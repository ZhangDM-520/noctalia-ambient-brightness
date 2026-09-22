--!nonstrict
-- Noctalia [[service]] entry point for ambient-light adaptive panel brightness.
--
-- This file is the only place that touches hardware or the shell. All decision
-- logic lives in src/policy.luau, which is pure and unit-tested, so the parts
-- that can be reasoned about offline are tested offline and this file stays a
-- thin, boring shim.
--
-- Design notes and the measurements behind every constant: docs/DESIGN.md.

local policy = require("./policy.luau")
local colortemp = require("./colortemp.luau")

-- ── paths ────────────────────────────────────────────────────────────────────
local ALS_RAW = "/sys/bus/iio/devices/iio:device2/in_illuminance_raw"
local ALS_CT  = "/sys/bus/iio/devices/iio:device2/in_colortemp_raw"
local DPMS    = "/sys/class/drm/card1-eDP-1/dpms"
local LID     = "/proc/acpi/button/lid/LID/state"
local BL_DIR  = "/sys/class/backlight/"
local SETTINGS_PATH = (noctalia.getenv("HOME") or "/home/zhangdm")
  .. "/.local/state/noctalia/settings.toml"

-- ── config (declared in plugin.toml) ──────────────────────────────────────────
local function setting(key, fallback)
  local value = noctalia.getConfig(key)
  if value == nil or value == "" then return fallback end
  return value
end

local CFG = {}
for k, v in pairs(policy.DEFAULTS) do CFG[k] = v end

local CONNECTOR   = setting("connector", "eDP-1")
local REF_RAW     = tonumber(setting("reference_raw", "185")) or 185
local REF_PERCENT = tonumber(setting("reference_percent", "70")) or 70
local ENABLED     = setting("enabled", true)
local COLORTEMP   = setting("colortemp", false)

-- Re-fit the whole anchor set around the owner's reference point. The curve is
-- expressed as "so many percentage points per decade of ambient light", which
-- is what keeps it meaningful without trusting the sensor's absolute lux
-- calibration (which is unverified -- a phone torch reads only 1665 lux).
do
  local points_per_decade = 25
  local log_ref = policy.log_of(REF_RAW)
  local anchors = {}
  for _, raw in ipairs({ 1, 10, 46, 185, 1000, 4000, 16384 }) do
    local pct = REF_PERCENT + points_per_decade * (policy.log_of(raw) - log_ref)
    anchors[#anchors + 1] = { raw, pct }
  end
  CFG.anchors = anchors
  CFG.min_percent = tonumber(setting("min_percent", "15")) or 15
  CFG.max_percent = tonumber(setting("max_percent", "100")) or 100
end

-- ── backlight device discovery ───────────────────────────────────────────────
local BL_CUR, BL_MAX
do
  local forced = setting("backlight", "")
  local name = forced
  if name == "" then
    local entries = noctalia.listDir(BL_DIR) or {}
    name = entries[1] or "amdgpu_bl1"
  end
  BL_CUR = BL_DIR .. name .. "/brightness"
  BL_MAX = BL_DIR .. name .. "/max_brightness"
end

-- ── logging ──────────────────────────────────────────────────────────────────
local LOG_PATH
do
  local ok, dir = pcall(noctalia.pluginDataDir)
  LOG_PATH = (ok and type(dir) == "string" and dir or "/tmp") .. "/als-brightness.log"
end

-- writeFile replaces the file, so keep a bounded ring buffer in memory and
-- rewrite it. That gives real history without needing an append mode.
local LOG_LINES = {}
local LOG_KEEP = 200

local function log(line)
  LOG_LINES[#LOG_LINES + 1] = line
  while #LOG_LINES > LOG_KEEP do
    table.remove(LOG_LINES, 1)
  end
  noctalia.writeFile(LOG_PATH, table.concat(LOG_LINES, "\n") .. "\n")
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
-- `noctalia msg status` is the only way to learn the lock state, and shelling
-- out every second would be wasteful, so it is sampled on its own cadence.
-- RunAsync with an argv table needs plugin_api 24, which is why the manifest
-- declares it.
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
  -- Record what we asked for, not what we read back: the readback path has its
  -- own transfer curve (actual ~= requested), but `brightness` is the value
  -- both brightnessctl and Noctalia agree on, and it is what we compare against.
  S.last_written = pct
end

-- ── colour temperature ───────────────────────────────────────────────────────
-- Noctalia owns the gamma LUT, so rather than opening a second writer on
-- zwlr_gamma_control_v1 we edit its own setting and ask it to reload. The edit
-- is an atomic replace (write a sibling, rename over the target) so a reader
-- never sees a half-written file, and the content is spliced as text so the
-- user's comments and key order survive.
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
    log(string.format("heartbeat raw=%d stab=%s last=%s observed=%s idle=%s locked=%s",
      raw,
      S.log and string.format("%.3f", S.log) or "nil",
      S.last_written and string.format("%.1f", S.last_written) or "nil",
      observed and string.format("%.1f", observed) or "nil",
      tostring(S.idle), tostring(S.locked)))
  end

  -- A change we did not command, while awake, is the user taking over.
  -- Crucially this is skipped while idle: the 30% idle dim is authored policy,
  -- not a preference, and must never be learned as one.
  --
  -- Only the FIRST detection records an override. Re-recording on every tick
  -- would move the anchor and reset the timeout each second, so the window
  -- could never expire.
  if not S.idle and S.last_written ~= nil and S.override == nil
     and policy.is_manual_change(S.last_written, observed, CFG) then
    S.override = { raw = raw, percent = observed, at = now_s }
    log(string.format("user override recorded: observed=%.1f%% raw=%d", observed, raw))
  end

  poll_locked(ticks)

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
  local target = policy.percent_for_log(S.log, CFG)
  local commanded = policy.slew(S.last_written, target, dt, CFG)

  if policy.should_write(S.last_written, commanded, CFG) then
    log(string.format("write: raw=%d target=%.1f commanded=%.1f (was %s)",
      raw, target, commanded, S.last_written and string.format("%.1f", S.last_written) or "nil"))
    write_percent(commanded)
  end

  -- Colour temperature rides on the same guards: it only acts when brightness
  -- would, so a dimmed, locked or overridden session is left alone too.
  if COLORTEMP then
    local ambient_k = read_num(ALS_CT)
    if ambient_k ~= nil and ambient_k > 0 then
      local target_k = colortemp.panel_k(ambient_k)
      if colortemp.should_apply(S.applied_k, target_k, S.last_temp_s, now_s) then
        apply_temperature(target_k, now_s)
      end
    end
  end
end

-- ── hooks ────────────────────────────────────────────────────────────────────
-- The idle chain is an explicit handshake, because logind IdleHint is never set
-- on this setup and DPMS only flips at the 70 s screen-off, leaving a ~20 s
-- window where the panel is deliberately dimmed and still DPMS-On. The idle
-- behaviour in ~/.config/noctalia/config.toml therefore emits these events (see
-- docs/DESIGN.md, "idle handshake").
function onIpc(event, _payload)
  if event == "idle-engaged" then
    S.idle = true
    log("idle engaged")
  elseif event == "idle-released" then
    S.idle = false
    -- Re-baseline from whatever brightnessctl -r just restored, so the restore
    -- is never mistaken for a user override.
    S.override = nil
    S.last_written = policy.percent_of(read_num(BL_CUR), read_num(BL_MAX))
    S.log = nil
    log(string.format("idle released, re-baselined at %s",
      S.last_written and string.format("%.1f%%", S.last_written) or "nil"))
  elseif event == "user-adjusted" then
    local raw = read_num(ALS_RAW) or 0
    S.override = { raw = raw, percent = policy.percent_of(read_num(BL_CUR), read_num(BL_MAX)) or 0,
                   at = noctalia.nowMs() / 1000.0 }
    log("user override via keybinding")
  else
    log("unknown ipc event: " .. tostring(event))
  end
end

function onConfigChanged()
  log("config changed")
end

log("service starting: connector=" .. CONNECTOR
  .. " reference=" .. REF_RAW .. "raw/" .. REF_PERCENT .. "%")
