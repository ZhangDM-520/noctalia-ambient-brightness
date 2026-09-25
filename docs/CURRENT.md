# CURRENT — start here

This repo is a Noctalia (Wayland shell) plugin in Luau that drives adaptive panel
brightness and colour temperature from the machine's ambient sensors. This file
is the current-state map — module layout, vocabulary, locked decisions;
`docs/DESIGN.md` is the phase-by-phase history and holds the measurements.

## Read-first path

1. This file.
2. `README.md`, the Settings section: user-visible behaviour — sliders, maps,
   learning, the OSD silencing step.
3. `docs/MEMORY.md`, "Project conventions": the rules the code enforces
   (pure-module split, seconds, splice discipline, manifest/code agreement).
4. `docs/DESIGN.md` §12 (the sliders/curve model) and §13 (the hardware probe):
   the two most recent designs, and the shape of the code as it stands.
5. The rest of `docs/DESIGN.md` as history only.

Sections older than §12 describe implementations that were replaced — read them
for *why*, never for *what the code does*. §3, §6 and §10 each carry an explicit
superseded callout at the top (§6's two-anchor ramp is gone; §10's map editor is
demoted to an advanced fallback). When history and this file disagree, this file
wins; if the code disagrees with both, the code wins.

## Module map

Source lives in `als-brightness/`. Depth here means: how much implementation
sits behind a small interface. If you are changing behaviour, find the row below
before opening a file — the depth note says where the fix belongs.

| File | What it owns | Depth note |
| --- | --- | --- |
| `service.luau` | The glue/entry point: the 1 Hz tick, guards wiring, the write path (`brightness-set`, the settings.toml splice + `config-reload`, `profile.json` IO), the IPC hooks (`onIpc`, `onConfigChanged`). The only file that touches hardware, shell or filesystem directly, besides `hardware.luau`'s injected env. | Shallow by design, ~673 lines. Historical defects lived here (ms/s mix, override re-recording, splice line shift) — check it first when behaviour is odd. |
| `curve.luau` | Pure PCHIP curve: node parsing (`parse_nodes`), `buildNodes`, `with_anchors`, `compile`/`eval`, `threshold_window`, `map_is_custom`. | Deep: one interpolation implementation, no-overshoot asserted per interval. |
| `policy.luau` | Pure brightness policy: stabiliser (asymmetric EMA on the log reading), slew, dead-band, guard, override window. | Deep in time behaviour; every constant traces to a measurement. |
| `profile.luau` | Pure learned profile: observations, `target_node`, `fit_thresholds` (threshold drift only, clamped). | Deep arithmetic, zero file IO — the entry point owns `profile.json`. |
| `colortemp.luau` | Pure temperature gate (`clamp_k`, `should_apply`) and the `settings.toml` text splice. | Deep: splice is text-in/text-out, unit-tested against real file shapes. |
| `hardware.luau` | `discover(env, opts)` with injected IO (`listDir`/`readFile`/`outputs`/`getenv`): every device path the plugin uses, probed once at start. | The deepest seam. Tests run fake machines through it (13 machine shapes). |
| `translations/en.json` | Settings-row text (labels and descriptions). | Shallow data. |
| `plugin.toml` | Manifest: 30 settings, defaults, `visible_when` gating, slider windows. | Shallow data, but its defaults must agree with `curve.luau`. |
| `tests/` | 366 checks across 5 test files (`curve`, `policy`, `profile`, `colortemp`, `hardware`) plus the `print-defaults.luau` helper. | Exercises only the pure modules and the hardware seam. |
| `run-tests.sh` | Syntax (`luau-compile`), lint (`luau-analyze`), manifest lint (`noctalia plugins lint`), defaults agreement (40 nodes + slider windows), catalog version. | The whole offline gate; run it before committing. |

Dependency direction: the pure modules never touch IO and never read the clock —
`service.luau` calls them. Nothing calls back up.

## Glossary

- **raw reading** — `in_illuminance_raw` sensor counts. The curve's x domain.
  Absolute lux is untrusted on this sensor, so nothing is calibrated in lux.
- **stabilised log reading** — `policy.log_of` (`log10(raw + 1)`) smoothed by an
  asymmetric EMA: rise τ 5 s, fall τ 0.5 s. What the curve is evaluated at.
- **percent** — panel brightness 0–100. Written as a 0..1 fraction to
  `noctalia msg brightness-set <connector>`.
- **kelvin** — panel colour-temperature target, clamped 2500–6500 K, written
  into `[nightlight] temperature_night` via the splice.
- **threshold (x)** — the ambient level where a node takes over. User-editable
  via its slider. **Output (y)** — what the node commands there; fixed constant
  (`FIXED_*_Y` in `curve.luau`), never edited, never learned.
- **map vs sliders** — map: the `curve_brightness`/`curve_temperature`
  `string_map` advanced editors, one row per node. Sliders: the
  `thr_brightness_NN`/`thr_temperature_NN` int settings, one per node.
- **hidden anchor** — four extra temperature nodes added by `curve.with_anchors`
  (two below row 1, two above row 10) so PCHIP keeps flat end tangents:
  14 compiled, 10 visible.
- **manual change vs override** — a manual change is DETECTED (observed differs
  from the last command by >2 points, or an `user-adjusted` IPC event); it opens
  an **override window**: the manual value stands while ambient stays in
  [0.5×, 2×] of its anchor count, or for 300 s.
- **learned profile** — `profile.json`: observations plus fitted thresholds.
  Learning drifts thresholds (EMA α = 0.125) toward observed ambient, never
  outputs; promoting a learned threshold into its slider is a manual copy.
- **drift guard / dead-band** — drift guard: `fit_thresholds` clamps every
  learned threshold into its `threshold_window`. Dead-band: `policy.should_write`
  with `dead_band_percent = 1` — no write until the command actually moves.
- **idle handshake** — IPC events, not logind: `idle-engaged`/`idle-released`
  emitted by the `dim` behaviour in `nri-idle`'s `idle.toml`. logind `IdleHint`
  is never set under niri and must not be used as an idle signal.
- **custom map precedence** — an edited map wins over the sliders and suspends
  learning; "edited" means its parsed nodes differ from the shipped defaults
  (re-ordering or whitespace is not an edit).
- **splice** — byte-preserving text edit of `settings.toml`
  (`colortemp.splice`): comments and key order survive, and the input is
  returned byte-for-byte when nothing changes.
- **guard** — `policy.guard`: may the plugin touch the panel right now? DPMS on,
  lid open, not idle, not locked, no override active. An *unavailable* guard
  (no DPMS node, no lid switch on this machine) passes — it must never block.
- **learning_profile / show_advanced** — the two page-head toggles.
  `learning_profile` gates *application* of learned thresholds, never recording;
  `show_advanced` reveals the two map editors. Both default off.
- **domain map (`map_x`)** — brightness x compiles in `log10(raw + 1)` domain;
  sliders and learning stay in raw counts and are mapped at build time. The
  temperature curve is linear in counts.

## Decision records

Decision — reason — evidence. All of these are locked.

- **All decision logic in pure modules** — testability without a display: 366
  checks run under a bare `luau`. See DESIGN.md §2.
- **One curve implementation only** — two implementations of one mapping drift
  apart while both stay green; Phase 2 deleted the duplicates. See DESIGN.md §9.4.
- **PCHIP, not a line and not a naive cubic** — a line jumps derivative at every
  node; a naive cubic overshoots out of the band the owner drew. No-overshoot is
  asserted per interval. See DESIGN.md §9.2.
- **Outputs fixed, sliders choose thresholds** — learning then has something
  safe to drift: node shape is never in question, only where its steps land.
  See DESIGN.md §12.2.
- **Edited map wins, learning suspended** — the map is the owner's explicit
  voice; two writers over one curve is how a profile goes bad. See DESIGN.md §12.3.
- **Titles bare, never values in static strings** — the host has no live-label
  interpolation; a value in a title goes stale on the first slider move. See
  docs/MEMORY.md "Project conventions" (the rows themselves: DESIGN.md §12).
- **Splice as text, never parse-and-reserialise** — comments and key order
  belong to the user; a round-trip deletes both. See DESIGN.md §6.
- **Probe hardware once at start, no hotplug** — re-probing costs CPU for a rare
  case; the remedy for changed hardware is toggling the plugin off and on.
  See DESIGN.md §13.
- **Unavailable guards PASS** — a machine without DPMS or a lid switch must
  still adapt; a nil path must never block forever. See DESIGN.md §13.
- **Nothing learned while idle** — the 30 % dim is authored policy, not a
  preference; the tick and the IPC handler both check before recording.
  See DESIGN.md §5.
- **Time in seconds inside pure modules** — the ms/s mix made every override
  expire on its first tick; convert once at the entry point. See DESIGN.md §5.
- **Temperature 14 nodes compiled / 10 visible** — duplicated outputs carried
  the flat floor/ceiling runs and read as a bug; the flats live under the hood
  where PCHIP's zero tangent works invisibly. The rule lives in
  docs/MEMORY.md "Project conventions"; the change is journaled in
  docs/NOTE.md ("Temperature curve restructure").
- **colortemp off by default** — enabling it forces night light on and overrides
  any day/night schedule; that is opt-in. See DESIGN.md §6.
- **Manifest defaults and code defaults must agree** — the number the settings
  page shows must be the number in use; `run-tests.sh` diffs keys as well as
  values, because text row sorting reorders an unpadded key. See DESIGN.md §12.5.
- **Plugins read config but cannot write it** — a learned threshold is applied
  at runtime and copied into its slider by hand; nothing pretends to write
  settings. See DESIGN.md §9.1.
- **The brightness OSD is silenced in user config, not by the plugin** — the
  only precise gate is the per-kind `osd.kinds` config, and the runtime lever is
  global; no save/restore around it. See DESIGN.md §11.

## What is deliberately not here

- No runtime temperature setter in the host — temperature goes through the
  settings.toml splice plus `config-reload`, and clamping means write-then-read
  back (DESIGN.md §6).
- No HDR handling — the curve is calibrated visually under HDR and the residual
  uncertainty is accepted rather than solved (DESIGN.md §7).
- The colour sensor is indicative only — `in_chromaticity_*_raw` read 0, so the
  CCT derives from incomplete data (DESIGN.md §7).
- No hotplug re-probe — discovery runs once; restart to re-probe (DESIGN.md §13).
