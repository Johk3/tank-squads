-- Ring garrison: divisions that hold a ring. A garrison division patrols
-- (patrol.lua) with posts dealt here instead of a route: a quarter of the
-- ring's garrison soldiers stand evenly round it as pickets, the rest by
-- the enemies near each sector, one hold point each, 9 tiles inside the
-- wall. Posts go out in contiguous blocks, one per division, so each
-- division holds one stretch. Sector weights are read one sector per sweep
-- slice, every PERIOD ticks.
--
-- ring.garrison = {divisions[key] = {key, player_index, n, count, mean,
--   signature}, weights[sector], alloc[sector], pending, next, due,
--   alarms[sector]}
local names = require('scripts.names')
local divisions = require('scripts.divisions')
local patrol = require('scripts.patrol')
local combat = require('scripts.combat')
local assault = require('scripts.assault')
local retreat = require('scripts.retreat')
local cover = require('scripts.cover')
local shredders = require('scripts.shredders')
local loans = require('scripts.engineers.loans')
local geometry = require('scripts.engineers.rings.geometry')
local rings = require('scripts.engineers.rings.rings')

local M = {}

M.PERIOD = 30 * 60
M.RADIUS = 200
M.WEIGHTS = {['unit-spawner'] = 5, turret = 2, unit = 1}
-- The wall alarm: at most one per sector every ALARM_TICKS. Garrison
-- soldiers within REACH answer, nearest first: one per
-- ENEMIES_PER_RESPONDER enemy units within HELP_RADIUS of the wall, at
-- least MIN_RESPONDERS.
M.ALARM_TICKS = 5 * 60
M.REACH = 150
M.HELP_RADIUS = 24
M.MIN_RESPONDERS = 3
M.ENEMIES_PER_RESPONDER = 2

-- Set by control.lua: garrisons came or went, so the wall damage filter
-- changes with them.
M.on_change = nil

-- Soldiers per sector. A quarter are pickets spread evenly round the ring;
-- the rest go by weight, largest remainder first (ties to the lower
-- sector). With no weight anywhere everyone is spread evenly.
function M.allocate(weights, total)
  local m, counts = #weights, {}
  for j = 1, m do counts[j] = 0 end
  if m == 0 or total <= 0 then return counts end
  local sum = 0
  for j = 1, m do sum = sum + weights[j] end
  local pickets = sum > 0 and math.floor(total / 4) or total
  for k = 1, pickets do
    local j = math.floor((k - 0.5) * m / pickets) + 1
    counts[j] = counts[j] + 1
  end
  local rest = total - pickets
  if rest > 0 then
    local shares, given = {}, 0
    for j = 1, m do
      local exact = rest * weights[j] / sum
      local whole = math.floor(exact)
      counts[j], given = counts[j] + whole, given + whole
      shares[j] = {j = j, r = exact - whole}
    end
    table.sort(shares, function(a, b)
      if a.r ~= b.r then return a.r > b.r end
      return a.j < b.j
    end)
    for k = 1, rest - given do counts[shares[k].j] = counts[shares[k].j] + 1 end
  end
  return counts
end

-- Hold points for the counts, sector by sector round the ring, spread
-- evenly along each sector.
function M.points(ring, counts)
  local out = {}
  for j, c in ipairs(counts) do
    if c > 0 then
      local seg = geometry.segment(ring, j)
      local span = seg.hi - seg.lo + (ring.shape == 'circle' and 0 or 1)
      for k = 1, c do
        out[#out + 1] = geometry.to_position(ring, seg.side, seg.lo + span * (k - 0.5) / c, geometry.POST_DEPTH)
      end
    end
  end
  return out
end

-- Cuts the points into contiguous blocks, one per division, divisions in
-- the order their soldiers stand round the ring.
function M.blocks(points, list)
  table.sort(list, function(a, b)
    if a.mean ~= b.mean then return a.mean < b.mean end
    return a.key < b.key
  end)
  local out, first = {}, 0
  for _, d in ipairs(list) do
    local block = {}
    for k = 1, d.count or 0 do block[k] = points[first + k] end
    out[d.key] = block
    first = first + (d.count or 0)
  end
  return out
end

function M.state(ring)
  ring.garrison = ring.garrison or {divisions = {}, weights = {}, alloc = {}, next = 1, due = 0, alarms = {}}
  return ring.garrison
end

-- The ring's garrison divisions that still hold it. An order that took a
-- division away left it listed; it is dropped here.
local function holding(ring, g)
  local list = {}
  for key, d in pairs(g.divisions) do
    local st = storage.divisions and storage.divisions[d.player_index]
    local record = st and st.slots[d.n]
    local r = record and record.mode == 'patrol' and record.patrol
    if r and r.garrison == ring.key then list[#list + 1] = d else g.divisions[key] = nil end
  end
  return list
end

-- Every garrison division of the ring deals its posts again next sweep.
function M.mark_all(ring, g)
  for _, d in ipairs(holding(ring, g)) do
    divisions.record(d.player_index, d.n).patrol.dirty = true
  end
end

-- The ring's posts, cut into one block per division.
function M.deal(ring, g)
  local list, total = holding(ring, g), 0
  for _, d in ipairs(list) do total = total + (d.count or 0) end
  local weights = {}
  for j = 1, ring.count do weights[j] = g.weights[j] or 0 end
  g.alloc = M.allocate(weights, total)
  return M.blocks(M.points(ring, g.alloc), list)
end

local function signature(block)
  local first = block and block[1]
  return #(block or {}) .. ':' .. (first and (first.x .. ',' .. first.y) or '')
end

-- patrol.garrison_layout: this division's posts. Other divisions of the
-- ring whose block moved deal their posts again.
function M.layout(player_index, n, r, keyed)
  local ring = rings.by_key(r.garrison)
  if not ring or (ring.state ~= 'building' and ring.state ~= 'built') then
    return {posts = {}, counts = {0}, centre = {x = 0, y = 0}, around = true}
  end
  local g = M.state(ring)
  local key = player_index .. ':' .. n
  local d = g.divisions[key] or {key = key, player_index = player_index, n = n}
  g.divisions[key] = d
  d.count = #keyed
  if #keyed > 0 then
    local sum = 0
    for _, k in ipairs(keyed) do sum = sum + geometry.order(ring, k.position.x, k.position.y) end
    d.mean = sum / #keyed
  end
  d.mean = d.mean or 0
  local blocks = M.deal(ring, g)
  local mine = blocks[key] or {}
  d.signature = signature(mine)
  for other_key, other in pairs(g.divisions) do
    if other_key ~= key then
      local sig = signature(blocks[other_key])
      if sig ~= other.signature then
        other.signature = sig
        divisions.record(other.player_index, other.n).patrol.dirty = true
      end
    end
  end
  local posts = {}
  for i, p in ipairs(mine) do posts[i] = {points = {p}, anchor = p, next = 1} end
  return {posts = posts, counts = {#posts}, centre = {x = ring.centre.x + 0.5, y = ring.centre.y + 0.5},
    around = true}
end

-- A division joined or left the ring: the others deal their posts again,
-- and the damage filter follows.
function M.changed(ring_key)
  local ring = rings.by_key(ring_key)
  if ring and ring.garrison then M.mark_all(ring, ring.garrison) end
  if M.on_change then M.on_change() end
end

local function halt(player_index, n)
  for _, soldier in ipairs(divisions.get(player_index, n)) do
    combat.set_command(soldier, {type = defines.command.stop, distraction = defines.distraction.by_enemy})
  end
end

-- Puts division n of the player on ring number ring_n of the player's
-- force, or with nil takes it off (it stops where it is). False for a bad
-- number, an empty division or a ring not standing.
function M.set(player_index, n, ring_n)
  if type(n) ~= 'number' or n % 1 ~= 0 or n < 1 or n > names.max_division then return false end
  local player = game.get_player(player_index)
  if not player then return false end
  local record = divisions.record(player_index, n)
  local current = record.mode == 'patrol' and record.patrol and record.patrol.garrison
  if not ring_n then
    if not current then return true end
    patrol.clear(player_index, n)
    record.mode = 'idle'
    halt(player_index, n)
    M.changed(current)
    return true
  end
  local fs = rings.peek(player.force_index)
  local ring = fs and fs.slots[ring_n]
  if not ring or (ring.state ~= 'building' and ring.state ~= 'built') then return false end
  if current == ring.key then return true end
  if #divisions.get(player_index, n) == 0 then return false end
  local key = player_index .. ':' .. n
  M.state(ring).divisions[key] = {key = key, player_index = player_index, n = n, count = 0, mean = 0}
  patrol.start_garrison(player_index, n, ring.key, ring.surface_index)
  if current then M.changed(current) end
  M.changed(ring.key)
  return true
end

-- rings.on_teardown: the ring's garrison stops where it stands.
function M.release_ring(ring)
  local g = ring.garrison
  if not g then return end
  for _, d in ipairs(holding(ring, g)) do
    patrol.clear(d.player_index, d.n)
    divisions.record(d.player_index, d.n).mode = 'idle'
    halt(d.player_index, d.n)
  end
  ring.garrison = nil
  if M.on_change then M.on_change() end
end

-- True while any ring has a garrison division.
function M.active()
  local s = storage.engineers
  for _, fs in pairs(s and s.rings or {}) do
    for _, ring in pairs(fs.slots) do
      if ring.garrison and next(ring.garrison.divisions) then return true end
    end
  end
  return false
end

-- Reads one sector's enemies within RADIUS of its midpoint. After the last
-- sector the weights take effect, and the posts are dealt again when a
-- sector's share changed.
function M.weigh(ring, g, tick)
  local j = g.next or 1
  local seg = geometry.segment(ring, j)
  local surface, force = game.surfaces[ring.surface_index], game.forces[ring.force_index]
  local enemies = assault.enemy_forces(force)
  local weight = 0
  if #enemies > 0 then
    local p = geometry.to_position(ring, seg.side, (seg.lo + seg.hi) / 2, 0)
    for kind, w in pairs(M.WEIGHTS) do
      weight = weight + w * surface.count_entities_filtered{position = p, radius = M.RADIUS, type = kind, force = enemies}
    end
  end
  g.pending = g.pending or {}
  g.pending[j] = weight
  if j < ring.count then
    g.next = j + 1
    return
  end
  g.next, g.due, g.weights, g.pending = 1, tick + M.PERIOD, g.pending, nil
  local total = 0
  for _, d in ipairs(holding(ring, g)) do total = total + (d.count or 0) end
  local weights = {}
  for k = 1, ring.count do weights[k] = g.weights[k] or 0 end
  local alloc = M.allocate(weights, total)
  for k = 1, ring.count do
    if alloc[k] ~= (g.alloc[k] or 0) then
      M.mark_all(ring, g)
      return
    end
  end
end

-- Each sweep slice (all when phase is nil): garrisoned rings read one
-- more sector when due. Once per second a ring that lost a division deals
-- its posts again, and the damage filter is checked: a deal or an alarm
-- may have dropped the last division from its list unseen.
function M.tick(phase)
  local s = storage.engineers
  if not (s and s.rings) then return end
  local tick, second = game.tick, phase == nil or phase == 0
  for _, fs in pairs(s.rings) do
    for _, ring in pairs(fs.slots) do
      local g = ring.garrison
      if g and next(g.divisions) then
        if second then
          local before = 0
          for _ in pairs(g.divisions) do before = before + 1 end
          if #holding(ring, g) < before then M.mark_all(ring, g) end
        end
        if tick >= g.due then M.weigh(ring, g, tick) end
      end
    end
  end
  if second and M.on_change then M.on_change() end
end

-- Sends the nearest free garrison soldiers of the ring to the wall. They
-- are patrol responders: each takes up its post again when its attack
-- completes. Each division that sent someone also calls its shredders.
function M.respond(ring, g, wall, tick)
  local p, surface_index = wall.position, wall.surface_index
  local reach, candidates = M.REACH * M.REACH, {}
  for _, d in ipairs(holding(ring, g)) do
    local r = divisions.record(d.player_index, d.n).patrol
    if r.posts then
      for _, soldier in ipairs(divisions.cached(d.player_index, d.n)) do
        local id = soldier.unit_number
        local answered = r.responders and r.responders[id]
        if soldier.valid and r.posts[id] and soldier.surface_index == surface_index and soldier.name ~= names.headquarters
            and not combat.fighting(id) and not (answered and tick - answered < patrol.RESPONSE_TICKS)
            and not retreat.is_away(r, id) and not cover.held(id) and not loans.on_loan(id) then
          local dx, dy = soldier.position.x - p.x, soldier.position.y - p.y
          local dist = dx * dx + dy * dy
          if dist <= reach then candidates[#candidates + 1] = {soldier = soldier, id = id, d = dist, r = r, division = d} end
        end
      end
    end
  end
  if not candidates[1] then return end
  local radius = M.HELP_RADIUS
  local enemies = #wall.surface.find_units{area = {{p.x - radius, p.y - radius}, {p.x + radius, p.y + radius}},
    force = wall.force, condition = 'enemy'}
  local wanted = math.max(M.MIN_RESPONDERS, math.ceil(enemies / M.ENEMIES_PER_RESPONDER))
  table.sort(candidates, function(a, b)
    if a.d ~= b.d then return a.d < b.d end
    return a.id < b.id
  end)
  local called = {}
  for i = 1, math.min(wanted, #candidates) do
    local c = candidates[i]
    c.r.responders = c.r.responders or {}
    c.r.responders[c.id] = tick
    if c.r.retry then c.r.retry[c.id] = nil end
    combat.set_command(c.soldier, {type = defines.command.attack_area, destination = {x = p.x, y = p.y},
      radius = radius, distraction = defines.distraction.by_enemy})
    if not called[c.division.key] then
      called[c.division.key] = true
      shredders.patrol_alarm(c.division.player_index, c.division.n, wall)
    end
  end
end

-- A wall or gate was hit. An enemy hit on the band of a garrisoned ring
-- raises that sector's alarm. True for every wall and gate, so the other
-- damage handlers never see them.
function M.on_wall_damaged(event)
  local wall = event.entity
  if not (wall and wall.valid) then return false end
  if wall.type ~= 'wall' and wall.type ~= 'gate' then return false end
  local fs = rings.peek(wall.force_index)
  local cause = event.cause
  if not (fs and cause and cause.valid) then return true end
  local force = wall.force
  if cause.force == force or not force.is_enemy(cause.force) then return true end
  local p, tick = wall.position, game.tick
  for _, ring in pairs(fs.slots) do
    local g = ring.garrison
    if g and next(g.divisions) and ring.surface_index == wall.surface_index and geometry.in_band(ring, p.x, p.y) then
      local side, along = geometry.to_frame(ring, p.x, p.y)
      local j = geometry.segment_of(ring, side, along)
      if (g.alarms[j] or 0) <= tick then
        g.alarms[j] = tick + M.ALARM_TICKS
        M.respond(ring, g, wall, tick)
      end
      return true
    end
  end
  return true
end

rings.on_teardown = M.release_ring

return M
