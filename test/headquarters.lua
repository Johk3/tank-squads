return function(ctx)
  local combat = require('scripts.combat')
  local names = require('scripts.names')
  local divisions = require('scripts.divisions')
  local scout = require('scripts.scout')
  local headquarters = require('scripts.headquarters')

  local function prepare()
    defines.command.attack, defines.command.compound, defines.command.stop = 3, 4, 5
    defines.compound_command = {return_last = 1}
    defines.distraction.none = 0
    local hq = ctx.soldier()
    hq.name, hq.type = names.headquarters, 'unit'
    return hq
  end

  ctx.test('headquarters: every order is unarmed and undistracted', function()
    local hq = prepare()
    local target = ctx.soldier('enemy')
    combat.set_command(hq, {type = defines.command.attack_area, destination = {x = 40, y = 0}, radius = 12,
      distraction = defines.distraction.by_enemy})
    assert(hq.command.type == defines.command.go_to_location, 'area attack was not turned into a move')
    assert(hq.command.destination.x == 40 and hq.command.radius == 12, 'move lost its destination')
    assert(hq.command.distraction == defines.distraction.none, 'the headquarters can be distracted')
    assert(not storage.assaults or not storage.assaults[hq.unit_number], 'the headquarters started an assault')
    combat.set_command(hq, {type = defines.command.attack, target = target, distraction = defines.distraction.by_enemy})
    assert(hq.command.type == defines.command.stop and hq.command.ticks_to_wait == 60,
      'a targeted attack does not become a wait that completes')
    local original = {type = defines.command.compound, structure_type = defines.compound_command.return_last,
      commands = {{type = defines.command.attack, target = target},
        {type = defines.command.go_to_location, destination = {x = 5, y = 5}, distraction = defines.distraction.by_enemy}}}
    combat.set_command(hq, original)
    assert(hq.command.commands[1].type == defines.command.stop, 'compound attack kept')
    assert(hq.command.commands[2].distraction == defines.distraction.none, 'compound move distracted')
    assert(original.commands[2].distraction == defines.distraction.by_enemy, 'the shared order was modified')
  end)

  ctx.test('headquarters: never scouts, and an HQ-only scouting division ends cleanly', function()
    local hq = prepare()
    divisions.assign(1, 1, {hq})
    assert(divisions.size(1, 1) == 1, 'the headquarters cannot join a division')
    assert(scout.set(1, 1, true), 'scout mode did not start')
    scout.tick()
    assert(divisions.record(1, 1).mode == 'idle', 'an HQ-only division kept scouting')
    assert(hq.command == nil, 'the headquarters was sent scouting')
  end)

  ctx.test('headquarters: saves without one pay nothing per sweep', function()
    storage.headquarters = nil
    for phase = 0, 9 do headquarters.tick(phase, 10) end
    assert(storage.headquarters == nil, 'a sweep created an empty registry')
  end)
end
