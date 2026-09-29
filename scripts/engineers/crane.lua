-- The constructor's crane: a four-frame animation drawn for one cycle,
-- turned toward the cluster, and the walls it sets down on the release
-- frame. The constructor's sweep calls place() on the first slice at or
-- after the release tick, at most 6 ticks late.
local names = require('scripts.names')
local appearance = require('scripts.appearance')
local ghosts = require('scripts.engineers.ghosts')

local M = {}

M.CYCLE = 60
M.RELEASE = 30
M.SPEED = 4 / M.CYCLE
-- Cycles a ghost under a unit waits before the constructor lets it go.
M.RETRIES = 3
local LOOK = appearance.constructor
-- A unit, character or vehicle on a ghost blocks its revive.
local BLOCKERS = {'unit', 'character', 'car', 'spider-vehicle'}
-- Trees and rocks give way to the wall. Player-placed simple entities
-- (simple-entity-with-owner) are never cleared.
local CLEARED = {'tree', 'simple-entity'}

function M.orientation(from, to)
  local dx, dy = to.x - from.x, to.y - from.y
  return (math.atan2(dx, -dy) / (2 * math.pi)) % 1
end

-- The frame is drawn north-facing around its centre, with the crane's base
-- below it. Shifting the frame along its heading by that distance keeps
-- the base on the constructor.
function M.offset(orientation)
  local d = LOOK.crane_base * LOOK.crane_scale / 32
  local a = orientation * 2 * math.pi
  return {x = d * math.sin(a), y = -d * math.cos(a)}
end

function M.stop(record)
  if record.crane and record.crane.valid then record.crane.destroy() end
  record.crane = nil
end

function M.start(record)
  M.stop(record)
  local entity, tick = record.entity, game.tick
  local o = M.orientation(entity.position, record.centre)
  -- Rendering counts frames from the absolute tick; the offset starts
  -- every cycle on its first frame.
  record.crane = rendering.draw_animation{animation = names.constructor_crane,
    target = {entity = entity, offset = M.offset(o)}, surface = entity.surface, orientation = o,
    render_layer = 'object', animation_speed = M.SPEED, animation_offset = -tick * M.SPEED,
    time_to_live = M.CYCLE}
  record.release_tick, record.done_tick, record.released = tick + M.RELEASE, tick + M.CYCLE, nil
end

-- Sets down the claimed walls. Trees and rocks on a ghost are cleared
-- first. A ghost under a unit stays claimed for the next cycle, up to
-- RETRIES cycles; one that cannot be revived is blocked. Returns the
-- number of walls built.
function M.place(record)
  local surface = record.entity.surface
  local kept, built = {}, 0
  for _, entry in ipairs(record.cluster or {}) do
    local ghost = entry.entity
    if not ghost.valid then
      ghosts.placed(record, entry)
    else
      local box = ghost.bounding_box
      for _, obstacle in pairs(surface.find_entities_filtered{area = box, type = CLEARED}) do obstacle.destroy() end
      if surface.count_entities_filtered{area = box, type = BLOCKERS, limit = 1} > 0 then
        kept[#kept + 1] = entry
      else
        local _, wall = ghost.revive{raise_revive = true}
        if wall then
          built = built + 1
          ghosts.placed(record, entry)
        else
          ghosts.block({entry}, ghosts.BLOCK)
        end
      end
    end
  end
  record.retries = #kept > 0 and (record.retries or 0) + 1 or 0
  if record.retries > M.RETRIES then
    ghosts.release(kept)
    kept, record.retries = {}, 0
  end
  record.cluster = kept
  return built
end

return M
