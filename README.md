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
| `learning_profile` | `false` | **The head of the settings page.** On: apply the curve learned from your own adjustments. Off: apply the node lists below. Either way the plugin keeps recording. |
| `curve_brightness` | 10 nodes | Your brightness curve. One row per node; the value is the target percent. Rows are editable in place. |
| `curve_temperature` | 10 nodes | Your panel-warmth curve. Same shape. |
| `enabled` | `true` | Master switch. While off the panel is left alone entirely. |
| `connector` | `eDP-1` | Output to drive. |
| `backlight` | auto | Backlight device under `/sys/class/backlight`. |
| `min_percent` | `15` | Hard floor, so a dark or occluded reading cannot blank the screen. |
| `max_percent` | `100` | Hard ceiling. |
| `colortemp` | `false` | Also warm the panel toward the ambient colour temperature. |

### The curve

Each curve is a **`string_map`**: one row per node, with the reading as the row's
key and the target as its value.

```toml
[plugin_settings."zhangdm/als-brightness".curve_brightness]
"00001" = "1:20.8"
"00030" = "30:50.6"
"00185" = "185:70"
"16384" = "16384:100"
```

It is a map rather than a list for one reason: **in-place editing**. Noctalia's
list editor has no edit callback — its rows are read-only labels with remove and
move buttons — so a node in a list can only be changed by deleting it and retyping
it. The map editor renders both cells per row as real inputs, so you edit a node
where it sits and press Enter (or click away) to commit.

Editing a value, and adding or removing a row, all work in the Settings UI. Two
habits make it pleasant:

* **Keys are zero-padded** (`"00185"`, not `"185"`). The editor sorts rows by key
  as text, so the padding is what keeps the curve reading in numeric order down
  the page. A row you add with an unpadded key still works — it just sorts to the
  bottom.
* **The value can be either the target alone or the whole node.** `"70"` takes its
  reading from the key; `"185:70"` carries its own. The value always wins, so a key
  that has fallen out of step can never move a node you typed — at worst the row
  sorts somewhere unexpected, and the plugin logs a line saying so.

Values *between* nodes are joined with a **monotone cubic (PCHIP)**, which is
guaranteed not to overshoot the two nodes it sits between — so however you move a
node, the panel stays inside the band you drew. A `#` starts a comment and blank
cells are ignored, so a half-edited map cannot break anything.

Readings are raw sensor counts, not lux. The sensor's absolute calibration is
unverified (a phone torch at point-blank reads only 1665 lux), so the curve is
defined against counts you can read directly:

```sh
cat /sys/bus/iio/devices/iio:device2/in_illuminance_raw
```

The ten shipped nodes reproduce "25 percentage points per decade of ambient light"
around the one datum measured on this machine — 185 counts → 70% — which is why a
fresh install behaves sensibly.

### The learned profile

With `learning_profile` **on**, the plugin fits a curve to the brightness
adjustments you have made and applies that instead of the node lists. Each band
takes the **median** of your adjustments in it — median rather than mean, because
this sensor moves ±10000 counts within a single 50 ms sample — and a band with
fewer than two adjustments falls back to the node you authored, so a sparse
profile degrades into the shipped curve rather than into noise.

The toggle gates **application, never recording**. The plugin always records, so
switching it on shows a profile that has been developing rather than an empty one.
That is what makes it useful while working out an initial curve.

The profile lives in `profile.json` in the plugin's data directory. The plugin
**cannot write its own settings** — the Noctalia host does not permit it — so
promoting a learned value into `curve_brightness` is a manual copy. The fitted
bands use exactly the node positions you authored, so it is a bar-for-bar paste.

## Testing

```sh
./run-tests.sh
```

263 checks over the pure decision logic. No hardware, no clock, no shell needed —
which is the reason all the logic lives in `policy.luau`, `curve.luau`,
`profile.luau` and `colortemp.luau` rather than in the service entry point.

The script also runs `noctalia plugins lint` (the only guard against an
unrecognised setting `type`, which the host silently degrades to a plain string),
and diffs the curve defaults in `plugin.toml` against those in `curve.luau` so the
settings page and the code cannot disagree about the shipped curve.

## Layout

| Path | Role |
| --- | --- |
| `als-brightness/service.luau` | The `[[service]]` entry point. The only file that touches hardware, the shell or the filesystem. |
| `als-brightness/curve.luau` | Pure: the user-owned curves, PCHIP interpolation, node parsing. |
| `als-brightness/profile.luau` | Pure: the learned profile — recording, band fitting, defensive loading. |
| `als-brightness/policy.luau` | Pure brightness policy: stabiliser, slew, dead-band, override window, guards. |
| `als-brightness/colortemp.luau` | Pure: the temperature guard rail and the `settings.toml` splice. |
| `tests/` | Unit tests for the four pure modules. |
| `docs/DESIGN.md` | Every decision, and the measurement behind it. |
| `catalog.toml` | Makes this repository installable as a plugin source. |
