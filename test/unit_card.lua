return function(ctx)
  local test, soldier = ctx.test, ctx.soldier
  local names = require('scripts.names')
  local veterans = require('scripts.veterans')
  local divisions = require('scripts.divisions')
  local card = require('scripts.unit_card')

  local function hover(entity)
    ctx.players()[1].selected = entity
    card.on_selected{player_index = 1}
    return ctx.players()[1].gui.screen.tank_squads_unit_card
  end

  test('card: hovering a soldier shows its name, rank, XP, kills and division', function()
    local e = soldier()
    local record = veterans.register(e)
    record.xp, record.rank, record.kills = 150, 1, 12
    divisions.assign(1, 7, {e})
    local frame = assert(hover(e), 'no card')
    assert(frame.ignored_by_interaction, 'card takes the cursor')
    assert(frame.unit_name.caption[2][1] == 'tank-squads.name-adjective-' .. record.adjective)
    assert(frame.unit_kind.caption[1] == 'entity-name.' .. e.name)
    assert(frame.rank_row.badge.sprite == 'tank-squad-rank-1' and frame.rank_row.title.caption[1] == 'tank-squads.rank-1')
    assert(math.abs(frame.xp_bar.value - 0.5) < 1e-9, 'XP bar ' .. frame.xp_bar.value)
    assert(frame.xp_text.caption[1] == 'tank-squads.card-xp' and frame.xp_text.caption[3] == 250)
    assert(frame.kill_count.caption[2] == 12)
    assert(frame.division_row.visible and frame.division_row.insignia.sprite == 'tank-squad-insignia-7')
    record.kills = 13
    card.refresh()
    assert(frame.kill_count.caption[2] == 13, 'sweep did not refresh the card')
    record.xp, record.rank = 5000, 3
    card.refresh()
    assert(frame.xp_bar.value == 1 and frame.xp_text.caption[1] == 'tank-squads.card-xp-top')
  end)

  test('card: leaving the unit, a dead unit or a removed player closes it', function()
    local e = soldier()
    veterans.register(e)
    local frame = hover(e)
    hover(nil)
    assert(not frame.valid and not (storage.unit_card and storage.unit_card[1]), 'card stayed')
    frame = hover(e)
    assert(frame.valid, 'card did not reopen')
    e.valid = false
    card.refresh()
    assert(not frame.valid, 'card of a dead unit stayed')
    local other = soldier()
    veterans.register(other)
    frame = hover(other)
    card.clear(1)
    assert(not frame.valid and not storage.unit_card[1])
  end)

  test('card: foreign units open nothing and the headquarters hides rank rows', function()
    local foreign = soldier('enemy')
    veterans.register(foreign)
    assert(hover(foreign) == nil, 'card for another force')
    local hq = soldier()
    hq.name = names.headquarters
    veterans.register(hq)
    local frame = hover(hq)
    assert(frame and not frame.rank_row.visible and not frame.xp_bar.visible and not frame.kill_count.visible)
    assert(not frame.division_row.visible, 'undivided unit shows a division')
  end)

  test('card: control opens it on hover and refreshes it every second', function()
    dofile('control.lua')
    local e = soldier()
    veterans.register(e)
    ctx.players()[1].selected = e
    ctx.handlers().on_selected_entity_changed{player_index = 1}
    local frame = assert(ctx.players()[1].gui.screen.tank_squads_unit_card, 'control did not route hover')
    e.valid = false
    local sweep = ctx.handlers().nth_tick
    sweep.handler{tick = 0}
    assert(not frame.valid, 'phase 0 sweep did not refresh the card')
  end)
end
