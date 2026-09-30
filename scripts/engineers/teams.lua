-- Engineer escort. Divisions a player marks (mode "engineer") form the
-- force's pool; their armed soldiers are dealt into one team per active
-- constructor, at most CAP each. A constructor whose team is short also
-- takes on soldiers in no division within DRAFT_RADIUS (draftees, see
-- loans.lua); a draftee leaves the pool when it joins a division or the
-- player orders it. A team runs the escort's defensive formation with its
-- constructor as ward, on a tighter ring, and heals through retreat.lua
-- like any escort. The split runs once per second and only when the pool
-- or the constructors changed.
local combat = require('scripts.combat')
local divisions = require('scripts.divisions')
local patrol = require('scripts.patrol')
local escort = require('scripts.escort')
local retreat = require('scripts.retreat')
local cover = require('scripts.cover')
local config = require('scripts.config')
local names = require('scripts.names')
local loans = require('scripts.engineers.loans')
local threat = require('scripts.engineers.threat')
local state = require('scripts.engineers.state')

local M = {}

M.CAP = 8
M.DRAFT_RADIUS = 100
M.DRAFT_TICKS = 5 * 60
-- A team rings its constructor closer than a player's escort, and meets
-- threats within the constructor's own pause radius.
M.RING, M.DETECT, M.STEP = 24, 80, 16
local FORMATION = {ring = M.RING, detect = M.DETECT}

local function halt(soldier)
  combat.set_command(soldier, {type = defines.command.stop, distraction = defines.distraction.by_enemy})
end

-- Deals soldiers to constructors. soldiers = {{id, strength}}, constructors
-- = sorted ids. The strongest min(#soldiers, cap * #constructors) soldiers
-- are dealt round-robin, strongest first (ties by id), so every team gets a
-- similar mix and team sizes differ by at most one. The deal is fresh each
-- time: a strong newcomer takes the place of the weakest soldier.
function M.split(soldiers, constructors, cap)
  local teams, count = {}, #constructors
  for _, c in ipairs(constructors) do teams[c] = {} end
  if count == 0 then return teams end
  local sorted = {}
  for i, s in ipairs(soldiers) do sorted[i] = s end
  table.sort(sorted, function(a, b)
    if a.strength ~= b.strength then return a.strength > b.strength end
    return a.id < b.id
  end)
  for i = 1, math.min(#sorted, cap * count) do
    local team = teams[constructors[(i - 1) % count + 1]]
    team[#team + 1] = sorted[i].id
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

-- Active constructors per force and surface, sorted by unit number. A
-- team fights only on its constructor's surface, so the pool is dealt per
-- surface. A constructor away healing has no team.
local function active(s)
  local ids = {}
  for id in pairs(s.constructors) do ids[#ids + 1] = id end
  table.sort(ids)
  local groups = {}
  for _, id in ipairs(ids) do
    local record = s.constructors[id]
    if record.entity.valid and record.state ~= 'healing' then
      local key = record.force_index .. ':' .. record.entity.surface_index
      local group = groups[key]
      if not group then
        group = {force_index = record.force_index, surface_index = record.entity.surface_index, constructors = {}}
        groups[key] = group
      end
      group.constructors[#group.constructors + 1] = id
    end
  end
  return groups
end

-- The armed soldiers of the force's pool divisions on the surface, by unit
-- number.
local function pool(force_index, surface_index)
  local out = {}
  local veterans = storage.veterans or {}
  for player_index, pstate in pairs(storage.divisions or {}) do
    local player = game.get_player(player_index)
    if player and player.force_index == force_index then
      for n = 1, names.max_division do
        local record = pstate.slots[n]
        if record and record.mode == 'engineer' then
          for _, e in ipairs(divisions.cached(player_index, n)) do
            if e.valid and e.surface_index == surface_index and names.soldier_set[e.name] then
              local veteran = veterans[e.unit_number]
              out[#out + 1] = {id = e.unit_number, strength = threat.strength(e.name, veteran and veteran.rank)}
            end
          end
        end
      end
    end
  end
  for id in pairs(storage.engineer_drafts or {}) do
    local e = game.get_entity_by_unit_number(id)
    if not (e and e.valid) or divisions.owner(id) then
      loans.release(id)
    elseif e.surface_index == surface_index and e.force_index == force_index then
      local veteran = veterans[id]
      out[#out + 1] = {id = id, strength = threat.strength(e.name, veteran and veteran.rank)}
    end
  end
  table.sort(out, function(a, b) return a.id < b.id end)
  return out
end

-- Whether the soldier's division is still in the pool. A soldier the
-- player ordered, dragged or moved to another division has left it, and a
-- team no longer commands it even before the next split drops it.
local function in_pool(id)
  local _, _, record = divisions.owner(id)
  if record then return record.mode == 'engineer' end
  return loans.drafted(id)
end

-- Soldiers in any player's drag selection: the player handles them.
local function selected(id)
  for _, pstate in pairs(storage.divisions or {}) do
    local record = pstate.slots[0]
    for _, member in ipairs(record and record.members or {}) do
      if member == id then return true end
    end
  end
  return false
end

-- Takes on soldiers in no division near a constructor whose team is short,
-- at most once per DRAFT_TICKS. Soldiers lent, held by a cover, in a
-- team, fighting or in a drag selection are left alone. Returns how many
-- joined; the next split deals them.
function M.draft(record)
  local s = state.get()
  local tick = game.tick
  if record.draft_tick and tick - record.draft_tick < M.DRAFT_TICKS then return 0 end
  record.draft_tick = tick
  local team = s.teams[record.id]
  local wanted = M.CAP - (team and #team.members or 0)
  if wanted <= 0 then return 0 end
  local entity = record.entity
  local n = 0
  for _, e in pairs(entity.surface.find_entities_filtered{position = entity.position, radius = M.DRAFT_RADIUS,
      name = names.soldier_names, force = record.force_index}) do
    local id = e.unit_number
    if e.valid and not divisions.owner(id) and not loans.drafted(id) and not loans.on_loan(id)
        and not s.team_of[id] and not cover.held(id) and not combat.fighting(id) and not selected(id) then
      loans.draft(id)
      n = n + 1
      if n >= wanted then break end
    end
  end
  if n > 0 then s.dirty = true end
  return n
end

-- A soldier dealt out of its team stops where it is while its division is
-- still in the pool. One that left the pool keeps the player's order.
local function spare(id)
  if not in_pool(id) then return end
  local e = game.get_entity_by_unit_number(id)
  if e and e.valid then halt(e) end
end

-- A soldier dealt to another team moves without a stop; one dealt to no
-- team is spared.
local function apply(s, split)
  local dealt = {}
  for c, ids in pairs(split) do
    for _, id in ipairs(ids) do dealt[id] = c end
  end
  for c, ids in pairs(split) do
    local record = s.constructors[c]
    local team = s.teams[c]
    if not team then
      team = {members = {}, state = new_state(record.surface_index), present = 0}
      s.teams[c] = team
    end
    for _, id in ipairs(team.members) do
      if not dealt[id] and s.team_of[id] == c then
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
  local groups, seen = active(s), {}
  for key, group in pairs(groups) do
    local soldiers = pool(group.force_index, group.surface_index)
    local parts = {}
    for _, c in ipairs(group.constructors) do parts[#parts + 1] = c; seen[c] = true end
    parts[#parts + 1] = '|'
    for _, x in ipairs(soldiers) do parts[#parts + 1] = x.id end
    local signature = table.concat(parts, ',')
    if s.dirty or s.signatures[key] ~= signature then
      s.signatures[key] = signature
      apply(s, M.split(soldiers, group.constructors, M.CAP))
    end
  end
  local gone = {}
  for c in pairs(s.teams) do if not seen[c] then gone[#gone + 1] = c end end
  for _, c in ipairs(gone) do dissolve(s, c) end
  for key in pairs(s.signatures) do
    if not groups[key] then s.signatures[key] = nil end
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
    if e and e.valid and e.surface_index == st.surface_index and not loans.on_loan(id) and in_pool(id) then
      members[#members + 1] = e
    end
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
  -- A soldier that left the pool completes the player's order, not the team's.
  if not (team and in_pool(unit_number)) then return false end
  local st = team.state
  if retreat.is_away(st, unit_number) then
    retreat.on_command_completed(st, unit_number, result)
  elseif st.responders and st.responders[unit_number] then
    st.responders[unit_number] = false
  end
  return true
end

function M.forget(unit_number)
  loans.release(unit_number)
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
