-- The engineers feature: constructors, their escort teams and nest task
-- forces. The rest of the mod calls this module only, except the leaf
-- module loans.lua, which patrol, cover and commands read.
local state = require('scripts.engineers.state')
local ghosts = require('scripts.engineers.ghosts')
local constructor = require('scripts.engineers.constructor')
local teams = require('scripts.engineers.teams')
local task_force = require('scripts.engineers.task_force')
local loans = require('scripts.engineers.loans')
local window = require('scripts.engineers.window')
local rings = require('scripts.engineers.rings.rings')
local names = require('scripts.names')

local M = {}

M.register = constructor.register
M.deploy = constructor.deploy
M.count = constructor.count
M.set_autonomous = constructor.set_autonomous
M.on_ghost = ghosts.add
M.set_pool = teams.set_pool
M.toggle_window = window.toggle
M.close_window = window.close
M.click = window.click
M.checked = window.checked
M.refresh_windows = window.refresh_all

-- Once per second. Without the engineers state this is one table check.
-- Open windows refresh; a player with constructors but no division still
-- gets the panel (and its engineers button) through update_panel.
function M.slow_sweep(update_panel)
  local s = state.peek()
  if not s then return end
  window.refresh_all()
  if not next(s.constructors) then
    -- The last constructor is gone: panels are judged once more.
    if s.shown then
      s.shown = nil
      for _, player in pairs(game.connected_players) do update_panel(player.index) end
    end
    return
  end
  s.shown = true
  for _, player in pairs(game.connected_players) do
    if not (storage.divisions and storage.divisions[player.index]) and constructor.count(player.force_index) > 0 then
      update_panel(player.index)
    end
  end
end

-- The last constructor gone lets its team go at once.
function M.unregister(unit_number)
  constructor.unregister(unit_number)
  teams.refresh()
end

-- A wall or gate that died left a ghost when the force keeps ghosts of
-- destroyed buildings; a ring wall is rebuilt either way.
function M.on_post_died(event)
  local ghost = event.ghost
  if ghost and ghost.valid then ghosts.add(ghost) end
  rings.on_wall_died(event)
end

M.on_wall_mined = rings.on_wall_mined

-- Runs before divisions.forget, while the loan still names the lender.
function M.forget_soldier(entity)
  task_force.on_soldier_died(entity)
  loans.finish(entity.unit_number)
  teams.forget(entity.unit_number)
end

function M.on_command_completed(unit_number, result)
  if constructor.on_command_completed(unit_number, result) then return true end
  if task_force.on_command_completed(unit_number, result) then return true end
  return teams.on_command_completed(unit_number, result)
end

-- One sweep slice (every slice when phase is nil). Without the engineers
-- state this is a single table check. Teams left by a constructor that
-- vanished without an event are dissolved by the next refresh.
function M.tick(phase)
  local s = state.peek()
  if not s then return end
  if next(s.constructors) or next(s.teams) then
    if phase == nil or phase == 0 then teams.refresh() end
    constructor.tick(phase)
    teams.tick(phase)
  end
  task_force.tick(phase)
  if s.rings and next(s.rings) then rings.tick(phase) end
end

function M.on_forces_merged(event)
  local s = state.peek()
  if not s then return end
  local from, to = event.source_index, event.destination.index
  for _, record in pairs(s.constructors) do
    if record.force_index == from then record.force_index = to end
  end
  for _, tf in pairs(s.task_forces) do
    if tf.force_index == from then tf.force_index = to end
  end
  M.reconcile()
end

-- After an upgrade or a force merge: every constructor lets go of its
-- claims and every visited surface is read again.
function M.reconcile()
  for _, surface in pairs(game.surfaces) do
    for _, entity in pairs(surface.find_entities_filtered{name = names.constructor}) do constructor.register(entity) end
  end
  local s = state.peek()
  if not s then return end
  for _, record in pairs(s.constructors) do
    if record.entity.valid and record.state ~= 'healing' and record.state ~= 'task_force' then
      constructor.reset(record)
    end
  end
  s.ghosts, s.scanned, s.claims, s.dirty = {}, {}, {}, true
  for _, record in pairs(s.constructors) do
    if record.entity.valid then ghosts.scan(record.entity.surface) end
  end
end

function M.set_min_team(value)
  state.get().min_team = value
  return value
end

function M.describe(unit_number)
  local s = state.peek()
  local record = s and s.constructors[unit_number]
  if not record then return nil end
  return {state = record.state, team = teams.present(unit_number), cluster = record.cluster and #record.cluster or 0}
end

function M.build_now(unit_number)
  local s = state.peek()
  local record = s and s.constructors[unit_number]
  if not (record and record.entity.valid) then return 0 end
  return constructor.build_now(record)
end

-- Engine tests: ring settings, the centre, planning one segment and a
-- summary of a ring.
function M.ring_set(force_index, name, value)
  return rings.set(force_index, name, value)
end

function M.ring_centre(force, surface, position)
  return rings.set_centre(force, surface, position)
end

function M.ring_plan(force, n, i)
  local fs = rings.force_state(force.index)
  ghosts.scan(game.surfaces[fs.settings.surface_index or 1])
  local ring = fs.slots[n] or rings.start(fs, force, n, game.surfaces[fs.settings.surface_index or 1])
  return rings.plan_segment(ring, i), ring.segments[i].live
end

function M.ring_info(force_index, n)
  local fs = rings.peek(force_index)
  local ring = fs and fs.slots[n]
  if not ring then return nil end
  local live, built, released, crossings = 0, 0, 0, 0
  for _, seg in ipairs(ring.segments) do
    live = live + seg.live
    if seg.state == 'built' then built = built + 1 end
  end
  for _ in pairs(ring.released) do released = released + 1 end
  for _ in pairs(ring.crossings) do crossings = crossings + 1 end
  return {state = ring.state, radius = ring.radius, count = ring.count, built = built, live = live,
    released = released, bulges = #ring.bulges, crossings = crossings}
end

function M.ring_delete(force_index, n) return rings.delete(force_index, n) end
function M.ring_again(force_index, n) return rings.again(force_index, n) end
function M.ring_tick() rings.tick(nil) end

return M
