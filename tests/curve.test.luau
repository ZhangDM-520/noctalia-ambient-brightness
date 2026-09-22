--!nonstrict
-- Pure-function tests for src/curve.luau.  Run from the repo root:
--     luau tests/curve.test.luau
-- No host API, no hardware, no clock.

-- The host resolves requires *with* the extension, the standalone interpreter
-- resolves them *without*; both point at the same file. Same as the other suites.
local curve = require("../als-brightness/curve")

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

-- ── parsing ──────────────────────────────────────────────────────────────────

do
  local nodes, problems = curve.parse_nodes({ "1:20", "10:30", "185:70" })
  check("three clean nodes parse", #nodes, 3)
  check("no problems on clean input", #problems, 0)
  check("x is read", nodes[3].x, 185)
  check("y is read", nodes[3].y, 70)
end

do
  -- whitespace and '#' annotation are tolerated, because the list editor makes it
  -- easy to type them and neither changes the meaning
  local nodes, problems = curve.parse_nodes({ "  185 : 70  # the measured datum" })
  check("whitespace and a comment are tolerated", #problems, 0)
  check("  ...and the value survives", nodes[1].y, 70)
  check("  ...with the x intact", nodes[1].x, 185)
end

do
  -- an unfilled row in the list editor is not an error
  local nodes, problems = curve.parse_nodes({ "1:20", "", "   ", "10:30" })
  check("blank rows are skipped silently", #nodes, 2)
  check("blank rows are not reported as problems", #problems, 0)
end

do
  local nodes, problems = curve.parse_nodes({ "1:20", "nonsense", "10:30" })
  check("a malformed row costs exactly one node", #nodes, 2)
  check("a malformed row is reported", #problems, 1)
  check_true("the problem names the row", problems[1]:find("entry 2") ~= nil)
end

do
  local nodes, problems = curve.parse_nodes({ "1", "10:30" })
  check("a row without a colon is rejected", #nodes, 1)
  check("  ...and reported", #problems, 1)
end

do
  local nodes, problems = curve.parse_nodes({ "1:20", "10:30", "1:99" })
  check("a duplicate x is dropped", #nodes, 2)
  check("a duplicate x is reported", #problems, 1)
  check_true("the problem says duplicate", problems[1]:find("duplicate") ~= nil)
  -- and first-wins, so the owner's later row cannot silently shadow the earlier one
  check("the first occurrence wins", nodes[1].y, 20)
end

do
  local nodes = curve.parse_nodes(nil)
  check("nil parses to an empty node list", #nodes, 0)
  local single = curve.parse_nodes("185:70")
  check("a bare string is treated as a one-row list", #single, 1)
  local nodes2, problems2 = curve.parse_nodes({ 42, "1:20" })
  check("a non-string row is rejected", #nodes2, 1)
  check("  ...and reported", #problems2, 1)
  local _, problems3 = curve.parse_nodes(42)
  check("a non-list is reported", #problems3, 1)
end

do
  local nodes = curve.parse_nodes({ "1000:88", "10:39", "185:70" })
  check("nodes are sorted ascending by x", nodes[1].x, 10)
  check("  ...second", nodes[2].x, 185)
  check("  ...third", nodes[3].x, 1000)
end

do
  -- the brightness domain transform. Not cosmetic: it is what makes the sparse
  -- low end of the measured range usable.
  local nodes, problems = curve.parse_nodes({ "185:70" }, { map_x = function(x)
    return math.log10(x + 1)
  end })
  check("map_x transforms the x domain", #problems, 0)
  check("  ...to log10(x+1)", nodes[1].x, math.log10(186))
  check("  ...and leaves y alone", nodes[1].y, 70)
end

-- ── the string_map shape ─────────────────────────────────────────────────────
-- The curves are `string_map` because ListEditor (behind `string_list`) has no
-- edit callback, so a list node can only be changed by deleting and retyping it.
-- These tests pin the map semantics, including the two traps that come with it:
-- a map has no array part (`#value` is 0 at any size), and the host sorts rows by
-- key as *text*, which is why the shipped keys are zero-padded.

do
  -- A map and the equivalent list must produce the same curve, or switching the
  -- setting type would have been a silent behaviour change.
  local from_map, map_problems = curve.parse_nodes({
    ["00001"] = "1:20",
    ["00010"] = "10:30",
    ["00185"] = "185:70",
  })
  local from_list = curve.parse_nodes({ "1:20", "10:30", "185:70" })
  check("a map yields the same node count as the list", #from_map, #from_list)
  check("a clean map reports no problems", #map_problems, 0)
  local same = true
  for i = 1, #from_map do
    if from_map[i].x ~= from_list[i].x or from_map[i].y ~= from_list[i].y then same = false end
  end
  check_true("a map yields the same nodes in the same order as the list", same)
end

do
  -- A map has no integer keys, so `#value` is 0 however many rows it holds. A
  -- guard written as `#value > 0` would therefore throw the whole curve away.
  local map = { ["00185"] = "185:70", ["00100"] = "100:63.4" }
  check("a map has no array part", #map, 0)
  local nodes = curve.parse_nodes(map)
  check("  ...and is still read in full", #nodes, 2)
end

do
  -- The documented shorthand: the value is just the target and the key supplies
  -- the reading. This is what makes a bare "70" in a row usable.
  local nodes, problems = curve.parse_nodes({ ["00185"] = "70" })
  check("a bare target takes x from the key", nodes[1].x, 185)
  check("  ...and y from the value", nodes[1].y, 70)
  check("  ...with no complaint", #problems, 0)
end

do
  -- The value is authoritative. A stale key must not be able to move a node the
  -- owner typed: it may only reorder the row on screen, and it says so once.
  local nodes, problems = curve.parse_nodes({ ["00185"] = "200:70" })
  check("a disagreeing key does not override the value's x", nodes[1].x, 200)
  check("  ...the target is still honoured", nodes[1].y, 70)
  check("  ...and it is reported once", #problems, 1)
  check_true("  ...saying the row is keyed differently", problems[1]:find("keyed") ~= nil)
end

do
  -- A key is an ordering hint, not an input: a non-numeric one is harmless as long
  -- as the value carries the node.
  local nodes, problems = curve.parse_nodes({ ["the bright one"] = "200:70" })
  check("a non-numeric key still yields its node", nodes[1].x, 200)
  check("  ...without a problem", #problems, 0)
  -- ...but with nothing else to go on, a row cannot invent a reading.
  local none, problems2 = curve.parse_nodes({ ["the bright one"] = "70" })
  check("a non-numeric key and a bare target yield nothing", #none, 0)
  check("  ...and are reported", #problems2, 1)
end

do
  -- Row labels follow the order the settings page renders, so a log line points at
  -- the row the owner is looking at.
  local _, problems = curve.parse_nodes({ ["00030"] = "nonsense", ["00010"] = "also bad" })
  check("both bad rows are reported", #problems, 2)
  check_true("the first names the lexicographically first row",
    problems[1]:find("00010", 1, true) ~= nil)
end

do
  -- An empty map and a map of blanks are both "not filled in yet", not errors.
  local empty, p1 = curve.parse_nodes({})
  check("an empty map yields no nodes", #empty, 0)
  check("  ...and no problems", #p1, 0)
  local blank, p2 = curve.parse_nodes({ ["00185"] = "", ["00100"] = "   " })
  check("blank values are skipped", #blank, 0)
  check("  ...without being reported", #p2, 0)
end

do
  -- The property the zero-padding exists for: the host sorts keys as text, so
  -- lexical order must equal numeric order or the curve reads scrambled on screen.
  -- A key that loses its padding breaks this silently and changes no numbers.
  local keys = {}
  for k in pairs(curve.DEFAULT_BRIGHTNESS) do keys[#keys + 1] = k end
  table.sort(keys) -- exactly what makeStringMapBlock does
  local nodes = curve.parse_nodes(curve.DEFAULT_BRIGHTNESS)
  check("the default brightness map has 10 rows", #keys, 10)
  local in_order = true
  for i = 1, #keys do
    if tonumber(keys[i]) ~= nodes[i].x then in_order = false end
  end
  check_true("lexical key order equals numeric curve order (brightness)", in_order)
end

do
  local keys = {}
  for k in pairs(curve.DEFAULT_TEMPERATURE) do keys[#keys + 1] = k end
  table.sort(keys)
  local nodes = curve.parse_nodes(curve.DEFAULT_TEMPERATURE)
  check("the default temperature map has 10 rows", #keys, 10)
  local in_order = true
  for i = 1, #keys do
    if tonumber(keys[i]) ~= nodes[i].x then in_order = false end
  end
  check_true("lexical key order equals numeric curve order (temperature)", in_order)
end

do
  -- The shipped keys must be strings: the manifest rejects a non-string value, but
  -- a numeric-looking key is worth pinning too, because that is what the padding
  -- makes them look like.
  local all_strings = true
  for k, v in pairs(curve.DEFAULT_BRIGHTNESS) do
    if type(k) ~= "string" or type(v) ~= "string" then all_strings = false end
  end
  check_true("every default key and value is a string", all_strings)
end

-- ── compile ──────────────────────────────────────────────────────────────────

do
  local c = curve.compile({})
  check("an empty node list compiles to nil", c, nil)
  check("nil compiles to nil", curve.compile(nil), nil)
end

do
  local c = curve.compile({ { x = 5, y = 42 } })
  check_true("a single node is a constant, not an error", c ~= nil)
  check("  ...and evaluates to its own y below", curve.eval(c, 0), 42)
  check("  ...and above", curve.eval(c, 100), 42)
end

do
  local c = curve.compile({ { x = 1, y = 0 }, { x = 2, y = 10 }, { x = 2, y = 20 } })
  check("a duplicated x cannot produce tangents", c, nil)
  local d = curve.compile({ { x = 2, y = 0 }, { x = 1, y = 10 } })
  check("a descending x cannot produce tangents", d, nil)
end

-- ── interpolation: the properties the whole design rests on ──────────────────

-- Per-interval no-overshoot. This is the real PCHIP guarantee, and the property
-- the whole design rests on: between any two adjacent nodes the curve must not
-- leave the band those two nodes define. The owner drew that segment; going
-- outside it means the panel does something they did not ask for.
--
-- A global check (stay inside [min(all y), max(all y)]) is NOT enough, and this
-- was verified rather than assumed. Against an honest naive-cubic variant
-- (Catmull-Rom tangents, no sign guard) the per-interval sweep finds:
--
--   * the flat/steep set below      -> 5.93 points outside its band, at x=0.667,
--     i.e. between two 10% nodes the naive cubic reaches ~15.9%. The global
--     maximum of that set is 95%, so a global-range test misses this entirely.
--   * the non-monotone set below    -> 0.65 points outside
--   * the shipped default curve     -> 5.13 points outside, at raw ~ 7413, i.e.
--     the naive cubic commands ~105% -- over full brightness.
--
-- PCHIP scores 0.000000 on all three. The node set below is kept because it is
-- the one that slips past a global-range check.
local function worst_interval_excursion(nodes)
  local c = curve.compile(nodes)
  local worst, where = 0, nil
  for i = 1, #nodes - 1 do
    local lo = math.min(nodes[i].y, nodes[i + 1].y)
    local hi = math.max(nodes[i].y, nodes[i + 1].y)
    local steps = 400
    for s = 0, steps do
      local x = nodes[i].x + (nodes[i + 1].x - nodes[i].x) * (s / steps)
      local y = curve.eval(c, x)
      local excess = math.max(lo - y, y - hi)
      if excess > worst then worst, where = excess, x end
    end
  end
  return worst, where
end

do
  local nodes = curve.parse_nodes(curve.DEFAULT_BRIGHTNESS)
  local worst, where = worst_interval_excursion(nodes)
  check_true("the default curve never leaves the band between two adjacent nodes"
    .. " (worst " .. string.format("%.3e", worst) .. " at x=" .. tostring(where) .. ")",
    worst < 1e-9)
end

do
  -- The same property in the log domain the service actually evaluates in, since
  -- a transform that is not exactly monotone could in principle break it.
  local nodes = curve.parse_nodes(curve.DEFAULT_BRIGHTNESS, { map_x = function(x)
    return math.log10(x + 1)
  end })
  local worst, where = worst_interval_excursion(nodes)
  check_true("  ...and in the log10 domain the service uses"
    .. " (worst " .. string.format("%.3e", worst) .. " at x=" .. tostring(where) .. ")",
    worst < 1e-9)
end

do
  -- Flat runs next to steep climbs are where a naive cubic overshoots worst.
  local nodes = curve.parse_nodes({ "0:10", "1:10", "2:90", "3:90", "4:95" })
  local worst, where = worst_interval_excursion(nodes)
  check_true("flat runs beside steep climbs still cannot overshoot"
    .. " (worst " .. string.format("%.3e", worst) .. " at x=" .. tostring(where) .. ")",
    worst < 1e-9)
end

do
  -- A deliberately non-monotone set: an interior extremum must pin to the node
  -- value rather than bulging past it.
  local nodes = curve.parse_nodes({ "0:50", "1:80", "2:20", "3:60" })
  local worst, where = worst_interval_excursion(nodes)
  check_true("a non-monotone node set is honoured without bulging past any node"
    .. " (worst " .. string.format("%.3e", worst) .. " at x=" .. tostring(where) .. ")",
    worst < 1e-9)
end

do
  -- C1 continuity at the nodes. A piecewise-linear curve fails this, so the test
  -- distinguishes the chosen interpolation from the one it replaced.
  local nodes = curve.parse_nodes({ "1:20.8", "10:39.3", "185:70", "2200:96.8" })
  local c = curve.compile(nodes)
  local d = 1e-6
  local worst = 0
  for i = 2, #nodes - 1 do
    local x = nodes[i].x
    local left = (curve.eval(c, x) - curve.eval(c, x - d)) / d
    local right = (curve.eval(c, x + d) - curve.eval(c, x)) / d
    local scale = math.max(1, math.abs(left), math.abs(right))
    worst = math.max(worst, math.abs(left - right) / scale)
  end
  check_true("the derivative is continuous at every interior node (worst "
    .. string.format("%.2e", worst) .. ")", worst < 1e-3)
end

do
  -- A straight-line node set must reproduce the straight line exactly: the curve
  -- must not introduce error where the owner's data is already linear.
  local c = curve.compile({ { x = 0, y = 0 }, { x = 1, y = 10 }, { x = 2, y = 20 } })
  check("a straight line is reproduced at the first node", curve.eval(c, 0), 0)
  check("  ...at the middle node", curve.eval(c, 1), 10)
  check("  ...at the last node", curve.eval(c, 2), 20)
  check("  ...and midway between nodes", curve.eval(c, 0.5), 5)
  check("  ...and at three quarters", curve.eval(c, 1.75), 17.5)
end

do
  -- Passing through the nodes exactly is what makes the GUI honest: the number the
  -- owner types is the number the curve hits.
  local nodes = curve.parse_nodes(curve.DEFAULT_BRIGHTNESS)
  local c = curve.compile(nodes)
  local worst = 0
  for _, node in ipairs(nodes) do
    worst = math.max(worst, math.abs(curve.eval(c, node.x) - node.y))
  end
  check_true("the curve passes exactly through every configured node", worst < 1e-9)
end

do
  local nodes = curve.parse_nodes({ "1:20", "10:40" })
  local c = curve.compile(nodes)
  check("below the range the first value holds", curve.eval(c, -50), 20)
  check("above the range the last value holds", curve.eval(c, 5000), 40)
  check("exactly at the first node", curve.eval(c, 1), 20)
  check("exactly at the last node", curve.eval(c, 10), 40)
  check("NaN input yields nil rather than a garbage number", curve.eval(c, 0 / 0), nil)
  check("nil input yields nil", curve.eval(c, nil), nil)
  check("nil curve yields nil", curve.eval(nil, 5), nil)
end

-- ── monotonicity reporting ───────────────────────────────────────────────────

do
  check_true("an ascending node set is monotone",
    curve.is_monotone(curve.parse_nodes({ "1:20", "10:30", "100:40" })))
  check_true("a flat node set is monotone",
    curve.is_monotone(curve.parse_nodes({ "1:20", "10:20" })))
  check_true("a falling node set is reported as non-monotone",
    curve.is_monotone(curve.parse_nodes({ "1:20", "10:10" })) == false)
  check_true("nil is treated as monotone", curve.is_monotone(nil))
end

-- ── the shipped defaults ─────────────────────────────────────────────────────

do
  local nodes, problems = curve.parse_nodes(curve.DEFAULT_BRIGHTNESS)
  check("the default brightness list is 10 nodes", #nodes, 10)
  check("the default brightness list parses without problems", #problems, 0)
  check_true("  ...and is monotone", curve.is_monotone(nodes))
  local by_x = {}
  for _, node in ipairs(nodes) do by_x[node.x] = node.y end
  -- the one datum this machine actually measured: room at 185 raw, panel at 70%
  check("the default curve hits the owner's measured 185 -> 70", by_x[185], 70)
  check("  ...20.8 at 1 raw", by_x[1], 20.8)
  check("  ...30.7 at 4 raw", by_x[4], 30.7)
  check("  ...39.3 at 10 raw", by_x[10], 39.3)
  check("  ...50.6 at 30 raw", by_x[30], 50.6)
  check("  ...63.4 at 100 raw", by_x[100], 63.4)
  check("  ...78.3 at 400 raw", by_x[400], 78.3)
  check("  ...88.3 at 1000 raw", by_x[1000], 88.3)
  check("  ...96.8 at 2200 raw", by_x[2200], 96.8)
  check("  ...100 at 16384 raw", by_x[16384], 100)
end

do
  local nodes, problems = curve.parse_nodes(curve.DEFAULT_TEMPERATURE)
  check("the default temperature list is 10 nodes", #nodes, 10)
  check("the default temperature list parses without problems", #problems, 0)
  check_true("  ...and is monotone", curve.is_monotone(nodes))
  -- compiled exactly as the service compiles it: ten visible rows + four anchors
  local c = curve.compile(curve.with_anchors(nodes))
  -- the floor: the hidden anchors hold 5100 K below row 1 with a zero tangent
  check("a 2000 K room gives 5100 K", math.floor(curve.eval(c, 2000)), 5100)
  check("a warm 2500 K room gives 5100 K", math.floor(curve.eval(c, 2500)), 5100)
  check_true("  ...and eases out of it (2510 K stays under 5101 K)",
    curve.eval(c, 2510) < 5101)
  -- the unique ladder: every shipped row survives exactly
  check("3000 K ambient gives 5380 K", math.floor(curve.eval(c, 3000) + 0.5), 5380)
  check("4000 K ambient gives 5660 K", math.floor(curve.eval(c, 4000) + 0.5), 5660)
  check("5000 K ambient gives 5940 K", math.floor(curve.eval(c, 5000) + 0.5), 5940)
  check("6000 K ambient gives 6220 K", math.floor(curve.eval(c, 6000) + 0.5), 6220)
  -- the ceiling: the anchors carry 6500 K past row 10
  check("a 6500 K ambient gives 6500 K", math.floor(curve.eval(c, 6500) + 0.5), 6500)
  check("a 7500 K ambient still gives 6500 K", math.floor(curve.eval(c, 7500) + 0.5), 6500)
end

do
  -- The four hidden anchors: never shown, always compiled (14 under the hood,
  -- 10 visible rows).
  local vis = curve.parse_nodes(curve.DEFAULT_TEMPERATURE)
  local all = curve.with_anchors(vis)
  check("four hidden nodes are added", #all, 14)
  check("the visible list is untouched", #vis, 10)
  check("floor anchor sits at x1-500", all[1].x, 2000)
  check("second floor anchor at x1-300", all[2].x, 2200)
  check("both replicate row 1's output", all[1].y, 5100)
  check("  ...the second too", all[2].y, 5100)
  check("row 1 stays put", all[3].x, 2500)
  check("row 10 stays put", all[12].x, 6500)
  check("ceiling anchor at x10+500", all[13].x, 7000)
  check("last anchor at x10+1000", all[14].x, 7500)
  check("ceiling anchors replicate row 10", all[13].y, 6500)
  check("  ...both", all[14].y, 6500)
  local increasing = true
  for i = 2, #all do
    if all[i].x <= all[i - 1].x then increasing = false end
  end
  check_true("the 14 nodes are strictly increasing", increasing)
  check_true("...so the compiled curve exists", curve.compile(all) ~= nil)
  -- a custom map replicates ITS endpoints, whatever they are
  local ca = curve.with_anchors({ { x = 10, y = 5 }, { x = 20, y = 9 } })
  check("custom shapes get four anchors too", #ca, 6)
  check("its floor is replicated", ca[1].y, 5)
  check("its ceiling is replicated", ca[6].y, 9)
  -- degenerate input passes through
  check("an empty list passes through", #curve.with_anchors({}), 0)
end

do
  -- The brightness default must reproduce the formula it replaced
  --     pct = 70 + 25 * (log10(raw + 1) - log10(186))
  -- within a fraction of a percent, or an upgrade would visibly shift the panel.
  local nodes = curve.parse_nodes(curve.DEFAULT_BRIGHTNESS, { map_x = function(x)
    return math.log10(x + 1)
  end })
  local c = curve.compile(nodes)
  local ref = math.log10(186)
  local worst, worst_raw = 0, nil
  for _, raw in ipairs({ 4, 10, 30, 60, 100, 140, 185, 260, 400, 700, 1000, 1500 }) do
    local want = math.min(100, math.max(15, 70 + 25 * (math.log10(raw + 1) - ref)))
    local got = curve.eval(c, math.log10(raw + 1))
    local diff = math.abs(got - want)
    if diff > worst then worst, worst_raw = diff, raw end
  end
  check_true("the default curve tracks the old formula to within 1.5 points"
    .. " (worst " .. string.format("%.3f", worst) .. " at raw=" .. tostring(worst_raw) .. ")",
    worst < 1.5)
end
-- ── buildNodes: the threshold sliders ────────────────────────────────────────

local function fmt_map(nodes)
  local map = {}
  for _, node in ipairs(nodes) do
    map[string.format("%05d", node.x)] = string.format("%g:%g", node.x, node.y)
  end
  return map
end

local function maps_equal(a, b)
  for k, v in pairs(a) do
    if b[k] ~= v then return false end
  end
  for k in pairs(b) do
    if a[k] == nil then return false end
  end
  return true
end

do
  -- The regression guard for the whole phase: the shipped slider defaults must
  -- rebuild the shipped maps exactly -- keys and values both. If this fails, a
  -- fresh install would not behave like the curve it replaced.
  local br_nodes, br_problems =
    curve.buildNodes(curve.DEFAULT_BRIGHTNESS_X, curve.FIXED_BRIGHTNESS_Y)
  check("default brightness sliders build 10 nodes", #br_nodes, 10)
  check("default brightness sliders build without problems", #br_problems, 0)
  check_true("default brightness sliders rebuild the shipped map exactly",
    maps_equal(fmt_map(br_nodes), curve.DEFAULT_BRIGHTNESS))

  local tp_nodes, tp_problems =
    curve.buildNodes(curve.DEFAULT_TEMPERATURE_X, curve.FIXED_TEMPERATURE_Y)
  check("default temperature sliders build 10 nodes", #tp_nodes, 10)
  check("default temperature sliders build without problems", #tp_problems, 0)
  check_true("default temperature sliders rebuild the shipped map exactly",
    maps_equal(fmt_map(tp_nodes), curve.DEFAULT_TEMPERATURE))
end

do
  -- The outputs travel with their slider: sliding node 1 past node 2 swaps two
  -- steps of the curve, and never reassigns an output to the wrong threshold.
  local nodes = curve.buildNodes({ 185, 4 }, { 70, 30.7 })
  check("crossed sliders are re-sorted", #nodes, 2)
  check("  ...lower threshold first", nodes[1].x, 4)
  check("  ...output travels with its slider", nodes[1].y, 30.7)
  check("  ...and the other node follows", nodes[2].y, 70)
end

do
  -- Two sliders at the same position cannot both stay there: the second is
  -- spaced one unit up, and it is reported rather than silently moved.
  local nodes, problems = curve.buildNodes({ 10, 10, 10 }, { 20.8, 30.7, 39.3 })
  check("colliding thresholds are repaired to strictly increasing", #nodes, 3)
  check("  ...one unit apart", nodes[1].x + 1, nodes[2].x)
  check("  ...and the next one too", nodes[2].x + 1, nodes[3].x)
  check("a collision is reported once", #problems, 1)
  check_true("  ...as a collision", problems[1]:find("collided") ~= nil)
  check_true("the repaired curve still compiles", curve.compile(nodes) ~= nil)
end

do
  -- A slider left on a non-number (a hand-edited settings.toml) costs one node,
  -- exactly like a malformed map row -- never the service.
  local nodes, problems = curve.buildNodes({ 10, "nonsense", 400 }, { 20.8, 30.7, 78.3 })
  check("an unusable threshold drops its node", #nodes, 2)
  check("  ...and reports it", #problems, 1)
  check_true("the problem names the node", problems[1]:find("node 2") ~= nil)
  check("the surviving outputs are the right ones", nodes[1].y, 20.8)
end

do
  local nodes, problems = curve.buildNodes({ 10, 400 }, { 20.8, 30.7, 78.3 })
  check("mismatched lengths use the common prefix", #nodes, 2)
  check("mismatched lengths are reported", #problems, 1)
  local _, problems2 = curve.buildNodes(42, curve.FIXED_BRIGHTNESS_Y)
  check("a non-list is reported", #problems2, 1)
end

do
  -- map_x runs after the sort and repair, exactly like parse_nodes.
  local nodes, problems = curve.buildNodes({ 1, 185 }, { 20.8, 70 },
    { map_x = function(x) return math.log10(x + 1) end })
  check("map_x is applied", #problems, 0)
  check("  ...to the first node", nodes[1].x, math.log10(2))
  check("  ...and the second", nodes[2].x, math.log10(186))

  local dropped, problems3 = curve.buildNodes({ -5, 185 }, { 20.8, 70 },
    { map_x = function(x) return math.log10(x + 1) end })
  check("an x map_x cannot map drops the node", #dropped, 1)
  check("  ...and reports it", #problems3, 1)
end

do
  -- The slider windows, in one place: manifest literals and learning bounds both
  -- come from here (run-tests.sh diffs the manifest against this function).
  local lo, hi, step = curve.threshold_window("brightness", 1)
  check("brightness node 1 window min", lo, 0)
  check("brightness node 1 window max", hi, 3)
  check("brightness node 1 window step", step, 1)
  lo, hi, step = curve.threshold_window("brightness", 10)
  check("the top brightness node is capped at the sensor ceiling", hi, 16384)
  check("  ...and floors at a third of its default", lo, 5461)
  lo, hi, step = curve.threshold_window("temperature", 1)
  check("temperature node 1 window min", lo, 2000)
  check("temperature node 1 window max", hi, 3000)
  check("temperature node 1 window step", step, 50)
  lo, hi, step = curve.threshold_window("temperature", 10)
  check("temperature node 10 window min", lo, 6000)
  check("temperature node 10 window max", hi, 7000)
  check("an unknown kind has no window", curve.threshold_window("nonsense", 1), nil)
  check("an unknown index has no window", curve.threshold_window("brightness", 11), nil)
end

do
  -- Which side wins at reload is decision logic, so it lives here and not in the
  -- service. A map is "custom" only when its *parsed nodes* differ from the
  -- shipped defaults -- re-ordering rows or retyping whitespace is not an edit,
  -- and a map with nothing parseable in it is not an edit either (the sliders
  -- take over).
  local function copy_map(src)
    local out = {}
    for k, v in pairs(src) do out[k] = v end
    return out
  end

  local fresh = copy_map(curve.DEFAULT_BRIGHTNESS)
  check("the untouched default map is not custom",
    curve.map_is_custom(fresh, curve.DEFAULT_BRIGHTNESS), false)

  -- the same nodes as a re-ordered, re-whitespaced list: not an edit
  local reformatted = {}
  for _, v in pairs(curve.DEFAULT_BRIGHTNESS) do
    table.insert(reformatted, "  " .. v .. "  ")
  end
  check("a re-formatted equivalent list is not custom",
    curve.map_is_custom(reformatted, curve.DEFAULT_BRIGHTNESS), false)

  local edited_y = copy_map(curve.DEFAULT_BRIGHTNESS)
  edited_y["00001"] = "1:25"
  check("an edited output is custom",
    curve.map_is_custom(edited_y, curve.DEFAULT_BRIGHTNESS), true)

  local edited_x = copy_map(curve.DEFAULT_BRIGHTNESS)
  edited_x["00001"] = "2:20.8"
  check("an edited threshold is custom",
    curve.map_is_custom(edited_x, curve.DEFAULT_BRIGHTNESS), true)

  local extra = copy_map(curve.DEFAULT_BRIGHTNESS)
  extra["00200"] = "200:75"
  check("an extra node is custom",
    curve.map_is_custom(extra, curve.DEFAULT_BRIGHTNESS), true)

  local dropped = copy_map(curve.DEFAULT_BRIGHTNESS)
  dropped["00001"] = nil
  check("a dropped node is custom",
    curve.map_is_custom(dropped, curve.DEFAULT_BRIGHTNESS), true)

  check("garbage-only rows are not an edit",
    curve.map_is_custom({ "nonsense", "" }, curve.DEFAULT_BRIGHTNESS), false)
  check("an empty map is not an edit",
    curve.map_is_custom({}, curve.DEFAULT_BRIGHTNESS), false)
  check("nil items are not an edit",
    curve.map_is_custom(nil, curve.DEFAULT_BRIGHTNESS), false)
end

print(string.format("\n%d checks, %d failure(s)", checks, failures))
if failures > 0 then
  error(string.format("%d check(s) failed", failures), 0)
end
