--!nonstrict
-- Pure-function tests for als-brightness/temperature.luau.
--     luau tests/temperature.test.luau
-- The write path's return paths are the historical bug surface: each one
-- decides by hand (or now, visibly) whether the attempt counts as "applied",
-- and that bookkeeping is what decides whether the colortemp config is spliced
-- again. So every exit path has its own named test below, pinned through an
-- injected fake environment: what IO ran, in which order, what was logged, and
-- what happened to state.applied_k / state.last_temp_s.
--
-- The splice internals themselves are pinned in tests/colortemp.test.luau;
-- these tests pin the WRITE PATH around the splice and do not re-test it.

local temperature = require("../als-brightness/temperature")
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

local SETTINGS = "/home/u/.config/noctalia/settings.toml"
local TMP = SETTINGS .. ".als-brightness.tmp"

-- A config that already holds the target (splice must report changed == false),
-- and one that does not (splice must report changed == true).
local SAME = "[nightlight]\nenabled = true\nforce = true\ntemperature_night = 5200\n"
local DIFFERENT = "[nightlight]\ntemperature_night = 5100\n"

check_true("the unchanged fixture is genuinely a no-op splice",
  not (select(2, ct.splice(SAME, 5200))))
check_true("the other fixture really wants a write", (select(2, ct.splice(DIFFERENT, 5200))))

-- ── a fake machine ───────────────────────────────────────────────────────────
-- Records every call so a test can pin the ORDER of the IO, not just its fact.
-- opts: no_path, text, write_ok, rename_ok (defaults: path set, write/rename ok).
local function fake_env(opts)
  opts = opts or {}
  local calls = { reads = {}, writes = {}, renames = {}, reloads = 0, order = {} }
  local env = {
    settings_path = not opts.no_path and SETTINGS or nil,
    read_file = function(path)
      calls.reads[#calls.reads + 1] = path
      return opts.text
    end,
    write_file = function(path, text)
      calls.writes[#calls.writes + 1] = { path = path, text = text }
      calls.order[#calls.order + 1] = "write"
      return opts.write_ok ~= false
    end,
    rename = function(from, to)
      calls.renames[#calls.renames + 1] = { from = from, to = to }
      calls.order[#calls.order + 1] = "rename"
      return opts.rename_ok ~= false
    end,
    reload = function()
      calls.reloads = calls.reloads + 1
      calls.order[#calls.order + 1] = "reload"
    end,
  }
  return env, calls
end

local function fresh_state()
  return { applied_k = 4000, last_temp_s = 1, untouched = "keep" }
end

-- ── return path 1: no settings path ──────────────────────────────────────────
do
  local env, calls = fake_env({ no_path = true })
  local state = fresh_state()
  local actions = temperature.write_path(state, 5200, 1000, env)
  check("path 1 (no settings path): exactly one action", #actions, 1)
  check("  ...a warn_once, not a log line", actions[1] and actions[1].kind, "warn_once")
  check("  ...keyed settings-path", actions[1] and actions[1].key, "settings-path")
  check("  ...byte-identical line", actions[1] and actions[1].line,
    "colortemp skipped: no settings path (HOME unset)")
  check("  ...no file was read", #calls.reads, 0)
  check("  ...nothing was written", #calls.writes, 0)
  check("  ...no reload was asked for", calls.reloads, 0)
  check("  ...the bookkeeping is untouched", state.applied_k, 4000)
  check("  ...including last_temp_s", state.last_temp_s, 1)
end

-- ── return path 2: unreadable settings ───────────────────────────────────────
do
  local env, calls = fake_env({ text = nil })
  local state = fresh_state()
  local actions = temperature.write_path(state, 5200, 1000, env)
  check("path 2 (unreadable settings): exactly one action", #actions, 1)
  check("  ...a log line", actions[1] and actions[1].kind, "log")
  check("  ...byte-identical line", actions[1] and actions[1].line,
    "colortemp: cannot read " .. SETTINGS)
  check("  ...the read targeted settings.toml", calls.reads[1], SETTINGS)
  check("  ...nothing was written", #calls.writes, 0)
  check("  ...no reload was asked for", calls.reloads, 0)
  check("  ...the bookkeeping is untouched", state.applied_k, 4000)
  check("  ...including last_temp_s", state.last_temp_s, 1)
end

-- ── return path 3: the config already holds the target ───────────────────────
do
  local env, calls = fake_env({ text = SAME })
  local state = fresh_state()
  local actions = temperature.write_path(state, 5200, 1000, env)
  check("path 3 (unchanged config): silent -- the log ring must not fill", #actions, 0)
  check("  ...no tmp was written", #calls.writes, 0)
  check("  ...nothing was renamed", #calls.renames, 0)
  check("  ...no reload was asked for", calls.reloads, 0)
  check("  ...the target IS recorded as applied", state.applied_k, 5200)
  check("  ...with its timestamp, so the gate stops reconsidering", state.last_temp_s, 1000)
end

-- ── return path 4: the tmp write failed ──────────────────────────────────────
do
  local env, calls = fake_env({ text = DIFFERENT, write_ok = false })
  local state = fresh_state()
  local actions = temperature.write_path(state, 5200, 1000, env)
  check("path 4 (tmp write failure): exactly one action", #actions, 1)
  check("  ...a log line", actions[1] and actions[1].kind, "log")
  check("  ...byte-identical line", actions[1] and actions[1].line,
    "colortemp: cannot write " .. TMP)
  check("  ...the write targeted the sibling tmp", calls.writes[1] and calls.writes[1].path, TMP)
  check("  ...nothing was renamed", #calls.renames, 0)
  check("  ...no reload was asked for", calls.reloads, 0)
  check("  ...the bookkeeping is untouched", state.applied_k, 4000)
  check("  ...including last_temp_s", state.last_temp_s, 1)
end

-- ── return path 5: the replace failed ────────────────────────────────────────
do
  local env, calls = fake_env({ text = DIFFERENT, rename_ok = false })
  local state = fresh_state()
  local actions = temperature.write_path(state, 5200, 1000, env)
  check("path 5 (replace failure): exactly one action", #actions, 1)
  check("  ...a log line", actions[1] and actions[1].kind, "log")
  check("  ...byte-identical line", actions[1] and actions[1].line,
    "colortemp: cannot replace " .. SETTINGS)
  check("  ...the rename was tmp -> settings.toml", calls.renames[1] and calls.renames[1].from, TMP)
  check("  ...both ways", calls.renames[1] and calls.renames[1].to, SETTINGS)
  check("  ...no reload was asked for", calls.reloads, 0)
  check("  ...the bookkeeping is untouched", state.applied_k, 4000)
  check("  ...including last_temp_s", state.last_temp_s, 1)
end

-- ── return path 6: applied ───────────────────────────────────────────────────
do
  local env, calls = fake_env({ text = DIFFERENT })
  local state = fresh_state()
  local actions = temperature.write_path(state, 5200, 1000, env)
  check("path 6 (applied): exactly one action", #actions, 1)
  check("  ...a log line", actions[1] and actions[1].kind, "log")
  check("  ...byte-identical applied line", actions[1] and actions[1].line,
    "colortemp: applied 5200K")
  check("  ...one write, to the sibling tmp", #calls.writes, 1)
  check("  ...carrying the spliced text", calls.writes[1] and calls.writes[1].text,
    (select(1, ct.splice(DIFFERENT, 5200))))
  check("  ...then tmp renamed over settings.toml",
    calls.renames[1] and calls.renames[1].from, TMP)
  check("  ...onto the real file", calls.renames[1] and calls.renames[1].to, SETTINGS)
  check("  ...exactly one config-reload", calls.reloads, 1)
  check_true("  ...write -> rename -> reload, in that order",
    table.concat(calls.order, ",") == "write,rename,reload")
  check("  ...the target is recorded as applied", state.applied_k, 5200)
  check("  ...with its timestamp", state.last_temp_s, 1000)
end

-- ── the applied line's shape ─────────────────────────────────────────────────
do
  local env = fake_env({ text = DIFFERENT })
  local actions = temperature.write_path(fresh_state(), 5237.8, 1000, env)
  check("the applied line floors fractional kelvin", actions[1] and actions[1].line,
    "colortemp: applied 5237K")
end

-- ── the bookkeeping writes nothing else ──────────────────────────────────────
do
  local env = fake_env({ text = DIFFERENT })
  local state = fresh_state()
  temperature.write_path(state, 5200, 1000, env)
  check("the bookkeeping touches only applied_k and last_temp_s",
    state.untouched, "keep")
end

-- ── the splice gate, state explicit ──────────────────────────────────────────
-- Wiring only: the thresholds themselves (step_k / min_interval_s) are pinned
-- in tests/colortemp.test.luau. These checks pin that the gate reads the two
-- bookkeeping fields from the state -- the same fields write_path owns.
check_true("the gate opens on an empty state (nothing applied yet)",
  temperature.should_apply({}, 5200, 1000))
check_true("the gate reads applied_k from the state",
  not temperature.should_apply({ applied_k = 5000, last_temp_s = 0 }, 5050, 10000))
check_true("the gate reads last_temp_s from the state",
  not temperature.should_apply({ applied_k = 5000, last_temp_s = 9990 }, 6000, 10000))
check_true("a big move after the interval passes the gate",
  temperature.should_apply({ applied_k = 5000, last_temp_s = 1 }, 6000,
    1 + ct.MAP_DEFAULTS.min_interval_s))

print(string.format("\n%d checks, %d failure(s)", checks, failures))
if failures > 0 then
  error(string.format("%d check(s) failed", failures), 0)
end
