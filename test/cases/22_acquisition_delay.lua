local test = storage.acquisition_test
if not test then
  local s = game.surfaces["tank-squads-combat-test"]
  local a = s.create_entity{name = "tank-squad-soldier-1", position = {-15, -10}, force = "tank-squads-combat", raise_built = true}
  local first = s.create_entity{name = "biter-spawner", position = {-5, -10}, force = "enemy"}
  first.active = false
  first.health = 1
  storage.acquisition_test = {entity = a, first = first, started = game.tick}
  a.commandable.set_command{type = defines.command.go_to_location, destination = {15, -10}, radius = 1, distraction = defines.distraction.by_enemy}
  return "WAIT: moving before enemy appears"
end
if not test.enemy then
  if test.first.valid then return "WAIT: first enemy" end
  if not test.finished then
    test.finished = game.tick
    test.entity.commandable.set_command{type = defines.command.go_to_location, destination = {15, -10}, radius = 1, distraction = defines.distraction.by_enemy}
  end
  if game.tick - test.finished < 30 then return "WAIT: next encounter" end
  test.enemy = test.entity.surface.create_entity{name = "biter-spawner", position = {10, 0}, force = "enemy"}
  test.enemy.active = false
  test.appeared = game.tick
  return "WAIT: enemy appeared"
end
local record = storage.weapons[test.entity.unit_number]
if record.target ~= test.enemy then
  if game.tick - test.appeared < 360 then return "WAIT: acquisition" end
  error("no shot within 360 ticks of enemy appearing")
end
local delay = record.last_shot - test.appeared
test.entity.destroy{raise_destroy = true}
test.enemy.destroy()
storage.acquisition_test = nil
if delay > 45 then error("acquisition took " .. delay .. " ticks; expected at most 45") end
return "PASS: acquisition within " .. delay .. " ticks"
