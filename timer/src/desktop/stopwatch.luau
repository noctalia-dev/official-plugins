--!nonstrict
-- Stopwatch component for desktop widget.

local common = require("./common.luau")
local tr = common.tr

local M = {}

function M.render(sw: any?, opts: { color: string?, showFlags: boolean? }?)
    sw = sw or { state = "IDLE", elapsed = 0, display = "00:00", flags = {} }
    local o = opts or {}
    local color = o.color or "primary"
    local showFlags = o.showFlags ~= false

    local isRunning = sw.state == "RUNNING"
    local isPaused = sw.state == "PAUSED"
    local isActive = isRunning or isPaused

    local timeColor = isRunning and color or (isPaused and "on_surface_variant" or "outline")

    local rows = {}

    table.insert(rows, ui.row({ key = "desk-sw-header", gap = 4, align = "center", justify = "center" }, {
        ui.glyph({ name = "stopwatch", size = 14, color = isRunning and color or "on_surface_variant" }),
        ui.label({ text = tr("tab.stopwatch"), fontSize = 12, fontWeight = "medium", color = "on_surface_variant" }),
    }))

    table.insert(rows, ui.label({
        key = "desk-sw-display",
        text = sw.display or "00:00",
        fontSize = 38,
        fontWeight = "bold",
        color = timeColor,
        textAlign = "center",
    }))

    local toggleText = isRunning and tr("pause") or (isPaused and tr("resume") or tr("start"))
    local toggleGlyph = isRunning and "player-pause" or "player-play"
    local toggleVariant = isRunning and "secondary" or "primary"

    local controls = {
        ui.button({
            key = "desk-sw-reset",
            glyph = "refresh",
            text = tr("reset"),
            variant = "ghost",
            controlSize = "sm",
            enabled = isActive or sw.elapsed > 0,
            onClick = function() common.cmd("sw", "reset") end,
        }),
        ui.button({
            key = "desk-sw-toggle",
            glyph = toggleGlyph,
            text = toggleText,
            variant = toggleVariant,
            controlSize = "sm",
            onClick = function()
                if isRunning then
                    common.cmd("sw", "pause")
                else
                    common.cmd("sw", "start")
                end
            end,
        }),
        ui.button({
            key = "desk-sw-flag",
            glyph = "flag",
            variant = "ghost",
            controlSize = "sm",
            enabled = isActive,
            onClick = function() common.cmd("sw", "flag", "") end,
        }),
    }
    table.insert(rows, ui.row({ key = "desk-sw-controls", gap = 6, justify = "center" }, controls))

    if showFlags and type(sw.flags) == "table" and #sw.flags > 0 then
        local latest = sw.flags[#sw.flags]
        table.insert(rows, ui.row({ key = "desk-sw-last-flag", gap = 4, justify = "center", align = "center" }, {
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
