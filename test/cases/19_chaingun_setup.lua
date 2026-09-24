local s = game.surfaces["tank-squads-combat-test"] or game.create_surface("tank-squads-combat-test", {width = 64, height = 64, autoplace_controls = {}})
s.request_to_generate_chunks({0, 0}, 2)
s.force_generate_chunk_requests()
local tiles = {}
for x = -20, 20 do for y = -20, 20 do tiles[#tiles + 1] = {name = "grass-1", position = {x, y}} end end
s.set_tiles(tiles)
for _, e in pairs(s.find_entities_filtered{name = {"tank-squad-soldier-1", "steel-chest"}}) do e.destroy() end
local force = game.forces["tank-squads-combat"] or game.create_force("tank-squads-combat")
force.set_ammo_damage_modifier("bullet", 0)
force.set_gun_speed_modifier("bullet", 0)
local a = s.create_entity{name = "tank-squad-soldier-1", position = {0, 0}, force = force, raise_built = true}
local enemy = s.create_entity{name = "steel-chest", position = {12, 0}, force = "enemy"}
if not (a and enemy) then error("combat fixture could not spawn") end
local record = storage.weapons and storage.weapons[a.unit_number]
if not (record and record.gun.valid) then error("new carrier has no gun overlay") end
if not record.gun.use_target_orientation then error("idle gun does not follow hull") end
storage.combat_test = {entity = a, enemy = enemy, health = enemy.health, tick = game.tick}
a.commandable.set_command{type = defines.command.attack, target = enemy, distraction = defines.distraction.none}
