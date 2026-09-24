if not game.get_player(1) then return "SKIP: requires a connected test player; private rendering requests are covered by test/unit.py" end
local s = game.surfaces[1]
local player = game.get_player(1)
local a = s.create_entity{name = "tank-squad-soldier-1", position = {700, 700}, force = player.force}
local foreign = s.create_entity{name = "tank-squad-soldier-1", position = {705, 700}, force = "enemy"}
local area = {left_top = {x = 695, y = 695}, right_bottom = {x = 710, y = 710}}
local n = remote.call("tank-squads", "select", 1, area)
if n ~= 1 then error("foreign soldier selected") end
local ring = storage.divisions[1].slots[0].render.rings[a.unit_number]
if not (ring and ring.valid) then error("selection has no persistent ring") end
if #ring.players ~= 1 or ring.players[1].index ~= 1 then error("ring not private") end
if ring.time_to_live ~= 0 then error("selection ring expires") end
remote.call("tank-squads", "order", 1, {left_top = {x = 720, y = 720}, right_bottom = {x = 722, y = 722}})
if not ring.valid then error("order removed ring") end
remote.call("tank-squads", "select", 1, {left_top = {x = 800, y = 800}, right_bottom = {x = 802, y = 802}})
if ring.valid then error("reselection left old ring") end
remote.call("tank-squads", "select", 1, area)
local replacement = storage.divisions[1].slots[0].render.rings[a.unit_number]
a.destroy()
if replacement.valid then error("destroyed entity left render object") end
foreign.destroy()
