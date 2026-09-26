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
-- Also returns whether one of them died: it is gone for good and was not
-- away healing. A soldier moved to another division still exists.
local function roster(state, team, by_id)
  local out, kept, died = {}, {}, false
  for _, unit in ipairs(team.members) do
    local e = by_id[unit]
    if e then
      out[#out + 1], kept[#kept + 1] = e, unit
    else
      state.team_of[unit] = nil
      if not retreat.is_away(team, unit) then
        local entity = game.get_entity_by_unit_number(unit)
        if not (entity and entity.valid) then died = true end
      end
    end
  end
  if #kept ~= #team.members then team.members = kept end
  local hop = team.hop
  if hop then
    for unit in pairs(hop.pending) do if not by_id[unit] then hop.pending[unit] = nil end end
    for unit in pairs(hop.front) do if not by_id[unit] then hop.front[unit] = nil end end
  end
  if team.chase then
    for unit in pairs(team.chase) do if not by_id[unit] then team.chase[unit] = nil end end
  end
  return out, died
end

local function anchor(team)
  if team.withdraw then return team.withdraw.destination, retreat.arrival_radius(team.withdraw) end
  return team.hop and team.hop.point or team.last_point, 8
end

-- A soldier joining mid-hop walks to the team and takes a slot at the next
-- hop. It never enters `pending`, so a soldier still walking in cannot
-- stall the hop.
local function rejoin(team, soldier)
  local point, radius = anchor(team)
  if not point then return end
  go(soldier, point, radius)
  team.chase = team.chase or {}
  team.chase[soldier.unit_number] = game.tick + geometry.CHASE_RESEND
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

local function block(team, chunk, ttl)
  team.failed = team.failed or {}
  local count, oldest_key, oldest = 0, nil, math.huge
  for key, expiry in pairs(team.failed) do
    count = count + 1
    if expiry < oldest then oldest_key, oldest = key, expiry end
  end
  local key = chunk.x .. ":" .. chunk.y
  if not team.failed[key] and count >= geometry.FAILURE_LIMIT then team.failed[oldest_key] = nil end
  team.failed[key] = game.tick + (ttl or geometry.FAILURE_TTL)
end

local function chart(ctx, centre)
  local r = geometry.CHART_RADIUS
  ctx.force.chart(ctx.surface, {{x = centre.x - r, y = centre.y - r}, {x = centre.x + r, y = centre.y + r}})
end

-- Water blocks units, and the pathfinder is slow to give up on a
-- destination in it. Nil on an ungenerated chunk, which is not known.
local function wet(surface, p)
  if not surface.is_chunk_generated({x = math.floor(p.x / 32), y = math.floor(p.y / 32)}) then return nil end
  return surface.get_tile(p.x, p.y).collides_with("water_tile")
end

-- The hop moved onto dry ground: first across narrow water, then along the
-- shore, turning to the side the last shore hop took. Returns the point,
-- heading and reach, and whether the hop follows the shore; nil when every
-- candidate is wet.
local function dry_hop(surface, team, from, point, heading, reach)
  if not wet(surface, point) then return point, heading, reach, false end
  for _, p in ipairs(geometry.wade(point, heading)) do
    local w = wet(surface, p)
    if w == nil then break end
    if not w then return p, heading, false, false end
  end
  for _, d in ipairs(geometry.detours(from, heading, team.side or 1)) do
    if not wet(surface, d.point) then
      team.side = d.side
      return d.point, d.heading, false, true
    end
  end
end

-- The same rule for a hop whose front failed and a hop with no dry point.
-- Failed hops count in a row, so a success anywhere resets the count.
local function hop_failed(team, from, ttl)
  team.last_point = from
  team.detours = nil
  team.failures = (team.failures or 0) + 1
  if team.target then
    block(team, team.target, ttl)
    team.target = nil
    -- Every chunk in reach can lie across water or cliffs, and each stays
    -- uncharted. After MARCH_ANGLES failed hops in a row, march instead.
    if team.failures >= geometry.MARCH_ANGLES then team.march, team.failures = team.march or 1, nil end
  elseif team.failures >= geometry.MARCH_ANGLES then
    team.blocked = true
  else
    team.march = team.march % geometry.MARCH_ANGLES + 1
  end
end

-- Soldiers within STRAY tiles of `from`, and the rest.
local function split(present, from)
  local near, far, limit = {}, {}, geometry.STRAY * geometry.STRAY
  for _, e in ipairs(present) do
    if geometry.distance_squared(e.position, from) <= limit then near[#near + 1] = e else far[#far + 1] = e end
  end
  return near, far
end

-- Where the team stands: its last hop point, and the soldiers near it. When
-- every soldier is far from that point, the team gathers on the soldier
-- nearest to it instead.
local function core(team, present)
  local from = team.last_point or centroid(present)
  local near, far = split(present, from)
  if #near == 0 then
    local best, d
    for _, e in ipairs(present) do
      local here = geometry.distance_squared(e.position, from)
      if not best or here < d then best, d = e, here end
    end
    from = {x = best.position.x, y = best.position.y}
    near, far = split(present, from)
  end
  return from, near, far
end

-- Whether the team's target chunk is open water. An ungenerated target is
-- generated first, and checked on a later sweep. Each target is checked once.
local function at_sea(state, team, surface)
  if team.probe == true then return false end
  local t = team.target
  if not surface.is_chunk_generated(t) then
    if not team.probe then
      surface.request_to_generate_chunks({x = t.x * 32 + 16, y = t.y * 32 + 16}, 0)
      team.probe = "asked"
    end
    return false
  end
  team.probe = true
  local wet_tiles = 0
  for _, dx in ipairs(geometry.SEA_SAMPLES) do
    for _, dy in ipairs(geometry.SEA_SAMPLES) do
      if surface.get_tile(t.x * 32 + dx, t.y * 32 + dy).collides_with("water_tile") then wet_tiles = wet_tiles + 1 end
    end
  end
  if wet_tiles < geometry.SEA_WET then return false end
  if not state.sea or (state.sea_count or 0) >= geometry.SEA_LIMIT then state.sea, state.sea_count = {}, 0 end
  state.sea[geometry.chunk_key(t.x, t.y)] = game.tick + geometry.SEA_TTL
  state.sea_count = state.sea_count + 1
  return true
end

-- A straggler walks to the hop point. Its order is renewed only after it
-- completed or CHASE_RESEND passed, so a long path is not restarted every
-- hop.
local function chase(team, soldier, point)
  team.chase = team.chase or {}
  local unit = soldier.unit_number
  local renew = team.chase[unit]
  if renew and renew > game.tick then return end
  go(soldier, point, 8)
  team.chase[unit] = game.tick + geometry.CHASE_RESEND
end

-- Sends each soldier to its formation slot at `point`, facing `heading`.
-- Returns the hop's pending and front sets.
local function deploy(team, soldiers, point, heading)
  local entries = {}
  for i, e in ipairs(soldiers) do entries[i] = {id = e.unit_number, kind = assault.kind(e.name), position = e.position} end
  local slots = geometry.slots(entries, point, heading)
  local pending, front = {}, {}
  for _, e in ipairs(soldiers) do
    local unit = e.unit_number
    local slot = slots[unit]
    go(e, slot.position, slot.band == "rear" and 6 or 4)
    pending[unit] = true
    if slot.band == "front" then front[unit] = true end
    if team.chase then team.chase[unit] = nil end
  end
  return pending, front
end

-- Mutual aid. A team losing a fight falls back one hop, holds and calls for
-- help. When its call ends it gives up the target it was heading for, so it
-- goes around the fight instead of back into it. The numbers are in
-- scout_geometry.

-- Blocks the target for DANGER_TTL. A marching team turns to its next angle.
local function give_up(team)
  if team.target then
    block(team, team.target, geometry.DANGER_TTL)
    team.target, team.target_hops, team.probe = nil, nil, nil
  elseif team.march then
    team.march, team.found = team.march % geometry.MARCH_ANGLES + 1, nil
  end
end

-- Ends the team's help. The caller's call forgets its helper; with
-- `refused`, it also never asks this team again. The helper keeps its target
-- with a fresh hop count, since the help may have taken it far away.
local function end_help(state, team, refused)
  local caller = team.helping and state.teams[team.helping]
  local call = caller and caller.call
  if call and call.helper and state.teams[call.helper] == team then
    if refused then
      call.refused = call.refused or {}
      call.refused[call.helper] = true
    end
    call.helper = nil
  end
  team.helping, team.help_hops, team.detours, team.target_hops = nil, nil, nil, nil
end

-- Ends the team's call and its help; with `give`, it also gives up its
-- target.
local function stand_down(state, team, give)
  if team.call then
    team.call = nil
    if give then give_up(team) end
  end
  if team.helping then end_help(state, team, false) end
end

-- Records the ratio and its peak, and the tick of a death, which is answered
-- once soldiers are at hand. True when the ratio fell DISTRESS_DROP below the
-- peak. A withdrawing team is not measured; its peak starts again when the
-- withdraw ends.
local function detect(team, health, max_health, died)
  if team.withdraw then return false end
  if died then team.death = game.tick end
  if max_health <= 0 then return false end
  local ratio = health / max_health
  team.ratio = ratio
  team.peak = geometry.peak(team.peak, ratio, game.tick)
  return geometry.distressed(team.peak, ratio)
end

-- Opens a call, or refreshes the open one. A new call drops the hop in
-- progress without a failure and falls back to where the latest hop started,
-- facing the way the team advanced, so the front stands towards the threat.
-- With no such point, or one that is too near or too far, a team on the
-- move stops where its soldiers stand, and a team at rest holds where it is.
local function raise(state, team, present)
  local tick = game.tick
  if team.call then
    team.call.last_drop = tick
    return
  end
  -- A helper in trouble looks after itself first.
  if team.helping then end_help(state, team, false) end
  local here = team.last_point or centroid(present)
  local back, point, heading = team.back, nil, nil
  if back then
    local d = geometry.distance_squared(back.point, here)
    if d >= geometry.FALLBACK_MIN ^ 2 and d <= (2 * geometry.HOP) ^ 2 then point, heading = back.point, back.heading end
  end
  if not point and team.hop then point, heading = centroid(present), team.hop.heading end
  if point then
    local pending, front = deploy(team, present, point, heading)
    team.hop = {from = here, point = point, heading = heading, reach = true, pending = pending, front = front,
      size = #present, failed = {}, expires = tick + geometry.HOP_TIMEOUT, fallback = true}
    team.last_point = point
  else
    point = here
  end
  team.call = {point = {x = point.x, y = point.y}, last_drop = tick}
end

-- Picks a helper for an open call that has none, or whose helper is down to
-- one soldier at hand while the rest heal: the team nearest the call point
-- that is not blocked, withdrawing, calling or helping, had two or more
-- soldiers at hand and was healthy at its last sweep, stands within
-- HELP_RANGE and has not refused this call. Ties go to the lower id. At most
-- three teams are compared.
local function summon(state, id, call)
  local current = call.helper and state.teams[call.helper]
  if current and current.helping == id and (current.present or 0) >= 2 then return end
  call.helper = nil
  local best, best_d = nil, geometry.HELP_RANGE * geometry.HELP_RANGE
  for other = 1, state.team_count do
    local t = state.teams[other]
    if other ~= id and t and not t.blocked and not t.withdraw and not t.call and not t.helping
        and (t.present or 0) >= 2 and (t.ratio or 0) >= geometry.HELPER_HEALTH and t.last_point
        and not (call.refused and call.refused[other]) then
      local d = geometry.distance_squared(t.last_point, call.point)
      if d < best_d or (d == best_d and not best) then best, best_d = other, d end
    end
  end
  if best then
    call.helper = best
    state.teams[best].helping, state.teams[best].help_hops = id, 0
  end
end

-- A caller starts no hop while its call is open, and a helper none once it
-- stands on the call point.
local function holding(state, team)
  if team.call then return true end
  local caller = team.helping and state.teams[team.helping]
  local call = caller and caller.call
  return call ~= nil and team.last_point ~= nil and geometry.distance_squared(team.last_point, call.point) < 1
end

local function start_hop(state, team, present, ctx, from, near, far)
  -- A team that walks without charting its targets gives up.
  if (team.idle or 0) >= geometry.STALL_HOPS then
    team.blocked = true
    return
  end
  local helping, destination = team.helping, nil
  if helping then
    -- A help hop heads for the call point and never counts towards a target.
    if (team.help_hops or 0) >= geometry.HELP_HOPS then
      end_help(state, team, true)
      return
    end
    destination = state.teams[helping].call.point
  else
    -- Open water is skipped, not failed: the search then passes over it.
    if team.target and at_sea(state, team, ctx.surface) then
      team.target = nil
      return
    end
    if team.target then
      if (team.target_hops or 0) >= geometry.TARGET_HOPS then
        hop_failed(team, from, geometry.WATER_TTL)
        return
      end
      team.target_hops = (team.target_hops or 0) + 1
      destination = {x = team.target.x * 32 + 16, y = team.target.y * 32 + 16}
    else
      local a = geometry.march_angles(team.sectors)[team.march]
      destination = {x = from.x + math.cos(a) * geometry.MARCH_DISTANCE, y = from.y + math.sin(a) * geometry.MARCH_DISTANCE}
    end
  end
  local point, heading, reach = geometry.hop(from, destination)
  if not point then
    if not helping then team.target = nil end
    return
  end
  local shore
  point, heading, reach, shore = dry_hop(ctx.surface, team, from, point, heading, reach)
  if shore then team.detours = (team.detours or 0) + 1 elseif point then team.detours = nil end
  local limit = (helping or team.target) and geometry.DETOUR_LIMIT or geometry.MARCH_DETOURS
  if not point or (team.detours or 0) > limit then
    -- A helper that cannot get there gives up; that is no scouting failure.
    if helping then end_help(state, team, true) else hop_failed(team, from, geometry.WATER_TTL) end
    return
  end
  local pending, front = deploy(team, near, point, heading)
  for _, e in ipairs(far) do chase(team, e, point) end
  -- Where a call for help falls back to: the ground the team came from.
  team.back = {point = {x = from.x, y = from.y}, heading = heading}
  team.hop = {from = from, point = point, heading = heading, reach = reach, pending = pending, front = front,
    size = #near, failed = {}, expires = game.tick + geometry.HOP_TIMEOUT, help = helping}
  team.last_point = point
  if helping then
    team.help_hops = (team.help_hops or 0) + 1
  else
    team.idle = (team.idle or 0) + 1
  end
end

local function all_front_failed(hop)
  if not next(hop.front) then return false end
  for unit in pairs(hop.front) do
    if not hop.failed[unit] then return false end
  end
  return true
end

-- A hop is settled once its whole front, or half its soldiers, stand on
-- their slots. A soldier that stopped short, such as one caught on trees,
-- then holds the team for GRACE only, and gets a new slot at the next hop.
local function settled(hop)
  local size, left = hop.size or 0, 0
  for _ in pairs(hop.pending) do left = left + 1 end
  if (size - left) * 2 >= size then return true end
  for unit in pairs(hop.front) do
    if hop.pending[unit] then return false end
  end
  return true
end

-- Targets change only here, never in the middle of a hop.
local function finish_hop(state, team, ctx)
  local hop = team.hop
  team.hop = nil
  -- A fall-back hop leaves failures, targets and marches alone. A failed
  -- front holds where it stopped.
  if hop.fallback then return end
  -- A help hop leaves failures and targets alone too. A failed front short
  -- of the call point ends the help. On the point itself it is the crowd of
  -- the caller's soldiers, and the helper holds where it stopped. A hop for
  -- an earlier call just ends.
  if hop.help then
    if team.helping == hop.help and not hop.reach and all_front_failed(hop) then end_help(state, team, true) end
    return
  end
  if all_front_failed(hop) then
    hop_failed(team, hop.from)
    return
  end
  team.failures = nil
  if team.target then
    if hop.reach or ctx.force.is_chunk_charted(ctx.surface, team.target) then
      team.target, team.idle = nil, nil
    end
  elseif team.found then
    team.target, team.found, team.march, team.target_hops, team.probe = team.found, nil, nil, nil, nil
  end
end

-- Between hops: find a target (or keep marching) and start the next hop.
local function plan(state, team, present, ctx, from, near, far)
  if not team.helping and not team.target and not team.march then
    local chunk, empty = ctx.search(team, from)
    if chunk then
      team.target, team.target_hops, team.probe = chunk, nil, nil
    elseif empty then
      team.march, team.failures = 1, nil
    else
      return -- budget spent; the search resumes next sweep
    end
  end
  start_hop(state, team, present, ctx, from, near, far)
end

local function has_front(members)
  for _, e in ipairs(members) do
    if assault.kind(e.name) ~= "siege" then return true end
  end
  return false
end

-- A team merges into the nearest team that is not blocked when it is down
-- to one living soldier, has no front soldier left to screen its siege tanks, or is
-- blocked. The host takes over the sector unless it is blocked, takes over
-- its convoys, and never re-commands its own soldiers. Returns true when the
-- team is gone.
local function merge_check(state, id, team, members, present)
  local keep
  if team.blocked then
    keep = false
  elseif #members <= 1 or not has_front(members) then
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
  -- The newcomers change the host's health ratio, which is no fight: the
  -- host measures its distress from a fresh peak.
  host.peak = nil
  if keep then
    for _, r in ipairs(team.sectors) do host.sectors[#host.sectors + 1] = {from = r.from, to = r.to} end
  end
  retreat.absorb(host, team)
  for _, e in ipairs(present) do rejoin(host, e) end
  state.teams[id] = nil
  return true
end
-- The nearest barracks or headquarters, as retreat.barracks_in_reach lists
-- them, and the distance to it.
local function nearest_depot(ctx, position)
  local list = retreat.barracks_in_reach({force = ctx.force, surface_index = ctx.surface.index})
  local i, distance = retreat.nearest_barracks(list, position, ctx.cfg.range)
  if i then return list[i], distance end
end

local function send_home(present, w)
  for _, e in ipairs(present) do go(e, w.destination, retreat.arrival_radius(w)) end
end

local function end_withdraw(team, members, ctx, failed)
  team.withdraw, team.last_point = nil, nil
  team.formed = #members
  -- The healed team measures its distress from a fresh peak.
  team.peak, team.death = nil, nil
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
    local depot, distance = nearest_depot(ctx, centroid(present))
    if not depot then
      end_withdraw(team, members, ctx, true)
      return
    end
    w.barracks, w.destination, w.mobile = depot.entity, depot.position, depot.mobile
    w.best, w.progress = distance, game.tick
    send_home(present, w)
    return
  end
  if healed(present, ctx.cfg.rejoin) then
    end_withdraw(team, members, ctx, false)
    return
  end
  -- A moved headquarters sends every soldier after it that is not already
  -- there, through the resend check below.
  if retreat.follow(w) then
    for _, e in ipairs(present) do w.resend[e.unit_number] = true end
  end
  local closest
  for _, e in ipairs(present) do
    local d = geometry.distance(e.position, w.destination)
    if not closest or d < closest then closest = d end
  end
  if closest <= retreat.heal_radius(w) or closest < w.best - 1 then w.best, w.progress = closest, game.tick end
  if game.tick - w.progress >= retreat.TIMEOUT then
    end_withdraw(team, members, ctx, true)
    return
  end
  -- Only after a completion: re-sending a soldier that is still walking
  -- would restart its pathfinding every sweep.
  local arrival = retreat.arrival_radius(w)
  local limit = (arrival + 2) ^ 2
  for unit in pairs(w.resend) do
    local e = ctx.by_id[unit]
    if e and geometry.distance_squared(e.position, w.destination) > limit then go(e, w.destination, arrival) end
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
  local depot, distance = nearest_depot(ctx, centroid(present))
  if not depot then
    team.withdraw_after = game.tick + geometry.NO_BARRACKS_RETRY
    return false
  end
  team.hop = nil
  team.withdraw = {barracks = depot.entity, destination = depot.position, mobile = depot.mobile,
    best = distance, progress = game.tick, resend = {}}
  send_home(present, team.withdraw)
  return true
end

function M.sweep(state, id, ctx)
  local team = state.teams[id]
  local members, died = roster(state, team, ctx.by_id)
  for key, expiry in pairs(team.failed or {}) do
    if expiry <= game.tick then team.failed[key] = nil end
  end
  local cfg = ctx.cfg
  local rejoined = false
  local present, _, health, max_health = retreat.sweep(team, members, {
    force = ctx.force, surface_index = state.surface_index,
    retreat = team.withdraw and 0 or cfg.retreat, rejoin = cfg.rejoin, range = cfg.range,
    on_rejoin = function(soldier) rejoined = true; rejoin(team, soldier) end,
  })
  team.present = #present
  -- A soldier back from a depot, healed or not, changes the ratio without a
  -- fight: the team measures from a fresh peak.
  if rejoined then team.peak = nil end
  local hop = team.hop
  if hop then
    for unit in pairs(hop.pending) do if retreat.is_away(team, unit) then hop.pending[unit] = nil end end
    for unit in pairs(hop.front) do if retreat.is_away(team, unit) then hop.front[unit] = nil end end
  end
  if merge_check(state, id, team, members, present) then return end
  -- A blocked team with no host left waits for the division to stop.
  if team.blocked then
    stand_down(state, team, false)
    return
  end
  local distressed = detect(team, health, max_health, died)
  -- Before the wait below, so a call ends while every soldier is away.
  if team.call and game.tick - team.call.last_drop >= geometry.QUIET then stand_down(state, team, true) end
  -- A lone soldier waits for the rest of its team to come back from healing.
  if #present == 0 or (#present == 1 and #members > 1) then return end
  if withdraw(team, members, present, health, max_health, ctx) then
    stand_down(state, team, true)
    return
  end
  -- A death is answered now that soldiers are at hand, if it is recent.
  local death = team.death
  team.death = nil
  if distressed or (death and game.tick - death <= geometry.DISTRESS_WINDOW) then raise(state, team, present) end
  if team.call then summon(state, id, team.call) end
  if team.helping then
    local caller = state.teams[team.helping]
    local call = caller and caller.call
    if not (call and call.helper == id) then
      end_help(state, team, false)
    elseif team.hop and not team.hop.fallback and team.hop.help ~= team.helping then
      -- An ordinary hop, or one towards an earlier call, gives way to the
      -- help; that is no failure.
      team.hop = nil
    end
  end
  hop = team.hop
  if hop then
    if team.march and not team.found and not (team.call or team.helping) then
      local chunk = ctx.search(team, team.last_point)
      if chunk then team.found = chunk end
    end
    if hop.expires > game.tick + geometry.GRACE and settled(hop) then
      hop.expires = game.tick + geometry.GRACE
    end
    if next(hop.pending) and game.tick < hop.expires then return end
    finish_hop(state, team, ctx)
    if team.blocked then return end
  end
  if holding(state, team) then return end
  local from, near, far = core(team, present)
  chart(ctx, centroid(near))
  plan(state, team, present, ctx, from, near, far)
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
  elseif team.chase and team.chase[unit_number] then
    -- A straggler that arrived or gave up is sent again at the next hop.
    team.chase[unit_number] = nil
  end
end

function M.count(state)
  local count = 0
  for id = 1, state.team_count do
    if state.teams[id] then count = count + 1 end
  end
  return count
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
