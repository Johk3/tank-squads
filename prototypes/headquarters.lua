-- Mobile headquarters: a huge, slow, unarmed support unit. The visible unit
-- is a native `unit`, so selection, divisions and movement orders work as for
-- the combat units. Its services come from hidden native helper entities that
-- scripts/headquarters.lua sets up at its camp, where it last parked: a
-- roboport, a radar, a solar panel and an accumulator on their own small
-- electric network.
local util = require('util')
local copy = util.table.deepcopy
local appearance = require('scripts.appearance')
local hq = appearance.headquarters

local ICON = '__tank-squads__/graphics/headquarters-icon.png'
-- Base roboport reach, multiplied by 25. Adding or moving a roboport costs
-- time in proportion to its covered area: at 25x (625/1375 tiles) a move
-- takes a few milliseconds, at 100x it took around 50.
local RANGE_MULTIPLIER = 25

local function chassis()
  -- Same 4x4 sixteen-heading layout as the other vehicles: N clockwise in
  -- 22.5-degree steps, 313px cells on a 1254px sheet.
  return {filename = '__tank-squads__/graphics/headquarters-chassis.png', width = 313, height = 313,
    line_length = 4, direction_count = 16, frame_count = 1, scale = hq.chassis_scale,
    apply_projection = false}
end

local unit = {
  type = 'unit',
  name = 'tank-squad-headquarters',
  icon = ICON, icon_size = 1254,
  flags = {'placeable-player', 'placeable-off-grid', 'not-repairable', 'get-by-unit-number'},
  max_health = 400,
  healing_per_tick = 0,
  -- Units keep an unrotated square box. Six tiles keeps it out of narrow
  -- gaps; the selection box covers most of the body at every heading.
  collision_box = {{-3, -3}, {3, 3}},
  selection_box = {{-4.5, -4.5}, {4.5, 4.5}},
  subgroup = 'creatures',
  order = 'z-tank-squad-headquarters',
  movement_speed = 0.02,
  distance_per_frame = 0.12,
  -- Unarmed: a minimal sight range, and every command it receives goes
  -- through scripts/combat.lua, which never lets it attack.
  vision_distance = 1,
  absorptions_to_join_attack = {pollution = 0},
  distraction_cooldown = 3600,
  min_pursue_time = 0,
  max_pursue_distance = 0,
  ai_settings = {allow_try_return_to_spawner = false, do_separation = true},
  run_animation = chassis(),
  -- The engine requires an attack. This one has no effect and a range too
  -- short to reach anything around such a large body.
  attack_parameters = {
    type = 'projectile', range = 0.5, cooldown = 600, ammo_category = 'bullet',
    ammo_type = {target_type = 'entity', action = {type = 'direct',
      action_delivery = {type = 'instant'}}},
    animation = chassis(),
  },
}

local function hidden(entity)
  entity.flags = {'not-on-map', 'not-blueprintable', 'not-deconstructable', 'placeable-off-grid',
    'not-selectable-in-game', 'not-in-kill-statistics', 'no-copy-paste', 'not-upgradable'}
  entity.hidden = true
  entity.hidden_in_factoriopedia = true
  entity.minable = nil
  entity.selection_box = nil
  entity.collision_mask = {layers = {}}
  entity.fast_replaceable_group = nil
  entity.next_upgrade = nil
  entity.corpse = nil
  entity.dying_explosion = nil
  entity.damaged_trigger_effect = nil
  entity.water_reflection = nil
  entity.integration_patch = nil
  entity.circuit_connector = nil
  entity.circuit_wire_max_distance = 0
  -- The visible unit is the only damage target.
  entity.max_health = 1
  entity.create_ghost_on_death = false
  entity.icon, entity.icons, entity.icon_size = ICON, nil, 1254
  return entity
end

local empty = util.empty_sprite()
local empty_animation = util.empty_animation(1)

local roboport = hidden(copy(data.raw.roboport.roboport))
roboport.name = 'tank-squad-hq-roboport'
roboport.logistics_radius = data.raw.roboport.roboport.logistics_radius * RANGE_MULTIPLIER
roboport.construction_radius = data.raw.roboport.roboport.construction_radius * RANGE_MULTIPLIER
roboport.charging_energy = '500kW'
roboport.charging_offsets = {
  {-3, -5}, {3, -5}, {-4, -1.5}, {4, -1.5}, {-4, 1.5}, {4, 1.5}, {-3, 5}, {3, 5},
}
roboport.energy_source = {type = 'electric', usage_priority = 'secondary-input',
  input_flow_limit = '5MW', buffer_capacity = '100MJ'}
roboport.base, roboport.base_patch = empty, empty
roboport.base_animation = empty_animation
roboport.door_animation_up, roboport.door_animation_down = empty_animation, empty_animation
roboport.recharging_animation = empty_animation
roboport.working_sound, roboport.open_sound, roboport.close_sound = nil, nil, nil
roboport.open_door_trigger_effect, roboport.close_door_trigger_effect = nil, nil
roboport.draw_logistic_radius_visualization = false
roboport.draw_construction_radius_visualization = false
roboport.default_available_logistic_output_signal = nil
roboport.default_total_logistic_output_signal = nil
roboport.default_available_construction_output_signal = nil
roboport.default_total_construction_output_signal = nil
roboport.default_roboport_count_output_signal = nil

local radar = hidden(copy(data.raw.radar.radar))
radar.name = 'tank-squad-hq-radar'
radar.max_distance_of_nearby_sector_revealed = 8
radar.max_distance_of_sector_revealed = 32
radar.energy_usage = '3MW'
radar.pictures = {layers = {{filename = '__core__/graphics/empty.png', width = 1, height = 1,
  direction_count = 1}}}
radar.working_sound = nil
radar.connects_to_other_radars = false
radar.radius_minimap_visualisation_color = nil

local solar = hidden(copy(data.raw['solar-panel']['solar-panel']))
solar.name = 'tank-squad-hq-solar'
-- 200 base panels' worth of photovoltaic decks.
solar.production = '12MW'
solar.picture = empty
solar.overlay = nil

local accumulator = hidden(copy(data.raw.accumulator.accumulator))
accumulator.name = 'tank-squad-hq-accumulator'
accumulator.energy_source = {type = 'electric', usage_priority = 'tertiary',
  buffer_capacity = '1GJ', input_flow_limit = '12MW', output_flow_limit = '5MW'}
accumulator.chargable_graphics = {picture = empty}
accumulator.default_output_signal = nil
accumulator.working_sound = nil

local pole = hidden(copy(data.raw['electric-pole']['medium-electric-pole']))
pole.name = 'tank-squad-hq-pole'
-- Covers only the helpers standing on the headquarters. Wires to the
-- recipient grid are made by script, never by the player.
pole.supply_area_distance = 2
pole.maximum_wire_distance = 16
pole.auto_connect_up_to_n_wires = 0
pole.pictures = {filename = '__core__/graphics/empty.png', width = 1, height = 1, direction_count = 1}
pole.connection_points = {{wire = {copper = {0, -3}}, shadow = {copper = {0, 0}}}}
pole.radius_visualisation_picture = nil
pole.active_picture = nil

local recruit = 'tank-squad-recruit-headquarters'
data:extend{
  unit, roboport, radar, solar, accumulator, pole,
  {type = 'sprite', name = 'tank-squad-hq-radar-dish',
    filename = '__tank-squads__/graphics/headquarters-radar.png', width = 1254, height = 1254,
    scale = hq.dish_scale},
  {type = 'item', name = recruit, icon = ICON, icon_size = 1254,
    hidden = true, hidden_in_factoriopedia = true, stack_size = 1,
    subgroup = 'creatures', order = 'z-tank-squad-recruit-headquarters'},
  {type = 'recipe', name = 'tank-squad-train-headquarters', category = 'tank-squad-training',
    enabled = false, energy_required = 60,
    ingredients = {
      {type = 'item', name = 'steel-plate', amount = 400},
      {type = 'item', name = 'iron-gear-wheel', amount = 100},
      {type = 'item', name = 'electric-engine-unit', amount = 40},
      {type = 'item', name = 'processing-unit', amount = 40},
      {type = 'item', name = 'solar-panel', amount = 40},
      {type = 'item', name = 'accumulator', amount = 40},
      {type = 'item', name = 'roboport', amount = 4},
      {type = 'item', name = 'radar', amount = 4},
    },
    results = {{type = 'item', name = recruit, amount = 1}},
    allow_productivity = false, allow_decomposition = false},
  {type = 'technology', name = 'tank-squad-headquarters',
    icon = ICON, icon_size = 1254,
    effects = {{type = 'unlock-recipe', recipe = 'tank-squad-train-headquarters'}},
    prerequisites = {'tank-squad-unlock', 'logistic-robotics', 'construction-robotics',
      'electric-energy-accumulators', 'solar-energy', 'utility-science-pack', 'production-science-pack'},
    unit = {count = 1000, time = 60, ingredients = {
      {'automation-science-pack', 1}, {'logistic-science-pack', 1}, {'chemical-science-pack', 1},
      {'production-science-pack', 1}, {'utility-science-pack', 1},
    }}},
}
