-- Service records: every soldier's and headquarters' name, and a soldier's
-- kills, XP and rank. Keyed by unit number, which a promotion never
-- changes, so no other module's storage is touched.
--
-- storage.veterans[unit_number] = {
--   adjective, noun  - name word indices (scripts/unit_names.lua)
--   xp, kills, rank  - soldiers only; the headquarters has none
--   labels           - alt-mode render objects (scripts/unit_labels.lua)
-- }
local names = require("scripts.names")
local ranks = require("scripts.ranks")
local unit_names = require("scripts.unit_names")
local labels = require("scripts.unit_labels")

local M = {}

-- Enemy deaths reach Lua to credit the soldier that landed the killing blow.
-- Only the enemy force's deaths: trees, rocks and the player's own
-- buildings never call Lua.
M.KILL_FILTERS = {{filter = "force", force = "enemy"}}

M.SHOT, M.SHELL_HIT = "tank-squad-shot", "tank-squad-shell-hit"

-- A rank's extra damage per shot is a share of the native attack's own
-- damage, of the same type, scaled by the force's research for that ammo.
-- The siege shell copies the base cannon projectile (1000 physical) and adds
-- its bonus when it lands; the flame stream deals 7 fire per shot.
M.BASE = {
  ["tank-squad-soldier-1"] = {amount = 6, type = "physical", ammo = "bullet"},
  ["tank-squad-soldier-2"] = {amount = 10, type = "physical", ammo = "bullet"},
  ["tank-squad-soldier-3"] = {amount = 16, type = "physical", ammo = "bullet"},
  ["tank-squad-siege"] = {amount = 1000, type = "physical", ammo = "cannon-shell", on_hit = true},
  ["tank-squad-flame"] = {amount = 7, type = "fire", ammo = "flamethrower"},
}

function M.get(unit_number)
  return storage.veterans and storage.veterans[unit_number]
end

function M.register(entity)
  storage.veterans = storage.veterans or {}
  local record = storage.veterans[entity.unit_number]
  if record then return record end
  record = unit_names.draw()
  if names.soldier_set[entity.name] then record.xp, record.kills, record.rank = 0, 0, 0 end
  storage.veterans[entity.unit_number] = record
  return record
end

function M.unregister(unit_number)
  local record = M.get(unit_number)
  if not record then return end
  labels.clear(record)
  unit_names.release(record)
  storage.veterans[unit_number] = nil
end

-- Called by the sweeps for every living unit.
function M.repair(entity)
  local record = M.get(entity.unit_number)
  if record then labels.repair(entity, record) end
end

local function apply_speed(entity, record)
  entity.speed = entity.prototype.speed * (1 + ranks.bonus(record.rank).speed)
end

local function promote(entity, record, rank)
  record.rank = rank
  apply_speed(entity, record)
  labels.set_rank(entity, record)
  local text = {"tank-squads.promoted", unit_names.localised(record), {"tank-squads.rank-" .. rank}}
  for _, player in pairs(entity.force.connected_players) do
    player.create_local_flying_text{text = text, position = entity.position, surface = entity.surface}
  end
end

function M.add_xp(entity, record, amount)
  record.xp = record.xp + amount
  local rank = ranks.for_xp(record.xp)
  if rank > record.rank then promote(entity, record, rank) end
end

function M.on_kill(event)
  local cause, victim = event.cause, event.entity
  if not (cause and cause.valid and victim and victim.valid) then return end
  local record = storage.veterans and storage.veterans[cause.unit_number]
  if not (record and record.xp) then return end
  record.kills = record.kills + 1
  M.add_xp(cause, record, victim.max_health / 10)
end

-- After a mod update the prototype speed may have changed.
function M.reapply()
  for id, record in pairs(storage.veterans or {}) do
    if record.rank and record.rank > 0 then
      local entity = game.get_entity_by_unit_number(id)
      if entity and entity.valid then apply_speed(entity, record) end
    end
  end
end

-- Runs for every hit on our units (the event is filtered to them). Max
-- health is fixed per prototype, so a rank heals back its share of each hit
-- instead. A killing blow is not reduced.
function M.on_damaged(event)
  local entity = event.entity
  if not (entity and entity.valid) then return end
  local record = storage.veterans and storage.veterans[entity.unit_number]
  local rank = record and record.rank
  if not (rank and rank > 0) or event.final_health <= 0 then return end
  entity.health = entity.health + event.final_damage_amount * ranks.bonus(rank).reduction
end

-- Runs for every shot and every siege shell impact. Recruits cost one lookup.
function M.on_shot(event)
  local id, source = event.effect_id, nil
  if id == M.SHOT then source = event.source_entity
  elseif id == M.SHELL_HIT then source = event.cause_entity
  else return end
  if not (source and source.valid) then return end
  local record = storage.veterans and storage.veterans[source.unit_number]
  local rank = record and record.rank
  if not (rank and rank > 0) then return end
  local base = M.BASE[source.name]
  if not base or (base.on_hit == true) ~= (id == M.SHELL_HIT) then return end
  local target = event.target_entity
  if not (target and target.valid) then return end
  local force = source.force
  local amount = base.amount * ranks.bonus(rank).damage * (1 + force.get_ammo_damage_modifier(base.ammo))
  target.damage(amount, force, base.type, source, source)
end

return M
