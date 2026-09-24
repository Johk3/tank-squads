local s = game.surfaces['continuous-combat-test']
for _, e in pairs(s.find_entities()) do e.destroy{raise_destroy = true} end
local a = s.create_entity{name = 'tank-squad-soldier-1', position = {0, 0}, force = 'player', raise_built = true}
local nest = s.create_entity{name = 'biter-spawner', position = {20, 0}, force = 'enemy'}
local worm = s.create_entity{name = 'small-worm-turret', position = {-12, 0}, force = 'enemy'}
local biter = s.create_entity{name = 'small-biter', position = {6, 6}, force = 'enemy'}
nest.active, worm.active, biter.active = false, false, false
local function cleanup()
  for _, e in pairs{a, nest, worm, biter} do if e.valid then e.destroy{raise_destroy = true} end end
end
a.commandable.set_command{type = defines.command.attack, target = nest, distraction = defines.distraction.by_enemy}
nest.destroy()
local stale = a.commandable.command
local ok, err = pcall(script.get_event_handler(defines.events.on_script_trigger_effect),
  {effect_id = 'tank-squad-shot', source_entity = a, target_entity = worm, tick = game.tick})
local command = a.commandable.command
local defended = command and command.type == defines.command.compound and command.commands[1].target == biter
cleanup()
if not ok then error('defense crashed: ' .. tostring(err)) end
if not defended then
  error('carrier did not defend against the nearby biter')
end
return 'PASS: stale attack read back ' .. (stale.target and 'with' or 'without') .. ' target; defense resumed ' ..
  (command.commands[2].type == defines.command.stop and 'stop' or 'original order')
