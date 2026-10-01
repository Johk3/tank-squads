-- Soldiers in a constructor's way. At the start of each crane cycle the
-- constructor sends its force's soldiers off the cluster's ghosts, so the
-- walls are not held up, and off a ring's band around the cluster, so no
-- wall shuts them in. On a band they go to the constructor's side of it
-- (rings.stand); off a band, away from the cluster. One area search per
-- crane cycle.
--
-- A soldier whose order fails while it stands on a ring's band is walled
-- in there. It is moved off the band, to the side of the ring it is on,
-- as constructor.escape moves a constructor.
--
-- Parked shredders make way as soldiers do. A shredder about to strike
-- (igniting) or charging is left alone.
local names = require('scripts.names')
local combat = require('scripts.combat')
local shredders = require('scripts.shredders')
local state = require('scripts.engineers.state')
local rings = require('scripts.engineers.rings.rings')
local geometry = require('scripts.engineers.rings.geometry')

local M = {}

-- Tiles around the cluster centre searched: the cluster radius (3), half
-- a wall and half a hull, and a row of band beyond.
M.REACH = 6
-- A soldier this close to a ghost's centre stands on it: half a wall and
-- half a soldier's hull (0.6).
M.TOUCH = 1.1
-- Tiles beyond the farthest ghost a soldier is sent off a player's ghosts.
M.AWAY = 4
-- How close a soldier must get to the spot it is sent to.
M.RADIUS = 1
-- Ticks a soldier sent away is left alone while it drives off.
M.PATIENCE = 3 * 60
-- Tiles around a stuck constructor's hull searched by shove.
M.SHOVE = 3

-- A unit of the force that makes way: a soldier, or a shredder that is
-- parked or driving to its post.
local function movable(unit)
  if names.soldier_set[unit.name] then return true end
  return unit.name == names.shredder and shredders.ready(unit.unit_number)
end

-- The point `reach` tiles from centre in the direction of position. A
-- soldier on the centre itself goes toward `from` (the constructor).
function M.away(centre, position, from, reach)
  local dx, dy = position.x - centre.x, position.y - centre.y
  local length = math.sqrt(dx * dx + dy * dy)
  if length < 1e-6 then
    dx, dy = from.x - centre.x, from.y - centre.y
    length = math.sqrt(dx * dx + dy * dy)
    if length < 1e-6 then dx, dy, length = 0, 1, 1 end
  end
  return {x = centre.x + dx / length * reach, y = centre.y + dy / length * reach}
end

-- The distance from the centre to the farthest ghost, and whether
-- position stands on one of them.
local function extent(cluster, centre, position)
  local reach, touching = 0, false
  local t2 = M.TOUCH * M.TOUCH
  for _, entry in ipairs(cluster) do
    local p = entry.position
    local dx, dy = p.x - centre.x, p.y - centre.y
    reach = math.max(reach, math.sqrt(dx * dx + dy * dy))
    dx, dy = position.x - p.x, position.y - p.y
    if dx * dx + dy * dy <= t2 then touching = true end
  end
  return reach, touching
end

-- Where a soldier at position goes to make way, or nil when it is not in
-- the way.
local function spot(record, position)
  local on_band = rings.stand(record, position)
  if on_band then return on_band end
  local reach, touching = extent(record.cluster, record.centre, position)
  if not touching then return nil end
  return M.away(record.centre, position, record.entity.position, reach + M.AWAY)
end

-- Sends the soldiers in the way of the record's cluster off it. Returns
-- how many it sent.
function M.clear(record)
  local entity, centre, cluster = record.entity, record.centre, record.cluster
  if not (entity.valid and centre and cluster and #cluster > 0) then return 0 end
  local found = entity.surface.find_entities_filtered{position = centre, radius = M.REACH, type = 'unit',
    force = entity.force}
  local tick, sent, n = game.tick, record.sent_away, 0
  if sent then
    for id, at in pairs(sent) do
      if tick - at >= M.PATIENCE then sent[id] = nil end
    end
  end
  local s = state.peek()
  local crossings = s and s.crossings
  for _, unit in pairs(found) do
    local id = unit.unit_number
    if movable(unit) and not (sent and sent[id]) and not (crossings and crossings[id]) then
      local destination = spot(record, unit.position)
      if destination then
        -- A short hop off the band to the near side: no gate on the way.
        combat.set_command(unit, {type = defines.command.go_to_location, destination = destination,
          radius = M.RADIUS, distraction = defines.distraction.by_enemy}, true)
        sent = sent or {}
        sent[id] = tick
        n = n + 1
      end
    end
  end
  record.sent_away = sent and next(sent) and sent or nil
  return n
end

-- A soldier's order failed. One on a ring's band is moved off it, to the
-- side of the ring it is on. Returns true when it was moved.
function M.escape(unit_number, result)
  if result ~= defines.behavior_result.fail then return false end
  local s = state.peek()
  if not (s and s.rings) then return false end
  local unit = game.get_entity_by_unit_number(unit_number)
  if not (unit and unit.valid and (names.soldier_set[unit.name] or unit.name == names.shredder)) then
    return false
  end
  local fs = rings.peek(unit.force_index)
  local p = unit.position
  local ring = fs and rings.find(fs, unit.surface_index, p)
  if not ring then return false end
  local target = geometry.stand(ring, p.x, p.y, (geometry.side(ring, p.x, p.y)))
  target = unit.surface.find_non_colliding_position(unit.name, target, 8, 0.5)
  return target ~= nil and unit.teleport(target)
end

-- A constructor that has not moved for a while: the force's units
-- around its hull are sent straight away from it. Returns how many.
function M.shove(entity)
  local centre = entity.position
  local s = state.peek()
  local crossings = s and s.crossings
  local n = 0
  for _, unit in pairs(entity.surface.find_entities_filtered{position = centre, radius = M.SHOVE, type = 'unit',
      force = entity.force}) do
    if movable(unit) and not (crossings and crossings[unit.unit_number]) then
      combat.set_command(unit, {type = defines.command.go_to_location,
        destination = M.away(centre, unit.position, centre, M.SHOVE + M.AWAY),
        radius = M.RADIUS, distraction = defines.distraction.by_enemy}, true)
      n = n + 1
    end
  end
  return n
end

-- A position on one of the force's ring bands moved off it, to the side of
-- the ring the position is on; nil off every band. Shredders post and land
-- through this (shredders.keep_off), so they never wait where walls go up.
function M.off_band(force_index, surface_index, position)
  local fs = rings.peek(force_index)
  local ring = fs and rings.find(fs, surface_index, position)
  if not ring then return nil end
  return geometry.stand(ring, position.x, position.y, (geometry.side(ring, position.x, position.y)))
end

return M
