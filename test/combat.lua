return function(ctx)
  local combat = require('scripts.combat')
  local function prepare()
    defines.command.attack, defines.command.compound, defines.command.stop = 3, 4, 5
    defines.compound_command = {return_last = 1}
    defines.distraction.none = 0
    local a = ctx.soldier()
    a.type = 'unit'
    a.force.get_friend = function() return false end
    a.force.get_cease_fire = function() return false end
    local b = ctx.soldier('enemy')
    b.type, b.destructible = 'unit', true
    return a, b
  end
  ctx.test('defense resumes the latest order and repeated damage does not restart shooting', function()
    local a, b = prepare()
    local order = {type = defines.command.attack_area, destination = {x = 40, y = 0}, radius = 12}
    combat.set_command(a, order)
    a.commandable.command = order
    combat.on_damaged{entity = a, cause = b}
    local defense = a.command
    assert(defense.commands[1].target == b and defense.commands[2] == order)
    combat.on_damaged{entity = a, cause = b}
    assert(a.command == defense, 'damage restarted attack cooldown')
    local replacement = {type = defines.command.go_to_location, destination = {x = -40, y = 0}}
    combat.set_command(a, replacement)
    a.commandable.command = replacement
    combat.on_damaged{entity = a, cause = b}
    assert(a.command.commands[2] == replacement, 'defense restored obsolete order')
  end)
  ctx.test('building attack prioritizes a nearby hostile unit with bounded shot searches', function()
    local a, b = prepare()
    a.commandable.command = {type = defines.command.attack_area, destination = {x = 40, y = 0}, radius = 12}
    local base = ctx.soldier('enemy')
    base.type = 'unit-spawner'
    local searches = 0
    a.surface.find_units = function() searches = searches + 1; return {b} end
    for tick = 0, 24, 12 do combat.on_shot{effect_id = 'tank-squad-shot', source_entity = a, target_entity = base, tick = tick} end
    assert(a.command.commands[1].target == b)
    assert(searches == 1, 'scanned enemies on every shot')
    combat.on_shot{effect_id = 'tank-squad-shot', source_entity = a, target_entity = b, tick = 60}
    assert(searches == 1, 'scanned while already fighting a unit')
  end)
  ctx.test('repeated damage during a live defense does not read commands back', function()
    local a, b = prepare()
    a.commandable.command = {type = defines.command.go_to_location, destination = {x = 40, y = 0}}
    combat.on_damaged{entity = a, cause = b}
    local defense = a.command
    local reads = {ctx.count_reads(a.commandable, 'command'), ctx.count_reads(a.commandable, 'distraction_command')}
    for _ = 1, 5 do combat.on_damaged{entity = a, cause = b} end
    assert(reads[1].n + reads[2].n == 0, 'each hit reads the command back')
    assert(a.command == defense, 'damage restarted the defense')
  end)
  ctx.test('throttled building shots skip entity reads', function()
    local a = prepare()
    local base = ctx.soldier('enemy')
    base.type = 'unit-spawner'
    a.surface.find_units = function() return {} end
    combat.on_shot{effect_id = 'tank-squad-shot', source_entity = a, target_entity = base, tick = 0}
    local reads = {ctx.count_reads(a, 'name'), ctx.count_reads(base, 'type')}
    for tick = 12, 24, 12 do combat.on_shot{effect_id = 'tank-squad-shot', source_entity = a, target_entity = base, tick = tick} end
    assert(reads[1].n + reads[2].n == 0, 'throttled shots read entity properties')
  end)
  ctx.test('friendly damage and unrelated effects cannot hijack a carrier', function()
    local a = prepare()
    local ally = ctx.soldier()
    ally.type = 'unit'
    combat.on_damaged{entity = a, cause = ally}
    combat.on_damaged{entity = a}
    combat.on_shot{effect_id = 'unrelated', source_entity = a, target_entity = ally}
    assert(a.command == nil)
  end)

  ctx.test('ranged assault advances across buildings and stops retrying failed paths', function()
    local a = prepare()
    local first, second = ctx.soldier('enemy'), ctx.soldier('enemy')
    first.type, second.type = 'unit-spawner', 'unit-spawner'
    a.surface.find_nearest_enemy = function() if first.valid then return first elseif second.valid then return second end end
    combat.set_command(a, {type = defines.command.attack_area, destination = {x = 40, y = 0}, radius = 12})
    assert(a.command.type == defines.command.attack and a.command.target == first)
    first.valid = false
    assert(combat.on_command_completed(a.unit_number, defines.behavior_result.fail), 'another carrier killing the target stopped the assault')
    assert(a.command.target == second, 'did not advance to next building')
    assert(not combat.on_command_completed(a.unit_number, defines.behavior_result.fail))
    assert(storage.assaults[a.unit_number] == nil, 'unreachable target loops forever')
  end)

  ctx.test('defense never resumes an attack on a destroyed building', function()
    local a, first = prepare()
    local nest, worm = ctx.soldier('enemy'), ctx.soldier('enemy')
    nest.type, worm.type = 'unit-spawner', 'turret'
    a.commandable.command = {type = defines.command.attack, target = nest, distraction = defines.distraction.by_enemy}
    combat.on_damaged{entity = a, cause = first}
    first.valid, nest.valid = false, false
    -- The engine omits the target of a live command once it is destroyed.
    a.commandable.command = {type = defines.command.attack, distraction = defines.distraction.by_enemy}
    local incoming = ctx.soldier('enemy')
    incoming.type, incoming.destructible = 'unit', true
    a.surface.find_units = function() return {incoming} end
    combat.on_shot{effect_id = 'tank-squad-shot', source_entity = a, target_entity = worm, tick = 60}
    assert(a.command.commands[1].target == incoming)
    assert(a.command.commands[2].type == defines.command.stop, 'resumed attack on destroyed nest')
    storage.combat = nil
    combat.on_shot{effect_id = 'tank-squad-shot', source_entity = a, target_entity = worm, tick = 120}
    assert(a.command.commands[2].type == defines.command.stop, 'resumed targetless live attack')
    assert(a.command.commands[2].ticks_to_wait == 1, 'defense of a finished attack never completes')
  end)

  ctx.test('an idle carrier stays stopped after its defense', function()
    local a, b = prepare()
    combat.on_damaged{entity = a, cause = b}
    assert(a.command.commands[2].type == defines.command.stop)
    assert(a.command.commands[2].ticks_to_wait == nil, 'idle carrier reports a completion it never had')
  end)

  ctx.test('resumed building fire can replace a stale failed defense target', function()
    local a, old = prepare()
    a.commandable.command = {type = defines.command.attack_area, destination = {x = 40, y = 0}, radius = 12}
    combat.on_damaged{entity = a, cause = old}
    local base, incoming = ctx.soldier('enemy'), ctx.soldier('enemy')
    base.type, incoming.type, incoming.destructible = 'unit-spawner', 'unit', true
    a.surface.find_units = function() return {incoming} end
    a.commandable.command = a.command
    combat.on_shot{effect_id = 'tank-squad-shot', source_entity = a, target_entity = base, tick = 60}
    assert(a.command.commands[1].target == incoming, 'stale living target blocked new defense')
    assert(a.command.commands[2].type == defines.command.attack_area, 'nested obsolete defense instead of original order')
  end)
end
