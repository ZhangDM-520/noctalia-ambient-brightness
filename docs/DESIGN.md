# Design

Every decision here is traceable to something measured on the target machine
(ASUS Zenbook S 16 UM5606WA, CachyOS, kernel 7.3.0-rc3, niri 26.04, Noctalia
5.1.0). Where a measurement corrected the original plan, that is stated
explicitly — the corrections are the most useful part of this document.

Raw evidence, including the probe plugin's run log and the sensor traces, lives
in the session record (`files/probe-evidence.md` and friends).

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
| Panel not `On` | `/sys/class/drm/card1-eDP-1/dpms` | covers the 70 s screen-off |
| Lid closed | `/proc/acpi/button/lid/LID/state` | see below |
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

## 7. Known limitations

- **An override does not survive a plugin restart.** State is in memory, so
  editing a setting re-reads the panel's current brightness as the baseline and
  adaptation resumes from there. Self-correcting, mildly surprising.
- **Override expiry is a band or a timer, not learning.** wluma folds a manual
  change into its model permanently; here the manual value expires once the
  lighting changes materially or after 300 s. Simpler, and never fights, but it
  will not remember a preference across days.
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

`./run-tests.sh` — 92 checks, no hardware required. Verified live on the machine:

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

The lesson worth carrying forward: **every one of the four real defects found in
this work was found by running it, not by reading.** The `pluginDir` function
call, the seconds/milliseconds mix, the override re-recording, and the splice
index shift were all invisible to inspection and all caught immediately by a
test.
