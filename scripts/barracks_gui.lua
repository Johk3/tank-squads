local barracks = require('scripts.barracks')
local divisions = require('scripts.divisions')
local reinforcements = require('scripts.reinforcements')
local M = {}
local NAME = 'tank_squads_reinforcements'

function M.close(event)
  local player = game.get_player(event.player_index)
  local frame = player and player.gui.relative[NAME]
  if frame then frame.destroy() end
end

function M.refresh(player_index)
  local player = game.get_player(player_index)
  local frame = player and player.gui.relative[NAME]
  if not frame then return end
  local b = barracks.record(player.opened)
  if not b or b.entity.unit_number ~= frame.tags.barracks then frame.destroy(); return end
  local binding = b.reinforcement
  local editable = b.entity.force == player.force and (not binding or binding.player_index == player_index)
  frame.actions.apply.enabled = editable
  frame.actions.disable.enabled = editable and binding ~= nil
  if binding then
    local target, recruits = reinforcements.quota(b)
    frame.status.caption = {'tank-squads.reinforcement-status', binding.division, recruits or 0, target or 0}
    if not editable then frame.status.caption = {'tank-squads.reinforcement-other-owner'} end
  else
    frame.status.caption = {'tank-squads.reinforcement-off'}
  end
end

function M.open(event)
  M.close(event)
  local player = game.get_player(event.player_index)
  local b = barracks.record(event.entity)
  if not (player and b and b.entity.force == player.force) then return end
  local binding = b.reinforcement
  local n = binding and binding.division or math.max(1, divisions.selected(event.player_index))
  local target = reinforcements.quota(b) or 10
  local frame = player.gui.relative.add{type = 'frame', name = NAME, direction = 'vertical',
    caption = {'tank-squads.reinforcement-title'}, tags = {barracks = b.entity.unit_number},
    anchor = {gui = defines.relative_gui_type.assembling_machine_gui, position = defines.relative_gui_position.right}}
  local help = frame.add{type = 'label', caption = {'tank-squads.reinforcement-help'}}
  help.style.single_line = false
  help.style.maximal_width = 300
  frame.add{type = 'label', caption = {'tank-squads.reinforcement-division'}}
  local items = {}
  for i = 1, 9 do items[i] = {'tank-squads.division-number', i} end
  frame.add{type = 'drop-down', name = 'division', items = items, selected_index = n}
  frame.add{type = 'label', caption = {'tank-squads.reinforcement-target'}}
  frame.add{type = 'textfield', name = 'target', text = tostring(target),
    numeric = true, allow_decimal = false, allow_negative = false}
  local actions = frame.add{type = 'flow', name = 'actions'}
  actions.add{type = 'button', name = 'apply', caption = {'tank-squads.reinforcement-apply'},
    tags = {tank_squads_reinforcement_action = 'apply'}}
  actions.add{type = 'button', name = 'disable', caption = {'tank-squads.reinforcement-disable'},
    tags = {tank_squads_reinforcement_action = 'disable'}}
  frame.add{type = 'label', name = 'status', caption = ''}
  M.refresh(event.player_index)
end

function M.click(event)
  local element = event.element
  if not (element and element.valid) then return false end
  local action = element.tags.tank_squads_reinforcement_action
  if not action then return false end
  local player = game.get_player(event.player_index)
  local frame = player and player.gui.relative[NAME]
  local b = player and barracks.record(player.opened)
  if not (frame and b and frame.tags.barracks == b.entity.unit_number) then return true end
  local ok
  if action == 'disable' then
    ok = barracks.configure(b.entity, event.player_index, nil)
  elseif action == 'apply' then
    ok = barracks.configure(b.entity, event.player_index, frame.division.selected_index, tonumber(frame.target.text))
  end
  if not ok then player.print({'tank-squads.reinforcement-invalid'}) end
  M.refresh(event.player_index)
  return true
end

return M
