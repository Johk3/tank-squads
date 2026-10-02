local s = game.surfaces['continuous-combat-test'] or game.create_surface('continuous-combat-test')
for _, e in pairs(s.find_entities()) do e.destroy{raise_destroy = true} end
local a = s.create_entity{name = 'tank-squad-soldier-1', position = {0, 0}, force = 'player', raise_built = true}
local gone = s.create_entity{name = 'small-biter', position = {-6, 0}, force = 'enemy'}
local b = s.create_entity{name = 'small-biter', position = {6, 0}, force = 'enemy'}
b.active = false
local g = s.create_unit_group{position = {0, 0}, force = 'player'}
g.add_member(a)
local order = a.commandable.command
a.commandable.set_command{type = defines.command.stop}
g.destroy()
gone.destroy()
storage.combat = storage.combat or {}
storage.combat[a.unit_number] = {target = gone, resume = order}
local ok, err = pcall(script.get_event_handler(defines.events.on_entity_damaged), {entity = a, cause = b, tick = game.tick})
local command = a.commandable.command
storage.combat[a.unit_number] = nil
for _, e in pairs{a, b} do if e.valid then e.destroy{raise_destroy = true} end end
if order.type ~= defines.command.group then error('a group member read back ' .. serpent.line(order)) end
if not ok then error('defense crashed: ' .. tostring(err)) end
if not (command and command.type == defines.command.compound and command.commands[2].type == defines.command.stop) then
  error('defense did not fall back to a stop: ' .. serpent.line(command))
end
return 'PASS'
