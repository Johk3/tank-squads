local combat = require("scripts.combat")
local divisions = require("scripts.divisions")
local patrol = require("scripts.patrol")

local M = {}

-- Tiles charted around the division's centroid each sweep. A `unit` does not
-- lift fog of war by itself. Map vision (scripts/vision.lua) charts only two
-- chunks around each soldier and can be switched off, so scouting charts this
-- wider area itself.
M.CHART_RADIUS = 96
-- Chunks tested per division per sweep. The search resumes at the stored ring
-- and offset on the next sweep, so per-sweep cost stays flat as the charted
-- map grows.
M.CHUNK_BUDGET = 64
-- Rings of chunks searched before the division gives up. 32 chunks is 1024
-- tiles in each direction.
M.MAX_RING = 32
M.FAILURE_TTL = 60 * 60
M.FAILURE_LIMIT = 64

local function centroid(members)
  local x, y = 0, 0
  for _, e in pairs(members) do
    x = x + e.position.x
    y = y + e.position.y
  end
  return {x = x / #members, y = y / #members}
end

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

local function next_target(force, surface, cx, cy, state)
  local ring = state.ring or 1
  local offset = state.offset or 0
  local tested = 0
  while ring <= M.MAX_RING do
    local perimeter = 8 * ring
    while offset < perimeter do
      if tested >= M.CHUNK_BUDGET then
        state.ring, state.offset = ring, offset
        return nil
      end
      local chunk = ring_chunk(cx, cy, ring, offset)
      tested = tested + 1
      offset = offset + 1
      local blocked = state.failed and state.failed[chunk.x .. ":" .. chunk.y]
      if not (blocked and blocked > game.tick) and not force.is_chunk_charted(surface, chunk) then
        state.ring, state.offset = 1, 0
        return chunk
      end
    end
    ring = ring + 1
    offset = 0
  end
  state.ring, state.offset = nil, nil
  return nil, "exhausted"
end

local function send(members, chunk)
  local destination = {x = chunk.x * 32 + 16, y = chunk.y * 32 + 16}
  for _, soldier in pairs(members) do
    combat.set_command(soldier, {
      type = defines.command.go_to_location,
      destination = destination,
      radius = 8,
      -- Scouts fight what attacks them, then the next sweep reissues the leg.
      distraction = defines.distraction.by_enemy,
    })
  end
  return destination
end

function M.set(player_index, n, enabled)
  local record = divisions.record(player_index, n)
  if enabled and divisions.size(player_index, n) == 0 then return nil end
  if enabled then
    divisions.end_escort(record)
    patrol.clear(player_index, n)
    record.mode = "scout"
    record.order = nil
    record.scout = {ring = 1, offset = 0, target = nil}
  elseif record.mode == "scout" then
    -- Only reset when this division is actually scouting: scout.set(false)
    -- is reachable directly (remote interface, shortcut toggle-off) even
    -- while the division is escorting or patrolling, and must not stomp
    -- another mode's state.
    record.mode = "idle"
    record.scout = nil
  end
  return enabled
end

local function drive(player_index, n, record)
  local members = divisions.get(player_index, n)
  if #members == 0 then
    if divisions.is_reinforced(record) then return end
    record.mode = "idle"
    record.scout = nil
    return
  end
  local state = record.scout or {ring = 1, offset = 0}
  record.scout = state
  local leader = members[1]
  local surface = leader.surface
  local force = leader.force
  -- Coordinates only have meaning on one surface. Keep a scout operation on
  -- its original surface even if membership spans multiple planets.
  state.surface_index = state.surface_index or leader.surface_index
  local local_members = {}
  for _, member in ipairs(members) do
    if member.surface_index == state.surface_index then
      local_members[#local_members + 1] = member
    end
  end
  members = local_members
  if #members == 0 then
    record.mode, record.scout = "idle", nil
    return
  end
  surface = members[1].surface
  local origin = centroid(members)
  for key, expiry in pairs(state.failed or {}) do
    if expiry <= game.tick then state.failed[key] = nil end
  end

  force.chart(surface, {
    {x = origin.x - M.CHART_RADIUS, y = origin.y - M.CHART_RADIUS},
    {x = origin.x + M.CHART_RADIUS, y = origin.y + M.CHART_RADIUS},
  })

  local cx, cy = math.floor(origin.x / 32), math.floor(origin.y / 32)
  if state.target and not force.is_chunk_charted(surface, state.target) then
    return -- still walking to a target that is still worth reaching
  end

  local chunk, exhausted = next_target(force, surface, cx, cy, state)
  if exhausted then
    record.mode = "idle"
    record.scout = nil
    local player = game.get_player(player_index)
    if player then player.print({"tank-squads.scout-exhausted", n}) end
    return
  end
  if not chunk then return end -- budget spent; resumes next sweep
  state.target = chunk
  send(members, chunk)
end

function M.tick(phase)
  storage.divisions = storage.divisions or {}
  for player_index, state in pairs(storage.divisions) do
    for n, record in pairs(state.slots) do
      if record.mode == "scout" and divisions.in_phase(player_index, n, phase) then drive(player_index, n, record) end
    end
  end
end

-- A scout that finished its leg (arrived, or finished a fight it was dragged
-- into) would otherwise stand still until its target happened to be charted.
function M.on_command_completed(unit_number, result)
  local _, _, record = divisions.owner(unit_number)
  if not record or record.mode ~= "scout" then return false end
  local state = record.scout
  if state and state.target and result == defines.behavior_result.fail then
    state.failed = state.failed or {}
    local count, oldest_key, oldest = 0, nil, math.huge
    for key, expiry in pairs(state.failed) do
      count = count + 1
      if expiry < oldest then oldest_key, oldest = key, expiry end
    end
    local key = state.target.x .. ":" .. state.target.y
    if not state.failed[key] and count >= M.FAILURE_LIMIT then state.failed[oldest_key] = nil end
    state.failed[key] = game.tick + M.FAILURE_TTL
  end
  if state then state.target = nil end
  -- Coalesce completions into the next bounded sweep without searching any
  -- division's roster, including completions from unrelated native units.
  return true
end

return M
