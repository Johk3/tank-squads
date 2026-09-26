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
-- A chunk given up because water lies in the way stays blocked longer: the
-- water does not dry up, unlike a path blocked by enemies.
M.WATER_TTL = 10 * 60 * 60
-- A soldier further than STRAY tiles from the team's anchor at the start of
-- a hop walks after the team instead of taking a slot, and never holds the
-- hop. Its order is renewed at most every CHASE_RESEND ticks.
M.STRAY = 64
M.CHASE_RESEND = 20 * 60
-- Once the whole front, or half the team, stands on its slots, the rest
-- get GRACE ticks.
M.GRACE = 10 * 60
-- A hop point on water moves to dry ground: first to the far bank on the
-- same line, up to WADE tiles past it in WADE_STEP steps, so the pathfinder
-- leads the team around the lake; then along the shore by turning the hop
-- by each of TURNS to either side.
M.WADE, M.WADE_STEP = 160, 8
M.TURNS = {math.pi / 6, math.pi / 3, math.pi / 2, 2 * math.pi / 3, 5 * math.pi / 6}
-- Shore hops in a row before a target is given up, or a march angle counts
-- as failed.
M.DETOUR_LIMIT = 8
M.MARCH_DETOURS = 16
-- Hops since the team last charted its target before it is blocked, so a
-- team that walks without charting anything, as along the coast of an
-- explored island, ends instead of wandering for ever.
M.STALL_HOPS = 48
-- Hops towards one target before it is given up. Targets are the nearest
-- fog, so a reachable one is charted long before.
M.TARGET_HOPS = 20
-- A target chunk is open water when at least SEA_WET of its SEA_SAMPLES
-- tiles are water. The whole division then skips it for SEA_TTL ticks, so a
-- coast's endless sea chunks are not tried one after another. At most
-- SEA_LIMIT chunks are remembered.
M.SEA_SAMPLES = {4, 16, 28}
M.SEA_WET = 8
M.SEA_TTL = 30 * 60 * 60
M.SEA_LIMIT = 4096

-- A number that names a chunk, for keys that need no string.
function M.chunk_key(x, y)
  return x * 1048576 + y
end

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

-- Points past `point` along `heading`, WADE_STEP apart up to WADE tiles.
function M.wade(point, heading)
  local out = {}
  for d = M.WADE_STEP, M.WADE, M.WADE_STEP do
    out[#out + 1] = {x = point.x + heading.x * d, y = point.y + heading.y * d}
  end
  return out
end

-- Hops of HOP tiles from `from`, turned from `heading` by each of TURNS,
-- smallest turn first and `side` (1 or -1) first at each turn. Each entry
-- holds the point, its heading and the side it turned to.
function M.detours(from, heading, side)
  local out = {}
  for _, turn in ipairs(M.TURNS) do
    for _, s in ipairs({side, -side}) do
      local c, sn = math.cos(turn * s), math.sin(turn * s)
      local h = {x = heading.x * c - heading.y * sn, y = heading.x * sn + heading.y * c}
      out[#out + 1] = {point = {x = from.x + h.x * M.HOP, y = from.y + h.y * M.HOP}, heading = h, side = s}
    end
  end
  return out
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
