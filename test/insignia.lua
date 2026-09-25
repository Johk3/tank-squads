return function(ctx)
  local test, soldier = ctx.test, ctx.soldier
  local divisions = require('scripts.divisions')
  local render = require('scripts.render')
  local insignia = require('scripts.insignia')

  local function badges(target)
    local world, map = {}, {}
    for _, d in ipairs(ctx.draws()) do
      if d.valid and d.args.sprite and d.args.sprite:find('tank%-squad%-insignia') then
        local on = d.args.target.entity or d.args.target
        if on == target then
          if d.args.render_mode == 'chart' then map[#map + 1] = d else world[#world + 1] = d end
        end
      end
    end
    return world, map
  end

  test('insignia: a division shows its insignia over its leader and on the map, to the whole force', function()
    local a, b = soldier(), soldier()
    divisions.assign(1, 3, {a, b})
    divisions.refresh()
    local world, map = badges(a)
    assert(#world == 1 and #map == 1, 'badges: ' .. #world .. ' world, ' .. #map .. ' map')
    assert(world[1].args.sprite == 'tank-squad-insignia-3' and map[1].args.sprite == 'tank-squad-insignia-3')
    for _, d in ipairs({world[1], map[1]}) do
      assert(d.args.forces[1] == a.force and not d.args.players, 'insignia not force-wide')
    end
    assert(world[1].args.target.offset[2] < 0, 'world badge not above the leader')
    assert(world[1].args.x_scale * insignia.SPRITE_TILES > 2, 'world badge too small to read')
    assert(map[1].args.x_scale * insignia.SPRITE_TILES >= 12, 'map badge too small to read')
    local count = #ctx.draws()
    divisions.refresh()
    assert(#ctx.draws() == count, 'unchanged badges redrawn')
    a.valid = false
    divisions.refresh()
    assert(not world[1].valid and not map[1].valid, 'dead leader kept the badges')
    local w2, m2 = badges(b)
    assert(#w2 == 1 and #m2 == 1, 'new leader has no badges')
    divisions.clear_player(1)
    assert(not w2[1].valid and not m2[1].valid, 'cleared division kept its badges')
  end)

  test('insignia: the drag selection has none', function()
    local a = soldier()
    divisions.select_area(1, {a})
    divisions.refresh()
    local world, map = badges(a)
    assert(#world == 0 and #map == 0)
  end)

  test('insignia: markers from an older save gain badges without redrawing the number', function()
    local a = soldier()
    divisions.assign(1, 5, {a})
    divisions.refresh()
    local marker = divisions.record(1, 5).render.markers[a.surface_index]
    marker.badge.destroy(); marker.map_badge.destroy()
    marker.badge, marker.map_badge = nil, nil
    local number = marker.object
    divisions.refresh()
    assert(number.valid and marker.object == number, 'number redrawn')
    assert(marker.badge and marker.badge.valid and marker.map_badge.valid, 'old marker gained no badges')
  end)

  test('insignia: ring colours are the shields\' accents', function()
    for n = 1, 9 do assert(render.COLORS[n] == insignia.SLOTS[n].color, 'slot ' .. n) end
    assert(render.COLORS[0].g == 1.0, 'selection colour changed')
  end)

  test('insignia: an upgrade redraws rings and escort shapes in the new colours once', function()
    dofile('control.lua')
    local a = soldier()
    divisions.assign(1, 2, {a})
    local record = divisions.record(1, 2)
    assert(record.render.palette == render.PALETTE, 'new division lacks the palette version')
    local ring = record.render.rings[a.unit_number]
    ctx.handlers().configuration_changed()
    assert(ring.valid, 'current rings redrawn on every configuration change')
    record.render.palette = nil
    ctx.handlers().configuration_changed()
    assert(not ring.valid and record.render.rings[a.unit_number].valid, 'old-colour ring kept')
    assert(record.render.palette == render.PALETTE)
  end)
end
