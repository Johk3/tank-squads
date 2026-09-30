-- Engine reads for planning one ring segment: chunk generation, the
-- force's buildings and ghosts, cliffs, crossings and water. The result is
-- handed to layout.plan.
local geometry = require('scripts.engineers.rings.geometry')
local layout = require('scripts.engineers.rings.layout')

local M = {}

-- Tiles read beyond each end of the segment, so a bulge reaching into it
-- from a neighbour is seen whole.
M.MARGIN = layout.MAX_LENGTH
-- Rows read outward: the band, the deepest bulge and its clearance.
M.SCAN_DEPTH = 5 + layout.MAX_DEPTH + layout.CLEARANCE
-- Entities that never bend a ring: units, vehicles, robots, walls and what
-- lies on the ground.
M.SKIP = {unit = true, character = true, car = true, ['spider-vehicle'] = true, wall = true, gate = true,
  locomotive = true, ['cargo-wagon'] = true, ['fluid-wagon'] = true, ['artillery-wagon'] = true,
  ['combat-robot'] = true, ['construction-robot'] = true, ['logistic-robot'] = true, corpse = true,
  ['character-corpse'] = true, ['item-entity'] = true, ['item-request-proxy'] = true, ['tile-ghost'] = true,
  ['deconstructible-tile-proxy'] = true, ['highlight-box'] = true}
-- Lines through a ring: a gap (or rail gates) instead of a bulge.
M.CROSSING = {['transport-belt'] = true, ['underground-belt'] = true, pipe = true, ['pipe-to-ground'] = true,
  ['heat-pipe'] = true, ['straight-rail'] = true, ['curved-rail-a'] = true, ['curved-rail-b'] = true,
  ['half-diagonal-rail'] = true, ['legacy-straight-rail'] = true, ['legacy-curved-rail'] = true}
local CROSSING_TYPES = {}
for kind in pairs(M.CROSSING) do CROSSING_TYPES[#CROSSING_TYPES + 1] = kind end
table.sort(CROSSING_TYPES)

local function box(x0, y0, x1, y1)
  return {left_top = {x = x0, y = y0}, right_bottom = {x = x1, y = y1}}
end

-- The world area of along lo .. hi and rows d0 .. d1 on a segment's side.
function M.area(ring, seg, lo, hi, d0, d1)
  if ring.shape == 'circle' then
    local x0, y0, x1, y1 = layout.circle_box(ring, {lo = lo, hi = hi}, d0, d1)
    return box(x0, y0, x1 + 1, y1 + 1)
  end
  local ax, ay = geometry.to_tile(ring, seg.side, lo, d0)
  local bx, by = geometry.to_tile(ring, seg.side, hi, d1)
  return box(math.min(ax, bx), math.min(ay, by), math.max(ax, bx) + 1, math.max(ay, by) + 1)
end

-- The outermost row a segment's walls may take: the band, or the front of
-- a stored bulge reaching it.
function M.depth(ring, seg)
  local deep = 5
  for _, b in ipairs(ring.bulges) do
    if b.side == seg.side and b.kind == 'bulge' and b.a1 + 4 >= seg.lo and b.a0 - 4 <= seg.hi then
      deep = math.max(deep, b.depth + 5)
    end
  end
  return deep
end

function M.band_area(ring, seg)
  return M.area(ring, seg, seg.lo - 4, seg.hi + 4, -4, M.depth(ring, seg))
end

function M.generated(surface, area)
  local lt, rb = area.left_top, area.right_bottom
  for cx = math.floor(lt.x / 32), math.floor((rb.x - 1) / 32) do
    for cy = math.floor(lt.y / 32), math.floor((rb.y - 1) / 32) do
      if not surface.is_chunk_generated({x = cx, y = cy}) then return false end
    end
  end
  return true
end

-- Along and depth ranges of a bounding box on the segment's frame. A circle
-- uses the box's centre and half its larger side.
local function frame_box(ring, seg, bb)
  local lt, rb = bb.left_top, bb.right_bottom
  if ring.shape == 'circle' then
    local C = geometry.TAU * ring.radius
    local _, a, d = geometry.to_frame(ring, (lt.x + rb.x) / 2, (lt.y + rb.y) / 2)
    a = seg.gate + (a - seg.gate + C / 2) % C - C / 2
    local h = math.max(rb.x - lt.x, rb.y - lt.y) / 2
    return math.floor(a - h), math.ceil(a + h), math.floor(d - h), math.ceil(d + h)
  end
  local a0, a1, d0, d1 = math.huge, -math.huge, math.huge, -math.huge
  local cx, cy = ring.centre.x, ring.centre.y
  for _, p in ipairs({{lt.x, lt.y}, {rb.x - 0.01, lt.y}, {lt.x, rb.y - 0.01}, {rb.x - 0.01, rb.y - 0.01}}) do
    local a, d = geometry.on_side(ring, seg.side, math.floor(p[1]) - cx, math.floor(p[2]) - cy)
    a0, a1, d0, d1 = math.min(a0, a), math.max(a1, a), math.min(d0, d), math.max(d1, d)
  end
  return a0, a1, d0, d1
end

-- A straight rail running across a square's wall line takes rail gates.
-- A circle never does: its gates would not line up.
local function across(ring, seg, e)
  if ring.shape == 'circle' or e.type ~= 'straight-rail' then return false end
  local dir = e.direction
  local horizontal = dir == defines.direction.east or dir == defines.direction.west
  local vertical = dir == defines.direction.north or dir == defines.direction.south
  if seg.side == 1 or seg.side == 3 then return horizontal end
  return vertical
end

-- Reads what stands round segment i. Returns nil while its chunks are being
-- generated (they are requested), else {bulges (new ones only), crossings,
-- water (a set of 'x,y' tile keys, out-of-map tiles included)}.
function M.scan(ring, surface, force, i)
  local seg = geometry.segment(ring, i)
  local own = M.area(ring, seg, seg.lo, seg.hi, -4, 6)
  if not M.generated(surface, own) then
    local lt, rb = own.left_top, own.right_bottom
    local radius = math.ceil(math.max(rb.x - lt.x, rb.y - lt.y) / 64) + 1
    surface.request_to_generate_chunks({x = (lt.x + rb.x) / 2, y = (lt.y + rb.y) / 2}, radius)
    return nil
  end
  local wide = M.area(ring, seg, seg.lo - M.MARGIN, seg.hi + M.MARGIN, -8, M.SCAN_DEPTH)
  local boxes, crossings, c = {}, {}, layout.CLEARANCE
  local function consider(e, kind)
    local a0, a1, d0, d1 = frame_box(ring, seg, e.bounding_box)
    if M.CROSSING[kind] then
      if d1 >= -1 and d0 <= 4 and a1 >= seg.lo - 4 and a0 <= seg.hi + 4 then
        crossings[#crossings + 1] = {side = seg.side, a0 = a0, a1 = a1, rail = across(ring, seg, e)}
      end
      return
    end
    boxes[#boxes + 1] = {a0 = a0 - c, a1 = a1 + c, d0 = d0 - c, d1 = d1 + c}
  end
  for _, e in pairs(surface.find_entities_filtered{area = wide, force = force}) do
    local kind = e.type
    if kind == 'entity-ghost' then kind = e.ghost_type end
    if not M.SKIP[kind] then consider(e, kind) end
  end
  for _, e in pairs(surface.find_entities_filtered{area = wide, type = 'cliff'}) do consider(e, 'cliff') end
  local new = layout.bulges(boxes, ring.bulges, seg.side, M.SCAN_DEPTH)
  local deep = M.depth(ring, seg)
  for _, b in ipairs(new) do
    if b.kind == 'bulge' then deep = math.max(deep, b.depth + 5) end
  end
  local water, band = {}, M.area(ring, seg, seg.lo - 4, seg.hi + 4, -4, deep)
  for _, t in pairs(surface.find_tiles_filtered{area = band, collision_mask = 'water_tile'}) do
    water[t.position.x .. ',' .. t.position.y] = true
  end
  for _, t in pairs(surface.find_tiles_filtered{area = band, name = 'out-of-map'}) do
    water[t.position.x .. ',' .. t.position.y] = true
  end
  return {bulges = new, crossings = layout.crossings(crossings), water = water}
end

-- Whether a belt, pipe or rail still runs through a stored crossing.
function M.crossing_present(ring, surface, force, crossing)
  local seg = geometry.segment(ring, crossing.segment)
  local area = M.area(ring, seg, crossing.a0, crossing.a1, -1, 4)
  return surface.count_entities_filtered{area = area, type = CROSSING_TYPES, force = force, limit = 1} > 0
end

return M
