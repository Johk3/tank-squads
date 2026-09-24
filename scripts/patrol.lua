local combat = require("scripts.combat")
local names = require("scripts.names")
local divisions = require("scripts.divisions")
local render = require("scripts.render")
local geometry = require("scripts.escort_geometry")
local patrol_geometry = require("scripts.patrol_geometry")

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

function M.add_waypoint(player_index, n, position, surface)
  local player = game.get_player(player_index)
  surface = surface or (player and player.surface)
  if not surface then return nil end
  local record = divisions.record(player_index, n)
  local r = record.patrol
  if r and r.surface_index and r.surface_index ~= surface.index then return nil end
  if not r then
    r = {waypoints = {}, index = 1, members = {}, surface_index = surface.index}
    record.patrol = r
  end
  r.surface_index = surface.index
  table.insert(r.waypoints, {x = position.x, y = position.y})
  M.draw(player_index, n)
  return #r.waypoints
end

-- Prototype speeds never change during a session, so every peer builds the
-- same cache. Without prototype data (the unit tests) all speeds are equal.
-- The cache belongs to one `prototypes` object, which only the tests replace.
local speeds, speeds_from = {}, nil
local function speed(name)
  if speeds_from ~= prototypes then speeds, speeds_from = {}, prototypes end
  local value = speeds[name]
  if not value then
    local prototype = prototypes and prototypes.entity[name]
    value = prototype and prototype.speed or 1
    speeds[name] = value
  end
  return value
end

-- A better leader: any soldier before a headquarters, then the slower one.
local function leads(a, b)
  if a.hq ~= b.hq then return b.hq end
  return a.speed < b.speed
end

-- Lane 1 follows the route as drawn and goes to the slowest soldier, who is
-- also the leader: every other lane is shorter and walked at least as fast,
-- so the whole division arrives before the leader starts the next leg. The
-- other soldiers take the remaining lanes by their distance from the centre,
-- so each starts on the lane nearest to it. A headquarters is far too slow
-- to set the pace. It takes the innermost lanes, the shortest, near the
-- middle of the area, and leads only a division of headquarters. One
-- position and one name read per soldier, and one sort. Returns the soldiers
-- and their ids in lane order.
local function assign_lanes(soldiers, ids, centre)
  local keyed = {}
  for i, soldier in ipairs(soldiers) do
    local name = soldier.name
    keyed[i] = {entity = soldier, id = ids[i], speed = speed(name), hq = name == names.headquarters,
      d = geometry.distance_squared(soldier.position, centre)}
  end
  table.sort(keyed, function(a, b)
    if a.d ~= b.d then return a.d > b.d end
    return a.id < b.id
  end)
  if #keyed == 0 then return {}, {} end
  local slowest = 1
  for i, k in ipairs(keyed) do
    if leads(k, keyed[slowest]) then slowest = i end
  end
  local leader = table.remove(keyed, slowest)
  local out, out_ids = {leader.entity}, {leader.id}
  for pass = 1, 2 do
    for _, k in ipairs(keyed) do
      if k.hq == (pass == 2) then out[#out + 1], out_ids[#out_ids + 1] = k.entity, k.id end
    end
  end
  return out, out_ids
end

-- The previous leg's lane order when it still names exactly these soldiers,
-- so a steady patrol keeps its lanes without reading or sorting anything.
-- r.members is that order; a recruit appended to it takes the innermost lane.
local function kept_lanes(r, by_id, count)
  if not r.lanes or #r.members ~= count then return nil end
  local out = {}
  for i, id in ipairs(r.members) do
    out[i] = by_id[id]
    if not out[i] then return nil end
  end
  return out, r.members
end

local function send(player_index, n, r)
  r.resume_tick = nil
  local members = divisions.get(player_index, n)
  if not r.surface_index and members[1] then r.surface_index = members[1].surface_index end
  local present, ids, by_id = {}, {}, {}
  for _, soldier in pairs(members) do
    if soldier.surface_index == r.surface_index then
      local id, i = soldier.unit_number, #present + 1
      present[i], ids[i], by_id[id] = soldier, id, soldier
    end
  end
  local waypoint = r.waypoints[r.index]
  -- The soldiers spread over concentric copies of the route instead of all
  -- heading for the same waypoint, so together they sweep the whole area it
  -- encloses. A one-waypoint route has no area and keeps them together.
  local centre = patrol_geometry.centre(r.waypoints)
  local order, order_ids = kept_lanes(r, by_id, #present)
  if not order then order, order_ids = assign_lanes(present, ids, centre) end
  for k, soldier in ipairs(order) do
    combat.set_command(soldier, {
      type = defines.command.go_to_location,
      destination = patrol_geometry.lane_point(centre, waypoint, patrol_geometry.lane_scale(k, #order)),
      radius = 4,
      distraction = defines.distraction.by_enemy,
    })
  end
  -- Routes saved before lanes existed get one full assignment first.
  r.members, r.lanes = order_ids, true
  r.leader = r.members[1]
end

-- Membership changes keep the current leg, but elect a current member as
-- leader and resend once so an already-arrived replacement cannot stall it.
divisions.listen_members_changed(function(player_index, n)
  local record, r = route(player_index, n)
  if record.mode == "patrol" and r and #r.waypoints > 0 then
    send(player_index, n, r)
  end
end)

-- A recruit from a linked barracks joins the current leg without disturbing
-- the others, and kept_lanes() gives it the innermost lane from the next leg.
-- A recruit slower than the leader would fall behind that pace, so the next
-- leg assigns every lane afresh and the recruit leads. The current leg keeps
-- its leader: a recruit still walking from the barracks must not stall it.
-- A recruited headquarters keeps the innermost lane it is appended to, and a
-- soldier recruited into a patrol led by a headquarters takes over the lead.
function M.join(record, soldier)
  local r = record.patrol
  if record.mode ~= "patrol" or not (r and r.waypoints[r.index]) then return false end
  r.members[#r.members + 1] = soldier.unit_number
  if r.leader then
    local leader = game.get_entity_by_unit_number(r.leader)
    if leader and leader.valid then
      local name, leader_name = soldier.name, leader.name
      local hq, leader_hq = name == names.headquarters, leader_name == names.headquarters
      if leads({hq = hq, speed = speed(name)}, {hq = leader_hq, speed = speed(leader_name)}) then r.lanes = nil end
    end
  else
    r.leader = soldier.unit_number
  end
  combat.set_command(soldier, {type = defines.command.go_to_location,
    destination = r.waypoints[r.index], radius = 4, distraction = defines.distraction.by_enemy})
  return true
end

function M.start(player_index, n)
  local record, r = route(player_index, n)
  if not r or #r.waypoints == 0 then return nil end
  divisions.end_escort(record)
  record.mode = "patrol"
  record.order = nil
  record.scout = nil
  r.index, r.failures = 1, nil
  send(player_index, n, r)
  return r.index
end

function M.index(player_index, n)
  local _, r = route(player_index, n)
  return r and r.index or nil
end

-- Death cleanup runs after membership removal, so the dead leader is no
-- longer indexed. Search route leaders only here, never on completion events.
local function each_route(fn)
  storage.divisions = storage.divisions or {}
  for player_index, state in pairs(storage.divisions) do
    for n, record in pairs(state.slots) do
      if record.patrol then
        local result = fn(player_index, n, record.patrol)
        if result ~= nil then return result end
      end
    end
  end
  return nil
end

-- A failed path completes on the tick it is requested. Resending at once
-- would request the same kind of path every tick, so a failed leg waits for
-- the next sweep, and a fully unreachable route backs off.
function M.advance(unit_number, result)
  local player_index, n, record = divisions.owner(unit_number)
  local r = record and record.patrol
  if not r or not unit_number or r.leader ~= unit_number then return nil end
  r.index = r.index % #r.waypoints + 1
  if result == defines.behavior_result.fail then
    r.failures = (r.failures or 0) + 1
    r.resume_tick = game.tick + (r.failures >= #r.waypoints and M.RETRY_TICKS or 0)
  else
    r.failures = nil
    send(player_index, n, r)
  end
  return r.index
end

function M.tick(phase)
  each_route(function(player_index, n, r)
    if not divisions.in_phase(player_index, n, phase) then return end
    local record = divisions.record(player_index, n)
    if record.mode == "patrol" and r.resume_tick and game.tick >= r.resume_tick then send(player_index, n, r) end
  end)
end

function M.forget(unit_number)
  return each_route(function(player_index, n, r)
    if r.leader == unit_number then
      send(player_index, n, r)
      return r.leader or false
    end
  end)
end

return M
