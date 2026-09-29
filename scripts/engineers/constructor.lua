-- Constructor: an unmanned wall-laying vehicle. It fills the force's wall
-- and gate ghosts that construction robots cannot reach, while its escort
-- team rings it. Each constructor is checked once per second in the sweep
-- slice of its unit number; a building crane is checked every slice, so a
-- wall appears at most 6 ticks after the release frame.
--
-- record = {entity, id, force_index, surface_index, state, since, said,
--   cluster, centre, fails, retries, crane, release_tick, done_tick,
--   released, paused_since, calm_since, task_force, task_force_result}
-- state is 'waiting', 'seeking', 'moving', 'building', 'paused',
-- 'task_force', 'healing' or 'idle'.
local names = require('scripts.names')
local config = require('scripts.config')
local divisions = require('scripts.divisions')
local assault = require('scripts.assault')
local state = require('scripts.engineers.state')
local ghosts = require('scripts.engineers.ghosts')
local crane = require('scripts.engineers.crane')
local teams = require('scripts.engineers.teams')
local task_force = require('scripts.engineers.task_force')

local M = {}

M.MIN_TEAM = 2
M.CLUSTER_RADIUS, M.CLUSTER_MAX = 3, 9
-- Tiles between the farthest ghost of the cluster and the standing spot.
M.CLEARANCE = 2.5
M.ENEMY_RADIUS = 80
M.CALM = 5 * 60
M.PAUSE_LIMIT = 60 * 60
M.NEST_RADIUS = 40
M.PATH_FAILURES = 2
M.MOVE_LIMIT = 60 * 60
M.HOME_RADIUS = 8
M.SAY_INTERVAL = 10 * 60

local function min_team()
  local s = state.peek()
  return s and s.min_team or M.MIN_TEAM
end

local function set(record, name)
  record.state, record.since = name, game.tick
end

-- Flying text over the constructor for its force's players on its surface,
-- at most once per SAY_INTERVAL for each message.
local function say(record, key)
  local tick = game.tick
  local last = record.said[key]
  if last and tick - last < M.SAY_INTERVAL then return end
  record.said[key] = tick
  local entity = record.entity
  for _, player in pairs(entity.force.connected_players) do
    if player.surface_index == record.surface_index then
      player.create_local_flying_text{text = {'tank-squads.constructor-' .. key}, position = entity.position}
    end
  end
end

local function go(record, destination, radius)
  record.entity.commandable.set_command{type = defines.command.go_to_location, destination = destination,
    radius = radius or 1, distraction = defines.distraction.none}
end

local function stop(record)
  record.entity.commandable.set_command{type = defines.command.stop, distraction = defines.distraction.none}
end

-- Lets go of the claimed cluster and stops the crane.
local function release(record)
  crane.stop(record)
  ghosts.release(record.cluster)
  record.cluster, record.centre, record.fails, record.retries = nil, nil, nil, nil
end

function M.reset(record)
  release(record)
  record.task_force, record.task_force_result = nil, nil
  set(record, 'seeking')
end

function M.register(entity)
  if not (entity and entity.valid and entity.name == names.constructor) then return nil end
  local s = state.get()
  local record = s.constructors[entity.unit_number]
  if record then return record end
  record = {entity = entity, id = entity.unit_number, force_index = entity.force_index,
    surface_index = entity.surface_index, state = 'seeking', since = game.tick, said = {}}
  s.constructors[record.id] = record
  s.dirty = true
  ghosts.scan(entity.surface)
  return record
end

function M.unregister(unit_number)
  local s = state.peek()
  local record = s and s.constructors[unit_number]
  if not record then return end
  release(record)
  s.constructors[unit_number] = nil
  s.dirty = true
end

-- A finished constructor leaves the barracks door. Returns false when there
-- is no room, so the recruit waits in the machine.
function M.deploy(barracks_entity)
  local surface, p = barracks_entity.surface, barracks_entity.position
  local position = surface.find_non_colliding_position(names.constructor, {x = p.x, y = p.y + 3}, 16, 1)
  if not position then return false end
  local entity = surface.create_entity{name = names.constructor, position = position, force = barracks_entity.force}
  if not entity then return false end
  M.register(entity)
  return true
end

function M.count(force_index)
  local s = state.peek()
  local n = 0
  for _, record in pairs(s and s.constructors or {}) do
    if record.force_index == force_index then n = n + 1 end
  end
  return n
end

-- The nearest own barracks, or with `any` also headquarters, on the
-- constructor's surface.
function M.home(record, any)
  local position = record.entity.position
  local best, best_d
  local function consider(e)
    if e and e.valid and e.surface_index == record.surface_index and e.force_index == record.force_index then
      local dx, dy = e.position.x - position.x, e.position.y - position.y
      local d = dx * dx + dy * dy
      if not best_d or d < best_d then best, best_d = e, d end
    end
  end
  for _, b in ipairs(storage.barracks or {}) do consider(b.entity) end
  if any then
    for _, r in pairs(storage.headquarters or {}) do consider(r.entity) end
  end
  return best
end

-- Where to stand to build a cluster: beyond its farthest ghost, on the side
-- the constructor comes from, so its own hull never covers a ghost.
function M.spot(centre, from, positions)
  local reach = 0
  for _, p in ipairs(positions) do
    local dx, dy = p.x - centre.x, p.y - centre.y
    reach = math.max(reach, math.sqrt(dx * dx + dy * dy))
  end
  local dx, dy = from.x - centre.x, from.y - centre.y
  local length = math.sqrt(dx * dx + dy * dy)
  if length < 1e-6 then dx, dy, length = 0, 1, 1 end
  local d = reach + M.CLEARANCE
  return {x = centre.x + dx / length * d, y = centre.y + dy / length * d}
end

function M.enemy_near(entity)
  local forces = assault.enemy_forces(entity.force)
  if #forces == 0 then return false end
  return entity.surface.count_entities_filtered{position = entity.position, radius = M.ENEMY_RADIUS, type = 'unit',
    force = forces, limit = 1} > 0
end

-- Spawners and worms within NEST_RADIUS of the cluster, or nil.
function M.nest(entity, centre)
  local forces = assault.enemy_forces(entity.force)
  if #forces == 0 then return nil end
  local found = entity.surface.find_entities_filtered{position = centre, radius = M.NEST_RADIUS,
    type = {'unit-spawner', 'turret'}, force = forces}
  if #found == 0 then return nil end
  return found
end

local function positions(cluster)
  local out = {}
  for i, entry in ipairs(cluster) do out[i] = entry.position end
  return out
end

local function walk_to_cluster(record)
  local entity = record.entity
  local spot = M.spot(record.centre, entity.position, positions(record.cluster))
  spot = entity.surface.find_non_colliding_position(names.constructor, spot, 8, 0.5) or spot
  set(record, 'moving')
  go(record, spot, 1)
end

function M.seek(record)
  local cluster = ghosts.claim(record, M.CLUSTER_RADIUS, M.CLUSTER_MAX)
  if not cluster then set(record, 'idle'); return end
  local sx, sy = 0, 0
  for _, entry in ipairs(cluster) do sx, sy = sx + entry.position.x, sy + entry.position.y end
  record.cluster, record.fails, record.retries = cluster, 0, 0
  record.centre = {x = sx / #cluster, y = sy / #cluster}
  local entity = record.entity
  local structures = M.nest(entity, record.centre)
  if not structures then return walk_to_cluster(record) end
  local tf = task_force.request(record, structures)
  if tf then
    record.task_force = tf.id
    set(record, 'task_force')
    go(record, task_force.staging(tf, entity.position), 8)
    say(record, 'task-force')
  else
    ghosts.block(cluster, ghosts.BLOCK)
    record.cluster, record.centre = nil, nil
    set(record, 'seeking')
    say(record, 'too-strong')
  end
end

-- Once per second: health, a running task force, the escort, enemies, then
-- work.
function M.check(record, cfg)
  local entity = record.entity
  if not entity.valid then M.unregister(record.id); return end
  local tick = game.tick
  if record.state ~= 'healing' and entity.health < entity.max_health * cfg.retreat then
    local home = M.home(record, false)
    if home then
      M.reset(record)
      set(record, 'healing')
      go(record, home.position, M.HOME_RADIUS)
      state.get().dirty = true
      return
    end
  end
  if record.state == 'healing' then
    if entity.health < entity.max_health then return end
    M.reset(record)
    state.get().dirty = true
  end
  if record.state == 'task_force' then
    local result = record.task_force_result
    if not result then return end
    if result == 'broken' then ghosts.block(record.cluster, ghosts.BLOCK) end
    M.reset(record)
  end
  if teams.present(record.id) < min_team() then
    if record.state ~= 'waiting' then
      release(record)
      set(record, 'waiting')
      local home = M.home(record, true)
      if home then go(record, home.position, M.HOME_RADIUS) else stop(record) end
      say(record, 'waiting')
    end
    return
  end
  if record.state == 'waiting' then set(record, 'seeking') end
  if M.enemy_near(entity) then
    record.calm_since = nil
    if record.state ~= 'paused' then
      crane.stop(record)
      record.paused_since = tick
      set(record, 'paused')
      stop(record)
    elseif record.cluster and tick - record.paused_since > M.PAUSE_LIMIT then
      release(record)
    end
    return
  end
  if record.state == 'paused' then
    record.calm_since = record.calm_since or tick
    if tick - record.calm_since < M.CALM then return end
    record.calm_since, record.paused_since = nil, nil
    release(record)
    set(record, 'seeking')
  end
  if record.state == 'moving' and tick - record.since > M.MOVE_LIMIT then
    ghosts.block(record.cluster, ghosts.BLOCK)
    release(record)
    set(record, 'seeking')
  end
  if record.state == 'seeking' then
    M.seek(record)
  elseif record.state == 'idle' then
    -- An idle constructor searches again when a ghost joined its registry
    -- since it went idle, and once per RECHECK for expired blocks and
    -- ghosts robots no longer reach.
    local bucket = ghosts.bucket(record.surface_index, record.force_index)
    if (bucket and bucket.added and bucket.added >= record.since) or tick - record.since >= ghosts.RECHECK then
      M.seek(record)
    end
  end
end

function M.on_command_completed(unit_number, result)
  local s = state.peek()
  local record = s and s.constructors[unit_number]
  if not record then return false end
  if record.state ~= 'moving' or not record.entity.valid then return true end
  if result == defines.behavior_result.fail then
    record.fails = (record.fails or 0) + 1
    if record.fails >= M.PATH_FAILURES then
      ghosts.block(record.cluster, ghosts.BLOCK)
      release(record)
      set(record, 'seeking')
    else
      walk_to_cluster(record)
    end
    return true
  end
  set(record, 'building')
  crane.start(record)
  return true
end

local function build_step(record, tick)
  if not record.released and tick >= record.release_tick then
    record.released = true
    crane.place(record)
  end
  if tick < record.done_tick then return end
  crane.stop(record)
  if record.cluster and #record.cluster > 0 then
    -- Ghosts under a unit get another cycle.
    crane.start(record)
  else
    record.cluster = nil
    set(record, 'seeking')
    M.seek(record)
  end
end

-- Cranes every slice; each constructor's check in its own slice (all when
-- phase is nil).
function M.tick(phase)
  local s = state.peek()
  if not s then return end
  local tick, cfg = game.tick, nil
  for id, record in pairs(s.constructors) do
    if record.state == 'building' and record.entity.valid then build_step(record, tick) end
    if phase == nil or id % divisions.PHASES == phase then
      cfg = cfg or config.escort()
      M.check(record, cfg)
    end
  end
end

-- For the engine test: claims the next cluster and builds it at once,
-- without walking there. Returns the number of walls built.
function M.build_now(record)
  if not record.entity.valid then return 0 end
  M.seek(record)
  if record.state ~= 'moving' then return 0 end
  set(record, 'building')
  crane.start(record)
  local built = crane.place(record)
  -- Ghosts kept under a unit are let go, not left claimed.
  release(record)
  set(record, 'seeking')
  return built
end

return M
