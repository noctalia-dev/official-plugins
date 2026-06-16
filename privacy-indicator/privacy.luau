-- Privacy Indicator — bar widget (thin presentation client).
--
-- The detection logic lives in the [[service]] (privacy_service.luau). This
-- widget only reflects the published "status" state.

local lastStatus = nil

local function buildTooltip(status)
    if not status then return "Privacy Status" end
    local parts = {}
    if status.micActive and #status.micApps > 0 then
        table.insert(parts, "Mic: " .. table.concat(status.micApps, ", "))
    end
    if status.camActive and #status.camApps > 0 then
        table.insert(parts, "Cam: " .. table.concat(status.camApps, ", "))
    end
    if status.scrActive and #status.scrApps > 0 then
        table.insert(parts, "Screen: " .. table.concat(status.scrApps, ", "))
    end
    if #parts == 0 then
        return "No active capture streams"
    end
    return table.concat(parts, "\n")
end

local function applyStatus(status)
    lastStatus = status
    if type(status) ~= "table" then return end

    local hideInactive = noctalia.getConfig("hide_inactive")
    local activeColor = noctalia.getConfig("active_color") or "error"
    local inactiveColor = noctalia.getConfig("inactive_color") or "none"

    local activeCount = 0
    if status.micActive then activeCount += 1 end
    if status.camActive then activeCount += 1 end
    if status.scrActive then activeCount += 1 end

    local isAnyActive = activeCount > 0

    if not isAnyActive then
        barWidget.setGlyph("eye-off")
        barWidget.setGlyphColor(inactiveColor)
        barWidget.setColor(inactiveColor)
        barWidget.setText("")
        barWidget.setTooltip("No active capture streams")
        barWidget.setVisible(not hideInactive)
        return
    end

    local glyph = "eye"
    local text = ""

    if activeCount == 1 then
        if status.micActive then
            glyph = "microphone"
            text = "Mic"
        elseif status.camActive then
            glyph = "camera"
            text = "Cam"
        elseif status.scrActive then
            glyph = "screen-share"
            text = "Screen"
        end
    else
        glyph = "eye"
        text = "Privacy"
    end

    barWidget.setGlyph(glyph)
    barWidget.setGlyphColor(activeColor)
    barWidget.setColor(activeColor)
    barWidget.setText(text)
    barWidget.setTooltip(buildTooltip(status))
    barWidget.setVisible(true)
end

function onClick()
    noctalia.runAsync("noctalia msg settings-open")
end

applyStatus(noctalia.state.get("status") or {
    micActive = false,
    micApps = {},
    camActive = false,
    camApps = {},
    scrActive = false,
    scrApps = {}
})

noctalia.state.watch("status", applyStatus)
