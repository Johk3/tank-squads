local combat = require("scripts.combat")
local divisions = require("scripts.divisions")
local patrol = require("scripts.patrol")

local M = {}

local function centre(area)
  return {
    x = (area.left_top.x + area.right_bottom.x) / 2,
    y = (area.left_top.y + area.right_bottom.y) / 2,
  }
end
M.centre = centre

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

  for _, soldier in pairs(on_surface) do
    combat.set_command(soldier, record.order.command)
  end

  return attack and "attack" or "move"
end

return M
