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
- **`string_list` is ungated and renders as a full list editor** — add, remove,
  reorder, with a placeholder row. `getConfig` returns it as a Luau array, and an
  unset `string_list` returns the manifest default rather than nil.
  `string_map` exists too, but is gated behind a higher `plugin_api`.
- **`parseFieldType` silently falls back to `String`** for an unrecognised `type`.
  A typo in a setting's `type` does not error anywhere — it quietly changes the
  control. `noctalia plugins lint` is the only guard, so it runs in `run-tests.sh`.
- **Plugins read config but cannot write it.** Upstream states this plainly. A
  plugin cannot promote a learned value into its own settings; it must write a file
  and let the owner copy from it.
- **`noctalia msg config-reload` honours a hand edit** to `settings.toml` and fires
  `onConfigChanged`, so a settings change applies live without a restart. (An
  earlier note in `~/docs/MEMORY.md` warned that it overwrites hand edits; measured
  here, it did not.)

## Project conventions

- All decision logic lives in the **pure** `curve.luau` / `profile.luau` /
  `policy.luau` / `colortemp.luau` modules; `service.luau` is the only file allowed
  to touch hardware, the shell or the filesystem. This is what makes 236 checks
  runnable without a display.
- **The curve has exactly one implementation.** Phase 2 deleted two
  (`policy.percent_for_raw`, `colortemp.panel_k`) rather than leave them beside the
  new module, because two curves for one job drift apart while both stay tested.
- **Curve interpolation is PCHIP**, never a straight line and never a naive cubic.
  The no-overshoot property is asserted **per interval** in
  `tests/curve.test.luau`; a global-range check is too weak and was measured
  passing a curve that overshot by 5.93 points.
- **The manifest defaults and the code defaults must agree**, or the number the
  settings page shows is not the number in use. `run-tests.sh` diffs them.
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
