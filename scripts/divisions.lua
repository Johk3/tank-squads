local names = require("scripts.names")
local render = require("scripts.render")

local M = {}

-- Persisted with the rosters so loading a save never changes event routing.
-- Older saves build it once; configuration reconciliation repairs duplicates.
-- Only divisions 1-9 own soldiers. The drag selection (slot 0) lists them
-- without owning them, so it is never indexed.
local function ownership()
  if not storage.unit_divisions then
    storage.unit_divisions = {}
    for player_index, state in pairs(storage.divisions or {}) do
      for n, record in pairs(state.slots) do
        if n ~= 0 then
          for _, id in ipairs(record.members) do
            storage.unit_divisions[id] = {player_index = player_index, division = n}
          end
        end
      end
    end
  end
  return storage.unit_divisions
end

local function index_member(owners, id, player_index, n)
  if n == 0 then return end
  local owner = owners[id]
  if not owner or owner.player_index ~= player_index or owner.division ~= n then
    owners[id] = {player_index = player_index, division = n}
  end
end

local function unindex_member(owners, id, player_index, n)
  if n == 0 then return end
  local owner = owners[id]
  if owner and owner.player_index == player_index and owner.division == n then owners[id] = nil end
end

local function replace_members(player_index, n, record, members)
  local owners = ownership()
  for _, id in ipairs(record.members) do unindex_member(owners, id, player_index, n) end
  record.members = members
  for _, id in ipairs(members) do index_member(owners, id, player_index, n) end
end

function M.owner(unit_number)
  local owner = ownership()[unit_number]
  if not owner then return nil end
  local state = storage.divisions and storage.divisions[owner.player_index]
  local record = state and state.slots[owner.division]
  if record then return owner.player_index, owner.division, record end
end

-- Same-tick entity cache for escorts and linked producers. Rebuilt after
-- load and invalidated by every roster mutation and each barracks sweep.
local live = {}

local function live_key(player_index, n) return player_index .. ":" .. n end

local function invalidate_live(player_index, n)
  live[live_key(player_index, n)] = nil
end

-- A new barracks sweep must also detect silent entity destruction, even
-- when invoked remotely twice in the same tick.
function M.invalidate(player_index, n)
  invalidate_live(player_index, n)
end

local function player_state(player_index)
  storage.divisions = storage.divisions or {}
  local state = storage.divisions[player_index]
  if not state then
    state = {selected = 0, slots = {}}
    storage.divisions[player_index] = state
  end
  return state
end

function M.record(player_index, n)
  local state = player_state(player_index)
  local record = state.slots[n]
  if not record then
    record = {members = {}, mode = "idle", patrol = nil, scout = nil,
      render = {rings = {}, route = {}, palette = render.PALETTE}}
    state.slots[n] = record
  end
  record.render = record.render or {rings = {}, route = {}}
  return record
end

function M.selected(player_index)
  return player_state(player_index).selected or 0
end

function M.set_selected(player_index, n)
  player_state(player_index).selected = n
end

-- Factorio 2.0's "get-by-unit-number" entity prototype flag makes
-- game.get_entity_by_unit_number work for that prototype; all three soldier
-- prototypes carry it (prototypes/soldier.lua). That makes this an O(#division)
-- lookup instead of a scan over every surface (Nauvis + every planet + every
-- space platform under Space Age), which matters because this runs on every
-- order, every patrol leg advance, and every scout sweep.
function M.get(player_index, n)
  local player = game.get_player(player_index)
  local record = M.record(player_index, n)
  if not player then return {} end
  local out, kept, owners = {}, {}, ownership()
  -- Read once per division: every member compares against the same force.
  -- Only soldiers ever join a roster and unit numbers are never reused, so
  -- the force is the only property that can change under a stored id.
  local force_index = player.force.index
  for _, id in pairs(record.members) do
    local e = game.get_entity_by_unit_number(id)
    -- The drag selection lets go of a soldier another player now owns.
    local other = n == 0 and owners[id]
    if e and e.valid and e.force_index == force_index and not (other and other.player_index ~= player_index) then
      table.insert(out, e)
      table.insert(kept, id)
      index_member(owners, id, player_index, n)
    else
      unindex_member(owners, id, player_index, n)
      render.forget_ring(record, id)
    end
  end
  local changed = #kept ~= #record.members
  record.members = kept
  if changed then M.members_changed(player_index, n) end
  render.rings(player_index, n, record, out)
  -- Cached for M.cached(): divisions.refresh() resolves every populated
  -- division's members once per sweep, immediately before escort.tick()
  -- runs in the same script.on_nth_tick(60) handler, so escort can reuse
  -- this same-tick result instead of touching every soldier a second time.
  live[live_key(player_index, n)] = {tick = game.tick, entities = out}
  return out
end

function M.size(player_index, n)
  return #M.get(player_index, n)
end

-- How many of a barracks' recruits still serve in the division. Drops the
-- ones that died or left it, in place. Reads the ownership index, which the
-- last roster check and every death keep current.
function M.serving(player_index, n, recruits)
  local owners, kept = ownership(), 0
  for i = 1, #recruits do
    local id = recruits[i]
    local owner = owners[id]
    if owner and owner.player_index == player_index and owner.division == n then
      kept = kept + 1
      recruits[kept] = id
    end
  end
  for i = #recruits, kept + 1, -1 do recruits[i] = nil end
  return kept
end

-- The summed targets and serving recruits of the division's linked barracks,
-- or nil when no barracks is linked. Takes the record so a read never
-- creates an empty division.
function M.reinforcement(player_index, n, record)
  if not (record and M.is_reinforced(record)) then return nil end
  local target, serving = 0, 0
  for _, source in pairs(record.reinforcement_sources) do
    if type(source) == "table" then
      target = target + source.target
      serving = serving + M.serving(player_index, n, source.recruits)
    end
  end
  return target, serving
end

-- A same-tick cache of M.get(), for a hot per-sweep caller (escort) that
-- runs immediately after divisions.refresh() already resolved this
-- division's members this sweep. Falls back to a full M.get() otherwise, so
-- it is always correct, just not always free.
function M.cached(player_index, n)
  local entry = live[live_key(player_index, n)]
  if entry and entry.tick == game.tick then return entry.entities end
  return M.get(player_index, n)
end

function M.clear(player_index, n)
  local record = M.record(player_index, n)
  render.clear_rings(record)
  render.clear_route(record)
  M.end_escort(record)
  replace_members(player_index, n, record, {})
  record.patrol = nil
  record.scout = nil
  record.mode = "idle"
  record.order = nil
  invalidate_live(player_index, n)
end

function M.is_reinforced(record)
  return record.reinforcement_sources ~= nil and next(record.reinforcement_sources) ~= nil
end

function M.clear_player(player_index)
  storage.divisions = storage.divisions or {}
  local state = storage.divisions[player_index]
  if not state then return end
  for n in pairs(state.slots) do M.clear(player_index, n) end
  storage.divisions[player_index] = nil
end

-- Patrol and escort register here at module load. The list lives in module
-- state, never in save data, so it is rebuilt identically on every load.
local listeners = {}

function M.listen_members_changed(fn)
  listeners[#listeners + 1] = fn
end

function M.members_changed(player_index, n)
  local record = M.record(player_index, n)
  if #record.members == 0 and not M.is_reinforced(record) then M.clear(player_index, n); return end
  -- Scout teams drop departed soldiers on their next sweep and take in new
  -- ones as recruits.
  if record.scout then record.scout.roster_dirty = true end
  for _, fn in ipairs(listeners) do fn(player_index, n) end
end

function M.end_escort(record)
  render.clear_escort(record)
  record.escort = nil
  if record.mode == "escort" then record.mode = "idle" end
end

-- Batch ownership transfer: scan each existing membership once per selection,
-- rather than once per selected unit. No additional per-tick ownership scan.
local function detach(player_index, ids, keep)
  for owner, state in pairs(storage.divisions or {}) do
    for n, record in pairs(state.slots) do
      if owner ~= player_index or n ~= keep then
        local kept, changed = {}, false
        for _, id in ipairs(record.members) do
          if ids[id] then
            render.forget_ring(record, id)
            changed = true
          else kept[#kept + 1] = id end
        end
        if changed then
          replace_members(owner, n, record, kept)
          invalidate_live(owner, n)
          M.members_changed(owner, n)
        end
      end
    end
  end
end

local function fill(player_index, n, entities)
  local player = game.get_player(player_index)
  if not player then return 0 end
  local record = M.record(player_index, n)
  render.clear_rings(record)
  local ids, seen = {}, {}
  for _, e in pairs(entities) do
    if e.valid and names.unit_set[e.name] and e.force == player.force and not seen[e.unit_number] then
      table.insert(ids, e.unit_number)
      seen[e.unit_number] = true
    end
  end
  detach(player_index, seen, n)
  replace_members(player_index, n, record, ids)
  -- A player assignment is a new division: scouting deals fresh teams.
  if record.scout then record.scout.teams, record.scout.team_of = nil, nil end
  invalidate_live(player_index, n)
  M.members_changed(player_index, n)
  M.set_selected(player_index, n)
  return #M.get(player_index, n)
end

local AUTOMATED = {patrol = true, scout = true, escort = true}

-- Before the drag selection is ordered, its soldiers leave the player's
-- patrolling, scouting and escorting divisions, whose next leg would undo
-- the order. A manual division keeps its soldiers.
function M.release_for_order(player_index, members)
  local owners, state, ids = ownership(), storage.divisions and storage.divisions[player_index], {}
  for _, e in ipairs(members) do
    local owner = owners[e.unit_number]
    local record = owner and owner.player_index == player_index and state and state.slots[owner.division]
    if record and AUTOMATED[record.mode] then ids[e.unit_number] = true end
  end
  if next(ids) then detach(player_index, ids, 0) end
end

-- The drag selection lists soldiers without owning them: selecting never
-- changes a division, its job or a barracks' quota. It takes the player's
-- own soldiers and those in nobody's division, never a teammate's.
function M.select_area(player_index, entities)
  local player = game.get_player(player_index)
  if not player then return 0 end
  local record = M.record(player_index, 0)
  render.clear_rings(record)
  local owners, ids, seen = ownership(), {}, {}
  for _, e in pairs(entities) do
    if e.valid and names.unit_set[e.name] and e.force == player.force and not seen[e.unit_number] then
      local owner = owners[e.unit_number]
      if not (owner and owner.player_index ~= player_index) then
        ids[#ids + 1], seen[e.unit_number] = e.unit_number, true
      end
    end
  end
  record.members = ids
  invalidate_live(player_index, 0)
  M.members_changed(player_index, 0)
  M.set_selected(player_index, 0)
  return #M.get(player_index, 0)
end

function M.assign(player_index, n, entities)
  if n == 0 then return M.select_area(player_index, entities) end
  local count = fill(player_index, n, entities)
  if count == 0 then M.clear(player_index, n) end
  return count
end

-- Moves the drag selection into the lowest empty division 1-9 and selects
-- it, so a job can run on soldiers it owns. Returns the division, or nil
-- when the selection is empty or every division is in use. A leftover job
-- on an empty slot is cleared first, so the soldiers never inherit it.
function M.promote(player_index)
  local members = M.get(player_index, 0)
  if #members == 0 then return nil end
  local slots = player_state(player_index).slots
  for n = 1, names.max_division do
    local record = slots[n]
    if not record or (not M.is_reinforced(record) and #M.get(player_index, n) == 0) then
      M.clear(player_index, n)
      M.assign(player_index, n, members)
      return n
    end
  end
  return nil
end

function M.recall(player_index, n)
  M.set_selected(player_index, n)
  return M.size(player_index, n)
end

function M.forget(unit_number)
  local player_index, n, record = M.owner(unit_number)
  if not record then return end
  ownership()[unit_number] = nil
  for i = #record.members, 1, -1 do
    if record.members[i] == unit_number then
      render.forget_ring(record, unit_number)
      table.remove(record.members, i)
      invalidate_live(player_index, n)
      -- Deaths can arrive in a burst. Re-space escorts once on the next
      -- sweep, after all casualties have left the roster.
      if record.escort then record.escort.members_dirty = true end
      return
    end
  end
end

-- New recruits have no previous owner. Keep indexing and cache maintenance
-- here; the reinforcement module sends only the recruit its inherited order.
-- With the new entity at hand, a roster validated this tick stays valid with
-- the recruit appended, so a burst of recruits does not re-resolve the whole
-- roster once per recruit.
function M.add_member(player_index, n, unit_number, entity)
  local record = M.record(player_index, n)
  record.members[#record.members + 1] = unit_number
  index_member(ownership(), unit_number, player_index, n)
  local key = live_key(player_index, n)
  local entry = live[key]
  if entity and entry and entry.tick == game.tick then
    entry.entities[#entry.entities + 1] = entity
    render.rings(player_index, n, record, {entity})
  else
    live[key] = nil
  end
end

-- The one-second sweep is split into PHASES slices, one every 60 / PHASES
-- ticks. Each division, with its escort, scout, patrol and linked barracks,
-- is swept once per second in its own slice, so a large army's work does not
-- land on a single tick. A nil phase means every division, for full sweeps
-- run from the remote interface, the tests and configuration changes.
M.PHASES = 10

function M.phase(player_index, n)
  return (player_index + n) % M.PHASES
end

function M.in_phase(player_index, n, phase)
  return phase == nil or M.phase(player_index, n) == phase
end

-- Repairs render objects and drops stale membership without polling positions:
-- the renderer itself follows each entity.
function M.refresh(phase)
  storage.divisions = storage.divisions or {}
  for player_index, state in pairs(storage.divisions) do
    for n, record in pairs(state.slots) do
      if M.in_phase(player_index, n, phase) then
        local members = M.get(player_index, n)
        if #members == 0 and not M.is_reinforced(record) then M.clear(player_index, n) end
        render.markers(player_index, n, record, members)
      end
    end
  end
end

-- Repair duplicate ownership in older saves deterministically on upgrade.
function M.reconcile_ownership()
  local owners, seen = {}, {}
  for owner in pairs(storage.divisions or {}) do owners[#owners + 1] = owner end
  table.sort(owners)
  for _, owner in ipairs(owners) do
    local slots = storage.divisions[owner].slots
    local numbers = {}
    for n in pairs(slots) do numbers[#numbers + 1] = n end
    table.sort(numbers)
    for _, n in ipairs(numbers) do
      M.get(owner, n) -- Discard invalid entities and obsolete force ownership first.
      -- A selected soldier may also be in a division, so slot 0 keeps its list.
      if n ~= 0 then
        local record, kept = slots[n], {}
        for _, id in ipairs(record.members) do
          if not seen[id] then seen[id] = true; kept[#kept + 1] = id
          else render.forget_ring(record, id) end
        end
        replace_members(owner, n, record, kept)
        invalidate_live(owner, n)
        M.members_changed(owner, n)
      end
    end
  end
  storage.unit_divisions = nil
  ownership()
end

return M
