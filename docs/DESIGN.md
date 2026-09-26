# Design

Every decision here is traceable to something measured on the target machine
(ASUS Zenbook S 16 UM5606WA, CachyOS, kernel 7.3.0-rc3, niri 26.04, Noctalia
5.1.0). That machine's concrete paths (`iio:device2`, `card1-eDP-1`, …) appear
below as *measurement evidence only* — at runtime the plugin discovers each
machine's devices fresh (§13), so nothing here assumes yours match.
Where a measurement corrected the original plan, that is stated
explicitly — the corrections are the most useful part of this document.
For the current-state module map, glossary and decision records, start at
`docs/CURRENT.md`; this document is the phase-by-phase history.

Raw evidence (the probe plugin's run log and sensor traces) was captured in the
session record during development and is not checked in.

---

## 1. What was true before any code was written

**The sensor already worked and nothing consumed it.**
`/sys/bus/iio/devices/iio:device2`, `name = als`, from `HID-SENSOR-200041` on the
AMD Sensor Fusion Hub. `lux = in_illuminance_raw / 10`. The room read 184–189
counts (~18.5 lux nominal).

**Reading it is cheap.** 20 consecutive reads: median **0.03 ms**, max 0.32 ms.
Upstream projects warn that a polled IIO device with
`in_illuminance_sampling_frequency = 0` can block for *seconds* waiting for a
fresh sample — `iio-sensor-proxy` forces ≥10 Hz for exactly that reason. On this
unit the kernel returns immediately, so the trap does not apply. The cost that
does remain is battery: in `hid-sensor-als.c` every `_raw` read is a synchronous
`hid_sensor_power_state()` → `pm_runtime_resume_and_get()`/`put_autosuspend()`
transaction. Hence a 1 Hz poll, not a fast loop.

**The panel cannot see itself.** Stepping the backlight 1 % → 100 % (a 100× change
in emitted light) moved the reading by **nothing**:

| Panel set | `brightness` | ALS raw |
| --- | --- | --- |
| 100 % | 400000 | 188 |
| 40 % | 160000 | 188 |
| 1 % | 4000 | 188 |

The classic auto-brightness hazard — dim the panel, the sensor sees less light,
brightness falls further, the screen spirals down — **does not exist on this
chassis**. The sensor is optically isolated from the panel. This removed the
hardest part of the problem before design started.

**`scale = non-linear`.** Per `include/linux/backlight.h`:

```c
/** @BACKLIGHT_SCALE_NON_LINEAR: The scale is not linear.
 *  This is often used when the brightness values tries to adjust to
 *  the relative perception of the eye demanding a non-linear scale. */
```

The brightness value is therefore **already perceptually spaced**, so the curve
compresses the *ambient* axis logarithmically and maps **linearly** onto the
percentage. Applying an extra gamma to the panel value would double-correct.
(Measured sanity check: `actual_brightness ≈ max · (req/max)^1.75` — the panel's
own transfer function, living below the value we write.)

**The usable range is ~4000:1.** A hand over the sensor: 185 → **4 counts**. A
phone torch at the sensor: **16653 counts** (1665 lux nominal), well under the
15-bit field limit, so it does not saturate. 3.6 decades means a **logarithmic**
lux axis is mandatory — a linear one collapses everything below ~1000 counts
into a single step.

**The sensor is fast and noisy.** Largest single 50 ms change observed:
**±10 000 counts**. Under a hand it swung 12 → 17 → 47 → 67 → 79 → 83 → 78 → 68
→ 63 → 47 → 5 → 9 second-to-second. `in_illuminance_hysteresis_relative = 0`:
there is no filtering in the driver. **This is the empirical justification for
the asymmetric stabiliser and the dead-band.** A loop that wrote on every
reading would visibly pump.

---

## 2. Architecture: a Noctalia plugin, not a daemon

**Chosen:** a `[[service]]` in the Noctalia plugin API, with all decisions in
pure, unit-tested modules.

**Why.** Noctalia already owns brightness — the keys (`noctalia msg
brightness-up/down`), the OSD, `sync_all_monitors`, per-monitor backlight
selection. A daemon writing sysfs directly would be a second owner and would
desynchronise the shell. `noctalia msg brightness-set <connector> <0..1>` is a
clean first-class seam, and `brightness-osd` exists specifically for "an
external script controls brightness".

**This was validated before committing to it.** A throwaway probe plugin proved
on the running host that:

| Capability | Result |
| --- | --- |
| `plugin_api = 24` accepted | levels are cumulative; 23 = `async-file-read`, 24 = `direct-argv` |
| Top level runs **once** | tick counter and state survive; a settings change does **not** restart the runtime when `onConfigChanged` is defined |
| `readFile` / `readFileAsync` read sysfs | 0.03 ms sync, 1 ms async callback |
| argv `runAsync` (API 24) | `{"noctalia","msg","brightness-list-backlight-devices"}` → exit 0, 62 ms |
| `onIpc` receives events | `noctalia msg plugin <plugin> all <event>` → `onIpc(event, payload)` |

Two assumptions the probe corrected by running: `pluginDir`/`pluginDataDir` are
**functions**, not strings; and `readFile` results include the **trailing
newline**.

Also decisive for the design: the host API has **no brightness method, no
brightness field on `Output`, and no brightness hook event**. So the plugin must
shell out to `noctalia msg brightness-set` and cannot *subscribe* to brightness
changes — which is why override signalling is an explicit event (§5).

**Rejected:** `wluma` is the mature off-the-shelf tool and would work here, but
it writes sysfs directly and — worse — it *learns*, so it would fold the idle
dim into its model as if it were a user preference. **Fallback:** a Python
daemon modelled on `~/.local/bin/media-idle-bridge`, not needed because every
capability above was proven.

---

## 3. The curve, and what "calibration" means here

> **Partly superseded by §9.** The domain reasoning below still holds, and the
> shipped default nodes are built from it — but the anchor table is no longer
> hard-coded. Since Phase 2 the curve is a list of nodes the owner edits. Read this
> section for *why* the mapping has the shape it does; read §9 for where it lives.

The value written is a percentage, which is already perceptual (§1). So:

1. compress the ambient reading **logarithmically** (`log10(raw + 1)`);
2. map **linearly** onto the percentage.

Anchors are in **raw sensor counts**, and expressed as *percentage points per
decade* around a single reference point:

| Ambient | Target |
| --- | --- |
| 1 count | 20 % |
| 10 | 30 % |
| 46 | 50 % |
| **185** | **70 %** ← the owner's measured preference |
| 1000 | 88 % |
| 4000 | 97 % |
| 16384 | 100 % |

**Why raw counts and not lux.** The sensor's *absolute* calibration is
unverified: a phone torch at point-blank range read only 1665 lux, which is
implausibly low. Anchoring the curve in absolute lux would therefore be
pretending to a precision that does not exist. Instead the curve is made
self-consistent with the one fact that is directly observable — the owner sat in
an 18.5-lux room and chose **70 %**. Every other anchor is derived from that by
"25 percentage points per decade", which is the shape wluma's log interpolation
arrives at from the opposite direction (learning).

This also collapses calibration to one honest measurement: read the sensor in
your normal light, set `reference_raw` to it and `reference_percent` to the
brightness you actually want. That is the whole procedure.

**Temporal shaping**, in this order, each stage a separate tested function:

| Stage | Setting | Why |
| --- | --- | --- |
| Asymmetric EMA on `log10(raw+1)` | rise τ = 5 s, fall τ = 0.5 s | damp the ±10 000-count noise; rise slowly, fall fast |
| Log → percent | the table above | perceptually even steps |
| Slew limit | 30 points/s | never jump; a full-range change lands in ~3 s |
| Dead-band | 1 point | suppress writes that would not be seen |

---

## 4. Guards, and the assumption that was wrong

The adapter must not act while the idle chain, the lock, or the user has the
panel. The plan assumed logind's `IdleHint` would be the signal. **It is not.**

Measured while genuinely idle (the 50 s dim had already fired):

| dpms | brightness | `IdleHint` | State |
| --- | --- | --- | --- |
| **Off** | **120000** (30 %) | **`b false`** | `s "active"` |

And `loginctl show-session` reports `IdleHint=no` for **both** sessions. **niri
never propagates idle state to logind, so `IdleHint` is unusable on this setup.**

DRM DPMS does work (`/sys/class/drm/card1-eDP-1/dpms` read `Off`) — but it only
flips at the **70 s screen-off**, leaving a ~20 s window (50 s dim → 70 s
screen-off) where the panel is deliberately at 30 % and still DPMS-`On`. In that
window a signal-based adapter would either fight the dim or record 30 % as the
user's preference.

### The idle handshake

So the chain announces itself instead. The idle behaviour in
`~/.config/noctalia/config.toml` (authored in `~/.config/nri-idle/idle.toml`)
emits an event before it dims, and another after it restores:

```toml
[idle.behavior.dim]
command = "noctalia msg plugin zhangdm/als-brightness:als all idle-engaged; brightnessctl -s && brightnessctl set 30% && ..."
resume_command = "brightnessctl -r && ...; noctalia msg plugin zhangdm/als-brightness:als all idle-released"
```

Order is load-bearing in both directions: **engage before** the brightness
changes, **release after** it is restored — so the adapter is suspended for the
whole window and re-baselines from the value `brightnessctl -r` puts back.
`;` rather than `&&` after each notify, so uninstalling the plugin degrades to
"no handshake" instead of "no dim".

This inverts the plan's assumption in a good way: rather than *inferring* intent
from a signal that turned out not to exist, the adapter is *told*. It is
deterministic rather than probabilistic.

Full guard set, checked before every write, cheapest first:

| Guard | Source | Note |
| --- | --- | --- |
| Panel not `On` | `/sys/class/drm/card*-{connector}/dpms` (discovered, §13) | covers the 70 s screen-off |
| Lid closed | `/proc/acpi/button/lid/*/state` (discovered, §13) | see below |
| Idle engaged | the handshake | covers the ambiguous 50–70 s window |
| Locked | `noctalia msg status`, polled every 10 s | lock can leave DPMS On |
| User override | §5 | |

**On the lid guard.** Closing the lid was deliberately not tested: logind reports
`HandleLidSwitch = "suspend"`, so the lid test would have suspended the machine
and killed the loggers. That is itself the answer — **lid closed ⇒ suspended ⇒
no adaptation can go wrong**, so the hazard is unreachable on a single-`eDP-1`
machine. It *is* reachable when docked with an external monitor, where
`HandleLidSwitchDocked` (default `ignore`) keeps the machine awake with the
sensor occluded; the guard costs nothing and belongs in the design for that case.
A hand-cover reproduces the sensor side well enough to test (down to 4 counts).

---

## 5. User override: how a manual change is handled

Two mechanisms, because they fail differently:

1. **Change detection.** `brightness` is read every tick; a value differing from
   what we last commanded by more than 2 points, while awake, is a manual change.
   This catches every writer, including the Settings UI, with no cooperation
   needed.
2. **Explicit signal.** The brightness keys additionally emit
   `noctalia msg plugin zhangdm/als-brightness:als all user-adjusted`, which
   reaches `onIpc`. Exact, and free.

**Recovery follows Android's rule, not a bare timer.** The change stays valid
while the lighting is still recognisably what it was — leave the band
`[0.5×, 2×]` of the anchor count, or hit a 300 s ceiling. A plain timer would
snap back after five minutes even if the room had not changed at all, which is
the behaviour users describe as "it fights me".

Two defects found by testing this, both fixed:

- **The override was re-recorded every tick**, resetting its own 300 s timer
  each second so it could never expire. Only the *first* detection records now.
- **Seconds and milliseconds were mixed.** `override_timeout_s` (300, seconds)
  was compared against `noctalia.nowMs()` (milliseconds), so every override
  expired on the first tick. The parameter is now named `now_s` and documented,
  and a boundary test pins it.

And one accounting rule that makes the whole thing work: **changes observed
while idle are never recorded as preferences.** Without it the authored 30 % dim
would teach the adapter that 30 % is what the user wants.

---

## 6. Colour temperature

> **Superseded in part (Phase 2, §9).** The two-anchor linear ramp described
> below was replaced by the PCHIP curve in `curve.luau` (`curve_temperature`).
> What survives unchanged: the route (drive Noctalia's night light), the splice
> discipline and its two corruption fixes.

**Route A — drive Noctalia's own night light — chosen, and it needed no new
dependency.** The plan expected this to be impossible ("no runtime temperature
setter") and proposed `wl-gammarelay-rs` from the AUR. That was wrong.

`temperature_day` / `temperature_night` are ordinary settings in
`~/.local/state/noctalia/settings.toml`, and `noctalia msg config-reload`
applies them **live**. Proven on hardware: writing 3000 K and reloading made the
panel visibly warm, and the reload itself was invisible (the Settings window
that appeared was from a separate `settings-open` call). Noctalia clamps values
(3000 read back as 2900), so it must be written and read back rather than
assumed.

This matters architecturally: Noctalia and niri both implement
`zwlr_gamma_control_v1`. Driving Noctalia keeps **one** writer of the gamma LUT.
`wl-gammarelay-rs` would have added a second owner, and a hand-written client
(route C) would have been strictly redundant.

Implementation: `colortemp.luau` maps ambient CCT → panel CCT (clamped linear
between configurable anchors, defaulting to the owner's own measured 5100 K
preference at warm ambient), then edits `settings.toml` and reloads.

The edit is the risky part, so it is **pure and tested**: `splice(text, kelvin)`
is text-in/text-out. It never parses and re-serialises — a TOML round-trip would
silently delete every comment and reorder every key in a file the user owns. It
touches only `enabled`, `force` and `temperature_night` inside `[nightlight]`,
preserves key order and comments, and returns the input byte-for-byte when
nothing needs to change so the caller can skip the write. Written atomically
(temp file + rename) so a reader never sees a partial file.

Testing found a real corruption here: inserting the missing `force` key shifted
the line numbers of the already-recorded keys, so the rewrite landed one line too
high and **wrote the night temperature over `temperature_day`**. Rewrites now
happen before insertions. A second test caught a subtler one — the splice always
appended a trailing newline, editing a byte outside `[nightlight]` in a file that
had none.

`colortemp` is **off by default**: enabling it turns night light on in forced
mode and overrides any day/night schedule, which is a real change of behaviour
and should be opt-in.

---

### 6.1 — Temporal behaviour of the adaptation

Research only; no code was changed for this section. Every claim carries a
confidence level. Anything not measured is marked *unverified* rather than
argued.

#### How often the plugin actually writes (observed, not estimated)

The tick is 1 Hz (`setUpdateInterval(1000)`, service.luau), but the write gate
`colortemp.should_apply` demands **both** `|target − applied| ≥ step_k (150 K)`
**and** `≥ min_interval_s (120 s)` since the last write. The ceiling is
therefore **0.5 writes per minute**, and each write is one splice + one
`config-reload` — *high confidence, code path*.

Under a steady room the real rate is lower still. A 12-sample 1 Hz trace of
`in_colortemp_raw` read 3182–3189 K (7 K spread); through the shipped curve
that maps to a **1.9 K** target movement — 80× below the 150 K gate, so **zero
writes** in that minute. The plugin log over the current run contains **zero**
`colortemp: applied` lines — *measured, high confidence*. The 150 K gate
doubles as the noise deadband.

#### The largest single step the current curve can command

The temperature path has **no slew** (brightness has `policy.slew`; temperature
does not — service.luau applies `target_k` whole). Evaluated against the shipped
14-node curve (`curve.eval` + `clamp_k`, run under luau, not estimated):

| scenario | ambient swing | commanded panel step |
| --- | --- | --- |
| torch across this sensor's measured range (2832→4500 K) | 1668 K | **490 K in one write** |
| any ambient outside the node span (full curve range) | — | up to **1400 K** |
| custom advanced map at clamp extremes (2500↔6500) | — | up to **4000 K** |

The mechanism snaps all of it in one frame (below), so the perceptual size of a
fast ambient change equals the full mapped delta — *high confidence, code +
eval*.

#### Mechanism granularity: reload is an atomic snap, not a ramp

Source: the host tree that built the running binary
(`.../noctalia-git/src/noctalia`, HEAD `e7acd0654`).

`noctalia msg config-reload` → `ConfigService::forceReload()`
(config_service.cpp:1839) → `loadAll()` + `fireReloadCallbacks()` →
`GammaService::reload()` → `apply()` → `applyTarget(kelvin)`, whose own comment
states *"discrete toggles (enable/force/reload) **snap in a single upload**"*
(gamma_service.cpp:582). `applyTarget` uploads the whole ramp once and returns;
there is **no interpolation on the reload path** — *high confidence, source*.

The ramp that does exist — `kRampDuration` 60 min, `kTargetStepKelvin` 50,
`kMinTickInterval` 2 s — only runs while `computeTarget()` reports
`transitioning=true`, i.e. while following the **clock-anchored schedule**
window. In forced mode (`force = true`, which our splice always writes)
`computeTarget` returns `transitioning=false` immediately, so the ramp timer is
never armed for us — *high confidence, source*. **Abruptness is ours, not
Noctalia's: DESIGN §6's claim stands, and the write cadence is the only knob.**

#### Trying to falsify "no runtime setter"

Four routes checked, in order of plausibility:

1. **`noctalia msg` subcommands** — `nightlight-enable/disable/toggle/
   force-toggle` exist; **no temperature command** exists in `schema_msg.h`.
   Claim survives — *high confidence*.
2. **Plugin API** — `docs/plugin-api.json` exposes `noctalia.getSetting(path)`
   (read-only). No setter. Claim survives — *high confidence*.
3. **The Settings window's own path** — sliders commit via
   `ConfigService::setOverride()` → `mutateOverrides()` → write file + `loadAll`
   + `fireReloadCallbacks()` in-process (config_overrides.cpp:1959). A real
   runtime setter, but **reachable only inside Noctalia's UI**, not over IPC —
   *high confidence; claim survives as stated for external writers*.
4. **inotify — the route the claim misses (falsified).** `setupWatch()`
   watches the state dir with `IN_MODIFY | IN_CLOSE_WRITE | IN_MOVED_TO |
   IN_CREATE` (config_service.cpp:54, watch registered at :1092). **Any external
   write to `settings.toml` triggers `loadOverridesFromFile()` + `loadAll()` +
   `fireReloadCallbacks()` on its own** — no `config-reload` needed
   (config_service.cpp:899). Our atomic rename is an `IN_MOVED_TO` event. The
   `m_ownOverridesWritePending` echo-skip applies only to Noctalia's *own*
   writes, not ours. So each of our temperature changes likely fires **two**
   full reload cycles: the inotify one, then the explicit `config-reload` —
   *high confidence (source), live double-fire **unverified** (Noctalia's log
   fd points at /dev/null)*. DESIGN's "we must send config-reload" is therefore
   half-wrong: the splice alone would apply; the msg is belt-and-braces (kept,
   because relying on inotify silently degrades if the watch fails — the source
   warns `overrides reload disabled` in that case).

#### Reload cost (measured)

Five timed `noctalia msg config-reload` runs: **0.04–0.05 s wall** each. The
IPC handler runs `forceReload()` synchronously before answering `ok`, so this
*includes* `loadAll` + all ~30 reload subscribers — *measured, high confidence*.
At the current 120 s ceiling that is a ~0.04 % duty cycle; even a 1 s ceiling
would cost 4–5 %. **Cost alone would permit a far tighter ceiling than 120 s.**

What the reload touches besides gamma: `fireReloadCallbacks()` runs **every**
subscriber — style, theme, bar, widgets, the settings registry. The registry
slider comment says values refresh "through the rebuilt registry on the next
config reload" — so **a reload while Settings is open rebuilds the sheet
underneath the user** (source-supported, *high confidence*). Whether that reads
as a visible flash, and whether a reload during another writer's frame tears,
is **unverified** — it needs a human eye on a GUI session (open question below).
Gamma itself cannot flash on an unchanged target: `applyTarget` returns early
when the rounded Kelvin is unchanged, and there is no restore-then-apply
interleaving on the reload path — *high confidence, source*.

#### The three smoothing options, with real numbers

Notation: N = step size per write, R = rate ceiling, τ = exponential time
constant. Costs drawn from the measurements above (reload = 40–50 ms; gate =
150 K / 120 s today; torch step = 490 K).

**(a) Quantised stepping** — move N K toward target per reload.
- Reload frequency: exactly `1/min_interval`; ceiling R bounds it directly.
- Visible step: N K, guaranteed.
- Torch: 490 K gap closes in `⌈490/N⌉` writes — N=150 → 4 writes; N=50 → 10
  writes spread over `10×interval` seconds.
- Guards/learning: rides unchanged (temperature already acts only when
  brightness would; `profile.luau` never learns temperature). The gate's deadband
  role must be re-homed, or steady-room noise (1.9 K mapped) is harmless anyway
  at any N ≥ 5 K.
- Fails when: N chosen too large → still a visible jump; interval too short →
  settings-sheet rebuild rate becomes annoying if the user has Settings open.

**(b) Exponential smoothing of the target** — `target' += α·(target − target')`,
τ = 1/α seconds.
- Reload frequency: one write per interval **while moving**, then silence once
  within the deadband of the applied value.
- Visible step: bounded by `Δ·α` per interval early, shrinking geometrically —
  the smoothest of the three.
- Torch: follows a lag curve instead of stepping; panel reaches ~63 % of the
  swing in τ, ~95 % in 3τ. Choosing τ = 30 s turns a 490 K single jump into
  ~5–8 writes of ≤ ~100 K over ~90 s.
- Guards/learning: same as (a). Smoothing state must reset when guards suspend
  adaptation (otherwise the first post-resume write replays stale motion) and
  when the user drags a slider (target is theirs, not ours).
- Fails when: ambient oscillates with period ≈ τ around a steep curve segment —
  the smoother chases both ways; needs the step gate as a deadband to quench
  it. Also τ too small degenerates to today's behaviour.

**(c) Hysteresis deadband** — write only outside a band around the applied value.
- Not an alternative: it controls **oscillation**, not step size or frequency.
  `step_k = 150 K` already *is* a deadband — the current design has (c)
  built in, which is why the steady room produces zero writes.
- Alone it does nothing for the torch jump: 490 K is far outside any
  reasonable band.

**Recommendation: (b) with (a)'s rate ceiling, keeping the existing (c).**
Smooth the *target* with τ ≈ 30–60 s, quantise writes at N ≈ 50–150 K with an
interval derived from the measured cost (10–30 s is comfortably affordable at
40–50 ms/reload; the binding constraint is the settings-sheet rebuild, not
CPU), and leave the 150 K-equivalent gate as the deadband that stops noise and
threshold chatter. This converts the worst observed-class step (490 K in one
frame) into a trail of ≤150 K steps over ~1–2 minutes, at ≤ 4 writes/min —
still 2.5× *under* today's maximum rate but spread across the transition
instead of concentrated at its end.

**Boundary conditions where this recommendation fails:**

1. **Settings-open rebuild**: any ceiling tighter than ~10 s multiplies visible
   settings-sheet rebuilds while the owner has the window open. If the owner
   reports flicker there, back the ceiling off toward 120 s and accept longer
   transitions.
2. **τ vs. oscillating ambient**: ambient swinging across a steep segment with
   period ≈ τ re-excites every write; the deadband must then grow, which in
   turn blunts responsiveness. There is a (segment-slope × swing-amplitude)
   region where no single (τ, N, band) triple is both smooth and quiet.
3. **Guard churn**: idle/lock/override toggling faster than τ resets the
   smoother repeatedly — each resume starts a fresh visible trail. Fast
   day-office patterns (lid open/close) degrade toward today's behaviour.
4. **inotify double-reload** (if confirmed live): doubling halves the effective
   ceiling budget per unit cost — conclusions above hold only per *logical*
   change, not per physical reload.
5. **Perception untested**: if this panel's owner cannot distinguish 150 K
   steps at 10 s cadence from a smooth ramp, all of this is complexity for
   nothing — see open questions.

#### Open questions that need hardware (or a human) to answer

1. **Does a config-reload flash when Settings is open?** Source says the sheet
   rebuilds; only a GUI session can say whether that reads as a flash or a
   seamless refresh. *(unverified)*
2. **Does the inotify path actually double-fire on our splice?** One controlled
   run — splice *without* the msg, watch the panel and the (currently
   /dev/null) log — settles it. Touches `settings.toml`, so it needs the
   owner's go-ahead. *(unverified)*
3. **What is the perceptual threshold of one step on this panel?** 150 K?
   50 K? Eye-vs-eye comparison at a fixed ambient. This picks N. *(unverified)*
4. **Q5 below: does the encoded-space gain land where we think on an HDR
   panel?** Needs a colorimeter or at least a reference-white comparison shot.
   *(unverified)*
5. **A real torch trace at 1 Hz**, not a 12 s steady-room sample: how fast does
   this sensor's CCT actually move? That numbers the worst-case Δ and therefore
   τ. *(unverified)*
6. **Reload latency with Settings open vs closed** — the 40–50 ms figure is
   for a quiet session; a heavy sheet may cost more. *(unverified)*

#### Q5 — fidelity attribution: mechanism, not mapping

`fillGammaRamp` writes `ramp[i] = mul × (i × scale)` for each channel
(gamma_service.cpp:229): a **per-channel gain applied uniformly to every entry
of the identity ramp**. The identity ramp is a straight diagonal precisely
because a straight line *is* the no-op in the LUT's domain; multiplying it by
`mul` makes the LUT a pure gain **in that domain** — the compositor's
gamma-encoded pipeline, not linear light (*high confidence for "gain in LUT
domain"; the exact pipeline position is niri-side and **unverified***).

Colorimetric consequence: a gain g applied in encoded space corresponds to a
gain of **g^γ** in linear light (γ ≈ 2.2 class). Because the three channels get
different g, the *ratios* between channels change non-linearly: the realized
white point does not sit where the `kelvinToRgb` ratios intended — a
**chromaticity (hue/saturation) error class plus a brightness error**, growing
with how far the gains drift from 1.0 (largest at our warm end, where blue is
scaled hardest). `kelvinToRgb` also clamps its input to 1000–10000 K, so
extreme commanded values bend further.

**DESIGN §7 should attribute residual fidelity loss to the mechanism**
(noctalia's encoded-space gain), **not to our mapping** — our curve only
chooses which K to command; how that K is turned into channel gains is entirely
`GammaService`'s. On this HDR panel (`hdr mode="on"`) where those LUT entries
ultimately land is the one *unverified* link in that chain (open question 4).

---

## 7. Known limitations

- ~~**An override does not survive a plugin restart.**~~ **Resolved in §9.** The
  override *window* is still in memory, but every override is now recorded as an
  observation in `profile.json`, which does survive a restart. Editing a setting
  re-reads the panel's current brightness as the baseline and adaptation resumes
  from there — self-correcting, mildly surprising.
- **Override expiry is a band or a timer, not learning.** ~~wluma folds a manual
  change into its model permanently; here the manual value expires once the
  lighting changes materially or after 300 s.~~ **Partly resolved in §9.** The
  window still expires on the band or the 300 s timer, exactly as designed — but
  the observation itself is retained, and with `learning_profile` on it is applied
  as a fitted curve rather than forgotten.
- **Absolute lux is not trustworthy** on this sensor, which is why the curve is
  anchored in raw counts (§3).
- **HDR is unaddressed, by everyone.** This panel runs `hdr mode="on"
  reference-luminance 256`. wluma contains no HDR code at all, and no daemon on
  Linux maps the brightness value through an HDR transfer function. The curve is
  therefore calibrated visually under HDR, and the residual uncertainty is
  accepted rather than solved.
- **The colour sensor is partly unsupported.** `in_colortemp_raw` responds
  (2832–4500 K measured, and it tracked the torch), but
  `in_chromaticity_x_raw`/`y_raw` read 0, so the CCT derives from incomplete
  data and should be treated as indicative.
- **`in_illuminance_sampling_frequency` is 0 and root-owned**, so the plugin
  cannot set it the way `wluma` and `iio-sensor-proxy` do. Reads are fast on this
  unit, so this is a non-issue in practice, but it is an unowned dependency.
- **Not verified interactively:** the lid guard, and the *visual* result of the
  colour-temperature adaptation (the config-level effect was verified; the tint
  was confirmed once by the owner).

## 8. Verification status

`./run-tests.sh` — 263 checks at the time of writing (Phase 1; the suite is 366
as of Phase 7, see docs/CURRENT.md), no hardware required, plus `noctalia plugins lint`
and a check that the manifest and code ship the same curve defaults. Verified live
on the machine:

| Behaviour | Evidence |
| --- | --- |
| Curve is exact | ALS 179 → target 69.6 % → `brightness` 278560 = 69.6 % of 400000 |
| Dead-band suppresses noise | after the first write, no further writes while ambient was stable |
| Override detected | manual 45 % → `user override recorded: observed=45.0%` → `suspended: user_override`, no fight-back |
| Override recorded once | repeated ticks logged nothing further (the expiry-reset defect is fixed) |
| Idle handshake, dim | `idle engaged` → `suspended: idle_engaged`, panel held at 30 %, **not** recorded as a preference |
| Idle handshake, resume | `brightnessctl -r` restored 278560 → `idle released, re-baselined at 69.6%` → `resumed: adapting` |
| DPMS guard | `suspended: dpms=Off` → `resumed: adapting` |
| Keybinding override | `user override via keybinding` |
| Colour temperature | ambient 3394 K → 5312 K; `settings.toml` spliced in place with the following `[notifications]` section intact; merged config confirmed |
| Manifest defaults really are served | marker test: manifest node set to `185:45` → `target=45.0`. Had `getConfig` returned nil and the code fallback been used, it would have stayed 70 |
| Non-monotone nodes honoured, not rewritten | `curve curve_brightness: values are not monotone; using them as written`, and the curve still applied |
| Learning records with the toggle **off** | `learning=false`, manual 55 % → `profile.json` written with the observation, `source=authored` unchanged |
| Learned curve applied | restart → `source=learned (1/10 bands)` → `target=42.5` = median(55, 30) for that band |
| Profile survives a restart | `observations=2` after disable/enable, loaded before the first write |
| A settings change applies live | `learning_profile=true` + `config-reload` → `config changed; curves rebuilt, now using learned (0/10 bands)`, no restart |
| Sparse profile degrades safely | 1 observation → `learned (0/10 bands)`, so the authored curve was used rather than noise |
| Idle is never learned | `user-adjusted ignored while idle (the dim is not a preference)`, and `profile.json` absent |
| Temperature curve applies | ambient 3377 K → `colortemp: applied 5296K`. A straight chord would give 5311; the 15 K gap is the flat-run tangent correctly pinned to zero |
| `string_map` defaults really are served | marker test: manifest node set to `185:25` → `target=25.1` at raw 189. The cached list default would have stayed ≈70 |
| The value wins over a disagreeing key | `row "16384" is keyed 16384 but its value says x=200; using the value` → `target=80.3`, matching the x=200 node |
| A bare target takes its reading from the key | override `"00030" = "88"` parsed with no complaint; the same run gave `brightness=3 nodes temperature=10 nodes`, i.e. a partial override merges over the manifest default |
| Both cells are editable in place | settings-page capture, OCR'd: rows render as `02700 -> | 2700:5100` — two separate input fields per row |
| The padded keys really do order the rows | lexicographic sort of the shipped keys equals numeric order of the parsed nodes (asserted per curve in `tests/curve.test.luau`) |
| The brightness OSD really does pop for the plugin | timing-independent loop: 3/3 captures showed `65%`. A single fixed-delay capture had given a false negative |
| `[osd.kinds] brightness = false` silences it | 0/3 with the line, 3/3 with it removed, 0/3 with it re-applied — causation, not correlation |
| Only the brightness kind is affected | `volume-osd` still showed with the line in place (2/3), so no OSD was left globally suppressed |
| The config edit is additive and parses | diff vs a `cp -p` backup: 7 added lines, 0 removed; `tomllib` reads `osd.kinds = {'brightness': False}` |
| The plugin is unaffected | `config: brightness=10 nodes temperature=10 nodes`, `target=70.2` at raw 188, `observations=0`, profile.json absent |

This table records the Phase 1 verification run. Later phases verify in §10.6,
§12.5 and §13; §6.1 adds measured temporal behaviour of the adaptation.

The lesson worth carrying forward: **every one of the four real defects found in
this work was found by running it, not by reading.** The `pluginDir` function
call, the seconds/milliseconds mix, the override re-recording, and the splice
index shift were all invisible to inspection and all caught immediately by a
test.

## 9. Phase 2 — the curve belongs to the owner, and the learning has somewhere to live

Both changes are shaped by what the host actually permits, not by what would have
been convenient.

### 9.1 What the host permits (measured)

- **`string_list` is a real, ungated setting type.** `plugin_manifest.cpp`
  recognises `string`, `string_list`, `string_map`, `bool`, `int`, `double`,
  `select`, `file`, `folder`, `glyph`, `color`. `string_list` needs no
  `plugin_api` bump, and `getConfig` returns it as a Luau array.
- **`string_list` renders as a full list editor.**
  `settings_control_factory.cpp:1164 makeListBlock` wires add, remove, reorder and
  a placeholder. The node list is variable-length by construction, so ten is a
  default and not a cap. **Partly superseded by §10:** the editor has no *edit*
  callback, so this was a good storage model and a poor editing one. The curves are
  now `string_map` for that reason.
- **Declaration order is render order.** `manifestSettingSpecs` walks the manifest
  fields in order and `settings_content_plugins.cpp` renders that vector in order,
  so declaring `learning_profile` first literally puts it at the head of the page.
- **Plugins read config but cannot write it.** Upstream: *"plugins read config but
  cannot write it."* The whole learning design bends around this — it is why the
  profile is a file the owner copies from, rather than a self-tuning curve.
- **`parseFieldType` falls back to `String` for an unknown type.** A typo in a
  setting `type` does not error anywhere; it silently becomes a text box. Hence
  `noctalia plugins lint` in `run-tests.sh`.

### 9.2 The curve: PCHIP, not a line and not a naive cubic

Ten sparse nodes joined with straight lines leave a derivative discontinuity at
every node, so the *rate* of adaptation jumps as the ambient crosses one. A naive
cubic removes that but **overshoots** — which on this curve means commanding over
100 % or below the floor, i.e. leaving the band the owner drew.

Fritsch–Carlson monotone cubic Hermite (PCHIP) does neither: weighted-harmonic-mean
interior tangents, zero tangents where the secants change sign, one-sided endpoint
differences. A monotone node list therefore produces a monotone curve, so
`min_percent`/`max_percent` are satisfied by construction rather than by clamping,
and the construction is local, so one node cannot ripple into its neighbours.

**The guarantee is asserted, and the assertion was checked for teeth.** An honest
naive-cubic variant (Catmull-Rom tangents, no sign guard) measured against the same
per-interval sweep:

| Node set | PCHIP | naive cubic |
| --- | --- | --- |
| flat run beside a steep climb | 0.000000 | **5.93** points outside the band, between two 10 % nodes |
| non-monotone (`50, 80, 20, 60`) | 0.000000 | 0.65 points outside |
| the shipped default curve | 0.000000 | **5.13** points outside, at raw ≈ 7413 — about 105 % |

The first row is why the test is **per interval**: that excursion never exceeds the
set's global maximum of 95 %, so a global-range check passes it. The original
version of this test *was* that weaker check, and was rewritten after the naive
cubic slipped through.

### 9.3 The learned profile

`learning_profile` gates **application, never recording**:

| Toggle | Curve applied | Recording |
| --- | --- | --- |
| on | fitted from `profile.json` | continues |
| off (default) | the authored node lists | continues |

Recording while off is the point of the design: switching the toggle on later
reveals a profile that has been developing rather than an empty file.

- Observations reuse the shape the override already builds (`{raw, percent, at}`),
  recorded in the curve's own domain so the fit lays straight onto the authored x
  positions.
- Each band takes the **median** of its observations, not the mean, because this
  sensor moves ±10000 counts within one 50 ms sample. A band with fewer than
  **two** observations falls back to the authored node, so a sparse profile
  degrades into the shipped curve rather than into noise.
- `profile.json` is loaded through `profile.sanitise`, because it is a file the
  owner can open and corrupt and it is read at plugin start. Every field is
  validated and anything unusable is dropped rather than trusted.
- The window is capped at 512 observations, newest kept.

Since the plugin cannot write config, promoting a learned value into the curve is a
manual copy — but the fitted x positions are exactly the authored ones, so it is a
bar-for-bar paste.

### 9.4 One curve, one implementation

`policy.percent_for_log`/`percent_for_raw` and `colortemp.panel_k` were **removed**
rather than left sitting alongside the new module. Two implementations of one curve
drift apart, and a duplicated test suite lets them drift while both stay green.
Their behaviour survives in the shipped default node lists, and
`tests/curve.test.luau` asserts the brightness default tracks the old formula to
within 1.5 points across the operating range.

### 9.5 A defect this phase found on hardware

`user-adjusted` recorded **the idle dim as a preference**. During verification the
session went idle, the 50 s dim drove the panel to 30 %, and an injected
`user-adjusted` event filed 30 % as a learned value — precisely the mistake the
idle handshake exists to prevent, arriving through the one code path that did not
check `S.idle`. The handler now ignores the event while idle, and the fix is
verified: `user-adjusted ignored while idle (the dim is not a preference)`, with no
`profile.json` written.

That makes five defects in this project found by running it rather than by reading
it.

---

## 10. Phase 3 — the nodes become editable in place

> **The map editor built here is superseded by §12** as the primary route: it
> worked, but its host-side override semantics masked sibling rows (§12.1). The
> analysis below is still correct and the maps survive as an advanced fallback.

The owner's report was that a curve node *"can only be edited by remove and create
new"*. That was accurate, and the cause turned out to be outside this plugin.

### 10.1 The root cause is the host's list editor

`ListEditor` (`src/ui/controls/list_editor.{h,cpp}`) exposes exactly three
callbacks — `setOnAddRequested`, `setOnRemoveRequested`, `setOnMoveRequested`.
There is **no edit callback**, and `rebuildRows()` renders every item as a read-only
`ui::label` beside ghost remove/move buttons. So for any `string_list`, in any
plugin, a value can only be changed by deleting its row and retyping it.

Three consequences worth recording:

- This is a **host-widget gap**, not a defect here, and nothing about the plugin
  could have worked around it: `string_list` offers no seam for a plugin to inject
  an edit affordance.
- Phase 2 chose `string_list` believing reorder-plus-add-plus-remove was a
  reasonable editing model. It was a reasonable *storage* model and a poor *editing*
  one; the screenshot below is what settled it.
- No upstream issue tracks this. The only `list_editor` PR ever filed was
  *"Don't disable the dropdown on full"* (#4458, merged), so an upstream fix would
  be new work rather than a +1.

### 10.2 `string_map` is the type that can be edited in place

`SettingsControlFactory::makeStringMapBlock` builds each row as `ui::input` for
**both** the key and the value, each with `.onSubmit` and
`.submitOnFocusLoss = true`. Committing is Enter or clicking away. Two measured
details made this a clean fit:

- **The gate is API level 6** (`kStringMapSettingPluginApiVersion`), and this
  plugin declares 24, so `string_map` was already available and **no bump was
  needed**.
- **Plugin settings get no suggested keys.** `settings_content_plugins.cpp`
  constructs `StringMapSetting` with only `entries` and two generic placeholders,
  and `plugin_manifest.cpp` exposes no `suggested` field at all. That is lucky
  rather than incidental: `addSuggestedRow` renders the key as a read-only label
  with only the value editable, while `addCustomRow` — the path every row takes
  when there are no suggestions — makes both editable.

### 10.3 The catch: rows sort by key as text

```cpp
std::ranges::sort(customKeys);   // and `suggested` is sorted as well
```

The manifest exposes no field to change this, so numeric keys would render
`1, 10, 100, 1000, 16384, 185, 2200, 30, 4, 400, 4000` — a curve you cannot read.
The shipped keys are therefore **zero-padded** (`"00001"`, `"00185"`, `"16384"`),
which makes lexical order equal numeric order. `tonumber` strips the padding, so no
arithmetic changed, and `tests/curve.test.luau` asserts the property directly
rather than trusting it: for each curve, sorting the keys as text must yield the
same sequence as the nodes sorted numerically.

The residual papercut is honest and documented in the setting's own description: a
row added with an unpadded key sorts to the bottom. It still applies correctly,
because `parse_nodes` sorts numerically regardless.

### 10.4 One source of truth between the key and the value

The owner asked for the value to hold the full `"x:y"` node, which means the
reading appears twice per row. Rather than reject that as redundant, the rule is:

> **The value is the node. The key is a display-order hint.**

| Row | Result |
| --- | --- |
| `"00185" = "185:70"` | node at x=185, y=70 — the normal case |
| `"00185" = "70"` | no colon, so the key supplies x → x=185, y=70 |
| `"00185" = "200:70"` | value wins → x=200. One log line notes the disagreement; the row may sort oddly, the curve is exactly as typed |
| `"zzz" = "200:70"` | non-numeric key, still x=200 |

A stale key can therefore never silently move a node, and no row is dropped merely
for disagreeing. `curve.luau` still accepts a plain `string_list` as well — the
curve is just a list of numbers, and keeping that path costs nothing while leaving
every Phase 2 test meaningful.

### 10.5 The trap this migration created in the service

`setting_list` guarded emptiness with `#value > 0`. A `string_map` has **no array
part**, so `#value` is 0 at any size and that guard would have thrown away every
curve the GUI produced — silently, falling back to the shipped default, which looks
like "settings are ignored". It is now `next(value) ~= nil`, and the reasoning is
recorded at the call site.

### 10.6 What was verified, and what was not

Verified on the machine, in order:

1. The manifest parses and lints clean; the shape is enforced loudly
   (`string_map default must be a table`, and every value must be a quoted string —
   an unquoted `185:70` is a hard error, not a silent degrade).
2. **The host really serves the map default.** Node `185` set to `25` →
   `target=25.1` at raw 189, where a stale default would have held ≈70. This needed
   a disable/enable: `config-reload` alone does *not* re-read the manifest.
3. **The value wins over a disagreeing key**, live: `row "16384" is keyed 16384 but
   its value says x=200; using the value` → `target=80.3`, matching the x=200 node.
   The same run, driven from a hand-written `settings.toml` override, gave
   `brightness=3 nodes temperature=10 nodes` — a partial override merges over the
   manifest default, and the untouched curve still falls back correctly.
4. **The rendered page has two fields per row.** Opened via
   `noctalia msg settings-open-plugin`, captured with niri, and OCR'd: the rows read
   `02700 -> | 2700:5100`, and the new setting description renders verbatim.
5. The non-monotone warning fires through the new shape as well
   (`values are not monotone; using them as written`).

**Not verified directly:** that the two fields accept keystrokes — that rests on the
`ui::input` construction read from source, on the placeholder translation keys being
present in the *installed* binary (checked with `grep -a`), and on the host
honouring a value written to `settings.toml` in exactly the shape the editor writes
(point 3). It was not exercised with synthetic input events.

**Also corrected:** an earlier check of "is anything stored that a type change would
orphan?" looked at `~/.config/noctalia/settings.toml`, which does not exist on this
machine. The real file is `~/.local/state/noctalia/settings.toml`, where
`[plugin_settings]` holds only `nightwatch75/todo`. The conclusion held — nothing
was stored, so the migration was free — but it had been reached via a path that
could not have shown the answer.

### 10.7 Rejected alternatives, recorded

- **Patch Noctalia's `ListEditor`** to add an edit affordance. The correct
  root-cause fix, and it would repair the settings UI for every plugin. Rejected as
  the primary because `noctalia-git` is an AUR build: the patch would need
  re-applying on every update, and the plugin would then depend on a host change.
  Still worth offering upstream.
- **One `string` setting holding the whole list**, e.g.
  `"1:20.8, 30:50.6, 185:70"`. Genuinely editable in place with no ordering problem,
  and the easiest target to paste a learned profile into, but it loses the per-row
  structure entirely.
- **Keep `string_list`.** Status quo; the owner's actual complaint.

---

## 11. Phase 4 — silencing the brightness OSD

A continuous adapter pops the brightness OSD every time it adapts, so the feature is
not seamless. The fix turned out to be a config line the plugin cannot write, and
the investigation is worth recording because two plausible escapes are both closed.

### 11.1 There is one choke point and exactly two gates

`src/shell/osd/osd_overlay.cpp`:

```cpp
void OsdOverlay::show(const OsdContent& content) {
  if (m_wayland == nullptr || m_renderContext == nullptr) return;
  if (!isEnabled()) return;                                                       // gate 1
  if (m_config != nullptr && !isOsdKindEnabled(m_config->config().osd.kinds, content.kind)) return;  // gate 2
```

with `case OsdKind::Brightness: return kinds.brightness;`.

| Gate | Lever | Scope | Persistence |
| --- | --- | --- | --- |
| 1 | `noctalia msg osd-disable` / `osd-enable` / `osd-toggle` | **all** kinds | runtime only |
| 2 | `[osd.kinds] brightness = false` | **brightness only** | persistent |

There is no per-kind runtime control and no `osd-reset`. `osd-toggle` flips *and*
reports, so the current state cannot be read without changing it.

### 11.2 The OSD is driven by a change callback, so no writer escapes it

`src/app/application_services.cpp:1426` wires it:

```cpp
m_brightnessService->setChangeCallback([this, shouldRefreshControlCenter]() {
  m_brightnessOsd.onBrightnessChanged(*m_brightnessService);
```

and `BrightnessOsd::onBrightnessChanged` diffs a snapshot and calls
`m_overlay->show(...)`. In `brightness_service.cpp` the callback is fired by the
logind `SetBrightness` path, the direct sysfs writer, the DDC path, **and the inotify
external-change watcher** (`dispatchWatch`).

So the obvious workaround — "skip Noctalia and write sysfs" — is closed twice:

1. `/sys/class/backlight/amdgpu_bl1/brightness` is `-rw-r--r-- root root`, so a
   user-space write cannot happen at all.
2. Even if it could, or via logind, the inotify watcher fires the same callback and
   pops the same OSD.

`brightness-set` was never the cause. The change callback is, and it fires for every
writer.

### 11.3 The fix, and why it is not in the plugin

`[osd.kinds] brightness = false` in `~/.local/state/noctalia/settings.toml` — gate 2.
It is precise, persistent, and silences every writer: the plugin's adaptation, the
idle `dim` at 50 s, and the `brightnessctl -r` restore on resume. Its cost is the OSD
on manual brightness keys, which cannot be separated from the plugin's writes because
the gate is per-kind rather than per-writer.

The plugin cannot apply it — established in §9, plugins read config but cannot write
it — so the phase is a documented config change plus this record. No module changed.

### 11.4 Rejected: wrapping writes in `osd-disable` … `osd-enable`

Gate 1 is reachable from the plugin, which makes this the tempting option. It is
rejected because it is **not safely reversible**: `osd-enable` calls
`setEnabledOverride(true)`, which is not the same as leaving the override *unset*. For
an owner who has `osd.enabled = false`, "unset" means false and the plugin would force
OSDs **on**. With no non-destructive read and no `osd-reset`, the plugin cannot
guarantee it leaves the state it found. A crash between the two calls would also leave
every OSD dead until the shell restarts.

Recording it here so it is not rediscovered as a good idea.

### 11.5 Verification — and a false negative that had to be caught

A single screenshot at a fixed delay is not evidence. It first appeared that only
`brightness-osd` popped an OSD while `brightness-set` did not; sampling the same call
at three delays showed why:

```
delay=0.15s -> 60%
delay=0.35s -> 60%
delay=0.80s -> <none>
```

The OSD was simply gone before the capture. The method is now timing-independent and
redundant: alternate the value every 200 ms so every frame is a real change that
re-shows the OSD, and take **three** captures per case. Two further guards were forced
by what went wrong while testing:

* **Stale-clipboard guard.** Before each capture the clipboard is overwritten with a
  text sentinel; if `wl-paste --list-types` does not then show `image/png`, the capture
  is reported STALE rather than re-reading the previous frame. Without this, case B
  scored 1/3 on a frame left over from case A — a false "the OSD is still showing".
* **Screen-off guard.** The machine's idle chain fired mid-test (`suspended: dpms=Off`
  in the plugin log), so a blank screen is reported distinctly instead of being scored
  as "no OSD".

| # | Case | Result |
| --- | --- | --- |
| A | baseline, no `[osd.kinds]` | **3/3** captures showed `65%` |
| B | `brightness = false`, after reload | **0/3** |
| C | line removed again (control) | **3/3** |
| D | line re-applied (final state) | **0/3** |
| E | `volume-osd` with the line in place | **2/3** — other kinds unaffected |

A and C positive with B and D negative is causation, not correlation. E proves the
runtime override was not left stuck off, which is the one way this change could have
quietly broken every other OSD.

The config edit is additive only — 7 lines inserted, 0 removed, verified by diff
against a `cp -p` backup — and `tomllib` confirms it still parses.
`osd.kinds.brightness` was already documented upstream, so no schema change was needed.

### 11.6 The lesson

**A negative from a timing-sensitive capture is not a measurement.** The first result
looked like good news ("the real path is already silent") and was wrong. The fix is not
a longer delay — it is making the observation redundant and self-checking, so that a
miss is reported as a miss.

---

## 12. Phase 6 — sliders replace the map as the way to shape the curve

The `string_map` editor of Phase 3 could edit a node in place, but the first
edit quietly broke every *other* node. The fix is not a patch to the map: it is
splitting the node in two — **fixed outputs, slider thresholds** — and demoting
the map to an advanced override.

### 12.1 The masking bug, and why a plugin cannot fix it

Measured in `settings_control_factory.h` / `settings_content_plugins.cpp`: a map
row commits to its own **sub-path** (`…curve_brightness.00185`), but the control's
`overridden` flag is `hasEffectiveOverride` on the **whole map path**. The first
row edit therefore marks the entire map as overridden, the manifest default stops
being served as the effective value, and every sibling row — which was never
written anywhere — disappears from what the plugin sees. Editing node 3 blanks
nodes 1, 2, 4…10.

Nothing in the plugin's reach repairs this: the plugin only reads the resolved
config, the write happens entirely inside the host UI, and there is no
per-sub-path override query. **Scalar settings are the fix** — each commits to its
own path and masks nothing — so the editable surface had to become scalars.

### 12.2 The model: fixed outputs, slider thresholds

A node is a pair `(threshold, output)`. Phase 6 puts the halves in different
editors:

- **Outputs are fixed constants** (`FIXED_BRIGHTNESS_Y`, `FIXED_TEMPERATURE_Y` in
  `curve.luau`) — 20.8 % … 100 % and 5100 K … 6500 K, the shipped map values.
  The shape of the curve is never in question; only where its steps land is.
- **One `int` slider per node** (`thr_brightness_01..10`,
  `thr_temperature_01..10`) chooses the threshold. `curve.threshold_window` is
  the single source for each slider's min/max/step *and* the learning bounds —
  the manifest literals are diffed against it in `run-tests.sh`, so the two can
  never drift.
- `curve.buildNodes(thresholds, fixed_ys, {map_x})` pairs them up, sorts by
  threshold, repairs collisions to `x[i] = max(x[i], x[i-1] + 1)` (one log line
  per repair — sliding past a neighbour just swaps two steps), then applies the
  domain map (`log10(x+1)` for brightness) exactly as `parse_nodes` does.

Sliding past a neighbour cannot break the interpolation because the pair travels
together; the worst case is a reordered step and a nudge one count apart.

### 12.3 Precedence: an edited map wins

`curve.map_is_custom(items, defaults)` compares **parsed nodes**, not text —
re-ordering rows or retyping whitespace is not an edit, and a map with nothing
parseable is not an edit either. The rule at every rebuild:

- map unedited ⇒ sliders (+ learned nudges) are the curve;
- map edited ⇒ the map is the curve and **learning is suspended** — two writers
  over one curve is how a profile goes bad, and the owner has declared their
  intent by hand-editing.

One config log line names which source is active and why.

### 12.4 Learning drifts thresholds, never outputs

A manual brightness change is matched to `target_node` — the node whose **fixed
output** is nearest the chosen level (ties to the lower index) — and
`fit_thresholds` eases that node's threshold toward the observed ambient by EMA
(α = 0.125). Two observations before anything moves; each node drifts
independently; a node never observed is left exactly where the slider sits;
every result is clamped into `threshold_window`. The slider values are the seeds
learning starts from, applied on top at each rebuild (`sliders+learned (N/10
nodes)` in the source line).

Recording is still ungated (only application is gated), still idle-guarded, and
still cannot write config — the learned thresholds live in `profile.json` and are
applied at runtime only.

### 12.5 Verification

The drift check now covers **40 rows** — the 20 map nodes and the 20 slider
defaults/windows — and `tests/curve.test.luau` asserts
`buildNodes(DEFAULT_*_X, FIXED_*_Y)` reproduces each shipped map exactly, so
"slider defaults rebuild the shipped curves" is a tested fact rather than a hope.
Precedence is tested offline (`map_is_custom`: identical, re-formatted, edited x,
edited y, extra row, dropped row, garbage-only, empty). Suite totals: 41 policy
+ 44 colortemp + 157 curve + 63 profile = **305 checks, 0 failures** (Phase 6;
366 as of Phase 7).

## 13. Phase 7 — hardware availability: probe before load

The plugin used to *guess* the machine it ran on: `iio:device2`, `card1-eDP-1`,
`/proc/acpi/button/lid/LID/state`, an `entries[1] or "amdgpu_bl1"` backlight
fallback, and `/home/zhangdm` when `HOME` was unset. Each was true only on the
reference machine; anywhere else the service degraded silently (`read or 0`) or
never adapted at all — a wrong DPMS path in particular meant `policy.guard`
saw `nil`, which blocks adaptation forever.

Phase 7 moves all of it behind one module, `hardware.luau`:

- **Interface:** `report = hardware.discover(env, opts)` — `env` is injected
  (`listDir` / `readFile` / `outputs` / `getenv`), `opts` carries the raw
  `backlight` / `connector` settings. The report carries `paths` (each resolved
  or nil), `devices` (names for the startup log), `required_missing` and
  `degraded` (human-readable reason lists), and `guard_state(env)` — the runtime
  guard inputs (`dpms` / `lid_closed`) with the unavailable-guard-passes
  decision folded in, read through the same injected env.
- **Seam:** two adapters make it real — the Noctalia environment (service.luau)
  and a fake machine (tests/hardware.test.luau: 40 checks over 13 machine
  shapes: no sensor, `in_illuminance_input` fallback, raw-beats-input across
  devices, no/forced/unreadable backlight, bad connector, no outputs, no lid,
  no DPMS, no colortemp sensor, unset HOME).
- **Required vs degraded:** no ambient sensor, no readable backlight, an
  explicit setting naming hardware this machine lacks, or no output to drive →
  `required_missing`: one `noctalia.notifyError`, a log line, the service idles
  and writes nothing, ever. Missing colortemp sensor / DPMS node / lid switch /
  `HOME` → `degraded`: that feature or guard drops out, adaptation continues.
  An unavailable guard PASSES rather than blocks (the old nil-DPMS trap).
- **Discovery runs exactly once, at service start** — before the profile, the
  curves or the first tick. Re-probing costs CPU for a rare case; the remedy
  for hotplug or a settings change is toggling the plugin off and on, which the
  `connector`/`backlight` descriptions state. Both settings resolve inside that
  one probe: empty = auto (focused output, sorted device list), explicit =
  validated against `noctalia.outputs()` / the backlight directory.
- Runtime read failures after a successful probe log once (`warn_once`) and
  skip the write; zeros never reach the curve.

Verified live (2026-09-22): the probe logs `als=iio:device2 (als)
backlight=amdgpu_bl1 connector=eDP-1 colortemp=iio:device2 (als)
dpms=/sys/class/drm/card1-eDP-1/dpms lid=LID` with no degraded entries on the
reference machine, and a forced `backlight = "not_here"` idles the service with
the exact reason; restoring it recovers adaptation.
