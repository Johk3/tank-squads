local test = storage.gun_death_test
if not test then
  local s = game.surfaces["tank-squads-combat-test"]
  local a = s.create_entity{name = "tank-squad-soldier-1", position = {0, 0}, force = "tank-squads-combat", raise_built = true}
  local enemy = s.create_entity{name = "steel-chest", position = {12, 0}, force = "enemy"}
  enemy.health = 1
  storage.gun_death_test = {entity = a, enemy = enemy, started = game.tick}
  a.commandable.set_command{type = defines.command.attack, target = enemy, distraction = defines.distraction.none}
  return "WAIT: waiting for lethal shot"
end
if test.enemy.valid then return "WAIT: target remains alive" end
local record = storage.weapons[test.entity.unit_number]
if not (record and record.gun.valid) then error("dead target destroyed carrier's gun") end
if not record.gun.use_target_orientation then return "WAIT: waiting for idle-facing sweep" end
local gun = record.gun
test.entity.destroy{raise_destroy = true}
if gun.valid then error("destroyed vehicle left gun") end
storage.gun_death_test = nil
