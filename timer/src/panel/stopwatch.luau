--!nonstrict
local common = require("./common.luau")
local tr = common.tr

local M = {}

M.sw = { state = "IDLE", elapsed = 0, display = "00:00", flags = {} }

local renamingFlagId = nil
local renameDraft = ""
local function setRenamingFlagId(id) renamingFlagId = id end
local function setRenameDraft(v) renameDraft = v end

function M.closeForm()
    renamingFlagId = nil
    renameDraft = ""
end

function M.render()
    local sw = M.sw
    local isRunning = sw.state == "RUNNING"
    local isPaused  = sw.state == "PAUSED"
    local isActive  = isRunning or isPaused

    local clockColor = isRunning and "primary" or (isPaused and "on_surface_variant" or "outline")
    local clock = ui.column({ align = "center", gap = 4 }, {
        ui.label({
            text       = sw.display,
            fontSize   = 52,
            fontWeight = "bold",
            color      = clockColor,
        }),
    })

    local controls = ui.row({ gap = 8, justify = "center" }, {
        ui.button({
            key     = "swctl-reset",
            glyph   = "refresh",
            text    = tr("reset"),
            variant = "ghost",
            enabled = isActive,
            onClick = function() common.cmd("sw", "reset") end,
        }),
        ui.button({
            key      = "swctl-toggle",
            glyph    = isRunning and "player-pause" or "player-play",
            text     = isRunning and tr("pause") or (isPaused and tr("resume") or tr("start")),
            variant  = "primary",
            flexGrow = 1,
            onClick  = function()
                if isRunning then common.cmd("sw", "pause") else common.cmd("sw", "start") end
            end,
        }),
        ui.button({
            key     = "swctl-flag",
            glyph   = "flag",
            text    = tr("flag"),
            variant = "ghost",
            enabled = isActive,
            onClick = function() common.cmd("sw", "flag", "") end,
        }),
    })

    local parts = { clock, controls }

    local flagsSection = common.flagList(sw.flags, "sw", renamingFlagId, setRenamingFlagId, renameDraft, setRenameDraft)
    if flagsSection then
        table.insert(parts, ui.separator({}))
        table.insert(parts, ui.row({ justify = "space_between", align = "center" }, {
            ui.label({ text = tr("flags_label"), fontSize = 11, color = "on_surface_variant" }),
            ui.button({
                glyph = "copy",
                variant = "ghost",
                controlSize = "sm",
                tooltip = tr("tip.copy_flags"),
                onClick = function() common.copyFlags("Stopwatch Flags:", sw.flags) end
            })
        }))
        table.insert(parts, flagsSection)
    end

    return ui.column({ gap = 12, align = "stretch" }, parts)
end

return M
