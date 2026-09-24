return function(ctx)
  local test, soldier, building = ctx.test, ctx.soldier, ctx.building
  local divisions = require('scripts.divisions')
  local scout = require('scripts.scout')
  local escort = require('scripts.escort')
  local patrol = require('scripts.patrol')
  local barracks = require('scripts.barracks')

  test('ownership lookup follows replacement, cross-player transfer and cleanup', function()
    local a,b = soldier(),soldier()
    divisions.assign(1,1,{a,b})
    local p,n,record = divisions.owner(a.unit_number)
    assert(p==1 and n==1 and record==divisions.record(1,1))
    divisions.assign(1,1,{b})
    assert(divisions.owner(a.unit_number)==nil, 'replaced member still indexed')
    game.players[2]={force=game.players[1].force}
    divisions.assign(2,3,{b})
    p,n=divisions.owner(b.unit_number)
    assert(p==2 and n==3, 'transfer retained old owner')
    divisions.clear_player(2)
    assert(divisions.owner(b.unit_number)==nil, 'removed player still owns unit')
    divisions.assign(1,2,{a})
    a.force='enemy'
    divisions.get(1,2)
    assert(divisions.owner(a.unit_number)==nil, 'force validation left stale ownership')
  end)

  test('ownership lookup includes recruits and excludes deaths', function()
    local producer,output=building()
    assert(barracks.configure(producer,1,4,1))
    output['tank-squad-recruit-1']=1
    barracks.tick()
    local member=divisions.get(1,4)[1]
    local p,n=divisions.owner(member.unit_number)
    assert(p==1 and n==4, 'new recruit missing from index')
    divisions.forget(member.unit_number)
    assert(divisions.owner(member.unit_number)==nil, 'dead recruit still indexed')
  end)

  test('a recruit burst resolves the linked roster once per sweep', function()
    local members={}
    for i=1,5 do members[i]=soldier() end
    divisions.assign(1,4,members)
    local outputs={}
    for i=1,3 do
      local producer,output=building()
      assert(barracks.configure(producer,1,4,10))
      output['tank-squad-recruit-1']=1
      outputs[i]=output
    end
    local lookups,lookup=0,game.get_entity_by_unit_number
    game.get_entity_by_unit_number=function(id) lookups=lookups+1; return lookup(id) end
    game.tick=60
    barracks.tick()
    game.get_entity_by_unit_number=lookup
    assert(lookups==5, 'roster resolved '..lookups..' entities for 3 recruits')
    local cached=divisions.cached(1,4)
    assert(#cached==8, 'recruits missing from the same-tick roster')
    for _,e in ipairs(cached) do
      assert(divisions.record(1,4).render.rings[e.unit_number], 'recruit has no selection ring')
    end
    game.tick=120
    assert(#divisions.get(1,4)==8, 'next sweep lost a recruit')
  end)

  test('ownership lookup recovers old saves and survives module reload', function()
    local a,b=soldier(),soldier()
    divisions.assign(1,2,{a,b})
    storage.unit_divisions=nil
    assert(divisions.owner(a.unit_number)==1, 'legacy membership not recovered')
    local old=package.loaded['scripts.divisions']
    package.loaded['scripts.divisions']=nil
    local reloaded=require('scripts.divisions')
    package.loaded['scripts.divisions']=old
    local p,n=reloaded.owner(b.unit_number)
    assert(p==1 and n==2, 'saved lookup lost on reload')
    divisions.record(1,1).members={a.unit_number}
    divisions.reconcile_ownership()
    p,n=divisions.owner(a.unit_number)
    assert(p==1 and n==1, 'upgrade did not index the reconciled owner')
    assert(#divisions.record(1,2).members==1)
  end)

  test('completion routing does not enumerate unrelated rosters', function()
    local a,b=soldier(),soldier()
    divisions.assign(1,1,{a})
    divisions.assign(1,2,{b})
    local first,second=divisions.record(1,1),divisions.record(1,2)
    first.mode,first.scout='scout',{target={x=1,y=1}}
    second.mode,second.scout='scout',{target={x=2,y=2}}
    for _,record in ipairs({first,second}) do
      setmetatable(record.members,{__pairs=function() error('completion scanned a roster') end})
    end
    assert(not scout.on_command_completed(999999,defines.behavior_result.success))
    assert(scout.on_command_completed(a.unit_number,defines.behavior_result.success))
    assert(first.scout.target==nil and second.scout.target.x==2)
    first.mode,first.escort='escort',{leg={leader=a.unit_number,command={},expires=100}}
    local slots=storage.divisions[1].slots
    setmetatable(slots,{__pairs=function() error('completion scanned divisions') end})
    assert(not escort.on_command_completed(999999,defines.behavior_result.success))
    assert(escort.on_command_completed(a.unit_number,defines.behavior_result.success))
    assert(first.escort.leg==nil)
    assert(patrol.advance(999999)==nil)
  end)
end
