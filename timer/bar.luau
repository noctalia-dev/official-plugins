--!nonstrict
-- Timer — bar widget.
--
-- Shows active timers based on display mode (smart, all).

local PANEL_ID = "noctalia/timer:panel"

local sw   = { state = "IDLE", display = "00:00" }
local tmr  = { state = "IDLE", display = "00:00" }
local pomo = { state = "IDLE", display = "25:00", stageType = "work", stageLabel = "Focus" }
local ringing = nil   -- { mode, label, since } while an alert is ringing

local DEFAULT_ORDER = "timer,sw,pomo"
local KNOWN = { timer = true, pomo = true, sw = true }
local orderCache = { key = nil, list = nil }

-- `priority_order` is one of six fixed permutations, e.g. "timer,sw,pomo".
local function getPriorityList()
    local raw = noctalia.getConfig("priority_order")
    if raw == orderCache.key and orderCache.list then return orderCache.list end
    local function parse(str)
        local list, seen = {}, {}
        for item in string.gmatch(str, "[^,]+") do
            if not KNOWN[item] or seen[item] then return nil end
            seen[item] = true
            table.insert(list, item)
        end
        return #list == 3 and list or nil
    end
    local list = (type(raw) == "string" and parse(raw)) or parse(DEFAULT_ORDER)
    orderCache.key, orderCache.list = raw, list
    return list
end

local function getTimerData(mode)
    if mode == "timer" then
        if tmr.state == "RUNNING" or tmr.state == "PAUSED" then
            return { display = tmr.display, glyph = "hourglass", color = tmr.state == "RUNNING" and "primary" or "on_surface_variant" }
        elseif tmr.state == "DONE" then
            return { display = "0:00", glyph = "hourglass", color = "error" }
        end
    elseif mode == "pomo" then
        if pomo.state == "RUNNING" or pomo.state == "PAUSED" then
            return { display = pomo.display, glyph = pomo.stageType == "work" and "brain" or "coffee", color = pomo.state == "RUNNING" and "primary" or "on_surface_variant" }
        elseif pomo.state == "DONE" then
            return { display = "0:00", glyph = "brain", color = "error" }
        end
    elseif mode == "sw" then
        if sw.state == "RUNNING" or sw.state == "PAUSED" then
            return { display = sw.display, glyph = "stopwatch", color = sw.state == "RUNNING" and "primary" or "on_surface_variant" }
        end
    end
    return nil
end

local function render()
    local mode = noctalia.getConfig("bar_display_mode") or "smart"
    local showTime = noctalia.getConfig("show_time") ~= false

    -- An active ring overrides everything: alarm bell + label, click to silence.
    if type(ringing) == "table" then
        local liveDisplay = ringing.label
        local liveGlyph = "alarm"
        local liveColor = "error"

        local isVertical = barWidget.isVertical()
        if isVertical then
            local content = { ui.glyph({ name = liveGlyph, color = liveColor }) }
            if showTime and liveDisplay and liveDisplay ~= "" then
                table.insert(content, ui.label({ text = liveDisplay, color = liveColor, textAlign = "center", fontSize = 10 }))
            end
            barWidget.render(ui.column({ gap = 2, align = "center" }, content))
        else
            local content = { ui.glyph({ name = liveGlyph, color = liveColor }) }
            if showTime and liveDisplay and liveDisplay ~= "" then
                table.insert(content, ui.label({ text = liveDisplay, fontWeight = "bold", color = liveColor }))
            end
            barWidget.render(ui.row({ gap = 4, align = "center" }, content))
        end
    else
        local activeItems = {}
        local order = mode == "smart" and getPriorityList() or { "timer", "pomo", "sw" }
        
        for _, k in ipairs(order) do
            local data = getTimerData(k)
            if data then
                table.insert(activeItems, data)
                if mode == "smart" then break end
            end
        end
        
        if #activeItems == 0 then
            activeItems = { { display = nil, glyph = "clock", color = "on_surface" } }
        end

        local isVertical = barWidget.isVertical()
        local content = {}
        
        for i, item in ipairs(activeItems) do
            if i > 1 then
                table.insert(content, ui.label({ text = "•", color = "on_surface_variant" }))
            end
            table.insert(content, ui.glyph({ name = item.glyph, color = item.color }))
            if showTime and item.display then
                if isVertical then
                    table.insert(content, ui.label({ text = item.display, color = item.color, textAlign = "center", fontSize = 10 }))
                else
                    table.insert(content, ui.label({ text = item.display, fontWeight = "bold", color = item.color }))
                end
            end
        end

        if isVertical then
            barWidget.render(ui.column({ gap = 2, align = "center" }, content))
        else
            barWidget.render(ui.row({ gap = 4, align = "center" }, content))
        end
    end

    local tooltipRows = {}
    if tmr.state ~= "IDLE" then
        table.insert(tooltipRows, { key = "Timer", value = tmr.display .. " (" .. tmr.state .. ")" })
    end
    if pomo.state ~= "IDLE" then
        table.insert(tooltipRows, { key = "Pomodoro", value = pomo.display .. " · " .. (pomo.stageLabel or "") })
    end
    if sw.state ~= "IDLE" then
        table.insert(tooltipRows, { key = "Stopwatch", value = sw.display })
    end
    if type(ringing) == "table" then
        table.insert(tooltipRows, 1, { key = "Ringing", value = (ringing.label ~= "" and ringing.label or ringing.mode or "") .. " — click to stop" })
    end
    if #tooltipRows > 0 then
        barWidget.setTooltip(tooltipRows)
    else
        barWidget.setTooltip("Timer — click to open")
    end
end

noctalia.state.watch("timer.sw",      function(v) if v then sw   = v end ; render() end)
noctalia.state.watch("timer.timer",   function(v) if v then tmr  = v end ; render() end)
noctalia.state.watch("timer.pomo",    function(v) if v then pomo = v end ; render() end)
noctalia.state.watch("timer.ringing", function(v) ringing = v ; render() end)

function update()
    render()
end

function onClick()
    if type(ringing) == "table" then
        noctalia.state.set("timer.cmd", { mode = "ring", action = "stop", nonce = math.floor(noctalia.nowMs()) * 1000 })
    end
    noctalia.togglePanel(PANEL_ID)
end

render()
