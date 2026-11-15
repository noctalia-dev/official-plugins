--!nonstrict
local M = {}
local utils = require("./utils.luau")
local ring = require("./ring.luau")

M.alarms = {}

local persistCallback = nil
function M.setPersistCallback(cb) persistCallback = cb end

-- os.time() reads its table as UTC while os.date("*t") gives local time, so a
-- wall-clock hh:mm has to be shifted by the local UTC offset. The offset is
-- measured twice so a DST change between now and the alarm is respected.
local function localToUnix(year, month, day, hh, mm)
    local guess = os.time({ year = year, month = month, day = day, hour = hh, min = mm, sec = 0 })
    local offset = os.time(os.date("*t", guess)) - guess
    local shifted = guess - offset
    offset = os.time(os.date("*t", shifted)) - shifted
    return guess - offset
end

local function nextFire(hh, mm, days)
    days = days or {}
    local t = utils.now()
    local today = os.date("*t", t)

    for offset = 0, 7 do
        -- os.time normalises day overflow.
        local candidate = localToUnix(today.year, today.month, today.day + offset, hh, mm)
        if candidate > t then
            if #days == 0 then
                return candidate
            end
            local w  = os.date("*t", candidate).wday
            local wd = w == 1 and 7 or w - 1
            for _, d in ipairs(days) do
                if d == wd then return candidate end
            end
        end
    end
    return nil
end

local MAX_LABEL  = 64
local MAX_ALARMS = 100

-- Clamp untrusted alarm fields coming from command payloads / disk.
local function sanitize(label, hh, mm, days)
    hh = math.max(0, math.min(23, math.floor(tonumber(hh) or 0)))
    mm = math.max(0, math.min(59, math.floor(tonumber(mm) or 0)))
    local seen, clean = {}, {}
    if type(days) == "table" then
        for _, d in ipairs(days) do
            d = tonumber(d)
            if d and d >= 1 and d <= 7 and d == math.floor(d) and not seen[d] then
                seen[d] = true
                table.insert(clean, d)
            end
        end
        table.sort(clean)
    end
    label = type(label) == "string" and string.sub(label, 1, MAX_LABEL) or ""
    return label, hh, mm, clean
end

local DEFAULT_LABEL = "Alarm"

-- An alarm's id is its position in the list, so the "#n" shown in the panel
-- is what the IPC toggle/remove commands expect.
local function renumber()
    for i, a in ipairs(M.alarms) do a.id = i end
end

function M.publish()
    noctalia.state.set("timer.alarms", M.alarms)
end

function M.add(label, hh, mm, days)
    if #M.alarms >= MAX_ALARMS then return nil end
    label, hh, mm, days = sanitize(label, hh, mm, days)
    local entry = {
        id       = #M.alarms + 1,
        label    = label ~= "" and label or DEFAULT_LABEL,
        hh       = hh,
        mm       = mm,
        enabled  = true,
        days     = days,
        nextFire = nextFire(hh, mm, days),
    }
    table.insert(M.alarms, entry)
    if persistCallback then persistCallback() end
    M.publish()
    return entry
end

function M.remove(id)
    for i, a in ipairs(M.alarms) do
        if a.id == id then
            table.remove(M.alarms, i)
            break
        end
    end
    renumber()
    if persistCallback then persistCallback() end
    M.publish()
end

function M.toggle(id)
    for _, a in ipairs(M.alarms) do
        if a.id == id then
            a.enabled = not a.enabled
            if a.enabled then
                a.nextFire = nextFire(a.hh, a.mm, a.days)
            end
            break
        end
    end
    if persistCallback then persistCallback() end
    M.publish()
end

function M.edit(id, label, hh, mm, days)
    label, hh, mm, days = sanitize(label, hh, mm, days)
    for _, a in ipairs(M.alarms) do
        if a.id == id then
            a.label  = label ~= "" and label or DEFAULT_LABEL
            a.hh     = hh
            a.mm     = mm
            a.days   = days
            a.nextFire = a.enabled and nextFire(hh, mm, days) or nil
            break
        end
    end
    if persistCallback then persistCallback() end
    M.publish()
end

function M.tick()
    local t = utils.now()
    local changed = false
    for _, a in ipairs(M.alarms) do
        if a.enabled and a.nextFire ~= nil and t >= a.nextFire then
            -- Found long after its time (machine asleep or shell off): report it
            -- instead of ringing at a random moment. 0 minutes means always ring.
            local graceMin = tonumber(noctalia.getConfig("alarm_missed_grace")) or 10
            if graceMin > 0 and t - a.nextFire > graceMin * 60 then
                noctalia.notifyError("Missed alarm", string.format("%s (%02d:%02d)", a.label, a.hh, a.mm))
            else
                noctalia.state.set("timer.alarm_fired", tostring(a.id))
                ring.alertFor("alarm", "⏰ Alarm", a.label, a.label)
            end
            if #a.days == 0 then
                -- One-time alarm: switch it off but keep it in the list.
                a.enabled  = false
                a.nextFire = nil
            else
                a.nextFire = nextFire(a.hh, a.mm, a.days)
            end
            changed = true
        end
    end
    if changed then
        if persistCallback then persistCallback() end
        M.publish()
    end
end

function M.load(saved)
    if type(saved) ~= "table" then return end
    if type(saved.alarms) == "table" then
        M.alarms = {}
        for _, a in ipairs(saved.alarms) do
            if type(a) == "table" and #M.alarms < MAX_ALARMS then
                local label, hh, mm, days = sanitize(a.label, a.hh, a.mm, a.days)
                local entry = {
                    id = #M.alarms + 1,
                    label = label ~= "" and label or DEFAULT_LABEL,
                    hh = hh, mm = mm, days = days,
                    enabled = a.enabled == true,
                }
                if entry.enabled then
                    -- Keep the saved time so an alarm that passed while the shell was off is reported as missed.
                    entry.nextFire = type(a.nextFire) == "number" and a.nextFire or nextFire(hh, mm, days)
                end
                table.insert(M.alarms, entry)
            end
        end
    end
    renumber()
end

return M
