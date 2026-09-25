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
end
