--!nonstrict
-- Noctalia [[service]] entry point for ambient-light adaptive panel brightness.
--
-- This file and hardware.luau are the only places that touch hardware, the shell
-- or the filesystem; hardware.luau does it through an injected environment, so a
-- fake machine can replace it in tests. All decision logic lives in pure modules,
-- which run under a bare `luau` and are unit-tested offline:
--
--   hardware.luau   device discovery: every path the service uses, probed at start
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
local hardware = require("./hardware.luau")

-- ── hardware report ─────────────────────────────────────────────────────────
-- Every device path is resolved ONCE by hardware.discover() at start (the start
-- block at the bottom of this file): no path, device number or connector is ever
-- guessed here. Until the probe runs they are nil, and while a required device is
-- missing HW_OK stays false and every entry point returns early.
local ALS_RAW, ALS_CT, DPMS, LID, SETTINGS_PATH
local HW_OK = false
local HW  -- the full discovery report

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

--- The curves arrive as a `string_map` (the in-place-editable shape) or as a
--- `string_list`. A bare string is accepted as a one-row list, so a hand-edited
--- config cannot silently disable a whole curve.
---
--- The emptiness test is `next()`, not `#value`: a map keyed "00185" has no integer
--- keys, so `#value` is 0 for a map of any size and an `#value > 0` guard would
--- throw away every curve the GUI produced.
local function setting_nodes(key, fallback)
  local value = noctalia.getConfig(key)
  if type(value) == "table" then
    if next(value) ~= nil then return value end
    return fallback
  end
  if type(value) == "string" and value ~= "" then return { value } end
  return fallback
end

--- The 20 threshold sliders ("thr_brightness_01".."thr_temperature_10"). Each
--- commits to its own config path, so a GUI edit of one slider never masks its
--- siblings -- which is exactly what the string_map editors do (the host marks
--- the whole map overridden on the first row edit), and why the maps are demoted
--- to advanced fallbacks. Out-of-window values from a hand-edited config are
--- honoured as written; buildNodes repairs whatever would break the
--- interpolation and logs it once.
local function setting_thresholds(prefix, defaults)
  local out = {}
  for i = 1, #defaults do
    out[i] = setting_number(string.format("%s_%02d", prefix, i), defaults[i])
  end
  return out
end

--- Has the owner edited a map away from the shipped default? That decision lives
--- in curve.map_is_custom (Phase 6 precedence): pure, and testable offline.

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

--- Log a line once per run: runtime read failures repeat every tick, and the log
--- is a bounded ring buffer, so a repeating line would evict real history.
local WARNED = {}
local function warn_once(key, line)
  if WARNED[key] then return end
  WARNED[key] = true
  log(line)
end

-- ── config-derived state ─────────────────────────────────────────────────────
local CFG = {}
for k, v in pairs(policy.DEFAULTS) do CFG[k] = v end

local CONNECTOR, ENABLED, COLORTEMP, LEARNING
-- The slider positions (thresholds, raw domain) currently in force, in slider
-- order. Learning seeds from these and drifts them, so promoting a learned value
-- back into the settings page is a bar-for-bar copy.
local THR_BR, THR_TEMP = {}, {}
-- The compiled curves: slider-built by default, the advanced map when edited.
local CURVE_BR, CURVE_TEMP = nil, nil
local COUNT_BR, COUNT_TEMP = 0, 0
local BR_CUSTOM_MAP, TEMP_CUSTOM_MAP = false, false
-- What the tick actually evaluates: the slider curve, optionally with learned
-- threshold nudges layered on (never on a custom map -- see rebuild_active).
local ACTIVE_BR = nil
local LEARNED_NODES = 0
local PROF_CFG_BR = nil
local CURVE_SOURCE = "sliders"

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

--- Learning clamps its nudges into each slider's own window
--- (curve.threshold_window), so a learned threshold can always be copied back
--- into the GUI without being clipped by the slider's own min/max.
local function fit_bounds(kind)
  local lo, hi = {}, {}
  for i = 1, #curve.FIXED_BRIGHTNESS_Y do
    local w_lo, w_hi = curve.threshold_window(kind, i)
    lo[i], hi[i] = w_lo, w_hi
  end
  return { lo = lo, hi = hi }
end

--- What the tick evaluates: the slider-built curve, with learned threshold nudges
--- layered on when learning is on. Outputs never move (they are the fixed
--- constants in curve.luau); only where each node sits does.
---
--- Runs on every observation, so it never logs -- slider build problems are
--- logged once, in reload().
local function rebuild_active()
  LEARNED_NODES = 0
  if BR_CUSTOM_MAP then
    -- A custom map is the power-user override and wins outright. Learning is
    -- suspended on purpose (decision locked): nudging thresholds would silently
    -- fight the curve the owner wrote by hand.
    ACTIVE_BR = CURVE_BR
    CURVE_SOURCE = "map (custom, learning suspended)"
    return
  end

  local xs = THR_BR
  if LEARNING then
    local fitted, counts = profile.fit_thresholds(
      PROF, curve.FIXED_BRIGHTNESS_Y, THR_BR, PROF_CFG_BR)
    xs = fitted
    LEARNED_NODES = profile.learned_nodes(counts)
  end

  local nodes = curve.buildNodes(xs, curve.FIXED_BRIGHTNESS_Y, { map_x = map_brightness_x })
  local built = curve.compile(nodes)
  if built == nil then
    -- Nothing usable: behave exactly as if the toggle were off, so an unusable
    -- profile can never leave the panel unmanaged.
    ACTIVE_BR = CURVE_BR
    CURVE_SOURCE = "sliders (profile not usable yet)"
    return
  end
  ACTIVE_BR = built
  if LEARNING then
    CURVE_SOURCE = string.format("sliders+learned (%d/%d nodes)", LEARNED_NODES, #THR_BR)
  else
    CURVE_SOURCE = "sliders"
  end
end

--- The map path: the owner's rows, parsed exactly as written (Phase 5 and
--- earlier). Used only when the map was edited away from the shipped default.
local function load_curve(key, fallback, map_x, anchor)
  local items = setting_nodes(key, fallback)
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
  local compiled = anchor and curve.with_anchors(nodes) or nodes
  return curve.compile(compiled), #nodes
end

--- The slider path (Phase 6): outputs are the fixed constants in curve.luau and
--- the sliders choose each node's threshold. Build problems (crossing sliders,
--- unusable values) are logged HERE, never in rebuild_active, which runs on
--- every observation.
local function load_slider_curve(key, thresholds, fixed_ys, map_x, anchor)
  local nodes, problems = curve.buildNodes(thresholds, fixed_ys, { map_x = map_x })
  for _, problem in ipairs(problems) do
    log("curve " .. key .. ": " .. problem)
  end
  local compiled = anchor and curve.with_anchors(nodes) or nodes
  return curve.compile(compiled), #nodes
end

local function reload()
  ENABLED = setting_bool("enabled", true)
  COLORTEMP = setting_bool("colortemp", false)
  LEARNING = setting_bool("learning_profile", false)
  -- CONNECTOR comes from the start probe, never from a guess; changing the
  -- setting takes effect on the next plugin restart (hardware is probed once).
  CFG.min_percent = setting_number("min_percent", 15)
  CFG.max_percent = setting_number("max_percent", 100)
  PROF_CFG_BR = fit_bounds("brightness")

  THR_BR = setting_thresholds("thr_brightness", curve.DEFAULT_BRIGHTNESS_X)
  THR_TEMP = setting_thresholds("thr_temperature", curve.DEFAULT_TEMPERATURE_X)

  -- Precedence (Phase 6): the sliders run the curve; the advanced map editors
  -- win only when the owner actually edited them away from the shipped default.
  BR_CUSTOM_MAP = curve.map_is_custom(
    setting_nodes("curve_brightness", curve.DEFAULT_BRIGHTNESS), curve.DEFAULT_BRIGHTNESS)
  TEMP_CUSTOM_MAP = curve.map_is_custom(
    setting_nodes("curve_temperature", curve.DEFAULT_TEMPERATURE), curve.DEFAULT_TEMPERATURE)

  if BR_CUSTOM_MAP then
    CURVE_BR, COUNT_BR = load_curve("curve_brightness", curve.DEFAULT_BRIGHTNESS, map_brightness_x)
  else
    CURVE_BR, COUNT_BR =
      load_slider_curve("curve_brightness", THR_BR, curve.FIXED_BRIGHTNESS_Y, map_brightness_x)
  end
  if TEMP_CUSTOM_MAP then
    CURVE_TEMP, COUNT_TEMP =
      load_curve("curve_temperature", curve.DEFAULT_TEMPERATURE, nil, true)
  else
    CURVE_TEMP, COUNT_TEMP =
      load_slider_curve("curve_temperature", THR_TEMP, curve.FIXED_TEMPERATURE_Y, nil, true)
  end

  if BR_CUSTOM_MAP and LEARNING then
    log("learning suspended: curve_brightness is a custom map (the map wins outright)")
  end

  if CURVE_TEMP then
    log(string.format("temperature curve: %d visible + %d hidden anchor nodes",
      COUNT_TEMP, CURVE_TEMP.n - COUNT_TEMP))
  end

  rebuild_active()

  log(string.format(
    "config: brightness=%d nodes via %s, temperature=%d nodes via %s, learning=%s source=%s",
    COUNT_BR, BR_CUSTOM_MAP and "map" or "sliders",
    COUNT_TEMP, TEMP_CUSTOM_MAP and "map" or "sliders",
    tostring(LEARNING), CURVE_SOURCE))
end

-- Backlight paths come from the start probe (hardware.discover), never guessed.
local BL_CUR, BL_MAX

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
  -- place it needs rebuilding. A custom map suspends learning entirely.
  if LEARNING and not BR_CUSTOM_MAP then rebuild_active() end
end

-- ── colour temperature ───────────────────────────────────────────────────────
-- Noctalia owns the gamma LUT, so rather than opening a second writer on
-- zwlr_gamma_control_v1 we edit its own setting and ask it to reload. The edit is
-- an atomic replace (write a sibling, rename over the target) so a reader never
-- sees a half-written file, and the content is spliced as text so the user's
-- comments and key order survive.
local function apply_temperature(kelvin, now_s)
  if SETTINGS_PATH == nil then
    -- Degraded at the probe (HOME unset): skip, and never guess a path.
    warn_once("settings-path", "colortemp skipped: no settings path (HOME unset)")
    return
  end
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
  if not HW_OK then return end
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
  if raw == nil then
    -- Probed once at start; a later failure skips the write rather than feeding
    -- zeros into the curve. Restart the plugin to re-probe the hardware.
    warn_once("als-read",
      "ambient read failed at " .. tostring(ALS_RAW) .. "; not writing")
    return
  end
  local observed = policy.percent_of(read_num(BL_CUR), read_num(BL_MAX))
  if observed == nil then
    warn_once("bl-read",
      "backlight read failed at " .. tostring(BL_CUR) .. "; not writing")
    return
  end

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
    -- An unavailable guard PASSES (reported as degraded at start); it never
    -- blocks adaptation, or a machine without a DPMS node or lid switch would
    -- never adapt at all.
    dpms = DPMS == nil and "On" or read_str(DPMS),
    lid_closed = LID ~= nil and (read_str(LID) or ""):find("closed") ~= nil,
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
  if not HW_OK then
    warn_once("ipc-while-down", "ipc event '" .. tostring(event) .. "' ignored: hardware unavailable")
    return
  end
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
  if not HW_OK then
    log("config changed; hardware still unavailable -- toggle the plugin to re-probe")
    return
  end
  log("config changed; curves rebuilt, now using " .. CURVE_SOURCE)
end

-- ── start ────────────────────────────────────────────────────────────────────
-- The probe runs FIRST, before the profile, the curves or any tick: hardware
-- availability is decided exactly once, here. Nothing below runs when a required
-- device is missing -- the service idles, says why, and never writes to a panel
-- it cannot see.
HW = hardware.discover(
  { listDir = noctalia.listDir, readFile = noctalia.readFile,
    outputs = noctalia.outputs, getenv = noctalia.getenv },
  { backlight = setting_string("backlight", ""),
    connector = setting_string("connector", "") })

for _, note in ipairs(HW.degraded) do
  log("hardware degraded: " .. note)
end

if #HW.required_missing > 0 then
  for _, reason in ipairs(HW.required_missing) do
    log("hardware unavailable: " .. reason)
  end
  noctalia.notifyError("ALS Brightness: hardware unavailable",
    table.concat(HW.required_missing, "\n"))
  log("service idle: nothing will be written; fix the hardware and toggle the plugin to re-probe")
  return
end
HW_OK = true

ALS_RAW, ALS_CT = HW.paths.als_raw, HW.paths.als_ct
DPMS, LID = HW.paths.dpms, HW.paths.lid
BL_CUR, BL_MAX = HW.paths.bl_cur, HW.paths.bl_max
SETTINGS_PATH = HW.paths.settings_path
CONNECTOR = HW.devices.connector

load_profile()
reload()

log(string.format("hardware: als=%s backlight=%s connector=%s%s%s%s",
  tostring(HW.devices.als), tostring(HW.devices.backlight),
  tostring(HW.devices.connector),
  HW.devices.colortemp and " colortemp=" .. HW.devices.colortemp or "",
  HW.paths.dpms ~= nil and " dpms=" .. HW.paths.dpms or "",
  HW.devices.lid ~= nil and " lid=" .. HW.devices.lid or ""))
log("service starting: connector=" .. tostring(CONNECTOR)
  .. " brightness=" .. tostring(BL_CUR)
  .. " observations=" .. tostring(#PROF.observations))
