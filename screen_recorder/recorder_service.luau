-- GPU Screen Recorder — headless service.
-- Owns all recording / replay-buffer logic and runs for the whole session, so a
-- recording can be started from the control-center shortcut with no bar widget
-- placed. The widget and shortcut are thin clients: they read the published
-- "status" and drive the recorder by writing to the "command" channel.
--
-- Settings come from the plugin's root-level [[setting]] block, seeded into
-- noctalia.getConfig and shared by every entry of the plugin.

noctalia.setUpdateInterval(250)

local CHECK_TICKS = 8 -- 8 * 250ms = 2s between process checks
local PENDING_TICKS = 8

local state = "idle" -- idle | pending | recording | replay_pending | replaying
local RECORDING_STATES = { "recording", "pending" }
local REPLAY_STATES = { "replaying", "replay_pending" }
local outputPath = ""
local isAvailable = false
local tickCount = 0
local pendingTick = 0
local checkedAvailability = false
local processCheckPending = false
local stateGeneration = 0
local updateDisplay
local lastStatusKey

-- ── Helpers ──────────────────────────────────────────────────────────────

local function cfg(key)
    return noctalia.getConfig(key)
end

-- Publish the recorder's status so the widget and shortcut can mirror it.
local function publishStatus()
    local key = `{state}/{if isAvailable then "1" else "0"}`
    if key == lastStatusKey then return end
    lastStatusKey = key
    noctalia.state.set("status", { state = state, available = isAvailable })
end

local function setState(nextState)
    if state == nextState then return end
    state = nextState
    stateGeneration += 1
end

local function detectProcessStateAsync(callback)
    local pending = 6
    local isReplaying = false
    local isRecording = false

    local function finish(kind, matched)
        if matched then
            if kind == "replaying" then
                isReplaying = true
            elseif kind == "recording" then
                isRecording = true
            end
        end

        pending -= 1
        if pending > 0 then return end

        callback(if isReplaying then "replaying" elseif isRecording then "recording" else nil)
    end

    local function queue(kind, name, token)
        local ok = noctalia.processMatches(function(matched)
            finish(kind, matched)
        end, name, token)
        if not ok then
            finish(kind, false)
        end
    end

    queue("replaying", "gpu-screen-recorder", " -r ")
    queue("replaying", "com.dec05eba.gpu_screen_recorder", " -r ")
    queue("recording", "gpu-screen-recorder", " -w ")
    queue("recording", "com.dec05eba.gpu_screen_recorder", " -w ")
    queue("recording", "gpu-screen-recorder", " -o ")
    queue("recording", "com.dec05eba.gpu_screen_recorder", " -o ")
end

local function flatpakGsrInstalled()
    if not noctalia.flatpakAppInstalled then
        return nil
    end
    return noctalia.flatpakAppInstalled("com.dec05eba.gpu_screen_recorder")
end

local function checkAvailability()
    if noctalia.commandExists("gpu-screen-recorder") then
        return true
    end
    return noctalia.commandExists("flatpak") and flatpakGsrInstalled() == true
end

local function copyToClipboard(path)
    local escapedPath = path:gsub(" ", "%%20"):gsub("'", "%%27"):gsub('"', "%%22")
    local uri = `file://{escapedPath}`
    noctalia.copyToClipboard(uri, "text/uri-list")
end

local function shellQuote(value)
    return "'" .. value:gsub("'", [["'"']]) .. "'"
end

local function notifyRecordingSavedIfPresent()
    local savedPath = outputPath
    if savedPath == "" then return end

    noctalia.runAsync(`sleep 0.5; test -s {shellQuote(savedPath)}`, function(result)
        if result.exitCode ~= 0 then
            return
        end

        noctalia.notify(noctalia.tr("notify.recording-saved"), savedPath)
        if cfg("copy_to_clipboard") then
            copyToClipboard(savedPath)
        end
    end)
end

-- ── Command builders ─────────────────────────────────────────────────────

local function buildAudioFlags()
    local source = cfg("audio_source")
    local codec = cfg("audio_codec")
    if source == "none" then return "" end
    if source == "both" then
        return `-ac {codec} -a "default_output|default_input"`
    end
    return `-ac {codec} -a {source}`
end

local function buildResolutionFlag()
    local res = cfg("resolution")
    return if res ~= "original" then `-s {res}` else ""
end

local function resolveVideoSource(errorTitle, focusedOutputName)
    local source = cfg("video_source")
    if source ~= "focused" then
        return source
    end

    local monitor = focusedOutputName
    if monitor == nil or monitor == "" then
        noctalia.notifyError(errorTitle, noctalia.tr("notify.no-monitor"))
        return nil
    end

    return monitor
end

local function buildGsrPrefix()
    return [[
_gpuscreenrecorder_flatpak_installed() {
  flatpak list --app 2>/dev/null | grep -q "com.dec05eba.gpu_screen_recorder"
}
if command -v gpu-screen-recorder >/dev/null 2>&1; then
  gpu-screen-recorder]]
end

local function outputDirectory()
    local configured = cfg("directory")
    local dir = if configured == "" then noctalia.expandPath("~/Videos/Recordings") else noctalia.expandPath(configured)
    if dir:sub(-1) ~= "/" then
        dir ..= "/"
    end
    return dir
end

local function buildGsrSuffix()
    return [[

elif command -v flatpak >/dev/null 2>&1 && _gpuscreenrecorder_flatpak_installed; then
  flatpak run --command=gpu-screen-recorder com.dec05eba.gpu_screen_recorder]]
end

local function buildRecordCommand(focusedOutputName)
    local source = resolveVideoSource(noctalia.tr("notify.recording-failed"), focusedOutputName)
    if source == nil then return nil end

    local dir = outputDirectory()

    local pattern = cfg("filename_pattern")
    local filename = `{noctalia.formatTime(pattern)}.mp4`
    outputPath = `{dir}{filename}`

    local fps = cfg("frame_rate")
    local codec = cfg("video_codec")
    local quality = cfg("quality")
    local cursor = if cfg("show_cursor") then "yes" else "no"
    local cr = cfg("color_range")
    local restore = if cfg("restore_portal") then "-restore-portal-session yes" else ""
    local audioFlags = buildAudioFlags()
    local resFlag = buildResolutionFlag()

    local flags = `-w {source} -f {fps} -k {codec} {audioFlags} -q {quality} -cursor {cursor} -cr {cr} {resFlag} {restore} -o "{outputPath}"`

    return `{buildGsrPrefix()} {flags}{buildGsrSuffix()} {flags}\nfi`
end

local function buildReplayCommand(focusedOutputName)
    local source = resolveVideoSource(noctalia.tr("notify.replay-failed"), focusedOutputName)
    if source == nil then return nil end

    local dir = outputDirectory()

    local duration = cfg("replay_duration")
    local storage = cfg("replay_storage")
    local fps = cfg("frame_rate")
    local codec = cfg("video_codec")
    local quality = cfg("quality")
    local cursor = if cfg("show_cursor") then "yes" else "no"
    local cr = cfg("color_range")
    local restore = if cfg("restore_portal") then "-restore-portal-session yes" else ""
    local audioFlags = buildAudioFlags()
    local resFlag = buildResolutionFlag()

    local flags = `-w {source} -c mp4 -f {fps} -k {codec} {audioFlags} -q {quality} -cursor {cursor} -cr {cr} {resFlag} -r {duration} -replay-storage {storage} {restore} -o "{dir}"`

    return `{buildGsrPrefix()} {flags}{buildGsrSuffix()} {flags}\nfi`
end

-- ── Portal check ─────────────────────────────────────────────────────────

local function checkPortalsAsync(callback)
    local pending = 5
    local hasPortal = false
    local hasBackend = false

    local function finish(kind, matched)
        if matched then
            if kind == "portal" then
                hasPortal = true
            elseif kind == "backend" then
                hasBackend = true
            end
        end

        pending -= 1
        if pending == 0 then
            callback(hasPortal and hasBackend)
        end
    end

    local function queue(kind, token)
        local ok = noctalia.processMatches(function(matched)
            finish(kind, matched)
        end, token)
        if not ok then
            finish(kind, false)
        end
    end

    queue("portal", "xdg-desktop-portal ")
    queue("backend", "xdg-desktop-portal-wlr ")
    queue("backend", "xdg-desktop-portal-hyprland ")
    queue("backend", "xdg-desktop-portal-gnome ")
    queue("backend", "xdg-desktop-portal-kde ")
end

-- ── Recording controls ───────────────────────────────────────────────────

local function startRecording(focusedOutputName)
    if not isAvailable or state ~= "idle" then return end

    setState("pending")
    pendingTick = 0
    updateDisplay()

    checkPortalsAsync(function(portalAvailable)
        if state ~= "pending" then return end

        if not portalAvailable then
            setState("idle")
            noctalia.notifyError(noctalia.tr("notify.recording-failed"), noctalia.tr("notify.portal-not-running"))
            updateDisplay()
            return
        end

        local cmd = buildRecordCommand(focusedOutputName)
        if not cmd then
            setState("idle")
            updateDisplay()
            return
        end

        if not noctalia.runAsync(cmd) then
            setState("idle")
            noctalia.notifyError(noctalia.tr("notify.recording-failed"), noctalia.tr("notify.launch-failed"))
            updateDisplay()
        end
    end)
end

local function stopRecording()
    if not table.find(RECORDING_STATES, state) then return end

    noctalia.runAsync("pkill -SIGINT -f '^(/nix/store/.*-)?gpu-screen-recorder' 2>/dev/null || pkill -SIGINT -f '^com.dec05eba.gpu_screen_recorder' 2>/dev/null || true")
    -- Force kill fallback
    noctalia.runAsync("(sleep 3 && pkill -9 -f '^(/nix/store/.*-)?gpu-screen-recorder' 2>/dev/null || true) &")

    if state == "recording" then
        notifyRecordingSavedIfPresent()
    end

    setState("idle")
end

-- ── Replay controls ──────────────────────────────────────────────────────

local function startReplay(focusedOutputName)
    if not isAvailable or state ~= "idle" then return end
    if not cfg("replay_enabled") then return end

    setState("replay_pending")
    pendingTick = 0
    updateDisplay()

    checkPortalsAsync(function(portalAvailable)
        if state ~= "replay_pending" then return end

        if not portalAvailable then
            setState("idle")
            noctalia.notifyError(noctalia.tr("notify.replay-failed"), noctalia.tr("notify.portal-not-running"))
            updateDisplay()
            return
        end

        local cmd = buildReplayCommand(focusedOutputName)
        if not cmd then
            setState("idle")
            updateDisplay()
            return
        end

        if not noctalia.runAsync(cmd) then
            setState("idle")
            noctalia.notifyError(noctalia.tr("notify.replay-failed"), noctalia.tr("notify.launch-failed"))
            updateDisplay()
        end
    end)
end

local function stopReplay()
    if not table.find(REPLAY_STATES, state) then return end

    noctalia.runAsync("pkill -SIGINT -f 'gpu-screen-recorder.*-r ' 2>/dev/null || true")
    noctalia.runAsync("(sleep 3 && pkill -9 -f 'gpu-screen-recorder.*-r ' 2>/dev/null || true) &")

    setState("idle")
    noctalia.notify(noctalia.tr("notify.replay-stopped"))
end

local function saveReplay()
    if state ~= "replaying" then return end
    noctalia.runAsync("pkill -SIGUSR1 -f 'gpu-screen-recorder.*-r ' 2>/dev/null || true")

    local pattern = cfg("replay_filename_pattern")
    if pattern ~= nil and pattern ~= "" then
        local dir = outputDirectory()
        local targetFile = `{dir}{noctalia.formatTime(pattern)}.mp4`
        -- Replay mode only accepts an output directory (-o "{dir}"), so gpu-screen-recorder
        -- names the file itself as Replay_<timestamp>.mp4 using its own clock when it
        -- finalizes. Rather than predict that name, poll for the newest Replay_*.mp4 the
        -- save produced and rename it. `ref` (one second before the SIGUSR1) bounds the
        -- search so an earlier replay sitting in the directory is never picked up.
        local ref = (tonumber(noctalia.formatTime("%s")) or 0) - 1
        local claim = `f=$(find {shellQuote(dir)} -maxdepth 1 -name 'Replay_*.mp4' -newermt "@{ref}" -printf '%T@ %p\\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2-); `
            .. `if [ -n "$f" ]; then mv -n -- "$f" {shellQuote(targetFile)}; else exit 1; fi`
        local attempts = 50
        local function poll()
            noctalia.runAsync(`sleep 0.2; {claim}`, function(result)
                if result.exitCode == 0 then return end
                if attempts > 0 then
                    attempts -= 1
                    poll()
                end
            end)
        end
        poll()
    end

    noctalia.notify(noctalia.tr("notify.replay-saved"))
end

-- ── State polling ────────────────────────────────────────────────────────

local function checkProcessState(processState)
    if state == "pending" then
        pendingTick += CHECK_TICKS
        if pendingTick >= PENDING_TICKS then
            if processState == "recording" then
                setState("recording")
            else
                setState("idle")
            end
        end
    elseif state == "replay_pending" then
        pendingTick += CHECK_TICKS
        if pendingTick >= PENDING_TICKS then
            if processState == "replaying" then
                setState("replaying")
                noctalia.notify(noctalia.tr("notify.replay-active"))
            else
                setState("idle")
            end
        end
    elseif state == "recording" then
        if processState ~= "recording" then
            setState("idle")
            notifyRecordingSavedIfPresent()
        end
    elseif state == "replaying" then
        if processState ~= "replaying" then
            setState("idle")
            noctalia.notify(noctalia.tr("notify.replay-stopped"))
        end
    elseif state == "idle" then
        if processState ~= nil then
            setState(processState)
        end
    end
end

local function requestProcessStateCheck()
    if processCheckPending then return end

    processCheckPending = true
    local generation = stateGeneration
    detectProcessStateAsync(function(processState)
        processCheckPending = false
        if generation ~= stateGeneration then return end
        if processState ~= nil then
            isAvailable = true
        end
        checkProcessState(processState)
        updateDisplay()
    end)
end

-- ── Status publication ─────────────────────────────────────────────────────

-- The service has no presentation; "updating the display" is publishing status.
function updateDisplay()
    publishStatus()
end

-- ── Callbacks ────────────────────────────────────────────────────────────

function update()
    tickCount += 1

    if not checkedAvailability then
        checkedAvailability = true
        isAvailable = checkAvailability()
        requestProcessStateCheck()
    end

    if tickCount % CHECK_TICKS == 0 then
        requestProcessStateCheck()
    end

    updateDisplay()
end

function onIpc(event, payload)
    local focusedOutputName = nil
    if type(payload) == "table" then
        focusedOutputName = payload.focusedOutputName
    elseif type(payload) == "string" and payload ~= "" then
        focusedOutputName = payload
    end
    if focusedOutputName == nil or focusedOutputName == "" then
        focusedOutputName = noctalia.focusedOutputName()
    end

    if event == "start" then
        startRecording(focusedOutputName)
    elseif event == "stop" then
        stopRecording()
    elseif event == "toggle" then
        if table.find(RECORDING_STATES, state) then
            stopRecording()
        elseif state == "idle" then
            startRecording(focusedOutputName)
        end
    elseif event == "replay-start" then
        startReplay(focusedOutputName)
    elseif event == "replay-stop" then
        stopReplay()
    elseif event == "replay-toggle" then
        if table.find(REPLAY_STATES, state) then
            stopReplay()
        elseif state == "idle" then
            startReplay(focusedOutputName)
        end
    elseif event == "replay-save" or event == "save-replay" then
        saveReplay()
    else
        noctalia.log(`screen_recorder: unknown command '{event}'`)
    end
end

-- The widget and shortcut drive the recorder by publishing to this channel.
noctalia.state.watch("command", function(cmd)
    local action = if type(cmd) == "table" and cmd.action ~= nil then cmd.action else cmd
    if type(action) == "string" then
        onIpc(action, if type(cmd) == "table" then cmd else nil)
    end
end)
