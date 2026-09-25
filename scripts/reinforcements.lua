local divisions = require('scripts.divisions')
local combat = require('scripts.combat')
local escort = require('scripts.escort')
local patrol = require('scripts.patrol')
local scout = require('scripts.scout')
local M = {}

local HEADQUARTERS_RECIPE = 'tank-squad-train-headquarters'

-- Each linked barracks keeps its own quota: the number of soldiers it
-- trained that still serve in the division. The division record holds one
-- source per barracks, keyed by the barracks' unit number.
local function source(b)
  local binding = b.reinforcement
  local state = storage.divisions and storage.divisions[binding.player_index]
  local record = state and state.slots[binding.division]
  return record, record and record.reinforcement_sources and record.reinforcement_sources[b.unit_number]
end

-- The target and recruits of a linked barracks, or nil when it is unlinked.
function M.quota(b)
  if not b.reinforcement then return nil end
  local _, own = source(b)
  if not own then return nil end
  return own.target, divisions.serving(b.reinforcement.player_index, b.reinforcement.division, own.recruits)
end

function M.release(b)
  if b.reinforcement then
    local record, own = source(b)
    if own then
      record.reinforcement_sources[b.unit_number] = nil
      if not next(record.reinforcement_sources) then record.reinforcement_surface_index = nil end
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
  b.unit_number = b.entity.unit_number
  -- A new target for the same division keeps the soldiers already trained.
  local binding = b.reinforcement
  local own = binding and binding.division == n and select(2, source(b))
  if own then own.target = target; return true end
  M.release(b)
  b.reinforcement = {player_index = player_index, division = n}
  record.reinforcement_sources = record.reinforcement_sources or {}
  record.reinforcement_sources[b.unit_number] = {target = target, recruits = {}}
  record.reinforcement_surface_index = surface_index
  return true
end

function M.needs_recruit(b)
  local binding = b.reinforcement
  if not binding then return true end
  local player = game.get_player(binding.player_index)
  if not player or player.force ~= b.entity.force then M.release(b); return false end
  local record, own = source(b)
  if not own then M.release(b); return false end
  -- Validates the roster once per sweep, so departed recruits leave the quota.
  divisions.cached(binding.player_index, binding.division)
  local route_surface = (record.patrol and record.patrol.surface_index)
    or (record.scout and record.scout.surface_index) or (record.escort and record.escort.surface_index)
    or (record.order and record.order.surface_index)
  if route_surface and route_surface ~= b.entity.surface.index then return false end
  return divisions.serving(binding.player_index, binding.division, own.recruits) < own.target
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
  local record, own = source(b)
  if not own then return false end
  -- A new entity has no previous owner. Appending must not select the division,
  -- detach survivors, or restart their combat/pathfinding commands.
  divisions.add_member(binding.player_index, binding.division, soldier.unit_number, soldier)
  own.recruits[#own.recruits + 1] = soldier.unit_number
  if patrol.join(record, soldier) then return true end
  if scout.join(record, soldier) then return true end
  if record.mode == 'escort' then return escort.join(record, soldier) end
  if record.mode == 'idle' and record.order then
    combat.set_command(soldier, record.order.command)
    return true
  end
  return false
end

-- Saves from before 0.18.0 hold one target per division, shared by all its
-- linked barracks. Split that target between the barracks and give each one
-- its share of the current members, so no barracks trains extra soldiers.
-- A headquarters goes only to a barracks that trains headquarters, which
-- counted every member before.
function M.upgrade()
  local by_unit = {}
  for _, b in ipairs(storage.barracks or {}) do
    if b.entity.valid then by_unit[b.entity.unit_number] = b end
  end
  local function trains_headquarters(id)
    local b = by_unit[id]
    local recipe = b and b.entity.get_recipe()
    return recipe ~= nil and recipe.name == HEADQUARTERS_RECIPE
  end
  for player_index, state in pairs(storage.divisions or {}) do
    for n, record in pairs(state.slots) do
      local legacy = {}
      for id, value in pairs(record.reinforcement_sources or {}) do
        if value == true then legacy[#legacy + 1] = id end
      end
      if #legacy > 0 then
        -- Carrier barracks first, so they take the carriers.
        table.sort(legacy, function(a, c)
          local ha, hc = trains_headquarters(a), trains_headquarters(c)
          if ha ~= hc then return hc end
          return a < c
        end)
        local total = record.reinforcement_target or 0
        local claimed = {}
        for i, id in ipairs(legacy) do
          local share = math.floor(total / #legacy) + (i <= total % #legacy and 1 or 0)
          local own = {target = math.max(1, share), recruits = {}}
          local any = trains_headquarters(id)
          for _, member in ipairs(divisions.get(player_index, n)) do
            if #own.recruits >= own.target then break end
            local unit = member.unit_number
            if not claimed[unit] and (any or not (storage.headquarters and storage.headquarters[unit])) then
              claimed[unit] = true
              own.recruits[#own.recruits + 1] = unit
            end
          end
          record.reinforcement_sources[id] = own
        end
      end
      record.reinforcement_target = nil
    end
  end
end

return M
