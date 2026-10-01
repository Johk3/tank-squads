-- Staged nest assault: the division gathers on a staging arc outside the
-- nest, siege tanks open a barrage on the worms, flame tanks push in, and
-- carriers follow. A few carriers screen the siege line. Offensive escorts
-- (scripts/escort.lua) stage on their own side of the nest; a manual order
-- onto a nest (scripts/commands.lua) surrounds it.
local combat = require('scripts.combat')
local geometry = require('scripts.escort_geometry')

local M = {}

M.NEST_SEARCH = 48
-- A leg target is part of a nest when a spawner stands this close to it.
M.SPAWNER_REACH = 32
M.MIN_STANDOFF = 40
M.WORM_MARGIN = 16
M.SLOT_SPACING = 4
M.ARRIVED = 8
-- Staging ends when the soldiers still walking have not closed in by
-- STAGE_PROGRESS tiles in total for STAGE_WINDOW ticks.
M.STAGE_PROGRESS = 2
M.STAGE_WINDOW = 10 * 60
M.BARRAGE_LIMIT = 20 * 60
M.FOLLOW_DELAY = 8 * 60
M.SCREEN_AHEAD = 10
M.SCREEN_SPACING = 4
M.PUSH_MARGIN = 8
M.FLAME_EDGE = 10
M.NO_KILL_TIMEOUT = 5 * 3600
-- A surrounding soldier walks round the staging circle to its slot through
-- waypoints at most this far apart, so its path never cuts across the nest.
M.WAYPOINT_ARC = math.pi / 4

local KINDS = {['tank-squad-siege'] = 'siege', ['tank-squad-flame'] = 'flame', ['tank-squad-nuclear'] = 'siege'}

function M.kind(name)
  return KINDS[name] or 'carrier'
end

-- One screen carrier per two siege tanks, at least two, never more than half
-- the carriers. No siege tanks, no screen.
function M.screen_size(siege, carriers)
  if siege == 0 then return 0 end
  return math.min(math.max(2, math.ceil(siege / 2)), math.floor(carriers / 2))
end

function M.standoff(radius, worm_range)
  return radius + math.max(worm_range + M.WORM_MARGIN, M.MIN_STANDOFF)
end

function M.nest_shape(structures)
  local center, radius = geometry.centroid(structures), 0
  for _, s in ipairs(structures) do radius = math.max(radius, geometry.distance(s.position, center)) end
  return center, radius
end

local function by_offset(a, b)
  if a.offset ~= b.offset then return a.offset < b.offset end
  return a.id < b.id
end

-- Each soldier's angle around the nest, relative to the bearing, in order.
local function offsets(members, center, bearing)
  local sorted = {}
  for _, e in ipairs(members) do
    local p = e.position
    local offset = math.atan2(p.y - center.y, p.x - center.x) - bearing
    sorted[#sorted + 1] = {id = e.unit_number, name = e.name, offset = (offset + math.pi) % (2 * math.pi) - math.pi}
  end
  table.sort(sorted, by_offset)
  return sorted
end

local function place(sorted, center, distance, bearing, step)
  local count, slots = #sorted, {}
  for i, s in ipairs(sorted) do
    slots[s.id] = geometry.slot_position(center, distance, bearing + (i - (count + 1) / 2) * step)
  end
  return slots
end

-- Slots SLOT_SPACING tiles apart along the arc, centred on the bearing. The
-- soldiers keep their angular order around the nest, so no two paths cross.
-- A division too big for the arc wraps evenly around the whole circle.
function M.arc_slots(members, center, distance, bearing)
  local step = math.min(M.SLOT_SPACING / distance, 2 * math.pi / math.max(#members, 1))
  return place(offsets(members, center, bearing), center, distance, bearing, step)
end

local KIND_ORDER = {siege = 1, flame = 2, carrier = 3}

-- Slots evenly spaced around the whole nest, the middle one on the bearing.
-- Each kind is spread evenly round the circle, so every side gets its share
-- of siege tanks, flame tanks and carriers. Within a kind the soldiers keep
-- their angular order.
function M.ring_slots(members, center, distance, bearing)
  local groups = {}
  for _, s in ipairs(offsets(members, center, bearing)) do
    local kind = M.kind(s.name)
    groups[kind] = groups[kind] or {}
    table.insert(groups[kind], s)
  end
  local spread = {}
  for kind, group in pairs(groups) do
    for j, s in ipairs(group) do
      spread[#spread + 1] = {id = s.id, share = (j - 0.5) / #group, kind = KIND_ORDER[kind]}
    end
  end
  table.sort(spread, function(a, b)
    if a.share ~= b.share then return a.share < b.share end
    if a.kind ~= b.kind then return a.kind < b.kind end
    return a.id < b.id
  end)
  return place(spread, center, distance, bearing, 2 * math.pi / math.max(#members, 1))
end

-- The points a soldier at `from` walks through to reach its slot `to`: round
-- the staging circle the short way, at most WAYPOINT_ARC apart, then the slot.
function M.around(from, center, distance, to)
  local start = math.atan2(from.y - center.y, from.x - center.x)
  local finish = math.atan2(to.y - center.y, to.x - center.x)
  local delta = (finish - start + math.pi) % (2 * math.pi) - math.pi
  local legs = math.ceil(math.abs(delta) / M.WAYPOINT_ARC)
  local points = {}
  for i = 1, legs - 1 do points[i] = geometry.slot_position(center, distance, start + delta * i / legs) end
  points[#points + 1] = to
  return points
end

-- A line across the path from the siege tanks to the nest, SCREEN_AHEAD
-- tiles in front of them.
function M.screen_points(from, center, count)
  local dx, dy = center.x - from.x, center.y - from.y
  local length = math.sqrt(dx * dx + dy * dy)
  if length == 0 then dx, dy, length = 1, 0, 1 end
  local ux, uy = dx / length, dy / length
  local ox, oy = from.x + ux * M.SCREEN_AHEAD, from.y + uy * M.SCREEN_AHEAD
  local points = {}
  for i = 1, count do
    local o = (i - (count + 1) / 2) * M.SCREEN_SPACING
    points[i] = {x = ox - uy * o, y = oy + ux * o}
  end
  return points
end

-- remaining: summed distance of the soldiers not yet arrived. progress keeps
-- the last sample that closed in by STAGE_PROGRESS tiles.
function M.stage_over(progress, remaining, tick)
  if remaining == 0 then return true end
  if not progress.sum or remaining <= progress.sum - M.STAGE_PROGRESS then
    progress.sum, progress.tick = remaining, tick
    return false
  end
  return tick - progress.tick >= M.STAGE_WINDOW
end

function M.push_ready(worms_in_reach, barrage_ticks)
  return worms_in_reach == 0 or barrage_ticks >= M.BARRAGE_LIMIT
end

function M.follow_ready(flame_engaged, push_ticks)
  return flame_engaged or push_ticks >= M.FOLLOW_DELAY
end

local function leg(destination)
  return {type = defines.command.go_to_location, destination = destination,
    radius = 4, distraction = defines.distraction.by_enemy}
end

local function go(soldier, destination)
  combat.set_command(soldier, leg(destination))
end

-- A surrounding soldier walks round the nest to its slot.
local function go_round(a, soldier, slot)
  local points = M.around(soldier.position, a.center, a.standoff, slot)
  if #points == 1 then return go(soldier, slot) end
  local legs = {}
  for i, point in ipairs(points) do legs[i] = leg(point) end
  combat.set_command(soldier, {type = defines.command.compound,
    structure_type = defines.compound_command.return_last, commands = legs})
end

local function set_role(a, unit, role)
  a.roles[unit] = role
  a.screen[unit] = role == 'screen' or nil
  a.orders[unit], a.targets[unit] = nil, nil
end

local function adopt(a, soldier)
  local unit = soldier.unit_number
  set_role(a, unit, M.kind(soldier.name))
  a.slots[unit] = a.slots[unit] or a.arc_centre
end

local function count_roles(a)
  local c = {siege = 0, flame = 0, carrier = 0, screen = 0}
  for _, role in pairs(a.roles) do c[role] = c[role] + 1 end
  return c
end

local function siege_centroid(a, members)
  local x, y, n = 0, 0, 0
  for _, e in ipairs(members) do
    if a.roles[e.unit_number] == 'siege' then
      local p = e.position
      x, y, n = x + p.x, y + p.y, n + 1
    end
  end
  if n > 0 then return {x = x / n, y = y / n} end
end

-- The staging slots of the siege tanks, in unit number order. A
-- surrounding assault screens each of them on its own.
local function siege_lines(a)
  local units = {}
  for unit, role in pairs(a.roles) do
    if role == 'siege' then units[#units + 1] = unit end
  end
  table.sort(units)
  local lines = {}
  for i, unit in ipairs(units) do lines[i] = {unit = unit, point = a.slots[unit]} end
  return lines
end

local function nearest_squared(points, position)
  local best = math.huge
  for _, point in ipairs(points) do best = math.min(best, geometry.distance_squared(point, position)) end
  return best
end

-- A grid over `points` that finds the nearest one without a scan over all
-- of them. Cells start sized for one point each over the points' box and
-- shrink while the points crowd into few cells, as staging slots on a circle
-- do, down to a fifth of a tile.
local function point_grid(points)
  local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
  for _, p in ipairs(points) do
    x0, y0, x1, y1 = math.min(x0, p.x), math.min(y0, p.y), math.max(x1, p.x), math.max(y1, p.y)
  end
  local size = math.max(0.2, math.sqrt((x1 - x0) * (y1 - y0) / #points), (x1 - x0) / #points, (y1 - y0) / #points)
  while true do
    local cells, used = {}, 0
    for i, p in ipairs(points) do
      local cx, cy = math.floor((p.x - x0) / size), math.floor((p.y - y0) / size)
      local column = cells[cx] or {}
      cells[cx] = column
      if not column[cy] then column[cy], used = {}, used + 1 end
      table.insert(column[cy], i)
    end
    if used * 2 >= #points or size <= 0.2 then
      return {x0 = x0, y0 = y0, size = size, points = points, cells = cells,
        cols = math.floor((x1 - x0) / size), rows = math.floor((y1 - y0) / size)}
    end
    -- Points along a line fill cells in proportion to 1 / size.
    size = math.max(0.2, size * math.max(used / #points, 0.125))
  end
end

local function scan(cells, x, y, points, position, taken, best, best_d)
  local column = cells[x]
  local cell = column and column[y]
  if not cell then return best, best_d end
  for _, i in ipairs(cell) do
    if not (taken and taken[i]) then
      local d = geometry.distance_squared(points[i], position)
      if d < best_d or (d == best_d and i < best) then best, best_d = i, d end
    end
  end
  return best, best_d
end

-- The index of the nearest point not in `taken`, the lowest index on a tie,
-- and its squared distance: the same answer as a scan in index order. Walks
-- square rings of cells outwards. A point in ring r + 1 or beyond is more
-- than r cells away, so the walk stops one ring after that bound passes the
-- best distance, which leaves room for rounding at cell edges.
local function grid_nearest(grid, position, taken)
  local size, points, cells, cols, rows = grid.size, grid.points, grid.cells, grid.cols, grid.rows
  local cx, cy = math.floor((position.x - grid.x0) / size), math.floor((position.y - grid.y0) / size)
  -- Rings before `first` lie wholly outside the grid, rings after `last` too.
  local first = math.max(0, -cx, cx - cols, -cy, cy - rows)
  local last = math.max(cx, cols - cx, cy, rows - cy)
  local best, best_d = nil, math.huge
  for r = first, last do
    if r == 0 then
      best, best_d = scan(cells, cx, cy, points, position, taken, best, best_d)
    else
      for x = math.max(cx - r, 0), math.min(cx + r, cols) do
        best, best_d = scan(cells, x, cy - r, points, position, taken, best, best_d)
        best, best_d = scan(cells, x, cy + r, points, position, taken, best, best_d)
      end
      for y = math.max(cy - r + 1, 0), math.min(cy + r - 1, rows) do
        best, best_d = scan(cells, cx - r, y, points, position, taken, best, best_d)
        best, best_d = scan(cells, cx + r, y, points, position, taken, best, best_d)
      end
    end
    if best and r >= 1 and best_d <= ((r - 1) * size) ^ 2 then break end
  end
  return best, best_d
end

-- Promotes the carriers nearest the siege line until the screen is full.
-- Never demotes while siege tanks remain, so the screen does not reshuffle
-- when a carrier dies. Reads carrier positions only when a slot is empty. A
-- surrounding assault compares staging slots instead of positions.
local function refill_screen(a, members, c)
  local missing = M.screen_size(c.siege, c.carrier + c.screen) - c.screen
  if missing <= 0 then return end
  local anchors = {}
  if a.surround then
    for i, line in ipairs(siege_lines(a)) do anchors[i] = line.point end
  else
    anchors[1] = a.siege_center or siege_centroid(a, members)
  end
  if not anchors[1] then return end
  local grid = a.surround and point_grid(anchors)
  local carriers = {}
  for _, e in ipairs(members) do
    local unit = e.unit_number
    if a.roles[unit] == 'carrier' then
      local d
      if grid then
        d = select(2, grid_nearest(grid, a.slots[unit]))
      else
        d = nearest_squared(anchors, e.position)
      end
      carriers[#carriers + 1] = {id = unit, d = d}
    end
  end
  table.sort(carriers, function(p, q)
    if p.d ~= q.d then return p.d < q.d end
    return p.id < q.id
  end)
  for i = 1, math.min(missing, #carriers) do set_role(a, carriers[i].id, 'screen') end
end

-- Each screen carrier joins the siege tank with the fewest screen carriers,
-- the nearest one on a tie, and the line forms in front of that tank.
-- Counts stay within one of each other, so the tanks with the fewest are
-- those not yet taken in the current round, and a round ends when every tank
-- has one more.
local function place_screen_around(a, units)
  local lines, groups = siege_lines(a), {}
  if #lines == 0 then return end
  local points = {}
  for i, line in ipairs(lines) do points[i] = line.point end
  local grid, taken, left = point_grid(points), {}, #lines
  for _, unit in ipairs(units) do
    if left == 0 then taken, left = {}, #lines end
    local best = grid_nearest(grid, a.slots[unit], taken)
    taken[best], left = true, left - 1
    groups[best] = groups[best] or {}
    table.insert(groups[best], unit)
  end
  for i, group in pairs(groups) do
    local points = M.screen_points(lines[i].point, a.center, #group)
    for j, unit in ipairs(group) do
      a.screen_slots[unit] = {key = 'screen:' .. lines[i].unit .. ':' .. j .. ':' .. #group, point = points[j]}
    end
  end
end

local function place_screen(a)
  local units = {}
  for unit in pairs(a.screen) do units[#units + 1] = unit end
  table.sort(units)
  if a.surround then
    a.screen_slots = {}
    return place_screen_around(a, units)
  end
  local points = M.screen_points(a.siege_center, a.center, #units)
  a.screen_slots = {}
  for i, unit in ipairs(units) do
    a.screen_slots[unit] = {key = 'screen:' .. i .. ':' .. #units, point = points[i]}
  end
end

-- Worms first, nearest first; spawners once every worm is dead. Positions
-- come from the cache taken at the start, so this reads no entity position.
local WORMS_FIRST = {true, false}
local function nearest_structure(a, position)
  for _, want_worm in ipairs(WORMS_FIRST) do
    local best, best_d = nil, math.huge
    for _, s in ipairs(a.structures) do
      if s.worm == want_worm and s.entity.valid then
        local d = geometry.distance_squared(s.position, position)
        if d < best_d then best, best_d = s.entity, d end
      end
    end
    if best then return best end
  end
end

-- Gives a soldier its role's order for the current phase, once. An order
-- already given is not repeated, so holding soldiers cost nothing.
local function command(a, soldier)
  local unit, phase = soldier.unit_number, a.phase
  -- An attacker whose path failed waits for the next kill instead of
  -- asking the pathfinder for the same route every second.
  if a.orders[unit] == 'failed' then return end
  local role = a.roles[unit]
  if role == 'siege' and phase ~= 'stage' then
    local target = a.targets[unit]
    if a.orders[unit] == 'fire' and target and target.valid then return end
    target = nearest_structure(a, soldier.position)
    if not target then return end
    a.targets[unit], a.orders[unit] = target, 'fire'
    combat.set_command(soldier, {type = defines.command.attack, target = target,
      distraction = defines.distraction.by_enemy})
    return
  end
  local key, destination = 'slot', a.slots[unit]
  local screen = a.screen_slots[unit]
  if role == 'screen' and phase ~= 'stage' and screen then
    key, destination = screen.key, screen.point
  elseif (role == 'flame' and (phase == 'push' or phase == 'follow')) or (role == 'carrier' and phase == 'follow') then
    key = 'attack'
  end
  if a.orders[unit] == key then return end
  a.orders[unit] = key
  if key == 'attack' then
    -- The existing assault missions fire from range, one target at a time.
    combat.set_command(soldier, {type = defines.command.attack_area, destination = a.center,
      radius = a.radius + M.PUSH_MARGIN, distraction = defines.distraction.by_enemy})
  elseif key == 'slot' and a.surround then
    go_round(a, soldier, destination)
  else
    go(soldier, destination)
  end
end

local function set_phase(a, phase, tick)
  a.phase, a.phase_tick = phase, tick
end

local function start_push(a, members, c, tick)
  if c.flame == 0 then return set_phase(a, 'follow', tick) end
  a.flame_health = {}
  for _, e in ipairs(members) do
    if a.roles[e.unit_number] == 'flame' then a.flame_health[e.unit_number] = e.health end
  end
  set_phase(a, 'push', tick)
end

local function worms_in_reach(a)
  local reach, n = (a.worm_range + a.siege_range) ^ 2, 0
  local lines = {a.siege_center}
  if a.surround then
    for i, line in ipairs(siege_lines(a)) do lines[i] = line.point end
  end
  for _, s in ipairs(a.structures) do
    if s.worm and s.entity.valid and nearest_squared(lines, s.position) <= reach then n = n + 1 end
  end
  return n
end

local function flame_engaged(a, members)
  local edge = (a.radius + M.FLAME_EDGE) ^ 2
  for _, e in ipairs(members) do
    local unit = e.unit_number
    if a.roles[unit] == 'flame' then
      local before = a.flame_health[unit]
      if before and e.health < before then return true end
      if geometry.distance_squared(e.position, a.center) <= edge then return true end
    end
  end
  return false
end

local function attacking(a, role)
  local phase = a.phase
  if role == 'siege' then return phase ~= 'stage' end
  if role == 'flame' then return phase == 'push' or phase == 'follow' end
  return role == 'carrier' and phase == 'follow'
end

-- True when some soldier is attacking and every attacker's path failed
-- since the last kill: the nest cannot be reached.
local function all_failed(a, members)
  local any = false
  for _, e in ipairs(members) do
    local unit = e.unit_number
    if attacking(a, a.roles[unit]) then
      if not a.failed[unit] then return false end
      any = true
    end
  end
  return any
end

local function advance(a, members, c, tick)
  if a.phase == 'stage' then
    -- Only soldiers present at the start count: a recruit walking in from a
    -- distant barracks must not hold the whole division.
    local remaining = 0
    for _, e in ipairs(members) do
      local unit = e.unit_number
      if a.stagers[unit] then
        local d = geometry.distance(e.position, a.slots[unit])
        if d > M.ARRIVED then remaining = remaining + d end
      end
    end
    if not M.stage_over(a.progress, remaining, tick) then return end
    a.siege_center = siege_centroid(a, members)
    if a.siege_center then set_phase(a, 'barrage', tick) else start_push(a, members, c, tick) end
  elseif a.phase == 'barrage' then
    -- With every siege tank lost there is no barrage left to wait for.
    if c.siege == 0 or M.push_ready(worms_in_reach(a), tick - a.phase_tick) then start_push(a, members, c, tick) end
  elseif a.phase == 'push' then
    if M.follow_ready(flame_engaged(a, members), tick - a.phase_tick) then set_phase(a, 'follow', tick) end
  end
end

-- Every force that `force` is at war with, for nest searches.
function M.enemy_forces(force)
  local out = {}
  for _, other in pairs(game.forces) do
    if other ~= force and force.is_enemy(other) then out[#out + 1] = other end
  end
  return out
end

-- Starts a nest assault when a spawner of `forces` stands within
-- SPAWNER_REACH of origin, and keeps it as holder.assault. Returns true when
-- it started. Any division stages: one of a single kind skips the phases it
-- has no tanks for, so carriers alone gather on the arc and then attack
-- together. With surround, the staging slots ring the whole nest.
function M.start(holder, members, origin, forces, surround)
  local found = members[1].surface.find_entities_filtered{position = origin, radius = M.NEST_SEARCH,
    type = {'unit-spawner', 'turret'}, force = forces}
  local structures, nest, worm_range = {}, false, 0
  local reach = M.SPAWNER_REACH * M.SPAWNER_REACH
  for _, e in pairs(found) do
    local p = e.position
    local worm = e.type == 'turret'
    if worm then
      local attack = e.prototype.attack_parameters
      worm_range = math.max(worm_range, attack and attack.range or 0)
    elseif geometry.distance_squared(p, origin) <= reach then
      nest = true
    end
    structures[#structures + 1] = {entity = e, position = {x = p.x, y = p.y}, worm = worm}
  end
  if not nest then return false end
  local center, radius = M.nest_shape(structures)
  local from = geometry.centroid(members)
  local bearing = math.atan2(from.y - center.y, from.x - center.x)
  local standoff = M.standoff(radius, worm_range)
  local tick = game.tick
  local a = {
    structures = structures, center = center, radius = radius, worm_range = worm_range,
    siege_range = prototypes.entity['tank-squad-siege'].attack_parameters.range,
    bearing = bearing, standoff = standoff, arc_centre = geometry.slot_position(center, standoff, bearing),
    phase = 'stage', phase_tick = tick, roles = {}, screen = {}, stagers = {},
    slots = (surround and M.ring_slots or M.arc_slots)(members, center, standoff, bearing),
    screen_slots = {}, orders = {}, targets = {},
    progress = {}, failed = {}, kills = 0, last_kill_tick = tick, surround = surround or nil,
  }
  for _, e in ipairs(members) do
    adopt(a, e)
    a.stagers[e.unit_number] = true
  end
  refill_screen(a, members, count_roles(a))
  holder.assault = a
  for _, e in ipairs(members) do command(a, e) end
  return true
end

-- Called by the offensive formation once it has picked a leg target. Returns
-- true when a nest assault replaced the plain leg.
function M.try_start(state, members, target, forces)
  return M.start(state, members, target.position, forces)
end

-- One sweep of a running assault. members are the soldiers present, so
-- retreating soldiers lose their role and get it back through M.join.
function M.tick(a, members)
  local tick = game.tick
  local alive = 0
  for _, s in ipairs(a.structures) do if s.entity.valid then alive = alive + 1 end end
  local kills = #a.structures - alive
  if kills > a.kills then
    a.kills, a.last_kill_tick, a.failed = kills, tick, {}
    for unit, key in pairs(a.orders) do
      if key == 'failed' then a.orders[unit] = nil end
    end
  end
  if alive == 0 then return 'done' end
  if tick - a.last_kill_tick >= M.NO_KILL_TIMEOUT then return 'failed' end
  local present = {}
  for _, e in ipairs(members) do
    present[e.unit_number] = true
    if not a.roles[e.unit_number] then adopt(a, e) end
  end
  for unit in pairs(a.roles) do
    if not present[unit] then
      a.roles[unit], a.screen[unit], a.orders[unit], a.targets[unit], a.failed[unit] = nil, nil, nil, nil, nil
    end
  end
  local c = count_roles(a)
  if c.siege == 0 and c.screen > 0 then
    -- Nothing left to screen: the screen joins the attack.
    for unit in pairs(a.screen) do set_role(a, unit, 'carrier') end
  else
    -- A siege tank that arrives after staging ended without one sets the
    -- siege line here, so its screen gets positions.
    if c.siege > 0 and a.phase ~= 'stage' and not a.siege_center then a.siege_center = siege_centroid(a, members) end
    refill_screen(a, members, c)
  end
  if all_failed(a, members) then return 'failed' end
  advance(a, members, c, tick)
  if a.phase ~= 'stage' and a.siege_center then place_screen(a) end
  for _, e in ipairs(members) do command(a, e) end
end

-- A recruit, or a soldier back from healing. A carrier fills a short screen
-- first. Late soldiers never count towards the stage progress.
function M.join(a, soldier)
  local unit = soldier.unit_number
  adopt(a, soldier)
  a.stagers[unit], a.failed[unit] = nil, nil
  if a.roles[unit] == 'carrier' then
    local c = count_roles(a)
    if c.screen < M.screen_size(c.siege, c.carrier + c.screen) then set_role(a, unit, 'screen') end
  end
  command(a, soldier)
  return true
end

-- A soldier rebuilt as another unit keeps its staging slot and joins again
-- under the new unit number.
function M.replace(a, old_id, soldier)
  a.slots[soldier.unit_number] = a.slots[old_id]
  a.roles[old_id], a.screen[old_id], a.orders[old_id], a.targets[old_id] = nil, nil, nil, nil
  a.failed[old_id], a.stagers[old_id], a.slots[old_id], a.screen_slots[old_id] = nil, nil, nil, nil
  return M.join(a, soldier)
end

-- A finished fire or attack order is re-issued on the next sweep. Arrivals
-- at a slot or screen point are not, or every holding soldier would be
-- re-ordered every second. A failed path marks the soldier until the next
-- kill; when every attacker has failed, the assault gives up.
function M.on_command_completed(a, unit_number, result)
  local key = a.orders[unit_number]
  if key ~= 'fire' and key ~= 'attack' then return end
  a.targets[unit_number] = nil
  if result == defines.behavior_result.fail then
    a.orders[unit_number], a.failed[unit_number] = 'failed', true
  else
    a.orders[unit_number] = nil
  end
end

return M
