return function(ctx)
  local test, soldier = ctx.test, ctx.soldier
  local names = require('scripts.names')

  -- The shared harness knows one force and exact-match queries. This adds
  -- an enemy force, the commands and controllers the engineers use, force
  -- lists and ghost_name in queries, and robot coverage as circles.
  local function all()
    local out, i = {}, 1
    while true do
      local e = game.get_entity_by_unit_number(i)
      if not e then break end
      out[#out + 1] = e
      i = i + 1
    end
    return out
  end

  local function force_matches(wanted, e)
    if wanted == nil then return true end
    local list = (type(wanted) == 'table' and wanted[1] ~= nil) and wanted or {wanted}
    for _, f in ipairs(list) do
      if f == e.force then return true end
      if type(f) == 'number' and type(e.force) == 'table' and e.force.index == f then return true end
    end
    return false
  end

  local function one_of(wanted, value)
    if wanted == nil then return true end
    local list = type(wanted) == 'table' and wanted or {wanted}
    for _, v in ipairs(list) do if v == value then return true end end
    return false
  end

  local function engine()
    defines.command.attack, defines.command.stop, defines.command.compound = 3, 4, 5
    defines.compound_command = {return_last = 1}
    defines.distraction.none = 0
    defines.controllers = {remote = 7}
    prototypes = {entity = {['tank-squad-siege'] = {attack_parameters = {range = 52}}}}
    local player = ctx.players()[1]
    player.surface_index = 1
    player.printed = {}
    player.print = function(message) player.printed[#player.printed + 1] = message end
    player.set_controller = function(args) player.controller = args end
    local own = player.force
    local enemy = {index = 2, name = 'enemy'}
    own.is_enemy = function(other) return other == enemy end
    enemy.is_enemy = function(other) return other == own end
    game.forces = {own, enemy}
    local surface = game.surfaces[1]
    surface.play_sound = function() end
    surface.find_units = function() return {} end
    surface.networks = {}
    surface.find_logistic_networks_by_construction_area = function(position)
      local out = {}
      for _, n in ipairs(surface.networks) do
        local dx, dy = position.x - n.x, position.y - n.y
        if dx * dx + dy * dy <= n.r * n.r then out[#out + 1] = n end
      end
      return out
    end
    surface.find_non_colliding_position = function(_, position) return {x = position.x, y = position.y} end
    surface.create_entity = function(args)
      local e = soldier(args.force, nil, args.position.x, args.position.y)
      e.name, e.type = args.name, 'unit'
      e.health, e.max_health = 800, 800
      e.destroy = function() e.valid = false end
      return e
    end
    surface.find_entities_filtered = function(q)
      local out = {}
      for _, e in ipairs(all()) do
        local ok = e.valid and e.surface == surface and one_of(q.name, e.name) and one_of(q.type, e.type)
          and one_of(q.ghost_name, e.ghost_name) and force_matches(q.force, e)
        if ok and q.radius then
          local dx, dy = e.position.x - q.position.x, e.position.y - q.position.y
          ok = dx * dx + dy * dy <= q.radius * q.radius
        end
        if ok and q.area then
          local a, b = q.area.left_top or q.area[1], q.area.right_bottom or q.area[2]
          local ax, ay, bx, by = a.x or a[1], a.y or a[2], b.x or b[1], b.y or b[2]
          ok = e.position.x >= ax and e.position.x <= bx and e.position.y >= ay and e.position.y <= by
        end
        if ok then out[#out + 1] = e end
        if q.limit and #out >= q.limit then break end
      end
      return out
    end
    return own, enemy, surface
  end

  local function constructor_entity(x, y)
    local own = ctx.players()[1].force
    return game.surfaces[1].create_entity{name = names.constructor, position = {x = x or 0, y = y or 0}, force = own}
  end

  local function ghost(x, y, name)
    local g = soldier(nil, nil, x, y)
    g.name, g.type, g.ghost_name = 'entity-ghost', 'entity-ghost', name or 'stone-wall'
    g.bounding_box = {left_top = {x = x - 0.5, y = y - 0.5}, right_bottom = {x = x + 0.5, y = y + 0.5}}
    g.revive = function()
      g.valid = false
      local w = soldier(nil, nil, x, y)
      w.name, w.type = g.ghost_name, 'wall'
      return {}, w
    end
    return g
  end

  local function enemy_unit(enemy, x, y, name, kind, health)
    local e = soldier(enemy, nil, x, y)
    e.name, e.type = name or 'small-biter', kind or 'unit'
    e.max_health, e.health = health or 100, health or 100
    return e
  end

  local function chunks_of(points)
    local ghosts = require('scripts.engineers.ghosts')
    local chunks, entries = {}, {}
    for id, p in ipairs(points) do
      local cx, cy = ghosts.chunk_of(p)
      local key = ghosts.key(cx, cy)
      chunks[key] = chunks[key] or {cx = cx, cy = cy, entries = {}, count = 0}
      local entry = {id = id, position = {x = p.x, y = p.y}, chunk = key}
      chunks[key].entries[id], chunks[key].count, entries[id] = entry, chunks[key].count + 1, entry
    end
    return chunks, entries
  end
  local function every() return true end

  local function nest_setup()
    local E = ctx.engineers
    local own, enemy, surface = E.engine()
    local spawner = E.enemy_unit(enemy, 100, 0, 'biter-spawner', 'unit-spawner', 350)
    local record = require('scripts.engineers.constructor').register(E.constructor_entity(40, 0))
    record.centre = {x = 90, y = 0}
    return own, enemy, surface, spawner, record
  end

  local function idle_division(n, count, x)
    local out = {}
    for i = 1, count do out[i] = soldier(nil, nil, (x or 60) + i, 0) end
    require('scripts.divisions').assign(1, n, out)
    return out
  end

  ctx.engineers = {engine = engine, constructor_entity = constructor_entity, ghost = ghost, enemy_unit = enemy_unit,
    all = all}

  test('engineers: the constructor stays out of every soldier list', function()
    assert(names.constructor == 'tank-squad-constructor')
    assert(names.constructor_recruit == 'tank-squad-recruit-constructor')
    assert(names.constructor_recipe == 'tank-squad-train-constructor')
    assert(not names.soldier_set[names.constructor] and not names.unit_set[names.constructor])
    assert(not names.recruit_set[names.constructor_recruit])
    assert(#names.recruit_names == 6 and names.unit_names[6] == names.headquarters, 'recruit indices moved')
  end)

  test('engineers: register once, count per force, unregister clears', function()
    engine()
    local constructor = require('scripts.engineers.constructor')
    local e = constructor_entity(5, 5)
    local record = constructor.register(e)
    assert(record and record.id == e.unit_number and record.state == 'seeking')
    assert(constructor.register(e) == record, 'second register made a new record')
    assert(constructor.register(soldier()) == nil, 'a soldier registered as a constructor')
    assert(constructor.count(1) == 1 and constructor.count(2) == 0)
    constructor.unregister(e.unit_number)
    assert(constructor.count(1) == 0)
  end)

  test('engineers: a moving constructor crushes the trees and rocks under its hull', function()
    engine()
    local constructor = require('scripts.engineers.constructor')
    local e = constructor_entity(0, 0)
    local record = constructor.register(e)
    local fallen = {}
    local function obstacle(x, y, kind, rock)
      local o = soldier(nil, nil, x, y)
      o.name, o.type, o.force = kind .. x, kind, 'neutral'
      o.prototype = {count_as_rock_for_filtered_deconstruction = rock}
      o.die = function(force, cause)
        assert(force == e.force and cause == e, 'crushed without the constructor as the cause')
        o.valid = false
        fallen[#fallen + 1] = o.name
      end
      return o
    end
    obstacle(1, 1, 'tree')
    obstacle(-1, 0, 'simple-entity', true)
    obstacle(1, -1, 'simple-entity', false)
    obstacle(4, 0, 'tree')
    assert(constructor.crush(record) == 2, 'crushed ' .. table.concat(fallen, ','))
    assert(constructor.crush(record) == 0, 'a standing constructor searched again')
    e.position = {x = 3, y = 0}
    assert(constructor.crush(record) == 1 and fallen[3] == 'tree4', 'the tree ahead still stands')
  end)

  test('engineers: a barracks deploys constructor recruits even with a full quota', function()
    local barracks = require('scripts.barracks')
    local divisions = require('scripts.divisions')
    local b, output = ctx.building()
    engine()
    assert(barracks.configure(b, 1, 2, 1))
    output['tank-squad-recruit-1'] = 1
    barracks.tick()
    assert(divisions.size(1, 2) == 1, 'soldier did not fill the quota')
    output[names.constructor_recruit] = 1
    barracks.tick()
    assert(output[names.constructor_recruit] == 0, 'constructor recruit stayed in the barracks')
    assert(require('scripts.engineers.constructor').count(1) == 1, 'no constructor deployed')
  end)

  test('engineers: nest score counts worms by size and spawners as two', function()
    local threat = require('scripts.engineers.threat')
    assert(threat.structure{name = 'small-worm-turret', type = 'turret'} == 1)
    assert(threat.structure{name = 'behemoth-worm-turret', type = 'turret'} == 8)
    assert(threat.structure{name = 'biter-spawner', type = 'unit-spawner'} == 2)
    assert(threat.structure{name = 'modded-worm', type = 'turret', max_health = 1000} == 4)
    assert(threat.structure{name = 'tiny-worm', type = 'turret', max_health = 10} == 1)
    local score = threat.nest{{name = 'medium-worm-turret', type = 'turret'},
      {name = 'spitter-spawner', type = 'unit-spawner'}}
    assert(score == 4 and threat.needed(score) == 6)
  end)

  test('engineers: soldier strength by kind and rank', function()
    local threat = require('scripts.engineers.threat')
    assert(threat.strength('tank-squad-soldier-1', 0) == 1)
    assert(threat.strength('tank-squad-siege', 2) == 2.25)
    assert(threat.strength('tank-squad-nuclear', 4) == 6)
    assert(threat.strength('tank-squad-flame', nil) == 1.5)
  end)

  test('engineers: pick takes the nearest until strong enough, else nothing', function()
    local threat = require('scripts.engineers.threat')
    local c = {{id = 1, strength = 1, d = 50}, {id = 2, strength = 3, d = 10}, {id = 3, strength = 1, d = 20},
      {id = 4, strength = 1, d = 20}}
    local picked, total = threat.pick(c, 4)
    assert(#picked == 2 and picked[1].id == 2 and picked[2].id == 3 and total == 4)
    assert(threat.pick(c, 7) == nil, 'picked while short')
    assert(threat.pick(c, 0) == nil, 'picked for no threat')
  end)

  test('engineers: a patrol keeps one soldier per 64 tiles, at least two', function()
    local threat = require('scripts.engineers.threat')
    assert(threat.patrol_keep(0) == 2 and threat.patrol_keep(128) == 2 and threat.patrol_keep(200) == 4)
    local soldiers = {{id = 1, strength = 3}, {id = 2, strength = 1}, {id = 3, strength = 1.5}, {id = 4, strength = 1}}
    local spare = threat.surplus(soldiers, 2)
    assert(#spare == 2 and spare[1].id == 2 and spare[2].id == 4, 'surplus is not the weakest')
    assert(#threat.surplus(soldiers, 4) == 0 and #threat.surplus(soldiers, 9) == 0)
  end)

  test('engineers: loans record, recall and finish', function()
    local loans = require('scripts.engineers.loans')
    assert(not loans.on_loan(7) and loans.finish(7) == nil)
    loans.lend(7, {task_force = 1, player_index = 1, n = 2, back = {x = 1, y = 2}})
    assert(loans.on_loan(7) and loans.get(7).n == 2)
    loans.recall({{valid = true, unit_number = 7}})
    assert(not loans.on_loan(7))
    loans.lend(8, {task_force = 1})
    assert(loans.finish(8).task_force == 1 and not loans.on_loan(8))
  end)

  test('engineers: nearest ghost across chunks', function()
    local ghosts = require('scripts.engineers.ghosts')
    local chunks = chunks_of{{x = 100, y = 100}, {x = 40, y = 0}, {x = 33, y = 0}, {x = -5, y = 0}}
    assert(ghosts.nearest(chunks, {x = 0, y = 0}, every).id == 4)
    assert(ghosts.nearest(chunks, {x = 36, y = 0}, every).id == 3)
    assert(ghosts.nearest(chunks, {x = 0, y = 0}, function(e) return e.id ~= 4 end).id == 3)
    assert(ghosts.nearest(chunks, {x = 0, y = 0}, function() return false end) == nil)
  end)

  test('engineers: a cluster is the seed and its nearest accepted neighbours', function()
    local ghosts = require('scripts.engineers.ghosts')
    local points = {}
    for x = 0, 10 do points[#points + 1] = {x = x, y = 0} end
    local chunks, entries = chunks_of(points)
    local c = ghosts.cluster(chunks, entries[1], 3, 9, every)
    assert(#c == 4 and c[1].id == 1 and c[2].id == 2 and c[4].id == 4)
    c = ghosts.cluster(chunks, entries[1], 3, 9, function(e) return e.id ~= 2 end)
    assert(#c == 3 and c[2].id == 3)
    local grid = {}
    for x = -2, 2 do for y = -2, 2 do grid[#grid + 1] = {x = x, y = y} end end
    chunks, entries = chunks_of(grid)
    assert(#ghosts.cluster(chunks, entries[13], 3, 9, every) == 9, 'cluster exceeded its maximum')
  end)

  test('engineers: ghosts register only on surfaces a constructor visited', function()
    local E = ctx.engineers
    local _, _, surface = E.engine()
    local ghosts = require('scripts.engineers.ghosts')
    local constructor = require('scripts.engineers.constructor')
    local first = E.ghost(1, 1)
    E.ghost(2, 2, 'iron-chest')
    ghosts.add(first)
    assert(storage.engineers == nil, 'a ghost created the engineers state')
    constructor.register(E.constructor_entity(0, 0))
    local bucket = ghosts.bucket(surface.index, 1)
    assert(bucket and bucket.count == 1, 'the first constructor did not read the surface')
    local second = E.ghost(3, 3, 'gate')
    ghosts.add(second)
    ghosts.add(second)
    assert(bucket.count == 2, 'a ghost counted twice')
  end)

  test('engineers: claim skips ghosts robots can reach', function()
    local E = ctx.engineers
    local _, _, surface = E.engine()
    local ghosts = require('scripts.engineers.ghosts')
    local constructor = require('scripts.engineers.constructor')
    local near, far = E.ghost(5, 0), E.ghost(20, 0)
    surface.networks = {{x = 5, y = 0, r = 4}}
    local record = constructor.register(E.constructor_entity(0, 0))
    local cluster = ghosts.claim(record, 3, 9)
    assert(cluster and #cluster == 1 and cluster[1].entity == far, 'took a ghost robots can reach')
    assert(storage.engineers.claims[far.unit_number] == record.id)
    ghosts.release(cluster)
    surface.networks = {}
    assert(ghosts.claim(record, 3, 9)[1].entity == far, 'asked about coverage again before a minute passed')
    ghosts.release({{id = far.unit_number}})
    game.tick = game.tick + ghosts.RECHECK + 1
    assert(ghosts.claim(record, 3, 9)[1].entity == near, 'never asked about coverage again')
  end)

  test('engineers: claimed and blocked ghosts go to nobody else', function()
    local E = ctx.engineers
    E.engine()
    local ghosts = require('scripts.engineers.ghosts')
    local constructor = require('scripts.engineers.constructor')
    local g1, g2 = E.ghost(2, 0), E.ghost(30, 0)
    local a = constructor.register(E.constructor_entity(0, 0))
    local b = constructor.register(E.constructor_entity(0, 1))
    local c1 = ghosts.claim(a, 3, 9)
    assert(c1[1].entity == g1 and ghosts.claim(b, 3, 9)[1].entity == g2)
    ghosts.block(c1, 600)
    assert(ghosts.claim(a, 3, 9) == nil, 'took a blocked or claimed ghost')
    game.tick = game.tick + 601
    assert(ghosts.claim(a, 3, 9)[1].entity == g1, 'block never expired')
  end)

  test('engineers: a vanished ghost leaves the registry and its chunk', function()
    local E = ctx.engineers
    local _, _, surface = E.engine()
    local ghosts = require('scripts.engineers.ghosts')
    local record = require('scripts.engineers.constructor').register(E.constructor_entity(0, 0))
    local g = E.ghost(4, 4)
    ghosts.add(g)
    g.valid = false
    assert(ghosts.claim(record, 3, 9) == nil)
    local bucket = ghosts.bucket(surface.index, 1)
    assert(bucket.count == 0 and next(bucket.chunks) == nil, 'empty chunk kept')
  end)

  test('engineers: build and death events feed the registry', function()
    local E = ctx.engineers
    E.engine()
    dofile('control.lua')
    local handlers = ctx.handlers()
    handlers[defines.events.on_built_entity]{entity = E.constructor_entity(0, 0)}
    local g = E.ghost(6, 0)
    handlers[defines.events.on_built_entity]{entity = g}
    local wall = E.ghost(9, 0)
    handlers[defines.events.on_post_entity_died]{ghost = wall}
    local ghosts = require('scripts.engineers.ghosts')
    assert(ghosts.bucket(1, 1).count == 2, 'events did not register the ghosts')
  end)

  test('engineers: the crane faces its cluster and keeps its base on the hull', function()
    local crane = require('scripts.engineers.crane')
    assert(math.abs(crane.orientation({x = 0, y = 0}, {x = 0, y = -5})) < 1e-9)
    assert(math.abs(crane.orientation({x = 0, y = 0}, {x = 5, y = 0}) - 0.25) < 1e-9)
    local look = require('scripts.appearance').constructor
    local d = look.crane_base * look.crane_scale / 32
    local east = crane.offset(0.25)
    assert(math.abs(east.x - d) < 1e-9 and math.abs(east.y) < 1e-9)
  end)

  test('engineers: a crane cycle draws once and lasts a second', function()
    local E = ctx.engineers
    E.engine()
    local crane = require('scripts.engineers.crane')
    local record = require('scripts.engineers.constructor').register(E.constructor_entity(0, 0))
    record.centre = {x = 0, y = -6}
    game.tick = 120
    crane.start(record)
    local draws = ctx.draws()
    local draw = draws[#draws]
    assert(draw.type == 'animation' and draw.args.animation == 'tank-squad-constructor-crane')
    assert(draw.args.time_to_live == 60 and record.release_tick == 150 and record.done_tick == 180)
    assert(math.abs(draw.args.animation_offset + 120 * draw.args.animation_speed) < 1e-9, 'cycle does not start on frame 1')
    crane.stop(record)
    assert(not draw.valid and record.crane == nil)
  end)

  test('engineers: a ghost that vanished is dropped, the rest is built', function()
    local E = ctx.engineers
    local _, _, surface = E.engine()
    local ghosts = require('scripts.engineers.ghosts')
    local crane = require('scripts.engineers.crane')
    local record = require('scripts.engineers.constructor').register(E.constructor_entity(0, 0))
    local a, b, c = E.ghost(10, 0), E.ghost(11, 0), E.ghost(12, 0)
    for _, g in ipairs({a, b, c}) do ghosts.add(g) end
    record.cluster = ghosts.claim(record, 3, 9)
    assert(#record.cluster == 3)
    b.valid = false
    local tree = soldier(nil, nil, 12, 0)
    tree.name, tree.type = 'tree-01', 'tree'
    tree.destroy = function() tree.valid = false end
    assert(crane.place(record) == 2, 'did not build the two remaining walls')
    assert(not a.valid and not c.valid and not tree.valid, 'tree on the ghost was not cleared')
    assert(ghosts.bucket(surface.index, 1).count == 0 and #record.cluster == 0)
  end)

  test('engineers: a ghost under a unit waits three cycles, then is let go', function()
    local E = ctx.engineers
    E.engine()
    local ghosts = require('scripts.engineers.ghosts')
    local crane = require('scripts.engineers.crane')
    local record = require('scripts.engineers.constructor').register(E.constructor_entity(0, 0))
    local g = E.ghost(10, 0)
    ghosts.add(g)
    record.cluster = ghosts.claim(record, 3, 9)
    local blocker = soldier(nil, nil, 10, 0)
    blocker.type = 'unit'
    for _ = 1, crane.RETRIES do
      assert(crane.place(record) == 0 and #record.cluster == 1, 'gave up too early')
    end
    assert(crane.place(record) == 0 and #record.cluster == 0, 'never gave up')
    assert(storage.engineers.claims[g.unit_number] == nil and g.valid)
  end)

  test('engineers: a ghost that cannot be revived is blocked for five minutes', function()
    local E = ctx.engineers
    E.engine()
    local ghosts = require('scripts.engineers.ghosts')
    local crane = require('scripts.engineers.crane')
    local record = require('scripts.engineers.constructor').register(E.constructor_entity(0, 0))
    local g = E.ghost(10, 0)
    ghosts.add(g)
    g.revive = function() return nil end
    record.cluster = ghosts.claim(record, 3, 9)
    assert(crane.place(record) == 0 and #record.cluster == 0)
    assert(storage.engineers.blocked[g.unit_number] == game.tick + ghosts.BLOCK)
  end)

  test('engineers: the split deals strongest first and caps each team', function()
    local teams = require('scripts.engineers.teams')
    local soldiers = {{id = 1, strength = 3}, {id = 2, strength = 3}, {id = 3, strength = 1.5},
      {id = 4, strength = 1}, {id = 5, strength = 1}}
    local split = teams.split(soldiers, {10, 20}, 8)
    assert(#split[10] == 3 and #split[20] == 2)
    assert(split[10][1] == 1 and split[20][1] == 2 and split[10][2] == 3, 'not dealt strongest first')
    local many = {}
    for i = 1, 20 do many[i] = {id = i, strength = 1} end
    split = teams.split(many, {10, 20}, 8)
    assert(#split[10] == 8 and #split[20] == 8, 'cap ignored')
    split = teams.split({{id = 1, strength = 1}}, {10, 20, 30}, 8)
    assert(#split[10] + #split[20] + #split[30] == 1)
    assert(next(teams.split(soldiers, {}, 8)) == nil)
  end)

  test('engineers: the split gives every team a mix of strong and weak', function()
    local teams = require('scripts.engineers.teams')
    local soldiers = {{id = 1, strength = 3}, {id = 2, strength = 3}, {id = 3, strength = 3},
      {id = 4, strength = 1}, {id = 5, strength = 1}, {id = 6, strength = 1}}
    local split = teams.split(soldiers, {10, 20}, 8)
    local strength = {}
    for _, x in ipairs(soldiers) do strength[x.id] = x.strength end
    for _, c in ipairs({10, 20}) do
      local strong, weak = 0, 0
      for _, id in ipairs(split[c]) do
        if strength[id] == 3 then strong = strong + 1 else weak = weak + 1 end
      end
      assert(#split[c] == 3 and strong > 0 and weak > 0, 'a team got only strong or only weak soldiers')
    end
  end)

  test('engineers: a strong newcomer takes the place of the weakest in full teams', function()
    local teams = require('scripts.engineers.teams')
    local soldiers = {}
    for i = 1, 16 do soldiers[i] = {id = i, strength = 1} end
    soldiers[17] = {id = 17, strength = 3}
    local split = teams.split(soldiers, {10, 20}, 8)
    local dealt = {}
    for _, c in ipairs({10, 20}) do
      assert(#split[c] == 8)
      for _, id in ipairs(split[c]) do dealt[id] = true end
    end
    assert(dealt[17], 'the strong newcomer was left out')
    assert(not dealt[16], 'the weakest soldier kept its place')
  end)

  test('engineers: marking a division puts it in the pool until another order', function()
    local E = ctx.engineers
    E.engine()
    local divisions = require('scripts.divisions')
    local teams = require('scripts.engineers.teams')
    local commands = require('scripts.commands')
    local a, b = soldier(), soldier()
    divisions.assign(1, 2, {a, b})
    assert(teams.set_pool(1, 2, true))
    local record = divisions.record(1, 2)
    assert(record.mode == 'engineer' and a.command.type == defines.command.stop)
    assert(not teams.set_pool(1, 5, true), 'an empty division joined the pool')
    commands.order(1, {left_top = {x = 10, y = 10}, right_bottom = {x = 12, y = 12}}, game.surfaces[1])
    assert(record.mode == 'idle', 'an order left the division in the pool')
  end)

  test('engineers: a drag order takes soldiers out of the pool', function()
    local E = ctx.engineers
    E.engine()
    local divisions = require('scripts.divisions')
    local a, b = soldier(), soldier()
    divisions.assign(1, 2, {a, b})
    require('scripts.engineers.teams').set_pool(1, 2, true)
    divisions.select_area(1, {a})
    divisions.release_for_order(1, {a})
    assert(divisions.size(1, 2) == 1, 'the pool division kept a soldier the player ordered')
  end)

  test('engineers: pool soldiers split into teams that ring their constructors', function()
    local E = ctx.engineers
    E.engine()
    local divisions = require('scripts.divisions')
    local teams = require('scripts.engineers.teams')
    local constructor = require('scripts.engineers.constructor')
    local soldiers = {}
    for i = 1, 5 do soldiers[i] = soldier(nil, nil, i, 0) end
    divisions.assign(1, 3, soldiers)
    teams.set_pool(1, 3, true)
    local c1 = constructor.register(E.constructor_entity(40, 0))
    local c2 = constructor.register(E.constructor_entity(-40, 0))
    teams.refresh()
    local s = storage.engineers
    assert(#s.teams[c1.id].members == 3 and #s.teams[c2.id].members == 2)
    for _, e in ipairs(soldiers) do assert(s.team_of[e.unit_number], 'a pool soldier has no team') end
    teams.tick()
    assert(teams.present(c1.id) == 3 and teams.present(c2.id) == 2)
    assert(teams.on_command_completed(soldiers[1].unit_number, defines.behavior_result.success))
    assert(not teams.on_command_completed(c1.id, defines.behavior_result.success))
    constructor.unregister(c2.id)
    teams.refresh()
    assert(s.teams[c2.id] == nil and #s.teams[c1.id].members == 5, 'soldiers of a gone constructor not dealt again')
  end)

  test('engineers: each constructor gets the pool soldiers on its own surface', function()
    local E = ctx.engineers
    local own = E.engine()
    local divisions = require('scripts.divisions')
    local teams = require('scripts.engineers.teams')
    local constructor = require('scripts.engineers.constructor')
    local function none() return {} end
    local other = {index = 2, find_entities_filtered = none, find_units = none}
    game.surfaces[2] = other
    local here = {soldier(nil, nil, 1, 0), soldier(nil, nil, 2, 0)}
    local there = {soldier(nil, other, 1, 0), soldier(nil, other, 2, 0)}
    divisions.assign(1, 3, {here[1], here[2], there[1], there[2]})
    teams.set_pool(1, 3, true)
    local c1 = constructor.register(E.constructor_entity(40, 0))
    local hull = soldier(own, other, 40, 0)
    hull.name, hull.type = names.constructor, 'unit'
    local c2 = constructor.register(hull)
    teams.refresh()
    local s = storage.engineers
    for _, e in ipairs(here) do assert(s.team_of[e.unit_number] == c1.id, 'a soldier went to a constructor elsewhere') end
    for _, e in ipairs(there) do assert(s.team_of[e.unit_number] == c2.id, 'a soldier went to a constructor elsewhere') end
    teams.tick()
    assert(teams.present(c1.id) == 2 and teams.present(c2.id) == 2)
  end)

  test('engineers: a patrol gives no post to a soldier on loan', function()
    local E = ctx.engineers
    E.engine()
    local divisions = require('scripts.divisions')
    local patrol = require('scripts.patrol')
    local loans = require('scripts.engineers.loans')
    local a, b, c = soldier(nil, nil, 0, 0), soldier(nil, nil, 5, 0), soldier(nil, nil, 10, 0)
    divisions.assign(1, 4, {a, b, c})
    patrol.add_waypoint(1, 4, {x = 0, y = 0}, game.surfaces[1])
    patrol.add_waypoint(1, 4, {x = 100, y = 0}, game.surfaces[1])
    patrol.start(1, 4)
    local r = divisions.record(1, 4).patrol
    assert(r.posts[c.unit_number])
    loans.lend(c.unit_number, {task_force = 1, player_index = 1, n = 4})
    r.dirty = true
    patrol.tick()
    assert(r.posts[c.unit_number] == nil and r.posts[a.unit_number], 'a loaned soldier kept its post')
    loans.finish(c.unit_number)
    r.dirty = true
    patrol.tick()
    assert(r.posts[c.unit_number], 'a returned soldier got no post')
  end)

  test('engineers: an order to lent soldiers takes them back', function()
    local E = ctx.engineers
    E.engine()
    local divisions = require('scripts.divisions')
    local loans = require('scripts.engineers.loans')
    local a = soldier()
    divisions.assign(1, 2, {a})
    loans.lend(a.unit_number, {task_force = 9})
    require('scripts.commands').order(1, {left_top = {x = 10, y = 10}, right_bottom = {x = 12, y = 12}},
      game.surfaces[1])
    assert(not loans.on_loan(a.unit_number))
  end)
  test('engineers: the split leaves soldiers the player ordered alone', function()
    local E = ctx.engineers
    E.engine()
    local divisions = require('scripts.divisions')
    local teams = require('scripts.engineers.teams')
    local a, b = soldier(nil, nil, 0, 0), soldier(nil, nil, 2, 0)
    divisions.assign(1, 3, {a, b})
    teams.set_pool(1, 3, true)
    local c = require('scripts.engineers.constructor').register(E.constructor_entity(40, 0))
    teams.refresh()
    assert(#storage.engineers.teams[c.id].members == 2)
    require('scripts.commands').order(1, {left_top = {x = 10, y = 10}, right_bottom = {x = 12, y = 12}},
      game.surfaces[1])
    local ordered = a.command
    teams.refresh()
    assert(#storage.engineers.teams[c.id].members == 0 and not storage.engineers.team_of[a.unit_number])
    assert(a.command == ordered, 'the split halted a soldier the player ordered')
  end)
  test('engineers: a team lets go of soldiers the player ordered before the next split', function()
    local E = ctx.engineers
    E.engine()
    local divisions = require('scripts.divisions')
    local teams = require('scripts.engineers.teams')
    local a, b = soldier(nil, nil, 0, 0), soldier(nil, nil, 2, 0)
    divisions.assign(1, 3, {a, b})
    teams.set_pool(1, 3, true)
    local c = require('scripts.engineers.constructor').register(E.constructor_entity(4, 0))
    teams.refresh()
    for _ = 1, 6 do teams.tick() end
    assert(storage.engineers.teams[c.id].state.anchor, 'the team never settled on its constructor')
    require('scripts.commands').order(1, {left_top = {x = 10, y = 10}, right_bottom = {x = 12, y = 12}},
      game.surfaces[1])
    local ordered_a, ordered_b = a.command, b.command
    storage.engineers.teams[c.id].state.members_dirty = true
    teams.tick()
    assert(a.command == ordered_a and b.command == ordered_b, 'the team re-commanded a soldier the player ordered')
    assert(teams.present(c.id) == 0)
    assert(not teams.on_command_completed(a.unit_number, defines.behavior_result.success),
      'the team swallowed the completion of an order')
  end)

  test('engineers: lenders are idle divisions, patrol surplus and soldiers in no division', function()
    local _, _, surface, spawner = nest_setup()
    local divisions = require('scripts.divisions')
    local patrol = require('scripts.patrol')
    local task_force = require('scripts.engineers.task_force')
    local idle = idle_division(1, 2)
    local walkers = {}
    for i = 1, 4 do walkers[i] = soldier(nil, nil, 50 + i, 5) end
    divisions.assign(1, 2, walkers)
    patrol.add_waypoint(1, 2, {x = 50, y = 5}, surface)
    patrol.add_waypoint(1, 2, {x = 100, y = 5}, surface)
    patrol.start(1, 2)
    local escorting = idle_division(3, 1, 70)
    divisions.record(1, 3).mode = 'escort'
    local pooled = idle_division(4, 1, 75)
    require('scripts.engineers.teams').set_pool(1, 4, true)
    local loose, far = soldier(nil, nil, 80, 0), soldier(nil, nil, 500, 0)
    local found = {}
    for _, c in ipairs(task_force.candidates(1, surface, spawner.position)) do found[c.id] = c end
    assert(found[idle[1].unit_number] and found[idle[2].unit_number], 'an idle division did not lend')
    local lent = 0
    for _, w in ipairs(walkers) do if found[w.unit_number] then lent = lent + 1 end end
    assert(lent == 2, 'a 50-tile patrol of 4 lent ' .. lent)
    assert(not found[escorting[1].unit_number] and not found[pooled[1].unit_number], 'a busy division lent')
    assert(found[loose.unit_number] and found[loose.unit_number].player_index == nil)
    assert(not found[far.unit_number], 'a soldier beyond reach lent')
  end)

  test('engineers: a division attacking lends nothing, one parked after a move does', function()
    local _, _, surface, spawner = nest_setup()
    local divisions = require('scripts.divisions')
    local task_force = require('scripts.engineers.task_force')
    local attacking = idle_division(1, 2)
    divisions.record(1, 1).order = {surface_index = 1, command = {type = defines.command.attack_area}}
    local parked = idle_division(2, 2, 70)
    divisions.record(1, 2).order = {surface_index = 1, command = {type = defines.command.go_to_location}}
    local found = {}
    for _, c in ipairs(task_force.candidates(1, surface, spawner.position)) do found[c.id] = c end
    assert(not found[attacking[1].unit_number] and not found[attacking[2].unit_number], 'an attacking division lent')
    assert(found[parked[1].unit_number] and found[parked[2].unit_number], 'a division parked after a move did not lend')
  end)

  test('engineers: a task force borrows enough soldiers and attacks the nest', function()
    local _, _, _, spawner, record = nest_setup()
    local loans = require('scripts.engineers.loans')
    local task_force = require('scripts.engineers.task_force')
    local idle = idle_division(1, 4)
    local tf = task_force.request(record, {spawner})
    assert(tf and #tf.members == 3, 'needed strength 3 from three carriers')
    assert(not loans.on_loan(idle[1].unit_number), 'lent the farthest soldier')
    for i = 2, 4 do assert(loans.on_loan(idle[i].unit_number)) end
    assert(tf.assault, 'no nest assault started')
    assert(ctx.players()[1].printed[1], 'lenders were not told')
    assert(task_force.near(1, {x = 110, y = 0}) == tf and task_force.near(1, {x = 300, y = 0}) == nil)
  end)

  test('engineers: nothing is borrowed when the nest is too strong', function()
    local _, enemy, _, spawner, record = nest_setup()
    local task_force = require('scripts.engineers.task_force')
    local worm = ctx.engineers.enemy_unit(enemy, 104, 0, 'behemoth-worm-turret', 'turret', 3000)
    idle_division(1, 1)
    assert(task_force.request(record, {spawner, worm}) == nil)
    assert(storage.engineer_loans == nil or next(storage.engineer_loans) == nil, 'borrowed while short')
  end)

  test('engineers: a cleared nest sends every soldier back', function()
    local _, _, _, spawner, record = nest_setup()
    local loans = require('scripts.engineers.loans')
    local task_force = require('scripts.engineers.task_force')
    local idle = idle_division(1, 4)
    local back = {x = idle[3].position.x, y = idle[3].position.y}
    local tf = task_force.request(record, {spawner})
    record.task_force = tf.id
    spawner.valid = false
    task_force.drive(tf)
    assert(storage.engineers.task_forces[tf.id] == nil and record.task_force_result == 'cleared')
    assert(not loans.on_loan(idle[3].unit_number))
    local command = idle[3].command
    assert(command.type == defines.command.go_to_location and command.destination.x == back.x, 'not sent back')
  end)

  test('engineers: a patrol lender deals its posts when soldiers leave and return', function()
    local _, _, surface, spawner, record = nest_setup()
    local divisions = require('scripts.divisions')
    local patrol = require('scripts.patrol')
    local task_force = require('scripts.engineers.task_force')
    local walkers = {}
    for i = 1, 6 do walkers[i] = soldier(nil, nil, 50 + i, 5) end
    divisions.assign(1, 2, walkers)
    patrol.add_waypoint(1, 2, {x = 50, y = 5}, surface)
    patrol.add_waypoint(1, 2, {x = 100, y = 5}, surface)
    patrol.start(1, 2)
    local r = divisions.record(1, 2).patrol
    local tf = task_force.request(record, {spawner})
    assert(tf and r.dirty, 'the patrol kept posts for lent soldiers')
    r.dirty = nil
    spawner.valid = false
    task_force.drive(tf)
    assert(r.dirty, 'the patrol did not take its soldiers back')
  end)

  test('engineers: a new order on a lender recalls its soldiers', function()
    local _, _, _, spawner, record = nest_setup()
    local divisions = require('scripts.divisions')
    local loans = require('scripts.engineers.loans')
    local task_force = require('scripts.engineers.task_force')
    local idle = idle_division(1, 4)
    local tf = task_force.request(record, {spawner})
    local before = idle[2].command
    divisions.record(1, 1).order = {surface_index = 1, command = {type = defines.command.go_to_location}}
    task_force.drive(tf)
    for i = 2, 4 do assert(not loans.on_loan(idle[i].unit_number), 'a recalled soldier stayed on loan') end
    assert(idle[2].command == before, 'a recalled soldier was sent home')
    assert(storage.engineers.task_forces[tf.id] == nil, 'an empty task force kept running')
  end)

  test('engineers: a task force outlives its constructor', function()
    local _, _, _, spawner, record = nest_setup()
    local loans = require('scripts.engineers.loans')
    local task_force = require('scripts.engineers.task_force')
    local idle = idle_division(1, 4)
    local tf = task_force.request(record, {spawner})
    record.task_force = tf.id
    require('scripts.engineers.constructor').unregister(record.id)
    spawner.valid = false
    task_force.tick()
    assert(storage.engineers.task_forces[tf.id] == nil)
    for i = 2, 4 do
      assert(not loans.on_loan(idle[i].unit_number) and idle[i].command.type == defines.command.go_to_location)
    end
  end)

  test('engineers: a lent patrol soldier hit at the nest calls no patrol help', function()
    local _, _, surface, spawner, record = nest_setup()
    local divisions = require('scripts.divisions')
    local patrol = require('scripts.patrol')
    local loans = require('scripts.engineers.loans')
    local task_force = require('scripts.engineers.task_force')
    local walkers = {}
    for i = 1, 6 do walkers[i] = soldier(nil, nil, 50 + i, 5) end
    divisions.assign(1, 2, walkers)
    patrol.add_waypoint(1, 2, {x = 50, y = 5}, surface)
    patrol.add_waypoint(1, 2, {x = 100, y = 5}, surface)
    patrol.start(1, 2)
    assert(task_force.request(record, {spawner}))
    local lent, kept = nil, {}
    for _, w in ipairs(walkers) do
      if loans.on_loan(w.unit_number) then lent = lent or w else kept[#kept + 1] = {w, w.command} end
    end
    assert(lent and #kept > 0)
    patrol.on_damaged{entity = lent, cause = spawner}
    local r = divisions.record(1, 2).patrol
    assert(not (r.responders and next(r.responders)), 'a lent soldier raised the patrol alarm')
    for _, k in ipairs(kept) do assert(k[1].command == k[2], 'a kept patrol soldier left for the nest') end
  end)

  test('engineers: soldiers of a deleted division fight on, then return to their back point', function()
    local _, _, _, spawner, record = nest_setup()
    local loans = require('scripts.engineers.loans')
    local task_force = require('scripts.engineers.task_force')
    local idle = idle_division(1, 4)
    local back = {x = idle[3].position.x, y = idle[3].position.y}
    local tf = task_force.request(record, {spawner})
    storage.divisions[1] = nil
    task_force.drive(tf)
    assert(storage.engineers.task_forces[tf.id] and loans.on_loan(idle[3].unit_number),
      'soldiers of a deleted division were let go at the nest')
    spawner.valid = false
    task_force.drive(tf)
    assert(storage.engineers.task_forces[tf.id] == nil and not loans.on_loan(idle[3].unit_number))
    local command = idle[3].command
    assert(command.type == defines.command.go_to_location and command.destination.x == back.x
      and command.destination.y == back.y, 'not sent to its back point')
  end)

  test('engineers: heavy losses call the shredders of the lenders', function()
    local _, _, _, spawner, record = nest_setup()
    local task_force = require('scripts.engineers.task_force')
    local shredders = require('scripts.shredders')
    local idle = idle_division(1, 4)
    task_force.request(record, {spawner})
    local calls, old = {}, shredders.call
    shredders.call = function(p, n) calls[#calls + 1] = {p, n}; return 0, nil end
    task_force.on_soldier_died(idle[4])
    local early = #calls
    task_force.on_soldier_died(idle[3])
    shredders.call = old
    assert(early == 0, 'called after one loss of three')
    assert(#calls == 1 and calls[1][1] == 1 and calls[1][2] == 1, 'did not call division 1')
  end)

  local function working(x, y)
    local E = ctx.engineers
    local record = require('scripts.engineers.constructor').register(E.constructor_entity(x or 0, y or 0))
    storage.engineers.min_team = 0
    return record
  end

  local function add_ghost(x, y)
    local g = ctx.engineers.ghost(x, y)
    require('scripts.engineers.ghosts').add(g)
    return g
  end

  test('engineers: the standing spot lies beside the cluster, toward the constructor', function()
    local constructor = require('scripts.engineers.constructor')
    local spot = constructor.spot({x = 20.5, y = 0}, {x = 0, y = 0}, {{x = 20, y = 0}, {x = 21, y = 0}})
    assert(math.abs(spot.x - 17.5) < 1e-9 and spot.y == 0)
    spot = constructor.spot({x = 0, y = 0}, {x = 0, y = 0}, {{x = 0, y = 0}})
    assert(spot.x == 0 and math.abs(spot.y - 2.5) < 1e-9, 'no fallback direction')
  end)

  test('engineers: without an escort a constructor waits at the barracks', function()
    local E = ctx.engineers
    ctx.building()
    E.engine()
    local constructor = require('scripts.engineers.constructor')
    local record = constructor.register(E.constructor_entity(30, 0))
    add_ghost(50, 0)
    constructor.tick()
    assert(record.state == 'waiting' and record.entity.command.destination.x == 0, 'did not head home')
    local flying = ctx.players()[1].flying
    assert(flying[1] and flying[1].text[1] == 'tank-squads.constructor-waiting', 'no waiting message')
  end)

  test('engineers: a constructor walks beside its cluster and builds it', function()
    ctx.engineers.engine()
    local constructor = require('scripts.engineers.constructor')
    local record = working()
    local a, b = add_ghost(20, 0), add_ghost(21, 0)
    constructor.tick()
    assert(record.state == 'moving' and #record.cluster == 2)
    local d = record.entity.command.destination
    assert(math.abs(d.x - 17.5) < 1e-9 and d.y == 0, 'stood at ' .. d.x)
    constructor.on_command_completed(record.id, defines.behavior_result.success)
    assert(record.state == 'building' and record.crane)
    game.tick = record.release_tick
    constructor.tick(99)
    assert(not a.valid and not b.valid, 'walls not placed on the release frame')
    game.tick = record.done_tick
    constructor.tick(99)
    assert(record.state == 'idle', 'did not look for more work')
  end)

  test('engineers: a cluster it cannot reach is blocked for five minutes', function()
    ctx.engineers.engine()
    local constructor = require('scripts.engineers.constructor')
    local ghosts = require('scripts.engineers.ghosts')
    local record = working()
    local g = add_ghost(20, 0)
    constructor.tick()
    constructor.on_command_completed(record.id, defines.behavior_result.fail)
    assert(record.state == 'moving', 'gave up after one failed path')
    constructor.on_command_completed(record.id, defines.behavior_result.fail)
    assert(record.state == 'seeking' and storage.engineers.blocked[g.unit_number] == game.tick + ghosts.BLOCK)
  end)

  test('engineers: enemies within 80 tiles pause the work until 5 calm seconds', function()
    local E = ctx.engineers
    local _, enemy = E.engine()
    local constructor = require('scripts.engineers.constructor')
    local record = working()
    add_ghost(20, 0)
    local biter = E.enemy_unit(enemy, 60, 0)
    constructor.tick()
    assert(record.state == 'paused')
    biter.valid = false
    constructor.tick()
    assert(record.state == 'paused', 'resumed at once')
    game.tick = game.tick + constructor.CALM
    constructor.tick()
    assert(record.state == 'moving', 'never resumed')
  end)

  test('engineers: a hurt constructor heals at a barracks, then works again', function()
    local b = ctx.building()
    ctx.engineers.engine()
    b.position = {x = -50, y = 0}
    local constructor = require('scripts.engineers.constructor')
    local record = working()
    record.entity.health = 100
    constructor.tick()
    assert(record.state == 'healing' and record.entity.command.destination.x == -50)
    record.entity.health = 800
    constructor.tick()
    assert(record.state == 'idle', 'still healing at full health')
  end)

  test('engineers: a nest by the ghosts calls a task force, then work goes on', function()
    local E = ctx.engineers
    local _, enemy = E.engine()
    local constructor = require('scripts.engineers.constructor')
    local task_force = require('scripts.engineers.task_force')
    local record = working()
    add_ghost(50, 0)
    local spawner = E.enemy_unit(enemy, 70, 0, 'biter-spawner', 'unit-spawner', 350)
    require('scripts.divisions').assign(1, 1, {soldier(nil, nil, 10, 0), soldier(nil, nil, 11, 0),
      soldier(nil, nil, 12, 0)})
    constructor.tick()
    assert(record.state == 'task_force' and record.task_force, 'no task force called')
    spawner.valid = false
    task_force.tick()
    constructor.tick()
    assert(record.state == 'moving', 'did not return to the cluster')
  end)

  test('engineers: a nest too strong blocks its ghosts', function()
    local E = ctx.engineers
    local _, enemy = E.engine()
    local constructor = require('scripts.engineers.constructor')
    local record = working()
    local g = add_ghost(50, 0)
    E.enemy_unit(enemy, 70, 0, 'biter-spawner', 'unit-spawner', 350)
    constructor.tick()
    assert(storage.engineers.blocked[g.unit_number], 'ghosts by a nest stayed open')
    assert(record.state ~= 'task_force')
    local flying = ctx.players()[1].flying
    assert(flying[#flying].text[1] == 'tank-squads.constructor-too-strong')
  end)

  test('engineers: a nest too strong blocks every ghost within its reach at once', function()
    local E = ctx.engineers
    local _, enemy = E.engine()
    local constructor = require('scripts.engineers.constructor')
    local record = working()
    local near, beside = add_ghost(50, 0), add_ghost(60, 20)
    local far = add_ghost(100, 60)
    E.enemy_unit(enemy, 70, 0, 'biter-spawner', 'unit-spawner', 350)
    constructor.tick()
    local blocked = storage.engineers.blocked
    assert(blocked[near.unit_number] and blocked[beside.unit_number], 'a ghost by the nest stayed open')
    assert(not blocked[far.unit_number], 'a ghost out of the nest reach was blocked')
    constructor.tick()
    assert(record.state == 'moving' and record.cluster[1].entity == far, 'the next seek did not go to the free ghost')
  end)

  test('engineers: entry points tolerate a save without engineers', function()
    local E = ctx.engineers
    E.engine()
    local engineers = require('scripts.engineers.init')
    engineers.tick(0)
    engineers.tick()
    assert(engineers.on_command_completed(12345, defines.behavior_result.success) == false)
    engineers.forget_soldier(soldier())
    engineers.on_ghost(E.ghost(1, 1))
    engineers.on_post_died({})
    assert(engineers.describe(1) == nil)
    assert(storage.engineers == nil, 'an entry point created the engineers state')
  end)

  test('engineers: the last constructor gone lets its team go', function()
    local E = ctx.engineers
    E.engine()
    local engineers = require('scripts.engineers.init')
    local s1 = soldier(nil, nil, 1, 0)
    require('scripts.divisions').assign(1, 3, {s1})
    engineers.set_pool(1, 3, true)
    local record = engineers.register(E.constructor_entity(10, 0))
    engineers.tick(0)
    assert(storage.engineers.team_of[s1.unit_number] == record.id)
    engineers.unregister(record.id)
    assert(storage.engineers.team_of[s1.unit_number] == nil and next(storage.engineers.teams) == nil)
  end)

  test('engineers: an idle constructor seeks again only for a new ghost or after a minute', function()
    ctx.engineers.engine()
    local constructor = require('scripts.engineers.constructor')
    local ghosts = require('scripts.engineers.ghosts')
    local record = working()
    constructor.tick()
    assert(record.state == 'idle')
    local idle_since = game.tick
    local claims, claim = 0, ghosts.claim
    ghosts.claim = function(...) claims = claims + 1; return claim(...) end
    local ok, err = pcall(function()
      while game.tick + 60 < idle_since + ghosts.RECHECK do
        game.tick = game.tick + 60
        constructor.tick()
      end
      assert(claims == 0, 'searched ' .. claims .. ' times with no new ghost')
      game.tick = idle_since + ghosts.RECHECK
      constructor.tick()
      assert(claims == 1 and record.state == 'idle', 'no search after a minute')
      game.tick = game.tick + 60
      constructor.tick()
      assert(claims == 1, 'searched again right after the minute')
      add_ghost(20, 0)
      game.tick = game.tick + 60
      constructor.tick()
      assert(claims == 2 and record.state == 'moving', 'a new ghost did not wake it')
    end)
    ghosts.claim = claim
    assert(ok, err)
  end)

  test('engineers: building at once lets go of ghosts kept under a unit', function()
    ctx.engineers.engine()
    local constructor = require('scripts.engineers.constructor')
    local record = working()
    local free, covered = add_ghost(20, 0), add_ghost(21, 0)
    local blocker = soldier(nil, nil, 21, 0)
    blocker.type = 'unit'
    assert(constructor.build_now(record) == 1 and not free.valid and covered.valid)
    assert(next(storage.engineers.claims) == nil, 'a ghost under a unit stayed claimed')
    assert(record.cluster == nil and record.state == 'seeking')
  end)

  test('engineers: a constructor that vanished without an event lets its team go', function()
    local E = ctx.engineers
    E.engine()
    local engineers = require('scripts.engineers.init')
    local s1 = soldier(nil, nil, 1, 0)
    require('scripts.divisions').assign(1, 3, {s1})
    engineers.set_pool(1, 3, true)
    local record = engineers.register(E.constructor_entity(10, 0))
    engineers.tick(0)
    assert(storage.engineers.team_of[s1.unit_number] == record.id)
    record.entity.valid = false
    require('scripts.engineers.constructor').tick()
    assert(storage.engineers.constructors[record.id] == nil)
    engineers.tick(0)
    assert(storage.engineers.team_of[s1.unit_number] == nil and next(storage.engineers.teams) == nil,
      'the team outlived its constructor')
  end)

  test('engineers: a constructor whose barracks is gone stops healing and works on', function()
    local b = ctx.building()
    ctx.engineers.engine()
    b.position = {x = -50, y = 0}
    local constructor = require('scripts.engineers.constructor')
    local record = working()
    record.entity.health = 100
    constructor.tick()
    assert(record.state == 'healing')
    b.valid = false
    game.tick = game.tick + 60
    constructor.tick()
    assert(record.state == 'idle', 'healed forever without a barracks: ' .. record.state)
    game.tick = game.tick + 60
    constructor.tick()
    assert(record.state == 'idle', 'went back to healing without a barracks')
  end)

  test('engineers: a healing constructor stuck away from its barracks is sent again', function()
    local b = ctx.building()
    ctx.engineers.engine()
    b.position = {x = -50, y = 0}
    local constructor = require('scripts.engineers.constructor')
    local record = working()
    record.entity.health = 100
    constructor.tick()
    local started = game.tick
    record.entity.command = nil
    game.tick = started + 60
    constructor.tick()
    assert(record.entity.command == nil, 'ordered again while still on its way')
    game.tick = started + constructor.MOVE_LIMIT + 1
    constructor.tick()
    local command = record.entity.command
    assert(record.state == 'healing' and command and command.destination.x == -50, 'never sent again')
    assert(record.since == game.tick, 'the trip timer was not restarted')
    record.entity.command = nil
    record.entity.position = {x = -45, y = 0}
    game.tick = game.tick + constructor.MOVE_LIMIT + 1
    constructor.tick()
    assert(record.entity.command == nil, 'ordered again beside its barracks')
  end)

  test('engineers: a healing constructor turns to the next barracks when its own is gone', function()
    local b1 = ctx.building()
    local b2 = ctx.building()
    ctx.engineers.engine()
    b1.position, b2.position = {x = -50, y = 0}, {x = 90, y = 0}
    local constructor = require('scripts.engineers.constructor')
    local record = working()
    record.entity.health = 100
    constructor.tick()
    assert(record.entity.command.destination.x == -50)
    b1.valid = false
    game.tick = game.tick + 60
    constructor.tick()
    assert(record.state == 'healing' and record.entity.command.destination.x == 90, 'kept heading to a lost barracks')
  end)
  test('engineers: the division panel shows the engineers button only with constructors', function()
    local E = ctx.engineers
    E.engine()
    local panel = require('scripts.panel')
    panel.update(1)
    local frame = ctx.players()[1].gui.screen.tank_squads_divisions
    assert(not frame or not frame.visible, 'panel shown with nothing in it')
    require('scripts.engineers.init').register(E.constructor_entity(0, 0))
    panel.update(1)
    frame = ctx.players()[1].gui.screen.tank_squads_divisions
    assert(frame and frame.visible and frame.titlebar.engineers.visible, 'no engineers button')
    assert(panel.click({player_index = 1, element = frame.titlebar.engineers}))
    assert(ctx.players()[1].gui.screen.tank_squads_engineers.valid, 'the button did not open the window')
  end)

  test('engineers: the engineers window marks escort divisions and lists constructors', function()
    local E = ctx.engineers
    E.engine()
    local engineers = require('scripts.engineers.init')
    local divisions = require('scripts.divisions')
    divisions.assign(1, 2, {soldier()})
    local record = engineers.register(E.constructor_entity(5, 5))
    engineers.toggle_window(1)
    local frame = ctx.players()[1].gui.screen.tank_squads_engineers
    assert(frame and frame.valid and frame.style.width == 340)
    local body = frame.body
    assert(body.pool.cell_2.visible and not body.pool.cell_3.visible, 'division rows wrong')
    local box = body.pool.cell_2.pool_2
    box.state = true
    assert(engineers.checked({player_index = 1, element = box}))
    assert(divisions.record(1, 2).mode == 'engineer', 'the tick did not mark the division')
    local row = body.list['state_' .. record.id]
    assert(row and row.style.single_line, 'constructor row missing or wrapping')
    assert(engineers.click({player_index = 1, element = body.list['map_' .. record.id]}))
    assert(ctx.players()[1].controller.type == defines.controllers.remote, 'map not opened')
    engineers.toggle_window(1)
    assert(not frame.valid, 'window did not close')
  end)

  test('engineers: window and panel tolerate a save without engineers', function()
    ctx.engineers.engine()
    local engineers = require('scripts.engineers.init')
    engineers.refresh_windows()
    engineers.toggle_window(1)
    engineers.toggle_window(1)
    require('scripts.panel').update(1)
    assert(storage.engineers == nil, 'the window created the engineers state')
  end)

  test('engineers: the slow sweep does no per-player work without engineers state', function()
    ctx.engineers.engine()
    local engineers = require('scripts.engineers.init')
    local real, touched, updated = game.connected_players, false, false
    game.connected_players = setmetatable({}, {__index = function() touched = true end,
      __pairs = function() touched = true; return next, {}, nil end})
    engineers.slow_sweep(function() updated = true end)
    game.connected_players = real
    assert(not touched and not updated, 'per-player work without engineers state')
  end)

  test('engineers: the slow sweep refreshes only open windows and panels of players with constructors', function()
    local E = ctx.engineers
    E.engine()
    local engineers = require('scripts.engineers.init')
    local record = engineers.register(E.constructor_entity(5, 5))
    local updates = 0
    engineers.slow_sweep(function() updates = updates + 1 end)
    assert(updates == 1, 'player with constructors but no division got no panel update')
    engineers.toggle_window(1)
    engineers.unregister(record.entity.unit_number)
    engineers.slow_sweep(function() updates = updates + 1 end)
    assert(updates == 2, 'panel not judged again when the last constructor went')
    engineers.slow_sweep(function() updates = updates + 1 end)
    assert(updates == 2, 'panel updated every second with no constructor')
    assert(ctx.players()[1].gui.screen.tank_squads_engineers.body.list.none, 'open window did not refresh')
  end)

  test('engineers: the window has a close button that works with no constructors', function()
    ctx.engineers.engine()
    local engineers = require('scripts.engineers.init')
    engineers.toggle_window(1)
    local frame = ctx.players()[1].gui.screen.tank_squads_engineers
    assert(engineers.click({player_index = 1, element = frame.body.close}))
    assert(not frame.valid, 'close button left the window open')
  end)
end
