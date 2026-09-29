-- Service records: every soldier's and headquarters' name, and a soldier's
-- kills, XP and rank. Keyed by unit number, which a promotion never
-- changes, so no other module's storage is touched.
--
-- storage.veterans[unit_number] = {
--   adjective, noun  - name word indices (scripts/unit_names.lua)
--   xp, kills, rank  - soldiers only; the headquarters has none
--   kind             - the unit's prototype name, for the soldier list
-- }
-- The hover card (scripts/unit_card.lua) shows the record. Nothing is drawn
-- over the units: a render object per unit costs the engine work every tick.
local names = require("scripts.names")
local ranks = require("scripts.ranks")
local unit_names = require("scripts.unit_names")

local M = {}

-- Enemy deaths reach Lua to credit the soldier that landed the killing blow.
-- Only the enemy force's deaths: trees, rocks and the player's own
-- buildings never call Lua.
M.KILL_FILTERS = {{filter = "force", force = "enemy"}}

M.SHOT, M.SHELL_HIT = "tank-squad-shot", "tank-squad-shell-hit"

-- A large bonus is dealt in at most this many hits per shot, each larger
-- than a native hit, so a Legend's shot costs four damage calls, not eleven.
M.MAX_HITS = 4

-- A rank's extra damage per attack is a share of the native attack's own
-- damage, of the same type, scaled by the force's research for that ammo.
-- `hit` is the size of one native hit. The bonus is banked on the gun record
-- and dealt in hits of exactly that size, so flat armour takes the same share
-- of it as of the native damage.
-- The siege shell copies the base cannon projectile (1000 physical) and adds
-- its bonus when it lands. A flame attack lands three stream particles of 7
-- fire (measured against a rocket silo: 21 raw per 12-tick attack). Units
-- with `on_hit` add their bonus when that impact effect fires.
M.BASE = {
  ["tank-squad-soldier-1"] = {amount = 6, hit = 6, type = "physical", ammo = "bullet"},
  ["tank-squad-soldier-2"] = {amount = 10, hit = 10, type = "physical", ammo = "bullet"},
  ["tank-squad-soldier-3"] = {amount = 16, hit = 16, type = "physical", ammo = "bullet"},
  ["tank-squad-siege"] = {amount = 1000, hit = 1000, type = "physical", ammo = "cannon-shell", on_hit = M.SHELL_HIT},
  ["tank-squad-flame"] = {amount = 21, hit = 7, type = "fire", ammo = "flamethrower"},
  -- A ball lands 120 on its target plus the 180 burst.
  ["tank-squad-electric"] = {amount = 300, hit = 300, type = "electric", ammo = "laser", on_hit = "tank-squad-electric-hit"},
  -- Only the fallback rocket takes a bonus (50 direct plus 100 splash); a
  -- nuke's rank shortens its reload instead (scripts/nuclear.lua).
  ["tank-squad-nuclear"] = {amount = 150, hit = 150, type = "explosion", ammo = "rocket", on_hit = "tank-squad-rocket-hit"},
}
-- Impact effects that carry a bonus, reported with the shooter as cause.
M.HITS = {}
for _, base in pairs(M.BASE) do if base.on_hit then M.HITS[base.on_hit] = true end end

function M.get(unit_number)
  return storage.veterans and storage.veterans[unit_number]
end

function M.register(entity)
  storage.veterans = storage.veterans or {}
  local record = storage.veterans[entity.unit_number]
  if record then
    -- Records from before 0.29.0 have no kind.
    record.kind = record.kind or entity.name
    return record
  end
  record = unit_names.draw()
  record.kind = entity.name
  if names.soldier_set[entity.name] then record.xp, record.kills, record.rank = 0, 0, 0 end
  storage.veterans[entity.unit_number] = record
  return record
end

function M.unregister(unit_number)
  local record = M.get(unit_number)
  if not record then return end
  unit_names.release(record)
  storage.veterans[unit_number] = nil
end

-- Set by control.lua to scripts/transition.lua's roll, which needs modules
-- that already require this one.
M.on_promoted = nil

local function apply_speed(entity, record)
  entity.speed = entity.prototype.speed * (1 + ranks.bonus(record.rank).speed)
end

-- Moves a service record to the unit that replaces its soldier, keeping
-- the name, XP, kills and rank.
function M.transfer(old_id, entity)
  local record = M.get(old_id)
  if not record then return nil end
  storage.veterans[old_id] = nil
  storage.veterans[entity.unit_number] = record
  record.kind = entity.name
  if record.rank and record.rank > 0 then apply_speed(entity, record) end
  return record
end

local function promote(entity, record, rank)
  record.rank = rank
  local gun = storage.weapons and storage.weapons[entity.unit_number]
  if gun then gun.rank = rank end
  apply_speed(entity, record)
  local text = {"tank-squads.promoted", unit_names.localised(record), {"tank-squads.rank-" .. rank}}
  for _, player in pairs(entity.force.connected_players) do
    player.create_local_flying_text{text = text, position = entity.position, surface = entity.surface}
  end
  if M.on_promoted then M.on_promoted(entity, record, rank) end
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

-- Runs for every shot and every siege shell impact. A shot's shooter is the
-- gun record weapons.on_shot already resolved, so a recruit's shot reads no
-- entity at all. Shell impacts are rare and look the siege tank up.
function M.on_shot(event, shooter)
  local id, source, rank = event.effect_id, nil, nil
  if id == M.SHOT then
    rank = shooter and shooter.rank
    if not (rank and rank > 0) then return end
    source = event.source_entity
  elseif M.HITS[id] then
    source = event.cause_entity
    if not (source and source.valid) then return end
    local record = storage.veterans and storage.veterans[source.unit_number]
    rank = record and record.rank
    if not (rank and rank > 0) then return end
  else
    return
  end
  local base = M.BASE[source.name]
  if not base or base.on_hit ~= (id ~= M.SHOT and id or nil) then return end
  local target = event.target_entity
  if not (target and target.valid) then return end
  local force = source.force
  local research = 1 + force.get_ammo_damage_modifier(base.ammo)
  local amount = base.amount * ranks.bonus(rank).damage * research
  -- An impact has no gun record to bank on; its bonus is large anyway.
  if id ~= M.SHOT then
    target.damage(amount, force, base.type, source, source)
    return
  end
  local hit = base.hit * research
  amount = amount + (shooter.bonus or 0)
  local hits = math.floor(amount / hit)
  if hits > M.MAX_HITS then hit, hits = amount / M.MAX_HITS, M.MAX_HITS end
  local dealt = 0
  while dealt < hits and target.valid do
    target.damage(hit, force, base.type, source, source)
    dealt = dealt + 1
  end
  shooter.bonus = math.max(0, amount - dealt * hit)
end

return M
