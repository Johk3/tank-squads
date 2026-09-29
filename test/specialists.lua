return function(ctx)
  local test, soldier, building = ctx.test, ctx.soldier, ctx.building
  local divisions = require('scripts.divisions')
  local barracks = require('scripts.barracks')
  local weapons = require('scripts.weapons')
  local patrol = require('scripts.patrol')
  local names = require('scripts.names')

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

  for _, case in ipairs({{tier = 2, animation = 'tank-squad-red-gun'}, {tier = 3, animation = 'tank-squad-green-gun'}}) do
    test('tier ' .. case.tier .. ' carrier draws its own untinted animated gun and recoils per shot', function()
      local a, enemy = soldier(), soldier('enemy')
      a.name = 'tank-squad-soldier-' .. case.tier
      local record = weapons.register(a)
      assert(record.gun.args.animation == case.animation, 'gun ' .. tostring(record.gun.args.animation))
      assert(record.gun.args.tint == nil, 'painted gun is tinted')
      weapons.on_shot{effect_id = 'tank-squad-shot', source_entity = a, target_entity = enemy, tick = 100}
      assert(record.gun.animation_speed == 1 and record.gun.animation_offset == -100, 'no recoil on shot')
      weapons.on_shot{effect_id = 'tank-squad-shot', source_entity = a, target_entity = enemy, tick = 112}
      assert(record.gun.animation_offset == -112, 'second shot did not restart the flash')
      game.tick = 200
      weapons.tick()
      assert(record.gun.animation_speed == 0 and record.gun.animation_offset == 0, 'gun not settled at rest')
    end)
  end

  test('tier 1 carrier keeps its tinted static gun', function()
    local a = soldier()
    local record = weapons.register(a)
    assert(record.gun.args.sprite == 'tank-squad-chaingun' and record.gun.args.tint ~= nil)
  end)

  test('configuration change turns old tier 2 and 3 guns into animations', function()
    dofile('control.lua')
    local a = soldier()
    a.name = 'tank-squad-soldier-2'
    storage.weapons = {}
    local old = {valid = true, type = 'sprite', args = {sprite = 'tank-squad-chaingun'}}
    old.destroy = function() old.valid = false end
    storage.weapons[a.unit_number] = {entity = a, gun = old, rank = 0}
    -- Only the soldier-name query finds the carrier; barracks, headquarters
    -- and headquarters-helper queries find nothing. Matched by identity, not
    -- just by shape, since headquarters.reconcile() also queries by a list.
    a.surface.find_entities_filtered = function(query)
      if query.name == names.soldier_names then return {a} end
      return {}
    end
    game.forces = {}
    ctx.handlers().configuration_changed{}
    assert(not old.valid, 'old sprite gun kept')
    assert(storage.weapons[a.unit_number].gun.args.animation == 'tank-squad-red-gun', 'no animation after migration')
  end)

  test('appearance: gun sequences start and end at rest and flash in between', function()
    local appearance = require('scripts.appearance')
    local sequence = appearance.gun_sequence{{2, 3}, {3, 3}, {4, 3}}
    assert(#sequence == 128 and sequence[1] == 1 and sequence[2] == 2 and sequence[4] == 2
      and sequence[5] == 3 and sequence[8] == 4 and sequence[11] == 1 and sequence[128] == 1)
  end)
end
