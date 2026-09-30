-- Nest threat and soldier strength for the nest task force. Pure: no
-- Factorio API, so every rule is unit tested.
local M = {}

M.WORMS = {['small-worm-turret'] = 1, ['medium-worm-turret'] = 2, ['big-worm-turret'] = 4,
  ['behemoth-worm-turret'] = 8}
M.SPAWNER = 2
-- A worm from another mod scores like a medium worm (2) per this much
-- maximum health, and at least 1.
M.MEDIUM_WORM_HEALTH = 500
M.MARGIN = 1.5
M.KINDS = {['tank-squad-siege'] = 1.5, ['tank-squad-flame'] = 1.5, ['tank-squad-electric'] = 3,
  ['tank-squad-nuclear'] = 3}
M.RANK_BONUS = 0.25
-- A patrol keeps one soldier per POST_LENGTH tiles of route, at least
-- MIN_PATROL, so no post grows longer when soldiers are lent.
M.POST_LENGTH = 32
M.MIN_PATROL = 4
-- A lending division keeps at least KEEP_SHARE of its soldiers and never
-- fewer than MIN_KEEP, so a task force only takes a real surplus.
M.KEEP_SHARE = 0.5
M.MIN_KEEP = 4

function M.structure(s)
  if s.type == 'unit-spawner' then return M.SPAWNER end
  local known = M.WORMS[s.name]
  if known then return known end
  return math.max(1, 2 * (s.max_health or 0) / M.MEDIUM_WORM_HEALTH)
end

function M.nest(structures)
  local score = 0
  for _, s in ipairs(structures) do score = score + M.structure(s) end
  return score
end

function M.strength(name, rank)
  return (M.KINDS[name] or 1) * (1 + M.RANK_BONUS * (rank or 0))
end

function M.needed(score)
  return score * M.MARGIN
end

-- Takes candidates by tier, then nearest first, until their strength
-- reaches `needed`. Soldiers in no division have tier 0 and go first.
-- Returns the picked candidates and their total strength, or nil and the
-- total when all of them together fall short.
function M.pick(candidates, needed)
  local sorted = {}
  for i, c in ipairs(candidates) do sorted[i] = c end
  table.sort(sorted, function(a, b)
    local ta, tb = a.tier or 0, b.tier or 0
    if ta ~= tb then return ta < tb end
    if a.d ~= b.d then return a.d < b.d end
    return a.id < b.id
  end)
  local picked, total = {}, 0
  for _, c in ipairs(sorted) do
    if total >= needed then break end
    picked[#picked + 1] = c
    total = total + c.strength
  end
  if #picked == 0 or total < needed then return nil, total end
  return picked, total
end

function M.patrol_keep(length)
  return math.max(M.MIN_PATROL, math.ceil(length / M.POST_LENGTH))
end

-- The soldiers a division of `count` keeps: at least `floor`, at least
-- KEEP_SHARE of them and at least MIN_KEEP.
function M.keep(count, floor)
  return math.max(floor or 0, M.MIN_KEEP, math.ceil(count * M.KEEP_SHARE))
end

-- The soldiers a patrol can spare: the weakest beyond `keep`.
function M.surplus(soldiers, keep)
  local sorted = {}
  for i, s in ipairs(soldiers) do sorted[i] = s end
  table.sort(sorted, function(a, b)
    if a.strength ~= b.strength then return a.strength < b.strength end
    return a.id < b.id
  end)
  local out = {}
  for i = 1, #sorted - keep do out[i] = sorted[i] end
  return out
end

return M
