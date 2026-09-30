-- Walls of rings being taken down, bucketed by chunk like the ghost
-- registry, one bucket per ring. Autonomous constructors claim clusters of
-- them as they claim ghosts; the crane destroys them. Robots may take them
-- first: those entries are dropped when read.
local state = require('scripts.engineers.state')
local ghosts = require('scripts.engineers.ghosts')

local M = {}

local function all()
  local s = state.get()
  s.dismantle = s.dismantle or {}
  return s.dismantle
end

function M.add(ring, entity)
  local list = all()
  local bucket = list[ring.key]
  if not bucket then
    bucket = {chunks = {}, count = 0, force_index = ring.force_index, surface_index = ring.surface_index}
    list[ring.key] = bucket
  end
  local id, p = entity.unit_number, entity.position
  local cx, cy = ghosts.chunk_of(p)
  local key = ghosts.key(cx, cy)
  local chunk = bucket.chunks[key]
  if not chunk then
    chunk = {cx = cx, cy = cy, entries = {}, count = 0}
    bucket.chunks[key] = chunk
  end
  if chunk.entries[id] then return end
  chunk.entries[id] = {entity = entity, id = id, position = {x = p.x, y = p.y}, chunk = key, ring = ring.key}
  chunk.count, bucket.count = chunk.count + 1, bucket.count + 1
end

local function drop(bucket, entry)
  local chunk = bucket.chunks[entry.chunk]
  if not (chunk and chunk.entries[entry.id]) then return end
  chunk.entries[entry.id] = nil
  chunk.count, bucket.count = chunk.count - 1, bucket.count - 1
  if chunk.count == 0 then bucket.chunks[entry.chunk] = nil end
  local s = state.get()
  s.claims[entry.id], s.blocked[entry.id] = nil, nil
end

-- The nearest cluster of walls to take down on the constructor's surface,
-- from any of its force's rings being torn down. Returns nil when none.
function M.claim(record, radius, max)
  local s = state.peek()
  local list = s and s.dismantle
  if not (list and next(list)) then return nil end
  local position, tick = record.entity.position, game.tick
  local best, best_bucket, best_d
  for _, bucket in pairs(list) do
    if bucket.force_index == record.force_index and bucket.surface_index == record.surface_index and bucket.count > 0 then
      local function free(entry)
        if not entry.entity.valid then drop(bucket, entry); return false end
        if s.claims[entry.id] then return false end
        return not (s.blocked[entry.id] and s.blocked[entry.id] > tick)
      end
      local seed = ghosts.nearest(bucket.chunks, position, free)
      if seed then
        local dx, dy = seed.position.x - position.x, seed.position.y - position.y
        local d = dx * dx + dy * dy
        if not best_d or d < best_d then best, best_bucket, best_d = seed, bucket, d end
      end
    end
  end
  if not best then return nil end
  local function free(entry)
    return entry.entity.valid and not s.claims[entry.id] and not (s.blocked[entry.id] and s.blocked[entry.id] > tick)
  end
  local cluster = ghosts.cluster(best_bucket.chunks, best, radius, max, free)
  for _, entry in ipairs(cluster) do s.claims[entry.id] = record.id end
  return cluster
end

-- The crane took the wall down, or found it gone.
function M.taken(entry)
  local s = state.peek()
  local bucket = s and s.dismantle and s.dismantle[entry.ring]
  if bucket then drop(bucket, entry) end
end

function M.count(ring_key)
  local s = state.peek()
  local bucket = s and s.dismantle and s.dismantle[ring_key]
  return bucket and bucket.count or 0
end

-- Drops walls that are gone (robots took them). Returns what is left.
function M.purge(ring_key)
  local s = state.peek()
  local bucket = s and s.dismantle and s.dismantle[ring_key]
  if not bucket then return 0 end
  local gone = {}
  for _, chunk in pairs(bucket.chunks) do
    for _, entry in pairs(chunk.entries) do
      if not entry.entity.valid then gone[#gone + 1] = entry end
    end
  end
  for _, entry in ipairs(gone) do drop(bucket, entry) end
  return bucket.count
end

function M.clear(ring_key)
  local s = state.peek()
  if s and s.dismantle then s.dismantle[ring_key] = nil end
end

return M
