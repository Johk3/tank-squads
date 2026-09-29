-- Nuclear tank launches. The native attack only reports a firing moment
-- once a second; this enforces the rank's reload, checks the blast radius
-- for friends and launches a nuke, or a plain rocket while friends are near.
local ranks = require("scripts.ranks")
local weapons = require("scripts.weapons")

local M = {}

M.EFFECT = "tank-squad-nuke"
M.NUKE, M.FALLBACK = "tank-squad-atomic-rocket", "tank-squad-nuke-fallback"
M.BLAST, M.MARGIN = 14, 3
M.RELOAD, M.FLOOR = 1200, 300
M.SPEED = 0.3

-- Entities that come and go on their own, such as our own tracers, never
-- count as friends in the blast.
local TRANSIENT = {
  projectile = true, ["artillery-projectile"] = true, stream = true, explosion = true, fire = true,
  sticker = true, ["particle-source"] = true, ["smoke-with-trigger"] = true, beam = true,
  corpse = true, ["character-corpse"] = true, ["entity-ghost"] = true, ["tile-ghost"] = true,
  ["item-request-proxy"] = true, ["deconstructible-tile-proxy"] = true, ["highlight-box"] = true,
  ["speech-bubble"] = true,
}

-- A rank's damage bonus shortens the reload by its square root.
function M.reload(rank)
  local ticks = M.RELOAD / math.sqrt(1 + ranks.bonus(rank).damage)
  return math.max(M.FLOOR, math.floor(ticks + 0.5))
end

-- True when no entity of the force or a friend force is within the blast
-- radius plus a margin. The tank counts too, so it never nukes itself.
function M.clear(surface, position, force)
  local radius = M.BLAST + M.MARGIN
  for _, other in pairs(game.forces) do
    if other == force or force.get_friend(other) then
      for _, e in pairs(surface.find_entities_filtered{position = position, radius = radius, force = other}) do
        if not TRANSIENT[e.type] then return false end
      end
    end
  end
  return true
end

-- Returns the projectile launched, or nil.
function M.on_trigger(event)
  if event.effect_id ~= M.EFFECT then return nil end
  local source, target = event.source_entity, event.target_entity
  if not (source and source.valid and target and target.valid) then return nil end
  local record = storage.weapons and storage.weapons[source.unit_number]
  if not record then return nil end
  if record.next_launch and event.tick < record.next_launch then return nil end
  local surface, position = source.surface, target.position
  local name = M.clear(surface, position, source.force) and M.NUKE or M.FALLBACK
  surface.create_entity{name = name, position = source.position, force = source.force,
    source = source, cause = source, target = position, speed = M.SPEED}
  surface.play_sound{path = "tank-squad-nuke-launch", position = source.position}
  record.next_launch = event.tick + M.reload(record.rank or 0)
  weapons.recoil(record, event.tick)
  return name
end

return M
