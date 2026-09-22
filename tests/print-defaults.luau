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
