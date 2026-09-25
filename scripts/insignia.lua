-- Division insignias, one per keybound slot. Slot 0, the drag selection, has
-- none. Shared by prototypes and runtime; contains no runtime API access.
local M = {}

-- Every insignia and rank image is 512 px square, drawn at scale 1: 16 tiles.
M.SPRITE_TILES = 16

-- Each slot's ring colour is its shield's accent. Slot 4 is a deep green so
-- it does not read as slot 0's bright selection green; slot 7 is tan and
-- slot 9 pale stone so neither repeats slot 2's orange or slot 5's gold.
M.SLOTS = {
  [1] = {file = "division-01-iron-vanguard", color = {r = 0.95, g = 0.22, b = 0.2, a = 0.9}},
  [2] = {file = "division-02-ashguard", color = {r = 1.0, g = 0.5, b = 0.1, a = 0.9}},
  [3] = {file = "division-03-stormbreakers", color = {r = 0.3, g = 0.5, b = 1.0, a = 0.9}},
  [4] = {file = "division-04-pathfinders", color = {r = 0.15, g = 0.6, b = 0.3, a = 0.9}},
  [5] = {file = "division-05-siege-hammers", color = {r = 0.95, g = 0.8, b = 0.25, a = 0.9}},
  [6] = {file = "division-06-night-watch", color = {r = 0.65, g = 0.35, b = 1.0, a = 0.9}},
  [7] = {file = "division-07-dust-wolves", color = {r = 0.85, g = 0.65, b = 0.42, a = 0.9}},
  [8] = {file = "division-08-steel-serpents", color = {r = 0.15, g = 0.8, b = 0.75, a = 0.9}},
  [9] = {file = "division-09-last-bastion", color = {r = 0.85, g = 0.83, b = 0.78, a = 0.9}},
}

function M.sprite(n)
  if M.SLOTS[n] then return "tank-squad-insignia-" .. n end
  return nil
end

return M
