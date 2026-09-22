# NOTE — session journal

Working notes, newest last. Durable facts belong in `MEMORY.md`.

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
   colortemp + 157 curve + 63 profile = **305 checks, 0 failures**.
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
`./run-tests.sh`: 305 checks, 0 failures.

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

**Verified.** run-tests.sh 345 checks 0 failures (40 new in
tests/hardware.test.luau across 13 fake machines); live: full probe report
logged, forced backlight `not_here` idled with the reason, restore recovered
adaptation.
