-- Ring geometry. Pure: no game API, unit tested in test/rings.lua.
--
-- ring = {shape = 'square' | 'circle', centre = {x, y} (a tile), radius,
--   bulges}. A place on a ring is given in a frame: side (1 east, 2 south,
--   3 west, 4 north for a square; 0 for a circle), along (tiles clockwise
--   along the ring; for a circle, arc length at the radius) and depth (tiles
--   outward from the middle wall row). A square side runs from the tile
--   after the previous corner to the end of its own corner block.
local M = {}

M.TAU = 2 * math.pi
-- Gates stand at along gate - 8 .. gate + 7, bastions out to gate - 14 ..
-- gate + 13.
M.GATE_HALF = 8
M.HOUSE_HALF = 14
-- Tiles between the outermost gatehouse of a side and its corner bastion.
M.CORNER_MARGIN = 24
-- Where a unit waits before a gatehouse, and where garrison posts stand.
M.INSIDE_APRON, M.OUTSIDE_APRON = -9, 10
M.POST_DEPTH = -9

-- Tiles between gatehouses: 128 up to radius 200, 16 less per extra 200 of
-- radius, never below 64, in steps of 16.
function M.spacing(radius)
  local s = math.max(64, math.min(128, 128 - 0.08 * (radius - 200)))
  return 16 * math.floor(s / 16 + 0.5)
end

-- Gatehouses on each side of a square side's centre gatehouse.
function M.half_count(radius)
  return math.max(0, math.floor((radius - 2 - M.CORNER_MARGIN - M.HOUSE_HALF) / M.spacing(radius)))
end

function M.circle_count(radius)
  return math.max(4, math.floor(M.TAU * radius / M.spacing(radius)))
end

function M.side_range(radius)
  return -(radius - 2), radius + 4
end

function M.segment_count(ring)
  if ring.shape == 'circle' then return M.circle_count(ring.radius) end
  return 4 * (2 * M.half_count(ring.radius) + 1)
end

-- Segment i: its side, the along position of its gatehouse and its along
-- range. A segment reaches halfway to the next gatehouse, so a gatehouse
-- never straddles two segments. A circle segment's range is [lo, hi).
function M.segment(ring, i)
  local R = ring.radius
  if ring.shape == 'circle' then
    local step = M.TAU * R / M.circle_count(R)
    local gate = (i - 1) * step
    return {side = 0, gate = gate, lo = gate - step / 2, hi = gate + step / 2, index = i}
  end
  local h, s = M.half_count(R), M.spacing(R)
  local per = 2 * h + 1
  local side = math.floor((i - 1) / per) + 1
  local k = (i - 1) % per - h
  local first, last = M.side_range(R)
  local lo = k == -h and first or math.ceil((k - 0.5) * s)
  local hi = k == h and last or math.ceil((k + 0.5) * s) - 1
  return {side = side, gate = k * s, lo = lo, hi = hi, index = i}
end

-- The segment holding a frame position.
function M.segment_of(ring, side, along)
  local R = ring.radius
  if ring.shape == 'circle' then
    local n = M.circle_count(R)
    return math.floor(along / (M.TAU * R / n) + 0.5) % n + 1
  end
  local h, s = M.half_count(R), M.spacing(R)
  local k = math.max(-h, math.min(h, math.floor(along / s + 0.5)))
  return (side - 1) * (2 * h + 1) + k + h + 1
end

-- The tile (its left-top corner) at a frame position. On a circle, the tile
-- under the point.
function M.to_tile(ring, side, along, depth)
  local cx, cy, R = ring.centre.x, ring.centre.y, ring.radius
  if side == 1 then return cx + R + depth, cy + along end
  if side == 2 then return cx - along, cy + R + depth end
  if side == 3 then return cx - R - depth, cy - along end
  if side == 4 then return cx + along, cy - R - depth end
  local a, r = along / R, R + depth
  return math.floor(cx + 0.5 + r * math.sin(a)), math.floor(cy + 0.5 - r * math.cos(a))
end

-- The centre of that tile, where an entity stands.
function M.to_position(ring, side, along, depth)
  local x, y = M.to_tile(ring, side, along, depth)
  return {x = x + 0.5, y = y + 0.5}
end

-- Along and depth of a tile on one square side's frame. tx and ty count
-- tiles from the centre tile.
function M.on_side(ring, side, tx, ty)
  local R = ring.radius
  if side == 1 then return ty, tx - R end
  if side == 2 then return -tx, ty - R end
  if side == 3 then return -ty, -tx - R end
  return tx, -ty - R
end

-- The frame of a world position. On a square, the side whose range holds
-- the tile and whose wall lies nearest outward wins; beyond a corner, the
-- side the tile faces. A circle's depth is not rounded.
function M.to_frame(ring, x, y)
  local cx, cy = ring.centre.x, ring.centre.y
  if ring.shape == 'circle' then
    local dx, dy = x - (cx + 0.5), y - (cy + 0.5)
    local a = math.atan2(dx, -dy) % M.TAU
    return 0, a * ring.radius, math.sqrt(dx * dx + dy * dy) - ring.radius
  end
  local tx, ty = math.floor(x) - cx, math.floor(y) - cy
  local first, last = M.side_range(ring.radius)
  local best, best_a, best_d
  for side = 1, 4 do
    local a, d = M.on_side(ring, side, tx, ty)
    if a >= first and a <= last and (not best_d or d > best_d) then best, best_a, best_d = side, a, d end
  end
  if best then return best, best_a, best_d end
  local side
  if math.abs(tx) >= math.abs(ty) then side = tx >= 0 and 1 or 3 else side = ty >= 0 and 2 or 4 end
  local a, d = M.on_side(ring, side, tx, ty)
  return side, a, d
end

-- The bulge of this side whose legs or end bastions reach along, or nil.
function M.bulge_at(bulges, side, along)
  for _, b in ipairs(bulges or {}) do
    if b.side == side and along >= b.a0 - 4 and along <= b.a1 + 4 then return b end
  end
  return nil
end

-- True on the ring's band: from the gatehouse bastions' inner rows (-3) to
-- the teeth (4), or a bulge with its legs and front.
function M.in_band(ring, x, y)
  local side, a, d = M.to_frame(ring, x, y)
  local b = M.bulge_at(ring.bulges, side, a)
  if b and b.kind == 'bulge' then return d >= -3.5 and d <= b.depth + 4.5 end
  return d >= -3.5 and d <= 4.5
end

-- 'inside' or 'outside' the ring, and whether the position is on the band.
-- The middle wall row decides, pushed out over a bulge's front.
function M.side(ring, x, y)
  local side, a, d = M.to_frame(ring, x, y)
  local wall = 0
  local b = M.bulge_at(ring.bulges, side, a)
  if b and b.kind == 'bulge' and a >= b.a0 and a <= b.a1 then wall = b.depth end
  return d < wall and 'inside' or 'outside', M.in_band(ring, x, y)
end

-- A circle's gatehouse is an axis-aligned block at its point on the circle:
-- gate rows run east-west near north and south, north-south near east and
-- west. u runs along (ux, uy), depth outward along (nx, ny).
function M.circle_house(ring, gate_along)
  local angle = gate_along / ring.radius
  local x, y = M.to_tile(ring, 0, gate_along, 0)
  local s, c = math.sin(angle), math.cos(angle)
  if math.abs(c) >= math.abs(s) then
    return {x = x, y = y, ux = 1, uy = 0, nx = 0, ny = c > 0 and -1 or 1, dir = 'north'}
  end
  return {x = x, y = y, ux = 0, uy = 1, nx = s > 0 and 1 or -1, ny = 0, dir = 'east'}
end

-- The point before a segment's gatehouse, 'inside' or 'outside' the ring.
function M.apron(ring, seg, where)
  local depth = where == 'inside' and M.INSIDE_APRON or M.OUTSIDE_APRON
  if ring.shape ~= 'circle' then return M.to_position(ring, seg.side, seg.gate, depth) end
  local h = M.circle_house(ring, seg.gate)
  return {x = h.x + depth * h.nx + 0.5, y = h.y + depth * h.ny + 0.5}
end

-- Where a constructor stands to build the band at a world position,
-- 'inside' or 'outside' the ring: off the band on that side, so no wall it
-- builds can shut it in. Plain wall and gatehouses: 5 rows inside the
-- middle wall row or 6 outside (a circle one more), clear of the band by
-- more than half a hull. Beside a circle's gatehouse, its apron. On a bulge's front,
-- inside means the pocket the bulge wraps; beside its legs, the pocket or
-- beyond the leg. On a square, inside stays clear of the corners.
M.STAND_INSIDE, M.STAND_OUTSIDE = -5, 6
function M.stand(ring, x, y, where)
  local side, a, d = M.to_frame(ring, x, y)
  local inside = where == 'inside'
  local b = M.bulge_at(ring.bulges, side, a)
  if b and b.kind == 'bulge' then
    local depth = b.depth
    if a >= b.a0 and a <= b.a1 then
      if not inside then return M.to_position(ring, side, a, depth + M.STAND_OUTSIDE) end
      return M.to_position(ring, side, math.max(b.a0 + 1, math.min(b.a1 - 1, a)), depth + M.STAND_INSIDE)
    end
    local left = a < b.a0
    if inside then
      local pocket = math.min(math.max(d, M.STAND_INSIDE), depth + M.STAND_INSIDE)
      return M.to_position(ring, side, left and b.a0 + 1 or b.a1 - 1, pocket)
    end
    return M.to_position(ring, side, left and b.a0 - 6 or b.a1 + 6, math.max(d, M.STAND_OUTSIDE))
  end
  if ring.shape == 'circle' then
    local seg = M.segment(ring, M.segment_of(ring, 0, a))
    local C = M.TAU * ring.radius
    if math.abs((a - seg.gate + C / 2) % C - C / 2) <= M.HOUSE_HALF + 4 then return M.apron(ring, seg, where) end
    -- Circle tiles are rounded onto the band, so one row more.
    return M.to_position(ring, 0, a, inside and M.STAND_INSIDE - 1 or M.STAND_OUTSIDE + 1)
  end
  if inside then
    local limit = ring.radius - 6
    return M.to_position(ring, side, math.max(-limit, math.min(limit, a)), M.STAND_INSIDE)
  end
  return M.to_position(ring, side, a, M.STAND_OUTSIDE)
end

-- A ranking of band positions for a constructor at `from` working along
-- the ring: the squared distance plus SWEEP_WEIGHT times the squared
-- distance along the ring. Rows across the band cost far less than tiles
-- along it, so it finishes the whole cross-section where it stands before
-- it moves on, and never ranks a position below its squared distance.
M.SWEEP_WEIGHT = 15
function M.sweep_score(ring, from)
  local side0, a0 = M.to_frame(ring, from.x, from.y)
  local C = M.TAU * ring.radius
  return function(p)
    local dx, dy = p.x - from.x, p.y - from.y
    local side, a = M.to_frame(ring, p.x, p.y)
    local da
    if ring.shape == 'circle' then
      da = (a - a0 + C / 2) % C - C / 2
    elseif side == side0 then
      da = a - a0
    else
      da = math.sqrt(dx * dx + dy * dy)
    end
    return dx * dx + dy * dy + M.SWEEP_WEIGHT * da * da
  end
end

-- A number that grows clockwise round the ring: the segment index plus how
-- far along the segment the position lies.
function M.order(ring, x, y)
  local side, along = M.to_frame(ring, x, y)
  local i = M.segment_of(ring, side, along)
  local seg = M.segment(ring, i)
  local rel = along - seg.lo
  if ring.shape == 'circle' then
    local C = M.TAU * ring.radius
    rel = (along - seg.gate + C / 2) % C - C / 2 + (seg.gate - seg.lo)
  end
  return i + rel / (seg.hi - seg.lo + 1)
end

return M
