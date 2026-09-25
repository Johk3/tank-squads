-- Unit nicknames: an adjective and a noun from the locale word lists, such
-- as "Rusty Anvil". The generator state lives in storage, so every peer,
-- including one that joins later, draws the same names.
local M = {}

M.ADJECTIVES, M.NOUNS = 80, 80
-- A pair already held by a living unit is redrawn this many times at most.
M.REDRAWS = 8

-- Park-Miller minimal standard generator. Its products stay below 2^53, so
-- Lua's doubles hold them exactly.
local MODULUS, MULTIPLIER, SEED = 2147483647, 16807, 20260925

local function next_value()
  local seed = (storage.name_seed or SEED) * MULTIPLIER % MODULUS
  storage.name_seed = seed
  return seed
end

local function key(adjective, noun) return adjective * 1000 + noun end

function M.draw()
  storage.name_taken = storage.name_taken or {}
  local taken, adjective, noun = storage.name_taken, nil, nil
  for _ = 1, M.REDRAWS do
    local value = next_value() % (M.ADJECTIVES * M.NOUNS)
    adjective, noun = math.floor(value / M.NOUNS) + 1, value % M.NOUNS + 1
    if not taken[key(adjective, noun)] then break end
  end
  local k = key(adjective, noun)
  taken[k] = (taken[k] or 0) + 1
  return {adjective = adjective, noun = noun}
end

function M.release(record)
  local taken = storage.name_taken
  local k = key(record.adjective, record.noun)
  local count = taken and taken[k]
  if not count then return end
  taken[k] = count > 1 and count - 1 or nil
end

function M.localised(record)
  return {"", {"tank-squads.name-adjective-" .. record.adjective}, " ", {"tank-squads.name-noun-" .. record.noun}}
end

return M
