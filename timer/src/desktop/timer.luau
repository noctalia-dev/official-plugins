--!nonstrict
-- Countdown Timer component for desktop widget.

local common = require("./common.luau")
local tr = common.tr

local M = {}

function M.render(tmr: any?, ringing: any?, opts: { color: string?, showProgress: boolean?, showFlags: boolean? }?)
    tmr = tmr or { state = "IDLE", remaining = 0, duration = 0, display = "00:00", flags = {} }
    local o = opts or {}
    local color = o.color or "primary"
    local showProgress = o.showProgress ~= false
    local showFlags = o.showFlags == true

    local isIdle = tmr.state == "IDLE"
    local isRunning = tmr.state == "RUNNING"
    local isPaused = tmr.state == "PAUSED"
    local isDone = tmr.state == "DONE"
    local isActive = isRunning or isPaused

    local timeColor = "outline"
    if isDone or (type(ringing) == "table" and ringing.mode == "timer") then
        timeColor = "error"
    elseif isRunning then
        timeColor = color
    elseif isPaused then
        timeColor = "on_surface_variant"
    elseif isIdle and tmr.remaining > 0 then
        timeColor = "on_surface"
    end

    local displayStr = tmr.display
    if isIdle and (tmr.remaining == 0 or not displayStr or displayStr == "") then
        displayStr = "--:--"
    end

    local rows = {}

    local banner = common.ringBanner(ringing)
    if banner then
        table.insert(rows, banner)
    end

    table.insert(rows, ui.row({ key = "desk-tmr-header", gap = 4, align = "center", justify = "center" }, {
        ui.glyph({ name = "hourglass", size = 14, color = isRunning and color or "on_surface_variant" }),
        ui.label({ text = tr("tab.timer"), fontSize = 12, fontWeight = "medium", color = "on_surface_variant" }),
    }))

    table.insert(rows, ui.label({
        key = "desk-tmr-display",
        text = displayStr,
        fontSize = 38,
        fontWeight = "bold",
        color = timeColor,
        textAlign = "center",
    }))

    if showProgress then
        local ratio = (tmr.duration > 0 and tmr.remaining > 0) and (tmr.remaining / tmr.duration) or 0
        table.insert(rows, ui.progress({
            key = "desk-tmr-progress",
            progress = ratio,
            fill = color,
            width = 160,
            height = 6,
            radius = 3,
        }))
    end

    if isIdle or isPaused then
        table.insert(rows, ui.row({ key = "desk-tmr-adjust", gap = 4, justify = "center" }, {
            ui.button({
                key = "desk-tadj--5m", text = "-5m", variant = "ghost", controlSize = "sm",
                onClick = function() common.cmd("timer", "adjust", -300) end,
            }),
            ui.button({
                key = "desk-tadj--1m", text = "-1m", variant = "ghost", controlSize = "sm",
                onClick = function() common.cmd("timer", "adjust", -60) end,
            }),
            ui.button({
                key = "desk-tadj--30s", text = "-30s", variant = "ghost", controlSize = "sm",
                onClick = function() common.cmd("timer", "adjust", -30) end,
            }),
            ui.button({
                key = "desk-tadj-+30s", text = "+30s", variant = "ghost", controlSize = "sm",
                onClick = function() common.cmd("timer", "adjust", 30) end,
            }),
            ui.button({
                key = "desk-tadj-+1m", text = "+1m", variant = "ghost", controlSize = "sm",
                onClick = function() common.cmd("timer", "adjust", 60) end,
            }),
            ui.button({
                key = "desk-tadj-+5m", text = "+5m", variant = "ghost", controlSize = "sm",
                onClick = function() common.cmd("timer", "adjust", 300) end,
            }),
        }))
    end

    local toggleText = isRunning and tr("pause") or (isPaused and tr("resume") or tr("start"))
    local toggleGlyph = isRunning and "player-pause" or "player-play"
    local toggleVariant = isRunning and "secondary" or "primary"

    local controls = {
        ui.button({
            key = "desk-tmr-reset",
            glyph = "refresh",
            text = tr("reset"),
            variant = isDone and "primary" or "ghost",
            controlSize = "sm",
            enabled = isActive or isDone or tmr.remaining > 0,
            onClick = function() common.cmd("timer", "reset") end,
        }),
        ui.button({
            key = "desk-tmr-toggle",
            glyph = toggleGlyph,
            text = toggleText,
            variant = toggleVariant,
            controlSize = "sm",
            enabled = not isDone and (isActive or tmr.remaining > 0),
            onClick = function()
                if isRunning then
                    common.cmd("timer", "pause")
                else
                    common.cmd("timer", "start")
                end
            end,
        }),
        ui.button({
            key = "desk-tmr-flag",
            glyph = "flag",
            variant = "ghost",
            controlSize = "sm",
            enabled = isActive,
            onClick = function() common.cmd("timer", "flag", "") end,
        }),
    }
    table.insert(rows, ui.row({ key = "desk-tmr-controls", gap = 6, justify = "center" }, controls))

    if showFlags and type(tmr.flags) == "table" and #tmr.flags > 0 then
        local latest = tmr.flags[#tmr.flags]
        table.insert(rows, ui.row({ key = "desk-tmr-last-flag", gap = 4, justify = "center", align = "center" }, {
            ui.glyph({ name = "flag", size = 11, color = "on_surface_variant" }),
            ui.label({
                text = string.format("%s: %s", latest.name, latest.display or ""),
                fontSize = 11,
                color = "on_surface_variant",
            }),
        }))
    end

    return ui.column({ gap = 8, align = "center" }, rows)
end

return M
