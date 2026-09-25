return function(ctx)
  local test = ctx.test
  local ranks = require('scripts.ranks')

  test('ranks: thresholds promote at exactly 50, 250 and 1000 XP', function()
    local cases = {{0, 0}, {49.9, 0}, {50, 1}, {249.99, 1}, {250, 2}, {999, 2}, {1000, 3}, {1e9, 3}}
    for _, case in ipairs(cases) do
      assert(ranks.for_xp(case[1]) == case[2], case[1] .. ' XP gave rank ' .. ranks.for_xp(case[1]))
    end
  end)

  test('ranks: bonuses grow with rank and unknown ranks give none', function()
    assert(ranks.bonus(1).speed == 0.10 and ranks.bonus(1).damage == 0.20 and ranks.bonus(1).reduction == 0.20)
    assert(ranks.bonus(3).speed == 0.30 and ranks.bonus(3).damage == 0.75 and ranks.bonus(3).reduction == 0.50)
    assert(ranks.bonus(99) == ranks.LIST[0], 'unknown rank has a bonus')
    for rank = 1, ranks.TOP do
      local low, high = ranks.bonus(rank - 1), ranks.bonus(rank)
      assert(high.xp > low.xp and high.speed > low.speed and high.damage > low.damage and high.reduction > low.reduction,
        'rank ' .. rank .. ' is not stronger than the one below')
    end
    assert(ranks.next_xp(0) == 50 and ranks.next_xp(2) == 1000 and ranks.next_xp(3) == nil)
    assert(ranks.sprite(2) == 'tank-squad-rank-2')
  end)
  local unit_names = require('scripts.unit_names')

  test('names: the same storage draws the same names on every peer', function()
    local first = {}
    for i = 1, 5 do local n = unit_names.draw(); first[i] = n.adjective .. ':' .. n.noun end
    storage = {}
    for i = 1, 5 do
      local n = unit_names.draw()
      assert(first[i] == n.adjective .. ':' .. n.noun, 'draw ' .. i .. ' differs after reset')
      assert(n.adjective >= 1 and n.adjective <= unit_names.ADJECTIVES and n.noun >= 1 and n.noun <= unit_names.NOUNS)
    end
  end)

  test('names: a name held by a living unit is redrawn, and released names come back', function()
    local held = unit_names.draw()
    local seed = storage.name_seed
    storage.name_seed = nil
    local again = unit_names.draw()
    assert(again.adjective ~= held.adjective or again.noun ~= held.noun, 'duplicate name drawn')
    local key = held.adjective * 1000 + held.noun
    assert(storage.name_taken[key] == 1)
    unit_names.release(held)
    assert(storage.name_taken[key] == nil, 'released name still counted')
    unit_names.release(held)
    assert(storage.name_taken[key] == nil, 'double release went negative')
    assert(seed ~= nil)
  end)

  test('names: localised from locale keys that all exist', function()
    local name = unit_names.localised{adjective = 3, noun = 57}
    assert(name[1] == '' and name[2][1] == 'tank-squads.name-adjective-3' and name[3] == ' '
      and name[4][1] == 'tank-squads.name-noun-57')
    local text = io.open('locale/en/tank-squads.cfg'):read('*a')
    for i = 1, unit_names.ADJECTIVES do assert(text:find('\nname%-adjective%-' .. i .. '='), 'missing adjective ' .. i) end
    for i = 1, unit_names.NOUNS do assert(text:find('\nname%-noun%-' .. i .. '='), 'missing noun ' .. i) end
  end)
  local function alt_draws()
    local out = {}
    for _, d in ipairs(ctx.draws()) do if d.valid and d.args.only_in_alt_mode then out[#out + 1] = d end end
    return out
  end

  local veterans = require('scripts.veterans')
  local names = require('scripts.names')

  test('records: soldiers enlist as recruits, the headquarters only gets a name', function()
    local e, hq = ctx.soldier(), ctx.soldier()
    hq.name = names.headquarters
    local record = veterans.register(e)
    assert(record.adjective and record.noun and record.xp == 0 and record.kills == 0 and record.rank == 0)
    assert(veterans.register(e) == record, 'register is not idempotent')
    local key = record.adjective * 1000 + record.noun
    assert(storage.name_taken[key] == 1, 'second register drew another name')
    local hq_record = veterans.register(hq)
    assert(hq_record.adjective and hq_record.xp == nil and hq_record.rank == nil)
    veterans.unregister(e.unit_number)
    assert(veterans.get(e.unit_number) == nil and storage.name_taken[key] == nil)
  end)

  test('kills: the killing soldier gains one kill and XP weighted by the victim', function()
    local e, biter = ctx.soldier(), ctx.soldier('enemy')
    biter.max_health = 75
    local record = veterans.register(e)
    veterans.on_kill{entity = biter, cause = e}
    assert(record.kills == 1 and math.abs(record.xp - 7.5) < 1e-9, 'kill XP ' .. record.xp)
  end)

  test('kills: other causes are ignored without errors', function()
    local e, biter, hq = ctx.soldier(), ctx.soldier('enemy'), ctx.soldier()
    hq.name = names.headquarters
    local record = veterans.register(e)
    veterans.register(hq)
    local dead = ctx.soldier()
    dead.valid = false
    veterans.on_kill{entity = biter}
    veterans.on_kill{entity = biter, cause = dead}
    veterans.on_kill{entity = biter, cause = {valid = true}}                -- no unit number
    veterans.on_kill{entity = biter, cause = ctx.soldier()}                 -- no record
    veterans.on_kill{entity = biter, cause = hq}                            -- no XP
    assert(record.kills == 0 and record.xp == 0)
    assert(veterans.get(hq.unit_number).xp == nil)
  end)

  test('promotion: crossing a threshold raises rank, speed and tells the force', function()
    local e = ctx.soldier()
    local record = veterans.register(e)
    veterans.add_xp(e, record, 49)
    assert(record.rank == 0 and e.speed == 0.12)
    veterans.add_xp(e, record, 1)
    assert(record.rank == 1, 'no promotion at 50 XP')
    assert(math.abs(e.speed - 0.12 * 1.1) < 1e-9, 'speed ' .. e.speed)
    local flying = ctx.players()[1].flying
    assert(#flying == 1 and flying[1].text[1] == 'tank-squads.promoted' and flying[1].text[3][1] == 'tank-squads.rank-1')
    veterans.add_xp(e, record, 2000)
    assert(record.rank == 3 and math.abs(e.speed - 0.12 * 1.3) < 1e-9, 'skipped ranks not applied')
    e.speed = 0.12
    veterans.reapply()
    assert(math.abs(e.speed - 0.12 * 1.3) < 1e-9, 'configuration change lost the speed bonus')
  end)

  test('records: weapons and the sweep keep service records in step', function()
    local weapons = require('scripts.weapons')
    local e = ctx.soldier()
    weapons.register(e)
    local record = assert(veterans.get(e.unit_number), 'registered soldier has no record')
    weapons.tick()
    -- Names show on the hover card only: an alt-mode label per unit costs
    -- the engine work every tick for every unit.
    assert(#alt_draws() == 0 and record.labels == nil, 'sweep drew alt-mode labels')
    weapons.unregister(e.unit_number)
    assert(veterans.get(e.unit_number) == nil, 'unregistered soldier kept its record')
  end)

  test('records: control credits enemy deaths and cleans up dead soldiers', function()
    dofile('control.lua')
    local e, biter = ctx.soldier(), ctx.soldier('enemy')
    biter.name = 'small-biter'
    biter.max_health = 15
    local record = veterans.register(e)
    ctx.handlers().on_entity_died{entity = biter, cause = e}
    assert(record.kills == 1, 'control did not route the enemy death')
    ctx.handlers().on_entity_died{entity = e}
    assert(veterans.get(e.unit_number) == nil, 'dead soldier kept its record')
  end)
  local function ranked(name, rank)
    local e = ctx.soldier()
    e.name = name or names.soldier_names[1]
    local record = veterans.register(e)
    record.rank = rank
    return e, record
  end

  test('bonuses: a ranked soldier heals back its share of every survivable hit', function()
    local e = ranked(nil, 2)
    e.health = 300
    veterans.on_damaged{entity = e, final_damage_amount = 100, final_health = 300}
    assert(math.abs(e.health - 340) < 1e-9, 'healed to ' .. e.health)
    local recruit = ranked(nil, 0)
    recruit.health = 300
    veterans.on_damaged{entity = recruit, final_damage_amount = 100, final_health = 300}
    assert(recruit.health == 300, 'recruit took less damage')
    e.health = 0
    veterans.on_damaged{entity = e, final_damage_amount = 100, final_health = 0}
    assert(e.health == 0, 'a killing blow was reduced')
  end)

  test('bonuses: a ranked shooter banks its bonus and deals it in native-sized hits', function()
    local e = ranked(names.soldier_names[1], 3)
    local target = ctx.soldier('enemy')
    e.force.get_ammo_damage_modifier = function(category) return category == 'bullet' and 0.5 or 0 end
    local gun = {rank = 3}
    -- A native Mk1 hit is 6 * 1.5 = 9; a Veteran's bonus per shot is 6 * 0.75 * 1.5 = 6.75.
    veterans.on_shot({effect_id = 'tank-squad-shot', source_entity = e, target_entity = target}, gun)
    assert(#target.damaged == 0 and math.abs(gun.bonus - 6.75) < 1e-9, 'a bonus smaller than a native hit was dealt alone')
    veterans.on_shot({effect_id = 'tank-squad-shot', source_entity = e, target_entity = target}, gun)
    local hit = target.damaged[1]
    -- Armour treats a native-sized hit like the native one, so the bonus keeps its share.
    assert(hit and math.abs(hit.amount - 9) < 1e-9, 'banked bonus hit ' .. tostring(hit and hit.amount))
    assert(hit.type == 'physical' and hit.force == e.force and hit.source == e and hit.cause == e)
    assert(math.abs(gun.bonus - 4.5) < 1e-9, 'remainder not kept: ' .. tostring(gun.bonus))
    local recruit = ranked(names.soldier_names[1], 0)
    veterans.on_shot({effect_id = 'tank-squad-shot', source_entity = recruit, target_entity = target}, {rank = 0})
    veterans.on_shot({effect_id = 'another-mod', source_entity = e, target_entity = target}, gun)
    veterans.on_shot({effect_id = 'tank-squad-shot', source_entity = e, target_entity = target})
    local gone = ctx.soldier('enemy')
    gone.valid = false
    veterans.on_shot({effect_id = 'tank-squad-shot', source_entity = e, target_entity = gone}, gun)
    assert(#target.damaged == 1 and #gone.damaged == 0, 'bonus from a recruit, another mod or a dead target')
  end)

  test('bonuses: a flame tank\'s bonus scales with its whole stream, not one particle', function()
    local flame = ranked('tank-squad-flame', 3)
    local target = ctx.soldier('enemy')
    local gun = {rank = 3}
    veterans.on_shot({effect_id = 'tank-squad-shot', source_entity = flame, target_entity = target}, gun)
    -- Three particles of 7 fire land per attack: 21 * 0.75 = 15.75, dealt as
    -- two particle-sized hits with 1.75 kept.
    assert(#target.damaged == 2, 'flame bonus hits: ' .. #target.damaged)
    for _, hit in ipairs(target.damaged) do assert(hit.amount == 7 and hit.type == 'fire') end
    assert(math.abs(gun.bonus - 1.75) < 1e-9)
  end)

  test('bonuses: a siege tank adds its bonus when the shell lands, not when it fires', function()
    local siege = ranked('tank-squad-siege', 3)
    local target = ctx.soldier('enemy')
    veterans.on_shot({effect_id = 'tank-squad-shot', source_entity = siege, target_entity = target}, {rank = 3})
    assert(#target.damaged == 0, 'siege bonus landed on firing')
    veterans.on_shot{effect_id = 'tank-squad-shell-hit', cause_entity = siege, target_entity = target}
    assert(#target.damaged == 1 and math.abs(target.damaged[1].amount - 750) < 1e-9)
    siege.valid = false
    veterans.on_shot{effect_id = 'tank-squad-shell-hit', cause_entity = siege, target_entity = target}
    veterans.on_shot{effect_id = 'tank-squad-shell-hit', target_entity = target}
    assert(#target.damaged == 1, 'shell of a dead siege tank dealt a bonus')
  end)

  test('bonuses: a recruit\'s shot reads nothing from the shooter or its target', function()
    local e = ranked(names.soldier_names[1], 0)
    local target = ctx.soldier('enemy')
    local reads = {ctx.count_reads(e, 'unit_number'), ctx.count_reads(e, 'valid'), ctx.count_reads(target, 'valid')}
    veterans.on_shot({effect_id = 'tank-squad-shot', source_entity = e, target_entity = target}, {rank = 0})
    for _, r in ipairs(reads) do assert(r.n == 0, 'a recruit shot read an entity field') end
    assert(#target.damaged == 0)
  end)

  test('bonuses: the weapons record carries the rank the shot hook reads', function()
    local weapons = require('scripts.weapons')
    local e = ctx.soldier()
    weapons.register(e)
    assert(storage.weapons[e.unit_number].rank == 0, 'new gun record lacks the rank')
    veterans.add_xp(e, veterans.get(e.unit_number), 300)
    assert(storage.weapons[e.unit_number].rank == 2, 'promotion did not reach the gun record')
    storage.weapons[e.unit_number].gun.valid = false
    weapons.tick()
    assert(storage.weapons[e.unit_number].rank == 2, 'a repaired gun record lost the rank')
  end)

  test('bonuses: control routes damage and shot events to the service records', function()
    dofile('control.lua')
    local e = ranked(nil, 1)
    local target = ctx.soldier('enemy')
    -- A unit target keeps combat.on_shot from searching for nearby enemies.
    target.type = 'unit'
    e.health = 300
    ctx.handlers().on_entity_damaged{entity = e, final_damage_amount = 50, final_health = 300}
    assert(math.abs(e.health - 310) < 1e-9, 'control did not route damage')
    -- Bonuses are banked until they reach a native hit: a Veteran Mk1 banks
    -- 4.5 per shot, so its second shot deals them.
    storage.veterans[e.unit_number].rank = 3
    for _ = 1, 2 do
      ctx.handlers().on_script_trigger_effect{effect_id = 'tank-squad-shot', source_entity = e, target_entity = target}
    end
    assert(#target.damaged == 1, 'control did not route shots')
  end)
end
