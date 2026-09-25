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
end
