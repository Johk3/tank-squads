local util = require("util")
local appearance = require("scripts.appearance")
local colors = appearance.tier_colors

local function chassis_animation(tint)
  -- The generated atlas is 1254px square. Sixteen 313px cells occupy the
  -- first 1252px; the final two transparent pixels are unused padding.
  return {
    filename = "__tank-squads__/graphics/chaingun-chassis.png",
    width = 313, height = 313, line_length = 4,
    direction_count = 16, frame_count = 1, scale = appearance.chassis_scale, tint = tint,
  }
end

local TRACER_PROBABILITY = 0.5

local function soldier(suffix, hp, damage, tint)
  return {
    type = "unit",
    name = "tank-squad-soldier-" .. suffix,
    icon = "__tank-squads__/graphics/chaingun-icon.png",
    icon_size = 1254,
    flags = {"placeable-player", "placeable-off-grid", "not-repairable", "get-by-unit-number"},
    max_health = hp,
    healing_per_tick = 0,
    collision_box = {{-0.6, -0.6}, {0.6, 0.6}},
    selection_box = {{-1.0, -1.0}, {1.0, 1.0}},
    subgroup = "creatures",
    order = "z-tank-squad-" .. suffix,
    movement_speed = 0.12,
    distance_per_frame = 0.15,
    vision_distance = 30,
    absorptions_to_join_attack = {pollution = 0},
    -- Recheck nearby enemies promptly after a previous distraction ends.
    distraction_cooldown = 0,
    min_pursue_time = 10 * 60,
    max_pursue_distance = 50,
    ai_settings = {allow_try_return_to_spawner = false, do_separation = true},
    run_animation = chassis_animation(tint),
    attack_parameters = {
      type = "projectile",
      range = 20,
      cooldown = 12,
      ammo_category = "bullet",
      projectile_creation_distance = 1.5,
      -- Reuse the native gun turret's audio, without creating a second
      -- attacking entity or duplicating its target searches.
      sound = util.table.deepcopy(data.raw["ammo-turret"]["gun-turret"].attack_parameters.sound),
      ammo_type = {
        target_type = "entity",
        action = {
          {
            type = "direct",
            action_delivery = {
              type = "instant",
              target_effects = {
                {type = "script", effect_id = "tank-squad-shot"},
                -- Hit sparks are only visual, so skip them in fights no
                -- player is near enough to see.
                {type = "create-entity", entity_name = "explosion-gunshot-small", only_when_visible = true},
                {type = "damage", damage = {amount = damage, type = "physical"}},
              },
            },
          },
          {
            -- Every tracer is an entity the engine updates each tick until it
            -- lands. Every other shot still gives a steady stream on screen.
            type = "direct",
            probability = TRACER_PROBABILITY,
            action_delivery = {
              type = "projectile", projectile = "tank-squad-tracer",
              starting_speed = 1.2, max_range = 24,
            },
          },
        },
      },
      animation = chassis_animation(tint),
    },
  }
end

data:extend{
  {
    type = "sprite", name = "tank-squad-chaingun",
    filename = "__tank-squads__/graphics/chaingun-turret.png",
    width = 1254, height = 1254, scale = appearance.gun_scale,
  },
  {
    type = "projectile", name = "tank-squad-tracer",
    flags = {"not-on-map"}, hidden = true,
    acceleration = 0, collision_box = {{0, 0}, {0, 0}},
    collision_mask = {layers = {}},
    -- Cosmetic only: the original instant bullet delivery still applies
    -- damage once, including the force's bullet research bonuses.
    animation = {
      filename = "__base__/graphics/entity/bullet/bullet.png",
      width = 3, height = 50, scale = 1.2, draw_as_glow = true,
    },
  },
  soldier("1", 400, 6, colors[1]),
  soldier("2", 500, 10, colors[2]),
  soldier("3", 600, 16, colors[3]),
}
