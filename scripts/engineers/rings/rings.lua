-- Rings: fortress walls that autonomous constructors build round a centre,
-- ring after ring outward. A ring is planned one segment at a time, when a
-- constructor reaches it, into ordinary wall and gate ghosts that the
-- constructors' work loop builds. Rings belong to a force and live on one
-- surface.
--
-- storage.engineers.rings[force_index] = {settings = {shape, spacing, count,
--   surface_index, centre}, slots[n] = ring, version, mark, mark_circle}
-- ring = {key, n, force_index, surface_index, centre, radius, shape, state,
--   count, segments[i], bulges, crossings[key], released[tile key], labels,
--   gatehouses[i], announced, audit, teardown, purge_tick, garrison}
-- ring.state is 'building', 'built', 'tearing_down' or 'deleted'.
-- segment = {state, live, ghosts[unit_number] = {entity, position}, due}
-- segment.state is 'unplanned', 'generating', 'placed' or 'built'.
-- storage.engineers.ring_ghosts[unit_number] = {ring = key, segment = i}
local state = require('scripts.engineers.state')
local ghosts = require('scripts.engineers.ghosts')
local geometry = require('scripts.engineers.rings.geometry')
local layout = require('scripts.engineers.rings.layout')
local obstacles = require('scripts.engineers.rings.obstacles')

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
      render_mode = 'chart', alignment = 'center', scale = 3, scale_with_zoom = true}
  end
end

-- Starts slot n from the current settings. Without a picked centre the ring
-- goes round the force's spawn on the given surface.
function M.start(fs, force, n, surface)
  local settings = fs.settings
  local surface_index = settings.surface_index or surface.index
  local ring_surface = game.surfaces[surface_index]
  local centre = settings.centre
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

-- Plans segment i and places its ghosts. Returns 'generating' (its chunks
-- were requested), 'placed', or 'built' when there was nothing to place.
function M.plan_segment(ring, i)
  local surface, force = game.surfaces[ring.surface_index], game.forces[ring.force_index]
  local seg = ring.segments[i]
  local found = obstacles.scan(ring, surface, force, i)
  if not found then
    seg.state, seg.due = 'generating', game.tick + M.RETRY
    return 'generating'
  end
  for _, b in ipairs(found.bulges) do ring.bulges[#ring.bulges + 1] = b end
  add_crossings(ring, i, found.crossings, force, surface)
  local tiles = layout.plan(ring, i, {bulges = ring.bulges, crossings = found.crossings, water = found.water})
  seg.state = 'placed'
  M.place(ring, i, tiles, surface, force)
  if seg.live == 0 then
    M.segment_built(ring, i)
    return 'built'
  end
  return 'placed'
end

-- Every segment built: the ring is built. The force hears it once.
function M.segment_built(ring, i)
  ring.segments[i].state = 'built'
  if M.on_segment_built then M.on_segment_built(ring, i) end
  for _, seg in ipairs(ring.segments) do
    if seg.state ~= 'built' then return end
  end
  if ring.state ~= 'building' then return end
  ring.state = 'built'
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
  if seg.live <= 0 and seg.state == 'placed' then M.segment_built(ring, tag.segment) end
end

-- One placed segment per call, in turn: ghosts that vanished without
-- passing the registry (robots built them, a player removed them) are
-- counted off.
function M.audit(ring)
  if ring.count == 0 then return end
  ring.audit = (ring.audit or 0) % ring.count + 1
  local seg = ring.segments[ring.audit]
  if not (seg and seg.state == 'placed') then return end
  for id, g in pairs(seg.ghosts) do
    if not g.entity.valid then M.ghost_gone(id, g.position, false) end
  end
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

-- Work for an autonomous constructor: ring ghosts, its own segment first,
-- or a new segment planned for it (one per tick for all constructors).
-- Returns a cluster and 'build', or nil and 'planning' (ask again next
-- second) or 'done' (nothing left).
function M.claim(record, radius, max)
  local own = record.segment
  if own then
    local cluster = ghosts.claim(record, radius, max, {ring = own.ring, segment = own.index, near = own.near})
    if cluster then return cluster, 'build' end
  end
  local cluster = ghosts.claim(record, radius, max, {ring = true})
  if cluster then return cluster, 'build' end
  local entity = record.entity
  local ring = M.current(M.force_state(record.force_index), entity.force, entity.surface)
  if not ring or ring.surface_index ~= record.surface_index then return nil, 'done' end
  local tick, s = game.tick, state.get()
  if s.plan_tick == tick then return nil, 'planning' end
  local i = M.next_segment(ring, entity.position, tick)
  if not i then return nil, M.waiting(ring, tick) and 'planning' or 'done' end
  s.plan_tick = tick
  local result = M.plan_segment(ring, i)
  local seg = geometry.segment(ring, i)
  record.segment = {ring = ring.key, index = i, near = geometry.to_position(ring, seg.side, (seg.lo + seg.hi) / 2, 0)}
  if result == 'placed' then
    cluster = ghosts.claim(record, radius, max, {ring = ring.key, segment = i, near = record.segment.near})
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

ghosts.on_ring_gone = M.ghost_gone

return M
