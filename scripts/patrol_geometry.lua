-- Pure geometry for patrol posts. No Factorio API calls, so every rule here
-- is covered by the server-free unit tests.
local M = {}

-- A stretch of route shorter than this is held, not walked: its soldier
-- stands at the middle of it and covers it with its guns. Keeps a crowded
-- route from turning into a stream of very short path requests.
M.MIN_POST = 32
-- Rings of a patrol are at least this many tiles apart.
M.MIN_RING_GAP = 12

local function distance(a, b)
  local dx, dy = a.x - b.x, a.y - b.y
  return math.sqrt(dx * dx + dy * dy)
end

-- Twice the signed area of the closed route and the waypoint average, both
-- relative to that average, so large map coordinates keep their precision.
local function signed(waypoints)
  local count = #waypoints
  local sx, sy = 0, 0
  for _, p in ipairs(waypoints) do sx, sy = sx + p.x, sy + p.y end
  local mean = {x = sx / count, y = sy / count}
  local area, cx, cy = 0, 0, 0
  if count < 3 then return area, cx, cy, mean end
  for i, p in ipairs(waypoints) do
    local q = waypoints[i % count + 1]
    local px, py, qx, qy = p.x - mean.x, p.y - mean.y, q.x - mean.x, q.y - mean.y
    local cross = px * qy - qx * py
    area, cx, cy = area + cross, cx + (px + qx) * cross, cy + (py + qy) * cross
  end
  return area, cx, cy, mean
end

-- The area centroid of the closed route, so waypoints bunched on one side do
-- not pull the centre towards them. A route with no area (one waypoint, two,
-- or all in a line) falls back to the waypoint average.
function M.centre(waypoints)
  local area, cx, cy, mean = signed(waypoints)
  if math.abs(area) < 1 then return mean end
  return {x = mean.x + cx / (3 * area), y = mean.y + cy / (3 * area)}
end

-- The area the closed route encloses; 0 for a route that encloses none.
function M.area(waypoints)
  local area = math.abs((signed(waypoints)))
  if area < 1 then return 0 end
  return area / 2
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

function M.length(path, closed)
  local count, total = #path, 0
  for i = 1, closed and count or count - 1 do total = total + distance(path[i], path[i % count + 1]) end
  return total
end

-- How many rings `count` soldiers patrol on. The soldiers spread evenly
-- along the rings, and the rings are about as far apart as neighbours on a
-- ring, so the whole area is covered and not only its edge. For a square
-- that is one ring up to 11 soldiers, two up to 33 and three up to 65. A
-- narrow area keeps fewer rings, at least MIN_RING_GAP tiles apart.
function M.ring_count(count, area, length)
  if count <= 1 or area <= 0 or length <= 0 then return 1 end
  local rings = math.floor(math.sqrt(3 * count * area) / length + 0.5)
  -- 2 * area / length is the inradius of a convex route.
  rings = math.min(rings, count, math.floor(2 * area / length / M.MIN_RING_GAP))
  return math.max(1, rings)
end

-- Soldiers per ring, outermost first: one each, the rest in proportion to
-- each ring's length, so every ring has the same spacing.
function M.ring_counts(count, rings)
  local weights, total = {}, 0
  for j = 1, rings do
    weights[j] = M.lane_scale(j, rings)
    total = total + weights[j]
  end
  local counts, rest, spare, given = {}, {}, count - rings, 0
  for j = 1, rings do
    local share = spare * weights[j] / total
    counts[j] = 1 + math.floor(share)
    rest[j] = share - math.floor(share)
    given = given + math.floor(share)
  end
  for _ = 1, spare - given do
    local best = 1
    for j = 2, rings do if rest[j] > rest[best] then best = j end end
    counts[best], rest[best] = counts[best] + 1, -1
  end
  return counts
end

-- Splits a path into `count` stretches of equal length, one post each. A post
-- lists the points its soldier walks back and forth: the stretch's ends and
-- the route corners between them. A stretch shorter than MIN_POST becomes a
-- single point at its middle. A lone soldier walks the whole path, round the
-- loop when it is closed. `anchor` is the middle of the stretch, where the
-- soldier takes up its post, and `next` the first point beyond it.
function M.posts(path, closed, count)
  local m = #path
  local edges = closed and m or m - 1
  local cum = {0}
  for i = 1, edges do cum[i + 1] = cum[i] + distance(path[i], path[i % m + 1]) end
  local total = cum[edges + 1] or 0
  local posts = {}
  if total <= 0 then
    for k = 1, count do
      local point = {x = path[1].x, y = path[1].y}
      posts[k] = {points = {point}, anchor = point, next = 1}
    end
    return posts
  end
  local e = 1
  local function at(s)
    while e > 1 and cum[e] > s do e = e - 1 end
    while e < edges and cum[e + 1] < s do e = e + 1 end
    local p, q = path[e], path[e % m + 1]
    local span = cum[e + 1] - cum[e]
    local t = span > 0 and (s - cum[e]) / span or 0
    return {x = p.x + (q.x - p.x) * t, y = p.y + (q.y - p.y) * t}
  end
  if count == 1 then
    local points, middle, next = {}, total / 2, nil
    for i = 1, m do
      points[i] = {x = path[i].x, y = path[i].y}
      if not next and cum[i] > middle then next = i end
    end
    posts[1] = {points = points, loop = closed or nil, anchor = at(middle), next = next or (closed and 1 or m)}
    return posts
  end
  local stretch = total / count
  for k = 1, count do
    local a, b = (k - 1) * stretch, k == count and total or k * stretch
    local middle = (a + b) / 2
    local anchor = at(middle)
    if stretch < M.MIN_POST then
      posts[k] = {points = {anchor}, anchor = anchor, next = 1}
    else
      local points, next = {at(a)}, nil
      -- Corners strictly inside the stretch; one within a tile of either
      -- end would be a leg shorter than the arrival radius.
      for v = 2, edges do
        if cum[v] > a + 1 and cum[v] < b - 1 then
          points[#points + 1] = {x = path[v].x, y = path[v].y}
          if not next and cum[v] > middle then next = #points end
        end
      end
      points[#points + 1] = at(b)
      posts[k] = {points = points, anchor = anchor, next = next or #points}
    end
  end
  return posts
end

-- The posts for `count` soldiers on a route, outermost ring first, and how
-- many of them each ring has. A route that encloses an area is patrolled on
-- concentric rings; one without (a single waypoint, two, or a line) along the
-- waypoints as drawn, which the soldiers split between them.
function M.layout(waypoints, count)
  local centre, area = M.centre(waypoints), M.area(waypoints)
  local closed = area > 0
  if count == 0 then return {posts = {}, counts = {}, centre = centre, around = closed} end
  local length = M.length(waypoints, closed)
  local rings = M.ring_count(count, area, length)
  local counts = M.ring_counts(count, rings)
  local posts = {}
  for j = 1, rings do
    local scale, path = M.lane_scale(j, rings), waypoints
    if scale ~= 1 then
      path = {}
      for i, w in ipairs(waypoints) do path[i] = M.lane_point(centre, w, scale) end
    end
    for _, post in ipairs(M.posts(path, closed, counts[j])) do posts[#posts + 1] = post end
  end
  return {posts = posts, counts = counts, centre = centre, around = closed}
end

-- Matches points (soldiers) to anchors (posts) one to one, keeping each
-- soldier near its post without trying every pairing. Around a centre both
-- are taken in angular order, turned by the rotation most soldiers prefer;
-- along a line, in order along it. O(n log n). Returns, for each point, the
-- index of its anchor.
function M.match(points, anchors, centre, around)
  local count = #points
  local function key_of(list)
    local keys = {}
    if around then
      for i, p in ipairs(list) do keys[i] = math.atan2(p.y - centre.y, p.x - centre.x) end
    else
      local first, last = anchors[1], anchors[#anchors]
      local dx, dy = last.x - first.x, last.y - first.y
      for i, p in ipairs(list) do keys[i] = (p.x - first.x) * dx + (p.y - first.y) * dy end
    end
    local order = {}
    for i = 1, #list do order[i] = i end
    table.sort(order, function(a, b)
      if keys[a] ~= keys[b] then return keys[a] < keys[b] end
      return a < b
    end)
    return order, keys
  end
  local by_point, point_keys = key_of(points)
  local by_anchor, anchor_keys = key_of(anchors)
  local rotation = 0
  if around and count > 1 then
    -- Each soldier votes for the rotation that gives it the anchor nearest
    -- in angle, found by binary search. The circular mean of the votes wins.
    local sx, sy, step = 0, 0, 2 * math.pi / count
    for i, p in ipairs(by_point) do
      local angle, lo, hi = point_keys[p], 1, count
      while lo < hi do
        local mid = math.floor((lo + hi) / 2)
        if anchor_keys[by_anchor[mid]] < angle then lo = mid + 1 else hi = mid end
      end
      local best, best_d = lo, math.huge
      for _, j in ipairs({lo - 1, lo, lo % count + 1}) do
        local index = (j - 1) % count + 1
        local d = math.abs(anchor_keys[by_anchor[index]] - angle)
        d = math.min(d, 2 * math.pi - d)
        if d < best_d then best, best_d = index, d end
      end
      local vote = (best - i) * step
      sx, sy = sx + math.cos(vote), sy + math.sin(vote)
    end
    if sx ~= 0 or sy ~= 0 then rotation = math.floor(math.atan2(sy, sx) / step + 0.5) % count end
  end
  local out = {}
  for i, p in ipairs(by_point) do out[p] = by_anchor[(i - 1 + rotation) % count + 1] end
  return out
end

return M
