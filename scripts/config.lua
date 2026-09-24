-- Escort map settings. DEFINITIONS is shared by settings.lua (settings
-- stage) and the runtime, and uses no runtime API at load time.
local M = {}

M.DEFINITIONS = {
  {key = "ring", name = "tank-squads-escort-ring-radius", default = 160, min = 32, max = 512},
  {key = "detect", name = "tank-squads-escort-detect-radius", default = 224, min = 48, max = 640},
  {key = "band_min", name = "tank-squads-escort-band-min", default = 256, min = 64, max = 1000},
  {key = "band_max", name = "tank-squads-escort-band-max", default = 448, min = 96, max = 1000},
  {key = "step", name = "tank-squads-escort-anchor-step", default = 64, min = 16, max = 256},
  {key = "retreat", name = "tank-squads-retreat-health", default = 35, min = 5, max = 90},
  {key = "rejoin", name = "tank-squads-rejoin-health", default = 95, min = 50, max = 100},
  {key = "range", name = "tank-squads-retreat-range", default = 1000, min = 50, max = 5000},
}

-- Map vision around soldiers. A plain on/off switch, not an escort distance.
M.VISION = "tank-squads-soldier-vision"

M.NAMES = {}
for _, d in ipairs(M.DEFINITIONS) do M.NAMES[d.name] = true end

-- Effective values. Factorio cannot make one setting depend on another, so
-- the dependent rules are applied here; the setting tooltips describe them.
-- Reads settings.global on every call and keeps no state, so it is safe
-- across save, load and multiplayer joins. Callers read it once per sweep.
function M.escort()
  local v = {}
  for _, d in ipairs(M.DEFINITIONS) do v[d.key] = settings.global[d.name].value end
  v.detect = math.max(v.detect, v.ring + 16)
  v.band_max = math.max(v.band_max, v.band_min + 32)
  v.rejoin = math.min(100, math.max(v.rejoin, v.retreat + 5))
  v.retreat, v.rejoin = v.retreat / 100, v.rejoin / 100
  return v
end

return M
