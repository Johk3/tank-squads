local insignia = require("scripts.insignia")

local M = {}

-- Slot 0 is the ad-hoc drag selection and keeps 0.2.0's green. Slots 1-9
-- take their insignia's accent colour.
M.COLORS = {[0] = {r = 0.2, g = 1.0, b = 0.35, a = 0.9}}
for n, slot in pairs(insignia.SLOTS) do M.COLORS[n] = slot.color end
-- Bumped whenever COLORS change; the configuration change redraws rings and
-- escort shapes of records drawn with another palette.
M.PALETTE = 2

-- Insignia sizes in tiles. The world badge floats over the leader; the map
-- badge sits above the slot number, which keeps its screen size.
local BADGE_TILES, BADGE_HEIGHT = 2.5, 3
local MAP_BADGE_TILES, MAP_BADGE_HEIGHT = 14, 9

local function destroy(objects, key)
  local object = objects[key]
  if object and object.valid then object.destroy() end
  objects[key] = nil
end

local function destroy_marker(marker)
  for _, key in ipairs({"object", "badge", "map_badge"}) do
    local object = marker[key]
    if object and object.valid then object.destroy() end
  end
end

-- Whole-force badges: the insignia is the division's public identity.
local function draw_badges(marker, n, leader)
  local sprite = insignia.sprite(n)
  if not sprite then return end
  for _, key in ipairs({"badge", "map_badge"}) do
    if marker[key] and marker[key].valid then marker[key].destroy() end
  end
  local forces, scale = {leader.force}, BADGE_TILES / insignia.SPRITE_TILES
  marker.badge = rendering.draw_sprite{sprite = sprite, target = {entity = leader, offset = {0, -BADGE_HEIGHT}},
    surface = leader.surface, forces = forces, x_scale = scale, y_scale = scale, render_layer = "air-object"}
  local map_scale = MAP_BADGE_TILES / insignia.SPRITE_TILES
  marker.map_badge = rendering.draw_sprite{sprite = sprite, target = {entity = leader, offset = {0, -MAP_BADGE_HEIGHT}},
    surface = leader.surface, forces = forces, x_scale = map_scale, y_scale = map_scale, render_mode = "chart"}
end

function M.clear_rings(record)
  record.render = record.render or {rings = {}, route = {}}
  for key in pairs(record.render.rings) do destroy(record.render.rings, key) end
  for key, marker in pairs(record.render.markers or {}) do
    destroy_marker(marker)
    record.render.markers[key] = nil
  end
end

-- One engine-followed label per division per surface, not per soldier.
function M.markers(player_index, n, record, entities)
  record.render.markers = record.render.markers or {}
  local markers, leaders = record.render.markers, {}
  for _, entity in ipairs(entities) do
    local index = entity.surface_index
    if not leaders[index] then leaders[index] = entity end
  end
  for index, marker in pairs(markers) do
    local leader = leaders[index]
    if not leader or not marker.object.valid or marker.unit_number ~= leader.unit_number then
      destroy_marker(marker)
      markers[index] = nil
    end
  end
  for index, leader in pairs(leaders) do
    if not markers[index] then
      markers[index] = {unit_number = leader.unit_number, object = rendering.draw_text{
        text = tostring(n), color = M.COLORS[n] or M.COLORS[0],
        target = leader, surface = leader.surface, players = {player_index},
        render_mode = "chart", alignment = "center", scale = 2,
        scale_with_zoom = true,
      }}
    end
    -- Keep a fixed screen size at distant map zooms. Update saved objects in
    -- place as well, so existing divisions benefit without being reassigned.
    local object = markers[index].object
    if object.scale ~= 2 then object.scale = 2 end
    if not object.scale_with_zoom then object.scale_with_zoom = true end
    local marker = markers[index]
    if n ~= 0 and not (marker.badge and marker.badge.valid and marker.map_badge and marker.map_badge.valid) then
      draw_badges(marker, n, leader)
    end
  end
end

function M.forget_ring(record, unit_number)
  record.render = record.render or {rings = {}, route = {}}
  destroy(record.render.rings, unit_number)
end

-- Ring radius by unit name. A ring is drawn on the ground, so it must reach
-- past the body to show. The headquarters' body reaches 7.9 tiles from its
-- centre; a ring the size of a tank's would stay hidden under it.
M.RING_RADIUS = {["tank-squad-headquarters"] = 8.2}
local RING_RADIUS = 1.7
-- A selected soldier also carries its division ring, so the selection ring
-- is drawn this much further out.
M.SELECTION_GAP = 0.5

-- Creates any missing ring and leaves existing ones alone, so this is safe to
-- call on every sweep. The renderer follows the entity itself, so no position
-- polling is needed. The name is read only when a ring is drawn.
function M.rings(player_index, n, record, entities)
  record.render = record.render or {rings = {}, route = {}}
  local rings, gap = record.render.rings, n == 0 and M.SELECTION_GAP or 0
  for _, entity in pairs(entities) do
    local ring = rings[entity.unit_number]
    if not (ring and ring.valid) then
      rings[entity.unit_number] = rendering.draw_circle{
        color = M.COLORS[n] or M.COLORS[0],
        radius = (M.RING_RADIUS[entity.name] or RING_RADIUS) + gap, width = 2, filled = false,
        target = entity, surface = entity.surface,
        players = {player_index}, draw_on_ground = true,
      }
    end
  end
end

function M.clear_route(record)
  record.render = record.render or {rings = {}, route = {}}
  for key in pairs(record.render.route) do destroy(record.render.route, key) end
end

function M.clear_escort(record)
  record.render = record.render or {rings = {}, route = {}}
  for key, object in pairs(record.render.escort or {}) do
    if object.valid then object.destroy() end
    record.render.escort[key] = nil
  end
  record.render.escort_ax = nil
  record.render.escort_ay = nil
  record.render.escort_formation = nil
  record.render.escort_ring = nil
  record.render.escort_band_min = nil
  record.render.escort_band_max = nil
  record.render.escort_char = nil
  record.render.escort_label_formation = nil
end

local BAND_SEGMENTS = 32

-- Anchor shapes are redrawn only when the anchor or formation changes. The
-- ward label is attached to the character, so the engine moves it; it is
-- recreated only when a respawn replaces the character.
function M.escort(owner_index, n, record, character, shape)
  local state = record.escort
  record.render = record.render or {rings = {}, route = {}}
  record.render.escort = record.render.escort or {}
  local objects = record.render.escort
  local color = M.COLORS[n] or M.COLORS[0]
  local viewers = {owner_index}
  if state.ward ~= owner_index then viewers[2] = state.ward end
  -- Anchor is only ever replaced (not mutated) when it actually moves
  -- (escort.M.track), so comparing numbers instead of rebuilding a string key
  -- every sweep still avoids redrawing when nothing changed. This compares
  -- the coordinates rather than the table reference: after a save/load,
  -- state.anchor and this gate's stored copy deserialize into two distinct
  -- tables even when they held the same position, so a reference comparison
  -- would force a spurious redraw on the first sweep after every load.
  local ax = state.anchor and state.anchor.x
  local ay = state.anchor and state.anchor.y
  -- The shape comes from map settings, so a changed radius redraws too.
  local band_min, band_max = shape.band[1], shape.band[2]
  if record.render.escort_ax ~= ax or record.render.escort_ay ~= ay
      or record.render.escort_formation ~= state.formation or record.render.escort_ring ~= shape.ring
      or record.render.escort_band_min ~= band_min or record.render.escort_band_max ~= band_max then
    for name, object in pairs(objects) do
      if name ~= "label" then
        if object.valid then object.destroy() end
        objects[name] = nil
      end
    end
    record.render.escort_ax, record.render.escort_ay, record.render.escort_formation = ax, ay, state.formation
    record.render.escort_ring, record.render.escort_band_min, record.render.escort_band_max = shape.ring, band_min, band_max
    if state.anchor and state.formation == "defensive" then
      objects.ring = rendering.draw_circle{color = color, radius = shape.ring, width = 3, filled = false,
        target = state.anchor, surface = state.surface_index, players = viewers, render_mode = "chart"}
    elseif state.anchor then
      for _, radius in ipairs(shape.band) do
        for i = 1, BAND_SEGMENTS do
          local a0, a1 = (i - 1) * 2 * math.pi / BAND_SEGMENTS, i * 2 * math.pi / BAND_SEGMENTS
          objects["band" .. radius .. ":" .. i] = rendering.draw_line{color = color, width = 2,
            dash_length = 6, gap_length = 6,
            from = {x = state.anchor.x + radius * math.cos(a0), y = state.anchor.y + radius * math.sin(a0)},
            to = {x = state.anchor.x + radius * math.cos(a1), y = state.anchor.y + radius * math.sin(a1)},
            surface = state.surface_index, players = viewers, render_mode = "chart"}
        end
      end
    end
  end
  -- Compared by character reference and formation, not a rebuilt string, so
  -- a steady escort (the common case) does no string work here either.
  local valid_character = character and character.valid and character or nil
  local label = objects.label
  if label and (not label.valid or record.render.escort_char ~= valid_character
      or record.render.escort_label_formation ~= state.formation) then
    if label.valid then label.destroy() end
    objects.label, label = nil, nil
  end
  if not label and valid_character then
    local text = n .. (state.formation == "defensive" and " DEF" or " OFF")
    -- Offset per division so two escorts on one ward do not overprint.
    objects.label = rendering.draw_text{text = text, color = color,
      target = {entity = valid_character, offset = {0, -2 - n}}, surface = valid_character.surface,
      players = viewers, render_mode = "chart", alignment = "center", scale = 1.5, scale_with_zoom = true}
    record.render.escort_char, record.render.escort_label_formation = valid_character, state.formation
  elseif not valid_character then
    record.render.escort_char, record.render.escort_label_formation = nil, nil
  end
end

-- Draws the route as a closed loop with numbered waypoints. Private to the
-- owning player, and redrawn from scratch whenever the route changes, which is
-- rare (a waypoint is added by hand).
function M.route(player_index, n, record, surface)
  M.clear_route(record)
  local patrol = record.patrol
  if not (patrol and patrol.waypoints and #patrol.waypoints > 1) then return end
  local color = M.COLORS[n] or M.COLORS[0]
  local objects = record.render.route
  local count = #patrol.waypoints
  for i = 1, count do
    local from = patrol.waypoints[i]
    local to = patrol.waypoints[(i % count) + 1]
    objects["line" .. i] = rendering.draw_line{
      color = color, width = 3,
      from = from, to = to, surface = surface,
      players = {player_index}, draw_on_ground = true,
      dash_length = 0.5, gap_length = 0.5,
    }
    objects["text" .. i] = rendering.draw_text{
      text = tostring(i), color = color,
      target = from, surface = surface,
      players = {player_index}, scale = 1.5,
      alignment = "center", scale_with_zoom = false,
    }
    objects["map-line" .. i] = rendering.draw_line{
      color = color, width = 2, from = from, to = to, surface = surface,
      players = {player_index}, render_mode = "chart",
    }
    objects["map-text" .. i] = rendering.draw_text{
      text = n .. ":" .. i, color = color, target = from, surface = surface,
      players = {player_index}, render_mode = "chart", scale = 1,
      alignment = "center", scale_with_zoom = false,
    }
  end
end

return M
