--!nonstrict
-- Response parsing shares the service's callback budget, so long lookups yield between small batches of work.

local M = {}
local SLICE_SECONDS = 0.004
local deadline = nil

function M.checkpoint()
  if deadline ~= nil and os.clock() >= deadline then
    coroutine.yield()
  end
end

function M.resume(thread)
  deadline = os.clock() + SLICE_SECONDS
  local ok, err = coroutine.resume(thread)
  deadline = nil
  return ok, err
end

return M
