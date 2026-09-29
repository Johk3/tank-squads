local electric = prototypes.entity['tank-squad-electric']
local nuclear = prototypes.entity['tank-squad-nuclear']
assert(electric and nuclear, 'special tanks are missing')
assert(electric.type == 'unit' and nuclear.type == 'unit', 'special tanks bypass native unit AI')
assert(electric.get_max_health('normal') == 1400 and nuclear.get_max_health('normal') == 1600, 'wrong special tank health')
assert(electric.attack_parameters.range == 24 and nuclear.attack_parameters.range == 52, 'wrong special tank range')
assert(prototypes.recipe['tank-squad-train-electric'] == nil and prototypes.recipe['tank-squad-train-nuclear'] == nil, 'special tanks can be trained')
for _, name in ipairs({'tank-squad-electric-ball', 'tank-squad-atomic-rocket', 'tank-squad-nuke-fallback', 'tank-squad-electric-impact', 'tank-squad-electric-shock', 'tank-squad-nuke-detonation'}) do
  assert(prototypes.entity[name], 'missing ' .. name)
end
local s = game.surfaces[1]
for _, name in ipairs({'tank-squad-red-gun', 'tank-squad-green-gun', 'tank-squad-electric-gun', 'tank-squad-nuclear-gun', 'tank-squad-electric-link'}) do
  local object = rendering.draw_animation{animation = name, target = {0, 0}, surface = s, time_to_live = 1}
  assert(object.valid, 'animation did not draw: ' .. name)
  object.destroy()
end
local t = storage.special_tanks_case
if not t then
  local c = game.surfaces['special-tanks'] or game.create_surface('special-tanks', {width = 128, height = 128, autoplace_controls = {}})
  c.request_to_generate_chunks({0, 0}, 3)
  c.force_generate_chunk_requests()
  local tiles = {}
  for x = -20, 40 do for y = -20, 20 do tiles[#tiles + 1] = {name = 'grass-1', position = {x, y}} end end
  c.set_tiles(tiles)
  for _, e in pairs(c.find_entities()) do if e.type ~= 'character' then e.destroy{raise_destroy = true} end end
  local f = game.forces['special-tanks'] or game.create_force('special-tanks')
  f.set_ammo_damage_modifier('laser', 0)
  local tank = assert(c.create_entity{name = 'tank-squad-electric', position = {0, 0}, force = f, raise_built = true})
  local target = assert(c.create_entity{name = 'rocket-silo', position = {18, 0}, force = 'enemy'})
  local friend = assert(c.create_entity{name = 'tank-squad-soldier-1', position = {16, 5}, force = f, raise_built = true})
  friend.active = false
  tank.commandable.set_command{type = defines.command.attack, target = target, distraction = defines.distraction.none}
  storage.special_tanks_case = {tank = tank, target = target, friend = friend, health = target.health,
    friend_health = friend.health, started = game.tick}
  return 'WAIT: electric combat'
end
if game.tick - t.started < 120 then return 'WAIT: electric combat' end
local ok, result = pcall(function()
  assert(t.target.valid and t.target.health < t.health, 'electric ball did not damage the target')
  assert(t.friend.valid and t.friend.health == t.friend_health, 'electric burst hurt a friend')
  local record = storage.weapons[t.tank.unit_number]
  assert(record and record.target, 'electric gun did not aim')
  return (t.health - t.target.health) .. ' electric damage'
end)
for _, e in ipairs({t.tank, t.target, t.friend}) do if e.valid then e.destroy{raise_destroy = true} end end
storage.special_tanks_case = nil
if not ok then error(result) end
return 'PASS: special tank prototypes load; ' .. result
