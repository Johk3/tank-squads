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

  local function obstacle(kind, x, y, force)
    local e = ctx.soldier(nil, nil, x, y)
    e.name, e.type, e.force = kind, kind, force or 'neutral'
    e.destroy = function(args) e.valid = false; e.destroyed_with = args end
    return e
  end

  ctx.test('headquarters: a driving headquarters clears trees, rocks and cliffs in its way', function()
    local hq = prepare()
    hq.position = {x = 0, y = 0}
    hq.commandable.command = {type = defines.command.go_to_location, destination = {x = 100, y = 0}}
    local tree, rock, cliff = obstacle('tree', 8, 2), obstacle('simple-entity', 3, -3), obstacle('cliff', 10, 0)
    local behind = obstacle('tree', -12, 0)
    local far = obstacle('tree', 40, 0)
    local wall = obstacle('stone-wall', 6, 0, game.players[1].force)
    headquarters.clear_path({entity = hq})
    assert(not tree.valid and not rock.valid and not cliff.valid, 'an obstacle in the way was left standing')
    assert(cliff.destroyed_with and cliff.destroyed_with.do_cliff_correction, 'cliff removed without correction')
    assert(behind.valid and far.valid, 'cleared outside the path')
    assert(wall.valid, 'a player building was destroyed')
  end)

  ctx.test('headquarters: a parked headquarters leaves the trees alone', function()
    local hq = prepare()
    hq.position = {x = 0, y = 0}
    local tree = obstacle('tree', 4, 0)
    hq.commandable.command = nil
    headquarters.clear_path({entity = hq})
    hq.commandable.command = {type = defines.command.stop}
    headquarters.clear_path({entity = hq})
    assert(tree.valid, 'a parked headquarters cleared a tree')
  end)

  ctx.test('headquarters: saves without one pay nothing per sweep', function()
    storage.headquarters = nil
    for phase = 0, 9 do headquarters.tick(phase, 10) end
    assert(storage.headquarters == nil, 'a sweep created an empty registry')
  end)
end
