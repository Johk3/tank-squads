return function(ctx)
  local test, soldier = ctx.test, ctx.soldier
  local electric = require('scripts.electric')

  local function setup()
    local own = ctx.players()[1].force
    local enemy = {index = 2, name = 'enemy'}
    -- LuaForce.is_enemy(other), called with a dot like the real method.
    own.is_enemy = function(other) return other == enemy end
    game.forces = {own, enemy}
    local tank = soldier()
    tank.name = 'tank-squad-electric'
    return tank, own, enemy
  end

  test('electric: an impact draws one arc to each nearby enemy, at most six', function()
    local tank, _, enemy = setup()
    local near = {}
    for i = 1, 8 do
      local e = soldier(enemy, nil, i * 0.5, 0)
      e.type = 'unit'
      near[i] = e
    end
    local far = soldier(enemy, nil, 20, 0)
    far.type = 'unit'
    local before = #ctx.draws()
    local surface = tank.surface
    game.surfaces = {[surface.index] = surface}
    local n = electric.on_hit{effect_id = 'tank-squad-electric-hit', cause_entity = tank,
      target_position = {x = 0, y = 0}, surface_index = surface.index}
    assert(n == 6, 'arcs ' .. tostring(n))
    local arc = ctx.draws()[before + 1].args
    assert(arc.animation == 'tank-squad-electric-link' and arc.time_to_live == electric.TTL)
    assert(math.abs(arc.orientation - 0) < 1e-9, 'east arc orientation ' .. arc.orientation)
    assert(math.abs(arc.target.x - 0.25) < 1e-9 and arc.target.y == 0, 'arc not centred between the ends')
  end)

  test('electric: other effects, a dead shooter or no enemies draw nothing', function()
    local tank = setup()
    game.surfaces = {[tank.surface.index] = tank.surface}
    local before = #ctx.draws()
    assert(electric.on_hit{effect_id = 'tank-squad-shot', cause_entity = tank} == nil)
    tank.valid = false
    assert(electric.on_hit{effect_id = 'tank-squad-electric-hit', cause_entity = tank,
      target_position = {x = 0, y = 0}, surface_index = tank.surface.index} == 0)
    assert(#ctx.draws() == before)
  end)
end
