# NOTE — session journal

Working notes, newest last. Durable facts belong in `MEMORY.md`.

| entry (heading + date) | what it settled | where the durable version lives now |
| --- | --- | --- |
| 2026-09-22: Phase 6: sliders replace the map as the primary curve editor | 20 threshold sliders become the primary curve editor; maps demote to an advanced fallback; learning drifts thresholds, never outputs | DESIGN.md §12 + MEMORY.md Project conventions |
| Advanced-toggle fix (2026-09-22) | plugin-owned `show_advanced` + `visible_when` replaces the host's global Advanced filter | README.md "The maps (advanced)" + `plugin.toml` `show_advanced` |
| Hardware availability (Phase 7, 2026-09-22) | runtime device discovery in `hardware.luau`; required-missing vs degraded split | DESIGN.md §13 + MEMORY.md Hardware discovery |
| Temp-label disambiguation (2026-09-22) | bare node-id titles, mapping in the description, never a value in a title | MEMORY.md Project conventions (titles) + `translations/en.json` descriptions |
| Temperature curve restructure: 14 under the hood / 10 visible (2026-09-22) | unique output ladder plus 4 hidden anchors; 14 compiled / 10 visible | DESIGN.md §12 + MEMORY.md (14/10 rule) |
| Research: §6.1 temporal behaviour of the adaptation (2026-09-22) | measured temporal behaviour and the smoothing recommendation | DESIGN.md §6.1 |
| Architecture review + docs legibility pass (2026-09-25) | six churn-ranked deepening candidates (A–F) from `/improve-codebase-architecture`; docs-only wave: CURRENT.md read-first map + era-stamped history | docs/CURRENT.md (docs outcome); this entry (code candidates deferred) |

New entries go at the bottom; update this index in the same commit.

## 2026-09-22 — Phase 6: sliders replace the map as the primary curve editor

**Goal.** The `string_map` node editor masked sibling rows on the first edit
(host-side override semantics, see DESIGN.md §12.1). Replace it with 20 per-node
threshold sliders: curve outputs fixed, sliders choose each node's ambient
threshold, maps demoted to an `advanced` fallback that wins when edited, learning
nudges thresholds (EMA) not outputs.

**Actions, in order.**

1. `plugin.toml` v0.3.0 → v0.4.0: 20 `int` sliders (`thr_brightness_01..10`,
   `thr_temperature_01..10`) with min/max/step from `curve.threshold_window`,
   `visible_when = { key = "colortemp", values = ["true"] }` on the temperature
   set, both maps `advanced = true`. `translations/en.json`: 40 new entries,
   learning/map descriptions rewritten. Validated with `tomllib`/`json` — 29
   settings, declaration order as designed.
2. `curve.luau`: `FIXED_*_Y` / `DEFAULT_*_X`, `threshold_window(kind, index)`,
   `buildNodes(thresholds, fixed_ys, {map_x})` (pair → sort → repair collisions
   `x[i] = max(x[i], x[i-1]+1)` → map_x → drop unmappable, one problem line
   each), `map_is_custom(items, defaults)` (parsed-node comparison — decision
   logic lives in a pure module so it is offline-testable).
3. `profile.luau` rewritten around thresholds: `target_node` (nearest fixed
   output, ties → lower index), `fit_thresholds` (EMA α = 0.125 toward
   `obs.raw`, ≥ 2 observations before anything moves, per-node independence,
   clamp into `threshold_window`, unseeded nodes never invented).
   `tests/profile.test.luau` rewritten to match (63 checks).
4. `service.luau` precedence: `setting_thresholds` reader, `load_slider_curve`,
   `rebuild_active()` — custom map ⇒ map wins and learning is suspended; else
   sliders + learned nudges. One config log line names the active source.
   `record_observation` rebuilds only `if LEARNING and not BR_CUSTOM_MAP`.
5. Drift guard extended: `tests/print-defaults.luau` emits the 20 map rows and
   the 20 slider rows (key/default/min/max/step), `run-tests.sh` diffs them
   against `plugin.toml` — **40 rows must agree**.
6. Tests: `map_is_custom` suite added (identical, re-formatted, edited x, edited
   y, extra row, dropped row, garbage-only, empty). Totals 41 policy + 44
   colortemp + 157 curve + 63 profile = **305 checks, 0 failures** (the suite
   then; 366 since the temperature-curve restructure).
7. Docs: README (slider model, maps-as-advanced, precedence, threshold
   learning), DESIGN.md §12, MEMORY.md (masking + slider facts).

**Pitfalls hit.**

- A pasted edit block landed in `service.luau` instead of `curve.luau`
  (`map_is_custom`); removed and re-applied to the right file. Check the file
  after a multi-target edit session.
- Wrote an expected clamp floor of 400 for a window that computes **4000**
  (`threshold_window` floor is `floor(default/3)` scaled at the top node).
  Compute expectations from the module, not from memory.
- `select(1, fit(...))[2]` is fragile in the luau interpreter — use plain
  locals for multi-return in tests.

**Findings worth keeping** (also in MEMORY.md / DESIGN.md §12):

- `string_map` row edits commit to sub-paths while `overridden` is evaluated on
  the whole map path ⇒ the first edit masks every sibling. Unfixable from a
  plugin; scalar settings are the fix.
- `curve.map_is_custom` must compare *parsed nodes*: text comparison flags
  re-ordering/whitespace as an edit and flips precedence for nothing.
- Learning-suspended-while-map-edited is a locked decision.

**Next.** `p6-verify`: full `./run-tests.sh`, `noctalia plugins lint .`, plugin
disable/enable (manifest changes need it), then the GUI acceptance check
(20 sliders render, temperature sliders only with `colortemp` on, one slider
edit leaves siblings live, maps behind show-advanced, OSD still silenced).

## Advanced-toggle fix (2026-09-22)

**Problem.** GUI verify passed except the advanced toggle: the two maps were
always visible. The manifest only had `advanced = true`, which defers to the
settings window's *global* Advanced filter — that toggle sits behind the sheet
modal and its `requestContentRebuild()` omits `rebuildEditorSheet`, so an open
plugin sheet never refreshes. There was no plugin-side toggle at all ("the logic
is entirely not complemented").

**Fix.** Plugin-owned `show_advanced` bool (default off) declared directly above
the maps; `curve_brightness` and `curve_temperature` now use
`visible_when = { key = "show_advanced", values = ["true"] }` — the same pattern
the `colortemp` sliders already prove live. `advanced = true` removed: the host's
advanced filter runs *before* `visible_when`, so keeping it would hide the maps
whenever the global filter is off (unreachable from the sheet). `en.json` +2 keys
(60 total), 30 settings, declaration order unchanged otherwise.
`./run-tests.sh`: 305 checks, 0 failures (the suite then; 366 since the
temperature-curve restructure).

## Hardware availability (Phase 7, 2026-09-22)

**Problem.** The service hardcoded `iio:device2`, `card1-eDP-1`, `LID`,
`amdgpu_bl1` and `/home/zhangdm` — true only on the author's machine — and
degraded silently (`or 0`) when a path did not exist. A wrong DPMS path blocks
adaptation forever (`policy.guard` needs `"On"`).

**Fix.** New deep module `als-brightness/hardware.luau`:
`discover(env, opts) -> report` (paths / devices / required_missing / degraded)
over an injected environment. service.luau probes FIRST, at start: required
missing -> one notifyError + log + idle (no panel writes); optional missing ->
degrade + guard-passes + log. Discovery once at start (user decision: no
re-probing CPU cost; toggle the plugin to re-probe). `connector` default
`eDP-1` -> `""` (auto, validated against `noctalia.outputs()`), descriptions
note "restart after changing".

**Verified.** run-tests.sh 345 checks 0 failures at the time (the suite is 366
since the temperature-curve restructure; 40 new in tests/hardware.test.luau
across 13 fake machines); live: full probe report
logged, forced backlight `not_here` idled with the reason, restore recovered
adaptation.

## Temp-label disambiguation (2026-09-22)

**Report.** Screenshot showed `Temp node 8/9/10 · 6500 K` — read as three
nodes sharing threshold 6500 K, suggesting a broken mapping.

**Diagnosis: text-only.** Row titles echo the fixed **output**
(`FIXED_TEMPERATURE_Y` — the intentional 6500 K flat ceiling, nodes 1-3 the
5100 K floor); the description described the **slider** (ambient threshold).
Thresholds were always distinct and the curve monotone — 345 checks green then
(366 since the temperature-curve restructure) incl. `buildNodes(DEFAULT_X,
FIXED_Y)` ≡ default map. Rejected: thresholds in
titles (static text, stale after any slider move).

**Fix.** 20 en.json descriptions now name both quantities ("Where this step
applies (…). The title is its output."); README one-liner; MEMORY convention
bullet extended. No code change.

**Iteration (same day).** First attempt kept the output number in titles and
only rewrote descriptions — rejected: the user reads the title as the row's
number and wants no repeated values there. Host labels are static
(`literalLabel = translate(key)`, no value interpolation, sheet does not
rebuild on slider change), so titles cannot echo the live threshold either.
Final format (user-specified, all 20 rows): bare title + mapping description —
`Node 6` / `sensor lightness counts mapped -> 70%`, `Temp node 1` /
`sensor ambient temp mapped -> 5100K`.

## Temperature curve restructure: 14 under the hood / 10 visible (2026-09-22)

**Insight (user).** Ceiling/floor nodes are essential to smooth the curve but
duplicated OUTPUTS exposed in the rows read as a bug to common users.

**Change.** `FIXED_TEMPERATURE_Y` -> unique ladder [5100, 5240, 5380, 5520,
5660, 5800, 5940, 6080, 6220, 6500] (six original values kept at rows
1,3,5,7,9,10; four gap midpoints added — user chose "keep-originals").
New `curve.with_anchors(nodes)`: 4 hidden nodes (x1-500, x1-300, x10+500,
x10+1000, replicating endpoint y) prepended/appended on BOTH temperature
paths (slider + advanced map) in service.luau; brightness untouched (outputs
already unique). plugin.toml map default + en.json descriptions updated in
lockstep. Settings sliders/x/windows unchanged.

**Verified.** Suite 366 checks 0 failures (was 345; +21 in curve.test:
anchored eval pins floor 5100 ease-out at 2510 K, ladder rows, ceiling past
7500 K, + structural with_anchors block); manifest lint + "40 nodes agree" ok.

## Research: §6.1 temporal behaviour of the adaptation (2026-09-22)

**Task.** Research-only report appended to DESIGN.md as §6.1 (no code, docs/
only), from /tmp/als-brightness-research-prompt.md.

**Measured.**
- Cadence: 1 Hz tick, gate step_k=150K + min_interval=120s -> hard ceiling
  0.5 writes/min; steady-room 12-sample 1 Hz trace (3182-3189K) maps to 1.9K
  target movement -> 0 writes; log has 0 `colortemp: applied` lines this run.
- Largest single step (evaluated on shipped 14-node curve, luau): torch swing
  2832->4500K ambient = **490 K in one write** (no slew on temperature path);
  curve range 1400 K; clamp span 4000 K.
- Reload cost: 5x timed `noctalia msg config-reload` = 0.04-0.05 s wall,
  handler runs forceReload() synchronously -> includes all ~30 subscribers.

**Source findings (host e7acd0654).**
- Reload path snaps atomically: applyTarget comment "discrete toggles
  (enable/force/reload) snap in a single upload" (gamma_service.cpp:582); the
  60min/50K/2s ramp only runs in schedule mode, bypassed by force=true (which
  we always write). Abruptness is our write cadence, not Noctalia's.
- "No runtime setter" falsification: msg has nightlight enable/disable/toggle/
  force only; plugin API getSetting read-only; Settings UI setOverride is
  in-process only -> claim holds for external writers. BUT inotify
  (config_service.cpp:54/899/1092) watches state dir incl. IN_MOVED_TO: our
  atomic rename alone triggers loadAll+fireReloadCallbacks -- our splice likely
  fires TWO reloads (inotify + explicit msg). Live double-fire unverified
  (noctalia log fd = /dev/null).
- Q5: fillGammaRamp applies mul x identity ramp = per-channel gain in
  gamma-ENCODED space -> g in encoded = g^gamma in linear -> chromaticity
  error class; §7 fidelity loss attributed to mechanism, not our mapping.
  HDR landing spot unverified.

**Recommendation in §6.1.** (b) exponential smoothing (tau 30-60s) + (a)'s
rate ceiling (10-30 s affordable at 40-50ms/reload; binding constraint =
settings-sheet rebuild while Settings open) + keep existing (c) deadband
(step_k). Converts 490K single jump into <=150K trail over 1-2 min at <=4
writes/min. 5 failure boundaries stated; 6 open questions flagged for hardware
(flash on reload w/ Settings open, inotify double-fire, perceptual step
threshold, HDR colorimeter, real torch trace, reload cost with Settings open).

**Artifacts.** DESIGN.md +§6.1 (~180 lines); this journal entry. No code
touched; run-tests.sh not required (docs-only) but suite unaffected (366).

## Architecture review + docs legibility pass (2026-09-25)

**Review.** `/improve-codebase-architecture` over the whole repo produced an
HTML report at `/tmp/architecture-review-20260925.html`, ranking deepening
candidates by churn. Six candidates, in that order:

- **A — collapse curve-source resolution into one module.** "Which curve is
  live" (edited map vs sliders + learned nudges) is one decision spread across
  `service.luau` (`setting_thresholds`, `load_slider_curve`, `rebuild_active`);
  one module should answer it.
- **B — one settings-surface module behind plugin.toml/en.json/curve.luau.**
  The 30 settings, their row text and their slider windows are one fact in
  three files that `run-tests.sh` diffs to keep honest; one owner would make
  disagreement impossible.
- **C — a docs/CURRENT.md read-first document.** *Done in this pass.*
- **D — the hardware report should carry its guard-state semantics.**
  `discover()` returns paths and reason lists, and `service.luau` re-derives
  "may I write right now?" from them; the report already implies the decision
  and should carry it.
- **E — an adaptation-session `decide()` module with an injected clock.** The
  tick's ordering (guard → override → adapt → record) and the ms→s conversions
  live in `service.luau`; a pure `decide(session, input, now_s)` would put the
  whole policy under the test suite.
- **F — temperature write-path state machine + `curve.luau` accretion.**
  splice → write → `config-reload` → read back is open-coded at each call with
  its own failure handling, and `curve.luau` has accreted parse / build /
  anchors / domain-map duties worth splitting.

**Docs pass (this wave — docs only).** `docs/CURRENT.md` created as the
read-first map (module map, glossary, decision records, what is deliberately
not here). README / DESIGN / MEMORY / NOTE repaired: check counts era-stamped
(no bare stale totals left), an explicit superseded callout on DESIGN §6 (§3
and §10 carry theirs too) so the history reads as history, the dangling
`files/probe-evidence` link replaced with the statement that raw evidence is
not checked in, and the glossary and decision records that previously existed
nowhere.

**Plan.** Candidates A/B/D/E/F are **not** implemented in this wave. They land
in later waves, after the power-measurement baseline — the baseline is what the
next write-cadence and smoothing decision must be measured against, so it comes
first.

**Verified.** `./run-tests.sh` 366 checks 0 failures (41 policy + 44 colortemp
+ 178 curve + 63 profile + 40 hardware), lint and manifest lint clean,
"plugin.toml and curve.luau ship the same 40 nodes" ok, catalog/plugin version
0.4.0 agree. The luau diffs in this wave are comment-only.

## Power study P0–P4 + wave E completion (2026-09-26)

- **Code first**: the reboot/wave-E interruption left `adaptation.luau` failing 4
  checks in the override-expiry cluster. Root cause: the expiry tick continued
  into the write stage, stomping its own re-baseline (panel snaps back to the
  curve value and the next tick records a fresh override). Fixed: the expiry tick
  now performs only the transition (`return actions`); resume + first adaptation
  land on the next tick. One test check was over-strict vs. the pre-refactor
  change-only suspend logging (proven from `git show HEAD`); it now proves
  suspension by absence of writes. `run-tests.sh` wired for the suite:
  **912 checks / 0 failures** across 8 suites. Live-reload verified clean.
- **Power study** (trimmed per OLED burn-in concern: no dedicated S1 sigma
  windows, no spark cycle): meter verdicts and the reproducible protocol in
  docs/POWER.md. Headline numbers: settled platform floor ≈ 3.6 W, 1 Hz sigma
  0.22 W; plugin steady-state cost −0.03 W = **below resolution**; single-shot
  costs exceed the 3σ bar only for config-reload (+0.47 J), plugin disable
  (+0.63 J), plugin enable (+0.21 J); a plain backlight write is invisible.
  Scanner rule: 1 Hz deviations > 0.66 W or 2 s windows > 0.16 J over baseline.
  The A/B pair-1 (+1.5 W) is a documented run-start GPU transient, not plugin
  cost — ABBA's settled pair is the readable one. S2 sigma and spark energies
  remain unmeasured (recorded as gaps).
- Pitfalls re-confirmed: `pgrep -f` self-match (use `pgrep -x`), column-blind awk
  (verify the TSV header before attributing a column), and reboot/rewind kills
  all background agents — their partial work must be re-validated cold.

## Wave F: temperature write path + review follow-ups (2026-09-26)

- **Wave F (temperature.luau)**: `apply_temperature`'s open-coded splice → write →
  reload with five return paths became `temperature.write_path(state, kelvin,
  now_s, env)` — pure, injected IO, and the SOLE owner of the
  `applied_k`/`last_temp_s` bookkeeping (the old code recorded only on some
  paths). The splice gate moved to `temperature.should_apply` (thresholds stay
  in `colortemp`). `curve.luau` cleanup: `is_finite` has one home (now exported;
  `profile.luau` imports it), `with_anchors` got its own documented section, and
  `from_list` was deleted after a repo-wide verdict (zero callers; the
  `tests/curve.test.luau:125` hit is a *local* alias of `curve.parse_nodes`).
  Each of the 5 no-write return paths plus the applied path has a named test —
  `tests/temperature.test.luau`, 58 checks. Live-reload verified through the new
  path (`colortemp: applied 5574K`), log formats byte-identical.
- **Regression review of 17851af..f2a161a** (read-only, all six behavioral
  categories clean: 21 log strings, precedence branches, ms/s single conversion,
  guard semantics, wiring order). Two items fixed here:
  1. *Drift check gap (latent)*: `run-tests.sh` literal-checked only the
     `setting_number` fallbacks, so flipping a `plugin.toml` `default` for a
     bool/string setting stayed green. Now `setting_bool` / `setting_string` /
     `read_bool` fallbacks are checked too (enabled, colortemp, learning_profile,
     backlight, connector). Falsifiability proven by mutation probe: flipping
     `colortemp`'s default yields `FAIL service.luau falls back to false ...`.
  2. *Clock-order nit*: `update()`/`onIpc()` evaluated `read_observed()` before
     `noctalia.nowMs()` in call arguments — Lua evaluation order is unspecified,
     so the clock is now sampled first and hoisted to locals at both sites.
- **Docs sync**: module maps (README Layout + docs/CURRENT.md) now include
  `temperature.luau`; counts everywhere say **970 checks / 9 suites**
  (41 policy, 44 colortemp, 58 temperature, 178 curve, 126 curve_source,
  331 settings_spec, 73 adaptation, 63 profile, 56 hardware); DESIGN §13's
  "40 checks over 13 machine shapes" refreshed to the measured 56 with the
  current shape list (standalone `luau tests/hardware.test.luau` = 56/0).
- Pitfall: a mutation probe run in parallel with a read of the same tree
  contaminates the read (both saw the deliberately-broken state). Run mutation
  probes alone, re-read after revert.
- Gate: `./run-tests.sh` = **970 checks / 0 failures** on the final tree.
