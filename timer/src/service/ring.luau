--!nonstrict
local M = {}
local utils = require("./utils.luau")

local RING_NAME    = "timer_ring"
local ringLoaded   = false
local ringSoundPath = "sounds/beep.ogg"
local DEFAULT_TIMEOUT = 120 -- matches ring_timeout default in plugin.toml

local ring = {
    active   = false,
    mode     = nil,
    label    = "",
    since    = 0,
    timeout  = DEFAULT_TIMEOUT,
}

function M.load()
    ringLoaded = false
    noctalia.sound.load(RING_NAME, ringSoundPath, function(ok, err)
        ringLoaded = ok == true
        if not ringLoaded then
            noctalia.log("timer: ring sound load failed for '" .. tostring(ringSoundPath) .. "': " .. tostring(err))
        end
    end)
end

function M.publish()
    if ring.active then
        noctalia.state.set("timer.ringing", {
            mode  = ring.mode,
            label = ring.label,
            since = ring.since,
        })
    else
        noctalia.state.set("timer.ringing", nil)
    end
end

function M.start(mode, label)
    ring.active   = true
    ring.mode     = mode
    ring.label    = label or ""
    ring.since    = utils.now()
    ring.timeout  = tonumber(noctalia.getConfig("ring_timeout")) or DEFAULT_TIMEOUT
    noctalia.setUpdateInterval(100)
    M.publish()
end

function M.stop()
    if not ring.active then return end
    ring.active = false
    ring.mode   = nil
    ring.label  = ""
    noctalia.setUpdateInterval(1000)
    M.publish()
end

function M.tick()
    if not ring.active then return end
    local t = utils.now()
    if ring.timeout > 0 and (t - ring.since) >= ring.timeout then
        M.stop()
        return
    end
    
    -- There is no loop support yet and the sound is 1s long, so ask for it every
    -- 100ms: a request while it plays is dropped, and one right as it ends restarts it.
    if ringLoaded then
        noctalia.sound.play(RING_NAME)
    end
end

function M.alertFor(kind, title, body, label)
    local pref = noctalia.getConfig("alert_mode") or "both"
    
    if kind == "pomo" then
        local pomoPref = noctalia.getConfig("pomo_alert_mode") or "inherit"
        if pomoPref ~= "inherit" then
            pref = pomoPref
        end
    end
    
    if pref == "notify" or pref == "both" then
        noctalia.notify(title, body)
    end
    
    if pref == "sound" or pref == "both" then
        M.start(kind, label or body)
    end
end

function M.isActive()
    return ring.active
end

function M.getMode()
    return ring.mode
end

return M
