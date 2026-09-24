-- Staged nest assault for offensive escorts: the division gathers on a
-- staging arc outside the nest, siege tanks open a barrage on the worms,
-- flame tanks push in, and carriers follow. A few carriers screen the siege
-- line. Only scripts/escort.lua calls this module.
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

local KINDS = {['tank-squad-siege'] = 'siege', ['tank-squad-flame'] = 'flame'}

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

-- Slots SLOT_SPACING tiles apart along the arc, centred on the bearing. The
-- soldiers keep their angular order around the nest, so no two paths cross.
-- A division too big for the arc wraps evenly around the whole circle.
function M.arc_slots(members, center, distance, bearing)
  local count = #members
  local step = math.min(M.SLOT_SPACING / distance, 2 * math.pi / math.max(count, 1))
  local sorted = {}
  for _, e in ipairs(members) do
    local p = e.position
    local offset = math.atan2(p.y - center.y, p.x - center.x) - bearing
    sorted[#sorted + 1] = {id = e.unit_number, offset = (offset + math.pi) % (2 * math.pi) - math.pi}
  end
  table.sort(sorted, function(a, b)
    if a.offset ~= b.offset then return a.offset < b.offset end
    return a.id < b.id
  end)
  local slots = {}
  for i, s in ipairs(sorted) do
    slots[s.id] = geometry.slot_position(center, distance, bearing + (i - (count + 1) / 2) * step)
  end
  return slots
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

local function go(soldier, destination)
  combat.set_command(soldier, {type = defines.command.go_to_location, destination = destination,
    radius = 4, distraction = defines.distraction.by_enemy})
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

-- Promotes the carriers nearest the siege line until the screen is full.
-- Never demotes while siege tanks remain, so the screen does not reshuffle
-- when a carrier dies. Reads carrier positions only when a slot is empty.
local function refill_screen(a, members, c)
  local missing = M.screen_size(c.siege, c.carrier + c.screen) - c.screen
  if missing <= 0 then return end
  local anchor = a.siege_center or siege_centroid(a, members)
  if not anchor then return end
  local carriers = {}
  for _, e in ipairs(members) do
    if a.roles[e.unit_number] == 'carrier' then
      carriers[#carriers + 1] = {id = e.unit_number, d = geometry.distance_squared(e.position, anchor)}
    end
  end
  table.sort(carriers, function(p, q)
    if p.d ~= q.d then return p.d < q.d end
    return p.id < q.id
  end)
  for i = 1, math.min(missing, #carriers) do set_role(a, carriers[i].id, 'screen') end
end

local function place_screen(a)
  local units = {}
  for unit in pairs(a.screen) do units[#units + 1] = unit end
  table.sort(units)
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
  for _, s in ipairs(a.structures) do
    if s.worm and s.entity.valid and geometry.distance_squared(s.position, a.siege_center) <= reach then n = n + 1 end
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

-- Called by the offensive formation once it has picked a leg target. Returns
-- true when a nest assault replaced the plain leg. The kind check runs first,
-- so a single-kind division never searches.
function M.try_start(state, members, target, forces)
  local kinds, count = {}, 0
  for _, e in ipairs(members) do
    local kind = M.kind(e.name)
    if not kinds[kind] then kinds[kind], count = true, count + 1 end
  end
  if count < 2 then return false end
  local origin = target.position
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
    slots = M.arc_slots(members, center, standoff, bearing), screen_slots = {}, orders = {}, targets = {},
    progress = {}, failed = {}, kills = 0, last_kill_tick = tick,
  }
  for _, e in ipairs(members) do
    adopt(a, e)
    a.stagers[e.unit_number] = true
  end
  refill_screen(a, members, count_roles(a))
  state.assault = a
  for _, e in ipairs(members) do command(a, e) end
  return true
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
