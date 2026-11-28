--!nonstrict
local M = {}

function M.now()
    return math.floor(noctalia.nowMs() / 1000)
end

function M.nowMs()
    return noctalia.nowMs()
end

function M.fmtTime(s)
    s = math.max(0, math.floor(s))
    local h = math.floor(s / 3600)
    local m = math.floor((s % 3600) / 60)
    local sec = s % 60
    if h > 0 then
        return string.format("%d:%02d:%02d", h, m, sec)
    end
    return string.format("%02d:%02d", m, sec)
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

return M
