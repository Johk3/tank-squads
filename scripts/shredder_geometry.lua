-- Shredder geometry: backline points, parking slots and the even split of
-- shredders over groups. Pure functions without runtime API access.
local M = {}

M.BACK = 80
-- Slot spacing. Slot i sits RING * sqrt(i - 1) tiles out on a sunflower
-- spiral, so neighbours stay about RING tiles apart at any count.
M.RING = 2.5
local GOLDEN = 2.39996323

function M.distance2(a, b)
  local dx, dy = a.x - b.x, a.y - b.y
  return dx * dx + dy * dy
end

-- Mean position of the entities, or nil for none.
function M.centre(entities)
  local x, y, count = 0, 0, 0
  for _, e in ipairs(entities) do
    local p = e.position
    x, y, count = x + p.x, y + p.y, count + 1
  end
  if count == 0 then return nil end
  return {x = x / count, y = y / count}
end

-- The point `distance` tiles from the centre toward home; a home closer
-- than that is the point itself. Without home the point lies away from the
-- nearest enemy, and without either, south of the centre.
function M.backline(centre, home, enemy, distance)
  distance = distance or M.BACK
  if home then
    local dx, dy = home.x - centre.x, home.y - centre.y
    local d = math.sqrt(dx * dx + dy * dy)
    if d <= distance then return {x = home.x, y = home.y} end
    return {x = centre.x + dx / d * distance, y = centre.y + dy / d * distance}
  end
  if enemy then
    local dx, dy = centre.x - enemy.x, centre.y - enemy.y
    local d = math.sqrt(dx * dx + dy * dy)
    if d > 0.01 then return {x = centre.x + dx / d * distance, y = centre.y + dy / d * distance} end
  end
  return {x = centre.x, y = centre.y + distance}
end

-- A slot never depends on how many shredders park, so a newcomer never
-- moves the others.
function M.slot(point, index)
  if index <= 1 then return {x = point.x, y = point.y} end
  local r, a = M.RING * math.sqrt(index - 1), (index - 1) * GOLDEN
  return {x = point.x + r * math.cos(a), y = point.y + r * math.sin(a)}
end

local function by_distance_desc(point)
  return function(a, b)
    local da, db = M.distance2(a.position, point), M.distance2(b.position, point)
    if da ~= db then return da > db end
    return a.id < b.id
  end
end

-- Even split with only the surplus moving. Groups above ceil(total / n)
-- give up their farthest shredders; groups below floor(total / n) fill
-- first, then groups at floor, each taking the free shredder nearest its
-- point. Returns id -> group key, or false for a shredder left in the pool.
function M.rebalance(groups, pool)
  local changes = {}
  if #groups == 0 then return changes end
  local free, total = {}, #pool
  for _, s in ipairs(pool) do free[#free + 1] = s end
  for _, g in ipairs(groups) do total = total + #g.members end
  local high, low = math.ceil(total / #groups), math.floor(total / #groups)
  local counts = {}
  for i, g in ipairs(groups) do
    counts[i] = #g.members
    if counts[i] > high then
      local sorted = {}
      for _, s in ipairs(g.members) do sorted[#sorted + 1] = s end
      table.sort(sorted, by_distance_desc(g.point))
      for j = 1, counts[i] - high do
        free[#free + 1] = sorted[j]
        changes[sorted[j].id] = false
      end
      counts[i] = high
    end
  end
  -- Each group ranks the free shredders by distance once, on its first
  -- pick, and takes them in that order, skipping those taken meanwhile.
  local left, taken, ranked, next_of = #free, {}, {}, {}
  for _, cap in ipairs({low, high}) do
    for i, g in ipairs(groups) do
      if counts[i] < cap and left > 0 and not ranked[i] then
        local list = {}
        for j, s in ipairs(free) do list[j] = {s = s, d = M.distance2(s.position, g.point)} end
        table.sort(list, function(a, b)
          if a.d ~= b.d then return a.d < b.d end
          return a.s.id < b.s.id
        end)
        ranked[i], next_of[i] = list, 1
      end
      while counts[i] < cap and left > 0 do
        local list, k = ranked[i], next_of[i]
        while taken[list[k].s] do k = k + 1 end
        local s = list[k].s
        taken[s], next_of[i] = true, k + 1
        changes[s.id] = g.key
        left = left - 1
        counts[i] = counts[i] + 1
      end
    end
  end
  return changes
end

return M
