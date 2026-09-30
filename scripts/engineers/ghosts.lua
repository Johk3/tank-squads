-- The wall and gate ghosts constructors may build, per surface and force,
-- bucketed by 32-tile chunk so the nearest search visits few ghosts. Ghosts
-- come from build events and one read of each surface when its first
-- constructor arrives; the map is never scanned again. A ghost that
-- vanished (built by robots, mined, destroyed) is dropped when next read.
local state = require('scripts.engineers.state')

local M = {}

M.NAMES = {'stone-wall', 'gate'}
M.NAME_SET = {['stone-wall'] = true, gate = true}
M.CHUNK = 32
-- A ghost robots can reach is asked about again after this long.
M.RECHECK = 60 * 60
-- A cluster the constructor could not reach or clear waits this long.
M.BLOCK = 5 * 3600
-- Robot-covered ghosts a single claim may step over before giving up.
M.ATTEMPTS = 20

function M.chunk_of(position)
  return math.floor(position.x / M.CHUNK), math.floor(position.y / M.CHUNK)
end

function M.key(cx, cy)
  return cx .. ':' .. cy
end

-- Squared distance from the position to the nearest point of the chunk.
function M.chunk_distance2(cx, cy, position)
  local x0, y0 = cx * M.CHUNK, cy * M.CHUNK
  local dx = math.max(x0 - position.x, 0, position.x - (x0 + M.CHUNK))
  local dy = math.max(y0 - position.y, 0, position.y - (y0 + M.CHUNK))
  return dx * dx + dy * dy
end

local function distance2(a, b)
  local dx, dy = a.x - b.x, a.y - b.y
  return dx * dx + dy * dy
end

-- The accepted entry nearest the position. Chunks are visited nearest
-- first; the search stops at the first chunk farther than the best entry.
-- `accept` may drop the entry it is given from its chunk.
function M.nearest(chunks, position, accept)
  local order = {}
  for key, chunk in pairs(chunks) do
    order[#order + 1] = {chunk = chunk, key = key, d = M.chunk_distance2(chunk.cx, chunk.cy, position)}
  end
  table.sort(order, function(a, b)
    if a.d ~= b.d then return a.d < b.d end
    return a.key < b.key
  end)
  local best, best_d
  for _, o in ipairs(order) do
    if best_d and o.d > best_d then break end
    for _, entry in pairs(o.chunk.entries) do
      if accept(entry) then
        local d = distance2(entry.position, position)
        if not best_d or d < best_d or (d == best_d and entry.id < best.id) then best, best_d = entry, d end
      end
    end
  end
  return best
end

-- The seed and the accepted entries within `radius` of it, nearest first,
-- at most `max` in all. A radius below one chunk needs only the seed's
-- chunk and its eight neighbours.
function M.cluster(chunks, seed, radius, max, accept)
  local found, r2 = {}, radius * radius
  local cx, cy = M.chunk_of(seed.position)
  for x = cx - 1, cx + 1 do
    for y = cy - 1, cy + 1 do
      local chunk = chunks[M.key(x, y)]
      if chunk then
        for _, entry in pairs(chunk.entries) do
          if entry ~= seed then
            local d = distance2(entry.position, seed.position)
            if d <= r2 and accept(entry) then found[#found + 1] = {entry = entry, d = d} end
          end
        end
      end
    end
  end
  table.sort(found, function(a, b)
    if a.d ~= b.d then return a.d < b.d end
    return a.entry.id < b.entry.id
  end)
  local out = {seed}
  for i = 1, math.min(#found, max - 1) do out[#out + 1] = found[i].entry end
  return out
end

function M.bucket(surface_index, force_index, create)
  local s = create and state.get() or state.peek()
  if not s then return nil end
  local key = surface_index .. ':' .. force_index
  local bucket = s.ghosts[key]
  if not bucket and create then
    bucket = {chunks = {}, count = 0}
    s.ghosts[key] = bucket
  end
  return bucket
end

local function insert(bucket, entity)
  local id, p = entity.unit_number, entity.position
  local cx, cy = M.chunk_of(p)
  local key = M.key(cx, cy)
  local chunk = bucket.chunks[key]
  if not chunk then
    chunk = {cx = cx, cy = cy, entries = {}, count = 0}
    bucket.chunks[key] = chunk
  end
  if chunk.entries[id] then return end
  chunk.entries[id] = {entity = entity, id = id, position = {x = p.x, y = p.y}, chunk = key}
  chunk.count, bucket.count = chunk.count + 1, bucket.count + 1
end

-- Set by rings.lua: told when a ring ghost leaves the registry, and whether
-- the crane built it.
M.on_ring_gone = nil

local function drop(bucket, entry, built)
  local chunk = bucket.chunks[entry.chunk]
  if not (chunk and chunk.entries[entry.id]) then return end
  chunk.entries[entry.id] = nil
  chunk.count, bucket.count = chunk.count - 1, bucket.count - 1
  if chunk.count == 0 then bucket.chunks[entry.chunk] = nil end
  local s = state.get()
  s.claims[entry.id], s.blocked[entry.id] = nil, nil
  if M.on_ring_gone and s.ring_ghosts and s.ring_ghosts[entry.id] then
    M.on_ring_gone(entry.id, entry.position, built)
  end
end

-- A wall or gate ghost was placed. A surface no constructor has visited is
-- skipped: its first constructor reads every ghost there at once.
function M.add(entity)
  local s = state.peek()
  if not (s and entity and entity.valid and entity.type == 'entity-ghost' and M.NAME_SET[entity.ghost_name]) then
    return
  end
  if not s.scanned[entity.surface_index] then return end
  local bucket = M.bucket(entity.surface_index, entity.force_index, true)
  local before = bucket.count
  insert(bucket, entity)
  if bucket.count > before then bucket.added = game.tick end
end

function M.scan(surface)
  local s = state.get()
  if s.scanned[surface.index] then return end
  s.scanned[surface.index] = true
  for _, g in pairs(surface.find_entities_filtered{type = 'entity-ghost', ghost_name = M.NAMES}) do
    insert(M.bucket(surface.index, g.force_index, true), g)
  end
end

-- Claims the nearest free ghost and the free ghosts within `radius` of it,
-- at most `max`. Without a filter only ghosts outside every construction
-- network and outside every ring are taken; robot coverage is asked only
-- about the seed, and a covered seed is not asked about again for RECHECK
-- ticks. With a filter only ring ghosts are taken, robots or not:
-- filter.ring == true any ring's, or filter.ring == key with
-- filter.segment one segment's. filter.near moves the search centre.
-- Returns the cluster, or nil.
function M.claim(record, radius, max, filter)
  local s = state.get()
  local bucket = M.bucket(record.surface_index, record.force_index)
  if not (bucket and bucket.count > 0) then return nil end
  local entity = record.entity
  local surface, force, tick = entity.surface, entity.force, game.tick
  local tags = s.ring_ghosts
  local function free(entry)
    if not entry.entity.valid then drop(bucket, entry, false); return false end
    if s.claims[entry.id] then return false end
    local tag = tags and tags[entry.id]
    if filter then
      if not tag then return false end
      if filter.ring ~= true and (tag.ring ~= filter.ring or tag.segment ~= filter.segment) then return false end
    elseif tag then
      return false
    end
    local blocked = s.blocked[entry.id]
    if blocked then
      if blocked > tick then return false end
      s.blocked[entry.id] = nil
    end
    if filter then return true end
    return not (entry.covered_until and entry.covered_until > tick)
  end
  local position = filter and filter.near or entity.position
  for _ = 1, M.ATTEMPTS do
    local seed = M.nearest(bucket.chunks, position, free)
    if not seed then return nil end
    if filter or #surface.find_logistic_networks_by_construction_area(seed.position, force) == 0 then
      local cluster = M.cluster(bucket.chunks, seed, radius, max, free)
      for _, entry in ipairs(cluster) do s.claims[entry.id] = record.id end
      return cluster
    end
    seed.covered_until = tick + M.RECHECK
  end
  return nil
end

function M.release(cluster)
  local s = state.peek()
  if not (s and cluster) then return end
  for _, entry in ipairs(cluster) do s.claims[entry.id] = nil end
end

function M.block(cluster, ticks)
  local s = state.get()
  local until_tick = game.tick + ticks
  for _, entry in ipairs(cluster or {}) do
    s.claims[entry.id], s.blocked[entry.id] = nil, until_tick
  end
end

-- Blocks every unclaimed ghost of the constructor's registry within
-- `radius` of any of the positions, so a nest too strong to clear is
-- judged once, not once per cluster around it.
function M.block_near(record, positions, radius, ticks)
  local bucket = M.bucket(record.surface_index, record.force_index)
  if not (bucket and positions[1]) then return end
  local s = state.get()
  local until_tick, r2 = game.tick + ticks, radius * radius
  local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
  for _, p in ipairs(positions) do
    x0, y0, x1, y1 = math.min(x0, p.x), math.min(y0, p.y), math.max(x1, p.x), math.max(y1, p.y)
  end
  local cx0, cy0 = M.chunk_of({x = x0 - radius, y = y0 - radius})
  local cx1, cy1 = M.chunk_of({x = x1 + radius, y = y1 + radius})
  for cx = cx0, cx1 do
    for cy = cy0, cy1 do
      local chunk = bucket.chunks[M.key(cx, cy)]
      if chunk then
        for id, entry in pairs(chunk.entries) do
          if not s.claims[id] then
            for _, p in ipairs(positions) do
              if distance2(entry.position, p) <= r2 then
                s.blocked[id] = until_tick
                break
              end
            end
          end
        end
      end
    end
  end
end

-- The crane built the ghost, or found it gone.
function M.placed(record, entry)
  local bucket = M.bucket(record.surface_index, record.force_index)
  if bucket then drop(bucket, entry, true) end
end

-- Player ghosts not known to be in robot coverage, for the Engineers
-- window. Ring ghosts are shown per ring instead.
function M.count(surface_index, force_index)
  local bucket = M.bucket(surface_index, force_index)
  if not bucket then return 0 end
  local s = state.peek()
  local tags = s and s.ring_ghosts
  local tick, n = game.tick, 0
  for _, chunk in pairs(bucket.chunks) do
    for id, entry in pairs(chunk.entries) do
      if not (tags and tags[id]) and not (entry.covered_until and entry.covered_until > tick) then n = n + 1 end
    end
  end
  return n
end

return M
