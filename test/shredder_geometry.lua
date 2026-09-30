return function(ctx)
  local test = ctx.test
  local g = require('scripts.shredder_geometry')
  local function near(a, b) return math.abs(a - b) < 1e-6 end
  local function item(id, x, y) return {id = id, position = {x = x, y = y or 0}} end
  local function count(changes, key)
    local n = 0
    for _, k in pairs(changes) do if k == key then n = n + 1 end end
    return n
  end

  test('shredder geometry: the backline lies 120 tiles toward home', function()
    local p = g.backline({x = 0, y = 0}, {x = 300, y = 400})
    assert(near(p.x, 72) and near(p.y, 96), p.x .. ',' .. p.y)
  end)

  test('shredder geometry: a home closer than 120 tiles is the backline', function()
    local p = g.backline({x = 0, y = 0}, {x = 10, y = 0})
    assert(p.x == 10 and p.y == 0)
  end)

  test('shredder geometry: without home the backline lies away from the enemy, else south', function()
    local p = g.backline({x = 0, y = 0}, nil, {x = 0, y = -30})
    assert(near(p.x, 0) and near(p.y, 120))
    p = g.backline({x = 0, y = 0}, nil, {x = 30, y = 0})
    assert(near(p.x, -120) and near(p.y, 0))
    p = g.backline({x = 5, y = 5})
    assert(p.x == 5 and p.y == 125)
    p = g.backline({x = 0, y = 0}, {x = 0, y = 100}, nil, 40)
    assert(near(p.y, 40), 'distance argument ignored')
  end)

  test('shredder geometry: centre is the mean position, nil for nobody', function()
    local c = g.centre({{position = {x = 0, y = 0}}, {position = {x = 10, y = 4}}})
    assert(c.x == 5 and c.y == 2)
    assert(g.centre({}) == nil)
  end)

  test('shredder geometry: slots spiral out without overlapping', function()
    local first = g.slot({x = 3, y = 4}, 1)
    assert(first.x == 3 and first.y == 4)
    local seen = {}
    for i = 1, 16 do
      local s = g.slot({x = 0, y = 0}, i)
      for j, o in ipairs(seen) do assert(g.distance2(s, o) > 4, 'slots ' .. j .. ' and ' .. i .. ' overlap') end
      seen[#seen + 1] = s
    end
  end)

  test('shredder geometry: the pool splits evenly, nearest shredder first', function()
    local groups = {{key = 'a', point = {x = 0, y = 0}, members = {}}, {key = 'b', point = {x = 100, y = 0}, members = {}}}
    local changes = g.rebalance(groups, {item(1, 90), item(2, 5), item(3, 95), item(4, 10)})
    assert(changes[2] == 'a' and changes[4] == 'a' and changes[1] == 'b' and changes[3] == 'b')
  end)

  test('shredder geometry: only the surplus moves, farthest first', function()
    local groups = {
      {key = 'a', point = {x = 0, y = 0}, members = {item(1, 1), item(2, 50), item(3, 2), item(4, 3)}},
      {key = 'b', point = {x = 100, y = 0}, members = {item(5, 100)}},
    }
    local changes = g.rebalance(groups, {})
    assert(changes[2] == 'b', 'farthest surplus shredder did not move')
    local moved = 0
    for _ in pairs(changes) do moved = moved + 1 end
    assert(moved == 1, moved .. ' shredders moved for a one-shredder imbalance')
  end)

  test('shredder geometry: an even split moves nobody, and no groups keep the pool', function()
    local groups = {{key = 'a', point = {x = 0, y = 0}, members = {item(1, 0)}},
      {key = 'b', point = {x = 9, y = 0}, members = {item(2, 9), item(3, 9)}}}
    assert(next(g.rebalance(groups, {})) == nil)
    assert(next(g.rebalance({}, {item(4, 0)})) == nil)
  end)

  test('shredder geometry: with fewer shredders than groups none gets two', function()
    local groups = {{key = 'a', point = {x = 0, y = 0}, members = {}},
      {key = 'b', point = {x = 50, y = 0}, members = {}}, {key = 'c', point = {x = 100, y = 0}, members = {}}}
    local changes = g.rebalance(groups, {item(1, 99), item(2, 1)})
    assert(count(changes, 'a') + count(changes, 'b') + count(changes, 'c') == 2)
    assert(count(changes, 'a') <= 1 and count(changes, 'b') <= 1 and count(changes, 'c') <= 1)
  end)

  test('shredder geometry: a large pool is dealt without a distance scan per pick', function()
    local groups = {}
    for i = 1, 9 do groups[i] = {key = 'g' .. i, point = {x = i * 40, y = 0}, members = {}} end
    local pool = {}
    for i = 1, 1000 do pool[i] = item(i, (i * 37) % 400, (i * 11) % 90) end
    local distance2, calls = g.distance2, 0
    g.distance2 = function(a, b) calls = calls + 1; return distance2(a, b) end
    local changes = g.rebalance(groups, pool)
    g.distance2 = distance2
    local dealt = 0
    for i = 1, 9 do dealt = dealt + count(changes, 'g' .. i) end
    assert(dealt == 1000, dealt .. ' shredders dealt')
    assert(calls <= 9 * 1000, calls .. ' distances for 1000 shredders and 9 groups')
  end)
end
