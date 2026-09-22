--!nonstrict
-- Tests for als-brightness/hardware.luau.  Run from the repo root:
--     luau tests/hardware.test.luau
-- The environment is injected, so every test is a fake machine: no sysfs, no
-- Noctalia, no hardware needed.

local hardware = require("../als-brightness/hardware")

local failures = 0
local checks = 0

local function check(label, got, want)
  checks = checks + 1
  if got ~= want then
    failures = failures + 1
    print(string.format("FAIL  %s\n        got  %s\n        want %s",
      label, tostring(got), tostring(want)))
  end
end

local function check_true(label, got)
  check(label, got and true or false, true)
end

--- A fake machine: files maps a path to its contents, dirs maps a directory to
--- its entry names, outputs/getenv feed the Noctalia-side queries.
local function machine(opts)
  opts = opts or {}
  local files, dirs = opts.files or {}, opts.dirs or {}
  return {
    listDir = function(path)
      local entries = dirs[path]
      if entries == nil then return nil, "no such directory" end
      local out = {}
      for _, name in ipairs(entries) do out[#out + 1] = name end
      return out
    end,
    readFile = function(path)
      local value = files[path]
      if value == nil then return nil, "no such file" end
      return value
    end,
    outputs = function() return opts.outputs or {} end,
    getenv = function(name)
      if name == "HOME" then
        if opts.home == nil or opts.home == false then return nil end
        return opts.home
      end
      return nil
    end,
  }
end

local IIO = "/sys/bus/iio/devices/"
local BL = "/sys/class/backlight/"
local DRM = "/sys/class/drm/"
local LID = "/proc/acpi/button/lid/"

-- A complete, healthy machine: sensor, colour-temp, backlight, connector with
-- DPMS, lid switch, HOME. Every other test takes pieces away from this.
local function healthy(overrides)
  overrides = overrides or {}
  local files = {
    [IIO .. "iio:device2/in_illuminance_raw"] = "1234",
    [IIO .. "iio:device2/in_colortemp_raw"] = "5000",
    [IIO .. "iio:device2/name"] = "als\n",
    [BL .. "amdgpu_bl1/brightness"] = "100",
    [BL .. "amdgpu_bl1/max_brightness"] = "255",
    [DRM .. "card1-eDP-1/dpms"] = "On\n",
    [LID .. "LID/state"] = "open\n",
  }
  local dirs = {
    [IIO] = { "iio:device2" },
    [BL] = { "amdgpu_bl1" },
    [DRM] = { "card0", "card1-eDP-1", "renderD128" },
    [LID] = { "LID" },
  }
  for path, value in pairs(overrides.files or {}) do
    if value == false then files[path] = nil else files[path] = value end
  end
  for path, entries in pairs(overrides.dirs or {}) do
    if entries == false then dirs[path] = nil else dirs[path] = entries end
  end
  return machine({
    files = files, dirs = dirs,
    outputs = overrides.outputs or { { name = "eDP-1", focused = true } },
    home = overrides.home == nil and "/home/alice" or overrides.home,
  })
end

-- ── the healthy machine ─────────────────────────────────────────────────────
do
  local r = hardware.discover(healthy(), {})
  check("healthy: no required hardware missing", #r.required_missing, 0)
  check("healthy: nothing degraded", #r.degraded, 0)
  check("healthy: als path", r.paths.als_raw, IIO .. "iio:device2/in_illuminance_raw")
  check("healthy: colortemp path", r.paths.als_ct, IIO .. "iio:device2/in_colortemp_raw")
  check("healthy: backlight cur", r.paths.bl_cur, BL .. "amdgpu_bl1/brightness")
  check("healthy: backlight max", r.paths.bl_max, BL .. "amdgpu_bl1/max_brightness")
  check("healthy: dpms", r.paths.dpms, DRM .. "card1-eDP-1/dpms")
  check("healthy: lid", r.paths.lid, LID .. "LID/state")
  check("healthy: settings path", r.paths.settings_path,
    "/home/alice/.local/state/noctalia/settings.toml")
  check("healthy: connector (focused)", r.devices.connector, "eDP-1")
  check_true("healthy: als device named for the log", r.devices.als:find("iio:device2") ~= nil)
  check_true("healthy: als sensor name in the log", r.devices.als:find("als") ~= nil)
end

-- ── ambient sensor discovery ────────────────────────────────────────────────
do
  local r = hardware.discover(healthy({ dirs = { [IIO] = false } }), {})
  check("no iio at all: one required reason", #r.required_missing, 1)
  check_true("no iio at all: reason names the sensor need",
    r.required_missing[1]:find("ambient light sensor") ~= nil)
  check("no iio at all: als path nil", r.paths.als_raw, nil)
end

do
  local m = healthy({ dirs = { [IIO] = { "iio:device0" } }, files = {
    [IIO .. "iio:device2/in_illuminance_raw"] = false,
    [IIO .. "iio:device2/in_colortemp_raw"] = false,
    [IIO .. "iio:device2/name"] = false,
    [IIO .. "iio:device0/in_illuminance_input"] = "42\n",
    [IIO .. "iio:device0/name"] = "some-processed-sensor\n",
  }})
  local r = hardware.discover(m, {})
  check("input fallback: picks in_illuminance_input", r.paths.als_raw,
    IIO .. "iio:device0/in_illuminance_input")
  check("input fallback: no required reasons", #r.required_missing, 0)
end

do
  -- raw beats input even when input lives on the lower-numbered device: the
  -- shipped curve was calibrated against raw counts.
  local m = healthy({ dirs = { [IIO] = { "iio:device0", "iio:device3" } }, files = {
    [IIO .. "iio:device2/in_illuminance_raw"] = false,
    [IIO .. "iio:device2/in_colortemp_raw"] = false,
    [IIO .. "iio:device2/name"] = false,
    [IIO .. "iio:device0/in_illuminance_input"] = "7\n",
    [IIO .. "iio:device0/name"] = "processed\n",
    [IIO .. "iio:device3/in_illuminance_raw"] = "9\n",
    [IIO .. "iio:device3/name"] = "raw-sensor\n",
  }})
  local r = hardware.discover(m, {})
  check("raw preferred: picks device3 raw", r.paths.als_raw,
    IIO .. "iio:device3/in_illuminance_raw")
end

-- ── backlight ───────────────────────────────────────────────────────────────
do
  local r = hardware.discover(healthy({ dirs = { [BL] = {} } }), {})
  check_true("no backlight: required",
    r.required_missing[1] and r.required_missing[1]:find("no backlight device") ~= nil)
  check("no backlight: cur nil", r.paths.bl_cur, nil)
end

do
  local r = hardware.discover(healthy(), { backlight = "not_here" })
  check_true("forced-but-absent backlight: required names it",
    (#r.required_missing == 1
      and r.required_missing[1]:find("'not_here'", 1, true) ~= nil))
end

do
  local r = hardware.discover(healthy({ dirs = { [BL] = { "amdgpu_bl1", "intel_backlight" } },
    files = {
      [BL .. "intel_backlight/brightness"] = "128",
      [BL .. "intel_backlight/max_brightness"] = "1000",
    } }), { backlight = "intel_backlight" })
  check("forced backlight present: honoured", r.paths.bl_cur,
    BL .. "intel_backlight/brightness")
  check("forced backlight present: no required reasons", #r.required_missing, 0)
end

do
  local r = hardware.discover(healthy({ files = { [BL .. "amdgpu_bl1/brightness"] = false } }), {})
  check_true("unreadable backlight: required says so",
    (#r.required_missing == 1
      and r.required_missing[1]:find("not readable") ~= nil))
  check("unreadable backlight: path dropped", r.paths.bl_cur, nil)
end

-- ── connector ───────────────────────────────────────────────────────────────
do
  local r = hardware.discover(healthy(), { connector = "HDMI-A-1" })
  check_true("forced-but-absent connector: required names it",
    (#r.required_missing == 1
      and r.required_missing[1]:find("'HDMI-A-1'", 1, true) ~= nil))
end

do
  local r = hardware.discover(healthy({ outputs = {} }), {})
  check_true("no outputs reported: required",
    (#r.required_missing >= 1
      and r.required_missing[1]:find("no outputs") ~= nil))
end

do
  -- auto mode, nothing focused: alphabetically first, never a guess
  local r = hardware.discover(healthy({ outputs = {
    { name = "HDMI-A-1" }, { name = "eDP-1" } } }), {})
  check("auto connector: sorted pick", r.devices.connector, "HDMI-A-1")
end

-- ── optional pieces degrade, never block ────────────────────────────────────
do
  local r = hardware.discover(healthy({ dirs = { [LID] = false }, files = {
    [LID .. "LID/state"] = false } }), {})
  check("no lid: not required", #r.required_missing, 0)
  check_true("no lid: degraded says so", r.degraded[1] and r.degraded[1]:find("lid") ~= nil)
  check("no lid: path nil", r.paths.lid, nil)
end

do
  local r = hardware.discover(healthy({ files = { [DRM .. "card1-eDP-1/dpms"] = false } }), {})
  check("no dpms: not required", #r.required_missing, 0)
  check_true("no dpms: degraded says so",
    r.degraded[1] and r.degraded[1]:find("DPMS") ~= nil)
  check("no dpms: path nil", r.paths.dpms, nil)
end

do
  local r = hardware.discover(healthy({ home = false }), {})
  check("HOME unset: not required", #r.required_missing, 0)
  check_true("HOME unset: degraded says so",
    r.degraded[1] and r.degraded[1]:find("HOME") ~= nil)
  check("HOME unset: settings path nil", r.paths.settings_path, nil)
end

do
  local r = hardware.discover(healthy({ dirs = { [IIO] = { "iio:device2" } }, files = {
    [IIO .. "iio:device2/in_colortemp_raw"] = false,
  }}), {})
  check("no colortemp sensor: not required", #r.required_missing, 0)
  check_true("no colortemp sensor: degraded says so",
    r.degraded[1] and r.degraded[1]:find("colour-temp", 1, true) ~= nil)
  check("no colortemp sensor: path nil", r.paths.als_ct, nil)
end

print(string.format("%d checks, %d failure(s)", checks, failures))
if failures > 0 then
  error(string.format("%d check(s) failed", failures), 0)
end
