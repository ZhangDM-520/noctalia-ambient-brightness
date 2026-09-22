--!nonstrict
-- Pure-function tests for src/policy.luau.  Run from the repo root:
--     luau tests/policy.test.luau
-- No host API, no hardware, no clock: everything is injected.

-- NOTE: the Noctalia host resolves requires *with* the extension
-- (service.luau uses require("./policy.luau")), while the bare standalone luau
-- interpreter resolves them *without*. Both point at the same file; the
-- difference is a property of the two runtimes, not of this repo.
local policy = require("../als-brightness/policy")

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

local cfg = policy.DEFAULTS

-- ── the curve ────────────────────────────────────────────────────────────────
check("anchor 185 raw == the owner's measured 70%",
  policy.percent_for_raw(185, cfg), 70)
check("anchor 1 raw", policy.percent_for_raw(1, cfg), 20)
check("anchor 10000 is clamped to max_percent (not 100 from the 16384 anchor)",
  policy.percent_for_raw(10000, cfg) <= cfg.max_percent, true)

-- everything at or below the first anchor collapses toward its value
check("occluded floor 4 raw sits just above the first anchor",
  policy.percent_for_raw(4, cfg), 25.374933317397158)
check_true("0 raw does not blow up on log10 (clamps to the first anchor)",
  policy.percent_for_raw(0, cfg) == 20)
check_true("the occluded floor is still above min_percent",
  policy.percent_for_raw(4, cfg) > cfg.min_percent)
-- and above the last anchor clamps to the last value
check("torch 16653 raw clamps to max", policy.percent_for_raw(16653, cfg), 100)
check("vast 10^9 raw still clamps", policy.percent_for_raw(1000000000, cfg), 100)

-- monotonic non-decreasing across the whole measured range
do
  local prev, mono = -1, true
  local raw = 1
  while raw <= 40000 do
    local p = policy.percent_for_raw(raw, cfg)
    if p < prev - 1e-9 then mono = false end
    prev = p
    raw = raw + 7
  end
  check_true("curve is monotonic non-decreasing over 1..40000 raw", mono)
end

-- log compression: the dark end must actually be resolved. With a linear axis
-- raw 46 vs raw 185 would differ by ~35% of the total span and read as a cliff;
-- log should put them on distinct, well-separated steps.
do
  local a = policy.percent_for_raw(46, cfg)
  local b = policy.percent_for_raw(185, cfg)
  local c = policy.percent_for_raw(4000, cfg)
  check_true("dark end is resolved (46 < 185 < 4000 in percent)", a < b and b < c)
  check("4x ambient (46) sits 20 points under the 185 anchor", b - a, 20)
end

-- ── stabiliser: asymmetric on purpose ───────────────────────────────────────
do
  local start = policy.log_of(185)
  local dt = 1.0
  local rising = policy.stabilize(start, 16653, dt, cfg)
  local falling = policy.stabilize(start, 4, dt, cfg)
  local rise_gain = rising - start
  local fall_mag = start - falling
  check_true("a rise is damped harder than a fall", rise_gain < fall_mag)
  check_true("first sample initialises rather than filtering",
    policy.stabilize(nil, 185, dt, cfg) == policy.log_of(185))
  -- one 1 s step must not jump all the way to the target
  check_true("a 90x rise does not reach target in one second",
    rising < policy.log_of(16653))
end

-- ── slew limiter ────────────────────────────────────────────────────────────
do
  check("slew limits a big upward step", policy.slew(10, 100, 1.0, cfg), 40)
  check("slew limits a big downward step", policy.slew(90, 0, 1.0, cfg), 60)
  check("small steps pass through", policy.slew(50, 55, 1.0, cfg), 55)
  check("nil previous passes through", policy.slew(nil, 42, 1.0, cfg), 42)
  check("zero dt is a no-op", policy.slew(50, 90, 0.0, cfg), 50)
end

-- ── dead band ───────────────────────────────────────────────────────────────
check_true("first write always happens", policy.should_write(nil, 70, cfg))
check_true("sub-tolerance move is suppressed", not policy.should_write(70, 70.5, cfg))
check_true("tolerance move is a write", policy.should_write(70, 71, cfg))
check_true("large move is a write", policy.should_write(70, 30, cfg))

-- ── manual-change detection ─────────────────────────────────────────────────
check_true("nothing written yet is never a manual change",
  not policy.is_manual_change(nil, 90, cfg))
check_true("matching value is not a manual change",
  not policy.is_manual_change(70, 70.5, cfg))
check_true("user move is detected", policy.is_manual_change(70, 90, cfg))
check_true("user move down is detected", policy.is_manual_change(70, 40, cfg))

-- ── override expiry: the band, not a bare timer ────────────────────────────
do
  local ov = { raw = 185, percent = 90, at = 1000 }
  check_true("inside the band and inside the timeout stays active",
    not policy.override_expired(ov, 200, 1100, cfg))
  check_true("leaving the band upward expires it",
    policy.override_expired(ov, 185 * 2.5, 1100, cfg))
  check_true("leaving the band downward expires it",
    policy.override_expired(ov, 185 * 0.3, 1100, cfg))
  check_true("timeout expires it even with the lighting unchanged",
    policy.override_expired(ov, 185, 1000 + cfg.override_timeout_s, cfg))
  -- Boundary, because this is where a seconds/milliseconds mix-up hides: the
  -- host clock is in ms and must be converted before it reaches here.
  check_true("one second before the timeout it is still active",
    not policy.override_expired(ov, 185, 1000 + cfg.override_timeout_s - 1, cfg))
  check_true("the timeout is 300 SECONDS, not 300 ms",
    cfg.override_timeout_s == 300)
  check_true("a millisecond-scale now_s would expire instantly (guards regressions)",
    policy.override_expired(ov, 185, 1000 + 300 * 1000, cfg))
  check_true("no override at all counts as expired",
    policy.override_expired(nil, 185, 1000, cfg))
end

-- ── guards, in precedence order ─────────────────────────────────────────────
do
  local clean = { dpms = "On", lid_closed = false, idle_engaged = false,
                  locked = false, override_active = false }
  local ok, why = policy.guard(clean)
  check_true("clean signals allow adaptation", ok)
  check("clean reason", why, "ok")

  local function blocked(mutate)
    local s = {}
    for k, v in pairs(clean) do s[k] = v end
    mutate(s)
    return policy.guard(s)
  end

  check_true("panel off blocks", select(1, blocked(function(s) s.dpms = "Off" end)) == false)
  check_true("lid closed blocks", select(1, blocked(function(s) s.lid_closed = true end)) == false)
  check_true("idle blocks", select(1, blocked(function(s) s.idle_engaged = true end)) == false)
  check_true("locked blocks", select(1, blocked(function(s) s.locked = true end)) == false)
  check_true("override blocks", select(1, blocked(function(s) s.override_active = true end)) == false)
  -- reason strings must name the cause, otherwise a suspension is unexplainable
  check("dpms reason names the state", select(2, blocked(function(s) s.dpms = "Off" end)), "dpms=Off")
  check("idle reason", select(2, blocked(function(s) s.idle_engaged = true end)), "idle_engaged")
  check("override reason", select(2, blocked(function(s) s.override_active = true end)), "user_override")
end

-- ── percent_of ──────────────────────────────────────────────────────────────
check("70% of an amdgpu_bl1 panel", policy.percent_of(280000, 400000), 70)
check("the dimmed value observed during the idle trace", policy.percent_of(120000, 400000), 30)
check("missing inputs yield nil", policy.percent_of(nil, 400000), nil)
check("zero max yields nil", policy.percent_of(1, 0), nil)

print(string.format("\n%d checks, %d failure(s)", checks, failures))
if failures > 0 then
  -- Luau's standalone interpreter has no `os` library (verified: `os` is nil),
  -- which is also why src/service.luau must take its clock from
  -- noctalia.nowMs() rather than os.time().
  error(string.format("%d check(s) failed", failures), 0)
end
