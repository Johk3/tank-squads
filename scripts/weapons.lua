local names = require("scripts.names")
local combat = require('scripts.combat')
local vision = require('scripts.vision')
local appearance = require("scripts.appearance")
local colors = appearance.tier_colors
local M = {}

function M.register(entity)
  if not (entity and entity.valid and names.soldier_set[entity.name]) then return end
  vision.track(entity)
  storage.weapons = storage.weapons or {}
  local visual = appearance.weapons[entity.name]
  local offset = visual and -visual.pivot_pixels * visual.scale / 32
    or -appearance.gun_pivot_pixels * appearance.gun_scale / 32
  local record = storage.weapons[entity.unit_number]
  if record and record.gun.valid then
    record.gun.oriented_offset = {0, offset}
    return record
  end
  local args = {
    target = entity, surface = entity.surface,
    orientation_target = entity, use_target_orientation = true,
    -- Each generated weapon has its own measured bearing offset.
    oriented_offset = {0, offset},
    tint = colors[names.soldier_set[entity.name]], render_layer = "higher-object-above",
  }
  local gun
  if visual and visual.animation then
    args.animation, args.animation_speed = visual.animation, 0
    gun = rendering.draw_animation(args)
  else
    args.sprite = visual and visual.sprite or "tank-squad-chaingun"
    gun = rendering.draw_sprite(args)
  end
  record = {entity = entity, gun = gun, aim_timeout = visual and visual.aim_timeout or 60,
    recoil_ticks = visual and visual.recoil_ticks}
  storage.weapons[entity.unit_number] = record
  return record
end

function M.unregister(unit_number)
  combat.forget(unit_number)
  vision.forget(unit_number)
  local record = storage.weapons and storage.weapons[unit_number]
  if not record then return end
  if record.gun.valid then record.gun.destroy() end
  storage.weapons[unit_number] = nil
end

-- The weapon's native attack supplies the actual target. Once assigned, the
-- renderer follows both entities and rotates the gun without Lua position or
-- angle polling. Repeated shots at the same target only update the timestamp.
function M.on_shot(event)
  if event.effect_id ~= "tank-squad-shot" then return end
  local source, target = event.source_entity, event.target_entity
  if not (source and source.valid and target and target.valid) then return end
  local record = storage.weapons and storage.weapons[source.unit_number]
  if record and record.gun.valid and record.recoil_ticks then
    record.gun.animation_speed = 1
    record.gun.animation_offset = -event.tick
    record.recoiling = true
  end
  -- Sustained fire: the gun already tracks this target.
  if record and record.target == target and record.gun.valid then
    record.last_shot = event.tick
    return
  end
  if source.surface_index ~= target.surface_index then return end
  if not (record and record.gun.valid) then record = M.register(source) end
  if not record then return end
  if record.recoil_ticks and not record.recoiling then
    record.gun.animation_speed = 1
    record.gun.animation_offset = -event.tick
    record.recoiling = true
  end
  if record.target ~= target then
    record.gun.orientation_target = target
    record.gun.use_target_orientation = false
    record.target = target
  end
  record.last_shot = event.tick
end

-- Piggybacks on the existing one-second sweep. No enemy searches, movement,
-- ammunition simulation, or per-frame work happens here.
local function check(id, record)
  if not record.entity.valid then
    M.unregister(id)
  elseif not record.gun.valid then
    M.register(record.entity)
  else
    if record.recoiling and game.tick - record.last_shot >= record.recoil_ticks then
      record.gun.animation_speed, record.gun.animation_offset = 0, 0
      record.recoiling = nil
    end
    if record.target and (not record.target.valid
      or record.target.surface_index ~= record.entity.surface_index
      or game.tick - record.last_shot >= (record.aim_timeout or 60)) then
      record.gun.orientation_target = record.entity
      record.gun.use_target_orientation = true
      record.target = nil
      -- Recoil may still be active when a target dies immediately.
      if not record.recoiling then record.last_shot = nil end
    end
  end
end

-- Each soldier is checked in the slice its unit number falls in, so a large
-- army's guns are spread over the second. A nil phase checks every soldier.
function M.tick(phase, phases)
  for id, record in pairs(storage.weapons or {}) do
    if phase == nil or id % phases == phase then check(id, record) end
  end
end

return M
