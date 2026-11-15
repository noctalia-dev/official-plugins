--!nonstrict
-- Pomodoro component for desktop widget.

local common = require("./common.luau")
local tr = common.tr

local M = {}

function M.render(pomo: any?, ringing: any?, opts: { color: string?, showProgress: boolean?, showDots: boolean? }?)
    pomo = pomo or {
        state = "IDLE", stageLabel = "Focus", stageType = "work",
        remaining = 1500, duration = 1500, display = "25:00", progress = 0,
        looping = false, sessionsCompleted = 0, stageIdx = 1, stageCount = 4,
        schedule = {}, flags = {},
    }
    local o = opts or {}
    local color = o.color or "primary"
    local showProgress = o.showProgress ~= false
    local showDots = o.showDots ~= false

    local isRunning = pomo.state == "RUNNING"
    local isPaused = pomo.state == "PAUSED"
    local isDone = pomo.state == "DONE"
    local isActive = isRunning or isPaused

    local timeColor = "outline"
    if isDone or (type(ringing) == "table" and ringing.mode == "pomo") then
        timeColor = "error"
    elseif isRunning then
        timeColor = color
    elseif isPaused then
        timeColor = "on_surface_variant"
    elseif pomo.remaining and pomo.remaining > 0 then
        timeColor = "on_surface"
    end

    local rows = {}

    local banner = common.ringBanner(ringing)
    if banner then
        table.insert(rows, banner)
    end

    local stageIcon = pomo.stageType == "work" and "brain" or "coffee"
    table.insert(rows, ui.row({ key = "desk-pomo-header", gap = 6, align = "center", justify = "center" }, {
        ui.glyph({ name = stageIcon, size = 14, color = isRunning and color or "on_surface_variant" }),
        ui.label({
            text = pomo.stageLabel or "Focus",
            fontSize = 12,
            fontWeight = "bold",
            color = isRunning and color or "on_surface_variant",
        }),
        ui.label({
            text = string.format("%d/%d", pomo.stageIdx or 1, pomo.stageCount or 4),
            fontSize = 11,
            color = "on_surface_variant",
        }),
        ui.button({
            key = "desk-pomo-loop-" .. tostring(pomo.looping),
            glyph = pomo.looping and "repeat" or "repeat-off",
            variant = pomo.looping and "primary" or "ghost",
            controlSize = "sm",
            tooltip = pomo.looping and tr("pomo.loop_on") or tr("pomo.loop_off"),
            onClick = function() common.cmd("pomo", "toggle_loop") end,
        }),
        ui.label({
            text = string.format("✓ %d", pomo.sessionsCompleted or 0),
            fontSize = 11,
            color = "on_surface_variant",
        }),
    }))

    if showDots and pomo.stageCount and pomo.stageCount > 1 then
        local dots = {}
        for i = 1, pomo.stageCount do
            local isCurrent = i == pomo.stageIdx
            local stage = type(pomo.schedule) == "table" and pomo.schedule[i] or nil
            local dotColor = isCurrent and color or "on_surface_variant/0.3"
            local dotW = (stage and stage.type == "work") and 8 or 5
            table.insert(dots, ui.box({
                key = "desk-pomo-dot-" .. i,
                width = dotW,
                height = dotW,
                radius = dotW,
                fill = dotColor,
            }))
        end
        table.insert(rows, ui.row({ key = "desk-pomo-dots", gap = 4, align = "center", justify = "center" }, dots))
    end

    table.insert(rows, ui.label({
        key = "desk-pomo-display",
        text = pomo.display or "25:00",
        fontSize = 38,
        fontWeight = "bold",
        color = timeColor,
        textAlign = "center",
    }))

    if showProgress then
        table.insert(rows, ui.progress({
            key = "desk-pomo-progress",
            progress = pomo.progress or 0,
            fill = color,
            width = 160,
            height = 6,
            radius = 3,
        }))
    end

    table.insert(rows, ui.row({ key = "desk-pomo-adjust", gap = 4, justify = "center" }, {
        ui.button({
            key = "desk-padj--1m", text = "-1m", variant = "ghost", controlSize = "sm",
            onClick = function() common.cmd("pomo", "adjust_remaining", -60) end,
        }),
        ui.button({
            key = "desk-padj-+1m", text = "+1m", variant = "ghost", controlSize = "sm",
            onClick = function() common.cmd("pomo", "adjust_remaining", 60) end,
        }),
    }))

    local toggleText = isRunning and tr("pause") or (isPaused and tr("resume") or tr("start"))
    local toggleGlyph = isRunning and "player-pause" or "player-play"
    local toggleVariant = isRunning and "secondary" or "primary"

    local controls = {
        ui.button({
            key = "desk-pomo-reset",
            glyph = "refresh",
            text = tr("reset"),
            variant = "ghost",
            controlSize = "sm",
            enabled = isActive or isDone,
            onClick = function() common.cmd("pomo", "reset") end,
        }),
        ui.button({
            key = "desk-pomo-toggle",
            glyph = toggleGlyph,
            text = toggleText,
            variant = toggleVariant,
            controlSize = "sm",
            enabled = not isDone,
            onClick = function()
                if isRunning then
                    common.cmd("pomo", "pause")
                else
                    common.cmd("pomo", "start")
                end
            end,
        }),
        ui.button({
            key = "desk-pomo-skip",
            glyph = "player-skip-forward",
            text = tr("pomo.skip"),
            variant = "ghost",
            controlSize = "sm",
            enabled = isActive,
            onClick = function() common.cmd("pomo", "skip") end,
        }),
    }
    table.insert(rows, ui.row({ key = "desk-pomo-controls", gap = 6, justify = "center" }, controls))

    return ui.column({ gap = 8, align = "center" }, rows)
end

return M
