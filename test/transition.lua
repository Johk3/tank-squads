return function(ctx)
  local test, soldier, building = ctx.test, ctx.soldier, ctx.building
  local transition = require('scripts.transition')
  local veterans = require('scripts.veterans')
  local weapons = require('scripts.weapons')
  local divisions = require('scripts.divisions')
  local patrol = require('scripts.patrol')
  local barracks = require('scripts.barracks')
  local scout = require('scripts.scout')

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

  test('transition: a rebuilt scout keeps its team place and raises no alarm', function()
    local old = swappable()
    local list = {old, soldier(nil, nil, 2, 0), soldier(nil, nil, 4, 0)}
    for i = 2, 3 do weapons.register(list[i]) end
    divisions.assign(1, 4, list)
    assert(scout.set(1, 4, true), 'scout mode did not start')
    scout.tick()
    local state = divisions.record(1, 4).scout
    local id = state.team_of[old.unit_number]
    local team = state.teams[id]
    assert(team and team.hop, 'the team did not set out')
    local old_id = old.unit_number
    local new = assert(transition.swap(old, 'tank-squad-electric'))
    assert(state.team_of[old_id] == nil and state.team_of[new.unit_number] == id, 'team index not renamed')
    local places = 0
    for _, unit in ipairs(team.members) do
      assert(unit ~= old_id, 'the old unit number is still in the team')
      if unit == new.unit_number then places = places + 1 end
    end
    assert(places == 1, 'the new tank holds ' .. places .. ' places')
    assert(not team.hop.pending[old_id] and not team.hop.front[old_id], 'the hop still waits for the old tank')
    assert(new.command and new.command.destination, 'the new tank has no order')
    scout.tick()
    assert(not team.call and not (team.hop and team.hop.fallback), 'the rebuild was read as a death')
  end)

  test('transition: a rebuilt soldier away healing keeps its convoy place', function()
    local retreat = require('scripts.retreat')
    local state = {retreat = {next_id = 2, convoys = {[1] = {injured = {[5] = true}, guards = {}, resend = {}}},
      away = {[5] = 1}, cooldown = {[5] = 100}}}
    assert(retreat.replace(state, 5, 9), 'an away soldier was not reported away')
    local r, convoy = state.retreat, state.retreat.convoys[1]
    assert(r.away[5] == nil and r.away[9] == 1 and r.cooldown[5] == nil and r.cooldown[9] == 100, 'away marks not renamed')
    assert(convoy.injured[9] and not convoy.injured[5] and convoy.resend[9], 'convoy does not send the new unit')
    assert(not retreat.replace(state, 7, 8), 'a soldier at hand was reported away')
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
