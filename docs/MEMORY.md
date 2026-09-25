# MEMORY

Durable facts about this project. Session-by-session working notes belong in
`NOTE.md`; this file should only hold things that stay true. The maintainer-facing
current state of the plugin lives in `CURRENT.md`.

Facts here are either about the reference machine or rules the code enforces;
each section says which.

## Environment facts this project depends on

Reference-machine evidence. The plugin discovers devices at runtime
(`hardware.luau`); these are what was measured, not assumptions the code makes.

- **On the reference machine the ambient sensor is `iio:device2`, `name = als`**
  (AMD SFH, `HID-SENSOR-200041`). `lux = in_illuminance_raw / 10`. Reads are **0.03 ms**
  median, so a 1 Hz poll is cheap despite each read being a synchronous
  hub transaction with runtime-PM churn.
- **The sensor cannot see the panel.** A 100× change in backlight output moved
  the reading by zero counts. Do not design for a feedback loop on this chassis.
- **On the reference machine `/sys/class/backlight/amdgpu_bl1` has
  `scale = non-linear`**, which per
  `include/linux/backlight.h` means the value is already perceptually spaced.
  Never apply a gamma to a non-linear device (check `scale` on yours; a linear
  one does need the perceptual mapping). `actual_brightness ≈ max·(req/max)^1.75`.
- **`noctalia msg brightness-set <connector> <0..1>`** takes a *fraction*, and
  maps exactly linearly onto `max_brightness`. There is no `brightness-get`.
- **logind `IdleHint` is never set under niri** — niri does not propagate
  idle to logind (measured on the reference machine; verify on your compositor).
  Do not try to use it as an idle signal. `/sys/class/drm/*/dpms`
  works but only reflects the 70 s screen-off stage.
- **`HandleLidSwitch = "suspend"`**, so closing the lid suspends rather than
  giving an occluded-but-awake sensor.
- **The idle dim is authored in `~/.config/nri-idle/idle.toml`** and installed
  into `~/.config/noctalia/config.toml` by `nri-idle install`. Edit the fragment,
  never the generated block.

## Noctalia plugin API facts (measured, not from docs; reference host: Noctalia 5.1.0)

- `plugin_api` levels are **cumulative**: 23 = `async-file-read`,
  24 = `direct-argv`. This plugin declares 24.
- `noctalia.pluginDir` and `noctalia.pluginDataDir` are **functions**.
- `readFile` results include a **trailing newline**.
- The **top level of a service runs once**; `update()` runs on
  `setUpdateInterval`. Defining `onConfigChanged` makes settings changes update
  in place instead of restarting the runtime, so in-memory state survives.
- The host API has **no brightness method, no brightness field on `Output`, and
  no brightness hook**. Shell out to `noctalia msg`. To let a script signal the
  plugin, use `noctalia msg plugin <id>:<entry> all <event>` — target `all` is
  required for a singleton `[[service]]`.
- A plugin source is a git repo **or a plain directory** with `catalog.toml` at
  the root and one subdirectory per plugin. `plugins source add <name> path <dir>`.
- **Luau has no `os` and no `io` library.** Take the clock from
  `noctalia.nowMs()` (milliseconds) and never from `os.time()`.
- **`require` differs between runtimes:** the host wants the extension
  (`require("./policy.luau")`), the standalone `luau` interpreter rejects it
  (`require("../policy")`). Both refer to the same file.
- **Settings render in declaration order**, so the first `[[setting]]` block in the
  manifest is the first control on the page. `visible_when = { key, values }` gates
  a setting live — the pattern the `colortemp` sliders prove. Do NOT use
  `advanced = true` for a plugin sheet: it defers to the settings window's global
  Advanced filter, which sits behind the sheet modal and whose
  `requestContentRebuild()` omits `rebuildEditorSheet`, so an open sheet never
  refreshes — the setting then shows unconditionally (found the hard way,
  2026-09-22; the maps now use a plugin-owned `show_advanced` + `visible_when`).
- **`string_list` renders as a list editor with add, remove and move — and no
  edit.** `ListEditor` has exactly three callbacks (`setOnAddRequested`,
  `setOnRemoveRequested`, `setOnMoveRequested`) and renders each row as a read-only
  `ui::label`, so a value can only be changed by deleting the row and retyping it.
  This is true of **every** `string_list`, in every plugin. `getConfig` returns it
  as a Luau array, and an unset `string_list` returns the manifest default rather
  than nil.
- **`string_map` is the type that can be edited in place.** `makeStringMapBlock`
  renders each row as `ui::input` for **both** key and value, committing on Enter or
  focus loss. Gated at `plugin_api >= 6` (`kStringMapSettingPluginApiVersion`), so
  with this plugin's 24 no bump is needed. Plugin settings get **no suggested
  keys** — the manifest has no `suggested` field — which is lucky: suggested rows
  render the key as a read-only label, while unsuggested rows make both editable.
- **`string_map` rows sort by key as text**, and nothing in the manifest changes
  that. Zero-pad numeric keys (`"00185"`) so lexical order equals numeric order.
- A `string_map` manifest default **must be a TOML table** and every value **must be
  a quoted string**; both are hard manifest errors, not silent degrades. An unquoted
  `185:70` is rejected.
- **A `string_map` has no array part**, so `#value` is 0 at any size. Guarding
  emptiness with `#value > 0` silently discards the whole setting — use
  `next(value) ~= nil`.
- **A `string_map` edit masks its sibling rows.** Rows commit to *sub-paths*
  (`…map.<key>`), but the control's `overridden` flag is `hasEffectiveOverride`
  on the **whole map path** — so the first row edit stops the manifest default
  being served and every never-edited sibling vanishes from what the plugin sees.
  Unfixable from a plugin; **use scalar settings when each item must stay live
  while the others are edited**. This is why the curve sliders are `int`
  settings and the maps are an advanced fallback (Phase 6).
- **`parseFieldType` silently falls back to `String`** for an unrecognised `type`.
  A typo in a setting's `type` does not error anywhere — it quietly changes the
  control. `noctalia plugins lint` is the only guard, so it runs in `run-tests.sh`.
- **Plugins read config but cannot write it.** Upstream states this plainly. A
  plugin cannot promote a learned value into its own settings; it must write a file
  and let the owner copy from it.
- **`noctalia msg config-reload` honours a hand edit** to `settings.toml` and fires
  `onConfigChanged`, so a settings change applies live without a restart. (An
  earlier note in `~/docs/MEMORY.md` warned that it overwrites hand edits; measured
  here, it did not.) It does **not**, however, re-read `plugin.toml` — a manifest
  change needs `noctalia msg plugins disable`/`enable` to take effect.
- Plugin settings are stored `[plugin_settings."author/plugin"]` in
  **`~/.local/state/noctalia/settings.toml`** — not under `~/.config/noctalia/`,
  which holds only `config.toml`. Checking the wrong path silently "proves" nothing
  is stored.
- **`noctalia msg settings-open-plugin <id>`** opens the settings page at a plugin,
  and a compositor screenshot (niri: `niri msg action screenshot-screen`) puts a capture
  on the **clipboard**
  (`wl-paste --type image/png`), which is how the page can be inspected without a
  screenshot tool installed.

## Project conventions

Rules the code and tests enforce on any machine.

- All decision logic lives in the **pure** `curve.luau` / `profile.luau` /
  `policy.luau` / `colortemp.luau` modules; `service.luau` and `hardware.luau`
  are the only files allowed to touch hardware, the shell or the filesystem —
  `hardware.luau` through its injected environment, so a fake machine replaces it
  in tests. This is what makes 366 checks runnable without a display.
- **Host slider settings: `type = "int"` with `min`/`max`/`step`** (also `double`);
  the default must lie within [min, max] and `step > 0`. `visible_when = { key,
  values }` gates a control on another setting — the temperature sliders use
  `{ key = "colortemp", values = ["true"] }`. Declaration order is render order.
- **The curve has exactly one implementation.** Phase 2 deleted two
  (`policy.percent_for_raw`, `colortemp.panel_k`) rather than leave them beside the
  new module, because two curves for one job drift apart while both stay tested.
  (DESIGN §9.4)
- **Curve interpolation is PCHIP**, never a straight line and never a naive cubic.
  The no-overshoot property is asserted **per interval** in
  `tests/curve.test.luau`; a global-range check is too weak and was measured
  passing a curve that overshot by 5.93 points. (DESIGN §9.2)
- **The manifest defaults and the code defaults must agree**, or the number the
  settings page shows is not the number in use. `run-tests.sh` diffs them — and
  diffs the **keys** as well as the values, because the editor sorts rows by key as
  text, so a key that loses its zero-padding reorders the curve on screen without
  changing a single number. Since Phase 6 the diff also covers the 20 slider
  defaults and their min/max/step windows against `curve.threshold_window`.
  (DESIGN §9, §10)
- **A curve node is (threshold, output): outputs are fixed, sliders choose
  thresholds.** `curve.buildNodes` pairs, sorts and repairs to strictly
  increasing x; a slider crossing its neighbour swaps two steps and cannot break
  the curve. Precedence: an **edited** `curve_*` map wins over the sliders
  (`curve.map_is_custom` compares parsed nodes, so re-ordering/whitespace is not
  an edit) and **learning is suspended** while it does. Learning drifts
  thresholds (EMA toward the observed ambient) and never outputs. Settings-row
  titles are **bare node ids** (`Temp node 8`) and the description states the
  mapping (`sensor ambient temp mapped -> 6500K`). Never put a value in a
  title: it is a static string (host has no live-label interpolation) and it
  goes stale on the first slider move. The temperature curve ships **ten
  distinct outputs plus four hidden anchors** (`curve.with_anchors` on both
  temp paths): duplicated outputs used to carry the flat floor/ceiling runs
  and owners read the repeats as a bug — the flats belong under the hood,
  where PCHIP's zero tangent works invisibly (14 compiled / 10 visible).
  (DESIGN §12.2, §12.3, §12.4)
- **Nothing may be learned while the session is idle.** The 30 % idle dim is
  authored policy, not a preference; both the tick and the `onIpc` handler check
  `S.idle` before recording an observation. (DESIGN §4)
- **Time in the pure modules is SECONDS.** `noctalia.nowMs()` is milliseconds;
  convert once at the boundary. Mixing them silently makes every timeout fire
  immediately. (DESIGN §5)
- The **clock is a parameter**, never read inside the pure modules.
- Editing a user's TOML: **splice as text, never parse and re-serialise**, and
  return the input byte-for-byte when nothing changes. Same rule as `nri-idle`.
  (DESIGN §6)
- Toolchain: `luau-compile` for syntax, `luau-analyze` for lint, `./run-tests.sh`
  for the lot.

## Downstream integration

Project rules for the surrounding config (integration contract, any machine).

This plugin's idle handshake requires the `dim` behaviour in
`~/.config/nri-idle/idle.toml` to emit `idle-engaged` before dimming and
`idle-released` after restoring. **Removing those calls silently breaks the
adapter** — it would start treating the 30 % idle dim as a user preference.

The brightness keys additionally emit `user-adjusted`. That event is now ignored
while the session is idle, because the panel is not showing what the owner asked
for at that moment.

## Silencing an OSD (reference-host evidence, measured 2026-09-22 on Noctalia 5.1.0)

* **Every OSD passes one choke point with two gates**, in `OsdOverlay::show()`:
  `if (!isEnabled()) return;` (the runtime override set by `noctalia msg osd-disable` /
  `osd-enable` / `osd-toggle`) and `isOsdKindEnabled(config().osd.kinds, content.kind)`
  (per-kind config; `OsdKind::Brightness` maps to `kinds.brightness`).
* **Gate 1 is global; gate 2 is per-kind.** So *"stop the OSD for this one thing"* is only
  expressible in config, never at runtime. `[osd.kinds] brightness = false` lives in
  `~/.local/state/noctalia/settings.toml`, beside the `[osd]` cosmetics.
* **Noctalia's brightness OSD is driven by a change callback, not by the IPC command.**
  `application_services.cpp` wires `BrightnessService::setChangeCallback` to
  `BrightnessOsd::onBrightnessChanged`, and the callback fires from the logind path, the
  sysfs writer, the DDC path **and the inotify external-change watcher**. Consequence:
  **no writer escapes it.** Bypassing `brightness-set` to write sysfs is doubly futile —
  the `brightness` file is `-rw-r--r-- root root` (unwritable as a user anyway), and the
  watcher pops the same OSD.
* **Never build a save/restore around the OSD override.** `osd-enable` sets the override
  to *true*, which is not the same as leaving it unset, so a plugin that re-enables would
  force OSDs on for a user who configured `osd.enabled = false`. There is no `osd-reset`,
  and `osd-toggle` flips *and* reports, so the state cannot be read non-destructively.
  A crash mid-pair also leaves every OSD dead until the shell restarts.
* Useful cross-check that is *not* brightness: `noctalia msg volume-osd <n>` renders the
  volume OSD, so it proves gate 1 was not left stuck off by a test.

## Measuring a transient UI effect (reusable technique, learned the hard way)

A single screenshot at a fixed delay is **not** evidence, and a negative from one is not a
measurement. A brightness OSD was invisible at 0.7 s while being clearly present at 0.15 s
and 0.35 s — which first read as "the real path is already silent" and was wrong.

The method that works, for any transient on-screen effect:

1. **Make it continuous.** Re-trigger so the effect is on screen across the capture. For
   brightness, alternate the value every 200 ms — a *repeated identical* value triggers no
   change and therefore no OSD, which silently fakes a negative.
2. **Take three captures per case**, never one.
3. **Guard the clipboard.** `niri msg action screenshot-screen` puts the frame on the
   clipboard, so write a text sentinel with `wl-copy` first and require
   `wl-paste --list-types` to show `image/png` before trusting the frame. Without this, a
   missed screenshot silently re-reads the *previous* frame — which scored a false 1/3 on a
   suppression test here.
4. **Guard a blank screen.** The idle chain can fire mid-test (`suspended: dpms=Off`); check
   the capture's mean luminance and report a blank frame distinctly rather than scoring it
   as "no effect".
5. **Always include a causation control.** Removing the change and watching the effect
   return is what separates correlation from cause.

## Hardware discovery (Phase 7: rules the code enforces)

- **Never hardcode device paths.** `iio:device2`, `card1-eDP-1`, `LID`,
  `amdgpu_bl1`, `/home/zhangdm` were all true only on one machine. Every path now
  comes from `hardware.luau`'s `discover(env, opts)` — one injected-environment
  interface whose report splits `required_missing` (idle + one notification,
  write nothing) from `degraded` (drop that feature/guard, keep adapting).
- **An unavailable guard must PASS, not block.** `policy.guard` blocks unless
  `dpms == "On"`; a hardcoded wrong path made it read `nil` forever, so the
  plugin silently never adapted. Missing DPMS/lid now degrade to "guard passes".
- **Discovery runs once, at start — deliberately.** Re-probing per tick or per
  config change buys CPU cost for a rare case; the remedy for hotplug or a
  changed `connector`/`backlight` setting is toggling the plugin off and on
  (stated in the setting descriptions).
- **Lua patterns: `-` is a quantifier, not a hyphen.** `("colour-temp"):find("colour-temp")`
  returns nil (`r-` parses as repetition). Literal needles need
  `find(needle, 1, true)`.
- **The `luau` CLI has no `os.exit`** (and no `-e` flag): test suites finish with
  `error(string.format(...), 0)` when checks fail, matching the other suites.
