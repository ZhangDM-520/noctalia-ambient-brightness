--!nonstrict
-- Timeline tests for als-brightness/adaptation.luau (the decide() module).
-- Run from the repo root:
--     luau tests/adaptation.test.luau
-- No host API, no hardware, no clock: the clock arrives as injected readings
-- (opts.now_ms) and the tests construct timelines -- idle engagement, override
-- open/close, learning record/suppress, lock, profile transitions -- as
-- sequences of (tick, observed, events) calls.
--
-- NOTE: the Noctalia host resolves requires *with* the extension
-- (service.luau uses require("./policy.luau")), while the bare standalone luau
-- interpreter resolves them *without*. Both point at the same file; the
-- difference is a property of the two runtimes, not of this repo.
local adaptation = require("../als-brightness/adaptation")
local policy = require("../als-brightness/policy")
local profile = require("../als-brightness/profile")
local curve_source = require("../als-brightness/curve_source")
local colortemp = require("../als-brightness/colortemp")

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

-- ── timeline scaffolding ─────────────────────────────────────────────────────
local PATHS = {
  als_raw = "/sys/bus/iio/iio:device2/in_illuminance_raw",
  bl_cur = "/sys/class/backlight/amdgpu_bl1/brightness",
}

local function make_cfg()
  local cfg = {}
  for k, v in pairs(policy.DEFAULTS) do cfg[k] = v end
  cfg.enabled = true
  cfg.colortemp_enabled = false
  return cfg
end

local function new_session()
  local session = {
    log = nil,
    last_written = nil,
    override = nil,
    idle = false,
    locked = false,
    last_reason = nil,
    last_ms = nil,
    applied_k = nil,
    last_temp_s = nil,
    profile = profile.new(),
    curve_settings = {},
  }
  session.cs = curve_source.resolve(session.curve_settings, { profile = session.profile })
  return session
end

local function opts_at(now_ms)
  return { now_ms = now_ms, paths = PATHS }
end

local function observed_at(raw, percent)
  return { raw = raw, percent = percent, guards = { dpms = "On", lid_closed = false } }
end

-- One tick of the timeline. Returns the ordered action list decide() decided.
local function tick(session, n, now_ms, observed, cfg)
  return adaptation.decide(session, n, observed or observed_at(185, 70), {}, cfg, opts_at(now_ms))
end

-- One IPC event at its own instant (tick = nil), like service.onIpc.
local function event(session, name, now_ms, observed, cfg)
  return adaptation.decide(session, nil, observed or observed_at(185, 70), { name }, cfg, opts_at(now_ms))
end

local function lines_of(actions)
  local out = {}
  for _, action in ipairs(actions) do
    if action.kind == "log" then out[#out + 1] = action.line end
  end
  return table.concat(out, "\n")
end

local function count_kind(actions, kind)
  local n = 0
  for _, action in ipairs(actions) do
    if action.kind == kind then n = n + 1 end
  end
  return n
end

local function find_kind(actions, kind)
  for _, action in ipairs(actions) do
    if action.kind == kind then return action end
  end
  return nil
end

local function find_line(actions, needle)
  for _, action in ipairs(actions) do
    if action.kind == "log" or action.kind == "warn_once" then
      if string.find(action.line, needle, 1, true) ~= nil then return action.line end
    end
  end
  return nil
end

-- ── the write path: byte-identical evidence lines ────────────────────────────
do
  local session = new_session()
  local actions = tick(session, 1, 1000, observed_at(185, 70), make_cfg())
  check("the first tick logs resumed then writes",
    lines_of(actions), "resumed: adapting\nwrite: raw=185 target=70.0 commanded=70.0 (was nil) via sliders")
  local write = find_kind(actions, "write")
  check_true("a write action carries the commanded percent", write ~= nil and write.percent == 70)
  check("decide() records the commanded value, not the readback",
    session.last_written, 70)
end

do
  -- The heartbeat line is the maintainer's evidence stream: byte-identical.
  local session = new_session()
  local cfg = make_cfg()
  tick(session, 1, 1000, observed_at(185, 70), cfg)
  local actions = tick(session, 60, 60000, observed_at(185, 70), cfg)
  check("the heartbeat line is byte-identical",
    find_line(actions, "heartbeat"),
    "heartbeat raw=185 stab=2.270 last=70.0 observed=70.0 idle=false locked=false curve=sliders")
end

do
  -- ...and it fires on the 60-tick cadence only.
  local session = new_session()
  local cfg = make_cfg()
  tick(session, 1, 1000, observed_at(185, 70), cfg)
  local actions = tick(session, 59, 59000, observed_at(185, 70), cfg)
  check("no heartbeat before tick 60", find_line(actions, "heartbeat"), nil)
  check("a sub-deadband move holds without a write", count_kind(actions, "write"), 0)
end

-- ── the suspend/resume state machine ─────────────────────────────────────────
do
  local session = new_session()
  local cfg = make_cfg()
  tick(session, 1, 1000, observed_at(185, 70), cfg)
  session.locked = true
  local a2 = tick(session, 2, 2000, observed_at(185, 70), cfg)
  check("a lock suspends with the reason", lines_of(a2), "suspended: locked")
  local a3 = tick(session, 3, 3000, observed_at(185, 70), cfg)
  check("the suspension line fires once, not every tick", lines_of(a3), "")
  session.locked = false
  local a4 = tick(session, 4, 4000, observed_at(185, 70), cfg)
  check("unlock resumes", lines_of(a4), "resumed: adapting")
end

do
  -- The guard reasons are named so a suspension is always attributable.
  local session = new_session()
  local cfg = make_cfg()
  tick(session, 1, 1000, observed_at(185, 70), cfg)
  local observed = observed_at(185, 70)
  observed.guards = { dpms = "Off", lid_closed = false }
  check("the dpms reason names the state",
    lines_of(tick(session, 2, 2000, observed, cfg)), "suspended: dpms=Off")
end

do
  local session = new_session()
  local cfg = make_cfg()
  cfg.enabled = false
  check("disabling suspends with its own line",
    lines_of(tick(session, 1, 1000, nil, cfg)), "suspended: disabled by setting")
  check("the disabled suspension also fires once only",
    lines_of(tick(session, 2, 2000, nil, cfg)), "")
  -- The stored reason is "disabled" while the line says more; pinned so the
  -- change-detection keeps matching the pre-refactor state machine exactly.
  check("the stored disabled reason is the short form", session.last_reason, "disabled")
end

-- ── read failures: hold and warn once ────────────────────────────────────────
do
  local session = new_session()
  local cfg = make_cfg()
  local actions = tick(session, 1, 1000, { raw = nil, percent = 70,
    guards = { dpms = "On", lid_closed = false } }, cfg)
  check("an unreadable sensor warns with its path and holds",
    find_line(actions, "ambient read failed"),
    "ambient read failed at " .. PATHS.als_raw .. "; not writing")
  check("an unreadable sensor never writes", count_kind(actions, "write"), 0)
  local warn = find_kind(actions, "warn_once")
  check_true("the read-failure line is a warn_once", warn ~= nil and warn.key == "als-read")

  actions = tick(session, 2, 2000, { raw = 185, percent = nil,
    guards = { dpms = "On", lid_closed = false } }, cfg)
  check("an unreadable backlight warns with its path and holds",
    find_line(actions, "backlight read failed"),
    "backlight read failed at " .. PATHS.bl_cur .. "; not writing")
end

-- ── the idle handshake ───────────────────────────────────────────────────────
do
  local session = new_session()
  local cfg = make_cfg()
  tick(session, 1, 1000, observed_at(185, 30), cfg)
  check("idle engagement is announced", lines_of(event(session, "idle-engaged", 1500, nil, cfg)),
    "idle engaged")
  local a2 = tick(session, 2, 2000, observed_at(185, 30), cfg)
  check("an idle session suspends", find_line(a2, "suspended: idle_engaged"), "suspended: idle_engaged")
  check("an idle session never writes", count_kind(a2, "write"), 0)
end

do
  local session = new_session()
  local cfg = make_cfg()
  tick(session, 1, 1000, observed_at(185, 70), cfg)
  event(session, "idle-engaged", 1500, nil, cfg)
  local release = event(session, "idle-released", 2000, observed_at(185, 69.6), cfg)
  check("idle release re-baselines from the restored value",
    lines_of(release), "idle released, re-baselined at 69.6%")
  check("the restore becomes the new commanded baseline", session.last_written, 69.6)
  check("idle release clears any override", session.override, nil)
  check("idle release resets the stabiliser", session.log, nil)
  -- The restore itself must never look like a manual change on the next tick.
  local a3 = tick(session, 2, 2500, observed_at(185, 69.6), cfg)
  check("the restored value is not recorded as an override",
    find_line(a3, "user override recorded"), nil)
end

do
  local session = new_session()
  local cfg = make_cfg()
  local unknown = event(session, "something-else", 1000, nil, cfg)
  check("unknown events are named", lines_of(unknown), "unknown ipc event: something-else")
end

-- ── the override window ──────────────────────────────────────────────────────
do
  local session = new_session()
  local cfg = make_cfg()
  tick(session, 1, 1000, observed_at(185, 70), cfg)
  local open = tick(session, 2, 2000, observed_at(185, 45), cfg)
  check("a manual change is recorded verbatim",
    lines_of(open),
    "user override recorded: observed=45.0% raw=185\nsuspended: user_override")
  check("recording persists the observation", count_kind(open, "record"), 1)
  check("the override anchors where the owner was", session.override.raw, 185)
  check("the override anchor time is SECONDS", session.override.at, 2)
  local hold = tick(session, 3, 3000, observed_at(185, 45), cfg)
  -- The suspend line fires on CHANGE only (bounded log ring; matches the
  -- pre-refactor service, `git show HEAD:als-brightness/service.luau`), so on a
  -- held tick the proof of suspension is that adaptation does NOT act.
  check("an open override suspends adaptation", count_kind(hold, "write"), 0)
end

do
  local session = new_session()
  local cfg = make_cfg()
  tick(session, 1, 1000, observed_at(185, 70), cfg)
  tick(session, 2, 2000, observed_at(185, 45), cfg)
  local expire = tick(session, 3, 302000, observed_at(185, 45), cfg)
  check("the window expires at the timeout with a re-baseline line",
    find_line(expire, "override expired"),
    "override expired at raw=185, re-baselined at 45.0%")
  check("expiry re-baselines from where the owner left the panel",
    session.last_written, 45)
  local resume = tick(session, 4, 303000, observed_at(185, 45), cfg)
  check("the session resumes after expiry", find_line(resume, "resumed: adapting"), "resumed: adapting")
  check("the re-baselined value is not a fresh override",
    find_line(resume, "user override recorded"), nil)
end

do
  -- The window leaves when the lighting changes materially: Android's band.
  local session = new_session()
  local cfg = make_cfg()
  tick(session, 1, 1000, observed_at(185, 70), cfg)
  tick(session, 2, 2000, observed_at(185, 45), cfg)
  local out = tick(session, 3, 3000, observed_at(1000, 45), cfg)
  check("leaving the [0.5x, 2x] band expires the window",
    find_line(out, "override expired"), "override expired at raw=1000, re-baselined at 45.0%")
end

-- ── learning: record / suppress, and what lands in the profile ───────────────
do
  local session = new_session()
  local cfg = make_cfg()
  local actions = event(session, "user-adjusted", 1000, observed_at(200, 55), cfg)
  check("the keybinding signal is recorded verbatim",
    lines_of(actions), "user override via keybinding")
  check("the definitive signal is also an observation", count_kind(actions, "record"), 1)
  local save = find_kind(actions, "save_profile")
  check_true("the event forces a save", save ~= nil and save.force == true)
  check("one event is one observation", #session.profile.observations, 1)
  local obs = session.profile.observations[1]
  check("the observation records the ambient in the curve domain",
    obs.x, math.log10(200 + 1))
  check("the observation records what the owner chose", obs.y, 55)
  check("the observation records the raw counts for learning", obs.raw, 200)
  check("the observation timestamp is SECONDS", obs.at, 1)
end

do
  local session = new_session()
  session.curve_settings = { learning_profile = true }
  local cfg = make_cfg()
  event(session, "user-adjusted", 1000, observed_at(200, 55), cfg)
  event(session, "user-adjusted", 1500, observed_at(210, 55), cfg)
  check("two observations are both kept", #session.profile.observations, 2)
  check_true("the rebuilt curve carries the learned nudge",
    session.cs.brightness.source == "sliders+learned (1/10 nodes)")
end

-- ── cadences ─────────────────────────────────────────────────────────────────
do
  local session = new_session()
  local cfg = make_cfg()
  tick(session, 1, 1000, observed_at(185, 70), cfg)
  check("no lock poll before tick 10",
    find_kind(tick(session, 5, 5000, observed_at(185, 70), cfg), "poll_lock"), nil)
  check_true("the lock poll runs on its 10-tick cadence",
    find_kind(tick(session, 10, 10000, observed_at(185, 70), cfg), "poll_lock") ~= nil)
  local actions = tick(session, 11, 11000, observed_at(185, 70), cfg)
  check("every tick carries the (throttled) profile save request",
    count_kind(actions, "save_profile"), 1)
end

-- ── colour temperature rides the same guards ─────────────────────────────────
do
  local session = new_session()
  local cfg = make_cfg()
  cfg.colortemp_enabled = true
  local observed = observed_at(185, 70)
  observed.ambient_k = 3000
  local actions = tick(session, 1, 1000, observed, cfg)
  local apply = find_kind(actions, "apply_temperature")
  check_true("a cold ambient asks for a temperature write", apply ~= nil)
  check("the temperature target comes off the shipped curve", apply and apply.kelvin, 5380)

  -- Once applied, a stable ambient must not reconsider (the executor records
  -- the write outcome in these two fields).
  session.applied_k = 5380
  session.last_temp_s = 1
  local again = tick(session, 2, 2000, observed, cfg)
  check("a sub-step move is not worth a reload", find_kind(again, "apply_temperature"), nil)

  -- ...and the same guards that stop brightness stop temperature.
  session.idle = true
  event(session, "idle-engaged", 2500, nil, cfg)
  local idle_tick = tick(session, 3, 3000, observed, cfg)
  check("an idle session leaves the temperature alone",
    find_kind(idle_tick, "apply_temperature"), nil)
end

-- ── the five historical defects, each pinned ─────────────────────────────────
-- docs/DESIGN.md section 8 names the four defects found by running the project
-- and section 9.5 the fifth: the pluginDir function call (section 2), the
-- seconds/milliseconds mix (section 5), the override re-recording (section 5),
-- the splice index shift (section 6) and the idle dim recorded as a preference
-- (section 9.5). Each block below is named for its defect and fails if the
-- defect returns. The pluginDir one is a static guard in run-tests.sh (service
-- glue cannot load under a bare luau); the splice one is pinned here and in
-- tests/colortemp.test.luau.

do
  -- DESIGN.md section 9.5: `user-adjusted` recorded the idle dim as a
  -- preference. The 30% dim is authored policy, not a preference: while the
  -- session is idle the event must be swallowed, and nothing learned.
  local session = new_session()
  local cfg = make_cfg()
  event(session, "idle-engaged", 1000, nil, cfg)
  local actions = event(session, "user-adjusted", 1500, observed_at(185, 30), cfg)
  check("regression: the idle dim is a pause, not a preference (DESIGN 9.5)",
    lines_of(actions), "user-adjusted ignored while idle (the dim is not a preference)")
  check("regression: the idle dim never reaches the profile (DESIGN 9.5)",
    #session.profile.observations, 0)
  check("regression: the idle dim opens no override (DESIGN 9.5)",
    session.override, nil)
end

do
  -- DESIGN.md section 5: "The override was re-recorded every tick, resetting
  -- its own 300 s timer each second so it could never expire." Only the FIRST
  -- detection records; the anchor must never move afterwards.
  local session = new_session()
  local cfg = make_cfg()
  tick(session, 1, 1000, observed_at(185, 70), cfg)
  tick(session, 2, 2000, observed_at(185, 45), cfg)
  local anchor_at = session.override.at
  for n = 3, 8 do
    local actions = tick(session, n, 1000 + n * 1000, observed_at(185, 45), cfg)
    check("regression: a held manual change re-records nothing (DESIGN 5)",
      count_kind(actions, "record"), 0)
  end
  check("regression: the override anchor never moves (DESIGN 5)",
    session.override.at, anchor_at)
  check("regression: exactly one observation per manual change (DESIGN 5)",
    #session.profile.observations, 1)
  -- With the anchor pinned, the 300 s window CAN expire (raw unchanged, so the
  -- band holds and the timeout is the only exit).
  local expire = tick(session, 9, 1000 + 301 * 1000, observed_at(185, 45), cfg)
  check("regression: the 300 s window still expires (DESIGN 5)",
    find_line(expire, "override expired at raw=185, re-baselined at 45.0%"),
    "override expired at raw=185, re-baselined at 45.0%")
end

do
  -- DESIGN.md section 5: "Seconds and milliseconds were mixed.
  -- override_timeout_s (300, seconds) was compared against noctalia.nowMs()
  -- (milliseconds), so every override expired on the first tick." The clock
  -- arrives as MILLISECONDS (opts.now_ms) at real magnitudes and the window
  -- must survive 299 s and expire at 300 s. Any ms/s leak expires it early.
  local T0_MS = 1700000000000
  local session = new_session()
  local cfg = make_cfg()
  event(session, "user-adjusted", T0_MS, observed_at(185, 55), cfg)
  check("regression: the override anchor stores SECONDS at the ms boundary (DESIGN 5)",
    session.override.at, T0_MS / 1000.0)
  local hold = tick(session, 1, T0_MS + 299 * 1000, observed_at(185, 55), cfg)
  check("regression: 299 s in, the window is still open (DESIGN 5)",
    find_line(hold, "override expired"), nil)
  check("regression: ...and adaptation stays suspended under it (DESIGN 5)",
    find_line(hold, "suspended: user_override"), "suspended: user_override")
  local expire = tick(session, 2, T0_MS + 300 * 1000, observed_at(185, 55), cfg)
  check("regression: 300 s in, the window expires exactly on time (DESIGN 5)",
    find_line(expire, "override expired at raw=185, re-baselined at 55.0%"),
    "override expired at raw=185, re-baselined at 55.0%")
end

do
  -- DESIGN.md section 6: inserting the missing `force` key shifted the line
  -- numbers of the already-recorded keys, so the rewrite landed one line too
  -- high and wrote the night temperature over `temperature_day`. Rewrites must
  -- happen before insertions: with both keys present and `force` missing, the
  -- day key must survive untouched. (Same surface is pinned in
  -- tests/colortemp.test.luau; named here so all five defects have a pin.)
  local original = table.concat({
    "[nightlight]",
    "enabled = false",
    "temperature_day = 6500",
    "temperature_night = 5100",
    "",
    "[notifications]",
    "border = true",
  }, "\n")
  local out, changed = colortemp.splice(original, 4000)
  check_true("regression: the splice changes the file (DESIGN 6)", changed)
  check_true("regression: temperature_day is never the key rewritten (DESIGN 6)",
    out:find("temperature_day = 6500", 1, true) ~= nil)
  check_true("regression: temperature_night is the key rewritten (DESIGN 6)",
    out:find("temperature_night = 4000", 1, true) ~= nil
      and out:find("temperature_night = 5100", 1, true) == nil)
  check_true("regression: the missing force key is still inserted (DESIGN 6)",
    out:find("force = true", 1, true) ~= nil)
end

print(string.format("\n%d checks, %d failure(s)", checks, failures))
if failures > 0 then
  -- Luau's standalone interpreter has no `os` library (verified: `os` is nil),
  -- which is also why the clock is injected into decide() rather than read.
  error(string.format("%d check(s) failed", failures), 0)
end
