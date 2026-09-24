local colors = require("scripts.render").COLORS
local M = {}

function M.update(player_index)
  local player = game.get_player(player_index)
  if not player then return end
  local state = storage.divisions and storage.divisions[player_index]
  local selected = state and state.selected or 0
  local slots = state and state.slots or {}
  player.set_shortcut_toggled("tank-squad-scout-mode", slots[selected] ~= nil and slots[selected].mode == "scout")
  local frame = player.gui.left.tank_squads_divisions
  local populated = false
  for _, record in pairs(slots) do
    if #record.members > 0 or record.reinforcement_target then populated = true; break end
  end
  if not populated then
    if frame then frame.visible = false end
    return
  end
  if not frame then
    frame = player.gui.left.add{type = "frame", name = "tank_squads_divisions",
      direction = "vertical", caption = {"tank-squads.divisions-title"}}
    frame.add{type = "label", caption = {"tank-squads.divisions-help"}}
    local list = frame.add{type = "flow", name = "divisions", direction = "vertical"}
    for n = 0, 9 do
      local button = list.add{type = "button", name = "division_" .. n,
        tags = {tank_squads_division = n}, auto_toggle = false}
      button.style.font_color = colors[n]
      button.style.minimal_width = 260
      button.tooltip = n == 0 and {"tank-squads.selection-help"}
        or {"tank-squads.division-help", {"tank-squads.assign-key-" .. n}}
    end
  end
  frame.visible = true
  for n = 0, 9 do
    local record = slots[n]
    local count = record and #record.members or 0
    local mode = record and record.mode or "idle"
    local button = frame.divisions["division_" .. n]
    button.visible = n ~= 0 or count > 0
    button.enabled = count > 0 or (record ~= nil and record.reinforcement_target ~= nil)
    button.toggled = n == selected
    -- Avoid assigning captions each sweep when nothing changed. Localised control
    -- placeholders are resolved by Factorio, so rebound keys remain accurate.
    local target = record and record.reinforcement_target
    local state = record and record.escort
    local mode_caption = {"tank-squads.mode-" .. mode}
    local mode_key = mode
    if mode == "escort" and state then
      local ward = game.get_player(state.ward)
      local detail = state.available and {"tank-squads.formation-" .. state.formation} or {"tank-squads.formation-waiting"}
      mode_caption = {"tank-squads.mode-escort", ward and ward.name or "?", detail}
      mode_key = mode .. ":" .. state.ward .. ":" .. state.formation .. ":" .. tostring(state.available)
    end
    local signature = count .. ":" .. mode_key .. ':' .. tostring(target)
    if button.tags.status ~= signature then
      button.caption = {"tank-squads.division-row", n, target and {'tank-squads.reinforced-count', count, target} or count,
        n == 0 and {"tank-squads.drag-selection"} or {"tank-squads.select-key-" .. n},
        mode_caption}
      button.tags = {tank_squads_division = n, status = signature}
    end
  end
end

return M
