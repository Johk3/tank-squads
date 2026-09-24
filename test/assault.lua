return function(ctx)
  local test, soldier = ctx.test, ctx.soldier
  local assault = require('scripts.assault')
  local geometry = require('scripts.escort_geometry')

  local function close(a, b) return math.abs(a - b) < 1e-6 end

  test('assault geometry: screen size scales with siege tanks and leaves carriers to attack', function()
    assert(assault.screen_size(0, 10) == 0, 'screen without siege tanks')
    assert(assault.screen_size(1, 10) == 2, 'minimum screen is two')
    assert(assault.screen_size(4, 10) == 2)
    assert(assault.screen_size(7, 20) == 4)
    assert(assault.screen_size(10, 6) == 3, 'screen took more than half the carriers')
    assert(assault.screen_size(3, 1) == 0, 'a lone carrier was held back')
  end)

  test('assault geometry: staging stays outside the strongest worm and never closer than 40 tiles', function()
    assert(assault.standoff(5, 30) == 51)
    assert(assault.standoff(5, 48) == 69)
    assert(assault.standoff(5, 0) == 45, 'spawner-only nest staged inside 40 tiles')
    assert(assault.standoff(12, 20) == 52)
  end)

  test('assault geometry: nest center and radius cover every structure', function()
    local center, radius = assault.nest_shape({
      {position = {x = 290, y = 0}}, {position = {x = 300, y = 0}}, {position = {x = 295, y = 12}}})
    assert(close(center.x, 295) and close(center.y, 4), 'wrong center')
    assert(close(radius, 8), 'radius ' .. radius)
  end)

  test('assault geometry: arc slots face the division, 4 tiles apart, in angular order', function()
    local low, mid, high = soldier(nil, nil, 100, -10), soldier(nil, nil, 100, 0), soldier(nil, nil, 100, 10)
    local slots = assault.arc_slots({high, low, mid}, {x = 0, y = 0}, 50, 0)
    for _, e in ipairs({low, mid, high}) do
      assert(close(geometry.distance(slots[e.unit_number], {x = 0, y = 0}), 50), 'slot off the arc')
    end
    assert(close(slots[mid.unit_number].x, 50) and close(slots[mid.unit_number].y, 0), 'middle soldier not on the bearing')
    assert(slots[low.unit_number].y < 0 and slots[high.unit_number].y > 0, 'soldiers cross over')
    local angle = math.atan2(slots[high.unit_number].y, slots[high.unit_number].x)
    assert(close(angle * 50, 4), 'slots not 4 tiles apart along the arc')
  end)

  test('assault geometry: a division too big for the arc wraps evenly around the nest', function()
    local members = {}
    for i = 1, 200 do members[i] = soldier(nil, nil, 100, i - 100) end
    local slots = assault.arc_slots(members, {x = 0, y = 0}, 50, 0)
    local seen = {}
    for _, e in ipairs(members) do
      local p = slots[e.unit_number]
      local key = math.floor(p.x * 100 + 0.5) .. ':' .. math.floor(p.y * 100 + 0.5)
      assert(not seen[key], 'two soldiers share a slot')
      seen[key] = true
    end
  end)

  test('assault geometry: the screen line stands 10 tiles in front of the siege tanks', function()
    local points = assault.screen_points({x = 0, y = 0}, {x = 100, y = 0}, 3)
    assert(#points == 3)
    for i, y in ipairs({-4, 0, 4}) do
      assert(close(points[i].x, 10) and close(points[i].y, y), 'screen point ' .. i)
    end
    local same = assault.screen_points({x = 5, y = 5}, {x = 5, y = 5}, 1)
    assert(close(same[1].x, 15) and close(same[1].y, 5), 'degenerate line')
  end)

  test('assault phases: staging ends on arrival or after 10 seconds without closing in', function()
    assert(assault.stage_over({}, 0, 0), 'arrived division kept staging')
    local progress = {}
    assert(not assault.stage_over(progress, 100, 0))
    assert(not assault.stage_over(progress, 99, 300), 'stalled at 300 ticks')
    assert(not assault.stage_over(progress, 97, 500))
    assert(progress.sum == 97 and progress.tick == 500, 'closing in did not reset the window')
    assert(not assault.stage_over(progress, 97, 1099))
    assert(assault.stage_over(progress, 97, 1100), 'stuck division staged forever')
  end)

  test('assault phases: push and follow triggers', function()
    assert(assault.push_ready(0, 0), 'worms dead but no push')
    assert(not assault.push_ready(1, 1199))
    assert(assault.push_ready(1, 1200), 'barrage never capped')
    assert(assault.follow_ready(true, 0))
    assert(not assault.follow_ready(false, 479))
    assert(assault.follow_ready(false, 480))
  end)

  -- The shared stub ignores `type`; these tests honour it, so a nest search
  -- only sees spawners and worms. `searches.n` counts the engine searches.
  local function world()
    defines.command.attack, defines.command.stop = 3, 5
    prototypes = {entity = {['tank-squad-siege'] = {attack_parameters = {range = 52}}}}
    local structures, searches = {}, {n = 0}
    game.surfaces[1].find_entities_filtered = function(q)
      searches.n = searches.n + 1
      local out = {}
      for _, e in ipairs(structures) do
        local keep = e.valid
        if keep and q.type then
          keep = false
          for _, t in ipairs(q.type) do if e.type == t then keep = true end end
        end
        if keep and q.radius then keep = geometry.distance_squared(e.position, q.position) <= q.radius * q.radius end
        if keep and q.area then
          local a, b = q.area.left_top, q.area.right_bottom
          keep = e.position.x >= a.x and e.position.x <= b.x and e.position.y >= a.y and e.position.y <= b.y
        end
        if keep then out[#out + 1] = e end
      end
      return out
    end
    return structures, searches
  end

  local function spawner(structures, x, y)
    local e = soldier('enemy', nil, x, y)
    e.name, e.type = 'biter-spawner', 'unit-spawner'
    structures[#structures + 1] = e
    return e
  end

  local function worm(structures, x, y, range)
    local e = soldier('enemy', nil, x, y)
    e.name, e.type = 'medium-worm-turret', 'turret'
    e.prototype = {attack_parameters = {range = range}}
    structures[#structures + 1] = e
    return e
  end

  local function tank(name, x, y)
    local e = soldier(nil, nil, x, y)
    if name then e.name = name end
    return e
  end

  -- One siege tank, one flame tank and three carriers in a row from x.
  local function mixed(x)
    return {tank('tank-squad-siege', x, 0), tank('tank-squad-flame', x + 2, 0),
      tank(nil, x + 4, 0), tank(nil, x + 6, 0), tank(nil, x + 8, 0)}
  end

  local function arrive(a, members)
    for _, e in ipairs(members) do
      local slot = a.slots[e.unit_number]
      e.position = {x = slot.x, y = slot.y}
    end
  end

  -- A mixed division at x = 0 facing a worm at 290 and a spawner at 300.
  local function started()
    local structures, searches = world()
    local members = mixed(0)
    local w = worm(structures, 290, 0, 30)
    local sp = spawner(structures, 300, 0)
    local state = {}
    assert(assault.try_start(state, members, w, {'enemy'}), 'no assault')
    return state.assault, members, w, sp, structures, searches
  end

  local function count_role(a, members, role)
    local n = 0
    for _, e in ipairs(members) do if a.roles[e.unit_number] == role then n = n + 1 end end
    return n
  end

  test('assault start: a mixed division at a nest gets roles, a screen and arc slots', function()
    local a, members = started()
    assert(a.phase == 'stage' and a.worm_range == 30 and a.siege_range == 52)
    assert(close(a.center.x, 295) and close(a.radius, 5), 'wrong nest shape')
    local siege, flame, c1, c2, c3 = members[1], members[2], members[3], members[4], members[5]
    assert(a.roles[siege.unit_number] == 'siege' and a.roles[flame.unit_number] == 'flame')
    assert(a.roles[c1.unit_number] == 'screen' and a.screen[c1.unit_number], 'nearest carrier is not the screen')
    assert(a.roles[c2.unit_number] == 'carrier' and a.roles[c3.unit_number] == 'carrier')
    for _, e in ipairs(members) do
      local slot = a.slots[e.unit_number]
      assert(close(geometry.distance(slot, a.center), 51), 'slot not on the staging arc')
      assert(slot.x < a.center.x, 'slot on the far side of the nest')
      assert(e.command.type == defines.command.go_to_location and e.command.destination == slot, 'not sent to its slot')
    end
  end)

  test('assault start: no spawner near the target keeps the plain leg', function()
    local structures = world()
    local lone = worm(structures, 200, 0, 30)
    spawner(structures, 240, 0)
    local state = {}
    assert(not assault.try_start(state, mixed(0), lone, {'enemy'}), 'spawner 40 tiles away made a nest')
    assert(state.assault == nil)
  end)

  test('assault phases: a carrier-only division stages on the arc, then attacks together', function()
    local structures = world()
    local target = spawner(structures, 300, 0)
    local members = {tank(nil, 0, 0), tank(nil, 2, 0), tank(nil, 4, 0)}
    local state = {}
    assert(assault.try_start(state, members, target, {'enemy'}), 'carrier-only division did not stage')
    local a = state.assault
    for _, e in ipairs(members) do
      assert(a.roles[e.unit_number] == 'carrier', 'a carrier got another role')
      assert(e.command.type == defines.command.go_to_location and e.command.destination == a.slots[e.unit_number],
        'carrier not sent to the staging arc')
    end
    assault.tick(a, members)
    assert(a.phase == 'stage', 'carriers attacked before gathering')
    arrive(a, members)
    assault.tick(a, members)
    assert(a.phase == 'follow', 'gathered carriers did not attack')
    for _, e in ipairs(members) do
      assert(e.command.type == defines.command.attack_area, 'a gathered carrier did not attack')
    end
  end)

  test('assault phases: stage, barrage on worms, flame push, carrier follow, done', function()
    local a, members, w, sp = started()
    local siege, flame, screen, c2 = members[1], members[2], members[3], members[4]
    arrive(a, members)
    assert(assault.tick(a, members) == nil)
    assert(a.phase == 'barrage', 'arrived division still staging')
    assert(siege.command.type == defines.command.attack and siege.command.target == w, 'siege did not open on the worm')
    assert(screen.command.type == defines.command.go_to_location, 'screen got no position')
    assert(close(geometry.distance(screen.command.destination, a.siege_center), 10), 'screen not 10 tiles ahead')
    assert(flame.command.destination == a.slots[flame.unit_number], 'flame left the arc during the barrage')
    local held = flame.command
    assault.tick(a, members)
    assert(flame.command == held, 'holding soldier re-ordered every sweep')
    w.valid = false
    assault.tick(a, members)
    assert(a.phase == 'push', 'dead worms did not start the push')
    assert(flame.command.type == defines.command.attack_area, 'flame did not push')
    assert(c2.command.destination == a.slots[c2.unit_number], 'carrier pushed with the flame tank')
    assert(siege.command.target == sp, 'siege did not switch to the spawner')
    flame.health = flame.health - 1
    assault.tick(a, members)
    assert(a.phase == 'follow' and c2.command.type == defines.command.attack_area, 'carriers did not follow a hit flame tank')
    assert(screen.command.type == defines.command.go_to_location, 'screen left the siege line')
    sp.valid = false
    assert(assault.tick(a, members) == 'done')
  end)

  test('assault phases: the barrage is capped at 20 seconds and the carriers follow 8 seconds after the push', function()
    local a, members = started()
    arrive(a, members)
    assault.tick(a, members)
    game.tick = 1199
    assault.tick(a, members)
    assert(a.phase == 'barrage')
    game.tick = 1200
    assault.tick(a, members)
    assert(a.phase == 'push', 'barrage never capped')
    game.tick = 1679
    assault.tick(a, members)
    assert(a.phase == 'push')
    game.tick = 1680
    assault.tick(a, members)
    assert(a.phase == 'follow', 'carriers never followed')
  end)

  test('assault phases: a flame tank reaching the nest edge brings the carriers in', function()
    local a, members, w = started()
    arrive(a, members)
    assault.tick(a, members)
    w.valid = false
    assault.tick(a, members)
    assert(a.phase == 'push')
    members[2].position = {x = a.center.x - a.radius - 9, y = a.center.y}
    assault.tick(a, members)
    assert(a.phase == 'follow', 'flame tank at the edge did not bring the carriers')
  end)

  test('assault phases: a stuck soldier cannot hold the stage beyond the progress timeout', function()
    local a, members = started()
    arrive(a, members)
    members[5].position = {x = 0, y = 0}
    assault.tick(a, members)
    game.tick = 599
    assault.tick(a, members)
    assert(a.phase == 'stage', 'staging ended early')
    game.tick = 600
    assault.tick(a, members)
    assert(a.phase == 'barrage', 'stuck carrier held the stage')
  end)

  test('assault phases: a spawner-only nest stages 40 tiles out and pushes straight after the first barrage sweep', function()
    local structures = world()
    local members = mixed(0)
    local sp = spawner(structures, 300, 0)
    local state = {}
    assert(assault.try_start(state, members, sp, {'enemy'}))
    local a = state.assault
    assert(a.worm_range == 0 and close(geometry.distance(a.slots[members[1].unit_number], a.center), 40))
    arrive(a, members)
    assault.tick(a, members)
    assert(a.phase == 'barrage' and members[1].command.target == sp)
    assault.tick(a, members)
    assert(a.phase == 'push', 'no worms, yet the barrage waited')
  end)

  test('assault phases: without a siege tank the flame tanks push straight after staging; without flame tanks the carriers follow the barrage', function()
    local structures = world()
    local w = worm(structures, 290, 0, 30)
    spawner(structures, 300, 0)
    local state = {}
    local no_siege = {tank('tank-squad-flame', 0, 0), tank(nil, 2, 0), tank(nil, 4, 0)}
    assert(assault.try_start(state, no_siege, w, {'enemy'}))
    local a = state.assault
    assert(count_role(a, no_siege, 'screen') == 0, 'screen without siege tanks')
    arrive(a, no_siege)
    assault.tick(a, no_siege)
    assert(a.phase == 'push', 'flame tanks waited for a barrage that never comes')
    state = {}
    local no_flame = {tank('tank-squad-siege', 0, 0), tank(nil, 2, 0), tank(nil, 4, 0), tank(nil, 6, 0), tank(nil, 8, 0)}
    assert(assault.try_start(state, no_flame, w, {'enemy'}))
    a = state.assault
    arrive(a, no_flame)
    assault.tick(a, no_flame)
    w.valid = false
    assault.tick(a, no_flame)
    assert(a.phase == 'follow', 'carriers waited for a push that never comes')
    assert(no_flame[5].command.type == defines.command.attack_area)
  end)

  test('assault join: late soldiers take their role without holding the stage', function()
    local a, members, w = started()
    local recruit = tank('tank-squad-flame', -400, 0)
    assert(assault.join(a, recruit))
    assert(a.roles[recruit.unit_number] == 'flame', 'recruit got no role')
    assert(recruit.command.destination == a.slots[recruit.unit_number], 'recruit not sent to the arc')
    arrive(a, members)
    members[#members + 1] = recruit
    assault.tick(a, members)
    assert(a.phase == 'barrage', 'a distant recruit held the stage')
    local gunner = tank('tank-squad-siege', 200, 0)
    assault.join(a, gunner)
    assert(gunner.command.type == defines.command.attack and gunner.command.target == w, 'late siege tank did not join the barrage')
  end)

  test('assault roles: a lost screen carrier is replaced by the nearest attacking carrier', function()
    local a, members = started()
    arrive(a, members)
    assault.tick(a, members)
    local lost = table.remove(members, 3)
    assault.tick(a, members)
    assert(a.roles[lost.unit_number] == nil and not a.screen[lost.unit_number], 'lost soldier kept its role')
    assert(count_role(a, members, 'screen') == 1, 'screen not refilled')
  end)

  test('assault roles: without siege tanks the screen joins the attack', function()
    local a, members = started()
    local screen = members[3]
    arrive(a, members)
    assault.tick(a, members)
    table.remove(members, 1)
    game.tick = 1200
    assault.tick(a, members)
    assert(a.roles[screen.unit_number] == 'carrier', 'screen kept guarding a lost siege line')
    game.tick = 1680
    assault.tick(a, members)
    assert(a.phase == 'follow' and screen.command.type == defines.command.attack_area, 'former screen did not attack')
  end)

  test('assault end: a nest destroyed by others ends the assault; no kill for 5 minutes fails it', function()
    local a, members, w, sp, structures = started()
    w.valid, sp.valid = false, false
    assert(assault.tick(a, members) == 'done', 'assault outlived its nest')
    local w2 = worm(structures, 290, 200, 30)
    spawner(structures, 300, 200)
    local state = {}
    assert(assault.try_start(state, members, w2, {'enemy'}))
    a = state.assault
    assert(#a.structures == 2, 'destroyed structures cached')
    game.tick = 10000
    w2.valid = false
    assert(assault.tick(a, members) == nil)
    game.tick = 10000 + assault.NO_KILL_TIMEOUT - 1
    assert(assault.tick(a, members) == nil, 'a kill did not reset the timeout')
    game.tick = 10000 + assault.NO_KILL_TIMEOUT
    assert(assault.tick(a, members) == 'failed', 'stalled assault never gave up')
  end)

  test('assault completions: a finished fire or attack order is re-issued next sweep, a finished move is not', function()
    local a, members, w = started()
    local siege, flame = members[1], members[2]
    arrive(a, members)
    assault.tick(a, members)
    local first = siege.command
    assault.on_command_completed(a, siege.unit_number)
    assault.on_command_completed(a, flame.unit_number)
    assert(a.orders[siege.unit_number] == nil, 'fire order not re-armed')
    assert(a.orders[flame.unit_number] == 'slot', 'arrival cleared a holding order')
    assault.tick(a, members)
    assert(siege.command ~= first and siege.command.target == w, 'siege not re-ordered')
  end)

  local divisions = require('scripts.divisions')
  local commands = require('scripts.commands')
  local escort = require('scripts.escort')

  local function ward(index, x, y)
    local p = game.players[1]
    local character = soldier(nil, nil, x, y)
    character.name, character.type = 'character', 'character'
    game.players[index] = {index = index, name = 'ward' .. index, force = p.force, surface = p.surface,
      character = character, print = function() end,
      gui = {left = ctx.gui_element(), screen = ctx.gui_element()}, set_shortcut_toggled = function() end}
  end

  local function escort_world()
    local structures = world()
    game.players[1].print = function() end
    game.forces = {player = game.players[1].force, enemy = 'enemy'}
    game.players[1].force.is_enemy = function(other) return other == 'enemy' end
    game.surfaces[1].find_units = function() return {} end
    return structures
  end

  local function settle()
    for _ = 1, 5 do escort.tick() end
  end

  -- Division 3 escorts ward 2 at the origin in offensive formation. The ward
  -- settles over five sweeps; the fifth picks the first leg.
  local function offensive(members)
    ward(2, 0, 0)
    divisions.assign(1, 3, members)
    escort.start(1, 3, 2, 'offensive')
    settle()
    return divisions.record(1, 3).escort
  end

  local function nest(structures)
    return worm(structures, 290, 0, 30), spawner(structures, 300, 0)
  end

  test('assault wiring: a mixed offensive escort stages at a nest instead of a plain leg', function()
    local structures = escort_world()
    nest(structures)
    local members = mixed(5)
    local state = offensive(members)
    assert(state.assault and state.assault.phase == 'stage', 'no nest assault')
    assert(state.leg == nil, 'plain leg ran beside the assault')
    for _, e in ipairs(members) do
      assert(e.command.destination == state.assault.slots[e.unit_number], 'soldier not sent to the staging arc')
    end
  end)

  test('assault wiring: worm-only targets and the defensive formation keep plain legs; carrier-only escorts stage', function()
    local structures = escort_world()
    worm(structures, 290, 0, 30)
    local state = offensive(mixed(5))
    assert(state.assault == nil and state.leg.command.type == defines.command.attack_area, 'worm-only target changed')
    spawner(structures, 300, 0)
    escort.start(1, 3, 2, 'defensive')
    settle()
    assert(divisions.record(1, 3).escort.assault == nil, 'defensive escort assaulted')
    divisions.assign(1, 4, {tank(nil, 5, 4), tank(nil, 7, 4)})
    escort.start(1, 4, 2, 'offensive')
    settle()
    local carriers = divisions.record(1, 4).escort
    assert(carriers.assault and carriers.assault.phase == 'stage' and carriers.leg == nil, 'carrier-only escort did not stage')
  end)

  test('assault wiring: a manual attack order on a nest is unchanged', function()
    local structures = escort_world()
    nest(structures)
    local members = mixed(5)
    divisions.assign(1, 3, members)
    divisions.set_selected(1, 3)
    local area = {left_top = {x = 285, y = -5}, right_bottom = {x = 305, y = 5}}
    assert(commands.order(1, area, game.surfaces[1]) == 'attack')
    for _, e in ipairs(members) do assert(e.command.type == defines.command.attack_area, 'manual attack staged') end
    assert(divisions.record(1, 3).escort == nil)
  end)

  test('assault wiring: a destroyed nest ends the assault and the escort roams on', function()
    local structures = escort_world()
    local w, sp = nest(structures)
    local state = offensive(mixed(5))
    w.valid, sp.valid = false, false
    escort.tick()
    assert(state.assault == nil, 'assault outlived its nest')
    escort.tick()
    assert(state.leg and state.leg.command.type == defines.command.go_to_location, 'escort did not roam on')
  end)

  test('assault wiring: an assault with no kill for 5 minutes blocks the nest and moves on', function()
    local structures = escort_world()
    nest(structures)
    local state = offensive(mixed(5))
    game.tick = assault.NO_KILL_TIMEOUT
    escort.tick()
    assert(state.assault == nil and state.failed and state.failed['9:0'], 'failed nest not blocked')
    escort.tick()
    assert(state.assault == nil and state.leg.command.type == defines.command.go_to_location, 'blocked nest retried')
  end)

  test('assault wiring: convoy guards never come from the screen, and healed soldiers rejoin in role', function()
    local structures = escort_world()
    nest(structures)
    local members = {}
    for i = 1, 9 do members[i] = tank(nil, 5 + i, 0) end
    members[10] = tank('tank-squad-siege', 5, 0)
    members[11] = tank('tank-squad-siege', 5, 2)
    members[12] = tank('tank-squad-flame', 4, 0)
    local state = offensive(members)
    ctx.building().position = {x = 30, y = 0}
    local a = state.assault
    assert(a.roles[members[1].unit_number] == 'screen' and a.roles[members[2].unit_number] == 'screen',
      'test setup: the lowest unit numbers are not the screen')
    local injured = members[9]
    injured.health = 60
    escort.tick()
    local away = state.retreat.away
    assert(away[injured.unit_number], 'test setup: no retreat')
    assert(not away[members[1].unit_number] and not away[members[2].unit_number], 'screen carrier taken as a convoy guard')
    assert(away[members[3].unit_number], 'test setup: no convoy guard')
    assert(a.roles[injured.unit_number] == nil, 'away soldier kept its role')
    injured.health = 400
    escort.tick()
    assert(a.roles[injured.unit_number] == 'carrier', 'healed soldier did not rejoin the assault')
  end)

  test('assault wiring: an injured screen carrier leaves and the nearest carrier takes its place', function()
    local structures = escort_world()
    nest(structures)
    local members = mixed(5)
    local state = offensive(members)
    ctx.building().position = {x = 30, y = 0}
    local a = state.assault
    local screen = members[3]
    assert(a.roles[screen.unit_number] == 'screen', 'test setup: wrong screen')
    screen.health = 60
    escort.tick()
    assert(state.retreat.away[screen.unit_number], 'test setup: no retreat')
    assert(count_role(a, members, 'screen') == 1, 'screen not refilled')
  end)

  test('assault wiring: switching formation or stopping the escort drops the assault', function()
    local structures = escort_world()
    nest(structures)
    offensive(mixed(5))
    escort.start(1, 3, 2, 'defensive')
    assert(divisions.record(1, 3).escort.assault == nil, 'formation switch kept the assault')
    escort.start(1, 3, 2, 'offensive')
    settle()
    assert(divisions.record(1, 3).escort.assault, 'test setup: no second assault')
    escort.stop(1, 3)
    assert(divisions.record(1, 3).escort == nil)
  end)

  test('assault wiring: completions, recruits and settings changes reach the running assault', function()
    local structures = escort_world()
    local w = nest(structures)
    local members = mixed(5)
    local state = offensive(members)
    local a = state.assault
    arrive(a, members)
    escort.tick()
    assert(a.phase == 'barrage', 'test setup: no barrage')
    local siege = members[1]
    assert(escort.on_command_completed(siege.unit_number, defines.behavior_result.success))
    assert(a.orders[siege.unit_number] == nil, 'siege completion did not reach the assault')
    local recruit = tank('tank-squad-siege', 0, 0)
    divisions.add_member(1, 3, recruit.unit_number, recruit)
    assert(escort.join(divisions.record(1, 3), recruit))
    assert(a.roles[recruit.unit_number] == 'siege' and recruit.command.target == w, 'recruit did not join the barrage')
    escort.on_settings_changed()
    assert(state.assault == a, 'settings change dropped the assault')
  end)

  test('assault roles: losing every siege tank during the barrage starts the push at once', function()
    local a, members = started()
    arrive(a, members)
    assault.tick(a, members)
    assert(a.phase == 'barrage', 'test setup: no barrage')
    table.remove(members, 1)
    game.tick = 60
    assault.tick(a, members)
    assert(a.phase == 'push', 'division idled without siege tanks')
    assert(members[1].command.type == defines.command.attack_area, 'flame tank did not push')
  end)

  test('assault roles: a siege tank arriving after staging gets a working screen', function()
    local structures = world()
    local w = worm(structures, 290, 0, 30)
    spawner(structures, 300, 0)
    local members = {tank('tank-squad-flame', 0, 0), tank(nil, 2, 0), tank(nil, 4, 0), tank(nil, 6, 0), tank(nil, 8, 0)}
    local state = {}
    assert(assault.try_start(state, members, w, {'enemy'}))
    local a = state.assault
    arrive(a, members)
    assault.tick(a, members)
    assert(a.phase == 'push', 'test setup: no push')
    local gunner = tank('tank-squad-siege', 200, 0)
    assault.join(a, gunner)
    members[#members + 1] = gunner
    assault.tick(a, members)
    local screens = 0
    for _, e in ipairs(members) do
      if a.roles[e.unit_number] == 'screen' then
        screens = screens + 1
        local slot = a.screen_slots[e.unit_number]
        assert(slot and e.command.destination == slot.point, 'screen carrier sent back to the arc')
      end
    end
    assert(screens == 2, 'screen not formed: ' .. screens)
  end)

  test('assault failures: when every attacker fails to reach the nest the assault gives up', function()
    local a, members = started()
    arrive(a, members)
    assault.tick(a, members)
    assert(a.phase == 'barrage', 'test setup: no barrage')
    assault.on_command_completed(a, members[1].unit_number, defines.behavior_result.fail)
    assert(assault.tick(a, members) == 'failed', 'unreachable nest held the division')
  end)

  test('assault failures: one stuck attacker is not re-ordered and does not end the assault; a kill retries it', function()
    local structures = world()
    local members = mixed(0)
    local w = worm(structures, 290, 0, 30)
    local sp = spawner(structures, 300, 0)
    spawner(structures, 300, 10)
    local state = {}
    assert(assault.try_start(state, members, w, {'enemy'}))
    local a = state.assault
    arrive(a, members)
    assault.tick(a, members)
    w.valid = false
    assault.tick(a, members)
    assert(a.phase == 'push', 'test setup: no push')
    local flame = members[2]
    local held = flame.command
    assault.on_command_completed(a, flame.unit_number, defines.behavior_result.fail)
    assert(assault.tick(a, members) == nil, 'one stuck flame tank ended the assault')
    assert(flame.command == held, 'failed attacker re-ordered every sweep')
    sp.valid = false
    assault.tick(a, members)
    assert(flame.command ~= held and flame.command.type == defines.command.attack_area, 'a kill did not retry the stuck attacker')
  end)

  test('assault wiring: an unreachable nest is given up and every chunk it covers is blocked', function()
    local structures = escort_world()
    worm(structures, 318, 0, 30)
    spawner(structures, 326, 0)
    local members = mixed(5)
    local state = offensive(members)
    local a = state.assault
    arrive(a, members)
    escort.tick()
    assert(a.phase == 'barrage', 'test setup: no barrage')
    assert(escort.on_command_completed(members[1].unit_number, defines.behavior_result.fail))
    escort.tick()
    assert(state.assault == nil, 'unreachable nest held the division')
    assert(state.failed['9:0'] and state.failed['10:0'], 'a chunk of the nest stayed open')
    escort.tick()
    assert(state.assault == nil and state.leg.command.type == defines.command.go_to_location, 'blocked nest retried')
  end)
end
