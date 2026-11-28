--!nonstrict
local common = require("./common.luau")
local tr = common.tr

local M = {}

M.pomo = {
    state = "IDLE", stageLabel = "Focus", stageType = "work",
    remaining = 0, duration = 1500, display = "25:00", progress = 0,
    looping = false, sessionsCompleted = 0, stageIdx = 1, stageCount = 2,
    schedule = {}, flags = {},
}

local renamingFlagId = nil
local renameDraft = ""
local function setRenamingFlagId(id) renamingFlagId = id end
local function setRenameDraft(v) renameDraft = v end


function M.closeForm()
    renamingFlagId = nil
    renameDraft = ""
end


function M.render()
    local pomo = M.pomo
    local _isIdle   = pomo.state == "IDLE"
    local isRunning = pomo.state == "RUNNING"
    local isPaused  = pomo.state == "PAUSED"
    local isDone    = pomo.state == "DONE"
    local isActive  = isRunning or isPaused

    local dots = {}
    for i = 1, pomo.stageCount do
        local isCurrentStage = i == pomo.stageIdx
        local stage = pomo.schedule[i]
        local dotColor = isCurrentStage and "primary" or "on_surface_variant/0.3"
        local dotW = (stage and stage.type == "work") and 10 or 6
        table.insert(dots, ui.box({
            key    = "dot-" .. i,
            width  = dotW,
            height = dotW,
            radius = dotW,
            fill   = dotColor,
        }))
    end

    local clockColor = isDone and "error" or (isRunning and "primary" or (isPaused and "on_surface_variant" or "outline"))
    local stageIcon  = pomo.stageType == "work" and "brain" or "coffee"

    local header = ui.row({ align = "center", gap = 8 }, {
        ui.glyph({ name = stageIcon, color = clockColor, size = 16 }),
        ui.label({
            text       = pomo.stageLabel,
            fontSize   = 14,
            fontWeight = "bold",
            color      = clockColor,
            flexGrow   = 1,
        }),
        ui.label({
            text     = string.format("%d/%d", pomo.stageIdx, pomo.stageCount),
            fontSize = 11,
            color    = "on_surface_variant",
        }),
        ui.button({
            key     = "loop-" .. tostring(pomo.looping),
            glyph   = pomo.looping and "repeat" or "repeat-off",
            variant = pomo.looping and "primary" or "ghost",
            tooltip = pomo.looping and tr("pomo.loop_on") or tr("pomo.loop_off"),
            onClick = function() common.cmd("pomo", "toggle_loop") end,
        }),
        ui.label({
            text     = string.format("✓ %d", pomo.sessionsCompleted),
            fontSize = 11,
            color    = "on_surface_variant",
        }),
    })

    local dotRow = ui.row({ gap = 4, align = "center", justify = "center" }, dots)

    local clock = ui.column({ align = "center", gap = 8 }, {
        ui.label({
            text       = pomo.display,
            fontSize   = 52,
            fontWeight = "bold",
            color      = clockColor,
        }),
        ui.progress({
            progress = pomo.progress,
            height   = 4,
            radius   = 2,
        }),
    })

    local adjustRow = ui.row({ gap = 6, justify = "center" }, {
        ui.button({ key = "padj--60", text = "-1m", variant = "ghost", controlSize = "sm", onClick = function() common.cmd("pomo", "adjust_remaining", -60) end }),
        ui.button({ key = "padj-60",  text = "+1m", variant = "ghost", controlSize = "sm", onClick = function() common.cmd("pomo", "adjust_remaining", 60) end }),
    })

    local controls = ui.row({ gap = 6, justify = "center" }, {
        ui.button({
            key     = "pctl-reset",
            glyph   = "refresh",
            text    = tr("reset"),
            variant = "ghost",
            enabled = isActive or isDone,
            onClick = function() common.cmd("pomo", "reset") end,
        }),
        ui.button({
            key      = "pctl-toggle",
            glyph    = isRunning and "player-pause" or "player-play",
            text     = isRunning and tr("pause") or (isPaused and tr("resume") or tr("start")),
            variant  = "primary",
            flexGrow = 1,
            enabled  = not isDone,
            onClick  = function()
                if isRunning then common.cmd("pomo", "pause") else common.cmd("pomo", "start") end
            end,
        }),
        ui.button({
            key     = "pctl-skip",
            glyph   = "player-skip-forward",
            text    = tr("pomo.skip"),
            variant = "ghost",
            enabled = isActive,
            onClick = function() common.cmd("pomo", "skip") end,
        }),
    })

    local flagBtn = ui.button({
        key     = "pctl-flag",
        glyph   = "flag",
        text    = tr("flag"),
        variant = "ghost",
        enabled = isActive,
        onClick = function() common.cmd("pomo", "flag", "") end,
    })

    local resetAll = ui.button({
        key     = "pctl-reset-all",
        glyph   = "rotate",
        text    = tr("pomo.reset_all"),
        variant = "ghost",
        enabled = pomo.sessionsCompleted > 0 or pomo.stageIdx > 1 or isActive,
        onClick = function() common.cmd("pomo", "reset_all") end,
    })


    local parts = {
        header,
        dotRow,
        clock,
        adjustRow,
        controls,
        ui.row({ gap = 6, justify = "space_between", align = "center" }, {
            resetAll,
            flagBtn,
        }),
    }


    local flagsSection = common.flagList(pomo.flags, "pomo", renamingFlagId, setRenamingFlagId, renameDraft, setRenameDraft)
    if flagsSection then
        table.insert(parts, ui.separator({}))
        table.insert(parts, ui.row({ justify = "space_between", align = "center" }, {
            ui.label({ text = tr("flags_label"), fontSize = 11, color = "on_surface_variant" }),
            ui.button({
                glyph = "copy",
                variant = "ghost",
                controlSize = "sm",
                tooltip = tr("tip.copy_flags"),
                onClick = function() common.copyFlags("Pomodoro Flags:", pomo.flags) end
            })
        }))
        table.insert(parts, flagsSection)
    end

    return ui.column({ gap = 10, align = "stretch" }, parts)
end

return M
