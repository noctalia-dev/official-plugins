--!nonstrict
-- Timer — unified four-tab panel.
--

local common = require("./src/panel/common.luau")
local tr = common.tr

local alarmsTab = require("./src/panel/alarms.luau")
local stopwatchTab = require("./src/panel/stopwatch.luau")
local timerTab = require("./src/panel/timer.luau")
local pomodoroTab = require("./src/panel/pomodoro.luau")

local activeTab = "stopwatch"  -- "alarms" | "stopwatch" | "timer" | "pomodoro"
local ringing = nil
local isOpen = false

local render
common.render = function() render() end

local function tabButton(label, glyph, tab)
    local active = activeTab == tab
    return ui.button({
        key     = "tab-" .. tab,
        text    = label,
        glyph   = glyph,
        variant = active and "primary" or "ghost",
        onClick = function()
            if activeTab ~= tab then
                activeTab = tab
                render()
            end
        end,
    })
end

local function ringBanner()
    if type(ringing) ~= "table" then return nil end
    local modeLabel =
        ringing.mode == "alarm" and tr("tab.alarms")
        or (ringing.mode == "timer" and tr("tab.timer")
        or (ringing.mode == "pomo" and tr("tab.pomodoro") or ""))
    local title = (ringing.label ~= nil and ringing.label ~= "") and ringing.label or modeLabel
    return ui.row({
        key     = "ring-banner",
        gap     = 10,
        align   = "center",
        fill    = "error/0.15",
        radius  = 8,
        padding = 10,
    }, {
        ui.glyph({ name = "alarm", color = "error", size = 20 }),
        ui.column({ flexGrow = 1, gap = 1 }, {
            ui.label({ text = title, fontSize = 13, fontWeight = "bold", color = "error" }),
            ui.label({ text = tr("ring.subtitle", { mode = modeLabel }), fontSize = 10, color = "on_surface_variant" }),
        }),
        ui.button({
            key     = "ring-stop",
            glyph   = "player-stop",
            text    = tr("ring.stop"),
            variant = "primary",
            onClick = function() common.cmd("ring", "stop") end,
        }),
    })
end

render = function()
    if not isOpen then return end
    local headerRow = ui.row({ gap = 6, align = "center" }, {
        ui.label({ text = "Timer", fontSize = 14, fontWeight = "bold", color = "on_surface", flexGrow = 1 }),
        ui.button({
            key = "header-settings", glyph = "settings", variant = "ghost",
            tooltip = tr("tip.settings"), onClick = "onOpenSettings",
        }),
        ui.button({
            key = "header-close", glyph = "close", variant = "ghost",
            tooltip = tr("tip.close"), onClick = "onClosePanel",
        }),
    })

    local tabBar = ui.row({ gap = 4, align = "center" }, {
        tabButton(tr("tab.alarms"),    "bell",       "alarms"),
        tabButton(tr("tab.stopwatch"), "stopwatch",  "stopwatch"),
        tabButton(tr("tab.timer"),     "hourglass",  "timer"),
        tabButton(tr("tab.pomodoro"),  "brain",      "pomodoro"),
    })

    local content
    if activeTab == "alarms"    then content = alarmsTab.render()
    elseif activeTab == "stopwatch" then content = stopwatchTab.render()
    elseif activeTab == "timer" then content = timerTab.render()
    else content = pomodoroTab.render()
    end

    local kids = { headerRow, tabBar, ui.separator({}) }
    local banner = ringBanner()
    if banner then table.insert(kids, banner) end
    table.insert(kids, ui.scroll({
        key = "panel-body-" .. activeTab,
        flexGrow = 1, gap = 10, align = "stretch",
    }, { content }))

    panel.render(ui.column({ flexGrow = 1, gap = 10, align = "stretch" }, kids))
end

function onOpen(_context)
    isOpen = true
    stopwatchTab.sw = noctalia.state.get("timer.sw") or stopwatchTab.sw
    timerTab.tmr    = noctalia.state.get("timer.timer") or timerTab.tmr
    pomodoroTab.pomo = noctalia.state.get("timer.pomo") or pomodoroTab.pomo
    alarmsTab.alarmList = noctalia.state.get("timer.alarms") or {}
    ringing         = noctalia.state.get("timer.ringing")
    render()
end

function onClose()
    isOpen = false
    alarmsTab.closeForm()
    stopwatchTab.closeForm()
    timerTab.closeForm()
    pomodoroTab.closeForm()
end

noctalia.state.watch("timer.sw", function(v)
    if v then stopwatchTab.sw = v end
    render()
end)

noctalia.state.watch("timer.timer", function(v)
    if v then timerTab.tmr = v end
    render()
end)

noctalia.state.watch("timer.pomo", function(v)
    if v then pomodoroTab.pomo = v end
    render()
end)

noctalia.state.watch("timer.alarms", function(v)
    if v then alarmsTab.alarmList = v end
    render()
end)

noctalia.state.watch("timer.ringing", function(v)
    ringing = v
    render()
end)

function onOpenSettings()
    noctalia.openSettings()
end

function onClosePanel()
    panel.close()
end
