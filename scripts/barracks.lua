local combat = require("scripts.combat")
local names = require("scripts.names")
local weapons = require("scripts.weapons")
local reinforcements = require('scripts.reinforcements')
local divisions = require('scripts.divisions')
local headquarters = require('scripts.headquarters')

local M = {}

local HEAL_RADIUS = 12
local HEAL_AMOUNT = 20
-- Bounded search radius for resolving a barracks' nearest rally flag. The
-- healing radius (12) is much smaller than a sensible rally distance, so this
-- is deliberately generous while still being a bounded area scan instead of an
-- unbounded whole-surface one.
local RALLY_SEARCH_RADIUS = 200
-- How many soldiers one barracks may deploy in a single sweep. The engine can
-- only finish one craft per recipe duration, so this only ever matters for a
-- machine whose output backed up while deployment was blocked.
local DEPLOYS_PER_SWEEP = 4

function M.register(entity)
  storage.barracks = storage.barracks or {}
  for _, b in pairs(storage.barracks) do
    if b.entity.valid and b.entity.unit_number == entity.unit_number then return end
  end
  table.insert(storage.barracks, {entity = entity, unit_number = entity.unit_number, rally_unit_number = nil, rally_entity = nil})
end

function M.record(entity)
  if type(entity) ~= 'table' and type(entity) ~= 'userdata' then return nil end
  if not (entity and entity.valid and entity.name == names.barracks) then return nil end
  for _, b in ipairs(storage.barracks or {}) do
    if b.entity == entity then return b end
  end
end

function M.configure(entity, player_index, n, target)
  local b = M.record(entity)
  return b ~= nil and reinforcements.configure(b, player_index, n, target)
end

function M.clear_player(player_index)
  for _, b in ipairs(storage.barracks or {}) do
    if b.reinforcement and b.reinforcement.player_index == player_index then reinforcements.release(b) end
  end
end

local function stop_animation(b)
  if b.animation and b.animation.valid then b.animation.destroy() end
  b.animation = nil
end

local function animate_deploy(b)
  stop_animation(b)
  local speed = 4 / 60
  b.animation = rendering.draw_animation{
    animation = "tank-squad-barracks-deploy",
    target = b.entity, surface = b.entity.surface,
    -- Rendering uses the absolute game tick, not the object's creation tick.
    -- Cancel that phase so a deployment always starts with a closed door.
    render_layer = "object", animation_offset = -game.tick * speed,
    animation_speed = speed,
    time_to_live = 60,
  }
end

function M.unregister(unit_number)
  if not storage.barracks then return end
  for i = #storage.barracks, 1, -1 do
    local b = storage.barracks[i]
    if (not b.entity.valid) or b.entity.unit_number == unit_number then
      stop_animation(b)
      reinforcements.release(b)
      table.remove(storage.barracks, i)
    end
  end
end

-- Resolves (and caches) the barracks' rally point. The cached entity is
-- validated in O(1) via LuaEntity.valid; re-resolving a new nearest flag only
-- happens when the cached one is missing or destroyed, and does a bounded area
-- search (RALLY_SEARCH_RADIUS) rather than an unbounded whole-surface scan.
-- LuaEntity is serialisable, so caching it directly in storage is save/load
-- safe.
local function rally_position(b)
  if b.rally_entity then
    if b.rally_entity.valid then
      return b.rally_entity.position
    end
    b.rally_entity = nil
    b.rally_unit_number = nil
  end

  local surface = b.entity.surface
  local pos = b.entity.position
  local nearest, best = nil, nil
  for _, flag in pairs(surface.find_entities_filtered{
    position = pos, radius = RALLY_SEARCH_RADIUS, name = names.flag, force = b.entity.force,
  }) do
    local dx, dy = flag.position.x - pos.x, flag.position.y - pos.y
    local d = dx * dx + dy * dy
    if (not best) or d < best then best, nearest = d, flag end
  end
  if nearest then
    b.rally_entity = nearest
    b.rally_unit_number = nearest.unit_number
    return nearest.position
  end
  return b.entity.position
end

local function heal_nearby(b)
  local surface = b.entity.surface
  local pos = b.entity.position
  for _, soldier in pairs(surface.find_entities_filtered{position = pos, radius = HEAL_RADIUS, name = names.unit_names, force = b.entity.force}) do
    if soldier.health < soldier.max_health then
      soldier.health = math.min(soldier.max_health, soldier.health + HEAL_AMOUNT)
    end
  end
end

-- Returns true when a soldier of that tier actually walked out. Returning
-- false leaves the recruit item in the machine's output inventory, where the
-- engine reports it as "output full" and no further work is lost.
local function deploy(b, tier)
  local surface = b.entity.surface
  local name = names.unit_names[tier]
  local large = name == names.headquarters
  -- The headquarters' body is much wider than the entrance, so it needs a
  -- wider search for a free spot.
  local entrance = {x = b.entity.position.x, y = b.entity.position.y + (large and 8 or 2.5)}
  local position = surface.find_non_colliding_position(name, entrance, large and 32 or 16, 1)
  if not position then return false end
  local soldier = surface.create_entity{name = name, position = position, force = b.entity.force}
  if not soldier then return false end
  if large then headquarters.register(soldier) else weapons.register(soldier) end

  if not reinforcements.join(b, soldier) then
    combat.set_command(soldier, {
      type = defines.command.go_to_location,
      destination = rally_position(b),
      distraction = defines.distraction.by_enemy,
      radius = 4,
    })
  end
  animate_deploy(b)
  return true
end

-- Mining hands the output inventory to the player, where a recruit item can
-- never become a soldier. Deploy every buffered recruit first: a linked
-- barracks fills its division up to the target, and the rest walk to the
-- rally point. A recruit with no free space nearby is still lost.
function M.evacuate(entity)
  local b = M.record(entity)
  local output = b and entity.get_output_inventory()
  if not output then return end
  for tier, item in pairs(names.recruit_names) do
    while output.get_item_count(item) > 0 do
      if b.reinforcement and not reinforcements.needs_recruit(b) then reinforcements.release(b) end
      if not deploy(b, tier) then break end
      output.remove{name = item, count = 1}
    end
  end
end

-- A linked barracks runs in its division's phase, right after that
-- division's roster was validated. Others spread by unit number.
local function in_phase(b, phase)
  if phase == nil then return true end
  local binding = b.reinforcement
  if binding then return divisions.phase(binding.player_index, binding.division) == phase end
  return (b.unit_number or 0) % divisions.PHASES == phase
end

-- With a phase, control.lua has just run divisions.refresh(phase), which
-- validated every roster this phase's barracks are linked to. A full sweep
-- (nil phase) validates each linked roster afresh itself, including silent
-- script destruction. Producers then share the roster within the sweep.
function M.tick(phase)
  if not storage.barracks then return end
  if phase == nil then
    for _, b in ipairs(storage.barracks) do
      local binding = b.reinforcement
      if binding then divisions.invalidate(binding.player_index, binding.division) end
    end
  end
  local swept = {}
  for i = #storage.barracks, 1, -1 do
    local b = storage.barracks[i]
    if not b.entity.valid then
      stop_animation(b)
      reinforcements.release(b)
      table.remove(storage.barracks, i)
    elseif in_phase(b, phase) then
      swept[#swept + 1] = b
      heal_nearby(b)
      reinforcements.sync_production(b)
      local output = b.entity.get_output_inventory()
      if output then
        local deployed = 0
        for tier, item in pairs(names.recruit_names) do
          while deployed < DEPLOYS_PER_SWEEP and output.get_item_count(item) > 0 and reinforcements.needs_recruit(b) do
            if not deploy(b, tier) then break end
            output.remove{name = item, count = 1}
            deployed = deployed + 1
          end
        end
      end
    end
  end
  -- Barracks linked to one division share a phase, so a deployment that
  -- fills the division pauses its other producers in the same sweep.
  for _, b in ipairs(swept) do
    if b.entity.valid then reinforcements.sync_production(b) end
  end
end

return M
