-- Map vision around every soldier. A `unit` does not lift fog of war by
-- itself, so without this module a force sees nothing of its soldiers' fights
-- unless a radar or a player is nearby. Charting refreshes the chart, which
-- keeps the ground around each soldier live on the map, like a radar's
-- nearby coverage.
--
-- Reading a soldier's position is the main cost, so each soldier is read
-- only once every READ_SECONDS, spread evenly over the sweep slices. The
-- charted area is wide enough that a soldier stays well inside it between
-- reads. Charting runs every second from counts that change only when a
-- soldier enters a new chunk, so its cost follows the number of occupied
-- chunks, not the number of soldiers.
--
-- storage.vision holds:
--   layout   - LAYOUT when built; any other value is rebuilt
--   phases   - the sweep slice count the other fields were built for
--   slices   - slices[s][unit_number] = {entity, group, key, x, y}, the
--              soldiers read in slice s of the read cycle and the chunk each
--              was last seen in
--   occupied - occupied[group][key] = soldiers last seen in that chunk
--   coverage - coverage[p][group][x] = {cells = {[y] = n}, runs = list},
--              where n counts the occupied chunks within RADIUS of chunk x, y.
--              Column x is charted in sweep slice x % phases. runs caches the
--              column's unbroken runs of chunks until a cell changes.
-- group combines force and surface indices, and key a chunk's coordinates.
-- It is kept in storage, not in module locals, so a player who joins
-- mid-second charts the same chunks as everyone else.
local config = require("scripts.config")
local M = {}

-- Chunks charted around each occupied chunk, in each direction.
M.RADIUS = 2
-- Seconds between two position reads of one soldier. A read's new area is
-- charted up to one second later, so the fastest soldier (0.12 tiles per
-- tick) walks at most 36 tiles on stale data. It starts at least RADIUS
-- chunks (64 tiles) from the edge of its charted area, so at least 28 tiles
-- around it stay charted, close to a carrier's 30-tile vision distance.
M.READ_SECONDS = 4

-- Bump when the shape of storage.vision changes, so saves rebuild it.
local LAYOUT = 2

-- Chunk coordinates stay within +-2^20 on any map, and force and surface
-- indices below 2^20, so one number keys each exactly without building a
-- string per soldier.
local OFFSET, SPAN = 2 ^ 20, 2 ^ 21

local function rebuild(phases)
  local cycle = phases * M.READ_SECONDS
  local slices, coverage = {}, {}
  for s = 0, cycle - 1 do slices[s] = {} end
  for p = 0, phases - 1 do coverage[p] = {} end
  -- Positions are read in each soldier's own slice, not all at once here.
  for id, record in pairs(storage.weapons or {}) do slices[id % cycle][id] = {entity = record.entity} end
  storage.vision = {layout = LAYOUT, phases = phases, slices = slices, occupied = {}, coverage = coverage}
  return storage.vision
end

local function cover(state, group, cx, cy, delta)
  local radius, phases = M.RADIUS, state.phases
  for x = cx - radius, cx + radius do
    local bucket = state.coverage[x % phases]
    local by_x = bucket[group]
    if not by_x then by_x = {}; bucket[group] = by_x end
    local column = by_x[x]
    if not column then column = {cells = {}}; by_x[x] = column end
    local cells = column.cells
    for y = cy - radius, cy + radius do
      local n = (cells[y] or 0) + delta
      cells[y] = n > 0 and n or nil
    end
    column.runs = nil
    if not next(cells) then
      by_x[x] = nil
      if not next(by_x) then bucket[group] = nil end
    end
  end
end

local function occupy(state, group, key, cx, cy)
  local occupied = state.occupied[group]
  if not occupied then occupied = {}; state.occupied[group] = occupied end
  local n = (occupied[key] or 0) + 1
  occupied[key] = n
  if n == 1 then cover(state, group, cx, cy, 1) end
end

local function release(state, soldier)
  if not soldier.key then return end
  local occupied = state.occupied[soldier.group]
  local n = occupied[soldier.key] - 1
  if n > 0 then
    occupied[soldier.key] = n
  else
    occupied[soldier.key] = nil
    if not next(occupied) then state.occupied[soldier.group] = nil end
    cover(state, soldier.group, soldier.x, soldier.y, -1)
  end
  soldier.key = nil
end

-- Moves a soldier's count to the chunk it stands in now. Most reads find the
-- soldier in the chunk it was already in and change nothing.
local function read(state, soldier)
  local entity = soldier.entity
  local position = entity.position
  local group = entity.force_index * SPAN + entity.surface_index
  local cx, cy = math.floor(position.x / 32), math.floor(position.y / 32)
  local key = (cx + OFFSET) * SPAN + (cy + OFFSET)
  if soldier.key == key and soldier.group == group then return end
  release(state, soldier)
  soldier.group, soldier.key, soldier.x, soldier.y = group, key, cx, cy
  occupy(state, group, key, cx, cy)
end

-- Called by weapons.register and weapons.unregister, so no slice scans the
-- whole soldier registry. A new soldier is read at once, so it has vision
-- from its first second.
function M.track(entity)
  local state = storage.vision
  if not state then return end
  local slice = state.slices[entity.unit_number % (state.phases * M.READ_SECONDS)]
  if slice[entity.unit_number] then return end
  local soldier = {entity = entity}
  slice[entity.unit_number] = soldier
  read(state, soldier)
end

function M.forget(unit_number)
  local state = storage.vision
  if not state then return end
  local slice = state.slices[unit_number % (state.phases * M.READ_SECONDS)]
  local soldier = slice[unit_number]
  if not soldier then return end
  release(state, soldier)
  slice[unit_number] = nil
end

local function read_slice(state, s)
  local slice = state.slices[s]
  for id, soldier in pairs(slice) do
    if soldier.entity.valid then
      read(state, soldier)
    else
      release(state, soldier)
      slice[id] = nil
    end
  end
end

local function runs_of(cells)
  local ys, runs = {}, {}
  for y in pairs(cells) do ys[#ys + 1] = y end
  table.sort(ys)
  local first = ys[1]
  -- ys[#ys + 1] is nil, which closes the final run.
  for i = 2, #ys + 1 do
    if ys[i] ~= ys[i - 1] + 1 then
      runs[#runs + 1] = {first, ys[i - 1]}
      first = ys[i]
    end
  end
  return runs
end

-- Charts one sweep slice's columns. Each chunk is charted once however many
-- soldiers see it, and each unbroken run of chunks in a column is one call.
local function chart(bucket)
  for group, by_x in pairs(bucket) do
    local force = game.forces[math.floor(group / SPAN)]
    local surface = game.surfaces[group % SPAN]
    if force and surface then
      for x, column in pairs(by_x) do
        local runs = column.runs
        if not runs then runs = runs_of(column.cells); column.runs = runs end
        for _, run in ipairs(runs) do
          force.chart(surface, {{x = x * 32, y = run[1] * 32}, {x = x * 32 + 31, y = run[2] * 32 + 31}})
        end
      end
    end
  end
end

-- A nil phase reads every soldier and charts everything at once, for full
-- sweeps run from the remote interface and the tests.
function M.tick(phase, phases)
  -- Switched off, vision keeps no state, so track and forget cost nothing.
  -- Switching it back on rebuilds from the soldier registry.
  if not settings.global[config.VISION].value then
    storage.vision = nil
    return
  end
  local state = storage.vision
  if not (state and state.layout == LAYOUT and state.phases == phases) then state = rebuild(phases) end
  local cycle = phases * M.READ_SECONDS
  if phase == nil then
    for s = 0, cycle - 1 do read_slice(state, s) end
    for p = 0, phases - 1 do chart(state.coverage[p]) end
    return
  end
  -- The sweep runs one slice every 60 / phases ticks, so the slice count
  -- since the map started picks this slice of the read cycle.
  read_slice(state, math.floor(game.tick * phases / 60) % cycle)
  chart(state.coverage[phase])
end

return M
