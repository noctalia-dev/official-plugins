--!nonstrict
local M = {}
local utils = require("./utils.luau")
local flags = require("./flags.luau")

local sw = {
    state     = "IDLE",
    elapsed   = 0,
    startedAt = 0,
    flags     = {},
    nextFlagId = 1,
}

local function liveElapsed()
    if sw.state == "RUNNING" then
        return sw.elapsed + (utils.now() - sw.startedAt)
    end
    return sw.elapsed
end

local function snapshot()
    local live = liveElapsed()
    return {
        state   = sw.state,
        elapsed = live,
        display = utils.fmtTime(live),
        flags   = sw.flags,
    }
end

function M.publish()
    noctalia.state.set("timer.sw", snapshot())
end

function M.getState()
    return sw.state
end

function M.start()
    if sw.state == "IDLE" or sw.state == "PAUSED" then
        sw.startedAt = utils.now()
        sw.state     = "RUNNING"
    end
end

function M.pause()
    if sw.state == "RUNNING" then
        sw.elapsed = sw.elapsed + (utils.now() - sw.startedAt)
        sw.state   = "PAUSED"
    end
end

function M.reset()
    sw.state     = "IDLE"
    sw.elapsed   = 0
    sw.startedAt = 0
    sw.flags     = {}
    sw.nextFlagId = 1
end

function M.flag(name)
    local live = liveElapsed()
    flags.add(sw, name, { elapsed = live, display = utils.fmtTime(live) })
end

function M.renameFlag(id, newName)
    flags.rename(sw, id, newName)
end

function M.tick()
    if sw.state == "RUNNING" then
        M.publish()
    end
end

return M
