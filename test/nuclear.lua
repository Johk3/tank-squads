return function(ctx)
  local test, soldier = ctx.test, ctx.soldier
  local nuclear = require('scripts.nuclear')
  local weapons = require('scripts.weapons')

  local function setup()
    local own = ctx.players()[1].force
    local ally, enemy = {index = 3, name = 'ally'}, {index = 2, name = 'enemy'}
    own.get_friend = function(other) return other == ally end
    game.forces = {own, enemy, ally}
    local tank = soldier(nil, nil, 0, 0)
    tank.name = 'tank-squad-nuclear'
    tank.type = 'unit'
    local launched = {}
    tank.surface.create_entity = function(args) launched[#launched + 1] = args; return {valid = true} end
    tank.surface.play_sound = function() end
    local record = weapons.register(tank)
    local target = soldier('enemy', nil, 40, 0)
    return tank, target, record, launched, ally
  end

  local function fire(tank, target, tick)
    return nuclear.on_trigger{effect_id = 'tank-squad-nuke', source_entity = tank, target_entity = target, tick = tick}
  end

  test('nuclear: reload shortens with rank and never drops under the floor', function()
    local expected = {[0] = 1200, 849, 693, 537, 424, 346}
    for rank = 0, 5 do assert(nuclear.reload(rank) == expected[rank], 'rank ' .. rank .. ': ' .. nuclear.reload(rank)) end
    local ranks = require('scripts.ranks')
    local legend = ranks.LIST[5].damage
    ranks.LIST[5].damage = 1000
    assert(nuclear.reload(5) == nuclear.FLOOR)
    ranks.LIST[5].damage = legend
  end)

  test('nuclear: a clear target gets a nuke, then the tank reloads', function()
    local tank, target, record, launched = setup()
    assert(fire(tank, target, 100) == nuclear.NUKE)
    assert(launched[1].name == nuclear.NUKE and launched[1].source == tank and launched[1].cause == tank)
    assert(launched[1].target.x == 40, 'nuke not aimed at the target position')
    assert(record.next_launch == 1300 and record.recoiling, 'no reload or launcher animation')
    assert(fire(tank, target, 1299) == nil and #launched == 1, 'fired while reloading')
    assert(fire(tank, target, 1300) == nuclear.NUKE)
  end)

  test('nuclear: a friend near the target gets a plain rocket instead', function()
    local tank, target, _, launched = setup()
    soldier(nil, nil, 50, 0).type = 'unit'
    assert(fire(tank, target, 10) == nuclear.FALLBACK and launched[1].name == nuclear.FALLBACK)
  end)

  test('nuclear: an allied force near the target is protected too', function()
    local tank, target, _, launched, ally = setup()
    soldier(ally, nil, 30, 0).type = 'unit'
    assert(fire(tank, target, 10) == nuclear.FALLBACK and launched[1].name == nuclear.FALLBACK)
  end)

  test('nuclear: the tank itself blocks a close nuke', function()
    local tank, _, _, launched = setup()
    local close = soldier('enemy', nil, 12, 0)
    assert(fire(tank, close, 10) == nuclear.FALLBACK and launched[1].name == nuclear.FALLBACK)
  end)

  test('nuclear: transient friendly entities do not block a launch', function()
    local tank, target = setup()
    for _, kind in ipairs({'projectile', 'explosion', 'fire', 'corpse', 'entity-ghost', 'stream'}) do
      soldier(nil, nil, 42, 0).type = kind
    end
    assert(fire(tank, target, 10) == nuclear.NUKE)
  end)

  test('nuclear: other effects and dead shooters or targets are ignored', function()
    local tank, target, _, launched = setup()
    assert(nuclear.on_trigger{effect_id = 'tank-squad-shot', source_entity = tank, target_entity = target, tick = 1} == nil)
    target.valid = false
    assert(fire(tank, target, 1) == nil and #launched == 0)
  end)
end
