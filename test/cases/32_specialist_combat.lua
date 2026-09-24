local t = storage.specialist_combat_test
if not t then
  local s = game.surfaces['specialist-combat'] or game.create_surface('specialist-combat', {width=128,height=128,autoplace_controls={}})
  s.request_to_generate_chunks({0,0}, 3)
  s.force_generate_chunk_requests()
  local tiles = {}
  for x=-20,55 do for y=-20,35 do tiles[#tiles+1]={name='grass-1',position={x,y}} end end
  s.set_tiles(tiles)
  for _, e in pairs(s.find_entities()) do if e.type ~= 'character' then e.destroy{raise_destroy=true} end end
  local f = game.forces['specialist-combat'] or game.create_force('specialist-combat')
  f.set_ammo_damage_modifier('cannon-shell', 0)
  f.set_ammo_damage_modifier('flamethrower', 0)
  local siege = assert(s.create_entity{name='tank-squad-siege',position={0,0},force=f,raise_built=true})
  local flame = assert(s.create_entity{name='tank-squad-flame',position={0,20},force=f,raise_built=true})
  local far = assert(s.create_entity{name='rocket-silo',position={48,0},force='enemy'})
  local near = assert(s.create_entity{name='rocket-silo',position={10,20},force='enemy'})
  local friend = assert(s.create_entity{name='tank-squad-soldier-1',position={8,20},force=f,raise_built=true})
  friend.active = false
  siege.commandable.set_command{type=defines.command.attack,target=far,distraction=defines.distraction.none}
  flame.commandable.set_command{type=defines.command.attack,target=near,distraction=defines.distraction.none}
  storage.specialist_combat_test = {siege=siege,flame=flame,far=far,near=near,friend=friend,
    far_health=far.health,near_health=near.health,friend_health=friend.health,started=game.tick}
  return 'WAIT: specialist native combat'
end
if game.tick-t.started < 90 then return 'WAIT: specialist native combat' end
local ok, result = pcall(function()
assert(t.far.valid and t.far.health < t.far_health, 'cannon did not damage distant target')
assert(t.near.valid and t.near.health < t.near_health, 'flame stream did not damage target')
assert(math.abs(t.siege.position.x) < 3, 'siege tank drove into cannon range target')
assert(t.friend.valid and t.friend.health == t.friend_health, 'flame hurt friendly division member')
for _, a in ipairs({t.siege,t.flame}) do
  local record = storage.weapons[a.unit_number]
  assert(record and record.target and not record.gun.use_target_orientation,
    'specialist gun did not aim: '..a.name..' '..serpent.line{last=record and record.last_shot,
      target=record and record.target,timeout=record and record.aim_timeout,tick=game.tick,started=t.started})
end
assert(#t.flame.surface.find_entities_filtered{type='fire'} == 0, 'flame leaves persistent ground fire')
return (t.far_health-t.far.health) .. ' cannon / ' .. (t.near_health-t.near.health) .. ' flame'
end)
for _, e in ipairs({t.siege,t.flame,t.far,t.near,t.friend}) do if e.valid then e.destroy{raise_destroy=true} end end
storage.specialist_combat_test = nil
if not ok then error(result) end
return 'PASS: native specialist damage, range, aim and friendly safety: ' .. result
