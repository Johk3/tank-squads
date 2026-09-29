local assault = require("scripts.assault")
local combat = require("scripts.combat")
local divisions = require("scripts.divisions")
local names = require("scripts.names")
local patrol = require("scripts.patrol")
local loans = require("scripts.engineers.loans")

local M = {}

local function centre(area)
  return {
    x = (area.left_top.x + area.right_bottom.x) / 2,
    y = (area.left_top.y + area.right_bottom.y) / 2,
  }
end
M.centre = centre

-- An order onto a nest runs a nest assault (scripts/assault.lua) that
-- surrounds the nest, kept as order.assault. Both the drag selection and a
-- division can list a soldier, so storage.order_assaults names the order
-- that last took each soldier: the last order wins, as with plain orders.
-- Entries of ended orders are dropped when next read.
local function claims()
  storage.order_assaults = storage.order_assaults or {}
  return storage.order_assaults
end

local function claim(order, soldier)
  claims()[soldier.unit_number] = {id = order.id, player_index = order.player_index, division = order.division}
end

-- The idle record whose running nest assault holds the soldier, else nil.
-- A soldier that left the division, or a soldier of the drag selection that
-- a job division took over, is no longer held.
local function holder(unit_number, entry)
  local state = storage.divisions and storage.divisions[entry.player_index]
  local record = state and state.slots[entry.division]
  local order = record and record.mode == "idle" and record.order
  if not (order and order.id == entry.id and order.assault) then return nil end
  local owner_index, n, owner = divisions.owner(unit_number)
  if entry.division == 0 then
    if owner and owner.mode ~= "idle" then return nil end
  elseif owner_index ~= entry.player_index or n ~= entry.division then
    return nil
  end
  return record
end

-- Costs one table read for a soldier no assault holds.
local function held(unit_number)
  local entry = storage.order_assaults and storage.order_assaults[unit_number]
  if not entry then return nil end
  local record = holder(unit_number, entry)
  if not record then storage.order_assaults[unit_number] = nil end
  return record
end

local function stage_command(a)
  return {type = defines.command.go_to_location, destination = a.arc_centre, radius = 8,
    distraction = defines.distraction.by_enemy}
end

-- A soldier joins the order's running nest assault. The unarmed
-- headquarters waits on the staging arc on the division's side.
local function join_assault(order, soldier)
  claim(order, soldier)
  if soldier.name == names.headquarters then
    combat.set_command(soldier, stage_command(order.assault))
  else
    assault.join(order.assault, soldier)
  end
end

-- A recruit, or a soldier added to the division, follows the division's
-- manual order: into its nest assault when one runs, else the plain order.
-- Returns false when the division has no manual order.
function M.join(record, soldier)
  local order = record.mode == "idle" and record.order
  if not order then return false end
  if order.assault and soldier.surface_index == order.surface_index then
    join_assault(order, soldier)
  else
    combat.set_command(soldier, order.command)
  end
  return true
end

-- Adds the selected soldiers to division n. A manual division that was
-- given an order sends the newcomers after it, as it does recruits.
function M.add(player_index, n)
  local added = divisions.add(player_index, n, divisions.get(player_index, divisions.selected(player_index)))
  local record = divisions.record(player_index, n)
  local order = record.mode == "idle" and record.order
  if order then
    for _, soldier in ipairs(added) do
      if soldier.surface_index == order.surface_index then M.join(record, soldier) end
    end
  end
  return #added
end

-- Starts a nest assault when a spawner stands at the ordered spot. The
-- headquarters takes no part and waits on the staging arc.
local function try_assault(player_index, n, order, on_surface, destination)
  local soldiers = {}
  for _, soldier in ipairs(on_surface) do
    if soldier.name ~= names.headquarters then soldiers[#soldiers + 1] = soldier end
  end
  if #soldiers == 0 then return false end
  local forces = assault.enemy_forces(soldiers[1].force)
  if #forces == 0 or not assault.start(order, soldiers, destination, forces, true) then return false end
  storage.order_assault_id = (storage.order_assault_id or 0) + 1
  order.id, order.player_index, order.division = storage.order_assault_id, player_index, n
  for _, soldier in ipairs(on_surface) do
    claim(order, soldier)
    if soldier.name == names.headquarters then combat.set_command(soldier, stage_command(order.assault)) end
  end
  return true
end

function M.order(player_index, area, surface)
  local n = divisions.selected(player_index)
  local members = divisions.get(player_index, n)
  if #members == 0 then return nil end
  surface = surface or members[1].surface

  -- divisions.get is surface-agnostic (a division can contain soldiers spread
  -- across Nauvis, other planets, or space platforms under Space Age); only
  -- command the members that are actually on the surface the order was
  -- issued on, so soldiers elsewhere don't receive a destination computed
  -- from a different surface's coordinates.
  local on_surface, surface_index = {}, surface.index
  for _, soldier in pairs(members) do
    if soldier.surface_index == surface_index then table.insert(on_surface, soldier) end
  end
  if #on_surface == 0 then return nil end
  -- Soldiers the player orders leave any task force they were lent to.
  loans.recall(on_surface)
  if n == 0 then divisions.release_for_order(player_index, on_surface) end
  patrol.clear(player_index, n)
  local record = divisions.record(player_index, n)
  divisions.end_escort(record)
  record.mode, record.scout = "idle", nil

  -- One enemy decides the order type; the engine stops counting there.
  local attack = surface.count_entities_filtered{area = area, force = "enemy", limit = 1} > 0
  local destination = centre(area)
  record.order = {surface_index = surface.index, command = {
    type = attack and defines.command.attack_area or defines.command.go_to_location,
    destination = destination, radius = attack and 12 or 4,
    distraction = defines.distraction.by_enemy,
  }}

  -- This order replaces any nest assault that held these soldiers.
  if storage.order_assaults then
    for _, soldier in ipairs(on_surface) do storage.order_assaults[soldier.unit_number] = nil end
  end
  if try_assault(player_index, n, record.order, on_surface, destination) then return "assault" end

  for _, soldier in pairs(on_surface) do
    combat.set_command(soldier, record.order.command)
  end

  return attack and "attack" or "move"
end

-- The order's soldiers on its surface that its nest assault still holds.
-- The headquarters is listed apart, as it takes no part.
local function assault_members(player_index, n, record)
  local soldiers, others, entries, order = {}, {}, claims(), record.order
  for _, e in ipairs(divisions.cached(player_index, n)) do
    local entry = e.valid and e.surface_index == order.surface_index and entries[e.unit_number]
    if entry and entry.id == order.id and (n ~= 0 or holder(e.unit_number, entry)) then
      if e.name == names.headquarters then others[#others + 1] = e else soldiers[#soldiers + 1] = e end
    end
  end
  return soldiers, others
end

-- Once the nest falls or the assault gives up, the order carries on as the
-- plain order the player gave, so the division clears the spot or walks to
-- it.
local function finish(order, soldiers, others)
  order.assault = nil
  local entries = claims()
  for _, list in ipairs({soldiers, others}) do
    for _, e in ipairs(list) do
      entries[e.unit_number] = nil
      combat.set_command(e, order.command)
    end
  end
end

local function drive(player_index, n, record, order)
  local soldiers, others = assault_members(player_index, n, record)
  if #soldiers == 0 then
    -- Nobody left to fight. A reinforced division waits for recruits.
    if not divisions.is_reinforced(record) then finish(order, soldiers, others) end
    return
  end
  if assault.tick(order.assault, soldiers) then finish(order, soldiers, others) end
end

-- Drives the manual nest assaults in one sweep phase (all when phase is nil).
function M.tick(phase)
  for player_index, state in pairs(storage.divisions or {}) do
    for n, record in pairs(state.slots) do
      local order = record.order
      if order and order.assault and record.mode == "idle" and divisions.in_phase(player_index, n, phase) then
        drive(player_index, n, record, order)
      end
    end
  end
end

-- Returns true when the completion belonged to a manual nest assault.
function M.on_command_completed(unit_number, result)
  local record = held(unit_number)
  if not record then return false end
  assault.on_command_completed(record.order.assault, unit_number, result)
  return true
end

function M.forget(unit_number)
  if storage.order_assaults then storage.order_assaults[unit_number] = nil end
end

return M
