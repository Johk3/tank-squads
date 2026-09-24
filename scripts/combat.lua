local names = require('scripts.names')
local M = {}

-- Native attack_area walks into the area before firing. Issue native ranged
-- attacks one target at a time, choosing the next only on command completion.
local function assault_next(mission)
  local entity, order = mission.entity, mission.order
  local target = entity.surface.find_nearest_enemy{
    position = order.destination, max_distance = order.radius, force = entity.force,
  }
  if not target then return false end
  mission.target = target
  entity.commandable.set_command{type = defines.command.attack, target = target, distraction = defines.distraction.by_enemy}
  return true
end

function M.set_command(entity, command)
  M.forget(entity.unit_number)
  if command.type == defines.command.attack_area then
    storage.assaults = storage.assaults or {}
    local mission = {entity = entity, order = command}
    if assault_next(mission) then storage.assaults[entity.unit_number] = mission; return end
  end
  entity.commandable.set_command(command)
end

-- An attack whose target died reads back without `target`; set_command
-- rejects it, so such a command cannot be resumed.
local function resumable(command)
  if not command then return false end
  if command.type == defines.command.attack then return command.target ~= nil and command.target.valid end
  if command.type == defines.command.compound then
    for _, sub in pairs(command.commands) do if not resumable(sub) then return false end end
  end
  return true
end

-- Keep damage and firing in the engine. Interrupt building attacks for mobile
-- threats, then let a native compound command resume the original target.
local function defend(entity, enemy, building_shot)
  -- Runs on every hit. A live defense needs no further checks, so test it
  -- before any command readback, which builds new tables.
  local current = storage.combat and storage.combat[entity.unit_number]
  if current and current.target.valid and not building_shot then return end
  if not (enemy and enemy.valid and enemy.type == 'unit' and enemy.surface == entity.surface) then return end
  if entity.force == enemy.force or entity.force.get_friend(enemy.force) or entity.force.get_cease_fire(enemy.force) then return end
  local active = entity.commandable.distraction_command or entity.commandable.command
  if active and active.type == defines.command.attack and active.target and active.target.valid and active.target.type == 'unit' then return end
  storage.combat = storage.combat or {}
  local resume = current and current.resume or entity.commandable.command
  if not resumable(resume) then resume = {type = defines.command.stop, distraction = defines.distraction.by_enemy} end
  storage.combat[entity.unit_number] = {target = enemy, resume = resume}
  entity.commandable.set_command{
    type = defines.command.compound,
    structure_type = defines.compound_command.return_last,
    commands = {
      {type = defines.command.attack, target = enemy, distraction = defines.distraction.none},
      resume,
    },
  }
end

function M.on_damaged(event)
  local entity = event.entity
  if entity and entity.valid and names.soldier_set[entity.name] then defend(entity, event.cause) end
end

function M.on_shot(event)
  if event.effect_id ~= 'tank-squad-shot' then return end
  local entity, target = event.source_entity, event.target_entity
  if not (entity and entity.valid) then return end
  storage.combat_checks = storage.combat_checks or {}
  local last = storage.combat_checks[entity.unit_number]
  if last and event.tick - last < 30 then return end
  if not (names.soldier_set[entity.name] and target and target.valid) then return end
  if target.type == 'unit' then return end
  storage.combat_checks[entity.unit_number] = event.tick
  local nearest, best = nil, 20 * 20
  local p = entity.position
  for _, enemy in pairs(entity.surface.find_units{
    area = {{p.x - 20, p.y - 20}, {p.x + 20, p.y + 20}}, force = entity.force, condition = 'enemy',
  }) do
    local dx, dy = enemy.position.x - p.x, enemy.position.y - p.y
    local distance = dx * dx + dy * dy
    if enemy.destructible and distance < best then nearest, best = enemy, distance end
  end
  if nearest then defend(entity, nearest, true) end
end

function M.forget(unit_number)
  if storage.combat then storage.combat[unit_number] = nil end
  if storage.combat_checks then storage.combat_checks[unit_number] = nil end
  if storage.assaults then storage.assaults[unit_number] = nil end
end

function M.on_command_completed(unit_number, result)
  local mission = storage.assaults and storage.assaults[unit_number]
  if storage.combat then storage.combat[unit_number] = nil end
  if not mission then return false end
  local target_died = mission.target and not mission.target.valid
  if mission.entity.valid and (result ~= defines.behavior_result.fail or target_died) and assault_next(mission) then return true end
  M.forget(unit_number)
  return false
end

return M
