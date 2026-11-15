--!nonstrict
-- Shared utilities and helpers for desktop widgets.

local M = {}

M.tr = noctalia.tr

local BATCH_SIZE = 16
local cmdNonce = 0
local recent = {}

function M.cmd(mode: string, action: string, payload: any?)
    cmdNonce = math.max(cmdNonce + 1, math.floor(noctalia.nowMs()) * 1000)
    table.insert(recent, { mode = mode, action = action, payload = payload, nonce = cmdNonce })
    if #recent > BATCH_SIZE then
        table.remove(recent, 1)
    end
    noctalia.state.set("timer.cmd", { batch = recent })
end

function M.ringBanner(ringing: any?)
    if type(ringing) ~= "table" then
        return nil
    end

    local mode = ringing.mode
    local modeLabel = "Alert"
    if mode == "alarm" then
        modeLabel = M.tr("tab.alarms")
    elseif mode == "timer" then
        modeLabel = M.tr("tab.timer")
    elseif mode == "pomo" then
        modeLabel = M.tr("tab.pomodoro")
    end

    local title = (ringing.label ~= nil and ringing.label ~= "") and ringing.label or modeLabel

    return ui.column({
        key     = "desk-ring-banner",
        gap     = 6,
        align   = "center",
        fill    = "error/0.15",
        radius  = 8,
        padding = 8,
    }, {
        ui.row({ gap = 6, align = "center" }, {
            ui.glyph({ name = "alarm", color = "error", size = 16 }),
            ui.label({ text = title, fontSize = 12, fontWeight = "bold", color = "error" }),
        }),
        ui.button({
            key         = "desk-ring-stop",
            glyph       = "player-stop",
            text        = M.tr("ring.stop"),
            controlSize = "sm",
            variant     = "destructive",
            onClick     = function()
                M.cmd("ring", "stop")
            end,
        }),
    })
end

return M
