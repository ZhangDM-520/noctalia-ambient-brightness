--!nonstrict
-- Tests for als-brightness/curve_source.luau.  Run from the repo root:
--     luau tests/curve_source.test.luau
-- Pure: a settings table goes in, one report comes out. No host API, no clock.
--
-- The cases below cover exactly the historical bug surfaces of the glue this
-- module absorbed (docs/DESIGN.md sections 10.5, 12.1 and 12.3):
--   * map precedence -- edited map vs sliders vs learned nudges;
--   * the string_map emptiness trap (`#value` is 0 for a map of any size);
--   * the host's row masking (one row edit blanks every sibling -- the map is
--     then genuinely "custom" and must win, which is why the sliders own the
--     live curve);
--   * learned-nudge application and masking (min_observations, window clamp,
--     never on a custom map);
--   * anchor building (four hidden temperature nodes);
--   * the source/learned_count reporting and the exact log lines.

local curve_source = require("../als-brightness/curve_source")
local curve = require("../als-brightness/curve")
local profile = require("../als-brightness/profile")

local failures = 0
local checks = 0

local function check(label, got, want)
  checks = checks + 1
  local ok
  if type(want) == "number" and type(got) == "number" then
    ok = math.abs(got - want) < 1e-6
  else
    ok = got == want
  end
  if not ok then
    failures = failures + 1
    print(string.format("FAIL  %s\n        got  %s\n        want %s",
      label, tostring(got), tostring(want)))
  end
end

local function check_true(label, got)
  check(label, got and true or false, true)
end

--- Compare the report's log lines element by element: these strings are the
--- contract with the log file and the live behaviour, so a one-character drift
--- must fail loudly.
local function check_lines(label, got, want)
  check(label .. ": line count", #got, #want)
  for i = 1, #want do
    check(label .. ": line " .. i, got[i], want[i])
  end
end

local function copy_map(src)
  local out = {}
  for k, v in pairs(src) do out[k] = v end
  return out
end

-- ── setting_keys: the config surface the module owns ────────────────────────
do
  local keys = curve_source.setting_keys()
  check("setting_keys: 23 keys (2 maps + learning + 20 sliders)", #keys, 23)
  check("setting_keys: 1", keys[1], "curve_brightness")
  check("setting_keys: 2", keys[2], "curve_temperature")
  check("setting_keys: 3", keys[3], "learning_profile")
  check("setting_keys: thr_brightness_01", keys[4], "thr_brightness_01")
  check("setting_keys: thr_brightness_10", keys[13], "thr_brightness_10")
  check("setting_keys: thr_temperature_01", keys[14], "thr_temperature_01")
  check("setting_keys: thr_temperature_10", keys[23], "thr_temperature_10")
end

-- ── the default report ──────────────────────────────────────────────────────
do
  local r = curve_source.resolve({})
  check("default: brightness source", r.brightness.source, "sliders")
  check("default: brightness not custom", r.brightness.custom_map, false)
  check("default: brightness visible nodes", r.brightness.visible, 10)
  check("default: brightness learned_count", r.brightness.learned_count, 0)
  check("default: learning flag off", r.brightness.learning, false)
  check("default: brightness has no hidden nodes", r.brightness.built.n, 10)
  check("default: temperature origin", r.temperature.origin, "sliders")
  check("default: temperature visible nodes", r.temperature.visible, 10)
  check("default: temperature hidden anchors", r.temperature.hidden, 4)
  check("default: temperature compiled size", r.temperature.built.n, 14)

  -- The sliders curve the report builds is exactly the curve the old glue
  -- built: same nodes, same domain map.
  local expected = curve.compile(curve.buildNodes(
    curve.DEFAULT_BRIGHTNESS_X, curve.FIXED_BRIGHTNESS_Y,
    { map_x = curve_source.map_brightness_x }))
  for _, raw in ipairs({ 4, 100, 185, 2200, 16384 }) do
    local x = curve_source.map_brightness_x(raw)
    check("default: brightness curve matches slider build at raw " .. raw,
      curve.eval(r.brightness.built, x), curve.eval(expected, x))
  end

  check_lines("default log", r.log, {
    "temperature curve: 10 visible + 4 hidden anchor nodes",
    "config: brightness=10 nodes via sliders, temperature=10 nodes via sliders, "
      .. "learning=false source=sliders",
  })
end

-- ── the threshold slider readers (old setting_thresholds) ───────────────────
do
  -- each slider commits to its own config path; a present key is honoured even
  -- as a string, a missing or wrong-typed key falls back to its own default
  local r = curve_source.resolve({ thr_brightness_03 = "37", thr_brightness_04 = true })
  check("thresholds: string value coerced", r.brightness.thresholds[3], 37)
  check("thresholds: wrong-typed value falls back", r.brightness.thresholds[4], 30)
  check("thresholds: missing keys keep defaults (no sibling masking)",
    r.brightness.thresholds[1], curve.DEFAULT_BRIGHTNESS_X[1])
  check("thresholds: missing keys keep defaults (last)",
    r.brightness.thresholds[10], curve.DEFAULT_BRIGHTNESS_X[10])
  check("thresholds: fitted matches thresholds when learning is off",
    r.brightness.fitted[3], 37)

  -- out-of-window values from a hand-edited config are honoured as written
  local r2 = curve_source.resolve({ thr_brightness_10 = 50000 })
  check("thresholds: out-of-window value honoured", r2.brightness.thresholds[10], 50000)

  -- a non-number everywhere is not a reader problem: buildNodes reports it
  local r3 = curve_source.resolve({ thr_temperature_02 = "nonsense" })
  check("thresholds: unparsable string falls back", r3.temperature.thresholds[2], 2700)
  check_lines("thresholds: fallback needs no log", r3.log, {
    "temperature curve: 10 visible + 4 hidden anchor nodes",
    "config: brightness=10 nodes via sliders, temperature=10 nodes via sliders, "
      .. "learning=false source=sliders",
  })
end

-- ── the string_map emptiness trap (DESIGN.md section 10.5) ──────────────────
do
  -- `#value` is 0 for a map of any size; only `next()` sees a keyed map. A
  -- non-empty map must never fall back to the shipped default.
  local r = curve_source.resolve({ curve_brightness = { ["00185"] = "185:70" } })
  check("one-row map: not the fallback", r.brightness.visible, 1)
  check("one-row map: custom", r.brightness.custom_map, true)
  check("one-row map: map source", r.brightness.source, "map (custom, learning suspended)")

  -- an EMPTY map is indistinguishable from "nothing here": the default wins
  local r2 = curve_source.resolve({ curve_brightness = {} })
  check("empty map: falls back to sliders", r2.brightness.custom_map, false)
  check("empty map: full default curve", r2.brightness.visible, 10)

  -- a bare string is accepted as a one-row list, so a hand-edited config cannot
  -- silently disable a whole curve
  local r3 = curve_source.resolve({ curve_temperature = "4000:5660" })
  check("bare string: one node", r3.temperature.visible, 1)
  check("bare string: custom", r3.temperature.custom_map, true)

  -- wrong type entirely: fall back
  local r4 = curve_source.resolve({ curve_temperature = 42 })
  check("wrong-typed map: falls back to sliders", r4.temperature.custom_map, false)

  -- nothing parseable in the map is not an edit: the sliders take over
  local r5 = curve_source.resolve({ curve_brightness = { ["a"] = "nonsense", ["b"] = "" } })
  check("garbage-only map: sliders win", r5.brightness.custom_map, false)
  check("garbage-only map: full slider curve", r5.brightness.visible, 10)
end

-- ── precedence: an edited map wins outright (DESIGN.md section 12.3) ────────
do
  local edited = copy_map(curve.DEFAULT_BRIGHTNESS)
  edited["00001"] = "1:25"
  local r = curve_source.resolve({ curve_brightness = edited, learning_profile = true })
  check("edited map: custom", r.brightness.custom_map, true)
  check("edited map: map source", r.brightness.source, "map (custom, learning suspended)")
  check("edited map: learned_count stays 0", r.brightness.learned_count, 0)
  check("edited map: learning flag still reported", r.brightness.learning, true)

  -- the map curve really is the map the owner wrote (25 at node 1)
  local x1 = curve_source.map_brightness_x(1)
  check("edited map: built from the edited rows", curve.eval(r.brightness.built, x1), 25)

  check_lines("edited map + learning log", r.log, {
    "learning suspended: curve_brightness is a custom map (the map wins outright)",
    "temperature curve: 10 visible + 4 hidden anchor nodes",
    "config: brightness=10 nodes via map, temperature=10 nodes via sliders, "
      .. "learning=true source=map (custom, learning suspended)",
  })

  -- learning off: same precedence, no suspension note
  local r2 = curve_source.resolve({ curve_brightness = edited })
  check("edited map, learning off: same source", r2.brightness.source,
    "map (custom, learning suspended)")
  check_lines("edited map, learning off log", r2.log, {
    "temperature curve: 10 visible + 4 hidden anchor nodes",
    "config: brightness=10 nodes via map, temperature=10 nodes via sliders, "
      .. "learning=false source=map (custom, learning suspended)",
  })

  -- re-ordering rows / re-typing whitespace is NOT an edit: the sliders win
  local reformatted = {}
  for _, v in pairs(curve.DEFAULT_BRIGHTNESS) do
    reformatted[#reformatted + 1] = "  " .. v .. "  "
  end
  local r3 = curve_source.resolve({ curve_brightness = reformatted })
  check("re-formatted map: not custom", r3.brightness.custom_map, false)
  check("re-formatted map: sliders win", r3.brightness.source, "sliders")

  -- the host's row masking (section 12.1): after ONE row edit the host stops
  -- serving the map default and the plugin sees a one-row map. That map IS
  -- edited, so it wins -- which is exactly why the maps were demoted to
  -- advanced fallbacks and per-node sliders own the live curve.
  local masked = { ["00003"] = "3:45" }
  local r4 = curve_source.resolve({ curve_brightness = masked, learning_profile = true })
  check("masked map: counts as custom (documented trap)", r4.brightness.custom_map, true)
  check("masked map: only the surviving row", r4.brightness.visible, 1)
  check("masked map: map source, learning suspended", r4.brightness.source,
    "map (custom, learning suspended)")
end

-- ── precedence: learned nudges vs map vs sliders ────────────────────────────
local function prof_with(raws, y)
  local p = profile.new()
  for i, raw in ipairs(raws) do
    profile.add(p, {
      x = curve_source.map_brightness_x(raw),
      y = y,
      raw = raw,
      at = i,
    })
  end
  return p
end

do
  -- learning on, sliders: the nudges are applied and reported
  local p = prof_with({ 500, 500 }, 70) -- targets node 6 (fixed output 70)
  local r = curve_source.resolve({ learning_profile = true }, { profile = p })
  check("learned: source names the count", r.brightness.source, "sliders+learned (1/10 nodes)")
  check("learned: learned_count", r.brightness.learned_count, 1)

  -- the EMA is seeded from the slider position (185) at alpha 0.15:
  --   185 + .15*(500-185) = 232.25
  --   232.25 + .15*(500-232.25) = 272.4125
  check("learned: node 6 drifted toward the observations", r.brightness.fitted[6], 272.4125)
  check("learned: slider seed reported unchanged", r.brightness.thresholds[6], 185)

  -- nudging node 6 must not move any sibling
  for i = 1, 10 do
    if i ~= 6 then
      check("learned: node " .. i .. " not masked/moved by node 6's nudge",
        r.brightness.fitted[i], curve.DEFAULT_BRIGHTNESS_X[i])
    end
  end

  -- one observation is below min_observations: the nudge is masked and the
  -- slider position rules
  local single = prof_with({ 500 }, 70)
  local r2 = curve_source.resolve({ learning_profile = true }, { profile = single })
  check("single observation: nothing learned", r2.brightness.learned_count, 0)
  check("single observation: still the learned source shape (0 of 10)",
    r2.brightness.source, "sliders+learned (0/10 nodes)")
  check("single observation: node 6 stays on its slider", r2.brightness.fitted[6], 185)

  -- learned thresholds clamp into the slider's own window (185 => 61..555)
  local clamped = prof_with({ 5000, 5000 }, 70)
  local r3 = curve_source.resolve({ learning_profile = true }, { profile = clamped })
  check("learned: clamped to the slider window", r3.brightness.fitted[6], 555)
  check("learned: clamp still counts as learned", r3.brightness.learned_count, 1)

  -- learning off: the same profile is ignored entirely
  local r4 = curve_source.resolve({}, { profile = p })
  check("learning off: profile ignored", r4.brightness.source, "sliders")
  check("learning off: fitted == sliders", r4.brightness.fitted[6], 185)

  -- a non-boolean learning flag is not a toggle
  local r5 = curve_source.resolve({ learning_profile = "yes" }, { profile = p })
  check("string learning flag: not a toggle", r5.brightness.learning, false)
  check("string learning flag: sliders source", r5.brightness.source, "sliders")
end

do
  -- custom map beats learned nudges: the profile must not touch the map
  local edited = copy_map(curve.DEFAULT_BRIGHTNESS)
  edited["00001"] = "1:25"
  local p = prof_with({ 500, 500 }, 70)
  local r = curve_source.resolve(
    { curve_brightness = edited, learning_profile = true }, { profile = p })
  check("map + profile: learned_count 0", r.brightness.learned_count, 0)
  check("map + profile: thresholds untouched", r.brightness.fitted[1],
    curve.DEFAULT_BRIGHTNESS_X[1])
  check("map + profile: the map is still the curve",
    curve.eval(r.brightness.built, curve_source.map_brightness_x(1)), 25)
end

-- ── the unreachable-but-shipped fallback branch ─────────────────────────────
do
  -- every threshold unusable => nothing to build => behave as if the toggle
  -- were off, so an unusable profile/config can never leave the panel adrift
  local settings = {}
  for i = 1, 10 do
    settings[string.format("thr_brightness_%02d", i)] = 0 / 0
  end
  local r = curve_source.resolve(settings)
  check("unusable: no active curve", r.brightness.built, nil)
  check("unusable: no base curve", r.brightness.base, nil)
  check("unusable: source falls back", r.brightness.source, "sliders (profile not usable yet)")
  check("unusable: visible count 0", r.brightness.visible, 0)
end

-- ── anchor building ─────────────────────────────────────────────────────────
do
  -- the four hidden temperature nodes: two below the first row, two above the
  -- last, replicating the endpoint outputs. The settings page sees the visible
  -- rows; compile() sees fourteen.
  local r = curve_source.resolve({})
  check("anchors: hidden count", r.temperature.hidden, 4)
  check("anchors: compiled n", r.temperature.built.n, r.temperature.visible + 4)
  check("anchors: first x", r.temperature.built.x[1],
    curve.DEFAULT_TEMPERATURE_X[1] - 500)
  check("anchors: second x", r.temperature.built.x[2],
    curve.DEFAULT_TEMPERATURE_X[1] - 300)
  check("anchors: last x", r.temperature.built.x[14],
    curve.DEFAULT_TEMPERATURE_X[10] + 1000)
  check("anchors: floor stays flat below the first row",
    curve.eval(r.temperature.built, 2100), curve.FIXED_TEMPERATURE_Y[1])
  check("anchors: ceiling stays flat above the last row",
    curve.eval(r.temperature.built, 7200), curve.FIXED_TEMPERATURE_Y[10])

  -- the same on the map path, with the visible count from the owner's rows
  local three = { "2500:5100", "4000:5660", "6500:6500" }
  local r2 = curve_source.resolve({ curve_temperature = three })
  check("anchors on map: origin", r2.temperature.origin, "map")
  check("anchors on map: visible", r2.temperature.visible, 3)
  check("anchors on map: hidden", r2.temperature.hidden, 4)
  check("anchors on map: compiled n", r2.temperature.built.n, 7)
  check_lines("anchors on map: line names the owner's rows", r2.log, {
    "temperature curve: 3 visible + 4 hidden anchor nodes",
    "config: brightness=10 nodes via sliders, temperature=3 nodes via map, "
      .. "learning=false source=sliders",
  })

  -- brightness never gets anchors
  check("anchors: brightness stays un-anchored",
    curve_source.resolve({}).brightness.built.n, 10)
end

-- ── source/learned_count reporting and the exact log lines ──────────────────
do
  -- learning on with an empty profile still says "sliders+learned (0/10 nodes)"
  local r = curve_source.resolve({ learning_profile = true })
  check("empty profile + learning: zero learned", r.brightness.learned_count, 0)
  check_lines("learning on log", r.log, {
    "temperature curve: 10 visible + 4 hidden anchor nodes",
    "config: brightness=10 nodes via sliders, temperature=10 nodes via sliders, "
      .. "learning=true source=sliders+learned (0/10 nodes)",
  })

  -- a row whose key disagrees with its value: one problem line, value wins
  local r2 = curve_source.resolve({ curve_brightness = { ["00001"] = "2:20.8" } })
  check_lines("key/value disagreement log", r2.log, {
    'curve curve_brightness: row "00001" is keyed 1 but its value says x=2; '
      .. "using the value (the row sorts by the key)",
    "temperature curve: 10 visible + 4 hidden anchor nodes",
    "config: brightness=1 nodes via map, temperature=10 nodes via sliders, "
      .. "learning=false source=map (custom, learning suspended)",
  })
end

do
  -- full ordering pin: problems first, then the suspension note, then the
  -- anchor count, then the config summary -- exactly the old reload() order.
  local edited = copy_map(curve.DEFAULT_BRIGHTNESS)
  edited["00001"] = "1:25"
  local r = curve_source.resolve({
    curve_brightness = edited,
    learning_profile = true,
    -- equal thresholds collide once sorted; buildNodes re-spaces and reports it
    thr_temperature_02 = curve.DEFAULT_TEMPERATURE_X[1],
  })
  check_lines("mixed log order", r.log, {
    "curve curve_temperature: 1 threshold(s) collided when sorted; "
      .. "nodes re-spaced to strictly increasing",
    "learning suspended: curve_brightness is a custom map (the map wins outright)",
    "temperature curve: 10 visible + 4 hidden anchor nodes",
    "config: brightness=10 nodes via map, temperature=10 nodes via sliders, "
      .. "learning=true source=map (custom, learning suspended)",
  })
end

-- ── rebuild determinism (the per-observation path) ──────────────────────────
do
  -- resolve() is pure: the same settings + profile give the same report, so
  -- the service can re-run it on every observation without any log or drift.
  local p = prof_with({ 500, 500 }, 70)
  local settings = { learning_profile = true }
  local a = curve_source.resolve(settings, { profile = p })
  local b = curve_source.resolve(settings, { profile = p })
  check("determinism: source", b.brightness.source, a.brightness.source)
  check("determinism: fitted", b.brightness.fitted[6], a.brightness.fitted[6])
  check("determinism: learned_count", b.brightness.learned_count, a.brightness.learned_count)

  -- a new observation moves the active curve without touching the log contract
  profile.add(p, { x = curve_source.map_brightness_x(500), y = 70, raw = 500, at = 3 })
  local c = curve_source.resolve(settings, { profile = p })
  check("new observation: more learned context", c.brightness.learned_count, 1)
  check_true("new observation: threshold drifts further",
    c.brightness.fitted[6] > b.brightness.fitted[6])
end

print(string.format("\n%d checks, %d failure(s)", checks, failures))
if failures > 0 then
  error(string.format("%d check(s) failed", failures), 0)
end
