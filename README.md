# ALS Brightness

Ambient-light adaptive panel brightness for Linux, implemented as a
[Noctalia](https://noctalia.dev) plugin service.

The panel follows the light in the room — and the moment you touch the
brightness keys, it gets out of the way, because a manual adjustment is treated
as intent rather than as an error to be corrected.

Built for an ASUS Zenbook S 16 UM5606WA (AMD SFH ambient light sensor, Radeon
890M panel, niri + Noctalia), but nothing is specific to that chassis except the
defaults.

## Why a plugin rather than a daemon

On this machine Noctalia already owns brightness: the brightness keys, the OSD,
`sync_all_monitors` and the per-monitor backlight selection all live there. A
separate daemon writing sysfs directly would be a second owner of the same
thing and would desynchronise the shell's own state. Noctalia's plugin API can
hold the whole feature — a headless `[[service]]` with a poll loop and direct
sysfs reads — so that is where it lives.

The fallback (a `~/.local/bin` Python daemon in the style of
`media-idle-bridge`) is not needed: every capability the design depends on was
proven on the running host. See `docs/DESIGN.md`.

## Install

```sh
noctalia msg plugins source add als-brightness path ~/Projects/als-brightness
noctalia msg plugins enable zhangdm/als-brightness
```

Then add the idle handshake to your idle policy — **this is required**, not
optional. Without it the adapter cannot tell the idle dim apart from you
lowering the brightness, and will either fight the dim or record it as your
preference. See `docs/DESIGN.md` § "The idle handshake".

## Settings

Configured in Noctalia's Settings UI, or via
`~/.local/state/noctalia/settings.toml` under
`[plugin_settings."zhangdm/als-brightness"]`.

| Setting | Default | Meaning |
| --- | --- | --- |
| `enabled` | `true` | Master switch. While off the panel is left alone entirely. |
| `connector` | `eDP-1` | Output to drive. |
| `backlight` | auto | Backlight device under `/sys/class/backlight`. |
| `reference_raw` | `185` | Sensor count that maps to the reference brightness. **This is the whole calibration.** |
| `reference_percent` | `70` | Brightness (percent) wanted at `reference_raw`. |
| `min_percent` | `15` | Hard floor, so a dark or occluded reading cannot blank the screen. |
| `max_percent` | `100` | Hard ceiling. |
| `colortemp` | `false` | Also warm the panel toward the ambient colour temperature. |

### Calibrating

Sit in the light you normally work in, read the sensor, and set `reference_raw`
to it while setting `reference_percent` to the brightness you actually want:

```sh
cat /sys/bus/iio/devices/iio:device2/in_illuminance_raw   # e.g. 185
```

Everything else is derived: the curve is "so many percentage points per decade
of ambient light" around that anchor, so one honest measurement configures the
whole range. The shipped default (`185` → `70%`) is the value measured on this
machine, not a guess.

## Testing

```sh
./run-tests.sh
```

92 checks over the pure decision logic. No hardware, no clock, no shell needed —
which is the reason all the logic lives in `policy.luau` and `colortemp.luau`
rather than in the service entry point.

## Layout

| Path | Role |
| --- | --- |
| `als-brightness/service.luau` | The `[[service]]` entry point. The only file that touches hardware or the shell. |
| `als-brightness/policy.luau` | Pure brightness decisions: curve, stabiliser, dead-band, override, guards. |
| `als-brightness/colortemp.luau` | Pure colour-temperature mapping and the settings.toml splice. |
| `tests/` | Unit tests for the two pure modules. |
| `docs/DESIGN.md` | Every decision, and the measurement behind it. |
| `catalog.toml` | Makes this repository installable as a plugin source. |
