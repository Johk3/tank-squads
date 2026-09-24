local names = require("scripts.names")
local barracks = require("scripts.barracks")
local divisions = require("scripts.divisions")
local commands = require("scripts.commands")
local patrol = require("scripts.patrol")
local scout = require("scripts.scout")
local panel = require("scripts.panel")
local weapons = require("scripts.weapons")
local combat = require("scripts.combat")
local escort = require("scripts.escort")
local escort_gui = require("scripts.escort_gui")
local barracks_gui = require('scripts.barracks_gui')
local config = require("scripts.config")
local vision = require("scripts.vision")
local headquarters = require("scripts.headquarters")

local function on_built(event)
  local entity = event.entity
  if entity and entity.valid and entity.name == names.barracks then
    barracks.register(entity)
  elseif entity and entity.valid and names.soldier_set[entity.name] then
    weapons.register(entity)
  elseif entity and entity.valid and entity.name == names.headquarters then
    headquarters.register(entity)
  end
end

-- Name filters keep the engine from calling Lua for every other entity on
-- the map, such as every biter death on a busy map. Soldiers never come from
-- enemy spawners, so on_entity_spawned is not handled.
local soldier_filters, filters = {}, {{filter = "name", name = names.barracks}}
for _, name in ipairs(names.soldier_names) do
  soldier_filters[#soldier_filters + 1] = {filter = "name", name = name}
  filters[#filters + 1] = {filter = "name", name = name}
end
filters[#filters + 1] = {filter = "name", name = names.headquarters}
local unit_filters = {{filter = "name", name = names.headquarters}}
for _, filter in ipairs(soldier_filters) do unit_filters[#unit_filters + 1] = filter end
local clone_filters = {}
for _, filter in ipairs(filters) do clone_filters[#clone_filters + 1] = filter end
for _, name in ipairs(headquarters.HELPER_NAMES) do clone_filters[#clone_filters + 1] = {filter = "name", name = name} end

script.on_event(defines.events.on_built_entity, on_built, filters)
script.on_event(defines.events.on_robot_built_entity, on_built, filters)
script.on_event(defines.events.script_raised_built, on_built, filters)
script.on_event(defines.events.script_raised_revive, on_built, filters)
script.on_event(defines.events.on_script_trigger_effect, function(event)
  weapons.on_shot(event)
  combat.on_shot(event)
end)
local barracks_filters = {{filter = "name", name = names.barracks}}
local function on_pre_mined(event)
  local entity = event.entity
  if entity and entity.valid then barracks.evacuate(entity) end
end
script.on_event(defines.events.on_pre_player_mined_item, on_pre_mined, barracks_filters)
script.on_event(defines.events.on_robot_pre_mined, on_pre_mined, barracks_filters)
-- The headquarters is unarmed, but a patrol still comes to its help.
script.on_event(defines.events.on_entity_damaged, function(event)
  combat.on_damaged(event)
  patrol.on_damaged(event)
end, unit_filters)
script.on_event(defines.events.script_raised_destroy, function(event)
  local entity = event.entity
  if entity and entity.valid and names.soldier_set[entity.name] then
    weapons.unregister(entity.unit_number)
  elseif entity and entity.valid and entity.name == names.headquarters then
    headquarters.unregister(entity.unit_number)
  end
end, unit_filters)
script.on_event(defines.events.on_entity_cloned, function(event)
  local entity = event.destination
  -- A cloned headquarters builds its own helpers, so copied helpers go.
  if entity and entity.valid and headquarters.is_helper(entity.name) then
    entity.destroy()
    return
  end
  on_built{entity = entity}
end, clone_filters)

local function clear_player(event)
  barracks_gui.close(event)
  barracks.clear_player(event.player_index)
  divisions.clear_player(event.player_index)
  escort.forget_ward(event.player_index)
  escort_gui.close(event.player_index)
  if storage.patrol_mode then storage.patrol_mode[event.player_index] = nil end
  local player = game.get_player(event.player_index)
  if player then player.set_shortcut_toggled("tank-squad-patrol-mode", false) end
  panel.update(event.player_index)
end
script.on_event(defines.events.on_player_removed, clear_player)
script.on_event(defines.events.on_player_changed_force, clear_player)

script.on_configuration_changed(function()
  -- New unlock effects are not applied retroactively to researched technology.
  -- Enable only our added recipes, preserving unrelated recipe overrides.
  for _, force in pairs(game.forces or {}) do
    local technology = force.technologies['tank-squad-unlock']
    if technology and technology.researched then
      force.recipes['tank-squad-train-siege'].enabled = true
      force.recipes['tank-squad-train-flame'].enabled = true
    end
  end
  -- Recover producers missed by older versions' clone/revive handling.
  -- register() is idempotent and preserves existing inventories and timers.
  for _, surface in pairs(game.surfaces) do
    for _, entity in pairs(surface.find_entities_filtered{name = names.barracks}) do
      barracks.register(entity)
    end
    for _, entity in pairs(surface.find_entities_filtered{name = names.soldier_names}) do
      weapons.register(entity)
    end
  end
  headquarters.reconcile()
  divisions.reconcile_ownership()
  divisions.refresh()
  -- Upgrades and changed defaults re-space defensive rings and restart
  -- offensive legs under the current settings.
  escort.on_settings_changed()
  for player_index, state in pairs(storage.divisions or {}) do
    for n in pairs(state.slots) do patrol.draw(player_index, n) end
    panel.update(player_index)
  end
end)

script.on_event(defines.events.on_runtime_mod_setting_changed, function(event)
  if config.NAMES[event.setting] then escort.on_settings_changed() end
end)

script.on_event(defines.events.on_entity_died, function(event)
  local entity = event.entity
  if not (entity and entity.valid) then return end
  if entity.name == names.barracks then
    barracks.unregister(entity.unit_number)
  elseif names.soldier_set[entity.name] then
    weapons.unregister(entity.unit_number)
    -- Order matters: the dying entity is still .valid during on_entity_died,
    -- so divisions.forget must run first to drop it from storage.divisions
    -- before patrol.forget runs. patrol.forget re-sends orders to the
    -- route's remaining members via divisions.get; if it ran first,
    -- divisions.get would still find the about-to-die entity valid and
    -- re-add it as a patrol member (with a fresh command issued to a
    -- corpse) right before it dies.
    divisions.forget(entity.unit_number)
    patrol.forget(entity.unit_number)
  elseif entity.name == names.headquarters then
    headquarters.unregister(entity.unit_number)
    -- Same order as for soldiers above.
    divisions.forget(entity.unit_number)
    patrol.forget(entity.unit_number)
  end
end, filters)

script.on_event(defines.events.on_ai_command_completed, function(event)
  -- A finished distraction (a fight on the way) is reported on its own; the
  -- engine then resumes the original command, whose completion follows.
  if event.was_distracted then return end
  headquarters.on_command_completed(event.unit_number)
  if combat.on_command_completed(event.unit_number, event.result) then return end
  if scout.on_command_completed(event.unit_number, event.result) then return end
  if escort.on_command_completed(event.unit_number, event.result) then return end
  patrol.advance(event.unit_number, event.result)
end)

script.on_event(defines.events.on_player_selected_area, function(event)
  if event.item ~= "tank-squad-command-tool" then return end
  divisions.select_area(event.player_index, event.entities)
  panel.update(event.player_index)
end)

for n = 1, 9 do
  script.on_event("tank-squad-assign-division-" .. n, function(event)
    local player_index = event.player_index
    local selected = divisions.selected(player_index)
    local members = divisions.get(player_index, selected)
    divisions.assign(player_index, n, members)
    patrol.draw(player_index, n)
    panel.update(player_index)
  end)
  script.on_event("tank-squad-select-division-" .. n, function(event)
    divisions.recall(event.player_index, n)
    panel.update(event.player_index)
  end)
end

script.on_event(defines.events.on_gui_click, function(event)
  if barracks_gui.click(event) then panel.update(event.player_index); return end
  if escort_gui.click(event) then panel.update(event.player_index); return end
  local element = event.element
  if not (element and element.valid) then return end
  local n = element.tags.tank_squads_division
  if type(n) ~= "number" or n < 0 or n > 9 or n % 1 ~= 0 then return end
  divisions.recall(event.player_index, n)
  panel.update(event.player_index)
end)

script.on_event(defines.events.on_gui_opened, barracks_gui.open)

-- A unit has no window of its own. Opening the headquarters opens its
-- roboport, which holds its robots and repair packs.
script.on_event("tank-squad-open-headquarters", function(event)
  local player = game.get_player(event.player_index)
  local selected = player and player.selected
  if not (selected and selected.valid and selected.name == names.headquarters) then return end
  if selected.force ~= player.force then return end
  local roboport = headquarters.roboport(selected)
  if roboport then player.opened = roboport end
end)
script.on_event(defines.events.on_gui_closed, barracks_gui.close)

local function set_patrol_mode(player_index, value)
  storage.patrol_mode = storage.patrol_mode or {}
  storage.patrol_mode[player_index] = value
  local player = game.get_player(player_index)
  if player then
    player.set_shortcut_toggled("tank-squad-patrol-mode", value)
  end
  -- Toggling patrol mode ON starts a fresh route for the selected division so
  -- waypoints from an old route do not accumulate. Toggling it OFF
  -- intentionally leaves whatever route is already running untouched.
  if value then
    patrol.clear(player_index, divisions.selected(player_index))
  end
end

local function handle_alt_select(player_index, area, surface)
  storage.patrol_mode = storage.patrol_mode or {}
  local n = divisions.selected(player_index)
  if storage.patrol_mode[player_index] then
    if not patrol.add_waypoint(player_index, n, commands.centre(area), surface) then return nil end
    patrol.start(player_index, n)
    return "patrol"
  end
  return commands.order(player_index, area, surface)
end

script.on_event(defines.events.on_player_alt_selected_area, function(event)
  if event.item ~= "tank-squad-command-tool" then return end
  handle_alt_select(event.player_index, event.area, event.surface)
  panel.update(event.player_index)
end)

script.on_event(defines.events.on_lua_shortcut, function(event)
  if event.prototype_name == "tank-squad-escort" then
    escort_gui.toggle(event.player_index)
    return
  end
  if event.prototype_name == "tank-squad-patrol-mode" then
    storage.patrol_mode = storage.patrol_mode or {}
    set_patrol_mode(event.player_index, not storage.patrol_mode[event.player_index])
    return
  end
  if event.prototype_name ~= "tank-squad-scout-mode" then return end
  local player_index = event.player_index
  local n = divisions.selected(player_index)
  local record = divisions.record(player_index, n)
  local value = scout.set(player_index, n, record.mode ~= "scout")
  local player = game.get_player(player_index)
  if player then
    if value == nil then
      player.print({"tank-squads.scout-empty"})
      player.set_shortcut_toggled("tank-squad-scout-mode", false)
    else
      player.set_shortcut_toggled("tank-squad-scout-mode", value)
    end
  end
  panel.update(player_index)
end)

-- The one-second sweep, split into divisions.PHASES slices. Each division
-- and its barracks are swept once per second in their own slice. The
-- roster refresh runs first, so linked barracks, scouts and escorts in the
-- same slice reuse its validated members.
local PHASE_TICKS = 60 / divisions.PHASES
script.on_nth_tick(PHASE_TICKS, function(event)
  local phase = (event.tick / PHASE_TICKS) % divisions.PHASES
  divisions.refresh(phase)
  barracks.tick(phase)
  scout.tick(phase)
  patrol.tick(phase)
  escort.tick(phase)
  vision.tick(phase, divisions.PHASES)
  weapons.tick(phase, divisions.PHASES)
  headquarters.tick(phase, divisions.PHASES)
  if phase ~= 0 then return end
  escort_gui.update_wards(escort.wards())
  for player_index in pairs(storage.divisions or {}) do
    panel.update(player_index)
    barracks_gui.refresh(player_index)
  end
end)

remote.add_interface("tank-squads", {
  barracks_configure = function(player_index, entity, division, target)
    return barracks.configure(entity, player_index, division, target)
  end,
  tick = function() barracks.tick() end,
  select = function(player_index, area)
    local surface = game.surfaces[1]
    return divisions.select_area(player_index, surface.find_entities_filtered{area = area})
  end,
  order = function(player_index, area)
    return commands.order(player_index, area, game.surfaces[1])
  end,
  alt_select = function(player_index, area)
    return handle_alt_select(player_index, area, game.surfaces[1])
  end,
  patrol_mode_set = function(player_index, value)
    set_patrol_mode(player_index, value)
    return value
  end,
  division_assign = function(player_index, n, area)
    local surface = game.surfaces[1]
    return divisions.assign(player_index, n, surface.find_entities_filtered{area = area})
  end,
  division_recall = function(player_index, n) return divisions.recall(player_index, n) end,
  division_selected = function(player_index) return divisions.selected(player_index) end,
  division_size = function(player_index, n) return divisions.size(player_index, n) end,
  patrol_waypoint = function(player_index, n, position) return patrol.add_waypoint(player_index, n, position) end,
  patrol_start = function(player_index, n) return patrol.start(player_index, n) end,
  patrol_index = function(player_index, n, unit_number) return patrol.index(player_index, n, unit_number) end,
  patrol_target = function(player_index, n, unit_number) return patrol.target(player_index, n, unit_number) end,
  patrol_advance = function(unit_number) return patrol.advance(unit_number) end,
  scout_set = function(player_index, n, value) return scout.set(player_index, n, value) end,
  scout_tick = function() return scout.tick() end,
  scout_target = function(player_index, n)
    local state = divisions.record(player_index, n).scout
    return state and scout.target(state) or nil
  end,
  escort_start = function(owner, n, ward, formation) return escort.start(owner, n, ward, formation) end,
  escort_stop = function(owner, n) return escort.stop(owner, n) end,
  escort_dismiss = function(ward, owner, n) return escort.dismiss(ward, owner, n) end,
  escort_tick = function() escort.tick() end,
  vision_tick = function() vision.tick(nil, divisions.PHASES) end,
  headquarters_tick = function() headquarters.tick(nil, divisions.PHASES) end,
  escort_state = function(owner, n)
    local state = divisions.record(owner, n).escort
    if not state then return nil end
    return {formation = state.formation, available = state.available, anchor = state.anchor,
      leg = state.leg and state.leg.destination or nil}
  end,
})
