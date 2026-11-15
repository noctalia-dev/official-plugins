--!nonstrict
local common = require("./common.luau")
local tr = common.tr

local M = {}

M.alarmList = {}

local alarmForm = {
    open      = false,
    editId    = nil,
    label     = "",
    hhStr     = "",
    mmStr     = "",
    days      = {},
    labelKey  = 0,
    hhKey     = 0,
    mmKey     = 0,
}

function M.closeForm()
    alarmForm.open = false
end

local function dayName(d)
    local names = { "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" }
    return names[d] or "?"
end

local function isDaySelected(days, d)
    for _, v in ipairs(days) do
        if v == d then return true end
    end
    return false
end

local function toggleDay(days, d)
    for i, v in ipairs(days) do
        if v == d then
            table.remove(days, i)
            return days
        end
    end
    table.insert(days, d)
    table.sort(days)
    return days
end

-- Day names with runs of 3+ collapsed ("Mon–Sat") so the row stays short.
local function daySummary(days)
    local count = #days
    if count == 0 then return "Once" end
    if count == 7 then return "Daily" end
    if count == 5 and not isDaySelected(days, 6) and not isDaySelected(days, 7) then
        return tr("alarm.weekdays")
    end
    if count == 2 and isDaySelected(days, 6) and isDaySelected(days, 7) then return "Weekend" end
    local parts = {}
    local i = 1
    while i <= count do
        local j = i
        while j < count and days[j + 1] == days[j] + 1 do j += 1 end
        if j - i >= 2 then
            table.insert(parts, dayName(days[i]) .. "–" .. dayName(days[j]))
        else
            for k = i, j do table.insert(parts, dayName(days[k])) end
        end
        i = j + 1
    end
    return table.concat(parts, ", ")
end

local function sameDays(days, wanted)
    if #days ~= #wanted then return false end
    for _, d in ipairs(wanted) do
        if not isDaySelected(days, d) then return false end
    end
    return true
end

local function alarmLabel(a)
    return string.format("%02d:%02d", a.hh, a.mm)
end

-- A preset button is highlighted exactly when the selected days match it, so
-- the presets and the day buttons can never disagree. Pressing the highlighted
-- one clears the days (which highlights Once).
local function presetRow()
    local presets = {
        { key = "once",     text = "Once",              days = {} },
        { key = "daily",    text = "Daily",             days = { 1, 2, 3, 4, 5, 6, 7 } },
        { key = "weekdays", text = tr("alarm.weekdays"), days = { 1, 2, 3, 4, 5 } },
        { key = "weekend",  text = "Weekend",           days = { 6, 7 } },
    }
    local buttons = {}
    for _, preset in ipairs(presets) do
        local on = sameDays(alarmForm.days, preset.days)
        table.insert(buttons, ui.button({
            key         = "alarm-preset-" .. preset.key,
            text        = preset.text,
            variant     = on and "primary" or "ghost",
            controlSize = "sm",
            onClick     = function()
                alarmForm.days = on and {} or { table.unpack(preset.days) }
                common.render()
            end,
        }))
    end
    return ui.row({ gap = 4, justify = "space_between" }, buttons)
end

local function alarmFormView()
    local dayRow = {}
    for d = 1, 7 do
        local sel = isDaySelected(alarmForm.days, d)
        table.insert(dayRow, ui.button({
            key     = "day-" .. d,
            text    = dayName(d),
            variant = sel and "primary" or "ghost",
            controlSize = "sm",
            onClick = function()
                alarmForm.days = toggleDay(alarmForm.days, d)
                common.render()
            end,
        }))
    end

    return ui.column({ gap = 10, align = "stretch", fill = "surface_variant/0.3", radius = 8, padding = 12 }, {
        ui.label({
            text       = alarmForm.editId and tr("alarm.edit_title") or tr("alarm.add_title"),
            fontSize   = 13,
            fontWeight = "bold",
            color      = "on_surface",
        }),
        ui.input({
            key         = "alarm-label-" .. alarmForm.labelKey,
            value       = alarmForm.label,
            placeholder = tr("alarm.label_placeholder"),
            onChange    = function(v) alarmForm.label = v end,
        }),
        ui.row({ gap = 6, align = "center" }, {
            ui.input({
                key         = "alarm-hh-" .. alarmForm.hhKey,
                value       = alarmForm.hhStr,
                placeholder = "HH",
                flexGrow    = 1,
                onChange    = function(v) alarmForm.hhStr = v end,
            }),
            ui.label({ text = ":", fontSize = 18, fontWeight = "bold", color = "on_surface" }),
            ui.input({
                key         = "alarm-mm-" .. alarmForm.mmKey,
                value       = alarmForm.mmStr,
                placeholder = "MM",
                flexGrow    = 1,
                onChange    = function(v) alarmForm.mmStr = v end,
            }),
        }),
        ui.label({ text = tr("alarm.repeat_label"), fontSize = 11, color = "on_surface_variant" }),
        presetRow(),
        ui.row({ gap = 4, justify = "space_between" }, dayRow),
        ui.row({ gap = 8, justify = "end" }, {
            ui.button({
                key     = "alarmform-cancel",
                text    = tr("cancel"),
                variant = "ghost",
                onClick = function()
                    alarmForm.open   = false
                    alarmForm.editId = nil
                    common.render()
                end,
            }),
            ui.button({
                key     = "alarmform-submit",
                text    = alarmForm.editId and tr("save") or tr("alarm.add_btn"),
                variant = "primary",
                onClick = function()
                    local hh = math.max(0, math.min(23, tonumber(alarmForm.hhStr) or 0))
                    local mm = math.max(0, math.min(59, tonumber(alarmForm.mmStr) or 0))
                    if alarmForm.editId then
                        common.cmd("alarm", "edit", {
                            id    = alarmForm.editId,
                            label = alarmForm.label,
                            hh    = hh,
                            mm    = mm,
                            days  = alarmForm.days,
                        })
                    else
                        common.cmd("alarm", "add", {
                            label = alarmForm.label,
                            hh    = hh,
                            mm    = mm,
                            days  = alarmForm.days,
                        })
                    end
                    alarmForm.open   = false
                    alarmForm.editId = nil
                    common.render()
                end,
            }),
        }),
    })
end

local function alarmRow(a)
    local timeStr = alarmLabel(a)
    local dayStr  = daySummary(a.days)
    local nextStr = nil
    if a.enabled and a.nextFire then
        nextStr = "in " .. common.fmtCountdown(a.nextFire - noctalia.nowMs() / 1000)
    end

    return ui.row({
        key   = "alarm-" .. a.id,
        gap   = 8,
        align = "center",
        fill  = a.enabled and "primary/0.07" or nil,
        radius = 6,
        padding = 6,
    }, {
        ui.toggle({
            checked  = a.enabled,
            onChange = function()
                common.cmd("alarm", "toggle", a.id)
            end,
        }),
        ui.column({ flexGrow = 1, gap = 2 }, {
            ui.row({ gap = 6, align = "center" }, {
                ui.label({ text = "#" .. a.id, fontSize = 13, fontWeight = "bold", color = "on_surface_variant" }),
                ui.label({ text = "·", fontSize = 13, color = "on_surface_variant" }),
                ui.label({ text = a.label, fontSize = 13, fontWeight = "bold", color = "on_surface" }),
                nextStr and ui.label({ text = "·", fontSize = 13, color = "on_surface_variant" }) or nil,
                nextStr and ui.label({ text = nextStr, fontSize = 13, fontWeight = "bold", color = "on_surface_variant" }) or nil,
            }),
            ui.row({ gap = 6, align = "center" }, {
                ui.label({ text = timeStr, fontSize = 12, fontWeight = "bold", color = "primary" }),
                ui.label({ text = "·", fontSize = 11, color = "on_surface_variant" }),
                ui.label({ text = dayStr,  fontSize = 11, color = "on_surface_variant" }),
            }),
        }),
        ui.button({
            glyph   = "pencil",
            variant = "ghost",
            tooltip = tr("tip.edit"),
            onClick = function()
                alarmForm.open   = true
                alarmForm.editId = a.id
                alarmForm.label  = a.label
                alarmForm.hhStr  = string.format("%02d", a.hh)
                alarmForm.mmStr  = string.format("%02d", a.mm)
                alarmForm.days   = {}
                for _, d in ipairs(a.days) do table.insert(alarmForm.days, d) end
                alarmForm.labelKey += 1
                alarmForm.hhKey    += 1
                alarmForm.mmKey    += 1
                common.render()
            end,
        }),
        ui.button({
            glyph   = "trash",
            variant = "ghost",
            tooltip = tr("tip.delete"),
            onClick = function()
                common.cmd("alarm", "remove", a.id)
            end,
        }),
    })
end

function M.render()
    local header = ui.row({ align = "center", gap = 6 }, {
        ui.label({ text = tr("tab.alarms"), fontSize = 14, fontWeight = "bold", color = "on_surface", flexGrow = 1 }),
        ui.button({
            glyph   = "refresh",
            variant = "ghost",
            tooltip = "Refresh next fire",
            onClick = function() common.render() end,
        }),
        ui.button({
            glyph   = "plus",
            variant = "primary",
            tooltip = tr("alarm.add_btn"),
            onClick = function()
                alarmForm.open   = true
                alarmForm.editId = nil
                alarmForm.label  = ""
                alarmForm.hhStr  = ""
                alarmForm.mmStr  = ""
                alarmForm.days   = {}
                alarmForm.labelKey += 1
                alarmForm.hhKey    += 1
                alarmForm.mmKey    += 1
                common.render()
            end,
        }),
    })

    local parts = { header }
    if alarmForm.open then
        table.insert(parts, alarmFormView())
    end

    if #M.alarmList == 0 then
        table.insert(parts, ui.column({ align = "center", gap = 6, padding = 24 }, {
            ui.glyph({ name = "bell-off", size = 32, color = "on_surface_variant" }),
            ui.label({ text = tr("alarm.empty"), color = "on_surface_variant", fontSize = 12 }),
        }))
    else
        for _, a in ipairs(M.alarmList) do
            table.insert(parts, alarmRow(a))
        end
    end

    return ui.column({ gap = 10, align = "stretch" }, parts)
end

return M
