-- Healing retreat for escorting divisions: retreating soldiers travel in
-- convoys with guards. escort.lua calls sweep() once per escort sweep with the members on
-- the escort surface. The state lives inside the escort state, so anything
-- that ends the escort drops every convoy with it.
local combat = require("scripts.combat")

local M = {}

-- A convoy that makes no progress for this long rejoins, and its unhealed
-- soldiers wait this long before retreating again. Progress is closing in on
-- the barracks or standing in its healing radius, so a long walk at a large
-- search range is never cut short. Matches escort.LEG_TIMEOUT.
M.TIMEOUT = 3 * 3600
-- Keeps the convoy well inside the barracks' 12-tile healing radius.
M.ARRIVAL_RADIUS = 6
M.HEAL_RADIUS = 12
-- A second failed path to the barracks ends the convoy.
M.FAILURE_LIMIT = 2

-- Two reads per soldier: quality can change maximum health per entity, so it
-- is not cached per prototype.
local function ratio(soldier)
  return soldier.health / soldier.max_health
end

local function guard_count(size)
  if size > 20 then return 2 end
  if size > 10 then return 1 end
  return 0
end

local function distance_squared(a, b)
  local dx, dy = a.x - b.x, a.y - b.y
  return dx * dx + dy * dy
end

-- Barracks of the escort's force on its surface, with their positions, read
-- once per sweep however many soldiers need one. Walks the registry owned by
-- scripts/barracks.lua (entries are {entity = LuaEntity, ...}); requiring
-- barracks.lua here would create a require cycle through reinforcements.lua
-- and escort.lua.
local function barracks_in_reach(context)
  local out = {}
  for _, b in ipairs(storage.barracks or {}) do
    local e = b.entity
    if e.valid and e.surface_index == context.surface_index and e.force == context.force then
      out[#out + 1] = {entity = e, position = e.position}
    end
  end
  return out
end

-- Returns the index into `list` of the nearest barracks within range, and
-- the distance to it.
local function nearest_barracks(list, position, range)
  local best, best_d = nil, range * range
  for i, b in ipairs(list) do
    local d = distance_squared(b.position, position)
    if d <= best_d then best, best_d = i, d end
  end
  return best, best and math.sqrt(best_d)
end

local function send(soldier, destination)
  combat.set_command(soldier, {type = defines.command.go_to_location, destination = destination,
    radius = M.ARRIVAL_RADIUS, distraction = defines.distraction.by_enemy})
end

local function release(r, unit, soldier, context, unhealed)
  r.away[unit] = nil
  if unhealed then r.cooldown[unit] = game.tick + M.TIMEOUT end
  context.on_rejoin(soldier)
end

-- Every member rejoins. Injured soldiers that did not heal get the cooldown.
local function disband(r, id, convoy, by_id, context, unhealed)
  for unit in pairs(convoy.injured) do release(r, unit, by_id[unit], context, unhealed) end
  for unit in pairs(convoy.guards) do release(r, unit, by_id[unit], context, false) end
  r.convoys[id] = nil
end

local function lowest(set)
  local best
  for unit in pairs(set) do
    if not best or unit < best then best = unit end
  end
  return best
end

local function send_convoy(convoy, by_id)
  for unit in pairs(convoy.injured) do send(by_id[unit], convoy.destination) end
  for unit in pairs(convoy.guards) do send(by_id[unit], convoy.destination) end
end

local function closest_injured(convoy, by_id)
  local closest
  for unit in pairs(convoy.injured) do
    local d = math.sqrt(distance_squared(by_id[unit].position, convoy.destination))
    if not closest or d < closest then closest = d end
  end
  return closest
end

-- Returns true when any member rejoined.
local function advance(r, id, convoy, by_id, context)
  for unit in pairs(convoy.injured) do
    if not by_id[unit] then convoy.injured[unit] = nil end
  end
  for unit in pairs(convoy.guards) do
    if not by_id[unit] then convoy.guards[unit] = nil end
  end
  local changed = false
  for unit in pairs(convoy.injured) do
    local soldier = by_id[unit]
    if ratio(soldier) >= context.rejoin then
      convoy.injured[unit] = nil
      release(r, unit, soldier, context, false)
      changed = true
    end
  end
  if not next(convoy.injured) then
    disband(r, id, convoy, by_id, context, false)
    return true
  end
  if convoy.failures >= M.FAILURE_LIMIT then
    disband(r, id, convoy, by_id, context, true)
    return true
  end
  if not convoy.barracks.valid then
    local list = barracks_in_reach(context)
    local i, distance = nearest_barracks(list, by_id[lowest(convoy.injured)].position, context.range)
    if not i then
      disband(r, id, convoy, by_id, context, true)
      return true
    end
    convoy.barracks, convoy.destination = list[i].entity, list[i].position
    convoy.best, convoy.progress = distance, game.tick
    send_convoy(convoy, by_id)
    return changed
  end
  local closest = closest_injured(convoy, by_id)
  if closest <= M.HEAL_RADIUS or closest < convoy.best - 1 then
    convoy.best, convoy.progress = closest, game.tick
  end
  if game.tick - convoy.progress >= M.TIMEOUT then
    disband(r, id, convoy, by_id, context, true)
    return true
  end
  -- Only after a completion: re-sending a soldier that is still walking
  -- would restart its pathfinding every sweep.
  local limit = (M.ARRIVAL_RADIUS + 2) ^ 2
  for unit in pairs(convoy.resend) do
    local soldier = by_id[unit]
    if soldier and distance_squared(soldier.position, convoy.destination) > limit then
      send(soldier, convoy.destination)
    end
  end
  convoy.resend = {}
  return changed
end

-- Advances convoys, then drops away marks and cooldowns of soldiers that
-- left the division. Returns true when any member rejoined.
local function settle(r, members, context)
  local by_id = {}
  for _, soldier in ipairs(members) do by_id[soldier.unit_number] = soldier end
  local changed = false
  for id, convoy in pairs(r.convoys) do
    if advance(r, id, convoy, by_id, context) then changed = true end
  end
  for unit in pairs(r.away) do
    if not by_id[unit] then r.away[unit] = nil end
  end
  for unit, expiry in pairs(r.cooldown) do
    if expiry <= game.tick or not by_id[unit] then r.cooldown[unit] = nil end
  end
  return changed
end

local function without_away(r, members)
  if not next(r.away) then return members end
  local out = {}
  for _, soldier in ipairs(members) do
    if not r.away[soldier.unit_number] then out[#out + 1] = soldier end
  end
  return out
end

local function guard_candidates(present, context)
  local out = {}
  for _, soldier in ipairs(present) do
    local unit = soldier.unit_number
    local health = ratio(soldier)
    if health >= context.retreat and unit ~= context.leader
        and not (context.responders and context.responders[unit] ~= nil) then
      out[#out + 1] = {unit = unit, soldier = soldier, health = health}
    end
  end
  table.sort(out, function(a, b)
    if a.health ~= b.health then return a.health > b.health end
    return a.unit < b.unit
  end)
  return out
end

-- Returns the present members and whether anyone left or rejoined, which
-- means the formation must re-space. A division with no injured soldiers and
-- no convoys costs one health ratio per soldier and allocates nothing.
function M.sweep(state, members, context)
  local r = state.retreat
  if not r then
    r = {next_id = 1, convoys = {}, away = {}, cooldown = {}}
    state.retreat = r
  end
  local changed = false
  if next(r.convoys) or next(r.cooldown) then changed = settle(r, members, context) end
  local present = without_away(r, members)
  local groups, order, list = {}, {}, nil
  for _, soldier in ipairs(present) do
    if ratio(soldier) < context.retreat then
      local unit = soldier.unit_number
      if not r.cooldown[unit] then
        list = list or barracks_in_reach(context)
        local key, distance = nearest_barracks(list, soldier.position, context.range)
        if key then
          if not groups[key] then
            groups[key] = {barracks = list[key], injured = {}, best = distance}
            order[#order + 1] = key
          end
          local group = groups[key]
          group.injured[#group.injured + 1] = soldier
          group.best = math.min(group.best, distance)
        end
      end
    end
  end
  if #order == 0 then return present, changed end
  table.sort(order)
  local candidates = guard_candidates(present, context)
  local per_convoy, next_guard = guard_count(#members), 1
  for _, key in ipairs(order) do
    local group = groups[key]
    local id = r.next_id
    r.next_id = id + 1
    local destination = group.barracks.position
    local convoy = {barracks = group.barracks.entity, destination = destination, progress = game.tick,
      best = group.best, injured = {}, guards = {}, resend = {}, failures = 0}
    r.convoys[id] = convoy
    for _, soldier in ipairs(group.injured) do
      local unit = soldier.unit_number
      convoy.injured[unit], r.away[unit] = true, id
      send(soldier, destination)
    end
    for _ = 1, per_convoy do
      local entry = candidates[next_guard]
      if not entry then break end
      next_guard = next_guard + 1
      convoy.guards[entry.unit], r.away[entry.unit] = true, id
      send(entry.soldier, destination)
    end
  end
  return without_away(r, members), true
end

-- A completion from an away soldier. Any completion re-checks its position on
-- the next sweep, so a soldier pushed out of healing range by a fight walks
-- back. Failed paths of injured soldiers count towards ending the convoy.
function M.on_command_completed(state, unit_number, result)
  local r = state.retreat
  local id = r and r.away[unit_number]
  local convoy = id and r.convoys[id]
  if not convoy then return end
  if result == defines.behavior_result.fail and convoy.injured[unit_number] then
    convoy.failures = convoy.failures + 1
  end
  convoy.resend[unit_number] = true
end

function M.is_away(state, unit_number)
  local r = state.retreat
  return r ~= nil and r.away[unit_number] ~= nil
end

return M
