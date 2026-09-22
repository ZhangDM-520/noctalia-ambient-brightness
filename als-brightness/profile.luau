--!nonstrict
-- The learned profile: observations recorded from the owner's overrides, fitted
-- onto the same x positions as the authored curve.
--
-- Why this exists: before Phase 2 an override was lost on every plugin restart
-- (docs/DESIGN.md section 7 recorded that as a limitation). The profile gives the
-- learning somewhere to live. The head-of-page `learning_profile` toggle decides
-- whether the fitted curve is *applied*; it never decides whether observations are
-- *recorded*, so switching it on always reveals a profile that has been growing
-- rather than an empty file.
--
-- The plugin cannot write its own configuration (upstream: "plugins read config
-- but cannot write it"), so promoting a learned value into the curve is a manual
-- copy by the owner. The fitted x positions deliberately match the authored
-- nodes, which makes that copy a bar-for-bar paste.
--
-- Everything here is pure: no host API, no sysfs, no clock, no file IO. The
-- service owns reading and writing profile.json; this module owns the arithmetic.
-- Exercised by tests/profile.test.luau.

local M = {}

M.DEFAULTS = {
  -- A band needs at least this many observations before its median is trusted.
  -- One stray sample from a hand shadowing the sensor must not invent a node, so
  -- a sparse profile degrades into the authored curve rather than into noise.
  min_observations = 2,

  -- Observations are a rolling window, newest kept. Bounded so profile.json
  -- cannot grow without limit on a machine that is left running for months.
  max_observations = 512,
}

local is_finite = function(v)
  -- The type check is load-bearing: without it a *string* passes, because
  -- `"nonsense" ~= math.huge` is true in Lua. That let a corrupt profile.json
  -- through validation, which is exactly what sanitise() exists to prevent.
  if type(v) ~= "number" then return false end
  if v ~= v then return false end -- NaN
  return v ~= math.huge and v ~= -math.huge
end

--- A fresh, empty profile.
function M.new()
  return { version = 1, observations = {}, nodes = {}, updated_at = nil }
end

--- Median of a numeric array. Median rather than mean on purpose: this sensor
--- moves +/-10000 counts within a single 50 ms sample and swings 70+ counts
--- second-to-second, so a mean would be dragged by exactly the samples that carry
--- the least information.
function M.median(values)
  local n = #values
  if n == 0 then return nil end
  local sorted = {}
  for i = 1, n do sorted[i] = values[i] end
  table.sort(sorted)
  local mid = math.floor((n + 1) / 2)
  if n % 2 == 1 then return sorted[mid] end
  return (sorted[mid] + sorted[mid + 1]) / 2
end

--- Which band an x falls in, given ascending band centres.
--
-- Boundaries are the midpoints between neighbouring centres, so every observation
-- is attributed to its nearest authored node. Below the first centre is band 1,
-- above the last is band n -- the curves already hold their end values flat, so
-- attributing an out-of-range reading to the end band is consistent with that.
function M.band_of(xs, x)
  local n = #xs
  if n == 0 or not is_finite(x) then return nil end
  if n == 1 then return 1 end
  if x < (xs[1] + xs[2]) / 2 then return 1 end
  if x >= (xs[n - 1] + xs[n]) / 2 then return n end
  for i = 1, n - 1 do
    if x < (xs[i] + xs[i + 1]) / 2 then return i end
  end
  return n
end

--- Record one observation, in place. `obs` is `{ x = <curve domain>, y = <value>,
--- raw = <optional, diagnostics>, at = <optional, seconds> }`.
--
-- Returns the profile, for chaining in tests.
function M.add(profile, obs, cfg)
  cfg = cfg or M.DEFAULTS
  if profile == nil or obs == nil then return profile end
  if not is_finite(obs.x) or not is_finite(obs.y) then return profile end
  profile.observations = profile.observations or {}
  profile.observations[#profile.observations + 1] = obs
  local cap = cfg.max_observations or M.DEFAULTS.max_observations
  -- Drop from the front: the newest samples describe the current room, and the
  -- curve is meant to track the owner, not to average their whole history.
  while #profile.observations > cap do
    table.remove(profile.observations, 1)
  end
  return profile
end

--- Fit the observations onto the authored x positions.
--
-- Returns `ys` (one value per x) and `counts` (observations per band, so the
-- service can log how much of the profile is actually learned). Bands with fewer
-- than `min_observations` fall back to the authored value at that x.
function M.fit(profile, xs, fallback_ys, cfg)
  cfg = cfg or M.DEFAULTS
  local n = xs and #xs or 0
  local ys, counts = {}, {}
  if n == 0 then return ys, counts end

  local buckets = {}
  for i = 1, n do
    buckets[i] = {}
    counts[i] = 0
  end

  for _, obs in ipairs((profile and profile.observations) or {}) do
    local band = M.band_of(xs, obs.x)
    if band ~= nil and is_finite(obs.y) then
      buckets[band][#buckets[band] + 1] = obs.y
    end
  end

  local min_obs = cfg.min_observations or M.DEFAULTS.min_observations
  for i = 1, n do
    counts[i] = #buckets[i]
    if counts[i] >= min_obs then
      ys[i] = M.median(buckets[i])
    else
      ys[i] = fallback_ys and fallback_ys[i] or nil
    end
  end

  return ys, counts
end

--- How many bands the profile can actually speak for. Used for logging, and for
--- deciding whether the profile is worth applying at all.
function M.learned_bands(profile, xs, cfg)
  cfg = cfg or M.DEFAULTS
  local buckets = {}
  for i = 1, (#xs or 0) do buckets[i] = 0 end
  for _, obs in ipairs((profile and profile.observations) or {}) do
    local band = M.band_of(xs, obs.x)
    if band ~= nil then buckets[band] = buckets[band] + 1 end
  end
  local learned = 0
  for i = 1, #buckets do
    if buckets[i] >= (cfg.min_observations or M.DEFAULTS.min_observations) then
      learned = learned + 1
    end
  end
  return learned
end

--- Defensively clean a decoded profile.
--
-- profile.json is a file the owner can open, edit, and corrupt, and it is read at
-- plugin start. A malformed file must cost the learned data, never the service,
-- so every field is validated and anything unusable is dropped rather than
-- trusted. Returns a well-formed profile.
function M.sanitise(value)
  local clean = M.new()
  if type(value) ~= "table" then return clean end

  if type(value.version) == "number" then clean.version = value.version end
  if is_finite(value.updated_at) then clean.updated_at = value.updated_at end

  if type(value.observations) == "table" then
    for _, obs in ipairs(value.observations) do
      if type(obs) == "table" and is_finite(obs.x) and is_finite(obs.y) then
        clean.observations[#clean.observations + 1] = {
          x = obs.x,
          y = obs.y,
          raw = is_finite(obs.raw) and obs.raw or nil,
          at = is_finite(obs.at) and obs.at or nil,
        }
      end
    end
  end

  if type(value.nodes) == "table" then
    for _, node in ipairs(value.nodes) do
      if type(node) == "table" and is_finite(node.x) and is_finite(node.y) then
        clean.nodes[#clean.nodes + 1] = { x = node.x, y = node.y }
      end
    end
  end

  return clean
end

return M
