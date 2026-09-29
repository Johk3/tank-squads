-- Soldiers lent to a nest task force. A leaf module with no requires, so
-- patrol, cover and commands can ask about loans without a require cycle.
--
-- storage.engineer_loans[unit_number] = {task_force, player_index, n, back}
--   player_index, n  the lending division, nil for a soldier in no division
--   back             where the soldier returns to when its division has no
--                    patrol post for it
local M = {}

function M.on_loan(unit_number)
  local loans = storage.engineer_loans
  return loans ~= nil and loans[unit_number] ~= nil
end

function M.get(unit_number)
  local loans = storage.engineer_loans
  return loans and loans[unit_number]
end

function M.lend(unit_number, loan)
  storage.engineer_loans = storage.engineer_loans or {}
  storage.engineer_loans[unit_number] = loan
end

-- Ends the loan and returns it, or nil when the soldier was not lent.
function M.finish(unit_number)
  local loans = storage.engineer_loans
  local loan = loans and loans[unit_number]
  if loan then loans[unit_number] = nil end
  return loan
end

-- A direct order takes soldiers back from their task force. The task force
-- drops them on its next sweep and does not send them home.
function M.recall(entities)
  local loans = storage.engineer_loans
  if not loans then return end
  for _, e in ipairs(entities) do
    if e.valid then loans[e.unit_number] = nil end
  end
end

return M
