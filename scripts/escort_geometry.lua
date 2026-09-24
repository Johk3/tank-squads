-- Pure geometry for escort formations. No Factorio API calls, so every rule
-- here is covered by the server-free unit tests.
local M = {}

function M.distance_squared(a, b)
  local dx, dy = a.x - b.x, a.y - b.y
  return dx * dx + dy * dy
end

function M.distance(a, b)
  return math.sqrt(M.distance_squared(a, b))
end

function M.centroid(entities)
  local x, y = 0, 0
  for _, e in ipairs(entities) do
    x = x + e.position.x
    y = y + e.position.y
  end
  return {x = x / #entities, y = y / #entities}
end

function M.push(history, position, keep)
  history[#history + 1] = {x = position.x, y = position.y}
  while #history > keep do table.remove(history, 1) end
end

-- Settled means every sample in the window lies within `tolerance` of the
-- newest one, so a stop at a crossing shorter than the window does not count.
function M.settled(history, sweeps, tolerance)
  if #history < sweeps then return false end
  local newest, limit = history[#history], tolerance * tolerance
  for i = #history - sweeps + 1, #history do
    if M.distance_squared(history[i], newest) >= limit then return false end
  end
  return true
end

function M.slot_position(anchor, radius, angle)
  return {x = anchor.x + radius * math.cos(angle), y = anchor.y + radius * math.sin(angle)}
end

-- Evenly spaced slots in the soldiers' current angular order. The phase is the
-- circular mean of each soldier's offset from its evenly spaced slot, which
-- keeps total travel small without trying every rotation. O(n log n); runs
-- only when the anchor or the membership changes.
function M.assign_slots(entities, anchor, radius)
  local out, count = {}, #entities
  if count == 0 then return out end
  local sorted = {}
  for _, e in ipairs(entities) do
    sorted[#sorted + 1] = {entity = e, angle = math.atan2(e.position.y - anchor.y, e.position.x - anchor.x)}
  end
  table.sort(sorted, function(a, b)
    if a.angle ~= b.angle then return a.angle < b.angle end
    return a.entity.unit_number < b.entity.unit_number
  end)
  local step = 2 * math.pi / count
  local sx, sy = 0, 0
  for i, s in ipairs(sorted) do
    local offset = s.angle - (i - 1) * step
    sx, sy = sx + math.cos(offset), sy + math.sin(offset)
  end
  local phase = (sx == 0 and sy == 0) and 0 or math.atan2(sy, sx)
  for i, s in ipairs(sorted) do out[s.entity.unit_number] = phase + (i - 1) * step end
  return out
end

-- Uniform over the annulus area, so points do not bunch at the inner edge.
function M.band_point(anchor, min_radius, max_radius, random)
  local angle = random() * 2 * math.pi
  local r = math.sqrt(min_radius * min_radius + random() * (max_radius * max_radius - min_radius * min_radius))
  return {x = anchor.x + r * math.cos(angle), y = anchor.y + r * math.sin(angle)}
end

-- Index of the point closest to position, so callers can read each entity's
-- position once and reuse it.
function M.nearest_point(points, position)
  local best, best_d = nil, math.huge
  for i, p in ipairs(points) do
    local d = M.distance_squared(p, position)
    if d < best_d then best, best_d = i, d end
  end
  return best
end

-- Distances are computed once per entity, not once per comparison.
function M.nearest_half(entities, position)
  local sorted = {}
  for i, e in ipairs(entities) do
    sorted[i] = {entity = e, d = M.distance_squared(e.position, position), id = e.unit_number}
  end
  table.sort(sorted, function(a, b)
    if a.d ~= b.d then return a.d < b.d end
    return a.id < b.id
  end)
  local out = {}
  for i = 1, math.ceil(#sorted / 2) do out[i] = sorted[i].entity end
  return out
end

return M
