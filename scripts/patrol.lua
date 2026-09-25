local combat = require("scripts.combat")
local names = require("scripts.names")
local divisions = require("scripts.divisions")
local render = require("scripts.render")
local geometry = require("scripts.escort_geometry")
local patrol_geometry = require("scripts.patrol_geometry")
local retreat = require("scripts.retreat")
local config = require("scripts.config")

local M = {}

-- A route whose every waypoint failed in a row is unreachable for now.
M.RETRY_TICKS = 10 * 60

local function route(player_index, n)
  local record = divisions.record(player_index, n)
  return record, record.patrol
end

function M.clear(player_index, n)
  local record = divisions.record(player_index, n)
  record.patrol = nil
  render.clear_route(record)
end

function M.draw(player_index, n)
  local record = divisions.record(player_index, n)
  local r = record.patrol
  if not r then
    render.clear_route(record)
    return
  end
  local surface = game.surfaces[r.surface_index]
  if not surface then return end
  render.route(player_index, n, record, surface)
end

-- The drag selection owns nobody, so it never patrols; control.lua moves
-- it into a division first.
function M.add_waypoint(player_index, n, position, surface)
  if n == 0 then return nil end
  local player = game.get_player(player_index)
  surface = surface or (player and player.surface)
  if not surface then return nil end
  local record = divisions.record(player_index, n)
  local r = record.patrol
  if r and r.surface_index and r.surface_index ~= surface.index then return nil end
  if not r then
    r = {waypoints = {}, surface_index = surface.index}
    record.patrol = r
  end
  r.surface_index = surface.index
  table.insert(r.waypoints, {x = position.x, y = position.y})
  M.draw(player_index, n)
  return #r.waypoints
end

-- Each soldier keeps its own post: a stretch of one ring of the route that
-- it walks back and forth on its own, or a point it holds when the division
-- is crowded. The posts split the rings evenly, so the division covers the
-- whole area at once instead of walking it as one group. A soldier sends its
-- next leg when its own leg completes, so a steady patrol costs one command
-- per arrival and nothing per sweep.
--
-- r.posts[unit_number] = {points, loop, anchor, next, i, dir, failures, idle}
--   i       the point the soldier walks to: 0 is the anchor, where it takes
--           up its post, and nil sends it there when its command completes
--   idle    it holds its only point and has arrived
-- r.retry[unit_number]     the tick a failed soldier asks for a path again
-- r.responders[unit_number] the tick it left its post to help another

local function go(soldier, point)
  combat.set_command(soldier, {
    type = defines.command.go_to_location,
    destination = point,
    radius = 4,
    distraction = defines.distraction.by_enemy,
  })
end

local function target(post)
  if post.i == 0 then return post.anchor end
  return post.points[post.i]
end

-- Sends a soldier to the middle of its post. Neighbours then walk their
-- stretches in step and keep their spacing.
local function take_up(soldier, post)
  post.i, post.dir = 0, 1
  go(soldier, post.anchor)
end

-- A soldier fighting on its own or helping another keeps its command. It
-- takes up its post when that command completes.
M.RESPONSE_TICKS = 60 * 60
local function busy(r, id)
  local since = r.responders and r.responders[id]
  if since and game.tick - since < M.RESPONSE_TICKS then return true end
  return combat.fighting(id)
end

-- Deals the posts to the members on the route's surface. Soldiers far from
-- the centre take the outer rings and a headquarters the innermost, near
-- the middle of the area. With `all`, every soldier is sent to its post, as
-- a new route needs. Otherwise only newcomers and soldiers holding a point
-- are, and a soldier walking a leg finishes it first, so a recruit or a
-- casualty does not make the whole division request paths again.
local function assign(player_index, n, r, all)
  r.dirty = nil
  -- Reading the roster can report a silent loss, which deals the posts
  -- through the listener below; this call deals them once instead.
  r.assigning = true
  local members = divisions.get(player_index, n)
  r.assigning = nil
  if not r.surface_index and members[1] then r.surface_index = members[1].surface_index end
  local keyed = {}
  for _, soldier in pairs(members) do
    -- A soldier away healing or guarding has no post until it rejoins.
    if soldier.surface_index == r.surface_index and not retreat.is_away(r, soldier.unit_number) then
      keyed[#keyed + 1] = {entity = soldier, id = soldier.unit_number, position = soldier.position,
        hq = soldier.name == names.headquarters}
    end
  end
  local layout = patrol_geometry.layout(r.waypoints, #keyed)
  local centre = layout.centre
  for _, k in ipairs(keyed) do k.d = geometry.distance_squared(k.position, centre) end
  table.sort(keyed, function(a, b)
    if a.hq ~= b.hq then return b.hq end
    if a.d ~= b.d then return a.d > b.d end
    return a.id < b.id
  end)
  local old, posts, first = r.posts or {}, {}, 0
  for _, count in ipairs(layout.counts) do
    local points, anchors = {}, {}
    for i = 1, count do
      points[i] = keyed[first + i].position
      anchors[i] = layout.posts[first + i].anchor
    end
    local match = patrol_geometry.match(points, anchors, centre, layout.around)
    for i = 1, count do
      local k, post = keyed[first + i], layout.posts[first + match[i]]
      local id, before = k.id, old[k.id]
      posts[id] = post
      if busy(r, id) then
        post.i = nil
      elseif not all and before and before.idle and #post.points == 1
        and geometry.distance_squared(post.points[1], before.points[1]) < 1 then
        -- Already holding this very point.
        post.i, post.idle = 0, true
      elseif all or not before or before.idle then
        take_up(k.entity, post)
      else
        -- Walking: the leg in progress completes first.
        post.i = nil
      end
      if r.retry then r.retry[id] = nil end
    end
    first = first + count
  end
  r.posts = posts
  -- Routes saved before posts existed walked behind a leader.
  r.index, r.members, r.lanes, r.leader, r.resume_tick, r.failures = nil, nil, nil, nil, nil, nil
end

-- A division that gains or loses members is dealt new posts at once; the
-- divisions module calls this once per change, not once per soldier.
divisions.listen_members_changed(function(player_index, n)
  local record, r = route(player_index, n)
  if record.mode == "patrol" and r and #r.waypoints > 0 and not r.assigning then
    assign(player_index, n, r, false)
  end
end)

-- A recruit from a linked barracks heads for the nearest waypoint. The next
-- sweep deals every post again, once for a whole burst of recruits.
function M.join(record, soldier)
  local r = record.patrol
  if record.mode ~= "patrol" or not (r and r.waypoints[1]) then return false end
  r.dirty = true
  go(soldier, r.waypoints[geometry.nearest_point(r.waypoints, soldier.position)])
  return true
end

function M.start(player_index, n)
  if n == 0 then return nil end
  local record, r = route(player_index, n)
  if not r or #r.waypoints == 0 then return nil end
  divisions.end_escort(record)
  record.mode = "patrol"
  record.order = nil
  record.scout = nil
  r.retry, r.responders, r.alarm_tick, r.retreat = nil, nil, nil, nil
  assign(player_index, n, r, true)
  return #r.waypoints
end

-- The point a soldier walks to or holds, as an index into its post's points.
function M.index(player_index, n, unit_number)
  local _, r = route(player_index, n)
  local post = r and r.posts and r.posts[unit_number]
  return post and post.i or nil
end

-- The point itself.
function M.target(player_index, n, unit_number)
  local _, r = route(player_index, n)
  local post = r and r.posts and r.posts[unit_number]
  return post and post.i and target(post) or nil
end

local function each_route(fn)
  storage.divisions = storage.divisions or {}
  for player_index, state in pairs(storage.divisions) do
    for n, record in pairs(state.slots) do
      if record.patrol then
        local result = fn(player_index, n, record.patrol, record)
        if result ~= nil then return result end
      end
    end
  end
  return nil
end

-- Moves a post on by one point: round the loop, or back and forth along a
-- stretch. False for a post with one point, which is held.
local function step(post)
  local count = #post.points
  if count == 1 then return false end
  if post.i == 0 then
    post.i, post.dir = post.next, 1
  elseif post.loop then
    post.i = post.i % count + 1
  else
    local i = post.i + post.dir
    if i < 1 or i > count then
      post.dir = -post.dir
      i = post.i + post.dir
    end
    post.i = i
  end
  return true
end

-- A failed path completes on the tick it is requested. Resending at once
-- would request a path every tick, so a failed soldier skips to its next
-- point on the next sweep, and one whose every point failed backs off.
function M.advance(unit_number, result)
  local _, _, record = divisions.owner(unit_number)
  local r = record and record.mode == "patrol" and record.patrol
  local post = r and r.posts and r.posts[unit_number]
  if not post then return nil end
  local soldier = game.get_entity_by_unit_number(unit_number)
  if not (soldier and soldier.valid) then return nil end
  post.idle = nil
  if r.responders and r.responders[unit_number] then
    r.responders[unit_number] = nil
    post.i = nil
  end
  if not post.i then
    take_up(soldier, post)
    return post.i
  end
  if result == defines.behavior_result.fail then
    post.failures = (post.failures or 0) + 1
    step(post)
    r.retry = r.retry or {}
    r.retry[unit_number] = game.tick + (post.failures >= #post.points and M.RETRY_TICKS or 0)
    return post.i
  end
  post.failures = nil
  if step(post) then go(soldier, target(post)) else post.idle = true end
  return post.i
end

-- Soldiers that can retreat: members on the route's surface. The unarmed
-- headquarters never retreats and never guards; it is a depot itself.
local function retreat_members(player_index, n, r)
  local out = {}
  for _, e in ipairs(divisions.cached(player_index, n)) do
    if e.valid and e.surface_index == r.surface_index and e.name ~= names.headquarters then out[#out + 1] = e end
  end
  return out
end

-- A rejoin always reports a change, which deals the posts again.
local function rejoined() end

-- Injured soldiers leave for a depot as in escort mode (scripts/retreat.lua).
-- Anyone leaving or rejoining deals the posts again on the next sweep, once,
-- through the same path as a casualty. The settings are read once per call,
-- and only when a patrol division in this phase has soldiers.
function M.tick(phase)
  local cfg
  each_route(function(player_index, n, r, record)
    if record.mode ~= "patrol" or not divisions.in_phase(player_index, n, phase) then return end
    if r.dirty or not r.posts then
      if #r.waypoints > 0 then assign(player_index, n, r, not r.posts) end
      return
    end
    local members = retreat_members(player_index, n, r)
    if members[1] then
      cfg = cfg or config.escort()
      local _, changed = retreat.sweep(r, members, {
        force = members[1].force, surface_index = r.surface_index,
        retreat = cfg.retreat, rejoin = cfg.rejoin, range = cfg.range,
        responders = r.responders, on_rejoin = rejoined,
      })
      if changed then r.dirty = true end
    end
    if not r.retry then return end
    local tick = game.tick
    for id, due in pairs(r.retry) do
      if retreat.is_away(r, id) then
        r.retry[id] = nil
      elseif tick >= due then
        r.retry[id] = nil
        local post, soldier = r.posts[id], game.get_entity_by_unit_number(id)
        if post and post.i and soldier and soldier.valid then go(soldier, target(post)) end
      end
    end
    if not next(r.retry) then r.retry = nil end
  end)
end

-- Death cleanup runs after membership removal, so the dead soldier is no
-- longer indexed. Its post is dealt out again on the next sweep, once for
-- a burst of casualties.
function M.forget(unit_number)
  return each_route(function(_, _, r)
    if r.posts and r.posts[unit_number] then
      r.posts[unit_number] = nil
      if r.retry then r.retry[unit_number] = nil end
      if r.responders then r.responders[unit_number] = nil end
      r.dirty = true
      return true
    end
  end)
end

-- A patrol soldier or headquarters under attack calls the rest of its
-- division to help: every armed member not already fighting attacks the
-- enemies around it, then returns to its post. One call per route every
-- ALARM_TICKS, so a long fight costs a table lookup per hit.
M.ALARM_TICKS = 2 * 60
M.HELP_RADIUS = 24
function M.on_damaged(event)
  local entity = event.entity
  if not (entity and entity.valid) then return end
  local player_index, n, record = divisions.owner(entity.unit_number)
  local r = record and record.mode == "patrol" and record.patrol
  if not (r and r.posts) then return end
  local tick = game.tick
  if r.alarm_tick and tick < r.alarm_tick + M.ALARM_TICKS then return end
  local cause = event.cause
  if not (cause and cause.valid) then return end
  local force = entity.force
  if cause.force == force or not force.is_enemy(cause.force) then return end
  r.alarm_tick = tick
  local victim, surface_index, position = entity.unit_number, entity.surface_index, entity.position
  for _, soldier in ipairs(divisions.cached(player_index, n)) do
    local id = soldier.unit_number
    if id ~= victim and r.posts[id] and soldier.surface_index == surface_index
      and soldier.name ~= names.headquarters and not busy(r, id) then
      r.responders = r.responders or {}
      r.responders[id] = tick
      if r.retry then r.retry[id] = nil end
      combat.set_command(soldier, {type = defines.command.attack_area, destination = position,
        radius = M.HELP_RADIUS, distraction = defines.distraction.by_enemy})
    end
  end
end

return M
