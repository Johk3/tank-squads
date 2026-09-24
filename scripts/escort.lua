local combat = require("scripts.combat")
local divisions = require("scripts.divisions")
local patrol = require("scripts.patrol")
local geometry = require("scripts.escort_geometry")
local names = require("scripts.names")
local scout = require("scripts.scout")
local render = require("scripts.render")
local config = require("scripts.config")
local retreat = require("scripts.retreat")
local assault = require("scripts.assault")

local M = {}

-- Ring, threat zone, band and anchor step are map settings; see
-- scripts/config.lua. M.tick() reads them once per sweep.
M.SETTLE_DISTANCE = 16
M.SETTLE_SWEEPS = 5
-- Beyond this the division holds and waits instead of walking across the map.
M.LEASH = 1000
M.LEG_TIMEOUT = 3 * 3600

-- divisions.cached() is a same-tick cache: it is invalidated wherever
-- membership changes (divisions.lua), but a caller must still never trust a
-- cached entry blindly, since forget()/reinforcements.join() can be called
-- from event handlers this same function does not control the ordering of.
-- e.valid guards against a stale reference to a since-destroyed entity, which
-- would otherwise hard-error on the property read below.
local function members_on_surface(player_index, n, surface_index)
  local out = {}
  for _, e in ipairs(divisions.cached(player_index, n)) do
    -- The unarmed headquarters takes no part in escort formations.
    if e.valid and e.surface_index == surface_index and e.name ~= names.headquarters then out[#out + 1] = e end
  end
  return out
end

local function halt(members)
  for _, soldier in ipairs(members) do
    combat.set_command(soldier, {type = defines.command.stop, distraction = defines.distraction.by_enemy})
  end
end

function M.start(owner_index, n, ward_index, formation)
  if type(n) ~= "number" or n % 1 ~= 0 or n < 1 or n > names.max_division then return nil, "division" end
  if formation ~= "defensive" and formation ~= "offensive" then return nil, "formation" end
  local owner, ward = game.get_player(owner_index), game.get_player(ward_index)
  if not (owner and ward and ward.force == owner.force) then return nil, "ward" end
  -- The unarmed headquarters takes no part and keeps its last order, as in
  -- scouting. A division of nothing else cannot escort.
  local members = {}
  for _, e in ipairs(divisions.get(owner_index, n)) do
    if e.name ~= names.headquarters then members[#members + 1] = e end
  end
  if #members == 0 then return nil, "empty" end
  local record = divisions.record(owner_index, n)
  local previous = record.escort
  patrol.clear(owner_index, n)
  divisions.end_escort(record)
  record.mode, record.order, record.scout = "escort", nil, nil
  -- The escort only commands soldiers once its ward is available, so cancel
  -- any earlier order now instead of letting it run on while waiting.
  halt(members)
  local state = {ward = ward_index, formation = formation, surface_index = members[1].surface_index,
    history = {}, available = false}
  -- Switching formation for the same ward keeps its anchor, so the division
  -- does not wait five more sweeps for a ward who is already standing still.
  -- `state.pending` is a one-sweep transient, not part of the persisted state
  -- shape documented in the design spec: it tells the very next M.track()
  -- call to report `moved = true` even though the anchor itself did not move
  -- this sweep, so the freshly switched formation reslots/rechecks legs
  -- immediately against the kept anchor instead of waiting for a real anchor
  -- move. M.track() always clears it after reading it (see below), so it
  -- never survives past that one sweep.
  if previous and previous.ward == ward_index and previous.surface_index == state.surface_index then
    state.anchor, state.history = previous.anchor, previous.history
    state.pending = state.anchor ~= nil
  end
  record.escort = state
  return true
end

function M.stop(owner_index, n)
  local record = divisions.record(owner_index, n)
  if record.mode ~= "escort" then return false end
  local surface_index = record.escort and record.escort.surface_index
  divisions.end_escort(record)
  if surface_index then halt(members_on_surface(owner_index, n, surface_index)) end
  return true
end

function M.dismiss(ward_index, owner_index, n)
  local record = divisions.record(owner_index, n)
  if not (record.escort and record.escort.ward == ward_index) then return false end
  M.stop(owner_index, n)
  local owner, ward = game.get_player(owner_index), game.get_player(ward_index)
  if owner and ward_index ~= owner_index then
    owner.print({"tank-squads.escort-dismissed", n, ward and ward.name or "?"})
  end
  return true
end

local function each_escort(fn)
  for owner_index, state in pairs(storage.divisions or {}) do
    for n, record in pairs(state.slots) do
      if record.mode == "escort" and record.escort then fn(owner_index, n, record) end
    end
  end
end

function M.forget_ward(player_index)
  local ended = {}
  each_escort(function(owner_index, n, record)
    if record.escort.ward == player_index then ended[#ended + 1] = {owner_index, n} end
  end)
  for _, pair in ipairs(ended) do
    M.stop(pair[1], pair[2])
    local owner = game.get_player(pair[1])
    if owner and pair[1] ~= player_index then owner.print({"tank-squads.escort-ended", pair[2]}) end
  end
end

-- Returns the ward's character when the ward is available (same surface,
-- inside the leash), and whether the anchor moved this sweep. ward is the
-- player object drive() already fetched this sweep to validate the escort.
function M.track(state, members, ward, step)
  local character = ward and ward.character
  if not (character and character.valid and character.surface_index == state.surface_index) then
    state.history, state.available = {}, false
    return nil, false
  end
  local position = character.position
  geometry.push(state.history, position, M.SETTLE_SWEEPS)
  local reference = state.anchor or geometry.centroid(members)
  if geometry.distance(position, reference) > M.LEASH then
    state.available = false
    return nil, false
  end
  state.available = true
  local moved = state.pending or false
  state.pending = nil
  -- The anchor only moves once the ward has settled more than `step` tiles
  -- from it, so a ward pottering around a build never triggers pathfinding.
  if geometry.settled(state.history, M.SETTLE_SWEEPS, M.SETTLE_DISTANCE)
      and (not state.anchor or geometry.distance(position, state.anchor) > step) then
    state.anchor = {x = position.x, y = position.y}
    moved = true
  end
  return character, moved
end

local formations = {}

local function send_to_slot(state, soldier)
  local angle = state.slots and state.slots[soldier.unit_number]
  -- state.ring is the radius these slots were assigned for (M.reslot). A
  -- 0.7.x escort has none until its first re-space after the upgrade.
  if not (angle and state.anchor and state.ring) then return end
  combat.set_command(soldier, {
    type = defines.command.go_to_location,
    destination = geometry.slot_position(state.anchor, state.ring, angle),
    radius = 4,
    distraction = defines.distraction.by_enemy,
  })
end

function M.reslot(state, members, ring)
  state.response_dirty = true
  if not state.anchor then return end
  state.ring = ring
  state.slots = geometry.assign_slots(members, state.anchor, ring)
  for _, soldier in ipairs(members) do
    if not (state.responders and state.responders[soldier.unit_number] ~= nil) then send_to_slot(state, soldier) end
  end
end

-- Gathered once per M.tick(), not once per escort or per defensive escort's
-- threats() call: iterating game.players is bounded by the server's player
-- count (connected or not), which is cheap, and gives every defensive escort
-- the same list without re-touching the engine. This replaces an earlier,
-- wrong gate that skipped the whole character scan whenever
-- #game.connected_players <= 1 -- that heuristic silently missed real PvP
-- threats (e.g. the only connected player being the one under attack, or a
-- hostile character still standing while its controlling player is
-- offline). Scripted NPC characters (entities of type "character" spawned by
-- other means, not owned by a game.players entry) are deliberately not
-- considered: only a human player's own character counts as a threat here,
-- matching the spec's "enemy characters" as PvP wards on a hostile force.
local function player_characters()
  local out = {}
  for _, p in pairs(game.players) do
    if p.character and p.character.valid then out[#out + 1] = p.character end
  end
  return out
end

-- The threat zone is the circle around the ward joined with the same circle
-- around the ring's centre, so an enemy inside the formation is fought even
-- while the ward walks off, is dead, or is out of reach. Either centre may be
-- nil. Close centres share one unit-grid query over both circles' bounding
-- box; distant ones get one query each, and a unit both return is read once.
-- The pre-collected player characters (see player_characters() above) are
-- filtered to this surface, force and the circles. positions[i] is
-- found[i]'s position, read once for the whole sweep.
local function threats(surface, force, ward, anchor, characters, radius)
  local r2 = radius * radius
  local found, by_id, positions = {}, {}, {}
  local function inside(position)
    return (ward and geometry.distance_squared(position, ward) <= r2)
      or (anchor and geometry.distance_squared(position, anchor) <= r2) or false
  end
  local areas, seen
  local a, b = ward or anchor, anchor or ward
  if geometry.distance_squared(a, b) <= r2 then
    areas = {{{math.min(a.x, b.x) - radius, math.min(a.y, b.y) - radius},
      {math.max(a.x, b.x) + radius, math.max(a.y, b.y) + radius}}}
  else
    areas, seen = {{{a.x - radius, a.y - radius}, {a.x + radius, a.y + radius}},
      {{b.x - radius, b.y - radius}, {b.x + radius, b.y + radius}}}, {}
  end
  for _, area in ipairs(areas) do
    for _, e in pairs(surface.find_units{area = area, force = force, condition = "enemy"}) do
      local id = seen and e.unit_number
      if not (id and seen[id]) then
        if id then seen[id] = true end
        local position = e.position
        if inside(position) then
          found[#found + 1] = e
          positions[#found] = position
          by_id[id or e.unit_number] = true
        end
      end
    end
  end
  for _, c in ipairs(characters) do
    if c.surface_index == surface.index and c.force ~= force and force.is_enemy(c.force) then
      local position = c.position
      if inside(position) then
        found[#found + 1] = c
        positions[#found] = position
        by_id[c.unit_number] = true
      end
    end
  end
  return found, by_id, positions
end

local function recall_responders(state, members)
  if not state.responders then return end
  local responders = state.responders
  state.responders = nil
  for _, soldier in ipairs(members) do
    if responders[soldier.unit_number] ~= nil then send_to_slot(state, soldier) end
  end
end

function formations.defensive(state, members, character, moved, characters, cfg)
  if moved then M.reslot(state, members, cfg.ring) end
  -- Without a ward in reach the division still holds its ring, so it keeps
  -- clearing the ring's zone; only an escort that never attached has none.
  local ward_position = character and character.position
  local centre = ward_position or state.anchor
  if not centre then recall_responders(state, members); return end
  local found, in_zone, positions = threats(members[1].surface, members[1].force, ward_position, state.anchor,
    characters, cfg.detect)
  if #found == 0 then recall_responders(state, members); return end
  if not state.responders or state.response_dirty then
    -- The threat closest to the ward (or, without one, to the ring's centre)
    -- decides which half of the division responds.
    local primary = positions[geometry.nearest_point(positions, centre)]
    local kept, candidates, count = {}, {}, 0
    for _, soldier in ipairs(members) do
      local id = soldier.unit_number
      local target = state.responders and state.responders[id]
      if target ~= nil then
        kept[id], count = target, count + 1
      else
        candidates[#candidates + 1] = soldier
      end
    end
    local wanted = math.ceil(#members / 2)
    if count < wanted then
      for _, soldier in ipairs(geometry.nearest_half(candidates, primary)) do
        kept[soldier.unit_number] = false
        count = count + 1
        if count >= wanted then break end
      end
    end
    state.responders, state.response_dirty = kept, nil
  end
  for _, soldier in ipairs(members) do
    local target = state.responders[soldier.unit_number]
    if target ~= nil and not (target and target.valid and in_zone[target.unit_number]) then
      target = found[geometry.nearest_point(positions, soldier.position)]
      state.responders[soldier.unit_number] = target
      combat.set_command(soldier, {type = defines.command.attack, target = target,
        distraction = defines.distraction.by_enemy})
    end
  end
end

-- Worms are "turret"; spawners are "unit-spawner". Characters cover PvP.
M.TARGET_TYPES = {"unit", "unit-spawner", "turret", "ammo-turret", "electric-turret",
  "fluid-turret", "artillery-turret", "character"}

local function chunk_key(position)
  return math.floor(position.x / 32) .. ":" .. math.floor(position.y / 32)
end

local function blocked(state, position)
  local expiry = state.failed and state.failed[chunk_key(position)]
  return expiry and expiry > game.tick
end

local function block(state, position)
  state.failed = state.failed or {}
  local count, oldest_key, oldest = 0, nil, math.huge
  for key, expiry in pairs(state.failed) do
    count = count + 1
    if expiry < oldest then oldest_key, oldest = key, expiry end
  end
  local key = chunk_key(position)
  if not state.failed[key] and count >= scout.FAILURE_LIMIT then state.failed[oldest_key] = nil end
  state.failed[key] = game.tick + scout.FAILURE_TTL
end

local function enemy_forces(force)
  local out = {}
  for _, other in pairs(game.forces) do
    if other ~= force and force.is_enemy(other) then out[#out + 1] = other end
  end
  return out
end

-- Runs once per leg, not per sweep. Legs last tens of seconds, so even a band
-- full of nests costs one bounded scan every leg. Each candidate's position
-- is read once, and the failure list is only consulted for a candidate that
-- would become the new best, so most results build no chunk key.
local function pick_target(state, surface, forces, from, band_min, band_max)
  if #forces == 0 then return nil end
  local min2 = band_min * band_min
  local best, best_d = nil, math.huge
  local found = surface.find_entities_filtered{position = state.anchor, radius = band_max,
    type = M.TARGET_TYPES, force = forces}
  for _, e in pairs(found) do
    local position = e.position
    if geometry.distance_squared(position, state.anchor) >= min2 then
      local d = geometry.distance_squared(position, from)
      if d < best_d and not blocked(state, position) then best, best_d = e, d end
    end
  end
  return best
end

function formations.offensive(state, members, character, moved, characters, cfg)
  -- Charts every sweep, same as scout mode, even before the first attach
  -- (state.anchor nil): otherwise an offensive escort waiting on its ward to
  -- settle would sit in the fog for up to SETTLE_SWEEPS sweeps, revealing
  -- nothing.
  local surface, force = members[1].surface, members[1].force
  local origin = geometry.centroid(members)
  local r = scout.CHART_RADIUS
  force.chart(surface, {{x = origin.x - r, y = origin.y - r}, {x = origin.x + r, y = origin.y + r}})
  if not state.anchor then return end
  for key, expiry in pairs(state.failed or {}) do
    if expiry <= game.tick then state.failed[key] = nil end
  end
  -- A running nest assault replaces legs until the nest falls or the
  -- assault gives up; the next sweep then picks a normal leg.
  if state.assault then
    local result = assault.tick(state.assault, members)
    -- A nest often spans chunks: block every one, or the next leg would
    -- pick a structure in the neighbouring chunk and start again.
    if result == "failed" then
      for _, s in ipairs(state.assault.structures) do block(state, s.position) end
    end
    if result then state.assault = nil end
    return
  end
  if state.leg and state.leg.expires > game.tick then return end
  local forces = enemy_forces(force)
  local target = pick_target(state, surface, forces, origin, cfg.band_min, cfg.band_max)
  if target and assault.try_start(state, members, target, forces) then return end
  local command
  if target then
    command = {type = defines.command.attack_area, destination = {x = target.position.x, y = target.position.y},
      radius = 16, distraction = defines.distraction.by_enemy}
  else
    command = {type = defines.command.go_to_location,
      destination = geometry.band_point(state.anchor, cfg.band_min, cfg.band_max, math.random),
      radius = 8, distraction = defines.distraction.by_enemy}
  end
  state.leg = {destination = command.destination, command = command,
    leader = members[1].unit_number, expires = game.tick + M.LEG_TIMEOUT}
  for _, soldier in ipairs(members) do combat.set_command(soldier, command) end
end

M.formations = formations

local function drive(owner_index, n, record, characters, cfg, shape)
  local state = record.escort
  local owner, ward = game.get_player(owner_index), game.get_player(state.ward)
  if not (owner and ward and ward.force == owner.force) then
    M.stop(owner_index, n)
    if owner then owner.print({"tank-squads.escort-ended", n}) end
    return
  end
  -- divisions.get may have cleared an emptied, unreinforced division.
  if record.mode ~= "escort" then return end
  local members = members_on_surface(owner_index, n, state.surface_index)
  -- A reinforced division can be briefly empty (all members lost, barracks
  -- still catching up), or have every member away healing: skip driving it.
  -- M.wards() still reports it, so the ward panel keeps its dismiss entry.
  if #members > 0 then
    -- Retreats run before the ward check, so soldiers heal while the ward is
    -- away too. Away soldiers take no part in the formation.
    local present, retreated = retreat.sweep(state, members, {
      force = members[1].force, surface_index = state.surface_index,
      retreat = cfg.retreat, rejoin = cfg.rejoin, range = cfg.range,
      -- A convoy never takes its guards from the screen of a nest assault.
      responders = state.responders or (state.assault and state.assault.screen),
      leader = state.leg and state.leg.leader,
      on_rejoin = function(soldier)
        if state.assault then
          assault.join(state.assault, soldier)
        elseif state.formation == "offensive" and state.leg then
          combat.set_command(soldier, state.leg.command)
        end
      end,
    })
    if retreated then state.members_dirty = true end
    if #present > 0 then
      local character, moved = M.track(state, present, ward, cfg.step)
      if state.members_dirty then
        state.members_dirty = nil
        if state.formation == "defensive" then
          moved = true
        elseif state.leg then
          local alive = false
          for _, e in ipairs(present) do if e.unit_number == state.leg.leader then alive = true end end
          -- A death completion may arrive after ownership was removed, a
          -- transferred leader's completion no longer reaches this escort,
          -- and an away leader never completes the leg. Survivors may
          -- already have finished. Start the next leg this sweep.
          if not alive then state.leg = nil end
        end
      end
      formations[state.formation](state, present, character, moved, characters, cfg)
      if M.on_driven then M.on_driven(owner_index, n, record, character, shape) end
    end
  end
end

-- Every running escort by ward, for the ward panels. Reads saved state only,
-- so it covers escorts swept in other phases without touching entities. A
-- reinforced escort that is briefly empty, or has every member away
-- healing, keeps its entry, so the ward can still dismiss it.
function M.wards()
  local wards = {}
  each_escort(function(owner_index, n, record)
    local state = record.escort
    wards[state.ward] = wards[state.ward] or {}
    table.insert(wards[state.ward], {owner = owner_index, n = n, formation = state.formation, available = state.available})
  end)
  return wards
end

-- Drives the escorts in one sweep phase (every escort when phase is nil).
-- The ward panels need M.wards() only once per second; control.lua builds
-- it on phase 0 rather than on every slice.
function M.tick(phase)
  local jobs = {}
  each_escort(function(owner_index, n, record)
    if divisions.in_phase(owner_index, n, phase) then jobs[#jobs + 1] = {owner_index, n, record} end
  end)
  if #jobs > 0 then
    -- One settings read per sweep, shared by every escort.
    local cfg = config.escort()
    local shape = {ring = cfg.ring, band = {cfg.band_min, cfg.band_max}}
    local characters = player_characters()
    for _, job in ipairs(jobs) do
      if job[3].mode == "escort" then drive(job[1], job[2], job[3], characters, cfg, shape) end
    end
  end
end

-- Only the leader's completion ends a leg; the next leg is chosen on the
-- following sweep, so a whole division finishing together costs one scan.
function M.on_command_completed(unit_number, result)
  local _, _, record = divisions.owner(unit_number)
  if not record or record.mode ~= "escort" or not record.escort then return false end
  local state = record.escort
  -- Arriving at the barracks is not a formation event.
  if retreat.is_away(state, unit_number) then
    retreat.on_command_completed(state, unit_number, result)
    return true
  end
  if state.assault then assault.on_command_completed(state.assault, unit_number, result) end
  if state.leg and state.leg.leader == unit_number then
    if result == defines.behavior_result.fail and state.leg.command.type == defines.command.attack_area then
      block(state, state.leg.destination)
    end
    state.leg = nil
  elseif state.responders and state.responders[unit_number] then
    state.responders[unit_number] = false
  end
  return true
end

M.on_driven = function(owner_index, n, record, character, shape)
  render.escort(owner_index, n, record, character, shape)
end

-- A changed escort setting (or a mod upgrade) takes effect on the next
-- sweep: defensive rings re-space onto the current radius, and offensive
-- escorts pick their next leg inside the current band.
function M.on_settings_changed()
  each_escort(function(_, _, record)
    local state = record.escort
    if state.formation == "defensive" then state.members_dirty = true else state.leg = nil end
  end)
end

-- A recruit from a linked barracks. Recruits arrive in bursts, so a defensive
-- ring re-spaces once on the next sweep instead of once per recruit.
function M.join(record, soldier)
  local state = record.mode == "escort" and record.escort
  if not state or soldier.surface_index ~= state.surface_index or soldier.name == names.headquarters then return false end
  if state.formation == "defensive" then
    state.members_dirty = true
  elseif state.assault then
    assault.join(state.assault, soldier)
  elseif state.leg then
    combat.set_command(soldier, state.leg.command)
  end
  return true
end

-- Deaths, arrivals and transfers re-space the ring, or end an offensive leg
-- whose leader left, on the next sweep (see drive()).
divisions.listen_members_changed(function(owner_index, n)
  local record = divisions.record(owner_index, n)
  local state = record.mode == "escort" and record.escort
  if state then state.members_dirty = true end
end)

return M
