-- Mobile headquarters services. The visible unit carries no services itself:
-- native helper entities (prototypes/headquarters.lua) do the work in the
-- engine. This module places them at the unit's camp, couples their small
-- electric network to one nearby friendly pole and heals nearby units.
--
-- Moving a roboport with such a large reach costs the engine a few
-- milliseconds, so the helpers never follow a moving headquarters. They stay
-- at its last camp, still serving robots, until it parks again, and then all
-- move to it at once. Healing follows the unit itself.
--
-- storage.headquarters[unit_number] = {
--   entity, force_index,
--   helpers = {roboport, radar, solar, accumulator, pole},
--   anchor = {x, y}  - the camp, where the helpers stand
--   last = {x, y}    - the unit's position at the previous sweep
--   grid             - the friendly pole the network is wired to, or nil
--   grid_retry       - tick of the next pole search while uncoupled
--   dish             - the radar dish render object
-- }
-- The table is nil in saves that never had a headquarters, so their sweeps
-- cost one nil check.
local names = require('scripts.names')
local appearance = require('scripts.appearance')

local M = {}

M.HEAL_RADIUS = 24
-- Per sweep, which runs once per second for each headquarters.
M.HEAL_AMOUNT = 20
-- A headquarters that moved less than this since the previous sweep has
-- parked. Its camp moves to it once it parked this far from the camp.
M.PARKED_STEP = 0.1
M.CAMP_DISTANCE = 2
-- A friendly pole within this many tiles of the helpers receives the wire.
M.GRID_RADIUS = 12
M.GRID_RETRY_TICKS = 5 * 60

local HELPERS = {
  roboport = 'tank-squad-hq-roboport',
  radar = 'tank-squad-hq-radar',
  solar = 'tank-squad-hq-solar',
  accumulator = 'tank-squad-hq-accumulator',
  pole = 'tank-squad-hq-pole',
}
M.HELPER_NAMES = {}
for _, name in pairs(HELPERS) do M.HELPER_NAMES[#M.HELPER_NAMES + 1] = name end

local function registry() return storage.headquarters end

local function copper(entity)
  return entity.get_wire_connector(defines.wire_connector_id.pole_copper, true)
end

local function draw_dish(record)
  if record.dish and record.dish.valid then return end
  local entity = record.entity
  record.dish = rendering.draw_sprite{
    sprite = 'tank-squad-hq-radar-dish', target = entity, surface = entity.surface,
    orientation_target = entity, use_target_orientation = true,
    oriented_offset = {0, appearance.headquarters.dish_offset},
    render_layer = 'higher-object-above',
  }
end

local function create_helper(record, key, surface, position)
  local helper = surface.create_entity{name = HELPERS[key], position = position,
    force = record.entity.force, create_build_effect_smoke = false}
  if helper then
    -- The visible unit is the only damage target, including for area damage.
    helper.destructible = false
    record.helpers[key] = helper
  end
  return helper
end

local function disconnect_grid(record)
  local pole, grid = record.helpers.pole, record.grid
  if pole and pole.valid and grid and grid.valid then copper(pole).disconnect_from(copper(grid), defines.wire_origin.script) end
  record.grid, record.grid_retry = nil, nil
end

-- Spills every stored robot and repair pack where the roboport stands.
local function spill(roboport)
  for _, id in ipairs({defines.inventory.roboport_robot, defines.inventory.roboport_material}) do
    local inventory = roboport.get_inventory(id)
    for i = 1, inventory and #inventory or 0 do
      local stack = inventory[i]
      if stack.valid_for_read then
        roboport.surface.spill_item_stack{position = roboport.position, stack = stack,
          enable_looted = true, force = roboport.force, allow_belts = false}
        stack.clear()
      end
    end
  end
end

local function destroy_helpers(record, spill_items)
  disconnect_grid(record)
  for key, helper in pairs(record.helpers) do
    if helper.valid then
      if key == 'roboport' and spill_items then spill(helper) end
      helper.destroy()
    end
    record.helpers[key] = nil
  end
end

-- Makes the unit's position its camp: creates any missing helper and moves
-- the rest there. Teleporting keeps the roboport's robots and the battery's
-- charge. Units cannot change surface, so the helpers always share the
-- unit's surface.
local function place(record)
  local entity = record.entity
  local surface, position = entity.surface, entity.position
  local helpers = record.helpers
  disconnect_grid(record)
  for key in pairs(HELPERS) do
    local helper = helpers[key]
    if helper and helper.valid then
      if helper.position.x ~= position.x or helper.position.y ~= position.y then helper.teleport(position) end
    else
      create_helper(record, key, surface, position)
    end
  end
  record.anchor = {x = position.x, y = position.y}
  record.last = record.anchor
end

-- Replaces helpers another mod removed, at the current camp.
local function repair(record)
  for key in pairs(HELPERS) do
    local helper = record.helpers[key]
    if not (helper and helper.valid) then
      if key == 'pole' then disconnect_grid(record) end
      create_helper(record, key, record.entity.surface, record.anchor)
    end
  end
end

function M.register(entity)
  if not (entity and entity.valid and entity.name == names.headquarters) then return nil end
  storage.headquarters = storage.headquarters or {}
  local record = storage.headquarters[entity.unit_number]
  if record then return record end
  record = {entity = entity, force_index = entity.force_index, helpers = {}}
  storage.headquarters[entity.unit_number] = record
  place(record)
  draw_dish(record)
  return record
end

-- Dying or script-destroyed headquarters spill their stored robots and
-- repair packs where they stood, so nothing silently disappears.
function M.unregister(unit_number)
  local headquarters = registry()
  local record = headquarters and headquarters[unit_number]
  if not record then return end
  destroy_helpers(record, true)
  if record.dish and record.dish.valid then record.dish.destroy() end
  headquarters[unit_number] = nil
  if not next(headquarters) then storage.headquarters = nil end
end

function M.record(unit_number)
  local headquarters = registry()
  return headquarters and headquarters[unit_number]
end

function M.roboport(entity)
  local record = entity and entity.valid and M.record(entity.unit_number)
  local roboport = record and record.helpers.roboport
  return roboport and roboport.valid and roboport or nil
end

-- A clone of a helper belongs to no headquarters. A cloned headquarters
-- builds its own, so copied robots are never duplicated.
function M.is_helper(name)
  for _, helper in pairs(HELPERS) do if helper == name then return true end end
  return false
end

-- Wires the helpers' network to the nearest friendly pole, once. The grid
-- then draws on the solar decks and battery as on any other generator. Only
-- one pole is ever wired, so the headquarters never joins two factory grids.
local function couple(record)
  local pole = record.helpers.pole
  if not (pole and pole.valid) then return end
  local grid = record.grid
  if grid and grid.valid and copper(pole).is_connected_to(copper(grid), defines.wire_origin.script) then return end
  record.grid = nil
  if record.grid_retry and game.tick < record.grid_retry then return end
  local anchor, best, nearest = record.anchor, nil, nil
  for _, candidate in pairs(pole.surface.find_entities_filtered{type = 'electric-pole', position = anchor,
    radius = M.GRID_RADIUS, force = pole.force}) do
    if candidate.name ~= HELPERS.pole then
      local dx, dy = candidate.position.x - anchor.x, candidate.position.y - anchor.y
      local d = dx * dx + dy * dy
      if not best or d < best then best, nearest = d, candidate end
    end
  end
  if nearest and copper(pole).connect_to(copper(nearest), false, defines.wire_origin.script) then
    record.grid, record.grid_retry = nearest, nil
  else
    record.grid_retry = game.tick + M.GRID_RETRY_TICKS
  end
end

local function heal(record)
  local entity = record.entity
  for _, unit in pairs(entity.surface.find_entities_filtered{position = entity.position, radius = M.HEAL_RADIUS,
    name = names.soldier_names, force = entity.force}) do
    local missing = unit.max_health - unit.health
    if missing > 0 then unit.health = unit.health + math.min(missing, M.HEAL_AMOUNT) end
  end
end

local function sweep(id, record)
  local entity = record.entity
  if not entity.valid then M.unregister(id); return end
  if record.force_index ~= entity.force_index then
    disconnect_grid(record)
    for _, helper in pairs(record.helpers) do if helper.valid then helper.force = entity.force end end
    record.force_index = entity.force_index
  end
  local position = entity.position
  local anchor, last = record.anchor, record.last
  local dx, dy = position.x - anchor.x, position.y - anchor.y
  local mx, my = position.x - last.x, position.y - last.y
  local parked = mx * mx + my * my < M.PARKED_STEP * M.PARKED_STEP
  if parked and dx * dx + dy * dy > M.CAMP_DISTANCE * M.CAMP_DISTANCE then
    place(record)
  else
    repair(record)
    record.last = {x = position.x, y = position.y}
  end
  draw_dish(record)
  couple(record)
  heal(record)
end

-- A unit with nothing left to do starts to wander, and a wandering
-- headquarters would never park. Stop it instead; the handlers that run
-- after this one may still give it a new order.
function M.on_command_completed(unit_number)
  local record = M.record(unit_number)
  if record and record.entity.valid then
    record.entity.commandable.set_command{type = defines.command.stop, distraction = defines.distraction.none}
  end
end

-- Each headquarters is swept once per second, in the slice its unit number
-- falls in. A nil phase sweeps all of them, for tests and remote calls.
function M.tick(phase, phases)
  local headquarters = registry()
  if not headquarters then return end
  for id, record in pairs(headquarters) do
    if phase == nil or id % phases == phase then sweep(id, record) end
  end
end

-- Recovers headquarters and removes helpers that belong to none, after a
-- mod update or a clone that copied helpers on their own.
function M.reconcile()
  for _, surface in pairs(game.surfaces) do
    for _, entity in pairs(surface.find_entities_filtered{name = names.headquarters}) do M.register(entity) end
  end
  local owned = {}
  for _, record in pairs(registry() or {}) do
    for _, helper in pairs(record.helpers) do if helper.valid then owned[helper.unit_number] = true end end
  end
  for _, surface in pairs(game.surfaces) do
    for _, helper in pairs(surface.find_entities_filtered{name = M.HELPER_NAMES}) do
      if not owned[helper.unit_number] then helper.destroy() end
    end
  end
end

return M
