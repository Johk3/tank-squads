-- Crossing rings. Gates never open for units, and a path only goes
-- through a gate that is already open (engine probe, 2026-09-30). A unit
-- whose order lies across a ring first drives to the apron of a gatehouse
-- on its side; the gates open, it waits half a second, passes to the far
-- apron, and its order goes out again, which crosses the next ring the
-- same way. A charging shredder flies over walls, so it takes no gate.
--
-- storage.engineers.crossings[unit_number] = {entity, ring, gate, phase,
--   command, via, from, failed}. phase is 'approach', 'opening' or
-- 'through'; via 'combat' (the order came through combat.set_command) or
-- 'direct'; failed the gatehouses whose apron it found no path to.
local names = require('scripts.names')
local combat = require('scripts.combat')
local state = require('scripts.engineers.state')
local geometry = require('scripts.engineers.rings.geometry')
local layout = require('scripts.engineers.rings.layout')
local rings = require('scripts.engineers.rings.rings')

local M = {}

M.OPEN_TICKS = 15 * 60
M.WAIT_TICKS = 30
M.APRON_RADIUS = 3
-- Gatehouses a unit tries in turn when it finds no path to an apron.
M.TRIES = 3
-- Another gatehouse is tried only when its way is at most DETOUR times the
-- failed one's: a unit is never sent across the ring and back.
M.DETOUR = 2
-- A unit this close to the apron when its approach fails is there: a crowd
-- at the gatehouse reports failure to the last few units.
M.NEAR = 8

-- A built segment's gatehouse: its gates, found once, and its aprons.
function M.record(ring, i)
  local seg = geometry.segment(ring, i)
  local surface = game.surfaces[ring.surface_index]
  local gates = surface.find_entities_filtered{area = layout.gate_area(ring, seg), name = 'gate',
    force = game.forces[ring.force_index]}
  if #gates == 0 then
    ring.gatehouses[i] = nil
    return
  end
  ring.gatehouses[i] = {gates = gates, complete = true, inside = geometry.apron(ring, seg, 'inside'),
    outside = geometry.apron(ring, seg, 'outside')}
end

-- Every built segment's gatehouse, found again. Rings built before
-- gatehouses were recorded have none, so every crossing would go to the
-- few segments rebuilt since, however far away.
function M.record_built(ring)
  for i, seg in ipairs(ring.segments) do
    if seg.state == 'built' then M.record(ring, i) end
  end
end

-- A breach anywhere in the segment: its gatehouse is not used until the
-- segment is built again.
function M.breached(ring, i)
  local house = ring.gatehouses[i]
  if house then house.complete = false end
end

local function target_of(command)
  local kind = command.type
  if kind == defines.command.go_to_location or kind == defines.command.attack_area then return command.destination end
  if kind == defines.command.attack then
    local target = command.target
    return target and target.valid and target.position or nil
  end
  return nil
end

-- A ring is a barrier once it has been closed. While it goes up for the
-- first time its gaps are open, and the pathfinder takes them; a breach
-- later leaves at most a hole a unit may not fit through.
local function closed(ring)
  return ring.state == 'built' or (ring.state == 'building' and ring.closed == true)
end

-- The first closed ring on the way with a gatehouse: the innermost the unit
-- leaves when it starts inside, the outermost it enters when it starts
-- outside. A destination on a ring's band is on the unit's side.
function M.crossed(fs, surface_index, from, to)
  local best, best_side
  for _, ring in pairs(fs.slots) do
    if ring.surface_index == surface_index and closed(ring) and next(ring.gatehouses) then
      local a = geometry.side(ring, from.x, from.y)
      local b, on_band = geometry.side(ring, to.x, to.y)
      if not on_band and a ~= b then
        if not best or (a == 'inside' and ring.radius < best.radius) or (a == 'outside' and ring.radius > best.radius) then
          best, best_side = ring, a
        end
      end
    end
  end
  return best, best_side
end

local function distance(a, b)
  local dx, dy = a.x - b.x, a.y - b.y
  return math.sqrt(dx * dx + dy * dy)
end

local function way(house, side, from, to)
  local far = side == 'inside' and 'outside' or 'inside'
  return distance(from, house[side]) + distance(house[far], to)
end

-- The complete gatehouse with the shortest way through it, leaving out
-- the indices in `skip`, and its way.
function M.choose(ring, side, from, to, skip)
  local best, best_i, best_d
  for i, house in pairs(ring.gatehouses) do
    if house.complete and not (skip and skip[i]) then
      local d = way(house, side, from, to)
      if not best_d or d < best_d then best, best_i, best_d = house, i, d end
    end
  end
  return best, best_i, best_d
end

local function go(entity, point, command)
  local distraction = entity.name == names.headquarters and defines.distraction.none
    or (command.distraction or defines.distraction.by_enemy)
  entity.commandable.set_command{type = defines.command.go_to_location, destination = point,
    radius = M.APRON_RADIUS, distraction = distraction}
end

-- Sends the unit to a gatehouse when its order crosses a ring. Returns
-- true when it did. A new order for a unit already at or in the gatehouse,
-- still crossing the same way, only replaces the order it takes up after.
function M.route(entity, command, via)
  local s = state.peek()
  local list = s and s.crossings
  local id = entity.unit_number
  local current = list and list[id]
  if entity.name == names.shredder_charging then
    if current then list[id] = nil end
    return false
  end
  local fs = s and s.rings and s.rings[entity.force_index]
  local target = fs and target_of(command)
  local ring, side
  if target then ring, side = M.crossed(fs, entity.surface_index, entity.position, target) end
  if not ring then
    if current then list[id] = nil end
    return false
  end
  if current and current.ring == ring.key and current.from == side and current.phase ~= 'approach' then
    current.command, current.via = command, via
    return true
  end
  local house, index = M.choose(ring, side, entity.position, target)
  if not house then
    if current then list[id] = nil end
    return false
  end
  s.crossings = s.crossings or {}
  s.crossings[id] = {entity = entity, ring = ring.key, gate = index, phase = 'approach', command = command,
    via = via, from = side}
  go(entity, house[side], command)
  return true
end

local function open(house, force)
  for _, gate in ipairs(house.gates) do
    if gate.valid then gate.request_to_open(force, M.OPEN_TICKS) else house.complete = false end
  end
end

-- Gives the unit its order again. `cross` lets the next ring be crossed;
-- without it (after a failure) the order goes out as it is.
local function resume(entry, cross)
  local entity, command = entry.entity, entry.command
  if command.type == defines.command.attack and not (command.target and command.target.valid) then
    command = {type = defines.command.stop, ticks_to_wait = 1, distraction = defines.distraction.by_enemy}
  end
  if entry.via == 'direct' then
    if cross then combat.direct(entity, command) else entity.commandable.set_command(command) end
  else
    combat.set_command(entity, command, not cross)
  end
end

function M.on_command_completed(unit_number, result)
  local s = state.peek()
  local entry = s and s.crossings and s.crossings[unit_number]
  if not entry then return false end
  local entity = entry.entity
  if not entity.valid then
    s.crossings[unit_number] = nil
    return true
  end
  local ring = rings.by_key(entry.ring)
  local house = ring and ring.gatehouses[entry.gate]
  if result == defines.behavior_result.fail and house and entry.phase == 'approach'
      and distance(entity.position, house[entry.from]) <= M.NEAR then
    result = defines.behavior_result.success
  end
  -- No path to this apron: the next nearest gatehouse may have one, unless
  -- it is far out of the way.
  if result == defines.behavior_result.fail and house and entry.phase == 'approach' then
    entry.failed = entry.failed or {}
    entry.failed[entry.gate] = true
    local tried = 0
    for _ in pairs(entry.failed) do tried = tried + 1 end
    local target = tried < M.TRIES and target_of(entry.command)
    local other, index, d
    if target then other, index, d = M.choose(ring, entry.from, entity.position, target, entry.failed) end
    if other and d <= M.DETOUR * way(house, entry.from, entity.position, target) then
      entry.gate = index
      go(entity, other[entry.from], entry.command)
      return true
    end
  end
  if result == defines.behavior_result.fail or not house then
    s.crossings[unit_number] = nil
    resume(entry, false)
    return true
  end
  if entry.phase == 'approach' then
    open(house, entity.force)
    entry.phase = 'opening'
    entity.commandable.set_command{type = defines.command.stop, ticks_to_wait = M.WAIT_TICKS,
      distraction = defines.distraction.none}
  elseif entry.phase == 'opening' then
    open(house, entity.force)
    entry.phase = 'through'
    go(entity, house[entry.from == 'inside' and 'outside' or 'inside'], entry.command)
  else
    s.crossings[unit_number] = nil
    resume(entry, true)
  end
  return true
end

-- After an update: units on their way through a ring that is no barrier
-- (never closed, or gone) take their orders up again.
function M.release_open()
  local s = state.peek()
  if not (s and s.crossings) then return end
  local open = {}
  for id, entry in pairs(s.crossings) do
    local ring = rings.by_key(entry.ring)
    if not (ring and closed(ring)) then open[#open + 1] = id end
  end
  for _, id in ipairs(open) do
    local entry = s.crossings[id]
    s.crossings[id] = nil
    if entry.entity.valid then resume(entry, true) end
  end
end

function M.forget(unit_number)
  local s = state.peek()
  if s and s.crossings then s.crossings[unit_number] = nil end
end

-- Once per second: units that died without an event leave the list.
function M.sweep()
  local s = state.peek()
  if not (s and s.crossings) then return end
  local gone = {}
  for id, entry in pairs(s.crossings) do
    if not entry.entity.valid then gone[#gone + 1] = id end
  end
  for _, id in ipairs(gone) do s.crossings[id] = nil end
end

rings.on_segment_built = M.record
rings.on_breach = M.breached

return M
