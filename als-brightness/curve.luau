--!nonstrict
-- The panel curves: user-owned node lists, smoothed with PCHIP.
--
-- Phase 2 moved the mapping curve out of the code and into configuration, so the
-- owner can hand-tune it in the settings GUI instead of editing Luau. This module
-- is that curve: it parses the node strings, and interpolates between them.
--
-- Interpolation is Fritsch-Carlson monotone cubic Hermite ("PCHIP",
-- SIAM J. Numer. Anal. 17(2), 1980), not a straight line and not a naive cubic:
--
--   * A straight line leaves a derivative discontinuity at every node, so the
--     *rate* of adaptation visibly jumps each time the ambient crosses one.
--   * A naive cubic (Catmull-Rom, natural spline) overshoots. On this curve an
--     overshoot means commanding above 100% or below the floor -- the curve
--     leaves the band the owner drew, which is the one thing it must never do.
--
-- PCHIP fixes both: monotone nodes produce a monotone curve, so the output is
-- always inside [min(y), max(y)] and the max/min clamps are satisfied by
-- construction rather than by clamping. The construction is also local, so moving
-- one node cannot ripple into its neighbours.
--
-- Everything here is pure: no host API, no sysfs, no clock. It runs under a bare
-- `luau` interpreter and is exercised by tests/curve.test.luau.

local M = {}

local is_finite = function(v)
  -- The type check is load-bearing: without it a *string* passes, because
  -- `"nonsense" ~= math.huge` is true in Lua.
  if type(v) ~= "number" then return false end
  if v ~= v then return false end -- NaN
  return v ~= math.huge and v ~= -math.huge
end

M.is_finite = is_finite

-- ── the default node lists ───────────────────────────────────────────────────
-- These are also the manifest defaults in plugin.toml. run-tests.sh asserts the
-- two agree -- keys and values both -- because a silent divergence between what
-- the GUI shows and what the code uses would be a genuinely confusing bug, and
-- because the zero-padded keys are what keep the rows in numeric order.
--
-- They are written as maps, exactly as the manifest writes them, so the code
-- fallback and the settings page are the same table rather than two lists that
-- merely ought to match.
--
-- Brightness: ten log-spaced points spanning the measured 4..16653 raw range,
-- with an exact hit on the owner's one measured datum (185 raw -> 70%). They
-- reproduce the pre-Phase-2 formula
--     pct = 70 + 25 * (log10(raw + 1) - log10(186))
-- to within a fraction of a percent across the operating range. The top end is
-- deliberately *not* identical: that formula clipped to 100% at raw ~ 2947, i.e.
-- full brightness barely 3x the measured room level. Splitting it into
-- 2200 -> 96.8 and 16384 -> 100 gives the top of the range somewhere to go.
M.DEFAULT_BRIGHTNESS = {
  ["00001"] = "1:20.8",
  ["00004"] = "4:30.7",
  ["00010"] = "10:39.3",
  ["00030"] = "30:50.6",
  ["00100"] = "100:63.4",
  ["00185"] = "185:70",
  ["00400"] = "400:78.3",
  ["01000"] = "1000:88.3",
  ["02200"] = "2200:96.8",
  ["16384"] = "16384:100",
}

-- Temperature: ambient K -> panel K. Faithful to the pre-Phase-2 mapping (a flat
-- 5100 K below 3000 K ambient, then linear to 6500 K at 5500 K, then flat), so a
-- fresh install behaves as it did before. The flat runs at each end are real
-- features of that mapping, not padding: PCHIP pins a flat run with a zero
-- tangent, which is exactly the wanted behaviour at both extremes.
M.DEFAULT_TEMPERATURE = {
  ["02500"] = "2500:5100",
  ["02700"] = "2700:5100",
  ["03000"] = "3000:5100",
  ["03500"] = "3500:5380",
  ["04000"] = "4000:5660",
  ["04500"] = "4500:5940",
  ["05000"] = "5000:6220",
  ["05500"] = "5500:6500",
  ["06000"] = "6000:6500",
  ["06500"] = "6500:6500",
}

-- ── parsing ──────────────────────────────────────────────────────────────────

--- Split the raw setting into rows, each with the label the owner sees.
--
-- Two shapes arrive here and both must work:
--
--   * a `string_map` -- the shape the settings GUI can edit *in place*, keyed by
--     the reading;
--   * a `string_list` -- an array of node strings. Still accepted: the curve is a
--     plain list of numbers, and nothing about that needs enforcing.
--
-- They are told apart by the *key* type, not by `#items`: a map keyed "00185" has
-- no integer keys at all, so `#items` is 0 for a map of any size. Getting that
-- wrong would silently drop the whole curve.
local function normalise(items)
  local entries = {}
  if items == nil then return entries end
  if type(items) == "string" then items = { items } end
  if type(items) ~= "table" then return nil end

  local keyed = false
  for k in pairs(items) do
    if type(k) == "string" then
      keyed = true
      break
    end
  end

  if keyed then
    -- Sorted, matching the order the settings page renders (it sorts keys as
    -- text), so a problem message names the row where the owner will look for it.
    local keys = {}
    for k in pairs(items) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do
      entries[#entries + 1] = { label = tostring(k), text = items[k], key = tostring(k) }
    end
  else
    for i, v in ipairs(items) do
      entries[#entries + 1] = { label = tostring(i), text = v }
    end
  end
  return entries
end

--- Read one row into x and y, plus an optional note about a key that disagrees.
--
--   "185:70" -> x=185, y=70   the value carries the whole node
--   "70"     -> x from key    the value is just the target
--
-- The value always wins over the key. A stale key must never be able to move a
-- node the owner typed; the most it can do is sort the row somewhere unexpected,
-- and that is worth exactly one log line rather than being quietly obeyed.
local function read_node(text, key)
  local xs, ys = text:match("^([^:]+):(.*)$")
  if xs then
    local x = tonumber((xs:gsub("%s+$", "")))
    local y = tonumber((ys:gsub("^%s+", "")))
    if key and is_finite(x) then
      local keyed = tonumber(key)
      if is_finite(keyed) and keyed ~= x then
        return x, y, string.format(
          "row %q is keyed %s but its value says x=%s; using the value (the row sorts by the key)",
          key, tostring(keyed), tostring(x))
      end
    end
    return x, y, nil
  end
  -- No colon: the cell is the target alone, and the key supplies the reading.
  return key and tonumber(key), tonumber(text), nil
end

--- Parse node rows into a node list.
--
-- `opts.map_x` (optional) transforms the x domain after parsing. The brightness
-- curve passes log10(x + 1), because the measured 4000:1 range would otherwise
-- collapse everything below ~1000 raw into a single step; the temperature curve
-- passes nothing, because ambient kelvin is already linear.
--
-- Returns `nodes` (ascending by x, x unique) and `problems`, an array of
-- human-readable strings naming every row that was rejected or adjusted. This
-- never raises: a malformed row costs one node and one log line. A curve the owner
-- is midway through editing must not be able to take the service down.
function M.parse_nodes(items, opts)
  opts = opts or {}
  local map_x = opts.map_x
  local nodes, problems = {}, {}

  local entries = normalise(items)
  if entries == nil then
    problems[#problems + 1] = "curve is not a list"
    return nodes, problems
  end

  local seen = {}
  for _, entry in ipairs(entries) do
    if type(entry.text) ~= "string" then
      problems[#problems + 1] = "entry " .. entry.label .. " is not a string"
    else
      -- An optional '#' suffix comment, matching the TOML-splice discipline of
      -- never rewriting text the user owns: we tolerate annotation, we drop it.
      local text = entry.text:gsub("#.*$", "")
      text = text:gsub("^%s+", ""):gsub("%s+$", "")

      if text == "" then
        -- A blank row is how the editor renders a cell you have not filled in yet.
        -- Skipping it silently is deliberate: it is not an error.
      else
        local x, y, note = read_node(text, entry.key)
        if note then problems[#problems + 1] = note end
        if not is_finite(x) then
          problems[#problems + 1] = string.format(
            "entry %s: %q has no reading; write it as \"reading:target\"", entry.label, entry.text)
        elseif not is_finite(y) then
          problems[#problems + 1] = string.format(
            "entry %s: cannot read 'x:y' numbers from %q", entry.label, entry.text)
        elseif map_x then
          local mapped = map_x(x)
          if not is_finite(mapped) then
            problems[#problems + 1] = string.format(
              "entry %s: x=%s is outside the range this curve can use", entry.label, tostring(x))
          elseif seen[mapped] then
            problems[#problems + 1] = string.format(
              "entry %s: duplicate node at x=%s (ignored)", entry.label, tostring(x))
          else
            seen[mapped] = true
            nodes[#nodes + 1] = { x = mapped, y = y }
          end
        elseif seen[x] then
          problems[#problems + 1] = string.format(
            "entry %s: duplicate node at x=%s (ignored)", entry.label, tostring(x))
        else
          seen[x] = true
          nodes[#nodes + 1] = { x = x, y = y }
        end
      end
    end
  end

  table.sort(nodes, function(a, b) return a.x < b.x end)
  return nodes, problems
end

-- ── interpolation ────────────────────────────────────────────────────────────

--- Precompute tangents for a node list. Returns nil for an empty list.
--
-- `nodes` must already be ascending with unique x. Duplicated or descending x
-- makes the tangent maths meaningless, so it is rejected rather than guessed at.
function M.compile(nodes)
  local n = nodes and #nodes or 0
  if n == 0 then return nil end

  local c = { n = n, x = {}, y = {}, h = {}, d = {}, m = {} }
  for i = 1, n do
    c.x[i] = nodes[i].x
    c.y[i] = nodes[i].y
    if not is_finite(c.x[i]) or not is_finite(c.y[i]) then return nil end
  end

  if n == 1 then
    c.m[1] = 0 -- a single node is a constant, not an error: the owner may be mid-edit
    return c
  end

  for i = 1, n - 1 do
    c.h[i] = c.x[i + 1] - c.x[i]
    if c.h[i] <= 0 then return nil end
    c.d[i] = (c.y[i + 1] - c.y[i]) / c.h[i]
  end

  -- One-sided differences at the ends. Together with the harmonic-mean interior
  -- tangents below, every interval satisfies the Fritsch-Carlson monotonicity
  -- region, which is what makes the no-overshoot guarantee hold rather than be
  -- hoped for.
  c.m[1] = c.d[1]
  c.m[n] = c.d[n - 1]

  for i = 2, n - 1 do
    local d0, d1 = c.d[i - 1], c.d[i]
    if d0 * d1 <= 0 then
      -- A sign change (or a flat run) is a local extremum. A zero tangent pins the
      -- curve exactly on the node there, and that is precisely what stops the
      -- interpolation from inventing a bump between two nodes.
      c.m[i] = 0
    else
      local h0, h1 = c.h[i - 1], c.h[i]
      local w1, w2 = 2 * h1 + h0, h1 + 2 * h0
      c.m[i] = (w1 + w2) / (w1 / d0 + w2 / d1)
    end
  end

  return c
end

--- Evaluate a compiled curve at x. Outside the node range this holds the end
-- value flat, so the curve is defined for every input.
function M.eval(c, x)
  if c == nil or x == nil or x ~= x then return nil end
  local n = c.n
  if n == 1 then return c.y[1] end
  if x <= c.x[1] then return c.y[1] end
  if x >= c.x[n] then return c.y[n] end

  -- n is the number of nodes the owner typed (10 by default), so a linear scan
  -- beats a binary search and keeps the function small enough to reason about.
  local i = 1
  while i < n - 1 and x > c.x[i + 1] do i = i + 1 end

  local h = c.h[i]
  local t = (x - c.x[i]) / h
  local t2 = t * t
  local t3 = t2 * t

  local h00 = 2 * t3 - 3 * t2 + 1
  local h10 = t3 - 2 * t2 + t
  local h01 = -2 * t3 + 3 * t2
  local h11 = t3 - t2

  return c.y[i] * h00 + h * c.m[i] * h10 + c.y[i + 1] * h01 + h * c.m[i + 1] * h11
end

--- Is the node list non-decreasing in y? Used only to warn once, never to edit.
--
-- If the owner's numbers make the value fall as x rises, the curve is honoured as
-- written: silently monotone-ising their numbers would be the worst possible
-- behaviour for a curve they are trying to tune. They get a log line instead.
function M.is_monotone(nodes)
  if nodes == nil then return true end
  for i = 2, #nodes do
    if nodes[i].y < nodes[i - 1].y then return false end
  end
  return true
end

--- Compile a "x:y" list in one step. Convenience for the service, which does this
-- on config change and never per tick.
function M.from_list(items, opts)
  local nodes, problems = M.parse_nodes(items, opts)
  return M.compile(nodes), nodes, problems
end

return M
