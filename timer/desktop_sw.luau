--!nonstrict
-- Stopwatch Desktop Widget — dedicated [[desktop_widget]] client.

local desktopSw = require("./src/desktop/stopwatch.luau")

local color = noctalia.getConfig("color") or "primary"
local showFlags = noctalia.getConfig("show_flags") ~= false

local sw = { state = "IDLE", elapsed = 0, display = "00:00", flags = {} }

local function render()
    local tree = desktopSw.render(sw, { color = color, showFlags = showFlags })
    desktopWidget.render(tree)
end

noctalia.state.watch("timer.sw", function(v)
    if v then sw = v end
    render()
end)

function onConfigChanged()
    color = noctalia.getConfig("color") or "primary"
    showFlags = noctalia.getConfig("show_flags") ~= false
    render()
end

sw = noctalia.state.get("timer.sw") or sw
render()
