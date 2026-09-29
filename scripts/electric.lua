-- Electric tank impacts. The engine deals the burst damage and plays the
-- shock on every enemy it hits; this only draws the arcs from the contact
-- point to the nearest enemies, once per impact.
local appearance = require("scripts.appearance")

local M = {}

M.EFFECT = "tank-squad-electric-hit"
M.RADIUS, M.ARCS, M.TTL = 6, 6, 20
local TARGETS = {"unit", "unit-spawner", "turret", "character", "car", "spider-vehicle"}
-- Length in tiles of one link frame at its drawn scale.
local LINK_TILES = 313 * appearance.electric.link_scale / 32

local function arc(surface, from, to)
  local dx, dy = to.x - from.x, to.y - from.y
  local length = math.sqrt(dx * dx + dy * dy)
  if length < 0.1 then return end
  -- The link is drawn east-west. Orientation 0 is north and 0.25 is east,
  -- so a vector's orientation minus a quarter turn lays the link along it.
  local orientation = (math.atan2(dx, -dy) / (2 * math.pi) - 0.25) % 1
  rendering.draw_animation{animation = "tank-squad-electric-link", surface = surface,
    target = {x = from.x + dx / 2, y = from.y + dy / 2}, orientation = orientation,
    x_scale = length / LINK_TILES, y_scale = 1, time_to_live = M.TTL, animation_speed = 1,
    render_layer = "air-object"}
end

-- Returns the number of arcs drawn, or nil for another mod's effect.
function M.on_hit(event)
  if event.effect_id ~= M.EFFECT then return nil end
  local source = event.cause_entity or event.source_entity
  if not (source and source.valid) then return 0 end
  local surface = game.surfaces[event.surface_index]
  local from = event.target_position
  if not (surface and from) then return 0 end
  local force, drawn = source.force, 0
  for _, other in pairs(game.forces) do
    if force.is_enemy(other) then
      local found = surface.find_entities_filtered{position = from, radius = M.RADIUS, force = other,
        type = TARGETS, limit = M.ARCS - drawn}
      for _, e in pairs(found) do
        arc(surface, from, e.position)
        drawn = drawn + 1
      end
      if drawn >= M.ARCS then break end
    end
  end
  return drawn
end

return M
