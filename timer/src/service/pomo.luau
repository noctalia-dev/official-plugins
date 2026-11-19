--!nonstrict
local M = {}
local utils = require("./utils.luau")
local ring = require("./ring.luau")
local flags = require("./flags.luau")

M.pomo = {
    state    = "IDLE",
    schedule = {},
    stageIdx = 1,
    remaining = 0,
    endsAt   = 0,
    looping  = false,
    autoStart = false,
    pendingAuto = false, -- next stage queued; starts once the pomodoro alert is dismissed
    flags    = {},
    nextFlagId = 1,
    sessionsCompleted = 0,
}
local pomo = M.pomo

local cfgSnapshot = ""

local LABELS = { work = "Focus", short_break = "Short Break", long_break = "Long Break" }

local function stageLabel(stage)
    if stage == nil then return LABELS.work end
    return LABELS[stage.type] or stage.label or "Stage"
end

local function newStage(kind, minutes)
    return { type = kind, duration = minutes * 60, label = LABELS[kind] }
end

local function buildSchedule(workMin, shortMin, longMin, sessions)
    local sched = {}
    for i = 1, sessions do
        table.insert(sched, newStage("work", workMin))
        if i < sessions then
            table.insert(sched, newStage("short_break", shortMin))
        elseif longMin > 0 then
            table.insert(sched, newStage("long_break", longMin))
        else
            -- Long break disabled: the cycle ends with a regular short break.
            table.insert(sched, newStage("short_break", shortMin))
        end
    end
    return sched
end

local function cfgNum(key, default, lo, hi)
    local v = tonumber(noctalia.getConfig(key)) or default
    return math.max(lo, math.min(hi, math.floor(v)))
end

local function readConfig()
    return cfgNum("pomo_work", 25, 1, 240),
        cfgNum("pomo_short_break", 5, 1, 240),
        cfgNum("pomo_long_break", 15, 0, 240),
        cfgNum("pomo_sessions", 4, 1, 12)
end

local function readConfigKey()
    return table.concat({ readConfig() }, "|")
end

function M.buildFromConfig()
    pomo.autoStart = noctalia.getConfig("pomo_auto_start") == true
    cfgSnapshot = readConfigKey()
    return buildSchedule(readConfig())
end

function M.currentStage()
    return pomo.schedule[pomo.stageIdx]
end

local function liveRemaining()
    if pomo.state == "RUNNING" then
        return math.max(0, pomo.endsAt - utils.now())
    end
    return pomo.remaining
end

function M.reset()
    pomo.pendingAuto = false
    pomo.state     = "IDLE"
    pomo.stageIdx  = 1
    pomo.remaining = pomo.schedule[1] and pomo.schedule[1].duration or 0
    pomo.endsAt    = 0
    pomo.sessionsCompleted = 0
    pomo.flags     = {}
    pomo.nextFlagId = 1
end

function M.resetStage()
    pomo.pendingAuto = false
    local stage = M.currentStage()
    pomo.remaining = stage and stage.duration or 0
    pomo.endsAt    = 0
    pomo.state     = "IDLE"
end

function M.toggleLoop()
    pomo.looping = not pomo.looping
end

function M.publish()
    local stage = M.currentStage()
    local r = liveRemaining()
    noctalia.state.set("timer.pomo", {
        state     = pomo.state,
        stageIdx  = pomo.stageIdx,
        stageCount = #pomo.schedule,
        stageLabel = stageLabel(stage),
        stageType  = stage and stage.type or "work",
        remaining  = r,
        duration   = stage and stage.duration or 0,
        display    = utils.fmtTime(r),
        progress   = (stage and stage.duration > 0) and (r / stage.duration) or 0,
        looping    = pomo.looping,
        sessionsCompleted = pomo.sessionsCompleted,
        schedule   = pomo.schedule,
        flags      = pomo.flags,
    })
end

function M.start()
    pomo.pendingAuto = false
    if (pomo.state == "IDLE" or pomo.state == "PAUSED") and pomo.remaining > 0 then
        pomo.endsAt = utils.now() + pomo.remaining
        pomo.state  = "RUNNING"
    end
end

function M.pause()
    if pomo.state == "RUNNING" then
        pomo.remaining = liveRemaining()
        pomo.state     = "PAUSED"
    end
end

function M.adjust(delta)
    if pomo.state == "RUNNING" then
        local r = math.max(0, liveRemaining() + delta)
        pomo.endsAt = utils.now() + r
    elseif pomo.state == "IDLE" or pomo.state == "PAUSED" then
        pomo.remaining = math.max(0, pomo.remaining + delta)
    end
end

-- Move to the next stage, wrapping when looping. Past the last stage the
-- pomodoro is DONE and this returns false.
local function advance()
    if pomo.stageIdx < #pomo.schedule then
        pomo.stageIdx += 1
    elseif pomo.looping then
        pomo.stageIdx = 1
    else
        pomo.state     = "DONE"
        pomo.remaining = 0
        pomo.endsAt    = 0
        return false
    end
    return true
end

function M.skip()
    pomo.pendingAuto = false
    if advance() then M.resetStage() end
end

function M.flag(name)
    local r = liveRemaining()
    flags.add(pomo, name, {
        remaining  = r,
        stageLabel = stageLabel(M.currentStage()),
        display    = utils.fmtTime(r),
    })
end

function M.renameFlag(id, newName)
    flags.rename(pomo, id, newName)
end

-- Auto-start waits for the pomodoro alert to be dismissed (or time out).
function M.checkPending()
    if not pomo.pendingAuto or pomo.state ~= "IDLE" then return end
    if ring.isActive() and ring.getMode() == "pomo" then return end
    pomo.pendingAuto = false
    if pomo.remaining > 0 then
        pomo.endsAt = utils.now() + pomo.remaining
        pomo.state  = "RUNNING"
        M.publish()
    end
end

function M.tick()
    M.checkPending()
    if pomo.state == "RUNNING" then
        if utils.now() >= pomo.endsAt then
            local stage      = M.currentStage()
            local slabel = stageLabel(stage)
            if stage and stage.type == "work" then
                pomo.sessionsCompleted += 1
            end
            ring.alertFor("pomo", "Pomodoro", slabel .. " complete!", slabel .. " complete")

            if not advance() then
                M.publish()
                return
            end

            local nxt = M.currentStage()
            pomo.remaining = nxt and nxt.duration or 0
            pomo.endsAt      = 0
            pomo.state       = "IDLE"
            pomo.pendingAuto = pomo.autoStart and pomo.remaining > 0
            M.checkPending()
        end
        M.publish()
    end
end

function M.load()
    pomo.schedule  = M.buildFromConfig()
    pomo.stageIdx  = 1
    pomo.remaining = pomo.schedule[1] and pomo.schedule[1].duration or 0
end

-- Called for every plugin setting change. Only a change to the schedule
-- settings may disturb a running Pomodoro.
function M.onConfigChanged()
    pomo.autoStart = noctalia.getConfig("pomo_auto_start") == true
    if readConfigKey() ~= cfgSnapshot then
        pomo.schedule = M.buildFromConfig()
        M.reset()
    end
    M.publish()
end

return M
