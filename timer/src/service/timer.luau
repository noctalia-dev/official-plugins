--!nonstrict
local M = {}
local utils = require("./utils.luau")
local ring = require("./ring.luau")
local flags = require("./flags.luau")

local tmr = {
    state     = "IDLE",
    remaining = 0,
    duration  = 0,
    endsAt    = 0,
    flags     = {},
    nextFlagId = 1,
}

local MAX_SECONDS = 359999 -- 99:59:59

local function liveRemaining()
    if tmr.state == "RUNNING" then
        return math.max(0, tmr.endsAt - utils.now())
    end
    return tmr.remaining
end

function M.publish()
    local r = liveRemaining()
    noctalia.state.set("timer.timer", {
        state     = tmr.state,
        remaining = r,
        duration  = tmr.duration,
        display   = utils.fmtTime(r),
        flags     = tmr.flags,
    })
end

function M.getState()
    return tmr.state
end

function M.getRemaining()
    return liveRemaining()
end

function M.startCountdown(seconds)
    seconds = math.min(MAX_SECONDS, math.max(1, math.floor(seconds)))
    tmr.remaining = seconds
    tmr.duration  = seconds
    tmr.endsAt    = utils.now() + seconds
    tmr.state     = "RUNNING"
end

function M.start()
    if tmr.remaining > 0 and (tmr.state == "IDLE" or tmr.state == "PAUSED") then
        if tmr.state == "IDLE" then tmr.duration = tmr.remaining end
        tmr.endsAt = utils.now() + tmr.remaining
        tmr.state  = "RUNNING"
    end
end

function M.pause()
    if tmr.state == "RUNNING" then
        tmr.remaining = liveRemaining()
        tmr.state     = "PAUSED"
    end
end

function M.reset()
    tmr.state     = "IDLE"
    tmr.remaining = 0
    tmr.duration  = 0
    tmr.endsAt    = 0
    tmr.flags     = {}
    tmr.nextFlagId = 1
end

function M.set(seconds)
    if tmr.state == "IDLE" then
        tmr.remaining = math.min(MAX_SECONDS, math.max(0, math.floor(seconds)))
        tmr.duration  = tmr.remaining
    end
end

function M.adjust(delta)
    if tmr.state == "RUNNING" then
        local r = math.min(MAX_SECONDS, math.max(0, liveRemaining() + delta))
        tmr.endsAt = utils.now() + r
    else
        tmr.remaining = math.min(MAX_SECONDS, math.max(0, tmr.remaining + delta))
        if tmr.state == "IDLE" then tmr.duration = tmr.remaining end
    end
end

function M.flag(name)
    local r = liveRemaining()
    flags.add(tmr, name, { remaining = r, display = utils.fmtTime(r) })
end

function M.renameFlag(id, newName)
    flags.rename(tmr, id, newName)
end

function M.tick()
    if tmr.state == "RUNNING" then
        if utils.now() >= tmr.endsAt then
            tmr.state     = "DONE"
            tmr.remaining = 0
            ring.alertFor("timer", "⏰ Timer", "Time's up!", "Timer")
        end
        M.publish()
    end
end

return M
