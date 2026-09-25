local colors = require("scripts.render").COLORS
local divisions = require("scripts.divisions")
local M = {}

local NAME = "tank_squads_divisions"
-- Where a new window opens, in pixels at 100% UI scale: at the left edge,
-- below the top-left game widgets, where the side panel used to be.
local START = {x = 8, y = 180}
local WIDTH = {full = 260, compact = 0}

-- Per-player layout choices, kept with the save so the window looks the
-- same after loading. The window keeps its own position.
local function layout(player_index)
  storage.panel = storage.panel or {}
  local choice = storage.panel[player_index]
  if not choice then
    choice = {}
    storage.panel[player_index] = choice
  end
  return choice
end

local function title_button(bar, action, sprite, tooltip)
  return bar.add{type = "sprite-button", name = action, style = "frame_action_button", sprite = sprite,
    tooltip = tooltip, tags = {tank_squads_panel = action}}
end

-- A draggable window in player.gui.screen. The title bar moves it; its
-- buttons fold it to the title bar and switch between full and compact rows.
local function build(player)
  local old = player.gui.left[NAME]
  if old then old.destroy() end
  local frame = player.gui.screen.add{type = "frame", name = NAME, direction = "vertical"}
  local scale = player.display_scale or 1
  frame.location = {x = math.floor(START.x * scale), y = math.floor(START.y * scale)}
  local bar = frame.add{type = "flow", name = "titlebar", direction = "horizontal"}
  bar.drag_target = frame
  bar.style.horizontal_spacing = 8
  bar.add{type = "label", name = "title", style = "frame_title", caption = {"tank-squads.divisions-title"},
    ignored_by_interaction = true}
  local filler = bar.add{type = "empty-widget", name = "drag", style = "draggable_space_header"}
  filler.drag_target = frame
  filler.style.horizontally_stretchable = true
  filler.style.height = 24
  filler.style.minimal_width = 24
  title_button(bar, "compact", "utility/list_view", {"tank-squads.divisions-compact"})
  title_button(bar, "collapse", "utility/collapse", {"tank-squads.divisions-collapse"})
  local body = frame.add{type = "flow", name = "body", direction = "vertical"}
  body.add{type = "label", name = "help", caption = {"tank-squads.divisions-help"}}
  local list = body.add{type = "flow", name = "divisions", direction = "vertical"}
  for n = 0, 9 do
    local button = list.add{type = "button", name = "division_" .. n,
      tags = {tank_squads_division = n}, auto_toggle = false}
    button.style.font_color = colors[n]
    button.tooltip = n == 0 and {"tank-squads.selection-help"}
      or {"tank-squads.division-help", {"tank-squads.assign-key-" .. n}}
  end
  return frame
end

-- Applies the player's layout choices. Runs when the window is built or a
-- title button is clicked, not on every sweep.
local function arrange(frame, choice)
  local bar, body = frame.titlebar, frame.body
  body.visible = not choice.collapsed
  bar.collapse.sprite = choice.collapsed and "utility/expand" or "utility/collapse"
  bar.collapse.tooltip = choice.collapsed and {"tank-squads.divisions-expand"} or {"tank-squads.divisions-collapse"}
  bar.compact.toggled = choice.compact == true
  bar.compact.tooltip = choice.compact and {"tank-squads.divisions-full"} or {"tank-squads.divisions-compact"}
  body.help.visible = not choice.compact
  local width = choice.compact and WIDTH.compact or WIDTH.full
  for n = 0, 9 do body.divisions["division_" .. n].style.minimal_width = width end
end

function M.update(player_index)
  local player = game.get_player(player_index)
  if not player then return end
  local state = storage.divisions and storage.divisions[player_index]
  local selected = state and state.selected or 0
  local slots = state and state.slots or {}
  player.set_shortcut_toggled("tank-squad-scout-mode", slots[selected] ~= nil and slots[selected].mode == "scout")
  local frame = player.gui.screen[NAME]
  local populated = false
  for _, record in pairs(slots) do
    if #record.members > 0 or record.reinforcement_target then populated = true; break end
  end
  if not populated then
    if frame then frame.visible = false end
    -- A panel from before the window moved to the screen.
    local old = player.gui.left[NAME]
    if old then old.destroy() end
    return
  end
  local choice = layout(player_index)
  if not frame then
    frame = build(player)
    arrange(frame, choice)
  end
  frame.visible = true
  -- A folded window shows no rows, so it skips them until it is unfolded.
  if choice.collapsed then return end
  local compact = choice.compact == true
  for n = 0, 9 do
    local record = slots[n]
    local count = record and #record.members or 0
    local mode = record and record.mode or "idle"
    local button = frame.body.divisions["division_" .. n]
    button.visible = n ~= 0 or count > 0
    button.enabled = count > 0 or (record ~= nil and record.reinforcement_target ~= nil)
    button.toggled = n == selected
    -- Avoid assigning captions each sweep when nothing changed. Localised control
    -- placeholders are resolved by Factorio, so rebound keys remain accurate.
    local target = record and record.reinforcement_target
    -- A reinforcement target counts carriers, so a headquarters is left out.
    local carriers = target and divisions.fighters(player_index, n)
    local state = record and record.escort
    local mode_caption = {"tank-squads.mode-" .. mode}
    local mode_key = mode
    if mode == "escort" and state then
      local ward = game.get_player(state.ward)
      local detail = state.available and {"tank-squads.formation-" .. state.formation} or {"tank-squads.formation-waiting"}
      mode_caption = {"tank-squads.mode-escort", ward and ward.name or "?", detail}
      mode_key = mode .. ":" .. state.ward .. ":" .. state.formation .. ":" .. tostring(state.available)
    end
    local signature = count .. ":" .. mode_key .. ':' .. tostring(target) .. ':' .. tostring(carriers) .. ':' .. tostring(compact)
    if button.tags.status ~= signature then
      local size = target and {'tank-squads.reinforced-count', carriers, target} or count
      if compact then
        button.caption = {"tank-squads.division-row-compact", n, size, mode_caption}
      else
        button.caption = {"tank-squads.division-row", n, size,
          n == 0 and {"tank-squads.drag-selection"} or {"tank-squads.select-key-" .. n},
          mode_caption}
      end
      button.tags = {tank_squads_division = n, status = signature}
    end
  end
end

-- Title bar buttons. Returns true when the click was one of them.
function M.click(event)
  local element = event.element
  if not (element and element.valid) then return false end
  local action = element.tags.tank_squads_panel
  if action ~= "collapse" and action ~= "compact" then return false end
  local choice = layout(event.player_index)
  if action == "collapse" then choice.collapsed = not choice.collapsed or nil
  else choice.compact = not choice.compact or nil end
  local player = game.get_player(event.player_index)
  local frame = player and player.gui.screen[NAME]
  if frame then arrange(frame, choice) end
  return true
end

function M.clear_player(player_index)
  if storage.panel then storage.panel[player_index] = nil end
end

return M
