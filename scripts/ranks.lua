-- Veteran ranks. Shared by prototypes (sprite files) and runtime; contains no
-- runtime API access. Bonuses are fractions: speed and damage are added to
-- the base, reduction is the share of each hit that is healed back.
local M = {}

M.LIST = {
  [0] = {xp = 0, speed = 0, damage = 0, reduction = 0, file = "veteran-00-recruit"},
  [1] = {xp = 50, speed = 0.10, damage = 0.20, reduction = 0.20, file = "veteran-01-trained"},
  [2] = {xp = 250, speed = 0.20, damage = 0.40, reduction = 0.40, file = "veteran-02-seasoned"},
  [3] = {xp = 1000, speed = 0.30, damage = 0.75, reduction = 0.50, file = "veteran-03-veteran"},
}
M.TOP = 3

function M.for_xp(xp)
  for rank = M.TOP, 1, -1 do
    if xp >= M.LIST[rank].xp then return rank end
  end
  return 0
end

function M.bonus(rank)
  return M.LIST[rank] or M.LIST[0]
end

-- XP needed for the next rank, or nil at the top rank.
function M.next_xp(rank)
  local next_rank = M.LIST[rank + 1]
  return next_rank and next_rank.xp or nil
end

function M.sprite(rank)
  return "tank-squad-rank-" .. rank
end

return M
