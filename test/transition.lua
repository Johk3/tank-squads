return function(ctx)
  local test, soldier, building = ctx.test, ctx.soldier, ctx.building
  local transition = require('scripts.transition')
  local veterans = require('scripts.veterans')
  local weapons = require('scripts.weapons')
  local divisions = require('scripts.divisions')
  local patrol = require('scripts.patrol')
  local barracks = require('scripts.barracks')

  local function with_rolls(values, run)
    local i, old = 0, transition.random
    -- Each call, with or without an argument, returns the next listed value.
    transition.random = function()
      i = i + 1
      return values[i]
    end
    storage.transition_override = nil
    local ok, err = pcall(run)
    transition.random = old
    if not ok then error(err, 0) end
  end

  test('transition: odds rise with rank and only carriers roll', function()
    assert(transition.CHANCE[1] == 0.01 and transition.CHANCE[2] == 0.02 and transition.CHANCE[3] == 0.03
      and transition.CHANCE[4] == 0.05 and transition.CHANCE[5] == 0.08)
    with_rolls({0.009, 1}, function()
      assert(transition.pick('tank-squad-soldier-1', 1) == 'tank-squad-electric')
    end)
    with_rolls({0.009, 2}, function()
      assert(transition.pick('tank-squad-soldier-3', 1) == 'tank-squad-nuclear')
    end)
    with_rolls({0.01}, function() assert(transition.pick('tank-squad-soldier-2', 1) == nil, '1% roll at 0.01') end)
    with_rolls({0.079, 1}, function() assert(transition.pick('tank-squad-soldier-2', 5) ~= nil) end)
    with_rolls({0, 1}, function()
      assert(transition.pick('tank-squad-siege', 5) == nil and transition.pick('tank-squad-electric', 5) == nil)
    end)
    storage.transition_override = false
    assert(transition.pick('tank-squad-soldier-1', 5) == nil)
    storage.transition_override = 'tank-squad-nuclear'
    assert(transition.pick('tank-squad-soldier-1', 1) == 'tank-squad-nuclear')
    assert(transition.pick('tank-squad-flame', 1) == nil)
  end)

  local function swappable()
    local old = soldier()
    old.surface.create_entity = function(args)
      local e = soldier(nil, nil, args.position.x, args.position.y)
      e.name = args.name
      e.max_health = args.name == 'tank-squad-electric' and 1400 or 1600
      e.health = e.max_health
      return e
    end
    old.destroy = function(args) old.valid = false; old.destroyed = args end
    weapons.register(old)
    return old
  end

  test('transition: the new tank keeps the service record, health share and division job', function()
    local old = swappable()
    local mate = soldier()
    weapons.register(mate)
    divisions.assign(1, 2, {old, mate})
    patrol.add_waypoint(1, 2, {x = 40, y = 0}, old.surface)
    patrol.start(1, 2)
    local record = veterans.get(old.unit_number)
    record.xp, record.kills, record.rank = 300, 12, 2
    old.health = 200
    local old_id = old.unit_number
    local new = assert(transition.swap(old, 'tank-squad-electric'))
    assert(not old.valid and old.destroyed.raise_destroy == true, 'old tank not destroyed with an event')
    assert(veterans.get(old_id) == nil and veterans.get(new.unit_number) == record, 'record not moved')
    assert(record.kind == 'tank-squad-electric' and record.xp == 300 and record.kills == 12 and record.rank == 2)
    assert(math.abs(new.health - 700) < 1e-9, 'health share ' .. new.health)
    assert(math.abs(new.speed - new.prototype.speed * 1.6) < 1e-9, 'rank speed not applied')
    assert(storage.weapons[old_id] == nil and storage.weapons[new.unit_number], 'gun records not swapped')
    assert(storage.weapons[new.unit_number].rank == 2, 'gun record lost the rank')
    local members = divisions.get(1, 2)
    local ids = {}
    for _, e in ipairs(members) do ids[e.unit_number] = true end
    assert(ids[new.unit_number] and ids[mate.unit_number] and not ids[old_id], 'division not updated')
    assert(new.command and new.command.destination, 'new tank did not join the patrol')
  end)

  test('transition leaves no stale unit number in the reinforcement quota', function()
    local b = building()
    assert(barracks.configure(b, 1, 3, 2))
    local old = swappable()
    divisions.assign(1, 3, {old})
    local sources = divisions.record(1, 3).reinforcement_sources
    local own = sources[b.unit_number]
    own.recruits = {old.unit_number}
    local old_id = old.unit_number
    local new = assert(transition.swap(old, 'tank-squad-nuclear'))
    assert(own.recruits[1] == new.unit_number, 'quota still counts ' .. tostring(own.recruits[1]) .. ' not ' .. old_id)
  end)

  test('transition: a tank in no division swaps without joining one', function()
    local old = swappable()
    local new = assert(transition.swap(old, 'tank-squad-electric'))
    assert(divisions.owner(new.unit_number) == nil)
  end)

  test('transition: promotion rolls through control and tells the force', function()
    dofile('control.lua')
    local old = swappable()
    local record = veterans.get(old.unit_number)
    storage.transition_override = 'tank-squad-electric'
    local player = ctx.players()[1]
    player.play_sound = function() player.sounded = true end
    veterans.add_xp(old, record, 50)
    assert(not old.valid, 'promotion did not transition')
    local texts = player.flying
    assert(texts[1].text[1] == 'tank-squads.promoted' and texts[2].text[1] == 'tank-squads.transitioned-electric')
    assert(player.sounded, 'no sound')
  end)
end
