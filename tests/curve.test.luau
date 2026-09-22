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
  local c = curve.compile(nodes)
  -- faithful to the pre-Phase-2 mapping: flat 5100 below 3000 K ambient
  check("a warm 2500 K room gives 5100 K", math.floor(curve.eval(c, 2500)), 5100)
  check("3000 K ambient gives 5100 K", math.floor(curve.eval(c, 3000)), 5100)
  -- ...then linear, so the existing midpoints must survive the change
  check("4000 K ambient gives ~5660 K", math.floor(curve.eval(c, 4000) + 0.5), 5660)
  check("5000 K ambient gives ~6220 K", math.floor(curve.eval(c, 5000) + 0.5), 6220)
  -- ...and flat at the ceiling above 5500
  check("5500 K ambient gives 6500 K", math.floor(curve.eval(c, 5500) + 0.5), 6500)
  check("a 6500 K ambient still gives 6500 K", math.floor(curve.eval(c, 6500) + 0.5), 6500)
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

print(string.format("\n%d checks, %d failure(s)", checks, failures))
if failures > 0 then
  error(string.format("%d check(s) failed", failures), 0)
end
