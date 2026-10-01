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
local combat = require('scripts.combat')
local crossing = require('scripts.engineers.rings.crossing')
local make_way = require('scripts.engineers.make_way')
local patrol = require('scripts.patrol')
local garrison = require('scripts.engineers.rings.garrison')
local clearing = require('scripts.engineers.rings.clearing')
local names = require('scripts.names')
local shredders = require('scripts.shredders')

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
M.selected = window.selected
M.confirmed = window.confirmed
M.refresh_windows = window.refresh_all
combat.crossing = crossing.route
shredders.keep_off = make_way.off_band
patrol.garrison_layout = garrison.layout
M.garrison_set = garrison.set
M.garrison_active = garrison.active
M.on_wall_damaged = garrison.on_wall_damaged

-- control.lua switches the damage filter when garrisons come or go.
function M.on_garrison_change(fn)
  garrison.on_change = fn
end
-- First on every finished unit order. A soldier walled in on a ring's band
-- whose order failed is moved off the band; its order's owner still hears
-- of the failure. A unit crossing a ring hears back at each gatehouse step.
function M.on_crossing_completed(unit_number, result)
  make_way.escape(unit_number, result)
  return crossing.on_command_completed(unit_number, result)
end

-- Once per second. Without the engineers state this is one table check.
function M.has_rings(force_index)
  local fs = rings.peek(force_index)
  return fs ~= nil and next(fs.slots) ~= nil
end

-- The ring centre tool was used: the middle of the selected area.
function M.pick_centre(event)
  local player = game.get_player(event.player_index)
  if not player then return end
  local a = event.area
  rings.set_centre(player.force, event.surface,
    {x = (a.left_top.x + a.right_bottom.x) / 2, y = (a.left_top.y + a.right_bottom.y) / 2})
  player.clear_cursor()
  window.refresh(event.player_index)
end

-- Open windows refresh; a player with constructors but no division still
-- gets the panel (and its engineers button) through update_panel.
function M.slow_sweep(update_panel)
  local s = state.peek()
  if not s then return end
  window.refresh_all()
  if not next(s.constructors) and not (s.rings and next(s.rings)) then
    -- The last constructor and ring are gone: panels are judged once more.
    if s.shown then
      s.shown = nil
      for _, player in pairs(game.connected_players) do update_panel(player.index) end
    end
    return
  end
  s.shown = true
  for _, player in pairs(game.connected_players) do
    if not (storage.divisions and storage.divisions[player.index]) and (constructor.count(player.force_index) > 0 or M.has_rings(player.force_index)) then
      update_panel(player.index)
    end
  end
end

-- The last constructor gone lets its team go at once.
function M.unregister(unit_number)
  constructor.unregister(unit_number)
  crossing.forget(unit_number)
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
  crossing.forget(entity.unit_number)
end

-- A soldier rebuilt on promotion keeps its loan. True when it was lent.
M.replace_soldier = task_force.replace

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
  if s.rings and next(s.rings) then
    rings.tick(phase)
    garrison.tick(phase)
    clearing.tick(phase)
  end
  if s.crossings and (phase == nil or phase == 0) then crossing.sweep() end
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
  rings.release_force(from)
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
    -- Constructors from older versions have no map icon, and a merged
    -- force's icon shows only to the force that is gone.
    if record.entity.valid then constructor.mark(record) end
  end
  s.ghosts, s.scanned, s.claims, s.dirty = {}, {}, {}, true
  for _, record in pairs(s.constructors) do
    if record.entity.valid then ghosts.scan(record.entity.surface) end
  end
  -- Ring labels from older versions are drawn at an older size, and a ring
  -- being torn down lost its labels when it was deleted. Gates of older
  -- versions stand crosswise to the wall line, in one row instead of three.
  -- Rings built before crossings have no gatehouses recorded.
  for force_index, fs in pairs(s.rings or {}) do
    local force = game.forces[force_index]
    for _, ring in pairs(fs.slots) do
      local surface = game.surfaces[ring.surface_index]
      if force and surface and (ring.state == 'building' or ring.state == 'built') then
        rings.draw_labels(ring, force, surface)
        rings.turn_gates(ring)
        rings.widen_gates(ring)
        crossing.record_built(ring)
      else
        rings.clear_labels(ring)
      end
    end
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

function M.ring_plan(force, n, i, first_batch)
  local fs = rings.force_state(force.index)
  ghosts.scan(game.surfaces[fs.settings.surface_index or 1])
  local ring = fs.slots[n] or rings.start(fs, force, n, game.surfaces[fs.settings.surface_index or 1])
  local result = rings.plan_segment(ring, i)
  -- The test places the whole segment at once, unless it times the
  -- planning tick alone.
  if not first_batch then rings.place_pending(ring, i, math.huge) end
  return result, ring.segments[i].live
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

-- Engine tests: drops the force's rings with their map labels, centre mark
-- and crossing tags, so a case leaves nothing on the test map.
function M.ring_reset(force)
  local fs = rings.peek(force.index)
  if not fs then return end
  for _, ring in pairs(fs.slots) do
    rings.clear_labels(ring)
    rings.clear_crossings(ring)
  end
  if fs.mark and fs.mark.valid then fs.mark.destroy() end
  if fs.mark_circle and fs.mark_circle.valid then fs.mark_circle.destroy() end
  storage.engineers.rings[force.index] = nil
end
function M.ring_again(force_index, n) return rings.again(force_index, n) end

-- Engine tests: the upgrade of older gates. Returns gates turned and gate
-- ghosts added.
function M.ring_fix_gates(force_index)
  local fs = rings.peek(force_index)
  local turned, added = 0, 0
  for _, ring in pairs(fs and fs.slots or {}) do
    turned = turned + rings.turn_gates(ring)
    added = added + rings.widen_gates(ring)
  end
  return {turned = turned, added = added}
end
function M.ring_tick() rings.tick(nil) end
function M.clearing_tick() clearing.tick(nil) end

return M
