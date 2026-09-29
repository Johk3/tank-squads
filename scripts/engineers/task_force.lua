-- Nest task force. When a nest blocks a constructor's ghosts, soldiers are
-- borrowed from nearby divisions that can spare them: all of an idle or
-- parked division, the surplus of a patrol, and soldiers in no division.
-- They run the usual nest assault, call their divisions' shredders on heavy
-- losses, and go back to their jobs when the nest falls or the task force
-- breaks off. A lending division given a new order takes its soldiers back
-- at once. Runs in the sweep slice of its id.
--
-- task force = {id, surface_index, force_index, origin, structures,
--   members, strength, lenders, waiting, started, assault, targets,
--   window, called}
--   lenders[player_index .. ':' .. n] = {player_index, n, job}, where job
--     is the division's mode, order and patrol when it lent
--   waiting[constructor unit_number] = true for constructors it serves
local names = require('scripts.names')
local combat = require('scripts.combat')
local divisions = require('scripts.divisions')
local assault = require('scripts.assault')
local retreat = require('scripts.retreat')
local cover = require('scripts.cover')
local shredders = require('scripts.shredders')
local patrol_geometry = require('scripts.patrol_geometry')
local loans = require('scripts.engineers.loans')
local threat = require('scripts.engineers.threat')
local state = require('scripts.engineers.state')

local M = {}

M.REACH = 300
-- A constructor blocked by a nest a task force already fights waits for it.
M.JOIN_RADIUS = 40
M.WINDOW = 30 * 60
-- Where a waiting constructor stands: beyond the staging arc when an
-- assault runs, else this far from the nest.
M.STAGING = 60
M.STAGING_MARGIN = 10
M.TIMEOUT = 10 * 3600

local function distance2(a, b)
  local dx, dy = a.x - b.x, a.y - b.y
  return dx * dx + dy * dy
end

local function strength_of(e)
  local veteran = storage.veterans and storage.veterans[e.unit_number]
  return threat.strength(e.name, veteran and veteran.rank)
end

-- An armed soldier no task force, cover or engineer team holds.
local function free(s, e)
  local id = e.unit_number
  return e.valid and names.soldier_set[e.name] ~= nil and not loans.on_loan(id) and not cover.held(id)
    and not s.team_of[id]
end

-- An idle division runs no nest assault and no attack order. One parked
-- after a move order is idle.
local function idle(record)
  if record.mode ~= 'idle' then return false end
  local order = record.order
  if not order then return true end
  return not (order.assault or (order.command and order.command.type == defines.command.attack_area))
end

local function job(record)
  return {mode = record.mode, order = record.order, patrol = record.patrol}
end

local function same_job(record, j)
  return record ~= nil and record.mode == j.mode and record.order == j.order and record.patrol == j.patrol
end

function M.candidates(force_index, surface, origin)
  local s = state.get()
  local reach2, out = M.REACH * M.REACH, {}
  local function add(e, player_index, n, record)
    local d = distance2(e.position, origin)
    if d <= reach2 then
      out[#out + 1] = {id = e.unit_number, entity = e, strength = strength_of(e), d = d,
        player_index = player_index, n = n, record = record}
    end
  end
  for player_index, pstate in pairs(storage.divisions or {}) do
    local player = game.get_player(player_index)
    if player and player.force_index == force_index then
      for n = 1, names.max_division do
        local record = pstate.slots[n]
        if record and #record.members > 0 then
          if idle(record) then
            for _, e in ipairs(divisions.cached(player_index, n)) do
              if e.valid and e.surface_index == surface.index and free(s, e) then add(e, player_index, n, record) end
            end
          elseif record.mode == 'patrol' and record.patrol and record.patrol.posts then
            local r, here = record.patrol, {}
            for _, e in ipairs(divisions.cached(player_index, n)) do
              if e.valid and e.surface_index == surface.index and free(s, e) and not retreat.is_away(r, e.unit_number) then
                here[#here + 1] = {id = e.unit_number, entity = e, strength = strength_of(e)}
              end
            end
            local length = patrol_geometry.length(r.waypoints, patrol_geometry.area(r.waypoints) > 0)
            for _, x in ipairs(threat.surplus(here, threat.patrol_keep(length))) do
              add(x.entity, player_index, n, record)
            end
          end
        end
      end
    end
  end
  for _, e in pairs(surface.find_entities_filtered{position = origin, radius = M.REACH, name = names.soldier_names,
      force = force_index}) do
    if not divisions.owner(e.unit_number) and free(s, e) then add(e, nil, nil, nil) end
  end
  return out
end

-- The nest's spawner nearest the cluster, else its nearest worm.
local function origin_of(structures, centre)
  local best, best_d, best_spawner
  for _, e in ipairs(structures) do
    if e.valid then
      local d, spawner = distance2(e.position, centre), e.type == 'unit-spawner'
      if not best or (spawner and not best_spawner) or (spawner == best_spawner and d < best_d) then
        best, best_d, best_spawner = e, d, spawner
      end
    end
  end
  return best and {x = best.position.x, y = best.position.y}
end

local function alive(tf)
  local out = {}
  for _, e in ipairs(tf.structures) do
    if e.valid then out[#out + 1] = e end
  end
  return out
end

-- Without a spawner there is no staged assault: each soldier attacks the
-- nearest living structure.
local function attack(tf, members)
  local targets = alive(tf)
  if #targets == 0 then return end
  tf.targets = tf.targets or {}
  for _, e in ipairs(members) do
    local target = tf.targets[e.unit_number]
    if not (target and target.valid) then
      local best, best_d
      for _, t in ipairs(targets) do
        local d = distance2(t.position, e.position)
        if not best_d or d < best_d then best, best_d = t, d end
      end
      tf.targets[e.unit_number] = best
      combat.set_command(e, {type = defines.command.attack, target = best, distraction = defines.distraction.by_enemy})
    end
  end
end

local function announce(tf, key)
  local by_player = {}
  for _, lender in pairs(tf.lenders) do
    local list = by_player[lender.player_index] or {}
    by_player[lender.player_index] = list
    list[#list + 1] = lender.n
  end
  for player_index, list in pairs(by_player) do
    local player = game.get_player(player_index)
    if player then
      table.sort(list)
      player.print({'tank-squads.' .. key, table.concat(list, ', ')})
    end
  end
end

function M.near(surface_index, position)
  local s = state.peek()
  local r2 = M.JOIN_RADIUS * M.JOIN_RADIUS
  for _, tf in pairs(s and s.task_forces or {}) do
    if tf.surface_index == surface_index and distance2(tf.origin, position) <= r2 then return tf end
  end
  return nil
end

-- Starts a task force against the nest of `structures`, or joins the one
-- already fighting it. Returns nil when the lenders in reach are too weak.
function M.request(record, structures)
  local s = state.get()
  local entity = record.entity
  local origin = origin_of(structures, record.centre or entity.position)
  if not origin then return nil end
  local running = M.near(record.surface_index, origin)
  if running then
    running.waiting[record.id] = true
    return running
  end
  local summaries = {}
  for _, e in ipairs(structures) do
    if e.valid then summaries[#summaries + 1] = {name = e.name, type = e.type, max_health = e.max_health} end
  end
  local picked, total = threat.pick(M.candidates(record.force_index, entity.surface, origin),
    threat.needed(threat.nest(summaries)))
  if not picked then return nil end
  s.next_task_force = s.next_task_force + 1
  local tf = {id = s.next_task_force, surface_index = record.surface_index, force_index = record.force_index,
    origin = origin, structures = structures, members = {}, strength = total, lenders = {},
    waiting = {[record.id] = true}, started = game.tick}
  local entities = {}
  for _, c in ipairs(picked) do
    local p = c.entity.position
    loans.lend(c.id, {task_force = tf.id, player_index = c.player_index, n = c.n, back = {x = p.x, y = p.y}})
    tf.members[#tf.members + 1] = c.id
    entities[#entities + 1] = c.entity
    if c.record then
      local key = c.player_index .. ':' .. c.n
      if not tf.lenders[key] then tf.lenders[key] = {player_index = c.player_index, n = c.n, job = job(c.record)} end
      -- The patrol deals its posts again without the lent soldiers.
      if c.record.mode == 'patrol' then c.record.patrol.dirty = true end
    end
  end
  s.task_forces[tf.id] = tf
  if not assault.start(tf, entities, origin, assault.enemy_forces(entity.force), true) then attack(tf, entities) end
  announce(tf, 'task-force-sent')
  return tf
end

function M.staging(tf, from)
  local distance = tf.assault and tf.assault.standoff + M.STAGING_MARGIN or M.STAGING
  local dx, dy = from.x - tf.origin.x, from.y - tf.origin.y
  local length = math.sqrt(dx * dx + dy * dy)
  if length >= distance then return {x = from.x, y = from.y} end
  if length < 1e-6 then dx, dy, length = 0, 1, 1 end
  return {x = tf.origin.x + dx / length * distance, y = tf.origin.y + dy / length * distance}
end

-- A lender whose job changed took its soldiers back; they already follow
-- the new job. The soldiers of a lender that no longer exists stay, and
-- return to their back point when the task force ends.
local function recall_changed(tf)
  for key, lender in pairs(tf.lenders) do
    local pstate = storage.divisions and storage.divisions[lender.player_index]
    local record = pstate and pstate.slots[lender.n]
    if record and not same_job(record, lender.job) then
      for _, id in ipairs(tf.members) do
        local loan = loans.get(id)
        if loan and loan.player_index == lender.player_index and loan.n == lender.n then loans.finish(id) end
      end
      if record and record.mode == 'patrol' and record.patrol then record.patrol.dirty = true end
      tf.lenders[key] = nil
    end
  end
end

-- The members still lent to this task force, alive.
local function members_of(tf)
  local out, kept = {}, {}
  for _, id in ipairs(tf.members) do
    local loan = loans.get(id)
    local e = loan and loan.task_force == tf.id and game.get_entity_by_unit_number(id)
    if e and e.valid then
      out[#out + 1] = e
      kept[#kept + 1] = id
    end
  end
  tf.members = kept
  return out
end

function M.finish(tf, outcome)
  local s = state.get()
  for _, id in ipairs(tf.members) do
    local loan = loans.finish(id)
    local e = game.get_entity_by_unit_number(id)
    if loan and e and e.valid then
      local pstate = loan.player_index and storage.divisions and storage.divisions[loan.player_index]
      local record = pstate and pstate.slots[loan.n]
      if record and record.mode == 'patrol' and record.patrol then
        -- The patrol deals it a post on its next sweep.
        record.patrol.dirty = true
      else
        combat.set_command(e, {type = defines.command.go_to_location, destination = loan.back, radius = 4,
          distraction = defines.distraction.by_enemy})
      end
    end
  end
  for id in pairs(tf.waiting) do
    local record = s.constructors[id]
    if record and record.task_force == tf.id then record.task_force_result = outcome end
  end
  s.task_forces[tf.id] = nil
  announce(tf, 'task-force-' .. outcome)
end

function M.drive(tf)
  recall_changed(tf)
  local members = members_of(tf)
  if #alive(tf) == 0 then return M.finish(tf, 'cleared') end
  local strength = 0
  for _, e in ipairs(members) do strength = strength + strength_of(e) end
  if #members == 0 or strength * 2 < tf.strength or game.tick - tf.started > M.TIMEOUT then
    return M.finish(tf, 'broken')
  end
  if tf.assault then
    local result = assault.tick(tf.assault, members)
    if result == 'failed' then return M.finish(tf, 'broken') end
    -- The assault covers the structures around its spawner; worms beyond
    -- them are attacked one by one afterwards.
    if result == 'done' then tf.assault = nil end
  else
    attack(tf, members)
  end
end

function M.tick(phase)
  local s = state.peek()
  if not (s and next(s.task_forces)) then return end
  local ids = {}
  for id in pairs(s.task_forces) do
    if phase == nil or id % divisions.PHASES == phase then ids[#ids + 1] = id end
  end
  table.sort(ids)
  for _, id in ipairs(ids) do
    local tf = s.task_forces[id]
    if tf then M.drive(tf) end
  end
end

function M.on_command_completed(unit_number, result)
  local loan = loans.get(unit_number)
  if not loan then return false end
  local s = state.peek()
  local tf = s and s.task_forces[loan.task_force]
  if tf and tf.assault then
    assault.on_command_completed(tf.assault, unit_number, result)
  elseif tf and tf.targets then
    tf.targets[unit_number] = nil
  end
  return true
end

-- Runs before the soldier's loan ends. Half the task force lost within the
-- window, or its last soldier, calls the shredders of every lender.
function M.on_soldier_died(entity)
  local loan = loans.get(entity.unit_number)
  local s = state.peek()
  local tf = loan and s and s.task_forces[loan.task_force]
  if not tf then return end
  local tick = game.tick
  local window = tf.window
  if not window or tick - window.start > M.WINDOW then
    window = {start = tick, size = #tf.members, losses = 0}
    tf.window = window
  end
  window.losses = window.losses + 1
  if window.losses * 2 < window.size and #tf.members > 1 then return end
  if tf.called and tick - tf.called < M.WINDOW then return end
  tf.called = tick
  for _, lender in pairs(tf.lenders) do
    shredders.call(lender.player_index, lender.n, entity.surface, entity.position, entity.force)
  end
end

return M
