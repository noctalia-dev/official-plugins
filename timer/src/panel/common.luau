--!nonstrict
local M = {}

M.tr = noctalia.tr

-- Commands go out as a rolling batch so several issued in one tick aren't lost
-- to the single `timer.cmd` slot. Nonces are time-based, so they stay monotonic
-- across panel reloads and match the desktop widgets' own writes.
local BATCH_SIZE = 16
local cmdNonce = 0
local recent = {}
function M.cmd(mode, action, payload)
    cmdNonce = math.max(cmdNonce + 1, math.floor(noctalia.nowMs()) * 1000)
    table.insert(recent, { mode = mode, action = action, payload = payload, nonce = cmdNonce })
    if #recent > BATCH_SIZE then table.remove(recent, 1) end
    noctalia.state.set("timer.cmd", { batch = recent })
end

function M.copyFlags(title, flags)
    local lines = { title }
    for i, f in ipairs(flags) do
        table.insert(lines, string.format("%d. %s - %s (%s)", i, f.name, f.display or "", f.tsWall or ""))
    end
    noctalia.copyToClipboard(table.concat(lines, "\n"), "text/plain")
end

-- "5d 8h 59m" / "14h 05m" / "7m"; rounds up so an alarm one second away still reads "1m".
function M.fmtCountdown(seconds)
    local minutes = math.max(0, math.ceil(seconds / 60))
    if minutes >= 1440 then
        return string.format("%dd %dh %02dm", minutes // 1440, (minutes % 1440) // 60, minutes % 60)
    elseif minutes >= 60 then
        return string.format("%dh %02dm", minutes // 60, minutes % 60)
    end
    return string.format("%dm", minutes)
end

-- Callbacks to be set by main panel
M.render = function() end

function M.parseTimeStr(s)
    s = noctalia.string.trim(s):gsub("%s+", "")
    local parts = {}
    for p in s:gmatch("[^:]+") do table.insert(parts, p) end
    if #parts == 2 then
        return (tonumber(parts[1]) or 0) * 60 + (tonumber(parts[2]) or 0)
    elseif #parts == 3 then
        return (tonumber(parts[1]) or 0) * 3600 + (tonumber(parts[2]) or 0) * 60 + (tonumber(parts[3]) or 0)
    end
    local digits = s:gsub("[^%d]", "")
    if digits == "" then return 0 end
    if #digits <= 2 then return tonumber(digits) or 0 end
    if #digits <= 4 then
        local mm = tonumber(digits:sub(1, -3)) or 0
        local ss = tonumber(digits:sub(-2)) or 0
        return mm * 60 + ss
    end
    local ss = tonumber(digits:sub(-2)) or 0
    local mm = tonumber(digits:sub(-4, -3)) or 0
    local hh = tonumber(digits:sub(1, -5)) or 0
    return hh * 3600 + mm * 60 + ss
end

function M.flagList(flags, mode, renamingId, setRenaming, renameDraft, setRenameDraft)
    if #flags == 0 then return nil end
    local rows = {}
    for i = #flags, 1, -1 do
        local f = flags[i]
        local isRenaming = renamingId == f.id

        local nameCell
        if isRenaming then
            nameCell = ui.input({
                key      = "rename-" .. mode .. "-" .. f.id,
                value    = f.name,
                focus    = true,
                flexGrow = 1,
                onChange = function(v) setRenameDraft(v) end,
                onSubmit = function(val)
                    local name = (val ~= nil and val ~= "") and val or renameDraft
                    M.cmd(mode, "rename_flag", { id = f.id, name = name })
                    setRenaming(nil)
                    setRenameDraft("")
                    M.render()
                end,
            })
        else
            nameCell = ui.button({
                key          = "flag-name-" .. mode .. "-" .. f.id,
                text         = f.name,
                variant      = "ghost",
                contentAlign = "start",
                flexGrow     = 1,
                onClick      = function()
                    setRenameDraft(f.name)
                    setRenaming(f.id)
                    M.render()
                end,
            })
        end

        local elapsedStr = f.display or "—"
        local wallStr    = f.tsWall  or "—"

        table.insert(rows, ui.row({
            key   = "flag-" .. mode .. "-" .. f.id,
            gap   = 6,
            align = "center",
        }, {
            ui.glyph({ name = "flag", color = "primary", size = 12 }),
            nameCell,
            ui.column({ gap = 1, align = "end" }, {
                ui.label({ text = elapsedStr, fontSize = 11, fontWeight = "bold", color = "on_surface" }),
                ui.label({ text = wallStr,    fontSize = 10, color = "on_surface_variant" }),
            }),
        }))
    end
    return ui.column({ gap = 4, align = "stretch" }, rows)
end

return M
