--!nonstrict
-- Tests for als-brightness/settings_spec.luau.  Run from the repo root:
--     luau tests/settings_spec.test.luau
-- Pure: code constants go in, row strings come out. No host API, no file reads.
--
-- What is guarded here is the DERIVATION -- the number spelling, the bare-title
-- rule, the description templates and the canonical row shapes. The other half
-- of the drift guard is cross-file: run-tests.sh flattens plugin.toml +
-- translations/en.json and diffs them against spec.surface_rows(), so a value
-- that moves in curve.luau turns the suite red until the shipped copies follow.
--
-- The cases below cover the historical bug surfaces of the settings surface:
--   * PROSE drift -- the "-> 5940K" / "-> 70%" numbers in en.json descriptions
--     were never checked (run-tests.sh diffed only the 40 numeric rows);
--   * bare titles -- a value in a settings-row title is a static string and
--     goes stale on the first slider move (docs/MEMORY.md project conventions);
--   * row shape -- the drift check is a line diff, so one wrong column count
--     would compare unrelated fields and could still "match".

local spec = require("../als-brightness/settings_spec")
local curve = require("../als-brightness/curve")

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

-- ── number spelling ──────────────────────────────────────────────────────────
-- %g, never a trailing ".0": these strings are diffed against TOML literals
-- and glued into prose ("-> 70%"), so the spelling is part of the contract.

do
  check("70 spells as 70", spec.format_number(70), "70")
  check("100 spells as 100", spec.format_number(100), "100")
  check("20.8 spells as 20.8", spec.format_number(20.8), "20.8")
  check("63.4 spells as 63.4", spec.format_number(63.4), "63.4")
  check("5100 spells as 5100", spec.format_number(5100), "5100")
  check("16384 spells as 16384", spec.format_number(16384), "16384")
  check("0 spells as 0", spec.format_number(0), "0")
  check("0.5 spells as 0.5", spec.format_number(0.5), "0.5")
end

-- ── titles ───────────────────────────────────────────────────────────────────
-- Bare node ids, exactly as the owner named them (2026-09-22): the row title
-- must never carry the output value or any other number that can go stale.

do
  check("brightness node 1 title", spec.node_label("brightness", 1), "Node 1")
  check("brightness node 10 title", spec.node_label("brightness", 10), "Node 10")
  check("temperature node 1 title", spec.node_label("temperature", 1), "Temp node 1")
  check("temperature node 8 title", spec.node_label("temperature", 8), "Temp node 8")

  for _, kind in ipairs({ "brightness", "temperature" }) do
    local ys = kind == "brightness" and curve.FIXED_BRIGHTNESS_Y or curve.FIXED_TEMPERATURE_Y
    for i = 1, #ys do
      local label = spec.node_label(kind, i)
      check(kind .. " node " .. i .. " title matches its index exactly",
        label:find(tostring(i), 1, true) ~= nil, true)
      check_true(kind .. " node " .. i .. " title carries no mapping arrow",
        label:find("->", 1, true) == nil)
      check_true(kind .. " node " .. i .. " title carries no unit",
        label:find("K", 1, true) == nil and label:find("%", 1, true) == nil)
    end
  end
end

-- ── descriptions: the prose value must equal the constant ────────────────────

do
  -- The two rows named when this drift class was found: the description states
  -- the node's FIXED output, so both strings are derivable and checkable.
  check("temp node 7 description", spec.node_description("temperature", 7),
    "sensor ambient temp mapped -> 5940K")
  check("brightness node 6 description", spec.node_description("brightness", 6),
    "sensor lightness counts mapped -> 70%")

  for _, kind in ipairs({ "brightness", "temperature" }) do
    local ys = kind == "brightness" and curve.FIXED_BRIGHTNESS_Y or curve.FIXED_TEMPERATURE_Y
    for i = 1, #ys do
      local description = spec.node_description(kind, i)
      local want = kind == "brightness"
        and ("sensor lightness counts mapped -> " .. spec.format_number(ys[i]) .. "%")
        or ("sensor ambient temp mapped -> " .. spec.format_number(ys[i]) .. "K")
      check(kind .. " node " .. i .. " description states its fixed output",
        description, want)
    end
  end
end

-- ── canonical rows ───────────────────────────────────────────────────────────
-- Shapes and counts the python flatten in run-tests.sh must reproduce.

do
  local rows = spec.surface_rows()
  check("62 surface rows (20 map + 20 thr + 2 pct + 20 text)", #rows, 62)

  local kinds = { map = 0, thr = 0, pct = 0, text = 0 }
  local seen = {}
  for _, row in ipairs(rows) do
    local kind = row:match("^([a-z]+)\t")
    if kinds[kind] ~= nil then kinds[kind] = kinds[kind] + 1 end
    check_true("row is unique: " .. row, seen[row] == nil)
    seen[row] = true
  end
  check("20 map rows", kinds.map, 20)
  check("20 thr rows", kinds.thr, 20)
  check("2 pct rows", kinds.pct, 2)
  check("20 text rows", kinds.text, 20)

  -- Column counts: the check is a line diff, so a wrong shape would compare
  -- unrelated fields and could still match by accident.
  for _, row in ipairs(rows) do
    local kind = row:match("^([a-z]+)\t")
    local want_columns = ({ map = 4, thr = 6, pct = 3, text = 4 })[kind]
    local columns = 1
    for _ in row:gmatch("\t") do columns = columns + 1 end
    check_true("row shape " .. kind .. ": " .. row, want_columns ~= nil and columns == want_columns)
  end

  -- Sorted: both sides of the diff share one canonical order.
  for i = 2, #rows do
    check_true("rows are sorted at " .. i, rows[i - 1] < rows[i])
  end

end

do
  local rows = spec.surface_rows()
  local wanted = {
    ["map\tcurve_temperature\t05000\t5000:5940"] = true,
    ["thr\tthr_brightness_01\t1\t0\t3\t1"] = true,
    ["pct\tmin_percent\t15"] = true,
    ["text\tthr_temperature_07\tTemp node 7\tsensor ambient temp mapped -> 5940K"] = true,
    ["text\tthr_brightness_06\tNode 6\tsensor lightness counts mapped -> 70%"] = true,
  }
  local found = {}
  for _, row in ipairs(rows) do
    if wanted[row] then found[row] = true end
  end
  for row in pairs(wanted) do
    check_true("representative row ships: " .. row, found[row] == true)
  end

  -- Determinism: two calls must agree exactly (the diff has one canonical form).
  local again = spec.surface_rows()
  check("two calls emit the same rows", #again, #rows)
  local same = true
  for i = 1, #rows do
    if again[i] ~= rows[i] then same = false end
  end
  check_true("two calls emit the same strings", same)
end

-- ── map rows: the key and the value's reading are one number spelled twice ───
-- "00185" = "185:70" carries 185 twice, and the value always wins when they
-- disagree (curve.parse_nodes). The key is load-bearing only for row ORDER, so
-- a disagreement would silently move the node to a different reading than its
-- row sorts under. Self-consistency is checked once on the authority here; the
-- plugin.toml copy is transitively covered by the surface diff.

do
  for _, row in ipairs(spec.surface_rows()) do
    local map_key, value = row:match("^map\t[^\t]+\t([^\t]+)\t([^\t]+)$")
    if map_key then
      local reading = value:match("^(%d+):") or ""
      check_true("map key " .. map_key .. " is zero-padded to sort numerically",
        #map_key == 5)
      check("map key " .. map_key .. " agrees with its value's reading",
        tonumber(map_key), tonumber(reading))
    end
  end
end

print(string.format("\n%d checks, %d failure(s)", checks, failures))
if failures > 0 then
  error(string.format("%d check(s) failed", failures), 0)
end
