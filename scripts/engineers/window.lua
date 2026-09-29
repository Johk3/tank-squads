-- The Engineers window: which divisions escort constructors, and what each
-- constructor of the force is doing. Built when opened, refreshed once per
-- second only while open. It has a fixed width, one line per label and no
-- padding rows; the constructor list is rebuilt only when a row changed.
local names = require('scripts.names')
local insignia = require('scripts.insignia')
local state = require('scripts.engineers.state')
local ghosts = require('scripts.engineers.ghosts')
local teams = require('scripts.engineers.teams')

local M = {}

M.NAME = 'tank_squads_engineers'
M.WIDTH = 300
local ICON = 20
-- One short word per state; the tooltip explains it.
M.SHORT = {waiting = 'escort', seeking = 'moving', moving = 'moving', building = 'building', paused = 'paused',
  task_force = 'task-force', healing = 'healing', idle = 'idle'}

local function fixed(label)
  label.style.single_line = true
  label.style.horizontally_stretchable = false
  return label
end

local function slots(player_index)
  local pstate = storage.divisions and storage.divisions[player_index]
  return pstate and pstate.slots or {}
end

function M.close(player_index)
  local player = game.get_player(player_index)
  local frame = player and player.gui.screen[M.NAME]
  if frame and frame.valid then frame.destroy() end
end

local function build(player)
  local frame = player.gui.screen.add{type = 'frame', name = M.NAME, direction = 'vertical',
    caption = {'tank-squads.engineers-title'}}
  frame.style.width = M.WIDTH
  if frame.force_auto_center then frame.force_auto_center() end
  local body = frame.add{type = 'flow', name = 'body', direction = 'vertical'}
  fixed(body.add{type = 'label', name = 'escort_title', style = 'caption_label',
    caption = {'tank-squads.engineers-escort'}, tooltip = {'tank-squads.engineers-escort-help'}})
  local pool = body.add{type = 'table', name = 'pool', column_count = 3}
  for n = 1, names.max_division do
    local cell = pool.add{type = 'flow', name = 'cell_' .. n, direction = 'horizontal'}
    cell.style.vertical_align = 'center'
    local sprite = insignia.sprite(n)
    if sprite then
      local icon = cell.add{type = 'sprite', sprite = sprite}
      icon.style.width, icon.style.height = ICON, ICON
      icon.style.stretch_image_to_widget_size = true
    end
    cell.add{type = 'checkbox', name = 'pool_' .. n, state = false, caption = {'tank-squads.engineers-division', n},
      tags = {tank_squads_pool = n}}
  end
  fixed(body.add{type = 'label', name = 'list_title', style = 'caption_label',
    caption = {'tank-squads.engineers-constructors'}})
  body.add{type = 'table', name = 'list', column_count = 3, tags = {}}
  fixed(body.add{type = 'label', name = 'ghosts', tags = {}})
  body.add{type = 'button', name = 'close', caption = {'tank-squads.escort-close'},
    tags = {tank_squads_engineers = 'close'}}
  return frame
end

function M.refresh(player_index)
  local player = game.get_player(player_index)
  local frame = player and player.gui.screen[M.NAME]
  if not (frame and frame.valid) then return end
  local body, records = frame.body, slots(player_index)
  for n = 1, names.max_division do
    local cell = body.pool['cell_' .. n]
    local record = records[n]
    local has = record ~= nil and #record.members > 0
    if cell.visible ~= has then cell.visible = has end
    local on = has and record.mode == 'engineer'
    local box = cell['pool_' .. n]
    if box.state ~= on then box.state = on end
  end
  local s = state.peek()
  local rows = {}
  for _, r in pairs(s and s.constructors or {}) do
    if r.force_index == player.force_index then rows[#rows + 1] = r end
  end
  table.sort(rows, function(a, b) return a.id < b.id end)
  local parts = {}
  for _, r in ipairs(rows) do parts[#parts + 1] = r.id .. ':' .. r.state .. ':' .. teams.present(r.id) end
  local signature = table.concat(parts, ',')
  if body.list.tags.signature ~= signature then
    body.list.destroy()
    -- index keeps the list between its title and the ghost count.
    local list = body.add{type = 'table', name = 'list', column_count = 3, index = 4, tags = {signature = signature}}
    if #rows == 0 then fixed(list.add{type = 'label', name = 'none', caption = {'tank-squads.engineers-none'}}) end
    for _, r in ipairs(rows) do
      local short = M.SHORT[r.state] or 'idle'
      fixed(list.add{type = 'label', name = 'state_' .. r.id, caption = {'tank-squads.engineers-state-' .. short},
        tooltip = {'tank-squads.engineers-state-' .. short .. '-help'}})
      fixed(list.add{type = 'label', name = 'team_' .. r.id, caption = {'tank-squads.engineers-team', teams.present(r.id)}})
      list.add{type = 'sprite-button', name = 'map_' .. r.id, style = 'frame_action_button', sprite = 'item/radar',
        tooltip = {'tank-squads.engineers-map'}, tags = {tank_squads_constructor = r.id}}
    end
  end
  local count = ghosts.count(player.surface_index, player.force_index)
  if body.ghosts.tags.count ~= count then
    body.ghosts.caption = {'tank-squads.engineers-ghosts', count}
    body.ghosts.tags = {count = count}
  end
end

function M.toggle(player_index)
  local player = game.get_player(player_index)
  if not player then return end
  local frame = player.gui.screen[M.NAME]
  if frame and frame.valid then
    frame.destroy()
    return
  end
  build(player)
  M.refresh(player_index)
end

function M.refresh_all()
  for _, player in pairs(game.connected_players) do
    if player.gui.screen[M.NAME] then M.refresh(player.index) end
  end
end

-- The map button of a constructor row opens the map at it.
function M.click(event)
  local element = event.element
  if not (element and element.valid) then return false end
  if element.tags.tank_squads_engineers == 'close' then
    M.close(event.player_index)
    return true
  end
  local id = element.tags.tank_squads_constructor
  if not id then return false end
  local s = state.peek()
  local record = s and s.constructors[id]
  local player = game.get_player(event.player_index)
  if player and record and record.entity.valid and record.force_index == player.force_index then
    player.set_controller{type = defines.controllers.remote, position = record.entity.position,
      surface = record.entity.surface}
  end
  return true
end

function M.checked(event)
  local element = event.element
  if not (element and element.valid) then return false end
  local n = element.tags.tank_squads_pool
  if type(n) ~= 'number' then return false end
  if not teams.set_pool(event.player_index, n, element.state) then element.state = false end
  M.refresh(event.player_index)
  return true
end

return M
