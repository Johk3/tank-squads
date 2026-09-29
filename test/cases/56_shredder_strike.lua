local t = storage.shredder_strike_case
if not t then
  local s = game.surfaces['shredder-strike'] or game.create_surface('shredder-strike', {width = 192, height = 128, autoplace_controls = {}})
  s.request_to_generate_chunks({0, 0}, 4)
  s.force_generate_chunk_requests()
  local tiles = {}
  for x = -20, 90 do for y = -30, 30 do tiles[#tiles + 1] = {name = 'grass-1', position = {x, y}} end end
  s.set_tiles(tiles)
  for _, e in pairs(s.find_entities()) do if e.type ~= 'character' then e.destroy{raise_destroy = true} end end
  local f = game.forces['shredder-strike'] or game.create_force('shredder-strike')
  local shredder = assert(s.create_entity{name = 'tank-squad-shredder', position = {0, 0}, force = f, raise_built = true})
  local target = assert(s.create_entity{name = 'medium-worm-turret', position = {60, 0}, force = 'enemy'})
  target.active = false
  local near = assert(s.create_entity{name = 'small-biter', position = {63, 4}, force = 'enemy'})
  near.active = false
  local friend = assert(s.create_entity{name = 'tank-squad-soldier-1', position = {58, -3}, force = f, raise_built = true})
  friend.active = false
  local sent = remote.call('tank-squads', 'shredders_strike', {shredder.unit_number}, s.index, {x = 60, y = 0}, f.name, 40)
  assert(sent == 1, 'strike sent ' .. tostring(sent) .. ' shredders')
  storage.shredder_strike_case = {surface = s, target = target, near = near, friend = friend,
    friend_health = friend.health, started = game.tick}
  return 'WAIT: shredder charging'
end
local ok, result = pcall(function()
  local left = t.surface.count_entities_filtered{name = {'tank-squad-shredder', 'tank-squad-shredder-charging'}}
  if (t.target.valid or left > 0) and game.tick - t.started < 300 then return 'WAIT: shredder charging' end
  --[[ The shrapnel bursts when the fuse lands, about 8 ticks after contact. ]]
  t.crashed = t.crashed or game.tick
  if game.tick - t.crashed < 30 then return 'WAIT: shrapnel flying' end
  assert(not t.target.valid, 'the crash did not destroy the worm')
  assert(not t.near.valid, 'shrapnel did not kill the biter beside the worm')
  assert(t.friend.valid and t.friend.health == t.friend_health, 'shrapnel hurt a friend')
  assert(left == 0, 'the shredder survived its crash')
  return 'crashed 60 tiles away in ' .. (game.tick - t.started) .. ' ticks'
end)
if ok and type(result) == 'string' and result:find('^WAIT') then return result end
for _, key in ipairs({'target', 'near', 'friend'}) do local e = t[key]; if e and e.valid then e.destroy{raise_destroy = true} end end
storage.shredder_strike_case = nil
if not ok then error(result) end
return 'PASS: ' .. result
