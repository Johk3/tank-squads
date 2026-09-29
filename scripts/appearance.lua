-- Shared by prototypes and runtime overlays; contains no runtime API access.
local M = {
  chassis_scale = 0.45,
  gun_scale = 0.09,
  gun_pivot_pixels = 48,
  -- The electric link row is drawn at this scale and stretched along x.
  electric = {link_scale = 0.5},
  weapons = {
    ["tank-squad-siege"] = {
      animation = "tank-squad-siege-gun", scale = 0.36,
      pivot_pixels = 137, aim_timeout = 180, recoil_ticks = 24,
    },
    ["tank-squad-flame"] = {
      sprite = "tank-squad-flame-gun", scale = 0.095,
      pivot_pixels = 155, aim_timeout = 60,
    },
    -- Painted variant guns: 627 px frames, rest, flash, casing, recovery.
    ["tank-squad-soldier-2"] = {
      animation = "tank-squad-red-gun", scale = 0.20,
      pivot_pixels = 87, aim_timeout = 60, recoil_ticks = 12,
    },
    ["tank-squad-soldier-3"] = {
      animation = "tank-squad-green-gun", scale = 0.25,
      pivot_pixels = 87, aim_timeout = 60, recoil_ticks = 12,
    },
    ["tank-squad-electric"] = {
      animation = "tank-squad-electric-gun", scale = 0.20,
      pivot_pixels = 87, aim_timeout = 90, recoil_ticks = 16,
    },
    -- The launcher smokes for five seconds after a launch, at a quarter
    -- frame per tick. nuclear.lua starts it only when a rocket leaves.
    ["tank-squad-nuclear"] = {
      animation = "tank-squad-nuclear-gun", scale = 0.17,
      pivot_pixels = 102, aim_timeout = 360, recoil_ticks = 360,
      animation_speed = 0.25, scripted_recoil = true,
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
  -- Shredder. The charge sheet is drawn north-facing on top of an invisible
  -- charging unit and turned toward the target; its scale matches its hull
  -- to the directional sheet. The offsets put the hull centre, not the
  -- frame centre, on the unit: the charge frames carry exhaust room below
  -- the hull, and frames 3 and 4 sit 34 source pixels higher than 1 and 2.
  shredder = {
    chassis_scale = 0.45,
    charge_scale = 0.206,
    arm_offset = 0.203,
    boost_offset = 0.421,
    -- The reticle ring is about 210 px across: about 2.3 tiles here.
    lock_scale = 0.35,
    -- The breakup frames show the whole vehicle at hull size; the burst,
    -- about 237 px across, covers the 8-tile shrapnel radius.
    breakup_scale = 0.4,
    burst_scale = 2.0,
    shard_scale = 0.2,
  },
  -- Constructor. The hull is drawn a little larger than a carrier's, about
  -- siege-tank size. The crane frame's mounting centre sits crane_base
  -- source pixels below the frame centre; scripts/engineers/crane.lua
  -- offsets the frame so that point stays on the hull. Calibrate both in
  -- the engine check.
  constructor = {chassis_scale = 0.5, crane_scale = 0.16, crane_base = 162},
  tier_colors = {
    {r = 0.9, g = 0.8, b = 0.2, a = 1},
    {r = 0.85, g = 0.25, b = 0.2, a = 1},
    {r = 0.3, g = 0.8, b = 0.35, a = 1},
  },
}

-- A 128-entry frame sequence: one rest frame, then each {frame, count}
-- step, then rest. A frozen gun (speed 0, offset 0) shows entry 1, the
-- rest frame, and the sweep freezes a gun long before the sequence loops.
function M.gun_sequence(steps)
  local sequence = {1}
  for _, step in ipairs(steps) do
    for _ = 1, step[2] do sequence[#sequence + 1] = step[1] end
  end
  while #sequence < 128 do sequence[#sequence + 1] = 1 end
  return sequence
end

return M
