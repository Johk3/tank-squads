-- Pure geometry for patrol lanes. No Factorio API calls, so every rule here
-- is covered by the server-free unit tests.
local M = {}

-- The area centroid of the closed route, so waypoints bunched on one side do
-- not pull the centre towards them. A route with no area (one waypoint, two,
-- or all in a line) falls back to the waypoint average.
function M.centre(waypoints)
  local count = #waypoints
  local sx, sy = 0, 0
  for _, p in ipairs(waypoints) do sx, sy = sx + p.x, sy + p.y end
  local mean = {x = sx / count, y = sy / count}
  if count < 3 then return mean end
  -- Relative to the mean, so large map coordinates keep their precision.
  local area, cx, cy = 0, 0, 0
  for i, p in ipairs(waypoints) do
    local q = waypoints[i % count + 1]
    local px, py, qx, qy = p.x - mean.x, p.y - mean.y, q.x - mean.x, q.y - mean.y
    local cross = px * qy - qx * py
    area, cx, cy = area + cross, cx + (px + qx) * cross, cy + (py + qy) * cross
  end
  if math.abs(area) < 1 then return mean end
  return {x = mean.x + cx / (3 * area), y = mean.y + cy / (3 * area)}
end

-- Lane k of n is the route scaled towards its centre. Lane 1 is the route as
-- drawn. The scales split the enclosed area into n equal bands, so a large
-- division fills the inside evenly instead of crowding the centre.
function M.lane_scale(k, n)
  return math.sqrt((n - k + 1) / n)
end

function M.lane_point(centre, waypoint, scale)
  -- Lane 1 gets the waypoint itself, not a rounded copy of it.
  if scale == 1 then return {x = waypoint.x, y = waypoint.y} end
  return {x = centre.x + (waypoint.x - centre.x) * scale, y = centre.y + (waypoint.y - centre.y) * scale}
end

return M
