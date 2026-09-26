local names = require("scripts.names")
local divisions = require("scripts.divisions")
local patrol = require("scripts.patrol")
local config = require("scripts.config")
local geometry = require("scripts.scout_geometry")
local teams = require("scripts.scout_teams")
local render = require("scripts.render")

local M = {}

-- Tiles charted around a team between hops. A `unit` does not lift fog of
-- war by itself. Map vision (scripts/vision.lua) charts only two chunks
-- around each soldier and can be switched off, so scouting charts this wider
-- area itself.
M.CHART_RADIUS = geometry.CHART_RADIUS
-- Chunks asked of the engine per division per sweep, split between its
-- teams. The search resumes at the stored ring and offset on the next sweep,
-- so per-sweep cost stays flat as the charted map grows.
M.CHUNK_BUDGET = 64
-- Ring steps per team per sweep. Most of a ring can lie outside a team's
-- sector; the sector test is arithmetic, but it is bounded too.
M.STEP_BUDGET = 512
-- Rings of chunks searched before a team marches outward. 32 chunks is 1024
-- tiles in each direction.
M.MAX_RING = 32
M.FAILURE_TTL = geometry.FAILURE_TTL
M.FAILURE_LIMIT = geometry.FAILURE_LIMIT

-- Maps i in [0, 8 * ring) onto the chunks of the square ring at that radius,
-- walking it side by side. Deterministic, so a search can stop mid-ring and
-- resume at the same chunk on the next sweep.
local function ring_chunk(cx, cy, ring, i)
  local side = 2 * ring
  local seg = math.floor(i / side)
  local off = i % side
  if seg == 0 then return {x = cx - ring + off, y = cy - ring} end
  if seg == 1 then return {x = cx + ring, y = cy - ring + off} end
  if seg == 2 then return {x = cx + ring - off, y = cy + ring} end
  return {x = cx - ring, y = cy + ring - off}
end

local function chunk_of(p)
  return {x = math.floor(p.x / 32), y = math.floor(p.y / 32)}
end

-- The nearest uncharted, unblocked chunk inside the team's sectors, searched
-- in rings around `from`. Returns the chunk; nil when the budget ran out
-- (the search resumes next sweep); or nil, true when nothing is in reach.
local function next_target(force, surface, state, team, from, budget)
  team.search_centre = team.search_centre or chunk_of(from)
  local cx, cy = team.search_centre.x, team.search_centre.y
  local home = chunk_of(state.origin)
  local ring, offset = team.ring or 1, team.offset or 0
  local tested, steps = 0, 0
  while ring <= M.MAX_RING do
    local perimeter = 8 * ring
    while offset < perimeter do
      if tested >= budget or steps >= M.STEP_BUDGET then
        team.ring, team.offset = ring, offset
        return nil
      end
      local chunk = ring_chunk(cx, cy, ring, offset)
      offset, steps = offset + 1, steps + 1
      if (chunk.x ~= home.x or chunk.y ~= home.y) and geometry.in_sectors(team.sectors,
          geometry.angle(state.origin, {x = chunk.x * 32 + 16, y = chunk.y * 32 + 16})) then
        local blocked = team.failed and team.failed[chunk.x .. ":" .. chunk.y]
        local sea = state.sea and state.sea[geometry.chunk_key(chunk.x, chunk.y)]
        if not (blocked and blocked > game.tick) and not (sea and sea > game.tick) then
          tested = tested + 1
          if not force.is_chunk_charted(surface, chunk) then
            team.ring, team.offset, team.search_centre = 1, 0, nil
            return chunk
          end
        end
      end
    end
    ring, offset = ring + 1, 0
  end
  team.ring, team.offset, team.search_centre = 1, 0, nil
  return nil, true
end

function M.set(player_index, n, enabled)
  -- The drag selection owns nobody, so it never scouts; control.lua moves
  -- it into a division first.
  if enabled and n == 0 then return nil end
  local record = divisions.record(player_index, n)
  if enabled and divisions.size(player_index, n) == 0 then return nil end
  if enabled then
    divisions.end_escort(record)
    patrol.clear(player_index, n)
    record.mode = "scout"
    record.order = nil
    -- Teams form on the first sweep.
    record.scout = {}
  elseif record.mode == "scout" then
    -- Only reset when this division is actually scouting: scout.set(false)
    -- is reachable directly (remote interface, shortcut toggle-off) even
    -- while the division is escorting or patrolling, and must not stomp
    -- another mode's state.
    record.mode = "idle"
    record.scout = nil
    -- The team labels give way to the division label at once.
    render.markers(player_index, n, record, divisions.cached(player_index, n))
  end
  return enabled
end

local function drive(player_index, n, record, cfg)
  local all = divisions.cached(player_index, n)
  if #all == 0 then
    if divisions.is_reinforced(record) then return end
    record.mode, record.scout = "idle", nil
    return
  end
  local state = record.scout or {}
  record.scout = state
  -- Coordinates only have meaning on one surface. Keep a scout operation on
  -- its original surface even if membership spans multiple planets.
  state.surface_index = state.surface_index or all[1].surface_index
  local members, by_id = {}, {}
  for _, e in ipairs(all) do
    -- The unarmed headquarters never scouts; it keeps its last order.
    if e.valid and e.surface_index == state.surface_index and e.name ~= names.headquarters then
      members[#members + 1], by_id[e.unit_number] = e, e
    end
  end
  if #members == 0 then
    record.mode, record.scout = "idle", nil
    render.markers(player_index, n, record, all)
    return
  end
  local formed = not state.teams
  if formed then
    teams.form(state, members)
  elseif state.roster_dirty then
    teams.reconcile(state, members)
  end
  local alive = teams.count(state)
  local surface, force = members[1].surface, members[1].force
  local budget = math.max(16, math.floor(M.CHUNK_BUDGET / state.team_count))
  local ctx = {by_id = by_id, force = force, surface = surface, cfg = cfg,
    search = function(team, from) return next_target(force, surface, state, team, from, budget) end}
  for id = 1, state.team_count do
    if state.teams[id] then teams.sweep(state, id, ctx) end
  end
  if teams.all_blocked(state) then
    record.mode, record.scout = "idle", nil
    local player = game.get_player(player_index)
    if player then player.print({"tank-squads.scout-exhausted", n}) end
  end
  -- Team labels follow a new, merged or ended team in the same sweep; the
  -- roster refresh keeps them in step with deaths and new leaders.
  if formed or record.mode ~= "scout" or teams.count(state) ~= alive then
    render.markers(player_index, n, record, all)
  end
end

function M.tick(phase)
  storage.divisions = storage.divisions or {}
  local cfg
  for player_index, state in pairs(storage.divisions) do
    for n, record in pairs(state.slots) do
      if record.mode == "scout" and divisions.in_phase(player_index, n, phase) then
        -- One settings read per sweep, shared by every scouting division.
        cfg = cfg or config.escort()
        drive(player_index, n, record, cfg)
      end
    end
  end
end

-- Completions update the team's hop and are acted on by the next bounded
-- sweep, without searching any division's roster, including completions
-- from unrelated native units.
function M.on_command_completed(unit_number, result)
  local _, _, record = divisions.owner(unit_number)
  if not record or record.mode ~= "scout" then return false end
  if record.scout then teams.on_command_completed(record.scout, unit_number, result) end
  return true
end

-- A recruit from a linked barracks joins the smallest team. Before the first
-- sweep there are no teams yet; the recruit is then dealt with the rest.
function M.join(record, soldier)
  local state = record.mode == "scout" and record.scout
  if not state or soldier.name == names.headquarters then return false end
  if state.teams and soldier.surface_index == state.surface_index then teams.join(state, soldier) end
  return true
end

function M.target(state)
  return state.teams and teams.target(state) or nil
end

return M
