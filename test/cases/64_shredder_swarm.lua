local t = storage.shredder_swarm_case
if not t then
  local s = game.surfaces['shredder-swarm'] or game.create_surface('shredder-swarm', {width = 192, height = 128, autoplace_controls = {}})
  s.request_to_generate_chunks({0, 0}, 4)
  s.force_generate_chunk_requests()
  local tiles = {}
  for x = -40, 90 do for y = -30, 30 do tiles[#tiles + 1] = {name = 'grass-1', position = {x, y}} end end
  s.set_tiles(tiles)
  for _, e in pairs(s.find_entities()) do if e.type ~= 'character' then e.destroy{raise_destroy = true} end end
  local f = game.forces['shredder-swarm'] or game.create_force('shredder-swarm')
  --[[ A marching group of 20 biters at x = 0 and a gathering one of 20 at x = 60. ]]
  local function band(x)
    local group = s.create_unit_group{position = {x, 0}, force = 'enemy'}
    for i = 1, 20 do
      local p = s.find_non_colliding_position('small-biter', {x + (i % 5) * 2, math.floor(i / 5) * 2}, 10, 0.5)
      group.add_member(assert(s.create_entity{name = 'small-biter', position = p, force = 'enemy'}))
    end
    return group
  end
  local marching, gathering = band(0), band(60)
  marching.set_command{type = defines.command.go_to_location, destination = {-35, 0}, radius = 2,
    distraction = defines.distraction.none}
  marching.start_moving()
  storage.shredder_swarm_case = {surface = s, force = f.name, marching = marching, gathering = gathering,
    started = game.tick}
  return 'WAIT: group moving'
end
local ok, result = pcall(function()
  if game.tick - t.started < 30 then return 'WAIT: group moving' end
  local centre = t.marching.position
  local target = remote.call('tank-squads', 'shredders_swarm', t.surface.index, centre, t.force)
  assert(target, 'a marching swarm was not seen (group state ' .. tostring(t.marching.state) .. ')')
  local member = false
  for _, e in pairs(t.marching.members) do if e.unit_number == target then member = true end end
  assert(member, 'the target is not in the swarm')
  --[[ Both groups are within SWARM_RADIUS of each other: the marching one
  goes before the gathering one is checked on its own. ]]
  for _, e in pairs(t.marching.members) do e.destroy() end
  assert(remote.call('tank-squads', 'shredders_swarm', t.surface.index, {x = 64, y = 4}, t.force) == nil,
    'a gathering group counted as a swarm (group state ' .. tostring(t.gathering.state) .. ')')
  return 'marching swarm seen, gathering group ignored'
end)
if ok and type(result) == 'string' and result:find('^WAIT') then return result end
for _, e in pairs(t.surface.find_entities_filtered{force = 'enemy'}) do e.destroy() end
storage.shredder_swarm_case = nil
if not ok then error(result) end
return 'PASS: ' .. result
