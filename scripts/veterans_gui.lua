-- Every soldier of each of the player's divisions, ranked by XP.
-- Picked soldiers become the drag selection or a new division. The window
-- is built only when it opens and reads service records, never entities,
-- so it costs the sweep nothing. Picks are checked again on use.
local names = require("scripts.names")
local ranks = require("scripts.ranks")
local insignia = require("scripts.insignia")
local unit_names = require("scripts.unit_names")
local veterans = require("scripts.veterans")
local divisions = require("scripts.divisions")

local M = {}

local WINDOW = "tank_squads_veterans"
local ICON = 24

-- The division's soldiers, most XP first. Kills break ties, then the unit
-- number, so the order never depends on table order.
function M.ranked(members)
  local ranked = {}
  for _, id in ipairs(members) do
    local record = veterans.get(id)
    if record and record.xp then ranked[#ranked + 1] = {id = id, record = record} end
  end
  table.sort(ranked, function(a, b)
    if a.record.xp ~= b.record.xp then return a.record.xp > b.record.xp end
    if a.record.kills ~= b.record.kills then return a.record.kills > b.record.kills end
    return a.id < b.id
  end)
  return ranked
end

local function icon(parent, sprite)
  local widget = parent.add{type = "sprite", sprite = sprite}
  widget.style.width, widget.style.height = ICON, ICON
  widget.style.stretch_image_to_widget_size = true
  return widget
end

function M.close(player_index)
  local player = game.get_player(player_index)
  local frame = player and player.gui.screen[WINDOW]
  if frame then frame.destroy() end
end

local function build(player)
  local frame = player.gui.screen.add{type = "frame", name = WINDOW, direction = "vertical",
    caption = {"tank-squads.veterans-title"}}
  if frame.force_auto_center then frame.force_auto_center() end
  local body = frame.add{type = "flow", name = "body", direction = "vertical"}
  local pane = body.add{type = "scroll-pane", name = "pane"}
  pane.style.maximal_height = 480
  local list = pane.add{type = "flow", name = "list", direction = "vertical"}
  local state = storage.divisions and storage.divisions[player.index]
  local slots = state and state.slots or {}
  local units = {}
  for n = 1, names.max_division do
    local record = slots[n]
    local ranked = record and M.ranked(record.members) or {}
    if #ranked > 0 then
      local header = list.add{type = "flow", name = "division_" .. n, direction = "horizontal"}
      header.style.vertical_align = "center"
      local sprite = insignia.sprite(n)
      if sprite then icon(header, sprite) end
      header.add{type = "label", style = "caption_label",
        caption = {"tank-squads.veterans-division", n, {"tank-squads.division-name-" .. n}, #record.members}}
      for _, entry in ipairs(ranked) do
        local soldier = entry.record
        local row = list.add{type = "flow", name = "unit_" .. entry.id, direction = "horizontal"}
        row.style.vertical_align = "center"
        row.add{type = "checkbox", name = "pick", state = false, caption = unit_names.localised(soldier)}
        icon(row, ranks.sprite(soldier.rank))
        row.add{type = "label", caption = {"tank-squads.veterans-row", {"tank-squads.rank-" .. soldier.rank},
          math.floor(soldier.xp), soldier.kills}}
        units[#units + 1] = entry.id
      end
    end
  end
  if #units == 0 then list.add{type = "label", name = "empty", caption = {"tank-squads.veterans-empty"}} end
  local actions = body.add{type = "flow", name = "actions", direction = "horizontal"}
  actions.add{type = "button", name = "select", caption = {"tank-squads.veterans-select"},
    tooltip = {"tank-squads.veterans-select-help"}, tags = {tank_squads_veterans = "select"}}
  actions.add{type = "button", name = "form", caption = {"tank-squads.veterans-form"},
    tooltip = {"tank-squads.veterans-form-help"}, tags = {tank_squads_veterans = "form"}}
  actions.add{type = "button", name = "close", caption = {"tank-squads.escort-close"},
    tags = {tank_squads_veterans = "close"}}
  frame.tags = {units = units}
end

function M.toggle(player_index)
  local player = game.get_player(player_index)
  if not player then return end
  if player.gui.screen[WINDOW] then M.close(player_index); return end
  build(player)
end

-- The ticked soldiers that are still alive and still in one of the
-- player's divisions.
local function picked(player, frame)
  local list, out = frame.body.pane.list, {}
  for _, id in ipairs(frame.tags.units or {}) do
    local row = list["unit_" .. id]
    if row and row.pick.state then
      local owner = divisions.owner(id)
      local entity = owner == player.index and game.get_entity_by_unit_number(id)
      if entity and entity.valid and entity.force_index == player.force_index then out[#out + 1] = entity end
    end
  end
  return out
end

-- Returns true when the click was one of the window's buttons.
function M.click(event)
  local element = event.element
  if not (element and element.valid and element.tags) then return false end
  local action = element.tags.tank_squads_veterans
  if not action then return false end
  local player = game.get_player(event.player_index)
  local frame = player and player.gui.screen[WINDOW]
  if action == "close" or not frame then M.close(event.player_index); return true end
  local soldiers = picked(player, frame)
  if #soldiers == 0 then
    player.print({"tank-squads.veterans-none-picked"})
    return true
  end
  divisions.select_area(event.player_index, soldiers)
  if action == "form" then
    local n = divisions.promote(event.player_index)
    player.print(n and {"tank-squads.selection-promoted", n} or {"tank-squads.veterans-no-free-division"})
  end
  M.close(event.player_index)
  return true
end

return M
