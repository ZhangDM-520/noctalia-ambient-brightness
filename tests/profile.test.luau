--!nonstrict
-- Pure-function tests for src/profile.luau.  Run from the repo root:
--     luau tests/profile.test.luau
-- No host API, no hardware, no clock, no file IO.

-- The host resolves requires *with* the extension, the standalone interpreter
-- resolves them *without*; both point at the same file. Same as the other suites.
local profile = require("../als-brightness/profile")

local failures = 0
local checks = 0

local function check(label, got, want)
  checks = checks + 1
  local ok
  if type(want) == "number" and type(got) == "number" then
    ok = math.abs(got - want) < 1e-9
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

-- ── target_node ──────────────────────────────────────────────────────────────

do
  local ys = { 20, 45, 45, 70 }
  check("a change targets the node whose fixed output is nearest", profile.target_node(ys, 44), 2)
  check("  ...below the range is the first node", profile.target_node(ys, -3), 1)
  check("  ...above the range is the last node", profile.target_node(ys, 999), 4)
  check("an exact match targets exactly", profile.target_node(ys, 70), 4)
  -- Ties go to the lower node: when neighbours share an output (the three 5100 K
  -- temperature nodes, or two nodes the owner slid close together) the
  -- conservative pick is the earlier one.
  check("a tie goes to the lower node", profile.target_node({ 10, 30 }, 20), 1)
  check("equal outputs tie to the lower node", profile.target_node(ys, 45), 2)
  check("a single node always wins", profile.target_node({ 5 }, 12345), 1)
  check("no nodes means no target", profile.target_node({}, 1), nil)
  check("a non-finite value has no target", profile.target_node(ys, 0 / 0), nil)
  check("a non-table has no target", profile.target_node(nil, 1), nil)
end

-- ── fit_thresholds: learning nudges thresholds, never outputs ─────────────────

do
  local ys = { 20, 45, 70 }
  local seeds = { 100, 200, 300 }
  local xs, counts = profile.fit_thresholds(profile.new(), ys, seeds)
  check("an empty profile keeps the slider positions (1)", xs[1], 100)
  check("  ...(2)", xs[2], 200)
  check("  ...(3)", xs[3], 300)
  check("  ...and reports no observations", counts[1] + counts[2] + counts[3], 0)
end

do
  local ys = { 20, 45, 70 }
  local seeds = { 100, 200, 300 }
  local p = profile.new()
  profile.add(p, { x = 2.3, y = 46, raw = 250 })
  local xs, counts = profile.fit_thresholds(p, ys, seeds)
  check("one observation is not enough to move a node", xs[2], 200)
  check("  ...but it is counted", counts[2], 1)
end

-- ── add: the rolling window ──────────────────────────────────────────────────

do
  local p = profile.new()
  check("a new profile is empty", #p.observations, 0)
  profile.add(p, { x = 1, y = 70, raw = 185, at = 10 })
  check("an observation is recorded", #p.observations, 1)
  check("  ...with its curve-domain x", p.observations[1].x, 1)
  check("  ...its value", p.observations[1].y, 70)
  check("  ...and the ambient its threshold will drift toward", p.observations[1].raw, 185)
end

do
  -- Bounded so a machine left running for months cannot grow the file forever,
  -- and newest-kept because the curve should track the owner, not average their
  -- entire history.
  local p = profile.new()
  for i = 1, 10 do profile.add(p, { x = i, y = i * 2 }, { max_observations = 4 }) end
  check("the window is capped", #p.observations, 4)
  check("the oldest observations are dropped", p.observations[1].y, 14)
  check("the newest is kept", p.observations[4].y, 20)
end

do
  local p = profile.new()
  profile.add(p, { x = 0 / 0, y = 70 })
  profile.add(p, { x = 1, y = 0 / 0 })
  profile.add(p, { x = 1, y = math.huge })
  profile.add(p, { x = nil, y = 70 })
  profile.add(p, nil)
  check("non-finite and missing observations are refused", #p.observations, 0)
  check("refusing an observation is not an error", profile.add(nil, { x = 1, y = 1 }), nil)
end

do
  -- Two observations clear the floor. The EMA is seeded at the slider value, so
  -- "learned" always means "nudged from where the owner slid it": 200 -> 207.5
  -- -> 213.875, drifting toward the observed ambient of 250.
  local ys = { 20, 45, 70 }
  local seeds = { 100, 200, 300 }
  local p = profile.new()
  profile.add(p, { x = 2.3, y = 46, raw = 250 })
  profile.add(p, { x = 2.3, y = 44, raw = 250 })
  local xs, counts = profile.fit_thresholds(p, ys, seeds)
  check("two observations nudge the targeted node's threshold", xs[2], 213.875)
  check("  ...and leave the other nodes at their seeds (1)", xs[1], 100)
  check("  ...(3)", xs[3], 300)
  check("the nudged node reports its count", counts[2], 2)
end

do
  -- `raw` is the ambient in the slider domain; obs.x is a different domain
  -- (log10 for brightness), so an observation without raw cannot say where the
  -- node should sit -- it is skipped rather than guessed at.
  local ys = { 20, 45, 70 }
  local seeds = { 100, 200, 300 }
  local p = profile.new()
  profile.add(p, { x = 1.2, y = 45 })
  profile.add(p, { x = 1.3, y = 45 })
  local xs, counts = profile.fit_thresholds(p, ys, seeds)
  check("observations without raw counts cannot teach a threshold", xs[2], 200)
  check("  ...and are not counted", counts[2], 0)
end

do
  -- Each manual change lands on the node whose output the owner chose, and
  -- nodes drift independently: 100 -> 97 -> 94.45 and 300 -> 307.5 -> 313.875.
  local ys = { 20, 45, 70 }
  local seeds = { 100, 200, 300 }
  local p = profile.new()
  profile.add(p, { x = 1, y = 21, raw = 80 })
  profile.add(p, { x = 1, y = 19, raw = 80 })
  profile.add(p, { x = 3, y = 68, raw = 350 })
  profile.add(p, { x = 3, y = 72, raw = 350 })
  local xs, counts = profile.fit_thresholds(p, ys, seeds)
  check("nodes drift independently (1)", xs[1], 94.45)
  check("  ...(2)", xs[2], 200)
  check("  ...(3)", xs[3], 313.875)
  check("learned_nodes counts exactly the nodes that cleared the floor",
    profile.learned_nodes(counts), 2)
end

do
  -- A learned threshold is clamped into the slider's window
  -- (curve.threshold_window) so it can always be copied back into the GUI
  -- without being clipped by the slider's own min/max.
  local ys = { 20, 45, 70 }
  local seeds = { 100, 200, 300 }
  local p = profile.new()
  profile.add(p, { x = 3, y = 45, raw = 10000 })
  profile.add(p, { x = 3, y = 45, raw = 10000 })
  local xs_hi = profile.fit_thresholds(p, ys, seeds, { hi = { 120, 220, 320 } })
  check("a learned threshold is clamped to the window's ceiling", xs_hi[2], 220)
  local xs_lo = profile.fit_thresholds(p, ys, seeds, { lo = { 3000, 4000, 5000 } })
  check("  ...and to its floor", xs_lo[2], 4000)
end

do
  local ys = { 20, 45, 70 }
  local seeds = { 100, 200, 300 }
  local p = profile.new()
  profile.add(p, { x = 3, y = 45, raw = 250 })
  local xs = profile.fit_thresholds(p, ys, seeds, { min_observations = 1 })
  check("the observation floor is configurable", xs[2], 207.5)
  xs = profile.fit_thresholds(p, ys, seeds, { min_observations = 1, learn_alpha = 1 })
  check("so is the EMA weight", xs[2], 250)
end

do
  -- Without a seed the node has nowhere to drift from, so it stays unset rather
  -- than being invented.
  local p = profile.new()
  profile.add(p, { x = 1, y = 45, raw = 250 })
  profile.add(p, { x = 1, y = 45, raw = 250 })
  local xs, counts = profile.fit_thresholds(p, { 20, 45, 70 }, nil)
  check("an unseeded node is never invented", xs[2], nil)
  check("  ...and is not counted", counts[2], 0)
end

do
  local xs, counts = profile.fit_thresholds(profile.new(), {}, {})
  check("fitting no nodes is not an error", #xs, 0)
  check("  ...and counts nothing", #counts, 0)
end

-- ── learned_nodes ────────────────────────────────────────────────────────────

do
  check("an empty profile speaks for no nodes", profile.learned_nodes({}), 0)
  check("counts below the floor do not count", profile.learned_nodes({ 1, 0, 1, 1 }), 0)
  check("counts at the floor do", profile.learned_nodes({ 2, 1, 0, 5 }), 2)
  check("the floor is configurable",
    profile.learned_nodes({ 1, 1, 0, 1 }, { min_observations = 1 }), 3)
  check_true("missing counts are not an error", profile.learned_nodes(nil) == 0)
end

-- ── sanitise: profile.json is a file the owner can corrupt ───────────────────

do
  local clean = profile.sanitise(nil)
  check("nil sanitises to an empty profile", #clean.observations, 0)
  check("a string sanitises to an empty profile", #profile.sanitise("garbage").observations, 0)
  check("a number sanitises to an empty profile", #profile.sanitise(42).observations, 0)
  check("an array sanitises to an empty profile", #profile.sanitise({ 1, 2, 3 }).observations, 0)
end

do
  local clean = profile.sanitise({
    version = 1,
    updated_at = 1790045000,
    observations = {
      { x = 1, y = 70, raw = 185, at = 5 }, -- good
      { x = "nonsense", y = 70 }, -- bad x
      { x = 1 }, -- missing y
      "not a table", -- bad shape
      { x = 0 / 0, y = 1 }, -- NaN x
      { x = 2, y = 80 }, -- good, no raw/at
    },
    nodes = { { x = 1, y = 70 }, { x = "bad", y = 1 } },
  })
  check("only well-formed observations survive", #clean.observations, 2)
  check("  ...the first is intact", clean.observations[1].raw, 185)
  check("  ...the second lost its absent raw rather than inventing one",
    clean.observations[2].raw, nil)
  check("a finite version is kept", clean.version, 1)
  check("a finite timestamp is kept", clean.updated_at, 1790045000)
  check("only well-formed nodes survive", #clean.nodes, 1)
end

do
  local clean = profile.sanitise({ version = "one", updated_at = 0 / 0 })
  check("a non-numeric version falls back to the default", clean.version, 1)
  check("a NaN timestamp is dropped", clean.updated_at, nil)
end

do
  -- Regression, found by this suite. A bare string used to satisfy the finiteness
  -- check, because `"185" ~= math.huge` is true in Lua, so a corrupt profile.json
  -- carrying a string coordinate was trusted. The check is now type-aware.
  local clean = profile.sanitise({
    observations = { { x = "185", y = 70 }, { x = 1, y = "70" } },
  })
  check("a string coordinate is rejected, not trusted", #clean.observations, 0)
end

do
  -- A sanitised profile must be immediately usable by fit(), which is the point.
  local p = profile.sanitise({ observations = {
    { x = 1.1, y = 45, raw = 250 },
    { x = 1.2, y = 45, raw = 250 },
  } })
  local xs = profile.fit_thresholds(p, { 20, 45, 70 }, { 100, 200, 300 })
  check("a sanitised profile fits", xs[2], 213.875)
end

print(string.format("\n%d checks, %d failure(s)", checks, failures))
if failures > 0 then
  error(string.format("%d check(s) failed", failures), 0)
end
