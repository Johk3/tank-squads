-- A carrier's promotion may rebuild it as an electric or nuclear tank.
-- The swap reuses the death clean-up for the old unit and the
-- reinforcement join for the new one, so every job table sees a soldier
-- leave and a recruit arrive.
local names = require("scripts.names")
local veterans = require("scripts.veterans")
local weapons = require("scripts.weapons")
local divisions = require("scripts.divisions")
local patrol = require("scripts.patrol")
local commands = require("scripts.commands")
local scout = require("scripts.scout")
local reinforcements = require("scripts.reinforcements")
local unit_names = require("scripts.unit_names")
local combat = require("scripts.combat")

local M = {}

-- Chance by rank reached. About one carrier in six that reach Legend is
-- rebuilt on the way.
M.CHANCE = {[1] = 0.01, [2] = 0.02, [3] = 0.03, [4] = 0.05, [5] = 0.08}
M.CARRIERS = {["tank-squad-soldier-1"] = true, ["tank-squad-soldier-2"] = true, ["tank-squad-soldier-3"] = true}
M.KINDS = names.promoted_names
local SHORT = {["tank-squad-electric"] = "electric", ["tank-squad-nuclear"] = "nuclear"}

-- The game's own generator: deterministic on every peer. Tests replace it.
M.random = function(n)
  if n then return math.random(n) end
  return math.random()
end

-- The unit a carrier becomes at this rank, or nil. storage.transition_override
-- false never rebuilds, a unit name always picks that unit.
function M.pick(name, rank)
  if not M.CARRIERS[name] then return nil end
  local override = storage.transition_override
  if override == false then return nil end
  if override then return override end
  local chance = M.CHANCE[rank]
  if not chance or M.random() >= chance then return nil end
  return M.KINDS[M.random(#M.KINDS)]
end

local function announce(entity, record, kind)
  local text = {"tank-squads.transitioned-" .. SHORT[kind], unit_names.localised(record)}
  for _, player in pairs(entity.force.connected_players) do
    player.create_local_flying_text{text = text, position = entity.position, surface = entity.surface}
    player.play_sound{path = "utility/achievement_unlocked"}
  end
end

function M.swap(old, kind)
  local surface, position, force = old.surface, old.position, old.force
  local share = old.health / old.max_health
  local new = surface.create_entity{name = kind, position = position, force = force}
  if not new then return nil end
  new.health = new.max_health * share
  local old_id, new_id = old.unit_number, new.unit_number
  local player_index, n, division = divisions.owner(old_id)
  local record = veterans.transfer(old_id, new)
  -- A soldier outside a division, such as one walking to a rally flag,
  -- keeps its order. A fight's interrupted order is the one to resume.
  local fight = storage.combat and storage.combat[old_id]
  local command = not division and (fight and fight.resume or old.commandable.command)
  -- A scout team keeps the soldier's place, or it would read the swap as a
  -- death and call for help.
  if division then scout.replace(division, old_id, new) end
  -- The same clean-up as a death, in the same order (see control.lua).
  weapons.unregister(old_id)
  divisions.forget(old_id)
  patrol.forget(old_id)
  commands.forget(old_id)
  weapons.register(new)
  if division then
    reinforcements.replace(division, old_id, new_id)
    divisions.add_member(player_index, n, new_id, new)
    reinforcements.assign_job(division, new)
  elseif combat.resumable(command) then
    combat.set_command(new, command)
  end
  old.destroy{raise_destroy = true}
  if record then announce(new, record, kind) end
  return new
end

function M.roll(entity, record, rank)
  local kind = M.pick(entity.name, rank)
  if kind then return M.swap(entity, kind) end
end

return M
