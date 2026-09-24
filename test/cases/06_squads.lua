if not game.get_player(1) then return "SKIP: requires a connected test player; selection logic is covered by test/unit.py" end
local s = game.surfaces[1]
for _, e in pairs(s.find_entities_filtered{name = {"tank-squad-soldier-1"}}) do e.destroy() end
if not prototypes.item["tank-squad-command-tool"] then error("missing command tool item") end
local made = {}
for i = 1, 3 do made[i] = s.create_entity{name = "tank-squad-soldier-1", position = {100 + i * 2, 100}, force = "player"} end
local pindex = 1
local n = remote.call("tank-squads", "select", pindex, {left_top = {x = 95, y = 95}, right_bottom = {x = 115, y = 115}})
if n ~= 3 then error("selected " .. tostring(n) .. " soldiers, expected 3") end
local kind = remote.call("tank-squads", "order", pindex, {left_top = {x = 195, y = 195}, right_bottom = {x = 205, y = 205}})
if kind ~= "move" then error("expected move order on empty ground, got " .. tostring(kind)) end
made[1].destroy()
local left = remote.call("tank-squads", "division_size", pindex, 0)
if left ~= 2 then error("dead soldier still counted in squad: " .. tostring(left)) end
for _, e in pairs(made) do if e.valid then e.destroy() end end
