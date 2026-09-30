-- Shredder: an unmanned rammer a barracks trains. The parked unit drives to
-- its post on native pathfinding. A strike swaps it for the charging unit,
-- whose hull is invisible: scripts/shredders.lua draws the charge sheet on
-- it, turned toward the target. The crash is the charging unit's own melee
-- attack, so the engine deals every point of damage.
local copy = require('util').table.deepcopy
local appearance = require('scripts.appearance')
local names = require('scripts.names')
local look = appearance.shredder

-- Literal paths, so test/check-local-assets.py finds every sheet.
local CHASSIS = '__tank-squads__/graphics/tank-variants/shredder/chassis.png'
local CHARGE = '__tank-squads__/graphics/tank-variants/shredder/charge.png'
local FX = '__tank-squads__/graphics/tank-variants/shredder/effects.png'
local ICON = '__tank-squads__/graphics/tank-variants/shredder/icon.png'

-- Clockwise from north in 22.5-degree steps, one frame per heading.
local function hull()
  return {filename = CHASSIS, width = 313, height = 313, line_length = 4,
    direction_count = 16, frame_count = 1, scale = look.chassis_scale, apply_projection = false}
end

local function invisible()
  return {filename = '__core__/graphics/empty.png', width = 1, height = 1, direction_count = 1, frame_count = 1}
end

-- One row of the 4x4 effect sheet, 313 px cells.
local function fx(row, frames, scale, speed)
  return {filename = FX, width = 313, height = 313, y = row * 313, frame_count = frames,
    line_length = 4, scale = scale, animation_speed = speed}
end

local function unit(name, speed, run_animation, attack)
  local u = copy(data.raw.unit['tank-squad-soldier-1'])
  u.name, u.icon, u.icon_size = name, ICON, 1254
  u.order = 'z-' .. name
  u.max_health, u.movement_speed = 600, speed
  u.distance_per_frame = 0.2
  u.vision_distance = 20
  u.run_animation = run_animation
  u.attack_parameters = attack
  u.resistances = nil
  return u
end

-- The parked unit drives at a soldier's pace, so it trails its division
-- calmly; only a strike's charging unit is fast.
local parked = unit(names.shredder, 0.15, hull(), {
  -- Units need an attack. Parked shredders always carry commands without
  -- distraction, so this never fires; a strike swaps in the charging unit.
  type = 'projectile', range = 0.5, cooldown = 600, ammo_category = 'melee',
  animation = hull(),
  ammo_type = {target_type = 'entity', action = {type = 'direct', action_delivery = {type = 'instant'}}},
})

-- The crash. The fuse flies from the shredder to the target in about eight
-- ticks while the breakup plays, then bursts: shrapnel for enemies only.
local charging = unit(names.shredder_charging, 1.0, invisible(), {
  type = 'projectile', range = 1.5, cooldown = 60, ammo_category = 'melee',
  animation = invisible(),
  ammo_type = {target_type = 'entity', action = {
    {type = 'direct', action_delivery = {type = 'projectile', projectile = 'tank-squad-shredder-fuse',
      starting_speed = 0.2, max_range = 6}},
    {type = 'direct', action_delivery = {type = 'instant', target_effects = {
      {type = 'script', effect_id = 'tank-squad-shredder-impact'},
      {type = 'damage', damage = {amount = 1500, type = 'physical'}},
    }}},
  }},
})
charging.flags[#charging.flags + 1] = 'not-on-map'

local camera
for _, e in ipairs(data.raw.projectile['atomic-rocket'].action.action_delivery.target_effects) do
  if e.type == 'camera-effect' then camera = copy(e) end
end
if camera then camera.strength, camera.full_strength_max_distance, camera.max_distance = 1.5, 10, 40 end
local blast = data.raw.explosion['big-explosion'] and data.raw.explosion['big-explosion'].sound

local burst_effects = {
  {type = 'create-entity', entity_name = 'tank-squad-shredder-burst'},
  {type = 'nested-result', action = {type = 'area', radius = 8, force = 'enemy',
    action_delivery = {type = 'instant', target_effects = {
      {type = 'damage', damage = {amount = 400, type = 'physical'}},
      {type = 'damage', damage = {amount = 200, type = 'explosion'}},
    }}}},
}
if camera then burst_effects[#burst_effects + 1] = camera end
if blast then burst_effects[#burst_effects + 1] = {type = 'play-sound', sound = copy(blast)} end

local fuse = {
  type = 'projectile', name = 'tank-squad-shredder-fuse', flags = {'not-on-map'}, hidden = true,
  acceleration = 0, collision_box = {{0, 0}, {0, 0}}, hit_collision_mask = {layers = {}},
  action = {
    {type = 'direct', action_delivery = {type = 'instant', target_effects = burst_effects}},
    -- Cosmetic shards thrown outward; the area action above deals the damage.
    {type = 'cluster', cluster_count = 12, distance = 7, distance_deviation = 2,
      action_delivery = {type = 'projectile', projectile = 'tank-squad-shredder-shard',
        direction_deviation = 0.3, starting_speed = 0.45, starting_speed_deviation = 0.1}},
  },
}

local shard = {
  type = 'projectile', name = 'tank-squad-shredder-shard', flags = {'not-on-map'}, hidden = true,
  acceleration = 0, collision_box = {{0, 0}, {0, 0}}, hit_collision_mask = {layers = {}},
  animation = fx(1, 4, look.shard_scale, 0.5),
}

-- Frames 3 and 4 of row 3 as an expanding burst that fades out. One
-- explosion plays one run of frames, so the smoke of row 4 is a second
-- explosion the burst starts.
local burst = {
  type = 'explosion', name = 'tank-squad-shredder-burst', flags = {'not-on-map'}, hidden = true,
  animations = {{filename = FX, width = 313, height = 313, x = 2 * 313, y = 2 * 313, frame_count = 2,
    line_length = 2, scale = look.burst_scale, animation_speed = 0.2}},
  fade_out_duration = 5,
  created_effect = {type = 'direct', action_delivery = {type = 'instant', target_effects = {
    {type = 'create-entity', entity_name = 'tank-squad-shredder-smoke'},
  }}},
}
local smoke = {
  type = 'explosion', name = 'tank-squad-shredder-smoke', flags = {'not-on-map'}, hidden = true,
  animations = {fx(3, 4, look.burst_scale, 0.08)},
  fade_out_duration = 30,
}

-- The arm sheet shows standby then target acquired over the 20-tick
-- ignition; the boost sheet flickers between ignition and full boost.
local arm_sequence, boost_sequence = {}, {}
for i = 1, 20 do arm_sequence[i] = i <= 8 and 1 or 2 end
for i = 1, 64 do boost_sequence[i] = (i <= 4 or i % 3 == 0) and 1 or 2 end

-- Four frames converging on the target, then the compact lock held.
local lock_sequence = {}
for i = 1, 128 do lock_sequence[i] = math.min(4, math.ceil(i / 3)) end

data:extend{
  parked, charging, fuse, shard, burst, smoke,
  {type = 'animation', name = 'tank-squad-shredder-arm', filename = CHARGE, width = 627, height = 627,
    frame_count = 2, line_length = 2, frame_sequence = arm_sequence, scale = look.charge_scale},
  {type = 'animation', name = 'tank-squad-shredder-boost', filename = CHARGE, width = 627, height = 627,
    y = 627, frame_count = 2, line_length = 2, frame_sequence = boost_sequence, scale = look.charge_scale},
  {type = 'animation', name = 'tank-squad-shredder-lock', filename = FX, width = 313, height = 313,
    frame_count = 4, line_length = 4, frame_sequence = lock_sequence, scale = look.lock_scale, draw_as_glow = true},
  {type = 'animation', name = 'tank-squad-shredder-breakup', filename = FX, width = 313, height = 313,
    y = 2 * 313, frame_count = 2, line_length = 4, scale = look.breakup_scale},
  {type = 'sound', name = 'tank-squad-shredder-lock-sound',
    filename = '__base__/sound/programmable-speaker/alarm-2.ogg', volume = 0.5},
  {type = 'sound', name = 'tank-squad-shredder-boost-sound',
    filename = '__base__/sound/fight/rocket-launcher.ogg', volume = 0.9},
  {type = 'item', name = names.shredder_recruit, icon = ICON, icon_size = 1254, hidden = true,
    hidden_in_factoriopedia = true, stack_size = 1, subgroup = 'creatures', order = 'z-tank-squad-recruit-shredder'},
  {type = 'recipe', name = names.shredder_recipe, category = 'tank-squad-training', enabled = false,
    energy_required = 20,
    ingredients = {
      {type = 'item', name = 'steel-plate', amount = 25},
      {type = 'item', name = 'engine-unit', amount = 5},
      {type = 'item', name = 'grenade', amount = 10},
    },
    results = {{type = 'item', name = names.shredder_recruit, amount = 1}},
    allow_productivity = false, allow_decomposition = false},
}
