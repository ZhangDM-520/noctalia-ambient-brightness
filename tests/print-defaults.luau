--!nonstrict
-- Emits the expected settings surface in canonical "kind<TAB>..." rows so
-- run-tests.sh can diff it against the shipped copies.
--
-- Not a test suite: it always prints and always exits 0. The expectations all
-- come from als-brightness/settings_spec.luau, which derives them from the
-- code constants; run-tests.sh ("settings surface agrees") flattens
-- plugin.toml + translations/en.json with python3 into the same row shapes and
-- diffs the two streams. A silent divergence would mean the number the settings
-- page shows is not the number in use, or that the row text promises an output
-- the node no longer produces.
--
-- Row shapes (see settings_spec.surface_rows):
--   map   <setting key> <map key> <reading:target>
--   thr   <setting key> <default> <min> <max> <step>
--   pct   <setting key> <default>
--   text  <setting key> <label> <description>
local spec = require("../als-brightness/settings_spec")

for _, row in ipairs(spec.surface_rows()) do
  print(row)
end
