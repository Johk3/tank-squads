local copy = require('util').table.deepcopy
local appearance = require('scripts.appearance')
local icons = {
  siege = '__tank-squads__/graphics/siege-icon.png',
  flame = '__tank-squads__/graphics/flame-icon.png',
}

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
