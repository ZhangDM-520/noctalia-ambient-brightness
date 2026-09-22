--!nonstrict
-- Emits the code-side curve defaults in a canonical "setting<TAB>key<TAB>node"
-- form so run-tests.sh can diff them against the manifest defaults in plugin.toml.
--
-- Not a test suite: it always prints and always exits 0. It exists because the
-- manifest default (what the settings page shows) and the code default (what the
-- service falls back to) must be the same table, and a silent divergence would mean
-- the number you can see is not the number being used.
--
-- Both the keys and the values are compared. The keys are load-bearing: the editor
-- sorts rows by key as text, so a key that stops being zero-padded silently
-- reorders the curve on screen.
local curve = require("../als-brightness/curve")

local function emit(settingKey, defaults)
  local keys = {}
  for k in pairs(defaults) do keys[#keys + 1] = k end
  table.sort(keys)
  for _, k in ipairs(keys) do
    print(string.format("%s\t%s\t%s", settingKey, k, defaults[k]))
  end
end

emit("curve_brightness", curve.DEFAULT_BRIGHTNESS)
emit("curve_temperature", curve.DEFAULT_TEMPERATURE)

-- The 20 threshold sliders: key, default, min, max, step. The windows come from
-- curve.threshold_window -- the same function the learning clamps to -- so the
-- manifest literals cannot drift from it silently. %g matches Python's str() for
-- these integral values.
local function emit_thresholds(prefix, kind, defaults)
  for i = 1, #defaults do
    local lo, hi, step = curve.threshold_window(kind, i)
    print(string.format("%s_%02d\t%g\t%g\t%g\t%g", prefix, i, defaults[i], lo, hi, step))
  end
end

emit_thresholds("thr_brightness", "brightness", curve.DEFAULT_BRIGHTNESS_X)
emit_thresholds("thr_temperature", "temperature", curve.DEFAULT_TEMPERATURE_X)
