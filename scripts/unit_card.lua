-- A small card with a unit's service record, shown while the player hovers
-- the unit. Factorio has no custom tooltip for units. The card lives only
-- while the unit stays hovered, so it ignores the cursor and cannot be
-- dragged. storage.unit_card[player_index] = the hovered unit, so players
-- without a card cost the sweep nothing.
local names = require("scripts.names")
local ranks = require("scripts.ranks")
local insignia = require("scripts.insignia")
local unit_names = require("scripts.unit_names")
local veterans = require("scripts.veterans")
local divisions = require("scripts.divisions")

local M = {}

local NAME = "tank_squads_unit_card"
-- Right of the division window's default place, in pixels at 100% UI scale.
local START = {x = 284, y = 180}
local ICON = 32

local function icon(parent, name)
  local sprite = parent.add{type = "sprite", name = name}
  sprite.style.width, sprite.style.height = ICON, ICON
  sprite.style.stretch_image_to_widget_size = true
  return sprite
end

local function build(player)
  local frame = player.gui.screen.add{type = "frame", name = NAME, direction = "vertical"}
  frame.ignored_by_interaction = true
  local scale = player.display_scale or 1
  frame.location = {x = math.floor(START.x * scale), y = math.floor(START.y * scale)}
  frame.add{type = "label", name = "unit_name", style = "frame_title"}
  frame.add{type = "label", name = "unit_kind"}
  local rank = frame.add{type = "flow", name = "rank_row", direction = "horizontal"}
  icon(rank, "badge")
  rank.add{type = "label", name = "title"}
  frame.add{type = "progressbar", name = "xp_bar"}
  frame.add{type = "label", name = "xp_text"}
  frame.add{type = "label", name = "kill_count"}
  local division = frame.add{type = "flow", name = "division_row", direction = "horizontal"}
  icon(division, "insignia")
  division.add{type = "label", name = "title"}
  return frame
end

local function fill(frame, entity, record)
  frame.unit_name.caption = unit_names.localised(record)
  frame.unit_kind.caption = {"entity-name." .. entity.name}
  local soldier = record.xp ~= nil
  frame.rank_row.visible, frame.xp_bar.visible = soldier, soldier
  frame.xp_text.visible, frame.kill_count.visible = soldier, soldier
  if soldier then
    frame.rank_row.badge.sprite = ranks.sprite(record.rank)
    frame.rank_row.title.caption = {"tank-squads.rank-" .. record.rank}
    local floor, next_xp = ranks.LIST[record.rank].xp, ranks.next_xp(record.rank)
    local xp = math.floor(record.xp)
    if next_xp then
      frame.xp_bar.value = (record.xp - floor) / (next_xp - floor)
      frame.xp_text.caption = {"tank-squads.card-xp", xp, next_xp}
    else
      frame.xp_bar.value = 1
      frame.xp_text.caption = {"tank-squads.card-xp-top", xp}
    end
    frame.kill_count.caption = {"tank-squads.card-kills", record.kills}
  end
  local _, n = divisions.owner(entity.unit_number)
  local sprite = n and insignia.sprite(n)
  frame.division_row.visible = sprite ~= nil
  if sprite then
    frame.division_row.insignia.sprite = sprite
    frame.division_row.title.caption = {"tank-squads.division-name-" .. n}
  end
end

local function close(player_index)
  local player = game.get_player(player_index)
  local frame = player and player.gui.screen[NAME]
  if frame then frame.destroy() end
  if storage.unit_card then storage.unit_card[player_index] = nil end
end

local function show(player, entity)
  local record = veterans.get(entity.unit_number)
  if not record then close(player.index); return end
  local frame = player.gui.screen[NAME]
  if not (frame and frame.valid) then frame = build(player) end
  fill(frame, entity, record)
  storage.unit_card = storage.unit_card or {}
  storage.unit_card[player.index] = entity
end

function M.on_selected(event)
  local player = game.get_player(event.player_index)
  if not player then return end
  local entity = player.selected
  if entity and names.unit_set[entity.name] and entity.force_index == player.force_index then
    show(player, entity)
  elseif storage.unit_card and storage.unit_card[player.index] then
    close(player.index)
  end
end

-- Once a second: open cards follow kills and promotions.
function M.refresh()
  local cards = storage.unit_card
  if not cards then return end
  for player_index, entity in pairs(cards) do
    local player = game.get_player(player_index)
    if player and entity.valid and player.selected == entity then show(player, entity)
    else close(player_index) end
  end
end

function M.clear(player_index)
  close(player_index)
end

return M
