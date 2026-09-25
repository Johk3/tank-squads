-- Alt-mode labels over each unit: its name, and above it a small rank badge
-- once it is promoted. Visible to the unit's whole force. The sweeps draw
-- and repair them (weapons.check, the headquarters sweep), so a new unit
-- gets its labels within a second and no event path draws anything.
local insignia = require("scripts.insignia")
local ranks = require("scripts.ranks")
local unit_names = require("scripts.unit_names")

local M = {}

-- Name height above the unit's centre, in tiles. The headquarters' body
-- reaches 7.9 tiles from its centre.
M.NAME_OFFSET = {["tank-squad-headquarters"] = -8.4}
local NAME_OFFSET = -1.6
-- Rank badge size, and its height above the name, in tiles.
M.RANK_TILES = 0.6
local RANK_GAP = -0.6

local function name_offset(entity)
  return M.NAME_OFFSET[entity.name] or NAME_OFFSET
end

local function draw_rank(entity, record)
  local scale = M.RANK_TILES / insignia.SPRITE_TILES
  return rendering.draw_sprite{sprite = ranks.sprite(record.rank),
    target = {entity = entity, offset = {0, name_offset(entity) + RANK_GAP}},
    surface = entity.surface, forces = {entity.force}, only_in_alt_mode = true,
    x_scale = scale, y_scale = scale, render_layer = "air-object"}
end

function M.clear(record)
  local labels = record.labels
  if not labels then return end
  if labels.name and labels.name.valid then labels.name.destroy() end
  if labels.rank and labels.rank.valid then labels.rank.destroy() end
  record.labels = nil
end

function M.draw(entity, record)
  M.clear(record)
  local labels = {force_index = entity.force_index}
  labels.name = rendering.draw_text{text = unit_names.localised(record),
    target = {entity = entity, offset = {0, name_offset(entity)}},
    surface = entity.surface, forces = {entity.force}, only_in_alt_mode = true,
    color = {r = 1, g = 1, b = 1, a = 0.9}, alignment = "center", vertical_alignment = "middle"}
  if record.rank and record.rank > 0 then labels.rank = draw_rank(entity, record) end
  record.labels = labels
end

function M.set_rank(entity, record)
  local labels = record.labels
  if not labels then return end
  if labels.rank and labels.rank.valid then
    labels.rank.sprite = ranks.sprite(record.rank)
  else
    labels.rank = draw_rank(entity, record)
  end
end

function M.repair(entity, record)
  local labels = record.labels
  if labels and labels.name.valid and labels.force_index == entity.force_index
      and (not (record.rank and record.rank > 0) or (labels.rank and labels.rank.valid)) then
    return
  end
  M.draw(entity, record)
end

return M
