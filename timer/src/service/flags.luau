--!nonstrict
-- Shared flag/lap helpers for stopwatch, timer and pomodoro.
-- `owner` is the mode table; it must have `flags` and `nextFlagId`.
local M = {}

local MAX_FLAGS = 200
local MAX_NAME  = 40

function M.cleanName(name)
    if type(name) ~= "string" then return "" end
    return string.sub(name, 1, MAX_NAME)
end

function M.add(owner, name, extra)
    if #owner.flags >= MAX_FLAGS then return end
    local nowS  = math.floor(noctalia.nowMs() / 1000)
    local clean = M.cleanName(name)
    local entry = {
        id     = owner.nextFlagId,
        name   = clean ~= "" and clean or ("Flag " .. owner.nextFlagId),
        ts     = nowS,
        tsWall = noctalia.formatTime("%H:%M:%S", nowS),
    }
    for k, v in pairs(extra) do entry[k] = v end
    table.insert(owner.flags, entry)
    owner.nextFlagId += 1
end

function M.rename(owner, id, newName)
    local clean = M.cleanName(newName)
    if clean == "" then return end
    for _, f in ipairs(owner.flags) do
        if f.id == id then
            f.name = clean
            return
        end
    end
end

return M
