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
  tier_colors = {
    {r = 0.9, g = 0.8, b = 0.2, a = 1},
    {r = 0.85, g = 0.25, b = 0.2, a = 1},
    {r = 0.3, g = 0.8, b = 0.35, a = 1},
  },
}
