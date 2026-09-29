local copy = require('util').table.deepcopy
local appearance = require('scripts.appearance')
local icons = {
  siege = '__tank-squads__/graphics/siege-icon.png',
  flame = '__tank-squads__/graphics/flame-icon.png',
  electric = '__tank-squads__/graphics/tank-variants/electric/icon.png',
  nuclear = '__tank-squads__/graphics/tank-variants/nuclear/icon.png',
}
local ELECTRIC_FX = '__tank-squads__/graphics/tank-variants/electric/effects.png'
local NUCLEAR_FX = '__tank-squads__/graphics/tank-variants/nuclear/effects.png'

-- One row of a 4x4 effect sheet of 313 px cells.
local function effect(filename, row, frames, scale, speed, glow)
  return {filename = filename, width = 313, height = 313, y = row * 313, frame_count = frames,
    line_length = 4, scale = scale, animation_speed = speed, draw_as_glow = glow}
end

local function chassis(filename, scale)
  -- Match the carrier: N clockwise in 22.5-degree steps, one frame per heading.
  return {filename = filename, width = 313, height = 313, line_length = 4,
    direction_count = 16, frame_count = 1, scale = scale, apply_projection = false}
end

local function specialist(kind, hp, speed, filename, scale)
  -- Inherit the same collision, selection, AI and lifecycle contract as carriers.
  local unit = copy(data.raw.unit['tank-squad-soldier-1'])
  unit.name = 'tank-squad-' .. kind
  unit.icon = icons[kind]
  unit.order = 'z-tank-squad-' .. kind
  unit.max_health, unit.movement_speed = hp, speed
  unit.run_animation = chassis(filename, scale)
  unit.distance_per_frame = 0.12
  return unit, chassis(filename, scale)
end

local siege, siege_idle = specialist('siege', 900, 0.085,
  '__tank-squads__/graphics/siege-chassis.png', 0.38)
-- 52 tiles outranges the behemoth worm (48). scripts/assault.lua reads this
-- range from the prototype for its barrage.
siege.vision_distance = 52
siege.attack_parameters = {
  type = 'projectile', range = 52, cooldown = 120, ammo_category = 'cannon-shell',
  projectile_creation_distance = 1.5,
  sound = copy(data.raw.gun['tank-cannon'].attack_parameters.sound),
  animation = siege_idle,
  ammo_type = {target_type = 'entity', action = {
    {type = 'direct', action_delivery = {type = 'instant', target_effects = {
      {type = 'script', effect_id = 'tank-squad-shot'},
    }}},
    {type = 'direct', action_delivery = {
      type = 'projectile', projectile = 'tank-squad-cannon-projectile',
      starting_speed = 1, max_range = 60,
      source_effects = {{type = 'create-explosion', entity_name = 'explosion-gunshot', only_when_visible = true}},
    }},
  }},
}

local shell = copy(data.raw.projectile['cannon-projectile'])
shell.name = 'tank-squad-cannon-projectile'
-- Aimed shell, not a piercing line through a mixed division. Native projectile
-- delivery applies the cannon research modifier, with no scripted damage.
shell.direction_only, shell.piercing_damage = false, nil
shell.collision_box = {{0, 0}, {0, 0}}
shell.hit_collision_mask = {layers = {}}
shell.final_action = nil
-- Reports the impact, so a ranked siege tank's bonus damage lands with the
-- shell. The event's cause_entity is the siege tank that fired.
local impact = shell.action[1] or shell.action
table.insert(impact.action_delivery.target_effects, 1, {type = 'script', effect_id = 'tank-squad-shell-hit'})

local flame, flame_idle = specialist('flame', 2400, 0.07,
  '__tank-squads__/graphics/flame-chassis.png', 0.46)
flame.resistances = {{type = 'fire', percent = 90}, {type = 'physical', decrease = 4, percent = 20}}
flame.attack_parameters = {
  -- Discrete native attacks deliver overlapping flame streams. Stream attack
  -- mode only emits the aiming hook at the start of an indefinite burst.
  type = 'projectile', range = 10, cooldown = 12, ammo_category = 'flamethrower',
  projectile_creation_distance = 1.5,
  sound = {filename = '__base__/sound/fight/flamethrower-mid.ogg', volume = 0.15,
    aggregation = {max_count = 1, remove = true, count_already_playing = true}},
  animation = flame_idle,
  ammo_type = {target_type = 'entity', action = {
    {type = 'direct', action_delivery = {type = 'instant', target_effects = {
      {type = 'script', effect_id = 'tank-squad-shot'},
    }}},
    {type = 'direct', action_delivery = {type = 'stream', stream = 'tank-squad-flame-stream', duration = 12}},
  }},
}
local stream = copy(data.raw.stream['tank-flamethrower-fire-stream'])
stream.name = 'tank-squad-flame-stream'
stream.particle_buffer_size, stream.particle_spawn_interval = 32, 2
stream.smoke_sources = nil
stream.action = {type = 'area', radius = 2.5, force = 'enemy',
  action_delivery = {type = 'instant', target_effects = {
    {type = 'damage', damage = {amount = 7, type = 'fire'}},
  }}}

-- One recoil cycle followed by rest frames. The existing one-second sweep
-- freezes the animation before it can repeat; the engine advances every frame.
local recoil = {}
for frame = 1, 128 do recoil[frame] = frame <= 6 and 2 or frame <= 12 and 3 or 1 end
data:extend{
  siege, flame, shell, stream,
  {type = 'animation', name = 'tank-squad-siege-gun',
    filename = '__tank-squads__/graphics/siege-gun.png', width = 627, height = 627,
    frame_count = 4, line_length = 2, frame_sequence = recoil,
    scale = appearance.weapons['tank-squad-siege'].scale},
  {type = 'sprite', name = 'tank-squad-flame-gun',
    filename = '__tank-squads__/graphics/flame-gun.png', width = 1254, height = 1254,
    scale = appearance.weapons['tank-squad-flame'].scale},
}

-- Electric tank: a plasma ball that bursts on the target and shocks every
-- enemy around it. Damage is engine-side; one script effect per impact
-- draws the arcs and adds the rank bonus.
local electric, electric_idle = specialist('electric', 1400, 0.10,
  '__tank-squads__/graphics/tank-variants/electric/chassis.png', appearance.chassis_scale)
electric.resistances = {{type = 'electric', percent = 80}}
electric.attack_parameters = {
  type = 'projectile', range = 24, cooldown = 45, ammo_category = 'laser',
  projectile_creation_distance = 1.5,
  animation = electric_idle,
  ammo_type = {target_type = 'entity', action = {
    {type = 'direct', action_delivery = {type = 'instant', target_effects = {
      {type = 'script', effect_id = 'tank-squad-shot'},
    }}},
    {type = 'direct', action_delivery = {
      type = 'projectile', projectile = 'tank-squad-electric-ball', starting_speed = 0.6, max_range = 30,
    }},
  }},
}

local ball = {
  type = 'projectile', name = 'tank-squad-electric-ball', flags = {'not-on-map'}, hidden = true,
  acceleration = 0, collision_box = {{0, 0}, {0, 0}}, hit_collision_mask = {layers = {}},
  animation = effect(ELECTRIC_FX, 0, 4, 0.25, 0.5, true),
  action = {type = 'direct', action_delivery = {type = 'instant', target_effects = {
    {type = 'create-entity', entity_name = 'tank-squad-electric-impact'},
    {type = 'damage', damage = {amount = 120, type = 'electric'}},
    {type = 'script', effect_id = 'tank-squad-electric-hit'},
    {type = 'nested-result', action = {type = 'area', radius = 6, force = 'enemy',
      action_delivery = {type = 'instant', target_effects = {
        {type = 'damage', damage = {amount = 180, type = 'electric'}},
        {type = 'create-entity', entity_name = 'tank-squad-electric-shock'},
      }}}},
  }}},
}

-- Nuclear tank: the native attack only reports a firing moment. nuclear.lua
-- checks the blast radius for friends and launches a nuke or a plain rocket.
local nuclear, nuclear_idle = specialist('nuclear', 1600, 0.08,
  '__tank-squads__/graphics/tank-variants/nuclear/chassis.png', appearance.chassis_scale)
nuclear.vision_distance = 52
nuclear.attack_parameters = {
  type = 'projectile', range = 52, min_range = 20, cooldown = 60, ammo_category = 'rocket',
  projectile_creation_distance = 1.5,
  animation = nuclear_idle,
  ammo_type = {target_type = 'entity', action = {
    {type = 'direct', action_delivery = {type = 'instant', target_effects = {
      {type = 'script', effect_id = 'tank-squad-shot'},
      {type = 'script', effect_id = 'tank-squad-nuke'},
    }}},
  }},
}

-- Camera shake and the two nuclear explosion sounds come from the base
-- atomic rocket, so they match the base game.
local atomic_effects = {}
for _, e in ipairs(data.raw.projectile['atomic-rocket'].action.action_delivery.target_effects) do
  if e.type == 'camera-effect' or e.type == 'play-sound' then atomic_effects[#atomic_effects + 1] = copy(e) end
end
local nuke_effects = {
  {type = 'create-entity', entity_name = 'tank-squad-nuke-detonation'},
  {type = 'create-entity', entity_name = 'huge-scorchmark', offsets = {{0, -0.5}}, check_buildability = true},
  {type = 'destroy-decoratives', include_soft_decoratives = true, include_decals = true,
    invoke_decorative_trigger = true, decoratives_with_trigger_only = false, radius = 14},
  {type = 'create-decorative', decorative = 'nuclear-ground-patch', spawn_min_radius = 11.5,
    spawn_max_radius = 12.5, spawn_min = 30, spawn_max = 40, apply_projection = true, spread_evenly = true},
  -- Enemies only: a friend who walks in during the flight is spared.
  {type = 'nested-result', action = {type = 'area', radius = 6, force = 'enemy',
    action_delivery = {type = 'instant', target_effects = {
      {type = 'damage', damage = {amount = 5000, type = 'explosion'}},
    }}}},
  {type = 'nested-result', action = {type = 'area', radius = 14, force = 'enemy',
    action_delivery = {type = 'instant', target_effects = {
      {type = 'damage', damage = {amount = 1500, type = 'explosion'}},
      {type = 'damage', damage = {amount = 300, type = 'physical'}},
    }}}},
}
for _, e in ipairs(atomic_effects) do nuke_effects[#nuke_effects + 1] = e end

local atomic = {
  type = 'projectile', name = 'tank-squad-atomic-rocket', flags = {'not-on-map'}, hidden = true,
  acceleration = 0.005, turn_speed = 0.003, turning_speed_increases_exponentially_with_projectile_speed = true,
  animation = effect(NUCLEAR_FX, 0, 4, 0.3, 0.5, false),
  action = {type = 'direct', action_delivery = {type = 'instant', target_effects = nuke_effects}},
}

-- Fired instead of a nuke while friends are near the target. Its splash
-- also spares friends, and it reports its impact for the rank bonus.
local fallback = copy(data.raw.projectile['explosive-rocket'])
fallback.name = 'tank-squad-nuke-fallback'
for _, e in ipairs(fallback.action.action_delivery.target_effects) do
  if e.type == 'nested-result' then e.action.force = 'enemy' end
end
table.insert(fallback.action.action_delivery.target_effects, 1, {type = 'script', effect_id = 'tank-squad-rocket-hit'})

local function explosion(name, animation)
  return {type = 'explosion', name = name, flags = {'not-on-map'}, hidden = true, animations = {animation}}
end

-- Electric gun: rest, charged ball, discharge, residual arcs, rest.
-- Nuclear launcher: loaded, ignition, 5 s smoking, reloaded, loaded.
local nuclear_sequence = appearance.gun_sequence{{2, 2}, {3, 75}, {4, 10}}

data:extend{
  electric, ball, nuclear, atomic, fallback,
  explosion('tank-squad-electric-impact', effect(ELECTRIC_FX, 1, 4, 0.35, 0.25, true)),
  explosion('tank-squad-electric-shock', effect(ELECTRIC_FX, 3, 4, 0.2, 0.25, true)),
  explosion('tank-squad-nuke-detonation', effect(NUCLEAR_FX, 1, 12, 2.5, 0.1, false)),
  {type = 'animation', name = 'tank-squad-electric-link',
    filename = ELECTRIC_FX, width = 313, height = 313, y = 2 * 313, frame_count = 4, line_length = 4,
    animation_speed = 0.5, scale = appearance.electric.link_scale, draw_as_glow = true},
  {type = 'animation', name = 'tank-squad-electric-gun',
    filename = '__tank-squads__/graphics/tank-variants/electric/attack.png', width = 627, height = 627,
    frame_count = 4, line_length = 2, frame_sequence = appearance.gun_sequence{{2, 4}, {3, 4}, {4, 4}},
    scale = appearance.weapons['tank-squad-electric'].scale},
  {type = 'animation', name = 'tank-squad-nuclear-gun',
    filename = '__tank-squads__/graphics/tank-variants/nuclear/attack.png', width = 627, height = 627,
    frame_count = 4, line_length = 2, frame_sequence = nuclear_sequence,
    scale = appearance.weapons['tank-squad-nuclear'].scale},
  {type = 'sound', name = 'tank-squad-nuke-launch',
    filename = '__base__/sound/fight/rocket-launcher.ogg', volume = 0.8},
}
