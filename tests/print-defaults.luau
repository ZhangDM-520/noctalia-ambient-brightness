--!nonstrict
-- Emits the code-side curve defaults in a canonical "key<TAB>node" form so
-- run-tests.sh can diff them against the manifest defaults in plugin.toml.
--
-- Not a test suite: it always prints and always exits 0. It exists because the
-- manifest default (what the settings page shows) and the code default (what the
-- service falls back to) must be the same list, and a silent divergence would mean
-- the number you can see is not the number being used.
local curve = require("../als-brightness/curve")

for _, value in ipairs(curve.DEFAULT_BRIGHTNESS) do
  print(string.format("curve_brightness\t%s", value))
end
for _, value in ipairs(curve.DEFAULT_TEMPERATURE) do
  print(string.format("curve_temperature\t%s", value))
end
