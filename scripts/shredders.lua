-- Shredders: unmanned rammers that support divisions on their own.
--
-- storage.shredders = {
--   units[unit_number] = record (see M.register)
--   groups[player_index .. ':' .. n] = the shredders of one operational
--     division: {key, player_index, n, force_index, surface_index, members,
--     point, ordered, home, window, updated}
--   shadows[player_index] = shredders following a player in danger:
--     {members, surface_index, force_index, point, ordered, calm_since, spent}
--   locks[target unit_number] = shredders aimed at it
--   doomed[unit_number] = true for crashed shredders the next slice removes
--   present[force_index .. ':' .. surface_index] = true where shredders are
--   dirty = true when a shredder or group came, went or changed hands, so
--     the next split has work to do
--   stranded[unit_number] = true for charging units still to swap back to
--     parked ones: a swap that failed, or a charger found without a charge
-- }
-- Everything runs from events and the existing sweep slices; a parked
-- shredder costs nothing until its division moves.
local names = require('scripts.names')
local divisions = require('scripts.divisions')
local geometry = require('scripts.shredder_geometry')
local appearance = require('scripts.appearance')

local M = {}

M.PARKED, M.CHARGING = names.shredder, names.shredder_charging
M.EFFECT = 'tank-squad-shredder-impact'
M.REBALANCE_PHASE = 5
M.DRIFT = 20
-- A group its division slice has not refreshed for this long lost its slot.
M.STALE = 120
local READY = {parked = true, moving = true}
M.WINDOW = 30 * 60
M.STRIKE_RADIUS, M.TARGET_LIMIT = 40, 50
M.IGNITION = 20
M.BREAKUP_TICKS = 8
-- A charge gives up after this many targets it could not reach, so it
-- never circles a fight across water or cliffs.
M.RETARGETS = 5
local TARGETS = {'unit', 'unit-spawner', 'turret'}
local LOOK = appearance.shredder
M.DANGER_UNITS, M.DANGER_RADIUS, M.NEST_RADIUS = 10, 40, 50
M.SHADOW_SIZE, M.SHADOW_REACH, M.SHADOW_BACK, M.SHADOW_STRIKE, M.SHADOW_DRIFT = 3, 200, 40, 30, 15
M.CALM = 10 * 60
local NESTS = {'unit-spawner', 'turret'}
local PLAYER_TYPES = {character = true, car = true, ['spider-vehicle'] = true}

function M.state()
  local s = storage.shredders
  if not s then
    s = {units = {}, groups = {}, shadows = {}, locks = {}, doomed = {}, present = {}, dirty = true,
      stranded = {}}
    storage.shredders = s
  end
  return s
end

local function remove(list, id)
  for i = #list, 1, -1 do
    if list[i] == id then table.remove(list, i); return true end
  end
  return false
end

-- Takes the shredder out of its group or shadow.
local function leave(record)
  local s = M.state()
  s.dirty = true
  if record.group then
    local group = s.groups[record.group]
    if group then remove(group.members, record.id) end
    record.group = nil
  end
  if record.shadow then
    local shadow = s.shadows[record.shadow]
    if shadow then remove(shadow.members, record.id) end
    record.shadow = nil
  end
end

local function unlock(record)
  if record.lock_id then
    local locks = M.state().locks
    local n = (locks[record.lock_id] or 1) - 1
    locks[record.lock_id] = n > 0 and n or nil
  end
  record.target, record.lock_id = nil, nil
end

local function clear_renders(record)
  for key, object in pairs(record.renders) do
    if object.valid then object.destroy() end
    record.renders[key] = nil
  end
end

-- A shredder destroyed without an event keeps its record until the next
-- split, so orders check the entity first.
local function send(record, position)
  if not record.entity.valid then return end
  record.state = 'moving'
  record.entity.commandable.set_command{type = defines.command.go_to_location, destination = position,
    radius = 2, distraction = defines.distraction.none}
end

local function park(record)
  if not record.entity.valid then return end
  record.state = 'parked'
  record.entity.commandable.set_command{type = defines.command.stop, distraction = defines.distraction.none}
end

local function enemies_of(force)
  local out = {}
  for _, other in pairs(game.forces) do
    if other ~= force and force.is_enemy(other) then out[#out + 1] = other end
  end
  return out
end

local function lock(record, target)
  unlock(record)
  record.target, record.target_position = target, target.position
  record.lock_id = target.unit_number
  if record.lock_id then
    local locks = M.state().locks
    locks[record.lock_id] = (locks[record.lock_id] or 0) + 1
  end
end

-- Rendering uses the absolute tick; the offset starts each drawing on its
-- first frame, as the barracks door does.
local function draw(record, key, args, speed)
  local old = record.renders[key]
  if old and old.valid then old.destroy() end
  args.animation_speed, args.animation_offset = speed, -game.tick * speed
  record.renders[key] = rendering.draw_animation(args)
end

-- The charge sheet rides on the invisible charging unit, turned toward the
-- target; the reticle sits on the target for the shredder's force only.
local function draw_body(record, animation, offset, speed)
  local entity = record.entity
  draw(record, 'body', {animation = animation, target = entity, surface = entity.surface,
    orientation_target = record.target, oriented_offset = {0, offset}, render_layer = 'object'}, speed)
end

local function draw_lock(record)
  local target = record.target
  draw(record, 'lock', {animation = 'tank-squad-shredder-lock', target = target, surface = target.surface,
    render_layer = 'higher-object-above', forces = {record.entity.force}}, 0.5)
end

-- Replaces the entity with the other shredder prototype in place. The
-- record follows the new unit number, in its group or shadow too.
local function swap(record, name)
  local old = record.entity
  if old.name == name then return old end
  local s = M.state()
  local new = old.surface.create_entity{name = name, position = old.position, force = old.force}
  if not new then return nil end
  new.health = old.health / old.max_health * new.max_health
  old.destroy()
  local old_id = record.id
  s.units[old_id], s.doomed[old_id] = nil, nil
  record.entity, record.id = new, new.unit_number
  s.units[record.id] = record
  local holder = (record.group and s.groups[record.group]) or (record.shadow and s.shadows[record.shadow])
  if holder then
    for i, id in ipairs(holder.members) do if id == old_id then holder.members[i] = record.id end end
  end
  return new
end

-- record = {entity, id, force_index, surface_index, state, group, shadow, home_position, homeward,
--   target, target_position, lock_id, renders}. state is 'parked',
-- 'moving', 'igniting', 'charging', 'stranded' or 'spent'.
function M.register(entity)
  if not (entity and entity.valid and names.shredder_set[entity.name]) then return nil end
  local s = M.state()
  local record = s.units[entity.unit_number]
  if record then return record end
  -- Force and surface are kept on the record, so the split reads no entity
  -- of a settled army. A shredder teleported to another surface by another
  -- mod keeps its old split until it registers again.
  record = {entity = entity, id = entity.unit_number, state = 'moving', renders = {},
    force_index = entity.force_index, surface_index = entity.surface_index}
  s.units[record.id] = record
  s.dirty = true
  -- A charger cloned or found on an upgrade has no charge left to finish.
  if entity.name == M.CHARGING then
    record.state = 'stranded'
    s.stranded = s.stranded or {}
    s.stranded[record.id] = true
  end
  return record
end

function M.unregister(unit_number)
  local s = storage.shredders
  local record = s and s.units[unit_number]
  if not record then return end
  leave(record)
  unlock(record)
  clear_renders(record)
  s.units[unit_number] = nil
  s.doomed[unit_number] = nil
  if s.stranded then s.stranded[unit_number] = nil end
  s.dirty = true
end

-- A finished shredder leaves the barracks door. Returns false when there is
-- no room, so the recruit waits in the machine like a soldier's.
function M.deploy(barracks_entity, rally)
  local surface, p = barracks_entity.surface, barracks_entity.position
  local position = surface.find_non_colliding_position(M.PARKED, {x = p.x, y = p.y + 2.5}, 16, 1)
  if not position then return false end
  local entity = surface.create_entity{name = M.PARKED, position = position, force = barracks_entity.force}
  if not entity then return false end
  local record = M.register(entity)
  record.home_position = rally and {x = rally.x, y = rally.y} or {x = p.x, y = p.y}
  return true
end








-- Nearest own barracks or headquarters on the surface, or nil.
function M.home(surface_index, force_index, position)
  local best, best_d
  local function consider(entity)
    if entity and entity.valid and entity.surface_index == surface_index and entity.force_index == force_index then
      local d = geometry.distance2(entity.position, position)
      if not best_d or d < best_d then best, best_d = entity, d end
    end
  end
  for _, b in ipairs(storage.barracks or {}) do consider(b.entity) end
  for _, r in pairs(storage.headquarters or {}) do consider(r.entity) end
  return best
end

-- Sends the group's ready shredders to their slots around its backline.
function M.post(group)
  group.ordered = group.point
  local units = M.state().units
  for i, id in ipairs(group.members) do
    local record = units[id]
    if record and READY[record.state] then send(record, geometry.slot(group.point, i)) end
  end
end

function M.drop_group(key)
  local s = M.state()
  local group = s.groups[key]
  if not group then return end
  for _, id in ipairs(group.members) do
    local record = s.units[id]
    if record then record.group = nil end
  end
  s.groups[key] = nil
  s.dirty = true
end

-- Runs in the division's own slice, right after the roster refresh, so it
-- reuses the cached members. A division counts when it has an armed
-- soldier. A division may span surfaces: its group stays on its surface
-- while an armed soldier is there, else moves to the first armed soldier's.
function M.update_group(player_index, n)
  local s = M.state()
  local key = player_index .. ':' .. n
  local player = game.get_player(player_index)
  local members = player and divisions.cached(player_index, n) or {}
  local old = s.groups[key] and s.groups[key].surface_index
  local surface_index
  for _, e in ipairs(members) do
    if names.soldier_set[e.name] then
      if e.surface_index == old then surface_index = old; break end
      surface_index = surface_index or e.surface_index
    end
  end
  if not surface_index then M.drop_group(key); return end
  local here = {}
  for _, e in ipairs(members) do if e.surface_index == surface_index then here[#here + 1] = e end end
  local centre = geometry.centre(here)
  local group = s.groups[key]
  if not group then
    group = {key = key, player_index = player_index, n = n, members = {}}
    s.groups[key] = group
    s.dirty = true
  end
  if group.surface_index ~= surface_index or group.force_index ~= player.force.index then
    -- Its shredders stay behind on the old surface; the split sorts them out.
    group.ordered = nil
    s.dirty = true
  end
  group.force_index, group.surface_index, group.updated = player.force.index, surface_index, game.tick
  local home = group.home
  if not (home and home.valid and home.surface_index == surface_index) then
    home = M.home(surface_index, group.force_index, centre)
    group.home = home
  end
  local enemy
  if not home then
    enemy = here[1].surface.find_nearest_enemy{position = centre, max_distance = 100, force = player.force}
  end
  group.point = geometry.backline(centre, home and home.position, enemy and enemy.position)
  if not group.ordered or geometry.distance2(group.ordered, group.point) > M.DRIFT * M.DRIFT then
    M.post(group)
  end
end

-- Pooled shredders with no division to serve wait at their rally point.
local function go_home(record)
  if record.homeward or not record.home_position then return end
  send(record, record.home_position)
  record.homeward = true
end

-- The split reads a shredder's position only when it may move it: in the
-- pool, or in a group over its share.
local LAZY = {__index = function(item, key)
  if key ~= 'position' then return nil end
  local position = item.entity.position
  rawset(item, 'position', position)
  return position
end}

-- The even split, per force and surface. Reads only group records the
-- division slices keep current, so it walks no roster, and runs only after
-- a shredder or group came, went or changed hands: a parked army costs
-- nothing here.
function M.rebalance()
  local s = M.state()
  local tick = game.tick
  local keys = {}
  for key, group in pairs(s.groups) do
    if tick - (group.updated or 0) > M.STALE then keys[#keys + 1] = key end
  end
  for _, key in ipairs(keys) do M.drop_group(key) end
  if s.dirty == false then return end
  local buckets, present = {}, {}
  local function bucket(force_index, surface_index)
    local k = force_index .. ':' .. surface_index
    local b = buckets[k]
    if not b then b = {groups = {}, pool = {}, by_key = {}}; buckets[k] = b end
    return b
  end
  keys = {}
  for key in pairs(s.groups) do keys[#keys + 1] = key end
  table.sort(keys)
  for _, key in ipairs(keys) do
    local group = s.groups[key]
    local entry = {key = key, point = group.point, members = {}}
    local b = bucket(group.force_index, group.surface_index)
    b.groups[#b.groups + 1] = entry
    b.by_key[key] = entry
  end
  local ids = {}
  for id in pairs(s.units) do ids[#ids + 1] = id end
  table.sort(ids)
  for _, id in ipairs(ids) do
    local record = s.units[id]
    local e = record.entity
    if not e.valid then
      M.unregister(id)
    else
      present[record.force_index .. ':' .. record.surface_index] = true
      if READY[record.state] and not record.shadow then
        local b = bucket(record.force_index, record.surface_index)
        local item = setmetatable({id = id, entity = e}, LAZY)
        local entry = record.group and b.by_key[record.group]
        if entry then
          entry.members[#entry.members + 1] = item
        else
          if record.group then leave(record) end
          b.pool[#b.pool + 1] = item
        end
      end
    end
  end
  s.present = present
  for _, b in pairs(buckets) do
    if #b.groups == 0 then
      for _, item in ipairs(b.pool) do go_home(s.units[item.id]) end
    else
      local changes = geometry.rebalance(b.groups, b.pool)
      local moved = {}
      for id in pairs(changes) do moved[#moved + 1] = id end
      table.sort(moved)
      for _, id in ipairs(moved) do
        local record, key = s.units[id], changes[id]
        leave(record)
        record.homeward = nil
        if key then
          local group = s.groups[key]
          group.members[#group.members + 1] = id
          record.group = key
          send(record, geometry.slot(group.point, #group.members))
        end
      end
    end
  end
  -- The moves above only settle this split's own changes.
  s.dirty = false
end



function M.tick(phase)
  local s = storage.shredders
  if not (s and next(s.units)) then return end
  M.reap()
  M.recover()
  for player_index, pstate in pairs(storage.divisions or {}) do
    for n in pairs(pstate.slots) do
      if n ~= 0 and divisions.in_phase(player_index, n, phase) then M.update_group(player_index, n) end
    end
  end
  if phase == nil or phase == M.REBALANCE_PHASE then M.rebalance() end
  M.watch(phase)
end

-- Enemies within the radius, strongest first, then nearest.
function M.targets(surface, position, force, radius)
  local ranked = {}
  for _, other in ipairs(enemies_of(force)) do
    if #ranked >= M.TARGET_LIMIT then break end
    for _, e in pairs(surface.find_entities_filtered{position = position, radius = radius, force = other,
      type = TARGETS, limit = M.TARGET_LIMIT - #ranked}) do
      ranked[#ranked + 1] = {entity = e, health = e.max_health, d = geometry.distance2(e.position, position),
        id = e.unit_number or 0}
    end
  end
  table.sort(ranked, function(a, b)
    if a.health ~= b.health then return a.health > b.health end
    if a.d ~= b.d then return a.d < b.d end
    return a.id < b.id
  end)
  return ranked
end

-- Puts the shredder back on its wheels, out of any group; the next
-- rebalance gives it a post.
function M.stand_down(record)
  record.striking = nil
  unlock(record)
  clear_renders(record)
  leave(record)
  if swap(record, M.PARKED) then park(record); return end
  -- No room for the parked unit right now: hold still and retry next slice.
  local s = M.state()
  record.state = 'stranded'
  s.stranded = s.stranded or {}
  s.stranded[record.id] = true
  if record.entity.valid then
    record.entity.commandable.set_command{type = defines.command.stop, distraction = defines.distraction.none}
  end
end

-- Swaps stranded chargers back to parked units; the split then posts them.
function M.recover()
  local s = storage.shredders
  if not (s and s.stranded and next(s.stranded)) then return end
  local ids = {}
  for id in pairs(s.stranded) do ids[#ids + 1] = id end
  for _, id in ipairs(ids) do
    local record = s.units[id]
    if not (record and record.entity.valid and record.state == 'stranded') then
      s.stranded[id] = nil
    elseif swap(record, M.PARKED) then
      s.stranded[id] = nil
      park(record)
      s.dirty = true
    end
  end
end

-- Entities of a merged force now belong to the destination force.
function M.on_forces_merged(event)
  local s = storage.shredders
  if not s then return end
  for _, record in pairs(s.units) do
    if record.force_index == event.source_index then record.force_index = event.destination.index end
  end
  s.dirty = true
end

function M.launch(record)
  local target = record.target
  if not (target and target.valid) then return M.retarget(record) end
  local entity = record.entity
  record.state = 'charging'
  draw_body(record, 'tank-squad-shredder-boost', LOOK.boost_offset, 0.5)
  entity.commandable.set_command{type = defines.command.attack, target = target,
    distraction = defines.distraction.none}
  entity.surface.play_sound{path = 'tank-squad-shredder-boost-sound', position = entity.position}
  return true
end

-- A new enemy near the old target's last position: the least locked, then
-- the strongest. Enemies this charge could not reach are skipped.
function M.retarget(record)
  local around = record.target_position or record.entity.position
  unlock(record)
  if (record.retargets or 0) > M.RETARGETS then M.stand_down(record); return false end
  local entity = record.entity
  local skip = record.unreachable or {}
  local locks, best, best_locks = M.state().locks, nil, nil
  for _, r in ipairs(M.targets(entity.surface, around, entity.force, M.STRIKE_RADIUS)) do
    local id = r.entity.unit_number
    if not (id and skip[id]) then
      local n = locks[id] or 0
      if not best_locks or n < best_locks then best, best_locks = r.entity, n end
    end
  end
  if not best then M.stand_down(record); return false end
  lock(record, best)
  draw_lock(record)
  return M.launch(record)
end

-- With ignition the shredder first stands lit and aimed for IGNITION ticks;
-- without, it charges at once.
function M.charge(record, target, ignite)
  if not swap(record, M.CHARGING) then return false end
  record.retargets, record.unreachable = 0, nil
  lock(record, target)
  draw_lock(record)
  if not ignite then return M.launch(record) end
  local entity = record.entity
  record.state = 'igniting'
  draw_body(record, 'tank-squad-shredder-arm', LOOK.arm_offset, 1)
  entity.commandable.set_command{type = defines.command.stop, ticks_to_wait = M.IGNITION,
    distraction = defines.distraction.none}
  entity.surface.play_sound{path = 'tank-squad-shredder-lock-sound', position = entity.position}
  return true
end

-- Sends every ready shredder in the list at the enemies around the
-- position, one enemy each, strongest first. Returns the number sent.
function M.strike(ids, surface, position, force, radius)
  local s = storage.shredders
  if not (s and surface and force) then return 0 end
  local ranked = M.targets(surface, position, force, radius or M.STRIKE_RADIUS)
  if #ranked == 0 then return 0 end
  local ready = {}
  for _, id in ipairs(ids) do
    local record = s.units[id]
    if record and READY[record.state] and record.entity.valid and record.entity.surface_index == surface.index then
      ready[#ready + 1] = record
    end
  end
  local sent = 0
  for i, record in ipairs(ready) do
    if M.charge(record, ranked[(i - 1) % #ranked + 1].entity, true) then
      record.striking = true
      sent = sent + 1
    end
  end
  return sent
end

-- Only a strike counts; a shredder ramming its own attacker does not.
local function striking(group, units)
  for _, id in ipairs(group.members) do
    local record = units[id]
    if record and record.striking and (record.state == 'igniting' or record.state == 'charging') then return true end
  end
  return false
end

-- Runs before divisions.forget, while the division still lists the dying
-- soldier. Distress: half the size at the window's start lost within the
-- window, or the last soldier. Returns the number of shredders sent.
function M.on_soldier_died(entity)
  local s = storage.shredders
  if not s then return 0 end
  local player_index, n, division = divisions.owner(entity.unit_number)
  if not division or n == 0 then return 0 end
  local group = s.groups[player_index .. ':' .. n]
  if not group or #group.members == 0 or entity.surface_index ~= group.surface_index then return 0 end
  local tick, size = game.tick, #division.members
  local window = group.window
  if not window or tick - window.start > M.WINDOW then
    window = {start = tick, size = size, losses = 0}
    group.window = window
  end
  window.losses = window.losses + 1
  if window.losses * 2 < window.size and size > 1 then return 0 end
  if striking(group, s.units) then return 0 end
  local sent = M.strike(group.members, entity.surface, entity.position, entity.force, M.STRIKE_RADIUS)
  if sent > 0 then group.window = nil end
  return sent
end

-- The crash. The engine deals the ram damage and the shrapnel; this draws
-- the breakup turned along the charge and retires the shredder. The engine
-- is still running the crash's trigger, so the entity goes in the next
-- slice; it is invisible and inactive until then.
function M.on_trigger(event)
  if event.effect_id ~= M.EFFECT then return false end
  local source, s = event.source_entity, storage.shredders
  local record = source and source.valid and s and s.units[source.unit_number]
  if not record or record.state == 'spent' then return true end
  local from = source.position
  local to = event.target_position or (record.target and record.target.valid and record.target.position) or from
  local dx, dy = to.x - from.x, to.y - from.y
  rendering.draw_animation{animation = 'tank-squad-shredder-breakup', target = from, surface = source.surface,
    orientation = (math.atan2(dx, -dy) / (2 * math.pi)) % 1, render_layer = 'object',
    time_to_live = M.BREAKUP_TICKS, animation_speed = 0.25, animation_offset = -game.tick * 0.25}
  unlock(record)
  clear_renders(record)
  leave(record)
  record.state = 'spent'
  source.active = false
  s.doomed[record.id] = true
  return true
end

function M.reap()
  local s = storage.shredders
  if not (s and next(s.doomed)) then return end
  for id in pairs(s.doomed) do
    local record = s.units[id]
    if record and record.entity.valid then record.entity.destroy() end
    s.units[id], s.doomed[id] = nil, nil
  end
end

function M.on_command_completed(unit_number, result)
  local s = storage.shredders
  local record = s and s.units[unit_number]
  if not record then return false end
  if record.state == 'moving' then park(record)
  elseif record.state == 'igniting' then M.launch(record)
  elseif record.state == 'charging' then
    -- A failed attack on a living target means no path to it.
    local target = record.target
    if result == defines.behavior_result.fail and target and target.valid and target.unit_number then
      record.unreachable = record.unreachable or {}
      record.unreachable[target.unit_number] = true
      record.retargets = (record.retargets or 0) + 1
    end
    M.retarget(record)
  end
  return true
end

-- At least DANGER_UNITS enemy units within DANGER_RADIUS, or any nest or
-- worm within NEST_RADIUS. Both searches stop at their limit.
function M.danger(surface, position, force)
  local units = 0
  for _, other in ipairs(enemies_of(force)) do
    units = units + surface.count_entities_filtered{position = position, radius = M.DANGER_RADIUS,
      force = other, type = 'unit', limit = M.DANGER_UNITS - units}
    if units >= M.DANGER_UNITS then return true end
    if surface.count_entities_filtered{position = position, radius = M.NEST_RADIUS, force = other,
      type = NESTS, limit = 1} > 0 then return true end
  end
  return false
end

function M.release(player_index)
  local s = storage.shredders
  local shadow = s and s.shadows[player_index]
  if not shadow then return end
  for _, id in ipairs(shadow.members) do
    local record = s.units[id]
    if record then record.shadow = nil end
  end
  s.shadows[player_index] = nil
  s.dirty = true
end

-- Up to SHADOW_SIZE ready shredders within reach: from the largest group
-- first, never a group's last one, then from the pool; nearest first.
function M.form(player)
  local s = M.state()
  local character = player.character
  local position, force_index, surface_index = character.position, player.force.index, character.surface.index
  local sizes = {}
  for key, group in pairs(s.groups) do
    local ready = 0
    for _, id in ipairs(group.members) do
      local record = s.units[id]
      if record and READY[record.state] then ready = ready + 1 end
    end
    sizes[key] = ready
  end
  local candidates = {}
  for _, record in pairs(s.units) do
    local e = record.entity
    if e.valid and not record.shadow and READY[record.state] and e.force_index == force_index
      and e.surface_index == surface_index then
      local d = geometry.distance2(e.position, position)
      if d <= M.SHADOW_REACH * M.SHADOW_REACH then candidates[#candidates + 1] = {record = record, d = d} end
    end
  end
  local shadow = {members = {}, surface_index = surface_index, force_index = force_index}
  for _ = 1, M.SHADOW_SIZE do
    local best, best_i, best_size
    for i, c in ipairs(candidates) do
      local size = c.record.group and sizes[c.record.group] or 0
      if not c.record.group or size >= 2 then
        if not best or size > best_size or (size == best_size and (c.d < best.d
          or (c.d == best.d and c.record.id < best.record.id))) then
          best, best_i, best_size = c, i, size
        end
      end
    end
    if not best then break end
    local record = best.record
    if record.group then sizes[record.group] = sizes[record.group] - 1 end
    leave(record)
    record.shadow = player.index
    shadow.members[#shadow.members + 1] = record.id
    table.remove(candidates, best_i)
  end
  if #shadow.members == 0 then return nil end
  s.shadows[player.index] = shadow
  return shadow
end

-- Keeps the shadow SHADOW_BACK tiles behind the player, toward home.
function M.follow(shadow, surface, position, force)
  local home = M.home(surface.index, force.index, position)
  local point = geometry.backline(position, home and home.position, nil, M.SHADOW_BACK)
  shadow.point = point
  if shadow.ordered and geometry.distance2(shadow.ordered, point) <= M.SHADOW_DRIFT * M.SHADOW_DRIFT then return end
  shadow.ordered = point
  local units = M.state().units
  for i, id in ipairs(shadow.members) do
    local record = units[id]
    if record and READY[record.state] then send(record, geometry.slot(point, i)) end
  end
end

function M.watch_player(player)
  local s = M.state()
  local shadow = s.shadows[player.index]
  if not player.character then
    if shadow then M.release(player.index) end
    return
  end
  -- The character, not the player: a player in map or remote view has a
  -- camera position and surface of its own. A driven vehicle carries the
  -- character along.
  local character, force = player.character, player.force
  local surface = character.surface
  if shadow and (shadow.surface_index ~= surface.index or shadow.force_index ~= force.index) then
    M.release(player.index)
    shadow = nil
  end
  if not shadow and not s.present[force.index .. ':' .. surface.index] then return end
  local position = character.position
  if M.danger(surface, position, force) then
    -- Members that crashed ramming their own attackers leave the shadow;
    -- an emptied shadow that never struck forms again.
    if shadow and #shadow.members == 0 and not shadow.spent then
      M.release(player.index)
      shadow = nil
    end
    if shadow then shadow.calm_since = nil else shadow = M.form(player) end
    if shadow then M.follow(shadow, surface, position, force) end
  elseif shadow then
    shadow.calm_since = shadow.calm_since or game.tick
    if game.tick - shadow.calm_since >= M.CALM then
      M.release(player.index)
    else
      M.follow(shadow, surface, position, force)
    end
  end
end

-- One player per slice, by player index. Shadows of players who left go.
function M.watch(phase)
  local s = M.state()
  for _, player in pairs(game.connected_players) do
    if phase == nil or player.index % divisions.PHASES == phase then M.watch_player(player) end
  end
  for index in pairs(s.shadows) do
    local player = game.get_player(index)
    if not (player and player.connected) then M.release(index) end
  end
end

local function owner(entity)
  if entity.type == 'character' then return entity.player end
  local driver = entity.get_driver()
  if not driver then return nil end
  if driver.object_name == 'LuaPlayer' then return driver end
  return driver.player
end

-- Returns true for shredders and for the entities of players, so
-- control.lua keeps them away from the soldier handlers.
function M.on_damaged(event)
  local entity = event.entity
  if not (entity and entity.valid) then return false end
  local cause = event.cause
  if names.shredder_set[entity.name] then
    local s = storage.shredders
    local record = s and s.units[entity.unit_number]
    -- A killing blow is left to the engine: swapping now would cancel the death.
    if entity.name == M.PARKED and record and READY[record.state] and cause and cause.valid
      and cause.unit_number and (event.final_health or 1) > 0 and entity.force.is_enemy(cause.force) then
      M.charge(record, cause, false)
    end
    return true
  end
  if not PLAYER_TYPES[entity.type] then return false end
  local s = storage.shredders
  if not (s and next(s.shadows)) then return true end
  local player = owner(entity)
  local shadow = player and s.shadows[player.index]
  if not shadow or shadow.spent then return true end
  if not (cause and cause.valid and player.force.is_enemy(cause.force)) then return true end
  if M.strike(shadow.members, entity.surface, entity.position, player.force, M.SHADOW_STRIKE) > 0 then
    shadow.spent = true
  end
  return true
end

return M
