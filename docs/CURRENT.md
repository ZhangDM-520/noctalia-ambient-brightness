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
5. The four seams the refactors introduced, each named in the module map
   below: `curve_source.resolve` (which curve is live — DESIGN.md §12.3), the
   `settings_spec` drift check (§12.5), `adaptation.decide` (the timeline —
   §5 and the measurements in §6.1; its power cost is in `docs/POWER.md`) and
   `hardware.guard_state` (§13).
6. The rest of `docs/DESIGN.md` as history only.

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
| `service.luau` | The `[[service]]` entry point, now a thin shim: reads settings and sysfs, calls the pure modules (`curve_source.resolve`, `adaptation.decide`, `hardware.guard_state`, `temperature.write_path`), then performs the returned actions (brightness write, temperature splice + `config-reload`, `profile.json` IO, logging). The only file that touches hardware, shell or filesystem directly, besides `hardware.luau`'s injected env. | Shallow by design, ~395 lines. Historical defects lived here (ms/s mix, override re-recording, splice line shift) — each now has a named regression test in `adaptation` / `temperature`; check the wiring first when behaviour is odd. |
| `curve.luau` | Pure PCHIP curve: node parsing (`parse_nodes`), `buildNodes`, `with_anchors`, `compile`/`eval`, `threshold_window`, `map_is_custom`, and the `DEFAULT_*`/`FIXED_*` constants every settings row derives from. | Deep: one interpolation implementation, no-overshoot asserted per interval. |
| `curve_source.luau` | Pure: `resolve(settings, opts)` — which curve is live and why: tolerant config readers, map-vs-sliders precedence, learned-nudge layering, curve building for both paths, and the explanation log lines returned verbatim in `report.log`. | Deep: one decision that used to span five places in `service.luau`; report-shaped like `hardware.discover()`. |
| `settings_spec.luau` | Pure: the settings-surface drift authority — `surface_rows()` derives the exact `plugin.toml` rows and `en.json` description strings the code constants imply. The shipped files are checked against it, never generated from it. | Deep derivation over shallow data: one authority per value, everything else diffed against it. |
| `adaptation.luau` | Pure: `decide(session, tick, observed, events, cfg, opts)` with an injected clock (`opts.now_ms`, ms — converted once) — the idle/override/learning timeline (detect → record → poll → expire → guard → adapt → temperature), returned as an ordered action list. | Deep in time behaviour; decide() performs no IO and every historical timeline defect has a named regression test here. |
| `policy.luau` | Pure brightness policy: stabiliser (asymmetric EMA on the log reading), slew, dead-band, guard, override window. | Deep in time behaviour; every constant traces to a measurement. |
| `profile.luau` | Pure learned profile: observations, `target_node`, `fit_thresholds` (threshold drift only, clamped). | Deep arithmetic, zero file IO — the entry point owns `profile.json`. |
| `colortemp.luau` | Pure temperature pieces: `clamp_k`, `should_apply` (the threshold gate) and the `settings.toml` text splice. | Deep: splice is text-in/text-out, unit-tested against real file shapes. |
| `temperature.luau` | Pure temperature write path: `should_apply(state, target_k, now_s, cfg)` (the splice gate, thresholds delegated to `colortemp`) and `write_path(state, kelvin, now_s, env)` — the splice → replace → reload sequence returned as actions. Sole owner of the `applied_k`/`last_temp_s` bookkeeping. | Deep in state bookkeeping: the old `apply_temperature` had five return paths and only some of them recorded; every path has a named test in `tests/temperature.test.luau`. |
| `hardware.luau` | `discover(env, opts)` with injected IO (`listDir`/`readFile`/`outputs`/`getenv`): every device path the plugin uses, probed once at start. The report also carries `guard_state(env)` — the runtime guard inputs (dpms/lid) with the unavailable-guard-passes decision folded in at the probe. | The deepest seam. Tests run fake machines through it (56 checks). |
| `translations/en.json` | Settings-row text (labels and descriptions). | Shallow data. |
| `plugin.toml` | Manifest: 30 settings, defaults, `visible_when` gating, slider windows. | Shallow data, but its defaults must agree with `curve.luau`. |
| `tests/` | 970 checks across 9 suites — `policy` 41, `colortemp` 44, `temperature` 58, `curve` 178, `curve_source` 126, `settings_spec` 331, `adaptation` 73, `profile` 63, `hardware` 56 — plus the `print-defaults.luau` helper. | Exercises only the pure modules and the hardware seam; verified by `./run-tests.sh` (2026-09-26). |
| `run-tests.sh` | Syntax (`luau-compile`), lint (`luau-analyze`), manifest lint (`noctalia plugins lint`), settings-surface drift check (`plugin.toml` + `en.json` diffed against `settings_spec.surface_rows()` — 62 rows), catalog version. | The whole offline gate; run it before committing. |

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
- **adaptation session** — `session`, the explicit timeline state
  `adaptation.decide` mutates (stabilised reading, last write, override window,
  idle/locked flags, applied kelvin, the curve-source report). Data in, an
  ordered action list out; decide() performs no IO and the service executes the
  list.
- **expiry re-baseline** — when an override expires (left the band or timed
  out) or the idle dim releases, the session re-baselines `last_written` from
  the observed panel value and does not adapt on that tick: a same-tick write
  would stomp the baseline and read as a fresh manual change.
- **learned profile** — `profile.json`: observations plus fitted thresholds.
  Learning drifts thresholds (EMA α = 0.125) toward observed ambient, never
  outputs; promoting a learned threshold into its slider is a manual copy.
- **drift guard / dead-band** — drift guard: `fit_thresholds` clamps every
  learned threshold into its `threshold_window`. Dead-band: `policy.should_write`
  with `dead_band_percent = 1` — no write until the command actually moves.
- **curve source** — the `curve_source.resolve(settings, opts)` report: which
  curve is live (edited map vs sliders, learned nudges layered on) and why, with
  the explanation log lines returned in `report.log` for the caller to emit.
  All precedence logic lives here and nowhere else.
- **drift check** — the `run-tests.sh` diff of the shipped settings surface
  (`plugin.toml` rows, `en.json` text) against `settings_spec.surface_rows()`.
  A convention the gate enforces: no value lives in more than one unchecked
  place.
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
- **guard state** — `hardware.guard_state(env)`: the hardware half of those
  guards (dpms, lid_closed) with the unavailable-guard-passes decision folded
  in at the probe — no DPMS node reads "On", no lid switch reads open. A device
  that *was* probed but fails to read later keeps its raw result (nil dpms
  blocks); availability was decided once, at the probe.
- **learning_profile / show_advanced** — the two page-head toggles.
  `learning_profile` gates *application* of learned thresholds, never recording;
  `show_advanced` reveals the two map editors. Both default off.
- **domain map (`map_x`)** — brightness x compiles in `log10(raw + 1)` domain;
  sliders and learning stay in raw counts and are mapped at build time. The
  temperature curve is linear in counts.

## Decision records

Decision — reason — evidence. All of these are locked.

- **All decision logic in pure modules** — testability without a display: 970
  checks across 9 suites run under a bare `luau` (verified by `./run-tests.sh`,
  2026-09-26). See DESIGN.md §2.
- **One `resolve()` for which curve is live** — the precedence decision used to
  span five places in `service.luau`, where no test could load it;
  `curve_source.resolve` returns the built curves and the log lines together.
  See DESIGN.md §10.5 and §12.1 (the defects it consolidates), §12.3.
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
- **`decide()` returns actions, never performs IO** — the idle/override/
  learning timeline is pure data in / action list out with an injected clock,
  so the ms/s mix cannot return and every timeline defect has a named
  regression test. See DESIGN.md §5 and the measurements in §6.1.
- **Unavailable guards PASS** — a machine without DPMS or a lid switch must
  still adapt; `hardware.guard_state` folds that decision in at the probe, so
  a nil path must never block. See DESIGN.md §13.
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
  page shows must be the number in use. The agreement is checked through
  `settings_spec.surface_rows()` (the drift check): `run-tests.sh` diffs keys as
  well as values, because text row sorting reorders an unpadded key. See
  DESIGN.md §12.5.
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
