local test = storage.combat_test
if not test then error("missing combat fixture") end
local a, enemy = test.entity, test.enemy
if not (a.valid and enemy.valid) then error("combat fixture died before assertions") end
local record = storage.weapons[a.unit_number]
if not record.target then return "WAIT: native unit has not fired yet" end
if enemy.health == test.health then return "WAIT: native bullet has not hit yet" end
if #a.surface.find_entities_filtered{name = "tank-squad-tracer"} == 0 then return "WAIT: between visible tracers" end
if record.target ~= enemy then error("gun received the wrong attack target") end
if record.gun.use_target_orientation then error("firing gun follows enemy facing instead of aiming at enemy") end
local lost = test.health - enemy.health
if lost <= 0 or lost % 6 ~= 0 then error("tier 1 bullet damage changed: " .. lost) end
local gun = record.gun
local unit_number = a.unit_number
a.destroy{raise_destroy = true}
if gun.valid then error("destroyed carrier left gun behind") end
if storage.weapons[unit_number] then error("destroyed carrier remains registered") end
enemy.destroy()
storage.combat_test = nil
