local divisions = require('scripts.divisions')
local combat = require('scripts.combat')
local escort = require('scripts.escort')
local patrol = require('scripts.patrol')
local scout = require('scripts.scout')
local M = {}

local HEADQUARTERS_RECIPE = 'tank-squad-train-headquarters'

-- A headquarters is no carrier and leaves the target alone, except for a
-- barracks that trains headquarters: it counts them, or it would train
-- them without end. The recipe is only read while the division has one.
local function counted(b, binding, members)
  local headquarters = divisions.headquarters_count(binding.player_index, binding.division)
  if headquarters == 0 then return #members end
  local recipe = b.entity.get_recipe()
  if recipe and recipe.name == HEADQUARTERS_RECIPE then return #members end
  return #members - headquarters
end

function M.release(b)
  local binding = b.reinforcement
  if binding then
    local state = storage.divisions and storage.divisions[binding.player_index]
    local record = state and state.slots[binding.division]
    if record and record.reinforcement_sources then
      record.reinforcement_sources[b.unit_number] = nil
      if not next(record.reinforcement_sources) then
        record.reinforcement_surface_index = nil
        record.reinforcement_target = nil
      end
    end
  end
  b.reinforcement = nil
  if b.entity.valid and b.reinforcement_paused then b.entity.active = true end
  b.reinforcement_paused = nil
end

function M.configure(b, player_index, n, target)
  local player = game.get_player(player_index)
  if not (player and b.entity.valid and b.entity.force == player.force) then return false end
  if b.reinforcement and b.reinforcement.player_index ~= player_index then return false end
  if n == nil then M.release(b); return true end
  if type(n) ~= 'number' or n % 1 ~= 0 or n < 1 or n > 9 then return false end
  if type(target) ~= 'number' or target % 1 ~= 0 or target < 1 or target > 1000 then return false end
  local record = divisions.record(player_index, n)
  local surface_index = b.entity.surface.index
  if record.reinforcement_surface_index and record.reinforcement_surface_index ~= surface_index then return false end
  for _, member in ipairs(divisions.get(player_index, n)) do
    if member.surface_index ~= surface_index then return false end
  end
  local route_surface = (record.patrol and record.patrol.surface_index)
    or (record.scout and record.scout.surface_index) or (record.escort and record.escort.surface_index)
    or (record.order and record.order.surface_index)
  if route_surface and route_surface ~= surface_index then return false end
  M.release(b)
  b.unit_number = b.entity.unit_number
  b.reinforcement = {player_index = player_index, division = n}
  record.reinforcement_sources = record.reinforcement_sources or {}
  record.reinforcement_sources[b.unit_number] = true
  record.reinforcement_surface_index = surface_index
  record.reinforcement_target = target
  return true
end

function M.needs_recruit(b)
  local binding = b.reinforcement
  if not binding then return true end
  local player = game.get_player(binding.player_index)
  if not player or player.force ~= b.entity.force then M.release(b); return false end
  local record = divisions.record(binding.player_index, binding.division)
  local count = counted(b, binding, divisions.cached(binding.player_index, binding.division))
  local route_surface = (record.patrol and record.patrol.surface_index)
    or (record.scout and record.scout.surface_index) or (record.escort and record.escort.surface_index)
    or (record.order and record.order.surface_index)
  if route_surface and route_surface ~= b.entity.surface.index then return false end
  return count < (record.reinforcement_target or 0)
end

function M.sync_production(b)
  local needed = M.needs_recruit(b)
  if b.reinforcement and not needed then
    if b.entity.active then b.reinforcement_paused = true; b.entity.active = false end
  elseif b.reinforcement_paused then
    b.entity.active = true
    b.reinforcement_paused = nil
  end
  return needed
end

function M.join(b, soldier)
  local binding = b.reinforcement
  if not binding then return false end
  local record = divisions.record(binding.player_index, binding.division)
  -- A new entity has no previous owner. Appending must not select the division,
  -- detach survivors, or restart their combat/pathfinding commands.
  divisions.add_member(binding.player_index, binding.division, soldier.unit_number, soldier)
  if patrol.join(record, soldier) then return true end
  if scout.join(record, soldier) then return true end
  if record.mode == 'escort' then return escort.join(record, soldier) end
  if record.mode == 'idle' and record.order then
    combat.set_command(soldier, record.order.command)
    return true
  end
  return false
end

return M
