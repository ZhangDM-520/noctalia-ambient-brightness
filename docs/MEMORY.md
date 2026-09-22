# MEMORY

Durable facts about this project. Session-by-session working notes belong in
`NOTE.md`; this file should only hold things that stay true.

## Environment facts this project depends on

- **The ambient light sensor is `iio:device2`, `name = als`** (AMD SFH,
  `HID-SENSOR-200041`). `lux = in_illuminance_raw / 10`. Reads are **0.03 ms**
  median, so a 1 Hz poll is cheap despite each read being a synchronous
  hub transaction with runtime-PM churn.
- **The sensor cannot see the panel.** A 100× change in backlight output moved
  the reading by zero counts. Do not design for a feedback loop on this chassis.
- **`/sys/class/backlight/amdgpu_bl1`: `scale = non-linear`**, which per
  `include/linux/backlight.h` means the value is already perceptually spaced.
  Never apply a gamma to it. `actual_brightness ≈ max·(req/max)^1.75`.
- **`noctalia msg brightness-set <connector> <0..1>`** takes a *fraction*, and
  maps exactly linearly onto `max_brightness`. There is no `brightness-get`.
- **logind `IdleHint` is never set on this machine** — niri does not propagate
  idle to logind. Do not try to use it as an idle signal. `/sys/class/drm/*/dpms`
  works but only reflects the 70 s screen-off stage.
- **`HandleLidSwitch = "suspend"`**, so closing the lid suspends rather than
  giving an occluded-but-awake sensor.
- **The idle dim is authored in `~/.config/nri-idle/idle.toml`** and installed
  into `~/.config/noctalia/config.toml` by `nri-idle install`. Edit the fragment,
  never the generated block.

## Noctalia plugin API facts (measured, not from docs)

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
  manifest is the first control on the page. `advanced = true` hides a setting
  behind "show advanced"; `visible_when = { key, values }` gates it conditionally.
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
  and `niri msg action screenshot-screen` puts a capture on the **clipboard**
  (`wl-paste --type image/png`), which is how the page can be inspected without a
  screenshot tool installed.

## Project conventions

- All decision logic lives in the **pure** `curve.luau` / `profile.luau` /
  `policy.luau` / `colortemp.luau` modules; `service.luau` is the only file allowed
  to touch hardware, the shell or the filesystem. This is what makes 263 checks
  runnable without a display.
- **The curve has exactly one implementation.** Phase 2 deleted two
  (`policy.percent_for_raw`, `colortemp.panel_k`) rather than leave them beside the
  new module, because two curves for one job drift apart while both stay tested.
- **Curve interpolation is PCHIP**, never a straight line and never a naive cubic.
  The no-overshoot property is asserted **per interval** in
  `tests/curve.test.luau`; a global-range check is too weak and was measured
  passing a curve that overshot by 5.93 points.
- **The manifest defaults and the code defaults must agree**, or the number the
  settings page shows is not the number in use. `run-tests.sh` diffs them — and
  diffs the **keys** as well as the values, because the editor sorts rows by key as
  text, so a key that loses its zero-padding reorders the curve on screen without
  changing a single number.
- **Nothing may be learned while the session is idle.** The 30 % idle dim is
  authored policy, not a preference; both the tick and the `onIpc` handler check
  `S.idle` before recording an observation.
- **Time in the pure modules is SECONDS.** `noctalia.nowMs()` is milliseconds;
  convert once at the boundary. Mixing them silently makes every timeout fire
  immediately.
- The **clock is a parameter**, never read inside the pure modules.
- Editing a user's TOML: **splice as text, never parse and re-serialise**, and
  return the input byte-for-byte when nothing changes. Same rule as `nri-idle`.
- Toolchain: `luau-compile` for syntax, `luau-analyze` for lint, `./run-tests.sh`
  for the lot.

## Downstream integration

This plugin's idle handshake requires the `dim` behaviour in
`~/.config/nri-idle/idle.toml` to emit `idle-engaged` before dimming and
`idle-released` after restoring. **Removing those calls silently breaks the
adapter** — it would start treating the 30 % idle dim as a user preference.

The brightness keys additionally emit `user-adjusted`. That event is now ignored
while the session is idle, because the panel is not showing what the owner asked
for at that moment.

## Silencing an OSD (measured 2026-09-22, Noctalia 5.1.0)

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

## Measuring a transient UI effect (learned the hard way)

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
