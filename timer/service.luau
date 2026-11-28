--!nonstrict
-- Timer service: owns every state machine (timer, stopwatch, pomodoro, alarms),
-- publishes to noctalia.state and applies the commands the UI entries write to
-- `timer.cmd`.

noctalia.setUpdateInterval(1000)

local store = require("./src/service/store.luau")
local ring = require("./src/service/ring.luau")
local sw = require("./src/service/stopwatch.luau")
local tmr = require("./src/service/timer.luau")
local pomoMod = require("./src/service/pomo.luau")
local alarmsMod = require("./src/service/alarms.luau")
local ipc = require("./src/service/ipc.luau")

local function persistData()
    store.persist(alarmsMod.alarms)
end

alarmsMod.setPersistCallback(persistData)

local function stopRingFor(mode)
    if ring.isActive() and ring.getMode() == mode then ring.stop() end
end

local function dispatch(cmd)
    local mode    = cmd.mode
    local action  = cmd.action
    local payload = cmd.payload

    if mode == "sw" then
        if action == "start"       then sw.start()
        elseif action == "pause"   then sw.pause()
        elseif action == "reset"   then sw.reset()
        elseif action == "flag"    then sw.flag(payload)
        elseif action == "rename_flag" and type(payload) == "table" then
            sw.renameFlag(payload.id, payload.name)
        end
        sw.publish()

    elseif mode == "timer" then
        if action == "start"       then tmr.start()
        elseif action == "pause"   then tmr.pause()
        elseif action == "reset"   then
            tmr.reset()
            stopRingFor("timer")
        elseif action == "set" and type(payload) == "number" then
            tmr.set(payload)
        elseif action == "set_start" and type(payload) == "number" then
            tmr.set(payload)
            tmr.start()
        elseif action == "adjust" and type(payload) == "number" then
            tmr.adjust(payload)
        elseif action == "flag"    then tmr.flag(payload)
        elseif action == "rename_flag" and type(payload) == "table" then
            tmr.renameFlag(payload.id, payload.name)
        end
        tmr.publish()

    elseif mode == "pomo" then
        if action == "start"       then pomoMod.start()
        elseif action == "pause"   then pomoMod.pause()
        elseif action == "skip"    then pomoMod.skip()
        elseif action == "reset"   then
            pomoMod.resetStage()
            stopRingFor("pomo")
        elseif action == "reset_all" then
            pomoMod.reset()
            stopRingFor("pomo")
        elseif action == "toggle_loop" then
            pomoMod.toggleLoop()
        elseif action == "adjust_remaining" and type(payload) == "number" then
            pomoMod.adjust(payload)
        elseif action == "flag"    then pomoMod.flag(payload)
        elseif action == "rename_flag" and type(payload) == "table" then
            pomoMod.renameFlag(payload.id, payload.name)
        end
        pomoMod.publish()

    elseif mode == "alarm" then
        if type(payload) == "table" then
            if action == "add" then
                alarmsMod.add(payload.label, payload.hh, payload.mm, payload.days)
            elseif action == "edit" then
                alarmsMod.edit(tonumber(payload.id), payload.label, payload.hh, payload.mm, payload.days)
            end
        elseif action == "remove" and payload ~= nil then
            alarmsMod.remove(tonumber(payload))
        elseif action == "toggle" and payload ~= nil then
            alarmsMod.toggle(tonumber(payload))
        end

    elseif mode == "ring" then
        if action == "stop" then
            ring.stop()
            pomoMod.checkPending()
            -- Dismissing the ring also clears the finished (DONE) timer/pomodoro.
            local tState = noctalia.state.get("timer.timer")
            if tState and tState.state == "DONE" then tmr.reset(); tmr.publish() end
            local pState = noctalia.state.get("timer.pomo")
            if pState and pState.state == "DONE" then pomoMod.reset(); pomoMod.publish() end
        end
    end
end

-- `timer.cmd` holds one command or `{ batch = { cmd... } }`. Every command has a
-- monotonic `nonce` and anything at or below the last one seen is a duplicate.
-- Batching keeps commands issued in the same tick from overwriting each other.
local lastNonce = 0
noctalia.state.watch("timer.cmd", function(msg)
    if type(msg) ~= "table" then return end
    local list = type(msg.batch) == "table" and msg.batch or { msg }
    for _, cmd in ipairs(list) do
        if type(cmd) == "table" and type(cmd.nonce) == "number" and cmd.nonce > lastNonce then
            lastNonce = cmd.nonce
            dispatch(cmd)
        end
    end
end)

function onIpc(event, payload)
    ipc.handle(event, payload)
end

function update()
    sw.tick()
    tmr.tick()
    pomoMod.tick()
    alarmsMod.tick()
    ring.tick()
end

local saved = store.loadData()
alarmsMod.load(saved)
pomoMod.load()
ring.load()

-- Publish initial state so panel/widget have data on first open.
sw.publish()
tmr.publish()
pomoMod.publish()
alarmsMod.publish()
ring.publish()

function onConfigChanged()
    pomoMod.onConfigChanged()
end

function onExit(_signal, _reason)
    ring.stop()
end
