-- The Engineers window: which divisions escort constructors, what each
-- constructor of the force is doing and whether it builds rings, the
-- force's rings with their settings, and which divisions garrison them.
-- Built when opened, refreshed once per second only while open. It has a
-- fixed width, one line per label and no padding rows; the constructor and
-- ring lists are rebuilt only when a row changed.
local names = require('scripts.names')
local insignia = require('scripts.insignia')
local state = require('scripts.engineers.state')
local ghosts = require('scripts.engineers.ghosts')
local teams = require('scripts.engineers.teams')
local constructor = require('scripts.engineers.constructor')
local geometry = require('scripts.engineers.rings.geometry')
local rings = require('scripts.engineers.rings.rings')
local garrison = require('scripts.engineers.rings.garrison')

local M = {}

M.NAME = 'tank_squads_engineers'
M.WIDTH = 340
-- A delete asks for a second click within this many ticks.
M.CONFIRM_TICKS = 3 * 60
local ICON = 20
-- One short word per state; the tooltip explains it.
M.SHORT = {waiting = 'escort', seeking = 'moving', moving = 'moving', building = 'building', paused = 'paused',
  task_force = 'task-force', healing = 'healing', idle = 'idle'}
M.RING_SHORT = {built = 'built', tearing_down = 'tearing-down', deleted = 'deleted'}

local function fixed(label)
  label.style.single_line = true
  label.style.horizontally_stretchable = false
  return label
end

local function slots(player_index)
  local pstate = storage.divisions and storage.divisions[player_index]
  return pstate and pstate.slots or {}
end

local function count_of(list)
  local n = 0
  for _ in pairs(list or {}) do n = n + 1 end
  return n
end

-- The ring delete waiting for its second click, if still in time.
local function armed(player_index, n)
  local s = state.peek()
  local a = s and s.armed and s.armed[player_index]
  return a ~= nil and a.n == n and game.tick - a.tick < M.CONFIRM_TICKS
end

function M.close(player_index)
  local player = game.get_player(player_index)
  local frame = player and player.gui.screen[M.NAME]
  if frame and frame.valid then frame.destroy() end
end

local function division_cells(parent, name, add)
  local grid = parent.add{type = 'table', name = name, column_count = 3}
  for n = 1, names.max_division do
    local cell = grid.add{type = 'flow', name = 'cell_' .. n, direction = 'horizontal'}
    cell.style.vertical_align = 'center'
    local sprite = insignia.sprite(n)
    if sprite then
      local icon = cell.add{type = 'sprite', sprite = sprite}
      icon.style.width, icon.style.height = ICON, ICON
      icon.style.stretch_image_to_widget_size = true
    end
    add(cell, n)
  end
  return grid
end

local function build(player)
  local frame = player.gui.screen.add{type = 'frame', name = M.NAME, direction = 'vertical',
    caption = {'tank-squads.engineers-title'}}
  frame.style.width = M.WIDTH
  if frame.force_auto_center then frame.force_auto_center() end
  local body = frame.add{type = 'flow', name = 'body', direction = 'vertical'}
  fixed(body.add{type = 'label', name = 'escort_title', style = 'caption_label',
    caption = {'tank-squads.engineers-escort'}, tooltip = {'tank-squads.engineers-escort-help'}})
  division_cells(body, 'pool', function(cell, n)
    cell.add{type = 'checkbox', name = 'pool_' .. n, state = false, caption = {'tank-squads.engineers-division', n},
      tags = {tank_squads_pool = n}}
  end)
  fixed(body.add{type = 'label', name = 'list_title', style = 'caption_label',
    caption = {'tank-squads.engineers-constructors'}})
  body.add{type = 'table', name = 'list', column_count = 4, tags = {}}
  fixed(body.add{type = 'label', name = 'ghosts', tags = {}})
  fixed(body.add{type = 'label', name = 'rings_title', style = 'caption_label',
    tooltip = {'tank-squads.engineers-rings-help'}, tags = {}})
  local settings = body.add{type = 'flow', name = 'ring_settings', direction = 'horizontal'}
  settings.style.vertical_align = 'center'
  local shape = settings.add{type = 'drop-down', name = 'ring_shape', selected_index = 1,
    items = {{'tank-squads.engineers-ring-square'}, {'tank-squads.engineers-ring-circle'}},
    tooltip = {'tank-squads.engineers-ring-shape-help'}, tags = {tank_squads_ring = 'shape'}}
  shape.style.width = 96
  for _, spec in ipairs({{'spacing', 56}, {'count', 40}}) do
    local field = settings.add{type = 'textfield', name = 'ring_' .. spec[1], numeric = true, allow_decimal = false,
      allow_negative = false, lose_focus_on_confirm = true, tooltip = {'tank-squads.engineers-ring-' .. spec[1] .. '-help'},
      tags = {tank_squads_ring = spec[1]}}
    field.style.width = spec[2]
  end
  settings.add{type = 'sprite-button', name = 'ring_centre', style = 'frame_action_button',
    sprite = 'item/tank-squad-ring-centre', tooltip = {'tank-squads.engineers-ring-centre-help'},
    tags = {tank_squads_ring = 'centre'}}
  body.add{type = 'table', name = 'ring_list', column_count = 5, tags = {}}
  fixed(body.add{type = 'label', name = 'garrison_title', style = 'caption_label',
    caption = {'tank-squads.engineers-garrison'}, tooltip = {'tank-squads.engineers-garrison-help'}})
  division_cells(body, 'garrison', function(cell, n)
    local drop = cell.add{type = 'drop-down', name = 'garrison_' .. n, selected_index = 1,
      items = {{'tank-squads.engineers-garrison-none'}}, tags = {tank_squads_garrison = n}}
    drop.style.width = 72
  end)
  body.add{type = 'button', name = 'close', caption = {'tank-squads.escort-close'},
    tags = {tank_squads_engineers = 'close'}}
  return frame
end

local function refresh_constructors(player, body)
  local s = state.peek()
  local rows = {}
  for _, r in pairs(s and s.constructors or {}) do
    if r.force_index == player.force_index then rows[#rows + 1] = r end
  end
  table.sort(rows, function(a, b) return a.id < b.id end)
  local parts = {}
  for _, r in ipairs(rows) do
    parts[#parts + 1] = r.id .. ':' .. r.state .. ':' .. teams.present(r.id) .. ':' .. tostring(r.autonomous)
  end
  local signature = table.concat(parts, ',')
  if body.list.tags.signature == signature then return end
  body.list.destroy()
  -- index keeps the list between its title and the ghost count.
  local list = body.add{type = 'table', name = 'list', column_count = 4, index = 4, tags = {signature = signature}}
  if #rows == 0 then fixed(list.add{type = 'label', name = 'none', caption = {'tank-squads.engineers-none'}}) end
  for _, r in ipairs(rows) do
    local short = M.SHORT[r.state] or 'idle'
    fixed(list.add{type = 'label', name = 'state_' .. r.id, caption = {'tank-squads.engineers-state-' .. short},
      tooltip = {'tank-squads.engineers-state-' .. short .. '-help'}})
    fixed(list.add{type = 'label', name = 'team_' .. r.id, caption = {'tank-squads.engineers-team', teams.present(r.id)}})
    list.add{type = 'checkbox', name = 'auto_' .. r.id, state = r.autonomous == true,
      caption = {'tank-squads.engineers-auto'}, tooltip = {'tank-squads.engineers-auto-help'},
      tags = {tank_squads_auto = r.id}}
    list.add{type = 'sprite-button', name = 'map_' .. r.id, style = 'frame_action_button', sprite = 'item/radar',
      tooltip = {'tank-squads.engineers-map'}, tags = {tank_squads_constructor = r.id}}
  end
end

local function ring_status(ring)
  if not ring then return {'tank-squads.engineers-ring-waiting'} end
  if ring.state == 'building' then return {'tank-squads.engineers-ring-building', rings.progress(ring)} end
  return {'tank-squads.engineers-ring-' .. M.RING_SHORT[ring.state]}
end

local function refresh_rings(player, body, fs, settings)
  local built = 0
  for _, ring in pairs(fs and fs.slots or {}) do
    if ring.state == 'built' then built = built + 1 end
  end
  local title = body.rings_title
  if title.tags.built ~= built then
    title.caption = {'tank-squads.engineers-rings', built}
    title.tags = {built = built}
  end
  local row = body.ring_settings
  local index = settings.shape == 'circle' and 2 or 1
  if row.ring_shape.selected_index ~= index then row.ring_shape.selected_index = index end
  -- A field is written only when its value changed, never while typing.
  for _, key in ipairs({'spacing', 'count'}) do
    local field = row['ring_' .. key]
    if field.tags.value ~= settings[key] then
      field.text = tostring(settings[key])
      field.tags = {tank_squads_ring = key, value = settings[key]}
    end
  end
  local parts = {}
  for n = 1, settings.count do
    local ring = fs and fs.slots[n]
    parts[#parts + 1] = n .. ':' .. (ring and (ring.state .. ':' .. rings.progress(ring) .. ':' .. count_of(ring.crossings))
      or '-') .. ':' .. tostring(armed(player.index, n))
  end
  local signature = table.concat(parts, ',')
  if body.ring_list.tags.signature == signature then return end
  body.ring_list.destroy()
  -- index keeps the list between the settings and the garrison title.
  local list = body.add{type = 'table', name = 'ring_list', column_count = 5, index = 8, tags = {signature = signature}}
  for n = 1, settings.count do
    local ring = fs and fs.slots[n]
    fixed(list.add{type = 'label', name = 'ring_' .. n, caption = {'tank-squads.engineers-ring', n}})
    fixed(list.add{type = 'label', name = 'status_' .. n, caption = ring_status(ring)})
    local open = ring and count_of(ring.crossings) or 0
    fixed(list.add{type = 'label', name = 'open_' .. n,
      caption = open > 0 and {'tank-squads.engineers-ring-crossings', open} or '',
      tooltip = open > 0 and {'tank-squads.engineers-ring-crossings-help'} or nil})
    list.add{type = 'sprite-button', name = 'ring_map_' .. n, style = 'frame_action_button', sprite = 'item/radar',
      tooltip = {'tank-squads.engineers-ring-map'}, enabled = ring ~= nil and ring.state ~= 'deleted',
      tags = {tank_squads_ring_map = n}}
    if ring and ring.state == 'deleted' then
      list.add{type = 'button', name = 'ring_again_' .. n, caption = {'tank-squads.engineers-ring-again'},
        tags = {tank_squads_ring_again = n}}
    elseif ring and (ring.state == 'building' or ring.state == 'built') then
      local confirm = armed(player.index, n)
      list.add{type = 'button', name = 'ring_delete_' .. n, style = confirm and 'red_button' or nil,
        caption = {confirm and 'tank-squads.engineers-ring-confirm' or 'tank-squads.engineers-ring-delete'},
        tooltip = {'tank-squads.engineers-ring-delete-help'}, tags = {tank_squads_ring_delete = n}}
    else
      fixed(list.add{type = 'label', name = 'ring_none_' .. n, caption = ''})
    end
  end
end

local function refresh_garrison(body, records, settings)
  local count = settings.count
  for n = 1, names.max_division do
    local cell = body.garrison['cell_' .. n]
    local record = records[n]
    local has = record ~= nil and #record.members > 0
    if cell.visible ~= has then cell.visible = has end
    local drop = cell['garrison_' .. n]
    if drop.tags.count ~= count then
      local items = {{'tank-squads.engineers-garrison-none'}}
      for k = 1, count do items[k + 1] = {'tank-squads.engineers-ring', k} end
      drop.items = items
      drop.tags = {tank_squads_garrison = n, count = count}
    end
    local key = has and record.mode == 'patrol' and record.patrol and record.patrol.garrison
    local ring = key and rings.by_key(key)
    local index = (ring and ring.n <= count) and ring.n + 1 or 1
    if drop.selected_index ~= index then drop.selected_index = index end
  end
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
  refresh_constructors(player, body)
  local count = ghosts.count(player.surface_index, player.force_index)
  if body.ghosts.tags.count ~= count then
    body.ghosts.caption = {'tank-squads.engineers-ghosts', count}
    body.ghosts.tags = {count = count}
  end
  local fs = rings.peek(player.force_index)
  local settings = fs and fs.settings or rings.DEFAULTS
  refresh_rings(player, body, fs, settings)
  refresh_garrison(body, records, settings)
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

-- The point of a ring nearest the player: a side's gatehouse, or a
-- circle's north, east, south or west.
local function ring_point(ring, from)
  local best, best_d
  for k = 1, 4 do
    local p = ring.shape == 'circle' and geometry.to_position(ring, 0, (k - 1) * geometry.TAU * ring.radius / 4, 0)
      or geometry.to_position(ring, k, 0, 0)
    local dx, dy = p.x - from.x, p.y - from.y
    local d = dx * dx + dy * dy
    if not best_d or d < best_d then best, best_d = p, d end
  end
  return best
end

-- Map buttons open the map at a constructor or a ring. The ring buttons
-- pick the centre, delete a ring (a second click confirms) or free a
-- deleted slot.
function M.click(event)
  local element = event.element
  if not (element and element.valid) then return false end
  local tags, player_index = element.tags, event.player_index
  local player = game.get_player(player_index)
  if tags.tank_squads_engineers == 'close' then
    M.close(player_index)
    return true
  end
  if not player then return false end
  if tags.tank_squads_ring == 'centre' then
    if player.clear_cursor() then player.cursor_stack.set_stack{name = 'tank-squad-ring-centre', count = 1} end
    return true
  end
  local fs = rings.peek(player.force_index)
  local n = tags.tank_squads_ring_map
  if n then
    local ring = fs and fs.slots[n]
    if ring and ring.state ~= 'deleted' then
      player.set_controller{type = defines.controllers.remote, position = ring_point(ring, player.position),
        surface = game.surfaces[ring.surface_index]}
    end
    return true
  end
  n = tags.tank_squads_ring_delete
  if n then
    local s = state.get()
    s.armed = s.armed or {}
    if armed(player_index, n) then
      s.armed[player_index] = nil
      rings.delete(player.force_index, n)
    else
      s.armed[player_index] = {n = n, tick = game.tick}
    end
    M.refresh(player_index)
    return true
  end
  n = tags.tank_squads_ring_again
  if n then
    rings.again(player.force_index, n)
    M.refresh(player_index)
    return true
  end
  local id = tags.tank_squads_constructor
  if not id then return false end
  local s = state.peek()
  local record = s and s.constructors[id]
  if record and record.entity.valid and record.force_index == player.force_index then
    player.set_controller{type = defines.controllers.remote, position = record.entity.position,
      surface = record.entity.surface}
  end
  return true
end

-- Escort checkboxes and the constructors' auto boxes.
function M.checked(event)
  local element = event.element
  if not (element and element.valid) then return false end
  local id = element.tags.tank_squads_auto
  if id then
    constructor.set_autonomous(id, element.state)
    M.refresh(event.player_index)
    return true
  end
  local n = element.tags.tank_squads_pool
  if type(n) ~= 'number' then return false end
  if not teams.set_pool(event.player_index, n, element.state) then element.state = false end
  M.refresh(event.player_index)
  return true
end

-- The ring shape and the garrison dropdowns. A refused garrison shows the
-- division's real ring again on the refresh.
function M.selected(event)
  local element = event.element
  if not (element and element.valid) then return false end
  local player = game.get_player(event.player_index)
  if not player then return false end
  local tags = element.tags
  if tags.tank_squads_ring == 'shape' then
    rings.set(player.force_index, 'shape', element.selected_index == 2 and 'circle' or 'square')
  elseif tags.tank_squads_garrison then
    local index = element.selected_index
    garrison.set(event.player_index, tags.tank_squads_garrison, index > 1 and index - 1 or nil)
  else
    return false
  end
  M.refresh(event.player_index)
  return true
end

-- The spacing and count fields, on Enter. The field shows the value kept.
function M.confirmed(event)
  local element = event.element
  if not (element and element.valid) then return false end
  local key = element.tags.tank_squads_ring
  if key ~= 'spacing' and key ~= 'count' then return false end
  local player = game.get_player(event.player_index)
  if not player then return false end
  local value = rings.set(player.force_index, key, element.text)
  element.text = tostring(value)
  element.tags = {tank_squads_ring = key, value = value}
  M.refresh(event.player_index)
  return true
end

return M
