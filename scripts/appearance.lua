-- Shared by prototypes and runtime overlays; contains no runtime API access.
return {
  chassis_scale = 0.45,
  gun_scale = 0.09,
  gun_pivot_pixels = 48,
  weapons = {
    ["tank-squad-siege"] = {
      animation = "tank-squad-siege-gun", scale = 0.36,
      pivot_pixels = 137, aim_timeout = 180, recoil_ticks = 24,
    },
    ["tank-squad-flame"] = {
      sprite = "tank-squad-flame-gun", scale = 0.095,
      pivot_pixels = 155, aim_timeout = 60,
    },
  },
  headquarters = {
    -- About 9 by 14 tiles, three times the length of a base-game tank.
    chassis_scale = 1.7, dish_scale = 0.2,
    -- The dish sprite's bearing sits about 373 source pixels below its
    -- centre. Centring the sprite 1.65 tiles behind the body's centre puts
    -- that bearing on the chassis' rear pedestal, about 4 tiles back.
    dish_offset = 1.65,
  },
  tier_colors = {
    {r = 0.9, g = 0.8, b = 0.2, a = 1},
    {r = 0.85, g = 0.25, b = 0.2, a = 1},
    {r = 0.3, g = 0.8, b = 0.35, a = 1},
  },
}
