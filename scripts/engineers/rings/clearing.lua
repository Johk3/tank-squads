-- Clearing: no nest stands inside the rings. The interior of each force's
-- outermost standing ring is read chunk by chunk, a few chunks per sweep
-- slice, for enemy spawners and worms. Autonomous constructors send a task
-- force at each nest found, nearest first (constructor.lua `clear`), and
-- plan no new ring segment until the first read is done and no nest waits
-- (rings.claim). A nest too strong for the soldiers in reach is blocked for
-- BLOCK ticks and does not hold the rings up meanwhile. A finished read
-- starts again RESCAN ticks later, so nests that grow inside later are
-- found too. Reads run only while the force has an autonomous constructor.
--
-- fs.clearing = {ring = key of the ring read, x0, y0, x1, y1 (its interior
--   chunks), cx, cy (the next chunk, nil between reads), passes, due,
--   found (new nests this read), nests[id], next_id}
-- nest = {id, surface_index, position, blocked (tick it waits until)}
local state = require('scripts.engineers.state')
local assault = require('scripts.assault')
local geometry = require('scripts.engineers.rings.geometry')

local M = {}

-- Generated chunks read per sweep slice, and chunks looked at in all.
M.CHUNKS = 2
M.LOOKS = 256
M.RESCAN = 5 * 3600
M.BLOCK = 5 * 3600
-- Structures this close to a known nest belong to it.
M.MERGE = 40
local TYPES = {'unit-spawner', 'turret'}

local function distance2(a, b)
  local dx, dy = a.x - b.x, a.y - b.y
  return dx * dx + dy * dy
end

-- The standing ring with the largest radius, or nil.
function M.outermost(fs)
  local best
  for _, ring in pairs(fs.slots) do
    if (ring.state == 'building' or ring.state == 'built') and (not best or ring.radius > best.radius) then
      best = ring
    end
  end
  return best
end

-- A new read of the ring. Nests found before are kept.
local function start(fs, ring)
  local old = fs.clearing
  local x0, y0, x1, y1 = geometry.interior_chunks(ring)
  local c = {ring = ring.key, x0 = x0, y0 = y0, x1 = x1, y1 = y1, cx = x0, cy = y0, passes = 0, due = 0,
    found = 0, nests = old and old.nests or {}, next_id = old and old.next_id or 0}
  fs.clearing = c
  return c
end

-- Records a structure unless a known nest is within MERGE. True when a
-- new nest was added.
function M.add(c, surface_index, p)
  local r2 = M.MERGE * M.MERGE
  for _, nest in pairs(c.nests) do
    if nest.surface_index == surface_index and distance2(nest.position, p) <= r2 then return false end
  end
  c.next_id = c.next_id + 1
  c.nests[c.next_id] = {id = c.next_id, surface_index = surface_index, position = {x = p.x, y = p.y}}
  return true
end

-- A read ended. New nests wake parked constructors and the force hears of
-- them.
local function finish(fs, c, ring, tick)
  c.cx, c.cy = nil, nil
  c.passes, c.due = c.passes + 1, tick + M.RESCAN
  if c.found == 0 then return end
  fs.version = fs.version + 1
  local force = game.forces[ring.force_index]
  if force then force.print({'tank-squads.ring-nests', ring.n, c.found}) end
end

-- Reads the next chunks of the ring's interior: at most CHUNKS generated
-- ones and LOOKS in all.
function M.read(fs, ring, tick)
  local c = fs.clearing
  if not c or c.ring ~= ring.key then c = start(fs, ring) end
  if not c.cx then
    if tick < c.due then return end
    c.cx, c.cy, c.found = c.x0, c.y0, 0
  end
  local surface, force = game.surfaces[ring.surface_index], game.forces[ring.force_index]
  if not (surface and force) then return end
  local enemies = assault.enemy_forces(force)
  local read, looked = 0, 0
  while read < M.CHUNKS and looked < M.LOOKS do
    looked = looked + 1
    local cx, cy = c.cx, c.cy
    if #enemies > 0 and surface.is_chunk_generated({cx, cy}) then
      read = read + 1
      local x, y = cx * 32, cy * 32
      for _, e in pairs(surface.find_entities_filtered{area = {{x, y}, {x + 32, y + 32}}, type = TYPES,
          force = enemies}) do
        local p = e.position
        if geometry.interior(ring, p.x, p.y) and M.add(c, ring.surface_index, p) then c.found = c.found + 1 end
      end
    end
    if cx < c.x1 then
      c.cx = cx + 1
    elseif cy < c.y1 then
      c.cx, c.cy = c.x0, cy + 1
    else
      return finish(fs, c, ring, tick)
    end
  end
end

-- True while new segments of the ring wait: the outermost ring's first
-- read is not done, or a nest on the ring's surface is not blocked.
function M.holds(fs, ring, tick)
  local c, outer = fs.clearing, M.outermost(fs)
  if not (c and outer and c.ring == outer.key and c.passes > 0) then return true end
  for _, nest in pairs(c.nests) do
    if nest.surface_index == ring.surface_index and (nest.blocked or 0) <= tick then return true end
  end
  return false
end

local function nests_of(force_index)
  local s = state.peek()
  local fs = s and s.rings and s.rings[force_index]
  return fs and fs.clearing and fs.clearing.nests
end

-- The nearest nest on the constructor's surface that is not blocked and
-- not `busy` (a task force already fights it), or nil.
function M.claim(record, busy)
  local nests = nests_of(record.force_index)
  if not nests then return nil end
  local tick, p = game.tick, record.entity.position
  local best, best_d
  for _, nest in pairs(nests) do
    if nest.surface_index == record.surface_index and (nest.blocked or 0) <= tick and not busy(nest) then
      local d = distance2(nest.position, p)
      if not best_d or d < best_d then best, best_d = nest, d end
    end
  end
  return best
end

-- A surface was deleted: the nests found on it go.
function M.drop_surface(fs, surface_index)
  local c = fs.clearing
  if not c then return end
  for id, nest in pairs(c.nests) do
    if nest.surface_index == surface_index then c.nests[id] = nil end
  end
end

-- The nest is gone.
function M.drop(force_index, id)
  local nests = nests_of(force_index)
  if nests then nests[id] = nil end
end

-- The nest is too strong for now: it waits BLOCK ticks.
function M.block(force_index, id)
  local nests = nests_of(force_index)
  local nest = nests and nests[id]
  if nest then nest.blocked = game.tick + M.BLOCK end
end

-- Each sweep slice (all when phase is nil): every force with an
-- autonomous constructor reads on in its outermost ring.
function M.tick(phase)
  local s = state.peek()
  if not (s and s.rings) then return end
  local forces
  for _, record in pairs(s.constructors) do
    if record.autonomous then
      forces = forces or {}
      forces[record.force_index] = true
    end
  end
  if not forces then return end
  local tick = game.tick
  for force_index in pairs(forces) do
    local fs = s.rings[force_index]
    local ring = fs and M.outermost(fs)
    if ring then M.read(fs, ring, tick) end
  end
end

return M
