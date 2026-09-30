-- The wall pattern of a ring: which tiles of a segment get a wall or a
-- gate. Pure: no game API, unit tested in test/rings.lua. Rows are counted
-- outward from the middle wall row (depth 0).
local geometry = require('scripts.engineers.rings.geometry')

local M = {}

M.CLEARANCE = 4
M.MAX_LENGTH = 128
M.MAX_DEPTH = 64
M.BASTION_EVERY = 32
-- Plain bastions keep this far from a gatehouse's centre.
M.BASTION_GAP = 26

-- The cross-section: three wall rows, a gap, two rows of teeth on the
-- checkerboard of world tiles.
local function base(d, x, y)
  if d >= -1 and d <= 1 then return 'wall' end
  if (d == 3 or d == 4) and (x + y) % 2 == 0 then return 'wall' end
  return nil
end

-- A gatehouse around its centre, u tiles along and d rows out. Returns
-- true and the tile's content inside the block, false outside it.
local function house(u, d)
  if u < -geometry.HOUSE_HALF or u > geometry.HOUSE_HALF - 1 or d < -3 or d > 4 then return false end
  if u >= -geometry.GATE_HALF and u <= geometry.GATE_HALF - 1 then
    return true, (d >= -1 and d <= 1) and 'gate' or nil
  end
  return true, 'wall'
end

-- A bulge: legs out from the wall line, the full cross-section along its
-- front and a bastion on each outer corner. An 'end' leaves the wall open
-- over the obstacle with a bastion at each end. False where the bulge does
-- not decide the tile.
local function bulge_cell(b, a, d, x, y)
  if b.kind == 'end' then
    if a >= b.a0 and a <= b.a1 then return true, nil end
    if (a >= b.a0 - 4 and a < b.a0) or (a > b.a1 and a <= b.a1 + 4) then
      if d >= -1 and d <= 2 then return true, 'wall' end
    end
    return false
  end
  if a < b.a0 - 3 or a > b.a1 + 3 then return false end
  local depth = b.depth
  if (a <= b.a0 or a >= b.a1) and d >= depth + 1 and d <= depth + 4 then return true, 'wall' end
  if a < b.a0 or a > b.a1 then return true, (d >= -1 and d <= depth + 1) and 'wall' or nil end
  return true, base(d - depth, x, y)
end

-- The world tile at u along and d out from a segment's gatehouse centre.
function M.house_tile(ring, seg, u, d)
  if ring.shape ~= 'circle' then return geometry.to_tile(ring, seg.side, seg.gate + u, d) end
  local h = geometry.circle_house(ring, seg.gate)
  return h.x + u * h.ux + d * h.nx, h.y + u * h.uy + d * h.ny
end

-- A gatehouse is built only where no crossing, bulge or water touches its
-- block.
function M.house_clear(ring, seg, o)
  local lo, hi = seg.gate - geometry.HOUSE_HALF, seg.gate + geometry.HOUSE_HALF - 1
  for _, list in ipairs({o.crossings, o.bulges}) do
    for _, c in ipairs(list) do
      if c.side == seg.side and c.a0 - 4 <= hi and c.a1 + 4 >= lo then return false end
    end
  end
  for u = -geometry.HOUSE_HALF, geometry.HOUSE_HALF - 1 do
    for d = -3, 4 do
      local x, y = M.house_tile(ring, seg, u, d)
      if o.water[x .. ',' .. y] then return false end
    end
  end
  return true
end

-- A plain bastion covers along b - 1 .. b + 2 and rows 1 to 4, b a
-- multiple of 32, inside its segment, clear of the gatehouse and, on a
-- square, of the corners.
local function bastion(ring, seg, a, d)
  if d < 1 or d > 4 then return false end
  local b = M.BASTION_EVERY * math.floor((a + 1) / M.BASTION_EVERY)
  if a >= b + 3 then return false end
  if b - 1 < seg.lo or b + 2 > seg.hi or math.abs(b - seg.gate) < M.BASTION_GAP then return false end
  if ring.shape ~= 'circle' then
    local first = geometry.side_range(ring.radius)
    if b - 1 < first + 4 or b + 2 > ring.radius - 6 then return false end
  end
  return true
end

-- What stands on one tile: 'wall', 'gate' or nil. Crossings first, then
-- bulges, the gatehouse, a square's corner, plain bastions and the
-- cross-section.
function M.cell(ring, seg, a, d, x, y, o, house_ok)
  local side = seg.side
  for _, c in ipairs(o.crossings) do
    if c.side == side and a >= c.a0 and a <= c.a1 then
      return (c.rail and d >= -1 and d <= 1) and 'gate' or nil
    end
  end
  local b = geometry.bulge_at(o.bulges, side, a)
  if b then
    local handled, name = bulge_cell(b, a, d, x, y)
    if handled then return name end
  end
  if house_ok then
    local u, v
    if ring.shape == 'circle' then
      local h = geometry.circle_house(ring, seg.gate)
      local dx, dy = x - h.x, y - h.y
      u, v = dx * h.ux + dy * h.uy, dx * h.nx + dy * h.ny
    else
      u, v = a - seg.gate, d
    end
    local handled, name = house(u, v)
    if handled then return name end
  end
  if ring.shape ~= 'circle' and a >= ring.radius - 1 then
    return (d >= -1 and d <= 4) and 'wall' or nil
  end
  if bastion(ring, seg, a, d) then return 'wall' end
  return base(d, x, y)
end

-- The bounding tiles of a circle segment between depths d0 and d1.
function M.circle_box(ring, seg, d0, d1)
  local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
  local a = seg.lo
  while true do
    for _, d in ipairs({d0, d1}) do
      local x, y = geometry.to_tile(ring, 0, a, d)
      x0, y0, x1, y1 = math.min(x0, x), math.min(y0, y), math.max(x1, x), math.max(y1, y)
    end
    if a >= seg.hi then break end
    a = math.min(seg.hi, a + 8)
  end
  return x0 - 1, y0 - 1, x1 + 1, y1 + 1
end

-- The tiles of segment i: {x, y (entity position), name, dir, a}.
-- obstacles = {bulges, crossings, water}, each optional.
function M.plan(ring, i, obstacles)
  obstacles = obstacles or {}
  local o = {bulges = obstacles.bulges or ring.bulges or {}, crossings = obstacles.crossings or {},
    water = obstacles.water or {}}
  local seg = geometry.segment(ring, i)
  local house_ok = M.house_clear(ring, seg, o)
  local deep = 4
  for _, b in ipairs(o.bulges) do
    if b.side == seg.side and b.kind == 'bulge' and b.a1 + 4 >= seg.lo and b.a0 - 4 <= seg.hi then
      deep = math.max(deep, b.depth + 4)
    end
  end
  local tiles = {}
  local function consider(a, d, x, y, dir)
    if o.water[x .. ',' .. y] then return end
    local name = M.cell(ring, seg, a, d, x, y, o, house_ok)
    if name then
      tiles[#tiles + 1] = {x = x + 0.5, y = y + 0.5, name = name == 'gate' and 'gate' or 'stone-wall', dir = dir, a = a}
    end
  end
  if ring.shape ~= 'circle' then
    local dir = (seg.side == 1 or seg.side == 3) and 'east' or 'north'
    for a = seg.lo, seg.hi do
      for d = -3, deep do
        local x, y = geometry.to_tile(ring, seg.side, a, d)
        consider(a, d, x, y, dir)
      end
    end
    return tiles
  end
  local dir = geometry.circle_house(ring, seg.gate).dir
  local C = geometry.TAU * ring.radius
  local x0, y0, x1, y1 = M.circle_box(ring, seg, -5, deep + 1)
  for x = x0, x1 do
    for y = y0, y1 do
      local _, along, depth = geometry.to_frame(ring, x + 0.5, y + 0.5)
      local rel = (along - seg.gate + C / 2) % C - C / 2
      local d = math.floor(depth + 0.5)
      if rel >= seg.lo - seg.gate and rel < seg.hi - seg.gate and d >= -4 and d <= deep then
        consider(seg.gate + rel, d, x, y, dir)
      end
    end
  end
  return tiles
end

-- The direction of a gate at a world position of the ring.
function M.gate_dir(ring, x, y)
  local side, along = geometry.to_frame(ring, x, y)
  if ring.shape ~= 'circle' then return (side == 1 or side == 3) and 'east' or 'north' end
  local seg = geometry.segment(ring, geometry.segment_of(ring, 0, along))
  return geometry.circle_house(ring, seg.gate).dir
end

-- The world area of a segment's gates.
function M.gate_area(ring, seg)
  local x0, y0 = M.house_tile(ring, seg, -geometry.GATE_HALF, -1)
  local x1, y1 = M.house_tile(ring, seg, geometry.GATE_HALF - 1, 1)
  return {left_top = {x = math.min(x0, x1), y = math.min(y0, y1)},
    right_bottom = {x = math.max(x0, x1) + 1, y = math.max(y0, y1) + 1}}
end

-- Obstacle boxes (frame coordinates, clearance already added) that reach
-- the wall rows become bulges on `side`: merged where their legs would
-- touch, and dropped where a stored bulge already covers them. A bulge
-- longer than MAX_LENGTH, deeper than MAX_DEPTH or cut off by the scan
-- (reaching scan_depth) ends the wall instead.
function M.bulges(boxes, stored, side, scan_depth)
  local list = {}
  for _, b in ipairs(boxes) do
    if b.d1 >= -1 and b.d0 <= 4 then list[#list + 1] = {a0 = b.a0, a1 = b.a1, d0 = b.d0, d1 = b.d1} end
  end
  table.sort(list, function(p, q) return p.a0 < q.a0 end)
  local merged = {}
  for _, b in ipairs(list) do
    local last = merged[#merged]
    if last and b.a0 <= last.a1 + 3 then
      last.a1, last.d0, last.d1 = math.max(last.a1, b.a1), math.min(last.d0, b.d0), math.max(last.d1, b.d1)
    else
      merged[#merged + 1] = b
    end
  end
  local out = {}
  for _, m in ipairs(merged) do
    local clash = false
    for _, s in ipairs(stored) do
      if s.side == side and m.a0 <= s.a1 + 4 and m.a1 >= s.a0 - 4 then clash = true end
    end
    if not clash then
      local depth = math.max(m.d1 + 2, 2)
      local kind = (m.a1 - m.a0 > M.MAX_LENGTH or depth > M.MAX_DEPTH or m.d1 >= scan_depth - 1) and 'end' or 'bulge'
      out[#out + 1] = {side = side, a0 = m.a0, a1 = m.a1, depth = depth, kind = kind}
    end
  end
  return out
end

-- Crossings of one ring merged where they touch. A merged crossing is a
-- rail crossing only when all its parts are.
function M.crossings(list)
  table.sort(list, function(p, q)
    if p.side ~= q.side then return p.side < q.side end
    return p.a0 < q.a0
  end)
  local out = {}
  for _, c in ipairs(list) do
    local last = out[#out]
    if last and last.side == c.side and c.a0 <= last.a1 + 1 then
      last.a1, last.rail = math.max(last.a1, c.a1), last.rail and c.rail
    else
      out[#out + 1] = {side = c.side, a0 = c.a0, a1 = c.a1, rail = c.rail}
    end
  end
  return out
end

return M
