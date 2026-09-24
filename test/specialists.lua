return function(ctx)
  local test, soldier, building = ctx.test, ctx.soldier, ctx.building
  local divisions = require('scripts.divisions')
  local barracks = require('scripts.barracks')
  local weapons = require('scripts.weapons')
  local patrol = require('scripts.patrol')

  test('upgrade unlocks specialists only for forces with existing research', function()
    dofile('control.lua')
    local researched = {technologies={['tank-squad-unlock']={researched=true}}, recipes={
      ['tank-squad-train-siege']={enabled=false}, ['tank-squad-train-flame']={enabled=false}}}
    local pending = {technologies={['tank-squad-unlock']={researched=false}}, recipes={
      ['tank-squad-train-siege']={enabled=false}, ['tank-squad-train-flame']={enabled=false}}}
    game.forces = {researched, pending}
    ctx.handlers().configuration_changed{}
    assert(researched.recipes['tank-squad-train-siege'].enabled, 'researched save cannot build siege')
    assert(researched.recipes['tank-squad-train-flame'].enabled, 'researched save cannot build flame')
    assert(not pending.recipes['tank-squad-train-siege'].enabled, 'upgrade bypasses research')
  end)

  test('specialists join mixed divisions and receive patrol orders', function()
    local members = {soldier(), soldier(), soldier()}
    members[2].name, members[3].name = 'tank-squad-siege', 'tank-squad-flame'
    divisions.assign(1, 2, members)
    assert(divisions.size(1, 2) == 3, 'specialists excluded from division')
    patrol.add_waypoint(1, 2, {x=40,y=0}, members[1].surface)
    patrol.start(1, 2)
    for _, e in ipairs(members) do assert(e.command.destination.x == 40) end
  end)

  for _, kind in ipairs({'siege', 'flame'}) do
    test(kind .. ' recruit deploys, reinforces and heals through shared barracks', function()
      local b, output = building()
      assert(barracks.configure(b, 1, 2, 1))
      local recruit = 'tank-squad-recruit-' .. kind
      output[recruit] = 2
      barracks.tick()
      local members = divisions.get(1, 2)
      assert(#members == 1, 'specialist did not deploy')
      assert(members[1].name == 'tank-squad-' .. kind)
      assert(output[recruit] == 1, 'reinforcement cap lost recruit')
      members[1].health = 100
      barracks.tick()
      assert(members[1].health == 120, 'specialist excluded from healing')
    end)
  end

  test('siege gun holds aim between slow shots and resets recoil without polling frames', function()
    local a, enemy = soldier(), soldier('enemy')
    a.name = 'tank-squad-siege'
    local record = weapons.register(a)
    assert(record, 'siege weapon not registered')
    assert(record.gun.args.animation == 'tank-squad-siege-gun')
    weapons.on_shot{effect_id='tank-squad-shot', source_entity=a, target_entity=enemy, tick=10}
    game.tick = 70
    weapons.tick()
    assert(record.target == enemy, 'slow cannon loses aim between shots')
    assert(record.gun.animation_speed == 0, 'recoil loops while reloading')
    game.tick = 191
    weapons.tick()
    assert(not record.target and record.gun.use_target_orientation)
    weapons.unregister(a.unit_number)
    assert(not record.gun.valid)
  end)
end
