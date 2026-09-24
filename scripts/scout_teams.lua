-- Scout teams. A scouting division splits into teams that each explore
-- their own sector of the compass in formation, advancing in short hops.
-- scout.lua forms the teams, runs the chunk search and calls sweep() once
-- per team each sweep. All state lives in record.scout, so anything that
-- ends scouting drops every team, hop, convoy and withdraw with it.
local combat = require("scripts.combat")
local retreat = require("scripts.retreat")
local assault = require("scripts.assault")
local geometry = require("scripts.scout_geometry")

local M = {}

local function go(soldier, destination, radius)
  combat.set_command(soldier, {type = defines.command.go_to_location, destination = destination,
    radius = radius, distraction = defines.distraction.by_enemy})
end

local function centroid(soldiers)
  local points = {}
  for i, e in ipairs(soldiers) do points[i] = e.position end
  return geometry.centroid(points)
end

function M.form(state, members)
  local entries, fronts = {}, 0
  for i, e in ipairs(members) do
    local kind = assault.kind(e.name)
    entries[i] = {id = e.unit_number, kind = kind}
    if kind ~= "siege" then fronts = fronts + 1 end
  end
  local count = geometry.team_count(#members, fronts)
  local dealt, sectors = geometry.deal(entries, count), geometry.sectors(count)
  state.origin = centroid(members)
  state.teams, state.team_of, state.team_count = {}, {}, count
  for id = 1, count do
    state.teams[id] = {members = dealt[id], formed = #dealt[id], sectors = sectors[id]}
    for _, unit in ipairs(dealt[id]) do state.team_of[unit] = id end
  end
  state.roster_dirty = nil
  -- Scout state saved before teams existed.
  state.ring, state.offset, state.target, state.failed = nil, nil, nil, nil
end

-- The team's soldiers in this sweep's roster. Ids that left it (deaths,
-- transfers) are dropped here, so a departed soldier never stalls a hop.
local function roster(state, team, by_id)
  local out, kept = {}, {}
  for _, unit in ipairs(team.members) do
    local e = by_id[unit]
    if e then
      out[#out + 1], kept[#kept + 1] = e, unit
    else
      state.team_of[unit] = nil
    end
  end
  if #kept ~= #team.members then team.members = kept end
  local hop = team.hop
  if hop then
    for unit in pairs(hop.pending) do if not by_id[unit] then hop.pending[unit] = nil end end
    for unit in pairs(hop.front) do if not by_id[unit] then hop.front[unit] = nil end end
  end
  return out
end

local function anchor(team)
  if team.withdraw then return team.withdraw.destination, retreat.ARRIVAL_RADIUS end
  return team.hop and team.hop.point or team.last_point, 8
end

-- A soldier joining mid-hop walks to the team and takes a slot at the next
-- hop. It never enters `pending`, so a soldier still walking in cannot
-- stall the hop.
local function rejoin(team, soldier)
  local point, radius = anchor(team)
  if point then go(soldier, point, radius) end
end

function M.join(state, soldier)
  local best
  for id = 1, state.team_count do
    local team = state.teams[id]
    if team and not team.blocked and (not best or #team.members < #state.teams[best].members) then best = id end
  end
  if not best then
    for id = 1, state.team_count do
      if state.teams[id] then best = id; break end
    end
  end
  if not best then return false end
  local team = state.teams[best]
  team.members[#team.members + 1] = soldier.unit_number
  state.team_of[soldier.unit_number] = best
  rejoin(team, soldier)
  return true
end

-- Roster members without a team join as recruits. Departures need no scan:
-- roster() drops them on the team's next sweep.
function M.reconcile(state, members)
  state.roster_dirty = nil
  for _, e in ipairs(members) do
    if not state.team_of[e.unit_number] then M.join(state, e) end
  end
end

local function block(team, chunk)
  team.failed = team.failed or {}
  local count, oldest_key, oldest = 0, nil, math.huge
  for key, expiry in pairs(team.failed) do
    count = count + 1
    if expiry < oldest then oldest_key, oldest = key, expiry end
  end
  local key = chunk.x .. ":" .. chunk.y
  if not team.failed[key] and count >= geometry.FAILURE_LIMIT then team.failed[oldest_key] = nil end
  team.failed[key] = game.tick + geometry.FAILURE_TTL
end

local function chart(ctx, centre)
  local r = geometry.CHART_RADIUS
  ctx.force.chart(ctx.surface, {{x = centre.x - r, y = centre.y - r}, {x = centre.x + r, y = centre.y + r}})
end

local function start_hop(team, present)
  local from = team.last_point or centroid(present)
  local destination
  if team.target then
    destination = {x = team.target.x * 32 + 16, y = team.target.y * 32 + 16}
  else
    local a = geometry.march_angles(team.sectors)[team.march]
    destination = {x = from.x + math.cos(a) * geometry.MARCH_DISTANCE, y = from.y + math.sin(a) * geometry.MARCH_DISTANCE}
  end
  local point, heading, reach = geometry.hop(from, destination)
  if not point then
    team.target = nil
    return
  end
  local entries = {}
  for i, e in ipairs(present) do entries[i] = {id = e.unit_number, kind = assault.kind(e.name), position = e.position} end
  local slots = geometry.slots(entries, point, heading)
  local pending, front = {}, {}
  for _, e in ipairs(present) do
    local unit = e.unit_number
    local slot = slots[unit]
    go(e, slot.position, slot.band == "rear" and 6 or 4)
    pending[unit] = true
    if slot.band == "front" then front[unit] = true end
  end
  team.hop = {from = from, point = point, heading = heading, reach = reach, pending = pending, front = front,
    failed = {}, expires = game.tick + geometry.HOP_TIMEOUT}
  team.last_point = point
end

local function all_front_failed(hop)
  if not next(hop.front) then return false end
  for unit in pairs(hop.front) do
    if not hop.failed[unit] then return false end
  end
  return true
end

-- Targets change only here, never in the middle of a hop.
local function finish_hop(team, ctx)
  local hop = team.hop
  team.hop = nil
  if all_front_failed(hop) then
    team.last_point = hop.from
    if team.target then
      block(team, team.target)
      team.target = nil
    else
      team.march = team.march + 1
      if team.march > geometry.MARCH_ANGLES then team.blocked = true end
    end
    return
  end
  if team.target then
    if hop.reach or ctx.force.is_chunk_charted(ctx.surface, team.target) then team.target = nil end
  elseif team.found then
    team.target, team.found, team.march = team.found, nil, nil
  end
end

-- Between hops: find a target (or keep marching) and start the next hop.
local function plan(team, present, ctx)
  if not team.target and not team.march then
    local chunk, empty = ctx.search(team, team.last_point or centroid(present))
    if chunk then
      team.target = chunk
    elseif empty then
      team.march = 1
    else
      return -- budget spent; the search resumes next sweep
    end
  end
  start_hop(team, present)
end

local function has_front(members)
  for _, e in ipairs(members) do
    if assault.kind(e.name) ~= "siege" then return true end
  end
  return false
end

-- A team merges into the nearest team that is not blocked when it is down
-- to one soldier, has no front soldier left to screen its siege tanks, or is
-- blocked. The host takes over the sector unless it is blocked, takes over
-- its convoys, and never re-commands its own soldiers. Returns true when the
-- team is gone.
local function merge_check(state, id, team, members, present)
  local keep
  if team.blocked then
    keep = false
  elseif #present <= 1 or not has_front(members) then
    keep = true
  else
    return false
  end
  local here = team.last_point or (#present > 0 and centroid(present)) or nil
  local host_id, best
  for other = 1, state.team_count do
    local candidate = state.teams[other]
    if other ~= id and candidate and not candidate.blocked then
      local there = candidate.last_point
      local d = (here and there) and geometry.distance_squared(here, there) or math.huge
      if not host_id or d < best then host_id, best = other, d end
    end
  end
  if not host_id then return false end
  local host = state.teams[host_id]
  for _, unit in ipairs(team.members) do
    host.members[#host.members + 1] = unit
    state.team_of[unit] = host_id
  end
  host.formed = host.formed + #team.members
  if keep then
    for _, r in ipairs(team.sectors) do host.sectors[#host.sectors + 1] = {from = r.from, to = r.to} end
  end
  retreat.absorb(host, team)
  for _, e in ipairs(present) do rejoin(host, e) end
  state.teams[id] = nil
  return true
end
local function nearest_depot(ctx, position)
  local list = retreat.barracks_in_reach({force = ctx.force, surface_index = ctx.surface.index})
  local i, distance = retreat.nearest_barracks(list, position, ctx.cfg.range)
  if i then return list[i].entity, list[i].position, distance end
end

local function send_home(present, destination)
  for _, e in ipairs(present) do go(e, destination, retreat.ARRIVAL_RADIUS) end
end

local function end_withdraw(team, members, ctx, failed)
  team.withdraw, team.last_point = nil, nil
  team.formed = #members
  if failed then team.withdraw_after = game.tick + retreat.TIMEOUT end
  if team.target and ctx.force.is_chunk_charted(ctx.surface, team.target) then team.target = nil end
end

local function healed(present, rejoin_at)
  for _, e in ipairs(present) do
    if e.health / e.max_health < rejoin_at then return false end
  end
  return true
end

-- The same progress rule as a convoy: closing in on the barracks, or
-- standing in its healing radius, is progress.
local function withdraw_step(team, members, present, ctx)
  local w = team.withdraw
  if not w.barracks.valid then
    local barracks, destination, distance = nearest_depot(ctx, centroid(present))
    if not barracks then
      end_withdraw(team, members, ctx, true)
      return
    end
    w.barracks, w.destination, w.best, w.progress = barracks, destination, distance, game.tick
    send_home(present, destination)
    return
  end
  if healed(present, ctx.cfg.rejoin) then
    end_withdraw(team, members, ctx, false)
    return
  end
  local closest
  for _, e in ipairs(present) do
    local d = geometry.distance(e.position, w.destination)
    if not closest or d < closest then closest = d end
  end
  if closest <= retreat.HEAL_RADIUS or closest < w.best - 1 then w.best, w.progress = closest, game.tick end
  if game.tick - w.progress >= retreat.TIMEOUT then
    end_withdraw(team, members, ctx, true)
    return
  end
  -- Only after a completion: re-sending a soldier that is still walking
  -- would restart its pathfinding every sweep.
  local limit = (retreat.ARRIVAL_RADIUS + 2) ^ 2
  for unit in pairs(w.resend) do
    local e = ctx.by_id[unit]
    if e and geometry.distance_squared(e.position, w.destination) > limit then go(e, w.destination, retreat.ARRIVAL_RADIUS) end
  end
  w.resend = {}
end

-- Returns true while the team is withdrawing, so it does not hop. A team
-- below half health, or down to half the soldiers it had when it formed or
-- last healed, drives to the nearest barracks together.
local function withdraw(team, members, present, health, max_health, ctx)
  if team.withdraw then
    withdraw_step(team, members, present, ctx)
    return team.withdraw ~= nil
  end
  if team.withdraw_after and game.tick < team.withdraw_after then return false end
  if not geometry.should_withdraw(health, max_health, #members, team.formed) then return false end
  local barracks, destination, distance = nearest_depot(ctx, centroid(present))
  if not barracks then
    team.withdraw_after = game.tick + geometry.NO_BARRACKS_RETRY
    return false
  end
  team.hop = nil
  team.withdraw = {barracks = barracks, destination = destination, best = distance, progress = game.tick, resend = {}}
  send_home(present, destination)
  return true
end

function M.sweep(state, id, ctx)
  local team = state.teams[id]
  local members = roster(state, team, ctx.by_id)
  for key, expiry in pairs(team.failed or {}) do
    if expiry <= game.tick then team.failed[key] = nil end
  end
  local cfg = ctx.cfg
  local present, _, health, max_health = retreat.sweep(team, members, {
    force = ctx.force, surface_index = state.surface_index,
    retreat = team.withdraw and 0 or cfg.retreat, rejoin = cfg.rejoin, range = cfg.range,
    on_rejoin = function(soldier) rejoin(team, soldier) end,
  })
  local hop = team.hop
  if hop then
    for unit in pairs(hop.pending) do if retreat.is_away(team, unit) then hop.pending[unit] = nil end end
    for unit in pairs(hop.front) do if retreat.is_away(team, unit) then hop.front[unit] = nil end end
  end
  if merge_check(state, id, team, members, present) then return end
  if #present == 0 then return end
  if withdraw(team, members, present, health, max_health, ctx) then return end
  if hop then
    if team.march and not team.found then
      local chunk = ctx.search(team, team.last_point)
      if chunk then team.found = chunk end
    end
    if next(hop.pending) and game.tick < hop.expires then return end
    finish_hop(team, ctx)
    if team.blocked then return end
  end
  chart(ctx, centroid(present))
  plan(team, present, ctx)
end

function M.on_command_completed(state, unit_number, result)
  local id = state.team_of and state.team_of[unit_number]
  local team = id and state.teams[id]
  if not team then return end
  if retreat.is_away(team, unit_number) then
    retreat.on_command_completed(team, unit_number, result)
    return
  end
  if team.withdraw then
    team.withdraw.resend[unit_number] = true
    return
  end
  local hop = team.hop
  if hop and hop.pending[unit_number] then
    hop.pending[unit_number] = nil
    if result == defines.behavior_result.fail and hop.front[unit_number] then hop.failed[unit_number] = true end
  end
end

function M.all_blocked(state)
  local any = false
  for id = 1, state.team_count do
    local team = state.teams[id]
    if team then
      any = true
      if not team.blocked then return false end
    end
  end
  return any
end

function M.target(state)
  for id = 1, state.team_count or 0 do
    local team = state.teams[id]
    if team and team.target then return team.target end
  end
  return nil
end

return M
