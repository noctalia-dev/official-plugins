--!nonstrict
-- Pomodoro Desktop Widget — dedicated [[desktop_widget]] client.

local desktopPomo = require("./src/desktop/pomodoro.luau")

local color = noctalia.getConfig("color") or "primary"
local showProgress = noctalia.getConfig("show_progress") ~= false
local showDots = noctalia.getConfig("show_dots") ~= false

local pomo = {
    state = "IDLE", stageLabel = "Focus", stageType = "work",
    remaining = 1500, duration = 1500, display = "25:00", progress = 0,
    looping = false, sessionsCompleted = 0, stageIdx = 1, stageCount = 4,
    schedule = {}, flags = {},
}
local ringing = nil

local function render()
    local tree = desktopPomo.render(pomo, ringing, {
        color = color,
        showProgress = showProgress,
        showDots = showDots,
    })
    desktopWidget.render(tree)
end

noctalia.state.watch("timer.pomo", function(v)
    if v then pomo = v end
    render()
end)

noctalia.state.watch("timer.ringing", function(v)
    ringing = v
    render()
end)

function onConfigChanged()
    color = noctalia.getConfig("color") or "primary"
    showProgress = noctalia.getConfig("show_progress") ~= false
    showDots = noctalia.getConfig("show_dots") ~= false
    render()
end

pomo = noctalia.state.get("timer.pomo") or pomo
ringing = noctalia.state.get("timer.ringing")
render()
