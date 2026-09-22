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

-- ── median ───────────────────────────────────────────────────────────────────

check("median of an odd count", profile.median({ 3, 1, 2 }), 2)
check("median of an even count averages the middle pair", profile.median({ 4, 1, 3, 2 }), 2.5)
check("median of one value", profile.median({ 7 }), 7)
check("median of nothing is nil", profile.median({}), nil)
check("median does not reorder the caller's table", (function()
  local t = { 3, 1, 2 }
  profile.median(t)
  return t[1]
end)(), 3)

-- The reason median was chosen over mean: this sensor moves +/-10000 counts in one
-- 50 ms sample, so one shadowed sample must not drag a band's learned value.
do
  local noisy = { 70, 70.5, 69.5, 70, 9999 }
  local sum = 0
  for _, v in ipairs(noisy) do sum = sum + v end
  check("median shrugs off one wild sample", profile.median(noisy), 70)
  check_true("  ...where the mean would not (" .. string.format("%.1f", sum / #noisy) .. ")",
    math.abs(sum / #noisy - 70) > 1000)
end

-- ── band_of ──────────────────────────────────────────────────────────────────

do
  local xs = { 0, 1, 2, 3 } -- boundaries at 0.5, 1.5, 2.5
  check("below the first centre is band 1", profile.band_of(xs, 0), 1)
  check("just below the first boundary is band 1", profile.band_of(xs, 0.499), 1)
  check("the midpoint belongs to the upper band", profile.band_of(xs, 0.5), 2)
  check("mid band", profile.band_of(xs, 1.4), 2)
  check("the second midpoint belongs to band 3", profile.band_of(xs, 1.5), 3)
  check("the last midpoint belongs to the last band", profile.band_of(xs, 2.5), 4)
  check("far above the range is the last band", profile.band_of(xs, 99999), 4)
  check("far below the range is the first band", profile.band_of(xs, -99999), 1)
  check("a single centre is always band 1", profile.band_of({ 5 }, 12345), 1)
  check("no centres means no band", profile.band_of({}, 1), nil)
  check("NaN has no band", profile.band_of(xs, 0 / 0), nil)
  check("nil has no band", profile.band_of(xs, nil), nil)
end

-- ── add: the rolling window ──────────────────────────────────────────────────

do
  local p = profile.new()
  check("a new profile is empty", #p.observations, 0)
  profile.add(p, { x = 1, y = 70, raw = 185, at = 10 })
  check("an observation is recorded", #p.observations, 1)
  check("  ...with its curve-domain x", p.observations[1].x, 1)
  check("  ...its value", p.observations[1].y, 70)
  check("  ...and its raw counts kept for diagnostics", p.observations[1].raw, 185)
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

-- ── fit ──────────────────────────────────────────────────────────────────────

do
  local xs = { 0, 1, 2, 3 }
  local fallback = { 10, 20, 30, 40 }

  local ys, counts = profile.fit(profile.new(), xs, fallback)
  check("an empty profile fits to the authored values (1)", ys[1], 10)
  check("  ...(2)", ys[2], 20)
  check("  ...(3)", ys[3], 30)
  check("  ...(4)", ys[4], 40)
  check("  ...and reports no observations", counts[1] + counts[2] + counts[3] + counts[4], 0)
end

do
  -- Below the floor a band must NOT be learned: one shadowed sample is not a
  -- preference, it is noise.
  local xs = { 0, 1, 2, 3 }
  local fallback = { 10, 20, 30, 40 }
  local p = profile.new()
  profile.add(p, { x = 1.1, y = 99 })
  local ys, counts = profile.fit(p, xs, fallback)
  check("one observation is not enough to learn a band", ys[2], 20)
  check("  ...and the count still reports it", counts[2], 1)
end

do
  local xs = { 0, 1, 2, 3 }
  local fallback = { 10, 20, 30, 40 }
  local p = profile.new()
  profile.add(p, { x = 1.1, y = 99 })
  profile.add(p, { x = 1.2, y = 101 })
  local ys, counts = profile.fit(p, xs, fallback)
  check("two observations do learn a band", ys[2], 100)
  check("  ...and the other bands stay authored", ys[1], 10)
  check("  ...(3)", ys[3], 30)
  check("  ...(4)", ys[4], 40)
  check("the learned band is counted", counts[2], 2)
end

do
  -- The demonstration that matters: several observations in the band the owner
  -- actually sits in, plus one outlier, must produce the owner's value.
  local xs = { 0, 1, 2, 3 }
  local fallback = { 10, 20, 30, 40 }
  local p = profile.new()
  for _, y in ipairs({ 70, 70.5, 69.5, 70, 9999 }) do
    profile.add(p, { x = 1.05, y = y })
  end
  local ys = profile.fit(p, xs, fallback)
  check("a band fits the median, not the mean", ys[2], 70)
end

do
  local xs = { 0, 1, 2, 3 }
  local fallback = { 10, 20, 30, 40 }
  local p = profile.new()
  -- two observations squarely inside each band, so every band clears the floor
  for band = 1, 4 do
    local x = band - 1 -- 0, 1, 2, 3 sit inside bands 1..4 (boundaries are 0.5/1.5/2.5)
    profile.add(p, { x = x, y = band * 11 })
    profile.add(p, { x = x, y = band * 11 })
  end
  local ys, counts = profile.fit(p, xs, fallback)
  check("a fully learned profile overrides every band (1)", ys[1], 11)
  check("  ...(2)", ys[2], 22)
  check("  ...(3)", ys[3], 33)
  check("  ...(4)", ys[4], 44)
  check("every band reports its count", counts[4], 2)
  check("  ...and learned_bands agrees", profile.learned_bands(p, xs), 4)
end

do
  -- Out-of-domain observations land in the end bands, consistent with the curves
  -- holding their end values flat.
  local xs = { 0, 1, 2, 3 }
  local fallback = { 10, 20, 30, 40 }
  local p = profile.new()
  profile.add(p, { x = -500, y = 5 })
  profile.add(p, { x = -400, y = 10 })
  profile.add(p, { x = 900, y = 90 })
  profile.add(p, { x = 1000, y = 95 })
  local ys = profile.fit(p, xs, fallback)
  check("far-below observations fall into the first band", ys[1], 7.5)
  check("far-above observations fall into the last band", ys[4], 92.5)
end

do
  local ys, counts = profile.fit(profile.new(), {}, {})
  check("fitting no bands is not an error", #ys, 0)
  check("  ...and counts nothing", #counts, 0)
end

-- ── learned_bands ────────────────────────────────────────────────────────────

do
  local xs = { 0, 1, 2, 3 }
  local p = profile.new()
  check("an empty profile has no learned bands", profile.learned_bands(p, xs), 0)
  profile.add(p, { x = 1.1, y = 1 })
  check("one observation is not a learned band", profile.learned_bands(p, xs), 0)
  profile.add(p, { x = 1.2, y = 2 })
  check("two observations make one learned band", profile.learned_bands(p, xs), 1)
  profile.add(p, { x = 2.1, y = 3 })
  profile.add(p, { x = 2.2, y = 4 })
  check("two bands learned", profile.learned_bands(p, xs), 2)
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
  local p = profile.sanitise({ observations = { { x = 1.1, y = 90 }, { x = 1.2, y = 90 } } })
  local ys = profile.fit(p, { 0, 1, 2 }, { 10, 20, 30 })
  check("a sanitised profile fits", ys[2], 90)
end

print(string.format("\n%d checks, %d failure(s)", checks, failures))
if failures > 0 then
  error(string.format("%d check(s) failed", failures), 0)
end
