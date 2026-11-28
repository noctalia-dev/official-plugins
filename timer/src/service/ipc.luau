--!nonstrict
-- Timer suite IPC router and command parser.
--   noctalia msg plugin noctalia/timer:timer all <timer|sw|pomo|alarm|ring> <action> [args]
-- `stopwatch` and `pomodoro` are accepted for `sw` and `pomo`.

local tmr = require("./timer.luau")
local sw = require("./stopwatch.luau")
local pomoMod = require("./pomo.luau")
local alarmsMod = require("./alarms.luau")
local ring = require("./ring.luau")
local utils = require("./utils.luau")

local M = {}

local function stopRingFor(mode: string)
    if ring.isActive() and ring.getMode() == mode then
        ring.stop()
    end
end

-- Parse duration strings into seconds.
-- Supports:
--   - Plain numbers: treated as minutes (e.g. "40" -> 2400) for upstream compatibility
--   - Colons: "25:00" -> 1500, "1:30:00" -> 5400
--   - Units: "40m", "30s", "1h", "1h30m"
function M.parseDuration(s: string): number?
    if not s or s == "" then return nil end
    s = s:gsub("^%s+", ""):gsub("%s+$", ""):lower()

    if s:find(":") then
        local parts = {}
        for p in s:gmatch("[^:]+") do
            table.insert(parts, tonumber(p) or 0)
        end
        if #parts == 2 then
            return parts[1] * 60 + parts[2]
        elseif #parts == 3 then
            return parts[1] * 3600 + parts[2] * 60 + parts[3]
        end
    end

    if s:find("[hms]") then
        local total = 0
        local matched = false
        local h = s:match("(%d+%.?%d*)%s*h")
        if h then total += (tonumber(h) or 0) * 3600; matched = true end
        local m = s:match("(%d+%.?%d*)%s*m")
        if m then total += (tonumber(m) or 0) * 60; matched = true end
        local sec = s:match("(%d+%.?%d*)%s*s")
        if sec then total += (tonumber(sec) or 0); matched = true end
        if matched then return math.floor(total) end
    end

    local num = tonumber(s)
    if num and num > 0 and num < math.huge then
        return math.floor(num * 60)
    end

    return nil
end

-- Parse delta strings (+/- seconds or with units like +5m, -30s).
function M.parseDelta(s: string): number?
    if not s or s == "" then return nil end
    s = s:gsub("^%s+", ""):gsub("%s+$", ""):lower()
    local sign = 1
    if s:sub(1, 1) == "-" then
        sign = -1
        s = s:sub(2)
    elseif s:sub(1, 1) == "+" then
        s = s:sub(2)
    end

    if s:find("[hms]") then
        local dur = M.parseDuration(s)
        if dur then return sign * dur end
    end

    local num = tonumber(s)
    if num then
        return sign * math.floor(num)
    end
    return nil
end

-- Days token: once | daily | weekdays | weekend | digits 1-7 (Mon-Sun), e.g. "1,3,5".
-- No days means a one-time alarm. Returns nil for anything else.
local function parseDays(token: string)
    token = token:lower()
    if token == "once" then return {} end
    if token == "daily" or token == "everyday" then return { 1, 2, 3, 4, 5, 6, 7 } end
    if token == "weekdays" then return { 1, 2, 3, 4, 5 } end
    if token == "weekend" or token == "weekends" then return { 6, 7 } end
    if not token:match("^[1-7,]+$") then return nil end
    local seen, days = {}, {}
    for d in token:gmatch("%d") do
        local n = tonumber(d)
        if n and not seen[n] then
            seen[n] = true
            table.insert(days, n)
        end
    end
    table.sort(days)
    return days
end

-- "<HH:MM> [label] [days]". Quote the label if it ends in a number or a days keyword.
function M.parseAlarmArgs(args: string)
    if not args or args == "" then return nil end
    args = args:gsub("^%s+", ""):gsub("%s+$", "")

    local hhStr, mmStr, rest = args:match("^(%d%d?):(%d%d)%s*(.*)$")
    if not hhStr then return nil end
    local hh = tonumber(hhStr)
    local mm = tonumber(mmStr)
    if not hh or not mm or hh < 0 or hh > 23 or mm < 0 or mm > 59 then
        return nil
    end

    local label = ""
    local days = {}

    if rest ~= "" then
        local quoted, afterQuote = rest:match('^"([^"]*)"%s*(.*)$')
        if not quoted then
            quoted, afterQuote = rest:match("^'([^']*)'%s*(.*)$")
        end

        if quoted then
            label = quoted
            if afterQuote ~= "" then
                local parsed = parseDays(afterQuote)
                if not parsed then return nil end
                days = parsed
            end
        else
            local head, tail = rest:match("^(.-)%s*(%S+)$")
            local parsed = tail and parseDays(tail)
            if parsed then
                label, days = head, parsed
            else
                label = rest
            end
        end
    end

    return label, hh, mm, days
end

-- Argument checks shared by the handlers: nil unless the text parses to a
-- usable value.
local function positiveDuration(args: string?): number?
    if not args or args == "" then return nil end
    local seconds = M.parseDuration(args)
    if seconds and seconds > 0 then return seconds end
    return nil
end

local function nonzeroDelta(args: string?): number?
    if not args or args == "" then return nil end
    local delta = M.parseDelta(args)
    if delta and delta ~= 0 then return delta end
    return nil
end

local function handleTimer(action: string, args: string?)
    local state = tmr.getState()

    if action == "start" then
        if args and args ~= "" then
            local seconds = positiveDuration(args)
            if seconds and state ~= "RUNNING" then
                stopRingFor("timer")
                tmr.startCountdown(seconds)
                tmr.publish()
            end
        elseif state == "IDLE" or state == "PAUSED" then
            stopRingFor("timer")
            tmr.start()
            tmr.publish()
        end

    elseif action == "pause" then
        if state == "RUNNING" then
            tmr.pause()
        elseif state == "PAUSED" then
            tmr.start()
        else
            return
        end
        tmr.publish()

    elseif action == "toggle" then
        if state == "RUNNING" then
            tmr.pause()
            tmr.publish()
        elseif state == "PAUSED" or (state == "IDLE" and tmr.getRemaining() > 0) then
            stopRingFor("timer")
            tmr.start()
            tmr.publish()
        end

    elseif action == "resume" then
        if state == "PAUSED" then
            tmr.start()
            tmr.publish()
        end

    elseif action == "reset" then
        tmr.reset()
        stopRingFor("timer")
        tmr.publish()

    elseif action == "set" then
        local seconds = positiveDuration(args)
        if seconds then
            tmr.set(seconds)
            tmr.publish()
        end

    elseif action == "adjust" then
        local delta = nonzeroDelta(args)
        if delta then
            tmr.adjust(delta)
            tmr.publish()
        end

    elseif action == "flag" then
        tmr.flag(args or "")
        tmr.publish()
    end
end

-- start / pause / toggle / resume / flag work the same for the stopwatch and
-- the pomodoro. Returns false for any other action.
local function handlePlayback(mode: any, state: string, action: string, args: string?): boolean
    if action == "start" then
        mode.start()
    elseif action == "pause" then
        mode.pause()
    elseif action == "toggle" then
        if state == "RUNNING" then mode.pause() else mode.start() end
    elseif action == "resume" then
        if state ~= "PAUSED" then return true end
        mode.start()
    elseif action == "flag" then
        mode.flag(args or "")
    else
        return false
    end
    mode.publish()
    return true
end

local function handleStopwatch(action: string, args: string?)
    if handlePlayback(sw, sw.getState(), action, args) then return end

    if action == "reset" then
        sw.reset()
        sw.publish()
    end
end

local function handlePomodoro(action: string, args: string?)
    if handlePlayback(pomoMod, pomoMod.pomo.state, action, args) then return end

    if action == "skip" then
        pomoMod.skip()
    elseif action == "reset" then
        pomoMod.resetStage()
        stopRingFor("pomo")
    elseif action == "reset_all" then
        pomoMod.reset()
        stopRingFor("pomo")
    elseif action == "loop" then
        pomoMod.toggleLoop()
    elseif action == "adjust" then
        local delta = nonzeroDelta(args)
        if not delta then return end
        pomoMod.adjust(delta)
    else
        return
    end
    pomoMod.publish()
end

local function handleAlarm(action: string, args: string?)
    if action == "add" then
        if args and args ~= "" then
            local label, hh, mm, days = M.parseAlarmArgs(args)
            if hh == nil or mm == nil then
                noctalia.notifyError("Alarm Error", "Usage: alarm add <HH:MM> [label] [once|daily|weekdays|weekend|1,2,3]")
                return
            end
            local alarm = alarmsMod.add(label, hh, mm, days)
            if alarm == nil then
                noctalia.notifyError("Alarm Error", "Too many alarms")
            else
                noctalia.notify("Alarm Added", string.format("%02d:%02d%s, rings in %s",
                    hh, mm, alarm.label ~= "" and (" - " .. alarm.label) or "",
                    utils.fmtCountdown(alarm.nextFire - utils.now())))
            end
        end

    elseif action == "toggle" then
        local id = tonumber(args)
        if id then
            alarmsMod.toggle(id)
        end

    elseif action == "remove" then
        local id = tonumber(args)
        if id then
            alarmsMod.remove(id)
        end
    end
end

local function handleRing(action: string)
    if action == "stop" then
        ring.stop()
        pomoMod.checkPending()
        local tState = noctalia.state.get("timer.timer")
        if tState and tState.state == "DONE" then
            tmr.reset()
            tmr.publish()
        end
        local pState = noctalia.state.get("timer.pomo")
        if pState and pState.state == "DONE" then
            pomoMod.reset()
            pomoMod.publish()
        end
    end
end

local HANDLERS = {
    timer = handleTimer,
    sw = handleStopwatch,
    stopwatch = handleStopwatch,
    pomo = handlePomodoro,
    pomodoro = handlePomodoro,
    alarm = handleAlarm,
    ring = handleRing,
}

-- Every event is `<mode> [action] [args]`; a mode alone toggles.
function M.handle(event: string, payload: string?)
    if not event or event == "" then return end
    event = event:gsub("^%s+", ""):gsub("%s+$", "")

    local handler = HANDLERS[event:lower()]
    if not handler then
        noctalia.log(`timer: unhandled IPC event '{event}'`)
        return
    end

    local action = "toggle"
    local args = payload
    if payload and payload ~= "" then
        local first, rest = payload:match("^([%a_%-]+)%s*(.*)$")
        if first then
            action = first:lower()
            args = rest ~= "" and rest or nil
        else
            action = payload:lower()
            args = nil
        end
    end
    handler(action, args)
end

return M
