-- Rings: fortress walls that autonomous constructors build round a centre,
-- ring after ring outward. A ring is planned one segment at a time, when a
-- constructor reaches it, into ordinary wall and gate ghosts that the
-- constructors' work loop builds. Rings belong to a force and live on one
-- surface.
--
-- storage.engineers.rings[force_index] = {settings = {shape, spacing, count,
--   surface_index, centre}, slots[n] = ring, version, mark, mark_circle,
--   clearing (clearing.lua)}
-- ring = {key, n, force_index, surface_index, centre, radius, shape, state,
--   count, segments[i], bulges, crossings[key], released[tile key], labels,
--   gatehouses[i], announced, closed, audit, teardown, purge_tick, garrison,
--   placing[i] = true for segments with tiles still to place}
-- closed is true once every segment was built; from then on units cross
-- the ring through its gatehouses (crossing.lua).
-- ring.state is 'building', 'built', 'tearing_down' or 'deleted'.
-- segment = {state, live, ghosts[unit_number] = {entity, position}, due,
--   pending = {tiles, next}: planned tiles not placed yet}
-- segment.state is 'unplanned', 'generating', 'placed' or 'built'.
-- storage.engineers.ring_ghosts[unit_number] = {ring = key, segment = i}
local state = require('scripts.engineers.state')
local ghosts = require('scripts.engineers.ghosts')
local geometry = require('scripts.engineers.rings.geometry')
local layout = require('scripts.engineers.rings.layout')
local obstacles = require('scripts.engineers.rings.obstacles')
local dismantle = require('scripts.engineers.rings.dismantle')
local clearing = require('scripts.engineers.rings.clearing')

local M = {}

M.DEFAULTS = {shape = 'square', spacing = 200, count = 3}
M.SPACING = {100, 1000}
M.COUNT = {1, 20}
-- A new ring starts at least this far outside the ring before it: past
-- that ring's deepest possible bulge.
M.GAP = 80
-- Ticks before a segment whose chunks were requested is tried again.
M.RETRY = 2 * 60
M.CROSSING_CHECK = 5 * 3600
M.LABEL_DEPTH = 12
-- Ticks between counting off walls robots took during a tear-down.
M.PURGE = 10 * 60
-- Ghosts the audit reads per call, once per second per ring.
M.AUDIT_BATCH = 64
-- Ghosts placed per sweep slice, and at once when a segment is planned.
M.PLACE_BATCH = 64

-- Set by crossing.lua (on_segment_built, on_breach) and garrison.lua
-- (on_teardown).
M.on_segment_built = nil
M.on_breach = nil
M.on_teardown = nil

local function all()
  local s = state.get()
  s.rings = s.rings or {}
  return s.rings
end

-- The force's rings, or nil without creating them.
function M.peek(force_index)
  local s = state.peek()
  return s and s.rings and s.rings[force_index]
end

function M.force_state(force_index)
  local list = all()
  local fs = list[force_index]
  if not fs then
    fs = {settings = {shape = M.DEFAULTS.shape, spacing = M.DEFAULTS.spacing, count = M.DEFAULTS.count},
      slots = {}, version = 0}
    list[force_index] = fs
  end
  return fs
end

-- Grows on every change idle autonomous constructors should look at.
function M.version(force_index)
  local fs = M.peek(force_index)
  return fs and fs.version or 0
end

function M.bump(fs)
  fs.version = fs.version + 1
end

function M.key(force_index, n)
  return force_index .. ':' .. n
end

function M.by_key(key)
  local force_index, n = string.match(key or '', '^(%d+):(%d+)$')
  local fs = force_index and M.peek(tonumber(force_index))
  return fs and fs.slots[tonumber(n)]
end

local function tile_key(position)
  return math.floor(position.x) .. ',' .. math.floor(position.y)
end
M.tile_key = tile_key

-- Changes one setting; values are clamped. Returns the value kept.
function M.set(force_index, name, value)
  local fs = M.force_state(force_index)
  local settings = fs.settings
  if name == 'shape' then
    if value ~= 'square' and value ~= 'circle' then return settings.shape end
    settings.shape = value
  elseif name == 'spacing' or name == 'count' then
    local range = name == 'spacing' and M.SPACING or M.COUNT
    value = tonumber(value)
    if not value then return settings[name] end
    settings[name] = math.max(range[1], math.min(range[2], math.floor(value)))
  else
    return nil
  end
  M.bump(fs)
  return settings[name]
end

function M.draw_centre(fs, force, surface)
  if fs.mark and fs.mark.valid then fs.mark.destroy() end
  if fs.mark_circle and fs.mark_circle.valid then fs.mark_circle.destroy() end
  local c = fs.settings.centre
  local target = {x = c.x + 0.5, y = c.y + 0.5}
  fs.mark = rendering.draw_text{text = {'tank-squads.ring-centre-label'}, surface = surface, target = target,
    color = {1, 0.8, 0.2}, forces = {force}, render_mode = 'chart', alignment = 'center', scale = 2}
  fs.mark_circle = rendering.draw_circle{color = {1, 0.8, 0.2}, radius = 4, width = 2, filled = false,
    target = target, surface = surface, forces = {force}, render_mode = 'chart'}
end

-- The ring centre: a tile on a surface. Rings not started yet use it.
function M.set_centre(force, surface, position)
  local fs = M.force_state(force.index)
  fs.settings.surface_index = surface.index
  fs.settings.centre = {x = math.floor(position.x), y = math.floor(position.y)}
  M.draw_centre(fs, force, surface)
  M.bump(fs)
  return fs.settings.centre
end

function M.clear_labels(ring)
  for _, label in ipairs(ring.labels or {}) do
    if label.valid then label.destroy() end
  end
  ring.labels = {}
end

-- "Ring n" on the map just outside the teeth, at each side's centre (a
-- circle's north, east, south and west).
function M.draw_labels(ring, force, surface)
  M.clear_labels(ring)
  local points
  if ring.shape == 'circle' then
    local q = geometry.TAU * ring.radius / 4
    points = {{0, 0}, {0, q}, {0, 2 * q}, {0, 3 * q}}
  else
    points = {{1, 0}, {2, 0}, {3, 0}, {4, 0}}
  end
  for _, p in ipairs(points) do
    ring.labels[#ring.labels + 1] = rendering.draw_text{text = {'tank-squads.ring-label', ring.n}, surface = surface,
      target = geometry.to_position(ring, p[1], p[2], M.LABEL_DEPTH), color = {1, 1, 1}, forces = {force},
      render_mode = 'chart', alignment = 'center', scale = 1.5, scale_with_zoom = true}
  end
end

-- Starts slot n from the current settings. Without a picked centre the ring
-- goes round the force's spawn on the given surface.
function M.start(fs, force, n, surface)
  local settings = fs.settings
  local surface_index = settings.surface_index or surface.index
  local ring_surface = game.surfaces[surface_index]
  local centre = settings.centre
  -- A centre picked on a surface since deleted no longer counts.
  if not ring_surface then surface_index, ring_surface, centre = surface.index, surface, nil end
  if not centre then
    local p = force.get_spawn_position(ring_surface)
    centre = {x = math.floor(p.x), y = math.floor(p.y)}
  end
  local radius = n * settings.spacing
  for m = n - 1, 1, -1 do
    local before = fs.slots[m]
    if before and before.state ~= 'deleted' and before.surface_index == surface_index then
      radius = math.max(radius, before.radius + M.GAP)
      break
    end
  end
  local ring = {key = M.key(force.index, n), n = n, force_index = force.index, surface_index = surface_index,
    centre = centre, radius = radius, shape = settings.shape, state = 'building', segments = {}, bulges = {},
    crossings = {}, released = {}, labels = {}, gatehouses = {}}
  ring.count = geometry.segment_count(ring)
  for i = 1, ring.count do ring.segments[i] = {state = 'unplanned', live = 0, ghosts = {}} end
  fs.slots[n] = ring
  M.draw_labels(ring, force, ring_surface)
  M.bump(fs)
  return ring
end

local function open(seg, tick)
  return seg.state == 'unplanned' or (seg.state == 'generating' and tick >= seg.due)
end

-- The ring autonomous constructors work on: the lowest slot up to the ring
-- count, not deleted, with a segment left to plan. A free slot is started.
function M.current(fs, force, surface)
  for n = 1, fs.settings.count do
    local ring = fs.slots[n]
    if not ring then return M.start(fs, force, n, surface) end
    if ring.state == 'building' then
      for _, seg in ipairs(ring.segments) do
        if seg.state == 'unplanned' or seg.state == 'generating' then return ring end
      end
    end
  end
  return nil
end

-- The segment to plan next: open and nearest the position.
function M.next_segment(ring, position, tick)
  local best, best_d
  for i, seg in ipairs(ring.segments) do
    if open(seg, tick) then
      local s = geometry.segment(ring, i)
      local p = geometry.to_position(ring, s.side, (s.lo + s.hi) / 2, 0)
      local dx, dy = p.x - position.x, p.y - position.y
      local d = dx * dx + dy * dy
      if not best_d or d < best_d then best, best_d = i, d end
    end
  end
  return best
end

-- True while a segment waits for its chunks.
function M.waiting(ring, tick)
  for _, seg in ipairs(ring.segments) do
    if seg.state == 'generating' and tick < seg.due then return true end
  end
  return false
end

-- A wall or gate ghost on the tile, or nil where something stands. Trees
-- and rocks give way.
function M.create_ghost(surface, force, tile)
  local spec = {name = 'entity-ghost', inner_name = tile.name, position = {x = tile.x, y = tile.y},
    direction = defines.direction[tile.dir], force = force, build_check_type = defines.build_check_type.manual_ghost}
  local ghost = surface.create_entity(spec)
  if ghost then return ghost end
  local area = {{tile.x - 0.5, tile.y - 0.5}, {tile.x + 0.5, tile.y + 0.5}}
  local cleared = false
  for _, e in pairs(surface.find_entities_filtered{area = area, type = {'tree', 'simple-entity'}}) do
    e.destroy()
    cleared = true
  end
  if cleared then return surface.create_entity(spec) end
  return nil
end

-- Makes a ghost part of segment i and of the constructors' registry.
function M.tag(ring, i, ghost)
  local s = state.get()
  s.ring_ghosts = s.ring_ghosts or {}
  local seg = ring.segments[i]
  local id = ghost.unit_number
  if seg.ghosts[id] then return end
  local p = ghost.position
  s.ring_ghosts[id] = {ring = ring.key, segment = i}
  seg.ghosts[id] = {entity = ghost, position = {x = p.x, y = p.y}}
  seg.live = seg.live + 1
  ghosts.add(ghost)
end

-- Places the planned tiles of segment i that are not released. With
-- `only`, just the tiles along only.a0 .. only.a1.
function M.place(ring, i, tiles, surface, force, only)
  for _, t in ipairs(tiles) do
    if not ring.released[tile_key(t)] and (not only or (t.a >= only.a0 and t.a <= only.a1)) then
      local ghost = M.create_ghost(surface, force, t)
      if ghost then M.tag(ring, i, ghost) end
    end
  end
end

local function horizontal(direction)
  return direction == defines.direction.east or direction == defines.direction.west
end

-- Older versions placed gates crosswise to the wall line, so they never
-- joined. Turns every gate ghost on a standing ring's band to face along
-- it; a built gate is built again facing the right way. Returns how many were turned.
function M.turn_gates(ring)
  local surface, force = game.surfaces[ring.surface_index], game.forces[ring.force_index]
  if not (surface and force) or (ring.state ~= 'building' and ring.state ~= 'built') then return 0 end
  local turned = 0
  for i = 1, ring.count do
    local found = surface.find_entities_filtered{area = obstacles.band_area(ring, geometry.segment(ring, i)),
      force = force, type = {'gate', 'entity-ghost'}}
    for _, e in pairs(found) do
      local p = e.position
      if e.valid and (e.type == 'gate' or e.ghost_type == 'gate') and geometry.in_band(ring, p.x, p.y) then
        local want = defines.direction[layout.gate_dir(ring, p.x, p.y)]
        if horizontal(e.direction) ~= horizontal(want) then
          if e.type == 'entity-ghost' then
            e.direction = want
          else
            local name, position, health = e.name, {x = p.x, y = p.y}, e.health
            e.destroy()
            local gate = surface.create_entity{name = name, position = position, direction = want, force = force}
            if gate then gate.health = health end
          end
          turned = turned + 1
        end
      end
    end
  end
  return turned
end

-- Depth runs outward along these on a square's sides.
local NORMAL = {{1, 0}, {0, 1}, {-1, 0}, {0, -1}}

-- Older versions built gates in the middle wall row only. Beside every
-- gate or gate ghost there of a planned segment, the rows inside and
-- outside get gate ghosts, and the segment is built again. Returns how many
-- ghosts went up.
function M.widen_gates(ring)
  local surface, force = game.surfaces[ring.surface_index], game.forces[ring.force_index]
  if not (surface and force) or (ring.state ~= 'building' and ring.state ~= 'built') then return 0 end
  local added, touched = 0, {}
  for i = 1, ring.count do
    local planned = ring.segments[i].state
    if planned == 'placed' or planned == 'built' then
      local seg = geometry.segment(ring, i)
      local found = surface.find_entities_filtered{area = obstacles.band_area(ring, seg), force = force,
        type = {'gate', 'entity-ghost'}}
      for _, e in pairs(found) do
        local p = e.position
        if e.valid and (e.type == 'gate' or e.ghost_type == 'gate') then
          local side, along, depth = geometry.to_frame(ring, p.x, p.y)
          if math.abs(depth) < 0.5 and geometry.segment_of(ring, side, along) == i then
            local n = ring.shape == 'circle' and geometry.circle_house(ring, seg.gate) or nil
            local nx, ny = n and n.nx or NORMAL[side][1], n and n.ny or NORMAL[side][2]
            for _, d in ipairs({-1, 1}) do
              local tile = {x = p.x + d * nx, y = p.y + d * ny, name = 'gate', dir = layout.gate_dir(ring, p.x, p.y)}
              local box = {{tile.x - 0.4, tile.y - 0.4}, {tile.x + 0.4, tile.y + 0.4}}
              if not ring.released[tile_key(tile)]
                  and surface.count_entities_filtered{area = box, type = {'gate', 'wall', 'entity-ghost'}} == 0 then
                local ghost = M.create_ghost(surface, force, tile)
                if ghost then
                  M.tag(ring, i, ghost)
                  added, touched[i] = added + 1, true
                end
              end
            end
          end
        end
      end
    end
  end
  for i in pairs(touched) do ring.segments[i].state = 'placed' end
  if next(touched) then
    ring.state = 'building'
    M.bump(M.peek(ring.force_index))
  end
  return added
end

function M.clear_crossings(ring)
  for _, c in pairs(ring.crossings) do
    if c.tag and c.tag.valid then c.tag.destroy() end
  end
  ring.crossings = {}
end

-- Open crossings (not rail gates) of segment i get a map tag and a check
-- every CROSSING_CHECK ticks.
local function add_crossings(ring, i, list, force, surface)
  for _, c in ipairs(list) do
    if not c.rail then
      local key = i .. ':' .. c.side .. ':' .. c.a0
      if not ring.crossings[key] then
        local position = geometry.to_position(ring, c.side, (c.a0 + c.a1) / 2, 0)
        local tag = force.add_chart_tag(surface, {position = position, text = 'Ring ' .. ring.n .. ': open crossing'})
        ring.crossings[key] = {side = c.side, a0 = c.a0, a1 = c.a1, segment = i, tag = tag,
          due = game.tick + M.CROSSING_CHECK}
      end
    end
  end
end

-- Tiles in the order they go up: along the ring, from the segment end
-- nearest `from` (the planning constructor), so it builds in one sweep.
function M.sweep_order(ring, i, tiles, from)
  local seg = geometry.segment(ring, i)
  local dir = 1
  if from then
    local lo = geometry.to_position(ring, seg.side, seg.lo, 0)
    local hi = geometry.to_position(ring, seg.side, seg.hi, 0)
    local function d2(p) return (p.x - from.x) ^ 2 + (p.y - from.y) ^ 2 end
    if d2(hi) < d2(lo) then dir = -1 end
  end
  table.sort(tiles, function(p, q)
    if p.a ~= q.a then return (p.a - q.a) * dir < 0 end
    if p.x ~= q.x then return p.x < q.x end
    return p.y < q.y
  end)
  return tiles
end

-- Plans segment i and places its ghosts. Returns 'generating' (its chunks
-- were requested), 'placed', or 'built' when there was nothing to place.
-- `from` is where the planning constructor stands.
function M.plan_segment(ring, i, from)
  local surface, force = game.surfaces[ring.surface_index], game.forces[ring.force_index]
  local seg = ring.segments[i]
  local found = obstacles.scan(ring, surface, force, i)
  if not found then
    seg.state, seg.due = 'generating', game.tick + M.RETRY
    return 'generating'
  end
  for _, b in ipairs(found.bulges) do ring.bulges[#ring.bulges + 1] = b end
  add_crossings(ring, i, found.crossings, force, surface)
  local tiles = M.sweep_order(ring, i,
    layout.plan(ring, i, {bulges = ring.bulges, crossings = found.crossings, water = found.water}), from)
  seg.state = 'placed'
  if tiles[1] then
    seg.pending = {tiles = tiles, next = 1}
    ring.placing = ring.placing or {}
    ring.placing[i] = true
    M.place_pending(ring, i, M.PLACE_BATCH)
  end
  if seg.state == 'placed' and seg.live == 0 and not seg.pending then
    M.segment_built(ring, i)
  end
  return seg.state == 'built' and 'built' or 'placed'
end

-- Places up to `budget` of segment i's planned tiles. Returns how many
-- tiles it went through. A segment with nothing left to place and no
-- live ghost is built.
function M.place_pending(ring, i, budget)
  local seg = ring.segments[i]
  local pending = seg and seg.pending
  if not pending then
    if ring.placing then ring.placing[i] = nil end
    return 0
  end
  local tiles = pending.tiles
  local last = math.min(#tiles, pending.next + budget - 1)
  local batch = {}
  for k = pending.next, last do batch[#batch + 1] = tiles[k] end
  M.place(ring, i, batch, game.surfaces[ring.surface_index], game.forces[ring.force_index])
  pending.next = last + 1
  if pending.next > #tiles then
    seg.pending = nil
    ring.placing[i] = nil
    if seg.state == 'placed' and seg.live == 0 then M.segment_built(ring, i) end
  end
  return #batch
end

-- Every segment built: the ring is built. The force hears it once.
function M.segment_built(ring, i)
  ring.segments[i].state = 'built'
  if M.on_segment_built then M.on_segment_built(ring, i) end
  for _, seg in ipairs(ring.segments) do
    if seg.state ~= 'built' then return end
  end
  if ring.state ~= 'building' then return end
  ring.state, ring.closed = 'built', true
  if not ring.announced then
    ring.announced = true
    local force = game.forces[ring.force_index]
    if force then force.print({'tank-squads.ring-complete', ring.n}) end
  end
end

-- A ring ghost left the registry: built by the crane (built = true), or
-- found gone. A ghost gone with no wall on its tile was removed by a
-- player, so the tile is released and never planned again.
function M.ghost_gone(id, position, built)
  local s = state.peek()
  local tag = s and s.ring_ghosts and s.ring_ghosts[id]
  if not tag then return end
  s.ring_ghosts[id] = nil
  local ring = M.by_key(tag.ring)
  local seg = ring and ring.segments[tag.segment]
  if not (seg and seg.ghosts[id]) then return end
  seg.ghosts[id] = nil
  seg.live = seg.live - 1
  if not built and ring.state ~= 'tearing_down' then
    local surface = game.surfaces[ring.surface_index]
    local area = {{position.x - 0.4, position.y - 0.4}, {position.x + 0.4, position.y + 0.4}}
    if surface.count_entities_filtered{area = area, type = {'wall', 'gate'}, limit = 1} == 0 then
      ring.released[tile_key(position)] = true
    end
  end
  if seg.live <= 0 and seg.state == 'placed' and not seg.pending then M.segment_built(ring, tag.segment) end
end

-- Ghosts that vanished without passing the registry (robots built them,
-- a player removed them) are counted off, placed segment after placed
-- segment, at most AUDIT_BATCH ghosts per call. ring.audit = {i, ids, at}:
-- the segment read, its ghosts when the read began, and the next to check.
function M.audit(ring)
  if ring.count == 0 then return end
  local a = ring.audit
  if type(a) ~= 'table' or a.at > #a.ids then
    local start, found = type(a) == 'table' and a.i or 0, nil
    for k = 1, ring.count do
      local i = (start + k - 1) % ring.count + 1
      local seg = ring.segments[i]
      if seg and seg.state == 'placed' then
        found = i
        break
      end
    end
    if not found then
      ring.audit = nil
      return
    end
    local ids = {}
    for id in pairs(ring.segments[found].ghosts) do ids[#ids + 1] = id end
    a = {i = found, ids = ids, at = 1}
    ring.audit = a
  end
  local seg = ring.segments[a.i]
  local last = math.min(#a.ids, a.at + M.AUDIT_BATCH - 1)
  for k = a.at, last do
    local id = a.ids[k]
    local g = seg and seg.ghosts[id]
    if g and not g.entity.valid then M.ghost_gone(id, g.position, false) end
  end
  a.at = last + 1
end

-- Percent of segments built.
function M.progress(ring)
  if not ring.count or ring.count == 0 then return 0 end
  local built = 0
  for _, seg in ipairs(ring.segments) do
    if seg.state == 'built' then built = built + 1 end
  end
  return math.floor(built * 100 / ring.count)
end

-- The standing ring whose band holds the position, or nil.
function M.find(fs, surface_index, position)
  for _, ring in pairs(fs.slots) do
    if ring.surface_index == surface_index and ring.state ~= 'deleted'
        and geometry.in_band(ring, position.x, position.y) then
      return ring
    end
  end
  return nil
end

-- Where the constructor stands to build at a position on a ring's band:
-- off the band, on the side of the ring it is on now. Nil off every band.
function M.stand(record, position)
  local fs = M.peek(record.force_index)
  local ring = fs and M.find(fs, record.surface_index, position)
  if not ring then return nil end
  local p = record.entity.position
  return geometry.stand(ring, position.x, position.y, (geometry.side(ring, p.x, p.y)))
end

-- The segments other constructors of the force are working on, as
-- ring .. ':' .. index.
local function taken_by_others(record)
  local s = state.peek()
  local out = {}
  for id, other in pairs(s and s.constructors or {}) do
    if id ~= record.id and other.force_index == record.force_index and other.segment then
      out[other.segment.ring .. ':' .. other.segment.index] = true
    end
  end
  return out
end

local function distance2(a, b)
  local dx, dy = a.x - b.x, a.y - b.y
  return dx * dx + dy * dy
end

local function middle(ring, i)
  local seg = geometry.segment(ring, i)
  return geometry.to_position(ring, seg.side, (seg.lo + seg.hi) / 2, 0)
end

-- Places a batch of the nearest segment still placing on the
-- constructor's surface and not in `skip`, within `within` squared tiles
-- of its middle. True when a ghost went up.
local function place_nearest(record, skip, within)
  local position = record.entity.position
  local best_ring, best_i, best_d
  for _, ring in pairs(M.force_state(record.force_index).slots) do
    if ring.placing and ring.surface_index == record.surface_index then
      for i in pairs(ring.placing) do
        if not skip[ring.key .. ':' .. i] then
          local d = distance2(middle(ring, i), position)
          if d <= within and (not best_d or d < best_d) then best_ring, best_i, best_d = ring, i, d end
        end
      end
    end
  end
  return best_ring ~= nil and M.place_pending(best_ring, best_i, M.PLACE_BATCH) > 0
end

-- Work for an autonomous constructor: walls of a ring being torn down,
-- then its own segment, swept along the ring from where it stands. Then
-- whichever is nearer: ring ghosts no other constructor works on (a
-- breach, a segment whose constructor left) or a new segment planned for
-- it (one per tick for all constructors), once no nest inside the rings
-- waits (clearing.lua). Only when no segment is left to plan does it help
-- with the segments of others, nearest first. Returns a cluster and
-- 'dismantle' or 'build', or nil and 'planning' (ask again next second) or
-- 'done' (nothing left).
function M.claim(record, radius, max)
  local taken = dismantle.claim(record, radius, max)
  if taken then return taken, 'dismantle' end
  local entity = record.entity
  local position = entity.position
  local own = record.segment
  if own then
    local ring = M.by_key(own.ring)
    local seg = ring and ring.segments[own.index]
    local filter = {ring = own.ring, segment = own.index, near = position,
      score = ring and geometry.sweep_score(ring, position), ghosts = seg and seg.ghosts}
    local cluster = ghosts.claim(record, radius, max, filter)
    if cluster then return cluster, 'build' end
    -- Nothing placed is left: the next batch of its segment goes up now.
    if ring and ring.placing and ring.placing[own.index] and M.place_pending(ring, own.index, M.PLACE_BATCH) > 0 then
      cluster = ghosts.claim(record, radius, max, filter)
      if cluster then return cluster, 'build' end
    end
  end
  local skip = taken_by_others(record)
  local fs = M.force_state(record.force_index)
  local ring = M.current(fs, entity.force, entity.surface)
  if ring and ring.surface_index ~= record.surface_index then ring = nil end
  local tick, s = game.tick, state.get()
  local i = ring and M.next_segment(ring, position, tick)
  local within = i and distance2(middle(ring, i), position) or math.huge
  local filter = {ring = true, skip = skip, within = within}
  local cluster = ghosts.claim(record, radius, max, filter)
  if cluster then return cluster, 'build' end
  if place_nearest(record, skip, within) then
    cluster = ghosts.claim(record, radius, max, filter)
    if cluster then return cluster, 'build' end
  end
  if not i then
    -- Nothing left to plan: help the others, nearest first.
    cluster = ghosts.claim(record, radius, max, {ring = true})
    if cluster then return cluster, 'build' end
    if place_nearest(record, {}, math.huge) then
      cluster = ghosts.claim(record, radius, max, {ring = true})
      if cluster then return cluster, 'build' end
    end
    if not ring then return nil, 'done' end
    return nil, M.waiting(ring, tick) and 'planning' or 'done'
  end
  -- Nests inside the rings go first (clearing.lua).
  if clearing.holds(fs, ring, tick) then return nil, 'planning' end
  if s.plan_tick == tick then return nil, 'planning' end
  s.plan_tick = tick
  local result = M.plan_segment(ring, i, position)
  record.segment = {ring = ring.key, index = i}
  if result == 'placed' then
    cluster = ghosts.claim(record, radius, max, {ring = ring.key, segment = i, near = position,
      score = geometry.sweep_score(ring, position), ghosts = ring.segments[i].ghosts})
    if cluster then return cluster, 'build' end
  end
  return nil, 'planning'
end

-- A ring wall or gate died: biters broke through. Its ghost goes back up
-- (the one the force left, or a new one) and the segment is built again.
-- Released tiles stay open; walls of other kinds are not ring walls. The
-- event names the killer's force, not the wall's: the wall's force is the
-- ghost's, or that of the ring whose band holds the tile.
function M.on_wall_died(event)
  local s = state.peek()
  if not (s and s.rings) then return end
  local prototype, p = event.prototype, event.position
  if not (prototype and (prototype.name == 'stone-wall' or prototype.name == 'gate')) then return end
  local ghost = event.ghost
  local ring
  if ghost and ghost.valid then
    local fs = s.rings[ghost.force_index]
    ring = fs and M.find(fs, event.surface_index, p)
  else
    ghost = nil
    for _, fs in pairs(s.rings) do
      ring = M.find(fs, event.surface_index, p)
      if ring then break end
    end
  end
  if not ring or (ring.state ~= 'building' and ring.state ~= 'built') or ring.released[tile_key(p)] then return end
  local side, along = geometry.to_frame(ring, p.x, p.y)
  local i = geometry.segment_of(ring, side, along)
  local seg = ring.segments[i]
  -- A segment not planned yet plans this tile itself.
  if seg.state ~= 'placed' and seg.state ~= 'built' then return end
  if not ghost then
    ghost = M.create_ghost(game.surfaces[event.surface_index], game.forces[ring.force_index],
      {x = p.x, y = p.y, name = prototype.name, dir = layout.gate_dir(ring, p.x, p.y)})
  end
  if not ghost then return end
  M.tag(ring, i, ghost)
  seg.state, ring.state = 'placed', 'building'
  if M.on_breach then M.on_breach(ring, i) end
  M.bump(M.peek(ring.force_index))
end

-- A player or robot mined a ring wall or gate: the tile stays open.
function M.on_wall_mined(entity)
  if not (entity and entity.valid) then return end
  local fs = M.peek(entity.force_index)
  if not fs then return end
  local p = entity.position
  local ring = M.find(fs, entity.surface_index, p)
  if ring and (ring.state == 'building' or ring.state == 'built') then ring.released[tile_key(p)] = true end
end

-- Deletes ring n: its unbuilt ghosts go at once; its walls are marked for
-- deconstruction segment by segment (sweep_teardown) and autonomous
-- constructors take them down. False when ring n is not standing.
function M.delete(force_index, n)
  local fs = M.peek(force_index)
  local ring = fs and fs.slots[n]
  if not ring or (ring.state ~= 'building' and ring.state ~= 'built') then return false end
  local s = state.get()
  for _, seg in ipairs(ring.segments) do
    for id, g in pairs(seg.ghosts) do
      if s.ring_ghosts then s.ring_ghosts[id] = nil end
      if g.entity.valid then g.entity.destroy() end
    end
    seg.ghosts, seg.live, seg.pending = {}, 0, nil
  end
  ring.state, ring.teardown, ring.gatehouses, ring.placing = 'tearing_down', 1, {}, nil
  M.clear_labels(ring)
  M.clear_crossings(ring)
  if M.on_teardown then M.on_teardown(ring) end
  M.bump(fs)
  return true
end

-- A deleted slot is free again; the next ring there is planned afresh
-- from the current settings.
function M.again(force_index, n)
  local fs = M.peek(force_index)
  local ring = fs and fs.slots[n]
  if not ring or ring.state ~= 'deleted' then return false end
  fs.slots[n] = nil
  M.bump(fs)
  return true
end

-- Untags the ring's ghosts and drops its walls to take down, labels,
-- crossing tags and garrison. Its walls and ghosts stay as ordinary
-- entities.
local function let_go(s, ring)
  for _, seg in ipairs(ring.segments) do
    for id in pairs(seg.ghosts) do
      if s.ring_ghosts then s.ring_ghosts[id] = nil end
    end
  end
  dismantle.clear(ring.key)
  M.clear_labels(ring)
  M.clear_crossings(ring)
  if M.on_teardown then M.on_teardown(ring) end
end

local function clear_mark(fs)
  if fs.mark and fs.mark.valid then fs.mark.destroy() end
  if fs.mark_circle and fs.mark_circle.valid then fs.mark_circle.destroy() end
  fs.mark, fs.mark_circle = nil, nil
end

-- A force merged into another lets its rings go. Its walls and ghosts,
-- now the other force's, stay as ordinary entities; its garrisons stop.
function M.release_force(force_index)
  local fs = M.peek(force_index)
  if not fs then return end
  local s = state.get()
  for _, ring in pairs(fs.slots) do let_go(s, ring) end
  clear_mark(fs)
  s.rings[force_index] = nil
end

function M.finish_teardown(ring)
  dismantle.clear(ring.key)
  M.clear_labels(ring)
  ring.state, ring.teardown, ring.purge_tick = 'deleted', nil, nil
  ring.segments, ring.bulges, ring.released, ring.gatehouses, ring.garrison = {}, {}, {}, {}, nil
  local force = game.forces[ring.force_index]
  if force then force.print({'tank-squads.ring-removed', ring.n}) end
  M.bump(M.peek(ring.force_index))
end

-- A surface was deleted: every ring on it is deleted, as after a tear-down,
-- and a ring centre picked there is forgotten, so new rings go round the
-- spawn of the surface their constructor stands on.
function M.drop_surface(surface_index)
  local s = state.peek()
  if not (s and s.rings) then return end
  for _, fs in pairs(s.rings) do
    if fs.settings.surface_index == surface_index then
      clear_mark(fs)
      fs.settings.surface_index, fs.settings.centre = nil, nil
      M.bump(fs)
    end
    clearing.drop_surface(fs, surface_index)
    for _, ring in pairs(fs.slots) do
      if ring.surface_index == surface_index and ring.state ~= 'deleted' then
        let_go(s, ring)
        ring.placing, ring.audit = nil, nil
        M.finish_teardown(ring)
      end
    end
  end
end

-- One segment per call: its walls and gates are marked for deconstruction
-- and registered. After the last segment, the ring is deleted once no wall
-- is left; walls robots took are counted off every PURGE ticks.
function M.sweep_teardown(ring, tick)
  if ring.teardown <= ring.count then
    local i = ring.teardown
    ring.teardown = i + 1
    local surface, force = game.surfaces[ring.surface_index], game.forces[ring.force_index]
    local seg = geometry.segment(ring, i)
    local found = surface.find_entities_filtered{area = obstacles.band_area(ring, seg), type = {'wall', 'gate'},
      force = force}
    for _, wall in pairs(found) do
      local p = wall.position
      if geometry.in_band(ring, p.x, p.y) then
        local side, along = geometry.to_frame(ring, p.x, p.y)
        if geometry.segment_of(ring, side, along) == i then
          wall.order_deconstruction(force)
          dismantle.add(ring, wall)
        end
      end
    end
    return
  end
  if dismantle.count(ring.key) > 0 and tick >= (ring.purge_tick or 0) then
    ring.purge_tick = tick + M.PURGE
    dismantle.purge(ring.key)
  end
  if dismantle.count(ring.key) == 0 then M.finish_teardown(ring) end
end

-- An open crossing whose belt, pipe or rail has gone is walled up: its
-- tiles are planned and placed, and its map tag goes.
function M.recheck_crossings(ring, tick)
  for key, c in pairs(ring.crossings) do
    if tick >= c.due then
      c.due = tick + M.CROSSING_CHECK
      local surface, force = game.surfaces[ring.surface_index], game.forces[ring.force_index]
      if not obstacles.crossing_present(ring, surface, force, c) then
        local found = obstacles.scan(ring, surface, force, c.segment)
        if found then
          if c.tag and c.tag.valid then c.tag.destroy() end
          ring.crossings[key] = nil
          local tiles = layout.plan(ring, c.segment, {bulges = ring.bulges, crossings = found.crossings,
            water = found.water})
          local seg = ring.segments[c.segment]
          local before = seg.live
          M.place(ring, c.segment, tiles, surface, force, {a0 = c.a0, a1 = c.a1})
          if seg.live > before then
            seg.state, ring.state = 'placed', 'building'
            M.bump(M.peek(ring.force_index))
          end
        end
      end
    end
  end
end

-- Every sweep slice (all of them when phase is nil) a ring being torn
-- down marks one more segment. Once per second each standing ring checks
-- one placed segment for vanished ghosts, and its open crossings.
function M.tick(phase)
  local s = state.peek()
  if not (s and s.rings) then return end
  local tick, budget = game.tick, M.PLACE_BATCH
  for _, fs in pairs(s.rings) do
    for _, ring in pairs(fs.slots) do
      if budget > 0 and ring.placing and (ring.state == 'building' or ring.state == 'built') then
        for i in pairs(ring.placing) do
          budget = budget - M.place_pending(ring, i, budget)
          if budget <= 0 then break end
        end
      end
      if ring.state == 'tearing_down' then
        M.sweep_teardown(ring, tick)
      elseif (phase == nil or phase == 0) and (ring.state == 'building' or ring.state == 'built') then
        M.audit(ring)
        M.recheck_crossings(ring, tick)
      end
    end
  end
end

ghosts.on_ring_gone = M.ghost_gone

return M
