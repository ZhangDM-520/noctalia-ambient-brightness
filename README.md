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

Then, to stop every adaptation from popping the brightness OSD, see
[Making it seamless](#making-it-seamless-silencing-the-brightness-osd) below. It is
a one-line config change, and the plugin cannot make it for you.

## Settings

Configured in Noctalia's Settings UI, or via
`~/.local/state/noctalia/settings.toml` under
`[plugin_settings."zhangdm/als-brightness"]`.

| Setting | Default | Meaning |
| --- | --- | --- |
| `learning_profile` | `false` | **The head of the settings page.** On: nudge the sliders below toward the ambient you adjust brightness in. Off: the sliders are used exactly as you set them. Either way the plugin keeps recording. |
| `thr_brightness_01` … `thr_brightness_10` | 1, 4, 10, 30, 100, 185, 400, 1000, 2200, 16384 | **One slider per curve node.** Each chooses the ambient reading where that node takes over; what the node outputs (20.8 % … 100 %) is fixed. |
| `thr_temperature_01` … `thr_temperature_10` | 2500 … 6500 | The panel-warmth thresholds, same idea. Shown only while `colortemp` is on. |
| `show_advanced` | `false` | **Advanced maps.** On: reveal the two raw map editors below; Off: hidden. |
| `curve_brightness` | 10 nodes | **Advanced** (behind `show_advanced`). Power-user override: one row per node, `reading:target`. Edit it and it wins over the sliders. |
| `curve_temperature` | 10 nodes | **Advanced.** Same shape. |
| `enabled` | `true` | Master switch. While off the panel is left alone entirely. |
| `connector` | `eDP-1` | Output to drive. |
| `backlight` | auto | Backlight device under `/sys/class/backlight`. |
| `min_percent` | `15` | Hard floor, so a dark or occluded reading cannot blank the screen. |
| `max_percent` | `100` | Hard ceiling. |
| `colortemp` | `false` | Also warm the panel toward the ambient colour temperature. |

### The curve

Each curve is **ten nodes**. A node is a pair — the ambient reading where it takes
over, and the output it produces there — and the two halves are edited in
different places: the **outputs are fixed** (20.8 %, 30.7 % … 100 % for
brightness; 5100 K … 6500 K for panel warmth) and **one slider per node chooses
its threshold**.

`thr_brightness_01` … `thr_brightness_10` are those sliders, low node first. As
ambient light rises past a slider's value, that node takes over from the one
before it. Sliding a node past its neighbour simply swaps two steps of the curve
— the pair travels together, so the shape is never in question — and two sliders
landing on the same reading are nudged one count apart (with a log line) so the
interpolation always has something to interpolate.

Because each slider is its own setting, editing one in the Settings UI commits
one value and touches nothing else. This is the point of the design: the earlier
`string_map` editor could not offer that (see below).

### The maps (advanced)

`curve_brightness` and `curve_temperature` are still there, behind the
**Advanced maps** toggle (`show_advanced`, default off), as a power-user escape
hatch: one row per node, key the reading,
value the target.

```toml
[plugin_settings."zhangdm/als-brightness".curve_brightness]
"00001" = "1:20.8"
"00030" = "30:50.6"
"00185" = "185:70"
"16384" = "16384:100"
```

**A map wins over the sliders exactly when it has been edited** — judged by
comparing its parsed nodes against the shipped defaults, so re-ordering rows or
retyping whitespace does not count. As long as it matches the defaults the
sliders are the curve; the moment you change a node (or add or drop one) the map
becomes the curve and learning is suspended, because two writers fighting over
one curve is how a profile goes bad. Delete the row you added to hand the curve
back to the sliders.

Two habits make map editing pleasant:

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

With `learning_profile` **on**, learning nudges the **threshold sliders**, never
the outputs. When you set brightness by hand, the change targets the node whose
fixed output is nearest the level you chose, and that node's threshold eases
(EMA, α = 0.125) toward the ambient light you were in — so the curve drifts to
match where you actually want each level, while its shape stays the one drawn
above. Two observations move anything at all; a node you have never been near
stays exactly where you slid it.

The toggle gates **application, never recording**. The plugin always records, so
switching it on shows a profile that has been developing rather than an empty one.
That is what makes it useful while working out an initial curve. Nothing is
learned while the session is idle — the 30 % idle dim is policy, not a
preference.

The profile lives in `profile.json` in the plugin's data directory. The plugin
**cannot write its own settings** — the Noctalia host does not permit it — so the
learned thresholds apply at runtime and are not written back to the sliders; a
slider you move yourself is the seed learning starts from. (While a `curve_*` map
is edited and winning, learning is suspended entirely.)

### Making it seamless: silencing the brightness OSD

An adapter that changes brightness continuously will pop Noctalia's brightness OSD
every time it adapts, which is not seamless. Add this to
`~/.local/state/noctalia/settings.toml`:

```toml
[osd.kinds]
brightness = false
```

This is the only precise fix, and it is **why** it is in your config rather than in
the plugin: every OSD passes through a single gate in `OsdOverlay::show()` that
checks `osd.kinds` per kind, but a plugin cannot write config. The plugin's only
runtime lever, `noctalia msg osd-disable`, is **global** — it would also kill your
volume, Wi-Fi, Bluetooth and caffeine OSDs.

Two bonuses worth knowing about:

* It silences the brightness OSD for **every** writer, not just the plugin — so the
  idle `dim` at 50 s and the `brightnessctl -r` restore on resume stop popping one
  too.
* Noctalia's `[osd]` cosmetics in `settings.toml` are known to drive the OSD
  (this machine renders it at `bottom_center`, not the documented default), so the
  `[osd.kinds]` table in the same file is read too.

The cost is the OSD when you press the brightness keys yourself: the gate is
per-kind, not per-writer, so the two cannot be separated. Brightness is the one
setting where the screen is its own feedback, but it is a real trade.

**Do not try to dodge the OSD by writing sysfs instead.** It cannot work twice
over: the backlight `brightness` file is `-rw-r--r-- root root`, so a user-space
write is not possible at all, and Noctalia watches the file with inotify and fires
the same change callback — which pops the same OSD. `brightness-set` is not the
problem; the change callback is, and it fires for every writer.

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
