-- Cover for a division's veterans. A soldier of rank Veteran or above
-- walks with two to five lower-ranked soldiers of its division at its
-- sides. Covers come only from soldiers near the veteran, so a small
-- division spread thin over a patrol route or an escort ring gives none.
-- A veteran without cover that sees a large group of enemies coming calls
-- for help: nearby soldiers of its division and its shredders attack the
-- group, and the veteran falls back behind them until the fight is over.
--
-- This module holds soldiers: covers, helpers and a veteran falling back.
-- Escorts and patrols leave a held soldier out of their formations (see
-- M.free), and its completions stop here. Letting go of a soldier gives it
-- its division's job again, the way a recruit gets it. A new job for the
-- division, a nest assault or scouting lets go of every held soldier, as
-- those give orders to the whole division.
--
-- storage.cover = {
--   divisions = {[key] = {player_index, n, vips = {[vip_id] = vip}}},
--   held = {[unit_number] = vip_id},   -- covers, helpers and falling-back veterans
--   jobs = {[key] = {mode, order, escort, patrol}}, -- the job seen last sweep
-- }
-- vip = {covers = {ids}, slots = {[id] = position}, heading = {x, y}, last = position,
--   retry = tick, call = {helpers = {ids}, point, calm, expires, idle = {[id] = true}}, calm_until = tick}
local combat = require("scripts.combat")
local divisions = require("scripts.divisions")
local geometry = require("scripts.escort_geometry")
local loans = require("scripts.engineers.loans")
local retreat = require("scripts.retreat")
local shredders = require("scripts.shredders")
local unit_names = require("scripts.unit_names")

local M = {}

-- Veteran is rank 3 (scripts/ranks.lua).
M.RANK = 3
M.MIN_COVERS, M.MAX_COVERS = 2, 5
-- Covers come from soldiers this close to the veteran. A cover still
-- following a faster veteran stays one; one that stopped further away than
-- LEASH, as when it found no path, is let go.
M.REACH = 32
M.LEASH = 64
M.AUDIT_TICKS = 5 * 60
-- How far a cover walks from the veteran's centre, and how far its spot
-- must move before the cover is sent again.
M.SPACING = 6
M.RESEND = 4
-- Sides first, then the front corners, then the rear, as angles from the
-- veteran's heading.
M.ANGLES = {math.pi / 2, -math.pi / 2, math.pi / 4, -math.pi / 4, math.pi}
-- A veteran short of covers looks for more after this long.
M.RETRY_TICKS = 5 * 60
-- A veteran without cover calls for help when this many enemy units are
-- within DANGER_RADIUS of it.
M.DANGER_RADIUS = 40
M.DANGER_COUNT = 10
-- Helpers come from this far away: soldiers of the division that are not
-- veterans, at least MIN_HELPERS or one per ENEMIES_PER_HELPER enemies.
M.HELP_REACH = 160
M.MIN_HELPERS = 3
M.ENEMIES_PER_HELPER = 2
M.HELP_RADIUS = 24
-- The veteran stops this far behind its helpers, or with no helpers this
-- far away from the enemies.
M.BEHIND = 12
M.FALLBACK = 48
-- The call ends after this many sweeps with fewer than half DANGER_COUNT
-- enemies in the fight and near the veteran, or after TIMEOUT. The veteran then calls again
-- only after COOLDOWN.
M.CALM_SWEEPS = 5
M.TIMEOUT = 60 * 60
M.COOLDOWN = 10 * 60

-- Set by control.lua to reinforcements.assign_job, which needs modules that
-- require this one.
M.assign_job = nil

local function state()
  local s = storage.cover
  if not s then
    s = {divisions = {}, held = {}, jobs = {}}
    storage.cover = s
  end
  return s
end

local function key_of(player_index, n) return player_index .. ":" .. n end

-- True while this module holds the soldier. One table read.
function M.held(unit_number)
  local s = storage.cover
  return s ~= nil and s.held[unit_number] ~= nil
end

-- The soldiers of the list that this module does not hold. Returns the
-- list itself when it holds none of them.
function M.free(members)
  local s = storage.cover
  if not (s and next(s.held)) then return members end
  local held, out = s.held, nil
  for i, e in ipairs(members) do
    if held[e.unit_number] then
      if not out then
        out = {}
        for j = 1, i - 1 do out[j] = members[j] end
      end
    elseif out then
      out[#out + 1] = e
    end
  end
  return out or members
end

local function rank_of(unit_number)
  local record = storage.veterans and storage.veterans[unit_number]
  return record and record.rank or 0
end

-- The escort or patrol state that owns the division's convoys.
local function job_state(record)
  if record.mode == "escort" then return record.escort end
  if record.mode == "patrol" then return record.patrol end
  return nil
end

-- Escorts and patrols deal their formation again on their next sweep, so a
-- soldier taken out or given back changes it once.
local function reform(record)
  local job = job_state(record)
  if record.mode == "escort" and job then job.members_dirty = true end
  if record.mode == "patrol" and job then job.dirty = true end
end

local function remove(list, id)
  for i = #list, 1, -1 do
    if list[i] == id then table.remove(list, i) end
  end
end

-- Lets go of a soldier. With `record`, a soldier still in that division and
-- not away healing gets its job back.
local function let_go(s, id, record)
  s.held[id] = nil
  if not (record and M.assign_job) then return end
  local _, _, owner = divisions.owner(id)
  if owner ~= record then return end
  local job = job_state(record)
  if job and retreat.is_away(job, id) then return end
  local soldier = game.get_entity_by_unit_number(id)
  if soldier and soldier.valid then M.assign_job(record, soldier) end
end

local function end_call(s, vip_id, vip, record)
  local call = vip.call
  if not call then return end
  vip.call = nil
  vip.calm_until = game.tick + M.COOLDOWN
  for _, id in ipairs(call.helpers) do
    if s.held[id] == vip_id then let_go(s, id, record) end
  end
  if s.held[vip_id] == vip_id then let_go(s, vip_id, record) end
end

local function drop_vip(s, d, vip_id, record)
  local vip = d.vips[vip_id]
  if not vip then return end
  end_call(s, vip_id, vip, record)
  for _, id in ipairs(vip.covers) do
    if s.held[id] == vip_id then let_go(s, id, record) end
  end
  d.vips[vip_id] = nil
end

-- Lets go of every soldier held for the division. With `record`, each one
-- gets the division's job back; without, it keeps the order it has.
local function release_division(s, key, record)
  local d = s.divisions[key]
  if not d then return end
  local ids = {}
  for vip_id in pairs(d.vips) do ids[#ids + 1] = vip_id end
  for _, vip_id in ipairs(ids) do drop_vip(s, d, vip_id, record) end
  s.divisions[key] = nil
end

-- The job a division runs, as its identity: a new order, escort or patrol
-- is a new table.
local function job_changed(s, key, player_index, n, record)
  local seen, order, escort, patrol = s.jobs[key], record.order, record.escort, record.patrol
  local changed = seen ~= nil and (seen.mode ~= record.mode or seen.order ~= order or seen.escort ~= escort
    or seen.patrol ~= patrol)
  if not seen or changed then
    s.jobs[key] = {player_index = player_index, n = n, mode = record.mode, order = order, escort = escort,
      patrol = patrol}
  end
  return changed
end

-- A nest assault, scouting or an engineer escort commands the whole division.
local function whole_division(record)
  if record.mode == "scout" or record.mode == "engineer" then return true end
  if record.order and record.order.assault then return true end
  return record.mode == "escort" and record.escort ~= nil and record.escort.assault ~= nil
end

local function unit_vector(dx, dy)
  local length = math.sqrt(dx * dx + dy * dy)
  if length < 1e-6 then return nil end
  return {x = dx / length, y = dy / length}
end

-- The spot of the i-th cover around the veteran, whose heading is `base`.
local function spot(position, base, i)
  local angle = base + M.ANGLES[i]
  return {x = position.x + M.SPACING * math.cos(angle), y = position.y + M.SPACING * math.sin(angle)}
end

local function send(soldier, destination, radius, distraction)
  combat.set_command(soldier, {type = defines.command.go_to_location, destination = destination,
    radius = radius, distraction = distraction or defines.distraction.by_enemy})
end

-- Moves the covers to the veteran's sides. A cover is sent again only when
-- its spot moved RESEND tiles, or when an audit finds it finished its walk
-- away from its spot, so a veteran standing still costs no paths.
local function lead(vip, soldier, by_id, audit)
  local position = soldier.position
  local last = vip.last
  if last then
    local heading = unit_vector(position.x - last.x, position.y - last.y)
    if heading and geometry.distance_squared(position, last) >= 1 then vip.heading = heading end
  end
  vip.last = {x = position.x, y = position.y}
  local heading = vip.heading or {x = 0, y = -1}
  local base = math.atan2(heading.y, heading.x)
  vip.slots = vip.slots or {}
  local resend = M.RESEND * M.RESEND
  for i, id in ipairs(vip.covers) do
    local cover = by_id[id]
    if cover and not combat.fighting(id) then
      local target = spot(position, base, i)
      local slot = vip.slots[id]
      if not slot or geometry.distance_squared(slot, target) > resend
          or (audit and slot.done and geometry.distance_squared(cover.position, target) > resend) then
        vip.slots[id] = target
        send(cover, target, 2)
      end
    end
  end
end

-- Enemy units within DANGER_RADIUS of the position.
local function enemies_near(soldier, position)
  local r = M.DANGER_RADIUS
  local found = soldier.surface.find_units{area = {{position.x - r, position.y - r}, {position.x + r, position.y + r}},
    force = soldier.force, condition = "enemy"}
  local out, r2 = {}, r * r
  for _, e in ipairs(found) do
    local p = e.position
    if geometry.distance_squared(p, position) <= r2 then out[#out + 1] = p end
  end
  return out
end

local function announce(player_index, soldier)
  local player = game.get_player(player_index)
  local record = storage.veterans and storage.veterans[soldier.unit_number]
  if not (player and record) then return end
  player.create_local_flying_text{text = {"tank-squads.cover-call", unit_names.localised(record)},
    position = soldier.position, surface = soldier.surface}
end

-- Calls for help: the nearest soldiers of the division that are not
-- veterans, and the division's shredders, attack the enemies. The veteran
-- falls back behind the helpers, or towards the shredders' backline or
-- away from the enemies when nobody can come.
local function call(s, d, vip_id, vip, soldier, enemies, pool)
  local position = soldier.position
  local centre = geometry.centroid_points(enemies)
  local wanted = math.max(M.MIN_HELPERS, math.ceil(#enemies / M.ENEMIES_PER_HELPER))
  local reach = M.HELP_REACH * M.HELP_REACH
  local candidates = {}
  for _, e in ipairs(pool) do
    local id = e.unit_number
    if not s.held[id] and e.surface_index == soldier.surface_index then
      local distance = geometry.distance_squared(e.position, position)
      if distance <= reach then candidates[#candidates + 1] = {entity = e, id = id, d = distance} end
    end
  end
  table.sort(candidates, function(a, b)
    if a.d ~= b.d then return a.d < b.d end
    return a.id < b.id
  end)
  local helpers, points = {}, {}
  for i = 1, math.min(wanted, #candidates) do
    local c = candidates[i]
    helpers[#helpers + 1] = c.id
    points[#points + 1] = c.entity.position
    s.held[c.id] = vip_id
    combat.set_command(c.entity, {type = defines.command.attack_area, destination = centre,
      radius = M.HELP_RADIUS, distraction = defines.distraction.by_enemy})
  end
  local _, backline = shredders.call(d.player_index, d.n, soldier.surface, centre, soldier.force)
  local point
  if #points > 0 then
    local line = geometry.centroid_points(points)
    local away = unit_vector(line.x - centre.x, line.y - centre.y)
      or unit_vector(position.x - centre.x, position.y - centre.y) or {x = 0, y = 1}
    point = {x = line.x + away.x * M.BEHIND, y = line.y + away.y * M.BEHIND}
  elseif backline then
    point = backline
  else
    local away = unit_vector(position.x - centre.x, position.y - centre.y) or {x = 0, y = 1}
    point = {x = position.x + away.x * M.FALLBACK, y = position.y + away.y * M.FALLBACK}
  end
  s.held[vip_id] = vip_id
  send(soldier, point, 4, defines.distraction.none)
  vip.call = {helpers = helpers, point = point, centre = centre, calm = 0, expires = game.tick + M.TIMEOUT, idle = {}}
  announce(d.player_index, soldier)
end

-- Keeps an open call going: idle helpers attack again while the enemies
-- stay. The fight is where the enemies were last seen, which moves with
-- them, or around the veteran if they follow it. Returns true when the
-- call is over.
local function hold_call(s, vip_id, vip, soldier, by_id)
  local c = vip.call
  local enemies = enemies_near(soldier, c.centre)
  if #enemies * 2 < M.DANGER_COUNT then enemies = enemies_near(soldier, soldier.position) end
  if #enemies * 2 < M.DANGER_COUNT then
    c.calm = c.calm + 1
  else
    c.calm = 0
    c.centre = geometry.centroid_points(enemies)
  end
  if c.calm >= M.CALM_SWEEPS or game.tick >= c.expires then return true end
  for i = #c.helpers, 1, -1 do
    local id = c.helpers[i]
    local helper = by_id[id]
    if not helper or s.held[id] ~= vip_id then
      table.remove(c.helpers, i)
    elseif c.idle[id] and c.calm == 0 then
      c.idle[id] = nil
      combat.set_command(helper, {type = defines.command.attack_area, destination = c.centre,
        radius = M.HELP_RADIUS, distraction = defines.distraction.by_enemy})
    end
  end
  return false
end

-- Recruiting looks up the pool in square cells this wide, a power of two so
-- the cell of a position is exact.
local CELL = 8

-- The pool of one sweep by cell, each soldier's position and surface read
-- once. Held soldiers stay in: one let go later in the sweep is free again.
local function pool_cells(pool)
  local cells = {}
  for _, e in ipairs(pool) do
    local p = e.position
    local cx, cy = math.floor(p.x / CELL), math.floor(p.y / CELL)
    local column = cells[cx] or {}
    cells[cx] = column
    local cell = column[cy] or {}
    column[cy] = cell
    cell[#cell + 1] = {id = e.unit_number, position = p, surface_index = e.surface_index}
  end
  return cells
end

local function collect(s, cells, x, y, surface_index, position, reach, found)
  local column = cells[x]
  local cell = column and column[y]
  if not cell then return end
  for _, entry in ipairs(cell) do
    local id = entry.id
    if not s.held[id] and entry.surface_index == surface_index then
      local distance = geometry.distance_squared(entry.position, position)
      if distance <= reach then found[#found + 1] = {id = id, d = distance} end
    end
  end
end

-- The free soldiers within REACH of the position, or at least the `count`
-- nearest of them: square rings of cells outwards, until `count` stand
-- within the distance every unvisited cell is beyond, or REACH is covered.
-- The bound trails the ring by one cell to allow for rounding.
local function candidates_near(s, cells, surface_index, position, reach, count)
  local cx, cy = math.floor(position.x / CELL), math.floor(position.y / CELL)
  local found = {}
  local r = 0
  collect(s, cells, cx, cy, surface_index, position, reach, found)
  while (r - 1) * CELL < M.REACH do
    r = r + 1
    for x = cx - r, cx + r do
      collect(s, cells, x, cy - r, surface_index, position, reach, found)
      collect(s, cells, x, cy + r, surface_index, position, reach, found)
    end
    for y = cy - r + 1, cy + r - 1 do
      collect(s, cells, cx - r, y, surface_index, position, reach, found)
      collect(s, cells, cx + r, y, surface_index, position, reach, found)
    end
    local bound, inside = ((r - 1) * CELL) ^ 2, 0
    for _, c in ipairs(found) do
      if c.d <= bound then inside = inside + 1 end
    end
    if inside >= count then break end
  end
  return found
end

local function before(a, b)
  if a.d ~= b.d then return a.d < b.d end
  return a.id < b.id
end

-- The first `count` candidates, nearest first, the lower unit number on a
-- tie: the start of the sorted list, without sorting all of it.
local function nearest(candidates, count)
  local out = {}
  for _, c in ipairs(candidates) do
    local n = #out
    if n < count or before(c, out[n]) then
      if n == count then
        out[n] = nil
        n = n - 1
      end
      local i = n
      while i > 0 and before(c, out[i]) do
        out[i + 1] = out[i]
        i = i - 1
      end
      out[i + 1] = c
    end
  end
  return out
end

-- Takes free soldiers near the veteran as covers, up to `wanted`. The
-- nearest come first, the lower unit number on a tie. `lookup.pool` is the
-- sweep's pool; its cells are built on the first call.
local function recruit(s, vip_id, vip, soldier, lookup, wanted)
  lookup.cells = lookup.cells or pool_cells(lookup.pool)
  local candidates = candidates_near(s, lookup.cells, soldier.surface_index, soldier.position,
    M.REACH * M.REACH, wanted - #vip.covers)
  if #vip.covers + #candidates < M.MIN_COVERS then return end
  local chosen = nearest(candidates, wanted - #vip.covers)
  for i = 1, #chosen do
    local id = chosen[i].id
    vip.covers[#vip.covers + 1] = id
    s.held[id] = vip_id
  end
end

-- Veterans first by rank, then by XP, then by unit number.
local function by_rank(a, b)
  if a.rank ~= b.rank then return a.rank > b.rank end
  if a.xp ~= b.xp then return a.xp > b.xp end
  return a.id < b.id
end

local function sweep(s, player_index, n, record)
  local key = key_of(player_index, n)
  if job_changed(s, key, player_index, n, record) then
    -- The new job already gave every soldier its order.
    if s.divisions[key] then
      release_division(s, key, nil)
      reform(record)
    end
    return
  end
  if whole_division(record) then
    release_division(s, key, record.mode ~= "scout" and record or nil)
    return
  end
  local members = divisions.cached(player_index, n)
  local d = s.divisions[key]
  local veterans = storage.veterans or {}
  if not d then
    -- A division without veterans costs one read per soldier.
    local any = false
    for _, e in ipairs(members) do
      local veteran = veterans[e.unit_number]
      if veteran and (veteran.rank or 0) >= M.RANK then any = true; break end
    end
    if not any then return end
  end
  local job = job_state(record)
  local vips, pool, by_id = {}, {}, {}
  for _, e in ipairs(members) do
    -- The roster was validated this tick. Only soldiers have a rank; the
    -- headquarters' record has none.
    local id = e.unit_number
    local veteran = id and veterans[id]
    local rank = veteran and veteran.rank
    if rank and not (job and retreat.is_away(job, id)) and not loans.on_loan(id) then
      by_id[id] = e
      if rank >= M.RANK then
        vips[#vips + 1] = {entity = e, id = id, rank = rank, xp = veteran.xp or 0}
      else
        pool[#pool + 1] = e
      end
    end
  end
  if #vips == 0 and not d then return end
  if not d then
    d = {player_index = player_index, n = n, vips = {}}
    s.divisions[key] = d
  end
  local changed = false
  -- Veterans that left, died, went to heal or lost their rank let go of
  -- their soldiers; soldiers that left the division are simply dropped.
  local is_vip = {}
  for _, v in ipairs(vips) do is_vip[v.id] = true end
  -- Where the covers stand is read only in an audit, every AUDIT_TICKS per
  -- veteran, so a covered veteran costs one position read per sweep.
  local leash, tick, audits = M.LEASH * M.LEASH, game.tick, {}
  for vip_id, vip in pairs(d.vips) do
    if not is_vip[vip_id] then
      drop_vip(s, d, vip_id, record)
      changed = true
    elseif vip.covers[1] then
      local audit = not (vip.audit and tick < vip.audit)
      if audit then vip.audit, audits[vip_id] = tick + M.AUDIT_TICKS, true end
      local vip_entity = by_id[vip_id]
      local surface_index = audit and vip_entity.surface_index
      local position = audit and vip_entity.position
      for i = #vip.covers, 1, -1 do
        local id = vip.covers[i]
        local cover = by_id[id]
        local slot = vip.slots and vip.slots[id]
        if not cover or s.held[id] ~= vip_id or rank_of(id) >= M.RANK or (audit and (cover.surface_index ~= surface_index
            or (slot and slot.done and geometry.distance_squared(cover.position, position) > leash))) then
          table.remove(vip.covers, i)
          if vip.slots then vip.slots[id] = nil end
          if s.held[id] == vip_id then let_go(s, id, record) end
          changed = true
        end
      end
    end
  end
  table.sort(vips, by_rank)
  local share = math.min(M.MAX_COVERS, math.floor(#pool / math.max(1, #vips)))
  local lookup = {pool = pool}
  for _, v in ipairs(vips) do
    local vip = d.vips[v.id]
    if not vip then
      vip = {covers = {}}
      d.vips[v.id] = vip
    end
    if vip.call then
      if hold_call(s, v.id, vip, v.entity, by_id) then
        end_call(s, v.id, vip, record)
        changed = true
      end
    else
      if #vip.covers < share and share >= M.MIN_COVERS and not (vip.retry and tick < vip.retry) then
        local before = #vip.covers
        recruit(s, v.id, vip, v.entity, lookup, share)
        -- Short of its share, it looks again only after a while.
        if #vip.covers < share then vip.retry = tick + M.RETRY_TICKS end
        if #vip.covers ~= before then changed = true end
      end
      if #vip.covers < M.MIN_COVERS then
        -- Too few to cover: they go back to the job, and the veteran
        -- watches for danger on its own.
        for _, id in ipairs(vip.covers) do
          if s.held[id] == v.id then let_go(s, id, record) end
          changed = true
        end
        vip.covers, vip.slots = {}, nil
        if not (vip.calm_until and tick < vip.calm_until) then
          local enemies = enemies_near(v.entity, v.entity.position)
          if #enemies >= M.DANGER_COUNT then
            call(s, d, v.id, vip, v.entity, enemies, pool)
            changed = true
          end
        end
      else
        lead(vip, v.entity, by_id, audits[v.id])
      end
    end
  end
  if changed then reform(record) end
  if not next(d.vips) then s.divisions[key] = nil end
end

-- Runs in the division's own slice, right after the roster refresh and
-- before any job, so jobs see which soldiers are held. A nil phase sweeps
-- every division.
function M.tick(phase)
  local s = storage.cover
  local all = storage.divisions or {}
  if s then
    -- Divisions of a removed player, or emptied slots, let go.
    for key, d in pairs(s.divisions) do
      if divisions.in_phase(d.player_index, d.n, phase) then
        local st = all[d.player_index]
        local record = st and st.slots[d.n]
        if not record or #record.members == 0 then release_division(s, key, nil) end
      end
    end
    for key, job in pairs(s.jobs) do
      if divisions.in_phase(job.player_index, job.n, phase) then
        local st = all[job.player_index]
        if not (st and st.slots[job.n]) then s.jobs[key] = nil end
      end
    end
  end
  for player_index, st in pairs(all) do
    for n, record in pairs(st.slots) do
      if n ~= 0 and #record.members > 0 and divisions.in_phase(player_index, n, phase) then
        s = s or state()
        sweep(s, player_index, n, record)
      end
    end
  end
end

-- Completions of held soldiers stop here: a cover waits for its next spot,
-- a helper for the next sweep, a veteran behind the line for the call to
-- end.
function M.on_command_completed(unit_number)
  local s = storage.cover
  local vip_id = s and s.held[unit_number]
  if not vip_id then return false end
  local player_index, n = divisions.owner(unit_number)
  if not player_index then return true end
  local d = s.divisions[key_of(player_index, n)]
  local vip = d and d.vips[vip_id]
  if vip and vip.call then vip.call.idle[unit_number] = true end
  local slot = vip and vip.slots and vip.slots[unit_number]
  if slot then slot.done = true end
  return true
end

-- A soldier died or was rebuilt. A veteran's soldiers get their job back.
function M.forget(unit_number)
  local s = storage.cover
  if not s then return end
  local vip_id = s.held[unit_number]
  s.held[unit_number] = nil
  for _, d in pairs(s.divisions) do
    local vip = d.vips[unit_number]
    if vip then
      local st = storage.divisions and storage.divisions[d.player_index]
      drop_vip(s, d, unit_number, st and st.slots[d.n])
      return
    end
    vip = vip_id and d.vips[vip_id]
    if vip then
      remove(vip.covers, unit_number)
      if vip.slots then vip.slots[unit_number] = nil end
      if vip.call then remove(vip.call.helpers, unit_number) end
      return
    end
  end
end

return M
