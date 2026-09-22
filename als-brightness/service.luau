--!nonstrict
-- Noctalia [[service]] entry point for ambient-light adaptive panel brightness.
--
-- This file is the only place that touches hardware, the shell or the filesystem.
-- All decision logic lives in pure modules, which run under a bare `luau` and are
-- unit-tested offline:
--
--   policy.luau     temporal shaping, the override window, the guards
--   curve.luau      the user-owned mapping curves (PCHIP interpolation)
--   profile.luau    the learned profile fitted from the owner's overrides
--   colortemp.luau  the night-light config splice and its guard rail
--
-- What is left here is a thin, boring shim: read settings, read sysfs, call the
-- pure functions in the right order, write the result out.
--
-- Design notes and the measurements behind every constant: docs/DESIGN.md.

local policy = require("./policy.luau")
local curve = require("./curve.luau")
local colortemp = require("./colortemp.luau")
local profile = require("./profile.luau")

-- ── paths ────────────────────────────────────────────────────────────────────
local ALS_RAW = "/sys/bus/iio/devices/iio:device2/in_illuminance_raw"
local ALS_CT  = "/sys/bus/iio/devices/iio:device2/in_colortemp_raw"
local DPMS    = "/sys/class/drm/card1-eDP-1/dpms"
local LID     = "/proc/acpi/button/lid/LID/state"
local BL_DIR  = "/sys/class/backlight/"
local HOME_DIR = noctalia.getenv("HOME") or "/home/zhangdm"
local SETTINGS_PATH = HOME_DIR .. "/.local/state/noctalia/settings.toml"

-- ── config ───────────────────────────────────────────────────────────────────
-- Every reader tolerates the wrong type rather than trusting the stored config,
-- because a settings file is a file the owner can edit by hand.
local function setting_bool(key, fallback)
  local value = noctalia.getConfig(key)
  if type(value) == "boolean" then return value end
  return fallback
end

local function setting_number(key, fallback)
  local value = noctalia.getConfig(key)
  if type(value) == "number" then return value end
  if type(value) == "string" then return tonumber(value) or fallback end
  return fallback
end

local function setting_string(key, fallback)
  local value = noctalia.getConfig(key)
  if type(value) == "string" and value ~= "" then return value end
  if type(value) == "number" then return tostring(value) end
  return fallback
end

--- A `string_list` arrives as a Luau array. A bare string is accepted as a one-row
--- list, so a hand-edited config cannot silently disable a whole curve.
local function setting_list(key, fallback)
  local value = noctalia.getConfig(key)
  if type(value) == "table" and #value > 0 then return value end
  if type(value) == "string" and value ~= "" then return { value } end
  return fallback
end

-- ── logging ──────────────────────────────────────────────────────────────────
-- writeFile replaces the file, so keep a bounded ring buffer in memory and rewrite
-- it. That gives real history without needing an append mode.
local DATA_DIR
do
  local ok, dir = pcall(noctalia.pluginDataDir)
  DATA_DIR = (ok and type(dir) == "string" and dir or "/tmp")
end
local LOG_PATH = DATA_DIR .. "/als-brightness.log"
local PROFILE_PATH = DATA_DIR .. "/profile.json"

local LOG_LINES = {}
local LOG_KEEP = 200

local function log(line)
  LOG_LINES[#LOG_LINES + 1] = line
  while #LOG_LINES > LOG_KEEP do
    table.remove(LOG_LINES, 1)
  end
  noctalia.writeFile(LOG_PATH, table.concat(LOG_LINES, "\n") .. "\n")
end

-- ── config-derived state ─────────────────────────────────────────────────────
local CFG = {}
for k, v in pairs(policy.DEFAULTS) do CFG[k] = v end

local CONNECTOR, ENABLED, COLORTEMP, LEARNING
-- The authored curves, plus the x positions they were built from. Keeping the x's
-- lets a fitted profile be laid onto exactly the same points, which is what makes
-- promoting a learned value into the settings page a bar-for-bar copy.
local CURVE_BR, XS_BR, AUTHORED_BR = nil, {}, {}
local CURVE_TEMP = nil
local COUNT_BR, COUNT_TEMP = 0, 0
-- What the tick actually evaluates: the authored curve, or the authored curve with
-- learned bands filled in.
local ACTIVE_BR = nil
local LEARNED_BANDS = 0
local CURVE_SOURCE = "authored"

--- The brightness curve is interpolated in log10(raw + 1). Not cosmetic: the
--- measured range is ~4000:1 (4 .. 16653 raw), so a linear axis would collapse
--- everything below ~1000 raw into a single step.
local function map_brightness_x(x)
  return math.log10(x + 1)
end

local PROF = profile.new()

local function load_profile()
  local text = noctalia.readFile(PROFILE_PATH)
  if text == nil or text == "" then return end
  local ok, decoded = pcall(noctalia.json.decode, text)
  if not ok or decoded == nil then
    -- A corrupt profile must cost the learned data, never the service.
    log("profile: cannot parse " .. PROFILE_PATH .. "; starting a fresh one")
    return
  end
  PROF = profile.sanitise(decoded)
end

local LAST_SAVE_S = nil
local DIRTY = false

local function save_profile(now_s, force)
  if not DIRTY and not force then return end
  -- Throttled rather than saved per observation: holding a brightness key fires
  -- many events, and this file is a convenience, not a transaction log.
  if not force and LAST_SAVE_S ~= nil and (now_s - LAST_SAVE_S) < 2 then
    return
  end
  PROF.updated_at = math.floor(now_s)
  local ok, encoded = pcall(noctalia.json.encode, PROF)
  if not ok or encoded == nil then return end
  if noctalia.writeFile(PROFILE_PATH, encoded) then
    DIRTY = false
    LAST_SAVE_S = now_s
  end
end

--- Fill the authored curve's y values in with whatever the profile can speak for.
local function rebuild_active()
  LEARNED_BANDS = 0
  if not LEARNING then
    ACTIVE_BR = CURVE_BR
    CURVE_SOURCE = "authored"
    return
  end

  local ys = profile.fit(PROF, XS_BR, AUTHORED_BR, CFG)
  local nodes = {}
  for i = 1, #XS_BR do nodes[i] = { x = XS_BR[i], y = ys[i] } end
  local learned = curve.compile(nodes)
  if learned == nil then
    -- Nothing learnable yet: behave exactly as if the toggle were off, so an empty
    -- profile can never leave the panel unmanaged.
    ACTIVE_BR = CURVE_BR
    CURVE_SOURCE = "authored (profile not usable yet)"
    return
  end
  ACTIVE_BR = learned
  LEARNED_BANDS = profile.learned_bands(PROF, XS_BR, CFG)
  CURVE_SOURCE = string.format("learned (%d/%d bands)", LEARNED_BANDS, #XS_BR)
end

local function load_curve(key, fallback, map_x)
  local items = setting_list(key, fallback)
  local nodes, problems = curve.parse_nodes(items, { map_x = map_x })
  for _, problem in ipairs(problems) do
    log("curve " .. key .. ": " .. problem)
  end
  if #nodes == 0 then
    log("curve " .. key .. ": no usable nodes, falling back to the shipped default")
    nodes = curve.parse_nodes(fallback, { map_x = map_x })
  end
  if not curve.is_monotone(nodes) then
    -- Honoured, never rewritten: silently monotone-ising the owner's numbers would
    -- be the worst possible behaviour for a curve they are tuning. It stays safe
    -- because PCHIP cannot overshoot past a node value.
    log("curve " .. key .. ": values are not monotone; using them as written")
  end
  local xs, ys = {}, {}
  for i, node in ipairs(nodes) do
    xs[i] = node.x
    ys[i] = node.y
  end
  return curve.compile(nodes), xs, ys, #nodes
end

local function reload()
  ENABLED = setting_bool("enabled", true)
  COLORTEMP = setting_bool("colortemp", false)
  LEARNING = setting_bool("learning_profile", false)
  CONNECTOR = setting_string("connector", "eDP-1")
  CFG.min_percent = setting_number("min_percent", 15)
  CFG.max_percent = setting_number("max_percent", 100)

  local br
  br, XS_BR, AUTHORED_BR, COUNT_BR =
    load_curve("curve_brightness", curve.DEFAULT_BRIGHTNESS, map_brightness_x)
  CURVE_BR = br
  CURVE_TEMP, _, _, COUNT_TEMP =
    load_curve("curve_temperature", curve.DEFAULT_TEMPERATURE, nil)

  rebuild_active()

  log(string.format(
    "config: brightness=%d nodes temperature=%d nodes learning=%s source=%s",
    COUNT_BR, COUNT_TEMP, tostring(LEARNING), CURVE_SOURCE))
end

-- ── backlight device discovery ───────────────────────────────────────────────
local BL_CUR, BL_MAX
local function resolve_backlight()
  local forced = setting_string("backlight", "")
  local name = forced
  if name == "" then
    local entries = noctalia.listDir(BL_DIR) or {}
    name = entries[1] or "amdgpu_bl1"
  end
  BL_CUR = BL_DIR .. name .. "/brightness"
  BL_MAX = BL_DIR .. name .. "/max_brightness"
end

-- ── state ────────────────────────────────────────────────────────────────────
local S = {
  log = nil,            -- stabilised log10 reading
  last_written = nil,   -- percent we last commanded
  override = nil,       -- {raw=, percent=, at=}
  idle = false,         -- set by the idle handshake, not inferred
  locked = false,       -- refreshed by a slow poll
  last_ms = nil,
  last_reason = nil,
  applied_k = nil,      -- night-light temperature we last wrote
  last_temp_s = nil,
}

local function trim(s)
  if s == nil then return nil end
  return (tostring(s):gsub("%s+$", ""))
end

local function read_num(path)
  return tonumber(trim(noctalia.readFile(path)))
end

local function read_str(path)
  return trim(noctalia.readFile(path))
end

-- ── the slow lock poll ───────────────────────────────────────────────────────
-- `noctalia msg status` is the only way to learn the lock state, and shelling out
-- every second would be wasteful, so it is sampled on its own cadence. RunAsync
-- with an argv table needs plugin_api 24, which is why the manifest declares it.
local LOCK_POLL_TICKS = 10
local function poll_locked(tick)
  if tick % LOCK_POLL_TICKS ~= 0 then return end
  noctalia.runAsync({ "noctalia", "msg", "status" }, function(result)
    if result == nil or result.exitCode ~= 0 then return end
    local ok, decoded = pcall(noctalia.json.decode, result.stdout or "")
    if ok and type(decoded) == "table" and decoded.locked ~= nil then
      S.locked = decoded.locked and true or false
    end
  end, 4000)
end

-- ── applying a change ────────────────────────────────────────────────────────
local function write_percent(pct)
  local frac = pct / 100.0
  noctalia.runAsync({ "noctalia", "msg", "brightness-set", CONNECTOR,
                      string.format("%.4f", frac) }, nil, 4000)
  -- Record what we asked for, not what we read back: the readback path has its own
  -- transfer curve (actual ~= requested), but `brightness` is the value both
  -- brightnessctl and Noctalia agree on, and it is what we compare against.
  S.last_written = pct
end

-- ── the learned profile ──────────────────────────────────────────────────────
--- An observation is simply an override the owner made: where the ambient was, and
--- what they set the panel to. Recorded in the curve's own domain, so the fit can
--- lay it straight onto the authored x positions.
local function record_observation(raw, percent, now_s)
  profile.add(PROF, {
    x = map_brightness_x(raw),
    y = percent,
    raw = raw,
    at = now_s,
  }, CFG)
  DIRTY = true
  save_profile(now_s, false)
  -- The learned curve only changes when an observation lands, so this is the only
  -- place it needs rebuilding.
  if LEARNING then rebuild_active() end
end

-- ── colour temperature ───────────────────────────────────────────────────────
-- Noctalia owns the gamma LUT, so rather than opening a second writer on
-- zwlr_gamma_control_v1 we edit its own setting and ask it to reload. The edit is
-- an atomic replace (write a sibling, rename over the target) so a reader never
-- sees a half-written file, and the content is spliced as text so the user's
-- comments and key order survive.
local function apply_temperature(kelvin, now_s)
  local text = noctalia.readFile(SETTINGS_PATH)
  if text == nil then
    log("colortemp: cannot read " .. SETTINGS_PATH)
    return
  end
  local new_text, changed = colortemp.splice(text, kelvin)
  if not changed then
    -- Already correct; record it so we stop reconsidering until the ambient moves.
    S.applied_k = kelvin
    S.last_temp_s = now_s
    return
  end
  local tmp = SETTINGS_PATH .. ".als-brightness.tmp"
  if not noctalia.writeFile(tmp, new_text) then
    log("colortemp: cannot write " .. tmp)
    return
  end
  if not noctalia.renameFile(tmp, SETTINGS_PATH) then
    log("colortemp: cannot replace " .. SETTINGS_PATH)
    return
  end
  noctalia.runAsync({ "noctalia", "msg", "config-reload" }, nil, 8000)
  S.applied_k = kelvin
  S.last_temp_s = now_s
  log(string.format("colortemp: applied %dK", math.floor(kelvin)))
end

-- ── the tick ─────────────────────────────────────────────────────────────────
local ticks = 0
noctalia.setUpdateInterval(1000)

function update()
  ticks = ticks + 1
  local now_ms = noctalia.nowMs()
  local dt = S.last_ms and (now_ms - S.last_ms) / 1000.0 or 1.0
  S.last_ms = now_ms
  if dt <= 0 then dt = 1.0 end
  -- The policy module works in SECONDS (see policy.override_expired); the host
  -- clock is in milliseconds. Convert once, here, and never pass raw ms down.
  local now_s = now_ms / 1000.0

  if not ENABLED then
    if S.last_reason ~= "disabled" then
      S.last_reason = "disabled"
      log("suspended: disabled by setting")
    end
    return
  end

  local raw = read_num(ALS_RAW)
  local observed = policy.percent_of(read_num(BL_CUR), read_num(BL_MAX))
  if raw == nil then return end

  if ticks % 60 == 0 then
    log(string.format("heartbeat raw=%d stab=%s last=%s observed=%s idle=%s locked=%s curve=%s",
      raw,
      S.log and string.format("%.3f", S.log) or "nil",
      S.last_written and string.format("%.1f", S.last_written) or "nil",
      observed and string.format("%.1f", observed) or "nil",
      tostring(S.idle), tostring(S.locked), CURVE_SOURCE))
  end

  -- A change we did not command, while awake, is the user taking over.
  -- Crucially this is skipped while idle: the 30% idle dim is authored policy,
  -- not a preference, and must never be learned as one.
  --
  -- Only the FIRST detection records an override. Re-recording on every tick would
  -- move the anchor and reset the timeout each second, so the window could never
  -- expire.
  if not S.idle and S.last_written ~= nil and S.override == nil
     and policy.is_manual_change(S.last_written, observed, CFG) then
    S.override = { raw = raw, percent = observed, at = now_s }
    log(string.format("user override recorded: observed=%.1f%% raw=%d", observed, raw))
    record_observation(raw, observed, now_s)
  end

  poll_locked(ticks)
  save_profile(now_s, false)

  local override_active = S.override ~= nil
    and not policy.override_expired(S.override, raw, now_s, CFG)
  if S.override ~= nil and not override_active then
    S.override = nil
    -- Re-baseline from wherever the user left the panel. Without this the next
    -- tick would compare against a stale last_written and immediately detect a
    -- brand-new override, so the adapter would never resume.
    S.last_written = observed
    log(string.format("override expired at raw=%d, re-baselined at %s",
      raw, observed and string.format("%.1f%%", observed) or "nil"))
  end

  local ok, reason = policy.guard({
    dpms = read_str(DPMS),
    lid_closed = (read_str(LID) or ""):find("closed") ~= nil,
    idle_engaged = S.idle,
    locked = S.locked,
    override_active = override_active,
  })

  if not ok then
    if S.last_reason ~= reason then
      S.last_reason = reason
      log("suspended: " .. reason)
    end
    return
  end

  if S.last_reason ~= "ok" then
    S.last_reason = "ok"
    log("resumed: adapting")
  end

  -- Stabilise first, then map, then rate limit: each stage is a separate pure
  -- function so the ordering is explicit and tested.
  S.log = policy.stabilize(S.log, raw, dt, CFG)
  local target = policy.clamp(curve.eval(ACTIVE_BR, S.log) or CFG.min_percent, CFG)
  local commanded = policy.slew(S.last_written, target, dt, CFG)

  if policy.should_write(S.last_written, commanded, CFG) then
    log(string.format("write: raw=%d target=%.1f commanded=%.1f (was %s) via %s",
      raw, target, commanded,
      S.last_written and string.format("%.1f", S.last_written) or "nil",
      CURVE_SOURCE))
    write_percent(commanded)
  end

  -- Colour temperature rides on the same guards: it only acts when brightness
  -- would, so a dimmed, locked or overridden session is left alone too. The
  -- learned profile deliberately does not touch it -- there is no user signal to
  -- learn a temperature preference from.
  if COLORTEMP then
    local ambient_k = read_num(ALS_CT)
    if ambient_k ~= nil and ambient_k > 0 then
      local mapped = curve.eval(CURVE_TEMP, ambient_k)
      local target_k = colortemp.clamp_k(mapped, colortemp.MAP_DEFAULTS)
      if target_k ~= nil
         and colortemp.should_apply(S.applied_k, target_k, S.last_temp_s, now_s) then
        apply_temperature(target_k, now_s)
      end
    end
  end
end

-- ── hooks ────────────────────────────────────────────────────────────────────
-- The idle chain is an explicit handshake, because logind IdleHint is never set on
-- this setup and DPMS only flips at the 70 s screen-off, leaving a ~20 s window
-- where the panel is deliberately dimmed and still DPMS-On. The idle behaviour in
-- ~/.config/noctalia/config.toml therefore emits these events (see docs/DESIGN.md,
-- "idle handshake").
function onIpc(event, _payload)
  if event == "idle-engaged" then
    S.idle = true
    log("idle engaged")
  elseif event == "idle-released" then
    S.idle = false
    -- Re-baseline from whatever brightnessctl -r just restored, so the restore is
    -- never mistaken for a user override.
    S.override = nil
    S.last_written = policy.percent_of(read_num(BL_CUR), read_num(BL_MAX))
    S.log = nil
    log(string.format("idle released, re-baselined at %s",
      S.last_written and string.format("%.1f%%", S.last_written) or "nil"))
  elseif event == "user-adjusted" then
    if S.idle then
      -- The 30% idle dim is authored policy, not a preference, and while it is in
      -- force the panel is not showing what the owner asked for. Recording here
      -- would file the dim as their preferred brightness -- exactly the mistake
      -- the idle handshake exists to prevent. This was caught on hardware: with
      -- the session idle, an injected user-adjusted event wrote 30% into the
      -- profile as a learned value.
      --
      -- Swallowing the event is safe: idle-release re-baselines from whatever
      -- brightnessctl -r restored, and the tick picks up any genuine change
      -- afterwards.
      log("user-adjusted ignored while idle (the dim is not a preference)")
      return
    end
    local raw = read_num(ALS_RAW) or 0
    local percent = policy.percent_of(read_num(BL_CUR), read_num(BL_MAX)) or 0
    local now_s = noctalia.nowMs() / 1000.0
    S.override = { raw = raw, percent = percent, at = now_s }
    log("user override via keybinding")
    -- The definitive signal is also the best observation: the owner has told us
    -- exactly where the ambient was and what they wanted.
    record_observation(raw, percent, now_s)
    save_profile(now_s, true)
  else
    log("unknown ipc event: " .. tostring(event))
  end
end

function onConfigChanged()
  reload()
  log("config changed; curves rebuilt, now using " .. CURVE_SOURCE)
end

-- ── start ────────────────────────────────────────────────────────────────────
resolve_backlight()
load_profile()
reload()

log("service starting: connector=" .. tostring(CONNECTOR)
  .. " brightness=" .. tostring(BL_CUR)
  .. " observations=" .. tostring(#PROF.observations))
