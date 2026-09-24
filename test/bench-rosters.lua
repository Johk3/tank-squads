local engine_game, engine_rendering = game, rendering
local old_divisions, old_barracks, old_index = storage.divisions, storage.barracks, storage.unit_divisions
local created, drawings = {}, {}
local ok, err = pcall(function()
  storage.divisions, storage.barracks, storage.unit_divisions = {}, {}, nil
  local s = game.surfaces[1]
  s.request_to_generate_chunks({0,0}, 5)
  s.force_generate_chunk_requests()
  local owner, force = 999994, game.forces.player
  local player = {index=owner, force=force, surface=s}
  local lookups = 0
  game = setmetatable({tick=engine_game.tick, get_player=function(n)
    if n == owner then return player end
    return engine_game.get_player(n)
  end, get_entity_by_unit_number=function(id)
    lookups=lookups+1
    return engine_game.get_entity_by_unit_number(id)
  end}, {__index=function(_, key) return engine_game[key] end})
  rendering = {}
  for _, method in ipairs({'draw_circle','draw_text','draw_line','draw_sprite','draw_animation'}) do
    rendering[method] = function(args)
      args.players=nil
      local object=engine_rendering[method](args)
      drawings[#drawings+1]=object
      return object
    end
  end
  for i=1,1000 do
    created[#created+1]=assert(s.create_entity{name='tank-squad-soldier-1',
      position={-60+(i%40)*3,-60+math.floor(i/40)*3}, force=force})
  end
  assert(remote.call('tank-squads','division_assign',owner,1,
    {left_top={x=-65,y=-65},right_bottom={x=65,y=20}})==1000)
  for i=1,20 do
    local b=assert(s.create_entity{name='tank-squad-barracks',position={-100+i*5,100},force=force,raise_built=true})
    created[#created+1]=b
    assert(remote.call('tank-squads','barracks_configure',owner,b,1,1000))
  end
  lookups=0
  game.tick=game.tick+60
  remote.call('tank-squads','tick')
  rcon.print('Roster lookups per full linked sweep (20 barracks / 1000 soldiers): '..lookups)
  game.get_entity_by_unit_number=nil
  for run=1,3 do
    local p=engine_game.create_profiler()
    for i=1,30 do
      game.tick=game.tick+60
      remote.call('tank-squads','tick')
    end
    p.stop(); p.divide(30)
    rcon.print({'','Barracks sweep, run ',run,': ',p})
  end
  -- Synthetic saved rosters isolate dispatch cost. No entity access or
  -- pathfinding occurs during these unrelated completion callbacks.
  storage.divisions={[owner]={selected=1,slots={}}}
  storage.unit_divisions=nil
  for n=1,9 do
    local members={}
    for i=1,1000 do members[i]=n*10000+i end
    storage.divisions[owner].slots[n]={members=members,mode='scout',scout={}}
  end
  local handler=script.get_event_handler(defines.events.on_ai_command_completed)
  local event={unit_number=99999999,result=defines.behavior_result.success,tick=game.tick}
  handler(event)
  for run=1,3 do
    local p=engine_game.create_profiler()
    for i=1,1000 do handler(event) end
    p.stop()
    rcon.print({'','1000 unrelated completions / 9000 scouts, run ',run,': ',p})
  end
end)
for _,e in ipairs(created) do if e.valid then e.destroy() end end
for _,object in ipairs(drawings) do if object.valid then object.destroy() end end
game, rendering = engine_game, engine_rendering
storage.divisions, storage.barracks, storage.unit_divisions = old_divisions, old_barracks, old_index
if not ok then error(err) end
return 'PASS roster benchmarks completed'
