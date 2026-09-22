--!nonstrict
-- Pure-function tests for als-brightness/colortemp.luau.
--     luau tests/colortemp.test.luau
-- The config splice is the risky part -- it edits a file the user owns -- so it
-- gets the most scrutiny here, including a comment-preservation check.

local ct = require("../als-brightness/colortemp")

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

local cfg = ct.MAP_DEFAULTS

-- ── the ambient -> panel mapping ────────────────────────────────────────────
check("warm anchor maps to the owner's 5100 K preference",
  ct.panel_k(3000, cfg), 5100)
check("cool anchor is neutral", ct.panel_k(5500, cfg), 6500)
check("midpoint interpolates", ct.panel_k(4250, cfg), 5800)
check("below the warm anchor clamps", ct.panel_k(1000, cfg), 5100)
check("above the cool anchor clamps", ct.panel_k(9000, cfg), 6500)
check("the measured room (~3400 K) sits near the warm end",
  ct.panel_k(3400, cfg), 5324)
-- monotonic
do
  local prev, mono = -1, true
  for k = 1000, 9000, 137 do
    local v = ct.panel_k(k, cfg)
    if v < prev - 1e-9 then mono = false end
    prev = v
  end
  check_true("mapping is monotonic non-decreasing", mono)
end

-- ── when to rewrite the config ──────────────────────────────────────────────
check_true("nothing applied yet is always worth applying",
  ct.should_apply(nil, 5000, nil, 1000, cfg))
check_true("a sub-step move is not worth a reload",
  not ct.should_apply(5000, 5100, 0, 10000, cfg))
check_true("a big move away from the anchor is worth it",
  ct.should_apply(5000, 6000, 0, 10000, cfg))
check_true("rate limiting suppresses a big move too soon",
  not ct.should_apply(5000, 6000, 1000, 1000 + 10, cfg))
check_true("rate limiting lets it through once the interval passes",
  ct.should_apply(5000, 6000, 1000, 1000 + cfg.min_interval_s, cfg))

-- ── the config splice ───────────────────────────────────────────────────────
do
  -- fresh file with no [nightlight] at all
  local original = "[shell]\ncorner_radius_scale = 1.1\n"
  local out, changed = ct.splice(original, 5200)
  check_true("appending a section counts as a change", changed)
  check_true("original content is preserved",
    out:find("corner_radius_scale = 1.1", 1, true) ~= nil)
  check_true("section header added", out:find("%[nightlight%]") ~= nil)
  check_true("enabled added", out:find("enabled = true", 1, true) ~= nil)
  check_true("force added", out:find("force = true", 1, true) ~= nil)
  check_true("temperature added",
    out:find("temperature_night = 5200", 1, true) ~= nil)

  -- idempotence: splicing the same value twice must not change anything
  local again, changed_again = ct.splice(out, 5200)
  check_true("second identical splice is a no-op", not changed_again)
  check("no-op returns the text byte-for-byte", again, out)
end

do
  -- an existing section, with comments and unrelated keys that MUST survive
  local original = table.concat({
    "# my noctalia settings",
    "[brightness]",
    "sync_all_monitors = true",
    "",
    "[nightlight]",
    "enabled = false",
    "temperature_day = 6500",
    "temperature_night = 5100   # the owner's preference",
    "",
    "[notification]",
    "border = true",
    "",
  }, "\n")

  local out, changed = ct.splice(original, 4000)
  check_true("rewriting an existing temperature is a change", changed)
  check_true("temperature_night updated",
    out:find("temperature_night = 4000", 1, true) ~= nil)
  check_true("the old value is gone",
    out:find("temperature_night = 5100", 1, true) == nil)
  check_true("enabled flipped to true", out:find("enabled = true", 1, true) ~= nil)
  check_true("force inserted", out:find("force = true", 1, true) ~= nil)
  check_true("temperature_day is NOT touched",
    out:find("temperature_day = 6500", 1, true) ~= nil)
  check_true("unrelated table survives",
    out:find("sync_all_monitors = true", 1, true) ~= nil)
  check_true("comments survive",
    out:find("# my noctalia settings", 1, true) ~= nil)
  check_true("key order is preserved",
    out:find("temperature_day = 6500", 1, true) < out:find("temperature_night = 4000", 1, true))
  check_true("the section after us is untouched",
    out:find("%[notification%]", 1) ~= nil)

  -- idempotence on an already-correct document
  local again, changed_again = ct.splice(out, 4000)
  check_true("re-splicing an already-correct file is a no-op", not changed_again)
  check("no-op is byte-for-byte identical", again, out)
end

do
  -- temperature_day must never be mistaken for temperature_night
  local original = "[nightlight]\ntemperature_day = 6500\n"
  local out = ct.splice(original, 3000)
  check_true("temperature_day is left alone when only it exists",
    out:find("temperature_day = 6500", 1, true) ~= nil)
  check_true("a night temperature is added alongside it",
    out:find("temperature_night = 3000", 1, true) ~= nil)
end

do
  -- keys in a later section must not be attributed to [nightlight]
  local original = "[nightlight]\nenabled = false\n\n[other]\ntemperature_night = 9999\n"
  local out = ct.splice(original, 3000)
  check_true("a same-named key in another table is not rewritten",
    out:find("temperature_night = 9999", 1, true) ~= nil)
  check_true("our own key was added to the right section instead",
    out:find("temperature_night = 3000", 1, true) ~= nil)
end

do
  -- fractional kelvin must not leak into the file
  local out = ct.splice("[nightlight]\n", 4237.8)
  check_true("kelvin is floored to an integer",
    out:find("temperature_night = 4237", 1, true) ~= nil)
end

do
  -- a file with NO trailing newline must not gain one: the splice has to touch
  -- nothing outside [nightlight], including the final byte.
  local original = "[nightlight]\ntemperature_night = 5100"
  local out, changed = ct.splice(original, 4000)
  check_true("a file without a trailing newline is changed", changed)
  check_true("no trailing newline is invented", out:sub(-1) ~= "\n")
  check_true("the value still landed",
    out:find("temperature_night = 4000", 1, true) ~= nil)

  -- and the round-trip is exact when there is nothing to do
  local same, changed_same = ct.splice(out, 4000)
  check_true("re-splice is a no-op", not changed_same)
  check("no-op is byte-for-byte identical", same, out)

  -- while a file that did end with one keeps it
  local with_nl = "[nightlight]\ntemperature_night = 5100\n"
  local out_nl = ct.splice(with_nl, 4000)
  check_true("an existing trailing newline is preserved", out_nl:sub(-1) == "\n")
end

print(string.format("\n%d checks, %d failure(s)", checks, failures))
if failures > 0 then
  error(string.format("%d check(s) failed", failures), 0)
end
