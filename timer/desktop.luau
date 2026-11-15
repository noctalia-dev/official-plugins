--!nonstrict
-- Countdown Timer & Unified Desktop Widget — [[desktop_widget]] client.
--
-- Reflects state from the headless timer service and allows mouse-based control.
-- Modes:
--   - "timer" (default): Countdown Timer
--   - "stopwatch": Stopwatch with lap tracking
--   - "pomodoro": Pomodoro with focus/break cycle
--   - "smart": Automatically shows the active mode

local desktopTimer = require("./src/desktop/timer.luau")
local desktopSw = require("./src/desktop/stopwatch.luau")
local desktopPomo = require("./src/desktop/pomodoro.luau")

local mode = noctalia.getConfig("mode") or "timer"
local color = noctalia.getConfig("color") or "primary"
local showProgress = noctalia.getConfig("show_progress") ~= false
local showFlags = noctalia.getConfig("show_flags") == true
local showDots = noctalia.getConfig("show_dots") ~= false

local tmr = { state = "IDLE", remaining = 0, duration = 0, display = "00:00", flags = {} }
local sw = { state = "IDLE", elapsed = 0, display = "00:00", flags = {} }
local pomo = { state = "IDLE", remaining = 1500, duration = 1500, display = "25:00", stageLabel = "Focus" }
local ringing = nil

local function render()
    local resolvedMode = mode

    if resolvedMode == "smart" then
        if type(ringing) == "table" and ringing.mode then
            resolvedMode = ringing.mode
        elseif tmr.state == "RUNNING" or tmr.state == "PAUSED" or tmr.state == "DONE" then
            resolvedMode = "timer"
        elseif pomo.state == "RUNNING" or pomo.state == "PAUSED" or pomo.state == "DONE" then
            resolvedMode = "pomodoro"
        elseif sw.state == "RUNNING" or sw.state == "PAUSED" then
            resolvedMode = "stopwatch"
        else
            resolvedMode = "timer"
        end
    end

    local tree
    if resolvedMode == "stopwatch" or resolvedMode == "sw" then
        tree = desktopSw.render(sw, { color = color, showFlags = showFlags })
    elseif resolvedMode == "pomodoro" or resolvedMode == "pomo" then
        tree = desktopPomo.render(pomo, ringing, { color = color, showProgress = showProgress, showDots = showDots })
    else
        tree = desktopTimer.render(tmr, ringing, { color = color, showProgress = showProgress, showFlags = showFlags })
    end

    desktopWidget.render(tree)
end

noctalia.state.watch("timer.timer", function(v)
    if v then tmr = v end
    render()
end)

noctalia.state.watch("timer.sw", function(v)
    if v then sw = v end
    render()
end)

noctalia.state.watch("timer.pomo", function(v)
    if v then pomo = v end
    render()
end)

noctalia.state.watch("timer.ringing", function(v)
    ringing = v
    render()
end)

function onConfigChanged()
    mode = noctalia.getConfig("mode") or "timer"
    color = noctalia.getConfig("color") or "primary"
    showProgress = noctalia.getConfig("show_progress") ~= false
    showFlags = noctalia.getConfig("show_flags") == true
    showDots = noctalia.getConfig("show_dots") ~= false
    render()
end

tmr = noctalia.state.get("timer.timer") or tmr
sw = noctalia.state.get("timer.sw") or sw
pomo = noctalia.state.get("timer.pomo") or pomo
ringing = noctalia.state.get("timer.ringing")

render()
