--!nonstrict
local common = require("./common.luau")
local tr = common.tr

local M = {}

M.tmr = { state = "IDLE", remaining = 0, duration = 0, display = "00:00", flags = {} }

local renamingFlagId = nil
local renameDraft = ""
local timerInputStr = ""
local timerInputKey = 0

local function setRenamingFlagId(id) renamingFlagId = id end
local function setRenameDraft(v) renameDraft = v end

function M.closeForm()
    renamingFlagId = nil
    renameDraft = ""
end

local PRESETS = {
    { "1m", 60, "100" }, { "5m", 300, "500" }, { "10m", 600, "1000" },
    { "15m", 900, "1500" }, { "25m", 1500, "2500" }, { "30m", 1800, "3000" },
    { "1h", 3600, "010000" },
}

local function presetButtons()
    local buttons = {}
    for _, p in ipairs(PRESETS) do
        local text, seconds, input = p[1], p[2], p[3]
        table.insert(buttons, ui.button({
            key = "tpreset-" .. text, text = text, variant = "ghost", controlSize = "sm",
            onClick = function()
                timerInputStr = input
                timerInputKey += 1
                common.cmd("timer", "set", seconds)
                common.render()
            end,
        }))
    end
    return buttons
end

function M.render()
    local tmr = M.tmr
    local isIdle    = tmr.state == "IDLE"
    local isRunning = tmr.state == "RUNNING"
    local isPaused  = tmr.state == "PAUSED"
    local isDone    = tmr.state == "DONE"
    local isActive  = isRunning or isPaused

    local clockColor = isDone and "error" or (isRunning and "primary" or (isPaused and "on_surface_variant" or "outline"))
    local clock = ui.column({ align = "center", gap = 8 }, {
        ui.label({
            text       = tmr.display,
            fontSize   = 52,
            fontWeight = "bold",
            color      = clockColor,
        }),
    })

    local inputSection = nil
    if isIdle then
        inputSection = ui.column({ gap = 6, align = "stretch" }, {
            ui.label({ text = tr("timer.set_label"), fontSize = 11, color = "on_surface_variant" }),
            ui.input({
                key         = "timer-input-" .. timerInputKey,
                value       = timerInputStr,
                placeholder = tr("timer.input_placeholder"),
                onChange    = function(v)
                    timerInputStr = v
                    common.cmd("timer", "set", common.parseTimeStr(v))
                end,
                onSubmit = function(v)
                    common.cmd("timer", "set_start", common.parseTimeStr(v ~= nil and v ~= "" and v or timerInputStr))
                end,
            }),
            ui.row({ gap = 6, justify = "space_between" }, presetButtons()),
        })
    end

    local adjustRow = ui.row({ gap = 6, justify = "center" }, {
        ui.button({ key = "tadj--300", text = "-5m",  variant = "ghost", controlSize = "sm", onClick = function() common.cmd("timer", "adjust", -300) end }),
        ui.button({ key = "tadj--60", text = "-1m",  variant = "ghost", controlSize = "sm", onClick = function() common.cmd("timer", "adjust", -60) end }),
        ui.button({ key = "tadj--30", text = "-30s", variant = "ghost", controlSize = "sm", onClick = function() common.cmd("timer", "adjust", -30) end }),
        ui.button({ key = "tadj-30",  text = "+30s", variant = "ghost", controlSize = "sm", onClick = function() common.cmd("timer", "adjust", 30) end }),
        ui.button({ key = "tadj-60",  text = "+1m",  variant = "ghost", controlSize = "sm", onClick = function() common.cmd("timer", "adjust", 60) end }),
        ui.button({ key = "tadj-300", text = "+5m",  variant = "ghost", controlSize = "sm", onClick = function() common.cmd("timer", "adjust", 300) end }),
    })

    local controls = ui.row({ gap = 8, justify = "center" }, {
        ui.button({
            key     = "tctl-reset",
            glyph   = "refresh",
            text    = tr("reset"),
            variant = isDone and "primary" or "ghost",
            onClick = function()
                timerInputStr = ""
                timerInputKey += 1
                common.cmd("timer", "reset")
            end,
        }),
        ui.button({
            key      = "tctl-toggle",
            glyph    = isRunning and "player-pause" or "player-play",
            text     = isRunning and tr("pause") or (isPaused and tr("resume") or tr("start")),
            variant  = "primary",
            flexGrow = 1,
            enabled  = not isDone and (isActive or (isIdle and tmr.remaining > 0)),
            onClick  = function()
                if isRunning then common.cmd("timer", "pause")
                else common.cmd("timer", "start") end
            end,
        }),
        ui.button({
            key     = "tctl-flag",
            glyph   = "flag",
            text    = tr("flag"),
            variant = "ghost",
            enabled = isActive,
            onClick = function() common.cmd("timer", "flag", "") end,
        }),
    })

    local parts = {}
    table.insert(parts, clock)
    if inputSection then table.insert(parts, inputSection) end
    if not isDone then table.insert(parts, adjustRow) end
    table.insert(parts, controls)

    local flagsSection = common.flagList(tmr.flags, "timer", renamingFlagId, setRenamingFlagId, renameDraft, setRenameDraft)
    if flagsSection then
        table.insert(parts, ui.separator({}))
        table.insert(parts, ui.row({ justify = "space_between", align = "center" }, {
            ui.label({ text = tr("flags_label"), fontSize = 11, color = "on_surface_variant" }),
            ui.button({
                glyph = "copy",
                variant = "ghost",
                controlSize = "sm",
                tooltip = tr("tip.copy_flags"),
                onClick = function() common.copyFlags("Timer Flags:", tmr.flags) end
            })
        }))
        table.insert(parts, flagsSection)
    end

    return ui.column({ gap = 12, align = "stretch" }, parts)
end

return M
