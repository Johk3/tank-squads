-- Pure rules for scout teams: team count, dealing, sectors, march angles,
-- formation slots, hops and the team retreat trigger. No Factorio API
-- calls, so every rule here is covered by the server-free unit tests.
local M = {}

M.TAU = 2 * math.pi
M.MAX_TEAMS = 4
-- Tiles a team advances per hop, and how far its siege tanks trail the
-- front. At 52 tiles of range they still reach 22 tiles past the front.
M.HOP = 32
M.TRAIL = 30
M.SPACING = 4
M.REAR_SPACING = 6
M.ROW = 5
M.HOP_TIMEOUT = 60 * 60
-- A team with nothing uncharted in reach marches outward. Odd, so the
-- middle angle is tried first.
M.MARCH_DISTANCE = 256
M.MARCH_ANGLES = 5
M.TEAM_RETREAT = 0.5
M.NO_BARRACKS_RETRY = 600
M.CHART_RADIUS = 96
M.FAILURE_TTL = 60 * 60
M.FAILURE_LIMIT = 64

function M.distance_squared(a, b)
  local dx, dy = a.x - b.x, a.y - b.y
  return dx * dx + dy * dy
end

function M.distance(a, b)
  return math.sqrt(M.distance_squared(a, b))
end

function M.centroid(points)
  local x, y = 0, 0
  for _, p in ipairs(points) do x, y = x + p.x, y + p.y end
  return {x = x / #points, y = y / #points}
end

-- One team per three soldiers, at most MAX_TEAMS, and never more teams than
-- front soldiers, so every team starts with a screen for its siege tanks.
function M.team_count(size, fronts)
  return math.max(1, math.min(M.MAX_TEAMS, math.floor(size / 3), fronts))
end

local ORDER = {siege = 1, flame = 2, carrier = 3}

-- Round-robin with one cursor across the kinds, sieges first, so each
-- team's count of every kind, and each team's size, differ by at most one.
-- Sorting by kind and unit number makes the deal independent of input order.
function M.deal(entries, count)
  local sorted = {}
  for i, e in ipairs(entries) do sorted[i] = e end
  table.sort(sorted, function(a, b)
    if ORDER[a.kind] ~= ORDER[b.kind] then return ORDER[a.kind] < ORDER[b.kind] end
    return a.id < b.id
  end)
  local teams = {}
  for i = 1, count do teams[i] = {} end
  for i, e in ipairs(sorted) do
    local team = teams[(i - 1) % count + 1]
    team[#team + 1] = e.id
  end
  return teams
end

-- Equal slices of the compass, the first starting due east (+x). Each team
-- gets a list of ranges, so a merge can hand its ranges to another team.
function M.sectors(count)
  local out = {}
  for i = 1, count do out[i] = {{from = (i - 1) * M.TAU / count, to = i * M.TAU / count}} end
  return out
end

function M.angle(origin, point)
  return math.atan2(point.y - origin.y, point.x - origin.x) % M.TAU
end

function M.in_sectors(ranges, angle)
  for _, r in ipairs(ranges) do
    if angle >= r.from and angle < r.to then return true end
  end
  return false
end

-- The centres of MARCH_ANGLES equal parts of the widest range, middle first
-- and then alternating outward.
function M.march_angles(ranges)
  local wide
  for _, r in ipairs(ranges) do
    if not wide or r.to - r.from > wide.to - wide.from then wide = r end
  end
  local n = M.MARCH_ANGLES
  local width, middle = (wide.to - wide.from) / n, (n + 1) / 2
  local out = {}
  for k = 0, n - 1 do
    local i = middle + math.ceil(k / 2) * (k % 2 == 1 and -1 or 1)
    out[#out + 1] = wide.from + (i - 0.5) * width
  end
  return out
end

-- The next hop point from `from` towards `target`, the unit heading, and
-- whether the hop ends on the target itself. Nil when already there.
function M.hop(from, target)
  local dx, dy = target.x - from.x, target.y - from.y
  local d = math.sqrt(dx * dx + dy * dy)
  if d < 1 then return nil end
  local heading = {x = dx / d, y = dy / d}
  if d <= M.HOP then return {x = target.x, y = target.y}, heading, true end
  return {x = from.x + heading.x * M.HOP, y = from.y + heading.y * M.HOP}, heading, false
end

-- Offsets are (forward, lateral) in the team's frame: forward along the
-- heading, lateral along (-heading.y, heading.x).
local function rotate(point, heading, forward, lateral)
  return {x = point.x + heading.x * forward - heading.y * lateral,
    y = point.y + heading.y * forward + heading.x * lateral}
end

-- Rows of at most ROW slots, centred, `spacing` apart; further rows sit
-- SPACING further back.
local function rows(count, forward, spacing)
  local out = {}
  for i = 1, count do
    local row = math.floor((i - 1) / M.ROW)
    local in_row = math.min(M.ROW, count - row * M.ROW)
    local column = (i - 1) % M.ROW
    out[i] = {forward = forward - row * M.SPACING, lateral = (column - (in_row - 1) / 2) * spacing}
  end
  return out
end

local function v(count, back)
  local out = {}
  for k = 1, count do
    local depth = math.ceil(k / 2)
    out[k] = {forward = -6 - 3 * depth - back, lateral = (3 + 3 * depth) * (k % 2 == 1 and 1 or -1)}
  end
  return out
end

-- Slots and members both go in lateral order, so a soldier takes a slot on
-- its own side of the team and no two paths cross.
local function place(out, band, members, offsets, point, heading)
  table.sort(offsets, function(a, b)
    if a.lateral ~= b.lateral then return a.lateral < b.lateral end
    return a.forward > b.forward
  end)
  local keyed = {}
  for i, m in ipairs(members) do
    local dx, dy = m.position.x - point.x, m.position.y - point.y
    keyed[i] = {m = m, side = -heading.y * dx + heading.x * dy}
  end
  table.sort(keyed, function(a, b)
    if a.side ~= b.side then return a.side < b.side end
    return a.m.id < b.m.id
  end)
  for i, k in ipairs(keyed) do
    local o = offsets[i]
    out[k.m.id] = {position = rotate(point, heading, o.forward, o.lateral), band = band}
  end
end

-- Flame tanks lead; without them carriers lead. Carriers behind flame tanks
-- form a V. Siege tanks trail by TRAIL, or lead when they are all there is.
function M.slots(entries, point, heading)
  local flames, carriers, sieges = {}, {}, {}
  for _, m in ipairs(entries) do
    local list = (m.kind == "flame" and flames) or (m.kind == "siege" and sieges) or carriers
    list[#list + 1] = m
  end
  local out = {}
  local front, middle = flames, {}
  if #flames == 0 then front = carriers else middle = carriers end
  if #front == 0 then
    place(out, "front", sieges, rows(#sieges, 0, M.SPACING), point, heading)
    return out
  end
  place(out, "front", front, rows(#front, 0, M.SPACING), point, heading)
  local back = math.floor((#front - 1) / M.ROW) * M.SPACING
  place(out, "middle", middle, v(#middle, back), point, heading)
  place(out, "rear", sieges, rows(#sieges, -M.TRAIL, M.REAR_SPACING), point, heading)
  return out
end

function M.should_withdraw(health, max_health, living, formed)
  if max_health > 0 and health / max_health < M.TEAM_RETREAT then return true end
  return formed >= 2 and living <= math.floor(formed / 2)
end

return M
