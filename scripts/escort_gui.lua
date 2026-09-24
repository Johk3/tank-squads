local divisions = require("scripts.divisions")
local escort = require("scripts.escort")
local names = require("scripts.names")

local M = {}
local WINDOW, PANEL = "tank_squads_escort", "tank_squads_escorts"

-- Built only when the window opens: connected teammates first, then offline
-- ones, each alphabetical. The window stores the indices so a player joining
-- while it is open cannot shift the selection.
function M.ward_options(owner)
  local online, offline = {}, {}
  for _, p in pairs(game.players) do
    if p.force == owner.force then
      if p.connected then online[#online + 1] = p else offline[#offline + 1] = p end
    end
  end
  local function by_name(a, b) return a.name < b.name end
  table.sort(online, by_name)
  table.sort(offline, by_name)
  local out = {}
  for _, p in ipairs(online) do out[#out + 1] = p.index end
  for _, p in ipairs(offline) do out[#out + 1] = p.index end
  return out
end

function M.close(player_index)
  local player = game.get_player(player_index)
  local frame = player and player.gui.screen and player.gui.screen[WINDOW]
  if frame then frame.destroy() end
end

function M.toggle(player_index)
  local player = game.get_player(player_index)
  if not player then return end
  if player.gui.screen[WINDOW] then M.close(player_index); return end
  local n = divisions.selected(player_index)
  local frame = player.gui.screen.add{type = "frame", name = WINDOW, direction = "vertical",
    caption = {"tank-squads.escort-title", n}}
  if frame.force_auto_center then frame.force_auto_center() end
  local body = frame.add{type = "flow", name = "body", direction = "vertical"}
  if n < 1 or n > names.max_division or divisions.size(player_index, n) == 0 then
    body.add{type = "label", name = "hint", caption = {"tank-squads.escort-needs-division"}}
    body.add{type = "button", name = "close", caption = {"tank-squads.escort-close"}, tags = {tank_squads_escort = "close"}}
    return
  end
  local options = M.ward_options(player)
  local items, selected = {}, 1
  local current = divisions.record(player_index, n).escort
  for i, index in ipairs(options) do
    local p = game.get_player(index)
    items[i] = p.connected and p.name or {"tank-squads.escort-offline", p.name}
    if current and current.ward == index then selected = i end
  end
  body.add{type = "drop-down", name = "ward", items = items, selected_index = selected}
  body.ward.selected_index = selected
  local actions = body.add{type = "flow", name = "actions", direction = "horizontal"}
  actions.add{type = "button", name = "defensive", caption = {"tank-squads.formation-defensive"}, tags = {tank_squads_escort = "defensive"}}
  actions.add{type = "button", name = "offensive", caption = {"tank-squads.formation-offensive"}, tags = {tank_squads_escort = "offensive"}}
  actions.add{type = "button", name = "stop", caption = {"tank-squads.escort-stop"}, tags = {tank_squads_escort = "stop"}}
  actions.add{type = "button", name = "close", caption = {"tank-squads.escort-close"}, tags = {tank_squads_escort = "close"}}
  frame.tags = {division = n, wards = options}
end

local reasons = {ward = "tank-squads.escort-bad-ward", empty = "tank-squads.escort-needs-division",
  division = "tank-squads.escort-needs-division"}

function M.click(event)
  local element = event.element
  if not (element and element.valid and element.tags) then return false end
  local player = game.get_player(event.player_index)
  if not player then return false end
  local dismiss = element.tags.tank_squads_dismiss
  if dismiss then
    escort.dismiss(event.player_index, dismiss[1], dismiss[2])
    return true
  end
  local action = element.tags.tank_squads_escort
  if not action then return false end
  local frame = player.gui.screen[WINDOW]
  if action == "close" or not frame then M.close(event.player_index); return true end
  local n = frame.tags.division
  if action == "stop" then
    escort.stop(event.player_index, n)
  else
    local ward = frame.tags.wards[frame.body.ward.selected_index]
    local ok, reason = escort.start(event.player_index, n, ward, action)
    if not ok then player.print({reasons[reason] or "tank-squads.escort-bad-ward"}) end
  end
  M.close(event.player_index)
  return true
end

-- Rebuilt only when the list of escorts for that ward changes.
function M.update_wards(wards)
  for _, player in pairs(game.players) do
    if player.connected then
      local rows = {}
      for _, entry in ipairs(wards[player.index] or {}) do
        if entry.owner ~= player.index then rows[#rows + 1] = entry end
      end
      local frame = player.gui.left[PANEL]
      local signature = ""
      for _, entry in ipairs(rows) do signature = signature .. entry.owner .. ":" .. entry.n .. ":" .. entry.formation .. ";" end
      if #rows == 0 then
        if frame then frame.visible = false end
      elseif not (frame and frame.tags and frame.tags.signature == signature) then
        if frame then frame.destroy() end
        frame = player.gui.left.add{type = "frame", name = PANEL, direction = "vertical",
          caption = {"tank-squads.escort-panel-title"}}
        local list = frame.add{type = "flow", name = "rows", direction = "vertical"}
        for _, entry in ipairs(rows) do
          local owner = game.get_player(entry.owner)
          local row = list.add{type = "flow", direction = "horizontal"}
          row.add{type = "label", caption = {"tank-squads.escort-panel-row", owner and owner.name or "?", entry.n,
            {"tank-squads.formation-" .. entry.formation}}}
          row.add{type = "button", name = "dismiss", caption = {"tank-squads.escort-dismiss"},
            tags = {tank_squads_dismiss = {entry.owner, entry.n}}}
        end
        frame.tags = {signature = signature}
        frame.visible = true
      else
        frame.visible = true
      end
    end
  end
end

return M
