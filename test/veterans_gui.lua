return function(ctx)
  local test, soldier = ctx.test, ctx.soldier
  local veterans = require('scripts.veterans')
  local divisions = require('scripts.divisions')
  local gui = require('scripts.veterans_gui')

  local function setup()
    local player = ctx.players()[1]
    player.gui = {left = ctx.gui_element(), screen = ctx.gui_element()}
    player.set_shortcut_toggled = function() end
    player.printed = {}
    player.print = function(message) player.printed[#player.printed + 1] = message end
    return player
  end

  local function veteran(xp, kills)
    local e = soldier()
    local record = veterans.register(e)
    record.xp, record.kills = xp, kills
    return e
  end

  local function tick(frame, e) frame.body.pane.list['unit_' .. e.unit_number].pick.state = true end

  test('veterans window: lists every soldier of each division best first', function()
    local player = setup()
    local weak, strong, tied, best = veteran(10, 1), veteran(900, 3), veteran(900, 9), veteran(4000, 50)
    local rest = {weak, strong, tied, best}
    for _ = 1, 6 do rest[#rest + 1] = veteran(0, 0) end
    divisions.assign(1, 2, rest)
    divisions.assign(1, 5, {veteran(20, 0)})
    gui.toggle(1)
    local frame = assert(player.gui.screen.tank_squads_veterans, 'window missing')
    local list = frame.body.pane.list
    assert(list.division_2 and list.division_5 and not list.division_1, 'division headers')
    local units = frame.tags.units
    assert(#units == #rest + 1, 'rows ' .. #units)
    assert(units[1] == best.unit_number and units[2] == tied.unit_number and units[3] == strong.unit_number,
      'not ranked by XP then kills')
    assert(units[4] == weak.unit_number and units[#rest] == rest[#rest].unit_number, 'weakest not last')
    gui.toggle(1)
    assert(not frame.valid, 'second toggle did not close')
  end)

  test('veterans window: picked soldiers form a new division and leave their old one', function()
    local player = setup()
    local a, b, c = veteran(500, 5), veteran(300, 2), veteran(1, 0)
    local d = veteran(700, 7)
    divisions.assign(1, 1, {a, b, c})
    divisions.assign(1, 3, {d})
    gui.toggle(1)
    local frame = player.gui.screen.tank_squads_veterans
    tick(frame, a); tick(frame, d)
    assert(gui.click{player_index = 1, element = frame.body.actions.form})
    assert(not frame.valid, 'window stayed open')
    assert(divisions.size(1, 2) == 2, 'new division size ' .. divisions.size(1, 2))
    assert(divisions.size(1, 1) == 2 and divisions.size(1, 3) == 0, 'soldiers stayed in their old divisions')
    assert(divisions.selected(1) == 2 and player.printed[1][1] == 'tank-squads.selection-promoted')
  end)

  test('veterans window: select makes a drag selection; empty or stale picks do nothing', function()
    local player = setup()
    local a, b = veteran(500, 5), veteran(300, 2)
    divisions.assign(1, 4, {a, b})
    gui.toggle(1)
    local frame = player.gui.screen.tank_squads_veterans
    assert(gui.click{player_index = 1, element = frame.body.actions.select_picked})
    assert(frame.valid and player.printed[1][1] == 'tank-squads.veterans-none-picked', 'empty pick')
    tick(frame, a); tick(frame, b)
    a.valid = false
    assert(gui.click{player_index = 1, element = frame.body.actions.select_picked})
    assert(divisions.selected(1) == 0 and divisions.size(1, 0) == 1, 'dead soldier selected')
    assert(divisions.size(1, 4) == 1, 'selecting changed the division')
  end)

  test('veterans window: the division window button opens it through control', function()
    dofile('control.lua')
    local player = setup()
    divisions.assign(1, 6, {veteran(5, 0)})
    require('scripts.panel').update(1)
    local bar = player.gui.screen.tank_squads_divisions.titlebar
    ctx.handlers().on_gui_click{player_index = 1, element = bar.veterans}
    local frame = assert(player.gui.screen.tank_squads_veterans, 'button did not open the window')
    ctx.handlers().on_gui_click{player_index = 1, element = frame.body.actions.close}
    assert(not frame.valid, 'close button')
  end)

  local function special(name, xp)
    local e = soldier()
    e.name = name
    local record = veterans.register(e)
    record.xp, record.kills = xp, 0
    return e
  end

  test('veterans window: special tanks stand out with icon, colour, tag and counts', function()
    local player = setup()
    local volt, nuke, plain = special('tank-squad-electric', 600), special('tank-squad-nuclear', 500), veteran(700, 1)
    divisions.assign(1, 4, {volt, nuke, plain})
    divisions.assign(1, 6, {special('tank-squad-electric', 10)})
    gui.toggle(1)
    local frame = player.gui.screen.tank_squads_veterans
    local list = frame.body.pane.list
    local row = list['unit_' .. volt.unit_number]
    assert(row.kind_icon.sprite == 'entity/tank-squad-electric', 'no unit icon')
    assert(row.pick.style.font_color and row.pick.style.font_color.b > 0.9, 'electric name not cyan')
    assert(row.special.caption[1] == 'tank-squads.veterans-kind-electric', 'no electric tag')
    assert(row.tooltip[1] == 'tank-squads.veterans-kind-electric-help')
    local nuke_row = list['unit_' .. nuke.unit_number]
    assert(nuke_row.special.caption[1] == 'tank-squads.veterans-kind-nuclear')
    local plain_row = list['unit_' .. plain.unit_number]
    assert(plain_row.kind_icon.sprite == 'entity/tank-squad-soldier-1' and plain_row.special == nil
      and plain_row.pick.style.font_color == nil, 'plain carrier marked special')
    assert(list.division_4.special.caption[1] == 'tank-squads.veterans-division-special'
      and list.division_4.special.caption[2] == 1 and list.division_4.special.caption[3] == 1)
    assert(frame.body.summary.visible and frame.body.summary.caption[2] == 2 and frame.body.summary.caption[3] == 1)
  end)

  test('veterans window: no special tanks, no summary and no header counts', function()
    local player = setup()
    divisions.assign(1, 1, {veteran(5, 0)})
    gui.toggle(1)
    local frame = player.gui.screen.tank_squads_veterans
    assert(frame.body.summary.visible == false and frame.body.pane.list.division_1.special == nil)
  end)

  test('veterans window: every kind has its GUI strings', function()
    local text = io.open('locale/en/tank-squads.cfg'):read('*a')
    for _, key in ipairs({'veterans-kind-electric', 'veterans-kind-nuclear', 'veterans-kind-electric-help',
        'veterans-kind-nuclear-help', 'veterans-division-special', 'veterans-special'}) do
      assert(text:find('\n' .. key:gsub('%-', '%%-') .. '='), 'missing ' .. key)
    end
  end)
end
