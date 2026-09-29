-- Engineer escort. Divisions a player marks (mode "engineer") form the
-- force's pool; their armed soldiers are dealt into one team per active
-- constructor, at most CAP each. A team runs the escort's defensive
-- formation with its constructor as ward, on a tighter ring, and heals
-- through retreat.lua like any escort. The split runs once per second and
-- only when the pool or the constructors changed.
local combat = require('scripts.combat')
local divisions = require('scripts.divisions')
local patrol = require('scripts.patrol')
local escort = require('scripts.escort')
local retreat = require('scripts.retreat')
local config = require('scripts.config')
local names = require('scripts.names')
local loans = require('scripts.engineers.loans')
local threat = require('scripts.engineers.threat')
local state = require('scripts.engineers.state')

local M = {}

M.CAP = 8
-- A team rings its constructor closer than a player's escort, and meets
-- threats within the constructor's own pause radius.
M.RING, M.DETECT, M.STEP = 24, 80, 16
local FORMATION = {ring = M.RING, detect = M.DETECT}

local function halt(soldier)
  combat.set_command(soldier, {type = defines.command.stop, distraction = defines.distraction.by_enemy})
end

-- Deals soldiers to constructors. soldiers = {{id, strength}}, constructors
-- = sorted ids, previous = the last team of each soldier. Team sizes differ
-- by at most one. A soldier stays in its team while the team has room; the
-- rest are dealt round-robin, strongest first.
function M.split(soldiers, constructors, previous, cap)
  local teams, room, count = {}, {}, #constructors
  for _, c in ipairs(constructors) do teams[c] = {} end
  if count == 0 then return teams end
  local total = math.min(#soldiers, cap * count)
  local base, extra = math.floor(total / count), total % count
  for i, c in ipairs(constructors) do room[c] = base + (i <= extra and 1 or 0) end
  local sorted = {}
  for i, s in ipairs(soldiers) do sorted[i] = s end
  table.sort(sorted, function(a, b)
    if a.strength ~= b.strength then return a.strength > b.strength end
    return a.id < b.id
  end)
  local rest = {}
  for _, s in ipairs(sorted) do
    local c = previous[s.id]
    if c and room[c] and room[c] > 0 then
      local team = teams[c]
      team[#team + 1], room[c] = s.id, room[c] - 1
    else
      rest[#rest + 1] = s
    end
  end
  local i = 0
  for _, s in ipairs(rest) do
    for _ = 1, count do
      i = i % count + 1
      local c = constructors[i]
      if room[c] > 0 then
        local team = teams[c]
        team[#team + 1], room[c] = s.id, room[c] - 1
        break
      end
    end
  end
  return teams
end

-- Marks or unmarks division n as engineer escort. Joining ends its patrol,
-- escort, scouting or order; either way its soldiers stop where they are.
-- Returns false for an empty division or a bad number.
function M.set_pool(player_index, n, value)
  if type(n) ~= 'number' or n % 1 ~= 0 or n < 1 or n > names.max_division then return false end
  if not game.get_player(player_index) then return false end
  local members = divisions.get(player_index, n)
  local record = divisions.record(player_index, n)
  if value then
    if #members == 0 then return false end
    if record.mode == 'engineer' then return true end
    patrol.clear(player_index, n)
    divisions.end_escort(record)
    record.mode, record.order, record.scout = 'engineer', nil, nil
  else
    if record.mode ~= 'engineer' then return true end
    record.mode = 'idle'
  end
  for _, soldier in ipairs(members) do halt(soldier) end
  state.get().dirty = true
  return true
end

local function new_state(surface_index)
  return {formation = 'defensive', surface_index = surface_index, history = {}, available = false}
end

-- Active constructors per force, sorted by unit number. A constructor away
-- healing has no team.
local function active(s)
  local ids = {}
  for id in pairs(s.constructors) do ids[#ids + 1] = id end
  table.sort(ids)
  local by_force = {}
  for _, id in ipairs(ids) do
    local record = s.constructors[id]
    if record.entity.valid and record.state ~= 'healing' then
      local list = by_force[record.force_index] or {}
      by_force[record.force_index] = list
      list[#list + 1] = id
    end
  end
  return by_force
end

-- The armed soldiers of the force's pool divisions, by unit number.
local function pool(force_index)
  local out = {}
  local veterans = storage.veterans or {}
  for player_index, pstate in pairs(storage.divisions or {}) do
    local player = game.get_player(player_index)
    if player and player.force_index == force_index then
      for n = 1, names.max_division do
        local record = pstate.slots[n]
        if record and record.mode == 'engineer' then
          for _, e in ipairs(divisions.cached(player_index, n)) do
            if e.valid and names.soldier_set[e.name] then
              local veteran = veterans[e.unit_number]
              out[#out + 1] = {id = e.unit_number, strength = threat.strength(e.name, veteran and veteran.rank)}
            end
          end
        end
      end
    end
  end
  table.sort(out, function(a, b) return a.id < b.id end)
  return out
end

-- A soldier dealt out of its team stops where it is while its division is
-- still in the pool. One that left the pool keeps the player's order.
local function spare(id)
  local _, _, record = divisions.owner(id)
  if not (record and record.mode == 'engineer') then return end
  local e = game.get_entity_by_unit_number(id)
  if e and e.valid then halt(e) end
end

local function apply(s, split)
  for c, ids in pairs(split) do
    local record = s.constructors[c]
    local team = s.teams[c]
    if not team then
      team = {members = {}, state = new_state(record.surface_index), present = 0}
      s.teams[c] = team
    end
    local keep = {}
    for _, id in ipairs(ids) do keep[id] = true end
    for _, id in ipairs(team.members) do
      if not keep[id] and s.team_of[id] == c then
        s.team_of[id] = nil
        spare(id)
      end
    end
    team.members = ids
    for _, id in ipairs(ids) do s.team_of[id] = c end
    team.state.members_dirty = true
  end
end

local function dissolve(s, c)
  local team = s.teams[c]
  s.teams[c] = nil
  for _, id in ipairs(team.members) do
    if s.team_of[id] == c then
      s.team_of[id] = nil
      spare(id)
    end
  end
end

-- Deals the pool again when it or the constructors changed. Runs once per
-- second, only while constructors exist, and after the last one is gone.
function M.refresh()
  local s = state.peek()
  if not s then return end
  local by_force, seen = active(s), {}
  for force_index, constructors in pairs(by_force) do
    local soldiers = pool(force_index)
    local parts = {}
    for _, c in ipairs(constructors) do parts[#parts + 1] = c; seen[c] = true end
    parts[#parts + 1] = '|'
    for _, x in ipairs(soldiers) do parts[#parts + 1] = x.id end
    local signature = table.concat(parts, ',')
    if s.dirty or s.signatures[force_index] ~= signature then
      s.signatures[force_index] = signature
      apply(s, M.split(soldiers, constructors, s.team_of, M.CAP))
    end
  end
  local gone = {}
  for c in pairs(s.teams) do if not seen[c] then gone[#gone + 1] = c end end
  for _, c in ipairs(gone) do dissolve(s, c) end
  for force_index in pairs(s.signatures) do
    if not by_force[force_index] then s.signatures[force_index] = nil end
  end
  s.dirty = false
end

local function drive(s, c, team, cfg, characters)
  local record = s.constructors[c]
  local entity = record and record.entity
  if not (entity and entity.valid) then team.present = 0; return end
  local st = team.state
  if st.surface_index ~= entity.surface_index then
    st = new_state(entity.surface_index)
    team.state = st
  end
  local members = {}
  for _, id in ipairs(team.members) do
    local e = game.get_entity_by_unit_number(id)
    if e and e.valid and e.surface_index == st.surface_index and not loans.on_loan(id) then members[#members + 1] = e end
  end
  if #members == 0 then team.present = 0; return end
  local present, retreated = retreat.sweep(st, members, {force = entity.force, surface_index = st.surface_index,
    retreat = cfg.retreat, rejoin = cfg.rejoin, range = cfg.range, responders = st.responders,
    on_rejoin = function() end})
  if retreated then st.members_dirty = true end
  team.present = #present
  if #present == 0 then return end
  local ward, moved = escort.follow(st, present, entity, M.STEP)
  if st.members_dirty then
    st.members_dirty = nil
    moved = true
  end
  escort.formations.defensive(st, present, ward, moved, characters, FORMATION)
end

-- Drives the teams whose constructor is in this sweep slice (all when phase
-- is nil).
function M.tick(phase)
  local s = state.peek()
  if not (s and next(s.teams)) then return end
  local cfg, characters
  for c, team in pairs(s.teams) do
    if phase == nil or c % divisions.PHASES == phase then
      cfg = cfg or config.escort()
      characters = characters or escort.player_characters()
      drive(s, c, team, cfg, characters)
    end
  end
end

-- Team soldiers present with the constructor at the last sweep.
function M.present(c)
  local s = state.peek()
  local team = s and s.teams[c]
  return team and team.present or 0
end

function M.on_command_completed(unit_number, result)
  local s = state.peek()
  local c = s and s.team_of[unit_number]
  local team = c and s.teams[c]
  if not team then return false end
  local st = team.state
  if retreat.is_away(st, unit_number) then
    retreat.on_command_completed(st, unit_number, result)
  elseif st.responders and st.responders[unit_number] then
    st.responders[unit_number] = false
  end
  return true
end

function M.forget(unit_number)
  local s = state.peek()
  local c = s and s.team_of[unit_number]
  if not c then return end
  s.team_of[unit_number] = nil
  local team = s.teams[c]
  if not team then return end
  for i = #team.members, 1, -1 do
    if team.members[i] == unit_number then table.remove(team.members, i) end
  end
  team.state.members_dirty = true
end

return M
