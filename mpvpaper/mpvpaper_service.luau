--!nonstrict
-- Video wallpaper — headless service.
-- This service handles active video wallpaper assignments and lifecycle.
-- Note: Noctalia plugin scripts run in an isolated sandbox without `require`.
-- Therefore, all logic (IPC, state management) must reside here.
-- In addition to single-video wallpapers, this service also drives per-output
-- directory slideshows: when a slideshow interval is set, it builds a playlist
-- from all videos in the chosen directory and tracks which file mpv is
-- currently showing via JSON IPC, updating both state and static wallpaper
-- frames to match.

noctalia.setUpdateInterval(1000)

-- ==============================================================================
-- ── PATHS AND STATE ────────────────────────────────────────────────────────
-- ==============================================================================

local CACHE_DIR = (noctalia.getenv("XDG_CACHE_HOME") or ((noctalia.getenv("HOME") or "") .. "/.cache")) .. "/noctalia/mpvpaper"
local STATE_DIR = (noctalia.getenv("XDG_STATE_HOME") or ((noctalia.getenv("HOME") or "") .. "/.local/state")) .. "/noctalia/mpvpaper"
local STATE_FILE = STATE_DIR .. "/assignments.json"

local VIDEO_EXTENSIONS = { mp4 = true, webm = true, mkv = true, mov = true, gif = true }
local assignments = {}      -- Map of connector -> video path ("*" for all outputs)
local launchedAsSystemd = {} -- Map of connector -> boolean (true if launched as systemd)
local lastPresent = {}      -- Map of connector -> true (monitors seen last tick)
local isPaused = {}         -- Map of connector -> true (paused monitors)
local currentPath = {}      -- Map of connector -> file mpv is actually showing right now (slideshow only)
local available = false     -- Is mpvpaper binary installed?
local mpvpaperSupportsAutoMode = false -- resolved at boot, before any launch
local socatAvailable = nil

-- Slideshow interval in seconds, set exclusively from the picker's slider (no
-- manifest setting backs this anymore). 0 means disabled. Persisted to disk so
-- it survives a service restart.
local slideshowOverride = 0

-- ==============================================================================
-- ── HELPERS ────────────────────────────────────────────────────────────────
-- ==============================================================================

local function cfg(key)
  return noctalia.getConfig(key)
end

-- Safely quotes strings for shell execution to prevent injection.
local function shellQuote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

-- Returns the systemd unit name for a given connector.
-- E.g., "*" -> "mpvpaper.scope", "DP-1" -> "mpvpaper-DP-1.scope".
local function unitNameFor(connector)
  if connector == "*" then
    return "mpvpaper.scope"
  end
  return "mpvpaper-" .. connector:gsub("[^%w%-]", "_") .. ".scope"
end

-- Builds a precise pkill -f pattern that matches only the exact connector.
-- Targets the '-p <connector>' argument followed by a space, preventing partial
-- matches (e.g., DP-1 accidentally matching DP-10 or DP-11).
local function pkillPattern(connector)
  -- Escape POSIX ERE metacharacters in the connector name (e.g., '*' for wildcard).
  local escaped = connector:gsub("([%.%*%+%?%(%)%[%]%^%$|\\{}])", "\\%1")
  return shellQuote("(^|/)mpvpaper .* " .. escaped .. " ")
end

-- Executes a function for every affected physical output.
-- Avoids massive code duplication for wildcard ("*") assignments.
local function forEachOutput(connector, fn)
  if connector == "*" then
    for _, output in ipairs(noctalia.outputs()) do
      fn(output.name)
    end
  else
    fn(connector)
  end
end

-- Effective slideshow interval, driven solely by the picker's slider.
-- 0 (or anything non-positive) disables the slideshow.
local function slideshowInterval()
  local v = slideshowOverride
  if type(v) ~= "number" or v <= 0 then return nil end
  return math.floor(v)
end

-- Path to the mpv JSON IPC socket for a given connector. Used to poll which
-- file mpv is currently showing while a slideshow playlist is active.
local function ipcSocketPath(connector)
  return STATE_DIR .. "/ipc-" .. connector:gsub("[^%w%-]", "_") .. ".sock"
end

-- ==============================================================================
-- ── STATE PERSISTENCE ──────────────────────────────────────────────────────
-- ==============================================================================

local function persist()
  noctalia.runAsync("mkdir -p " .. shellQuote(STATE_DIR))
  noctalia.writeFile(STATE_FILE, noctalia.json.encode({
    assignments = assignments,
    launchedAsSystemd = launchedAsSystemd
  }) or "")
end

local function loadAssignments()
  local content = noctalia.readFile(STATE_FILE)
  if type(content) == "string" and content ~= "" then
    local decoded = noctalia.json.decode(content)
    if type(decoded) == "table" then
      if decoded.assignments then
        assignments = decoded.assignments
        launchedAsSystemd = decoded.launchedAsSystemd or {}
      else
        assignments = decoded
      end
    end
  end
end

-- Persists the slider-driven slideshow interval so it survives restarts.
local function persistSlideshowOverride()
  noctalia.writeFile(STATE_DIR .. "/slideshow_override.json", noctalia.json.encode({ interval = slideshowOverride }) or "")
end

local function loadSlideshowOverride()
  local content = noctalia.readFile(STATE_DIR .. "/slideshow_override.json")
  if type(content) == "string" and content ~= "" then
    local decoded = noctalia.json.decode(content)
    if type(decoded) == "table" and type(decoded.interval) == "number" then
      slideshowOverride = decoded.interval
    end
  end
end

-- Publishes the internal state so the panel can read it (e.g., to render paused UI).
local function publish()
  noctalia.state.set("assignments", assignments)
  noctalia.state.set("available", available)
  noctalia.state.set("paused", isPaused)
end

-- ==============================================================================
-- ── COMMAND BUILDERS ───────────────────────────────────────────────────────
-- ==============================================================================

-- Builds the -o options string forwarded to the internal mpv process.
local function mpvOptions(connector)
  local parts = { "loop-file=inf", "panscan=1.0" }
  if cfg("mute") then table.insert(parts, "no-audio") end
  table.insert(parts, "hwdec=" .. (cfg("hardware_decode") and "auto" or "no"))
  table.insert(parts, "input-ipc-server=" .. ipcSocketPath(connector))

  local extra = cfg("mpv_options")
  if type(extra) == "string" and extra ~= "" then table.insert(parts, extra) end
  return table.concat(parts, " ")
end

local function probeAutoModeSupport(callback)
  noctalia.runAsync("mpvpaper --help", function(result)
    mpvpaperSupportsAutoMode = type(result) == "table"
      and type(result.stdout) == "string"
      and result.stdout:find("--auto%-mode") ~= nil
    if callback then callback() end
  end)
end

local function normalizedAutoPauseMode()
  local mode = cfg("auto_pause")
  if mode == true then return "full" end   -- legacy boolean schema
  if mode == false then return "off" end   -- legacy boolean schema
  if type(mode) == "string" then return mode end
  return "off"
end

local function autoPauseFlag()
  local mode = normalizedAutoPauseMode()
  if mode == "off" then return "" end

  if mpvpaperSupportsAutoMode then
    if mode == "max" then return "--auto-pause --auto-mode MAX" end
    if mode == "full" then return "--auto-pause --auto-mode FULL" end
  end

  -- mpvpaper ≤ 1.8 fallback: only plain --auto-pause exists.
  return "--auto-pause"
end

-- Builds mpvpaper flags from config, including auto-pause modes and slideshow.
-- When a slideshow interval is present, we append `--slideshow <seconds>` so
-- mpvpaper cycles through the playlist built for that connector.
local function mpvpaperFlags()
  local options = autoPauseFlag()

  local interval = slideshowInterval()
  if interval then
    options = options .. (options ~= "" and " " or "") .. "--slideshow " .. tostring(interval)
  end

  return options
end

-- Collects systemd-specific cgroup properties (e.g., CPUQuota).
local function systemdProperties()
  local props = {}
  local cpu_quota = cfg("cpu_quota")
  if type(cpu_quota) == "number" and cpu_quota > 0 then table.insert(props, "CPUQuota=" .. tostring(cpu_quota) .. "%") end

  local allowed_cpus = cfg("allowed_cpus")
  if type(allowed_cpus) == "string" and allowed_cpus ~= "" then table.insert(props, "AllowedCPUs=" .. allowed_cpus) end

  local memory_max = cfg("memory_max")
  if type(memory_max) == "string" and memory_max ~= "" then table.insert(props, "MemoryMax=" .. memory_max) end

  local cpu_weight = cfg("cpu_weight")
  if type(cpu_weight) == "number" and cpu_weight > 0 then table.insert(props, "CPUWeight=" .. tostring(cpu_weight)) end

  return props
end

-- ==============================================================================
-- ── THUMBNAILS & FRAME EXTRACTION ──────────────────────────────────────────
-- ==============================================================================

-- When systemd is disabled, we cannot freeze the process. We fallback to killing
-- the video and extracting a static frame to use as the Noctalia wallpaper.
local function extractStaticWallpaper(connector, videoPath)
  if not cfg("extract_last_frame") then
    forEachOutput(connector, function(name) noctalia.setWallpaperEnabled(name, true) end)
    return
  end

  noctalia.runAsync("mkdir -p " .. shellQuote(CACHE_DIR), function()
    local outPath = CACHE_DIR .. "/" .. connector:gsub("[^%w%-]", "_") .. "_static.jpg"
    local cmd = "ffmpeg -y -ss 1 -i " .. shellQuote(videoPath) .. " -frames:v 1 -q:v 2 " .. shellQuote(outPath)

    noctalia.runAsync(cmd, function(success)
      if success and noctalia.fileExists(outPath) then
        forEachOutput(connector, function(name)
          noctalia.setWallpaper(name, outPath)
          noctalia.setWallpaperEnabled(name, true)
        end)
      else
        forEachOutput(connector, function(name) noctalia.setWallpaperEnabled(name, true) end)
      end
    end)
  end)
end

local function cachePath(path)
  return CACHE_DIR .. "/" .. path:gsub("[^%w]", "_") .. ".jpg"
end

local function updateStaticWallpaper(connector, videoPath)
  local outPath = cachePath(videoPath)

  if noctalia.fileExists(outPath) then
    forEachOutput(connector, function(name)
      noctalia.setWallpaper(name, outPath)
    end)
    return
  end

  if not cfg("extract_last_frame") then return end

  noctalia.runAsync("mkdir -p " .. shellQuote(CACHE_DIR), function()
    local cmd = "ffmpeg -y -ss 1 -i " .. shellQuote(videoPath) .. " -frames:v 1 -q:v 2 " .. shellQuote(outPath)
    noctalia.runAsync(cmd, function(result)
      if type(result) == "table" and result.exit_code == 0 and noctalia.fileExists(outPath) then
        forEachOutput(connector, function(name)
          noctalia.setWallpaper(name, outPath)
        end)
      else
        noctalia.log("mpvpaper: static-frame extraction failed for " .. videoPath .. ": " .. tostring(result and result.stderr))
      end
    end)
  end)
end

-- ==============================================================================
-- ── Slideshow ──────────────────────────────────────────────────────────────
-- ==========================================================================

-- Builds a deterministic slideshow playlist for a connector. It gathers all
-- supported video files from the directory of the selected path, sorts them,
-- and rotates the list so the chosen file is first. mpvpaper then loops this
-- playlist when `--slideshow` is enabled.
local function buildSlideshowPlaylist(connector, selectedPath)
  local dir = selectedPath:match("^(.*)/[^/]+$") or "."
  local entries = noctalia.listDir(dir) or {}
  local files = {}
  for _, name in ipairs(entries) do
    local ext = name:match("%.([%a%d]+)$")
    if ext and VIDEO_EXTENSIONS[ext:lower()] then
      table.insert(files, dir .. "/" .. name)
    end
  end

  if #files == 0 then
    noctalia.log("mpvpaper: slideshow directory has no video files, falling back to single file: " .. dir)
    return selectedPath
  end

  table.sort(files)

  local startIdx = 1
  for i, f in ipairs(files) do
    if f == selectedPath then 
      startIdx = i
      break 
    end
  end
  local ordered = {}
  for i = 0, #files - 1 do
    table.insert(ordered, files[((startIdx - 1 + i) % #files) + 1])
  end

  local playlistPath = CACHE_DIR .. "/playlist_" .. connector:gsub("[^%w%-]", "_") .. ".m3u"
  noctalia.writeFile(playlistPath, table.concat(ordered, "\n"))
  return playlistPath
end

-- Resolves the actual target path for mpvpaper: either the raw file (no
-- slideshow) or the playlist built above when a slideshow interval is active.
local function resolveTarget(connector, path)
  if slideshowInterval() then
    return buildSlideshowPlaylist(connector, path)
  end
  return path
end

-- Asks mpv's JSON IPC socket which file it is currently showing.
-- Requires the `socat` binary; silently no-ops if the socket isn't up yet.
local function queryCurrentFile(connector, callback)
  local sock = ipcSocketPath(connector)
  if not noctalia.fileExists(sock) then
    callback(nil)
    return
  end
  local cmd = "echo '{\"command\":[\"get_property\",\"path\"]}' | socat - " ..
    shellQuote("UNIX-CONNECT:" .. sock)
  noctalia.runAsync(cmd, function(result)
    if type(result) ~= "table" or type(result.stdout) ~= "string" then
      noctalia.log("mpvpaper: ipc query failed for " .. connector .. ": " .. tostring(result))
      callback(nil)
      return
    end
    local path = result.stdout:match('"data":"(.-)"')
    callback(path)
  end)
end

-- Polls mpv for the currently displayed file, and if it changed since the
-- last tick, syncs `assignments` (so the picker highlights the right tile and
-- extractStaticWallpaper grabs the correct frame on stop) and refreshes the
-- static wallpaper texture to match. This is what keeps the slideshow-aware
-- state in sync with mpv's internal playlist position.
local function refreshCurrentFile(connector)
  queryCurrentFile(connector, function(current)
    if type(current) ~= "string" or current == "" then return end
    if currentPath[connector] == current then return end

    currentPath[connector] = current
    assignments[connector] = current
    persist()
    publish()
    updateStaticWallpaper(connector, current)
  end)
end

-- ==============================================================================
-- ── PROCESS MANAGEMENT ─────────────────────────────────────────────────────
-- ==============================================================================

-- Kills the mpvpaper process.
-- Note on pkill: The sandboxed noctalia.runAsync API does not return PIDs. Thus,
-- without systemd, matching by command line via pkill is the only reliable way to terminate it.
local function killMpvpaper(connector, callback, signal)
  local sig = (type(signal) == "number" and signal > 0) and signal or 15
  local killCmd
  local pattern = pkillPattern(connector)
  if launchedAsSystemd[connector] then
    local unitName = unitNameFor(connector)
    if isPaused[connector] then
      -- A frozen cgroup ignores SIGTERM. We must thaw it right before stopping.
      killCmd = "systemctl --user thaw " .. shellQuote(unitName) .. " ; systemctl --user stop " .. shellQuote(unitName)
    else
      killCmd = "systemctl --user stop " .. shellQuote(unitName)
    end
  elseif isPaused[connector] then
    -- A SIGSTOP'd process ignores SIGTERM. We must resume it right before killing.
    killCmd = "pkill -CONT -f -- " .. pattern .. " ; pkill -" .. sig .. " -f -- " .. pattern
  else
    killCmd = "pkill -" .. sig .. " -f -- " .. pattern
  end

  isPaused[connector] = false
  currentPath[connector] = nil

  if callback then
    noctalia.runAsync(killCmd, callback)
  else
    noctalia.runAsync(killCmd)
  end
end

-- Spawns a new mpvpaper instance for the given connector.
-- When a slideshow is active, we start mpvpaper against the generated
-- playlist; when it is disabled, we just point it at the single file.
local function startMpvpaper(connector, path)
  -- Temporarily set the cached thumbnail as the background to prevent black screens during startup.
  local thumb = CACHE_DIR .. "/" .. path:gsub("[^%w]", "_") .. ".jpg"
  local target = resolveTarget(connector, path)

  if noctalia.fileExists(thumb) then
    forEachOutput(connector, function(name)
      noctalia.setWallpaper(name, thumb)
      noctalia.setWallpaperEnabled(name, true)
    end)
  end

  killMpvpaper(connector, function()
    launchedAsSystemd[connector] = cfg("run_as_systemd")
    persist()
    local flags = mpvpaperFlags()
    local cmd = "mpvpaper "
    if flags ~= "" then cmd = cmd .. flags .. " " end
    cmd = cmd .. "-o " .. shellQuote(mpvOptions(connector)) .. " " .. shellQuote(connector) .. " " .. shellQuote(target) -- mpvpaper -o [mpv-options] [connector] [video-path]

    local nice = cfg("nice")
    if type(nice) == "number" and nice ~= 0 then
      cmd = "nice -n " .. tostring(nice) .. " " .. cmd
    end

    if launchedAsSystemd[connector] then
      local unitName = unitNameFor(connector)
      local propsCmd = ""
      for _, prop in ipairs(systemdProperties()) do
        propsCmd = propsCmd .. "--property=" .. shellQuote(prop) .. " "
      end
      cmd = "systemd-run --user --scope " .. propsCmd .. "--unit=" .. shellQuote(unitName) .. " " .. cmd
    end

    -- Run mpvpaper in background
    noctalia.runAsync("exec " .. cmd .. " >/dev/null 2>&1 &", function() end)
    noctalia.runAsync("sleep 0.8", function()
      forEachOutput(connector, function(name) noctalia.setWallpaperEnabled(name, false) end)
    end)
  end)
end

-- ==============================================================================
-- ── PAUSE / RESUME / TOGGLE ────────────────────────────────────────────────
-- ==============================================================================

local function freezeMpvpaper(connector)
  isPaused[connector] = true
  if cfg("run_as_systemd") then
    local unitName = unitNameFor(connector)
    noctalia.runAsync("systemctl --user freeze " .. shellQuote(unitName))
  else
    -- Send SIGSTOP to freeze the process in place, preserving the last frame on screen.
    noctalia.runAsync("pkill -STOP -f -- " .. pkillPattern(connector))
  end
end

local function thawMpvpaper(connector)
  isPaused[connector] = false
  if cfg("run_as_systemd") then
    local unitName = unitNameFor(connector)
    noctalia.runAsync("systemctl --user thaw " .. shellQuote(unitName))
  else
    -- Send SIGCONT to resume the frozen process.
    noctalia.runAsync("pkill -CONT -f -- " .. pkillPattern(connector))
  end
end

local function toggleMpvpaper(connector)
  if isPaused[connector] then
    thawMpvpaper(connector)
  else
    freezeMpvpaper(connector)
  end
end

-- ==============================================================================
-- ── CORE ASSIGNMENT LOGIC ──────────────────────────────────────────────────
-- ==============================================================================

-- Clears an assigned video and restores the host wallpaper.
-- When a slideshow was in effect, the static wallpaper frame comes from the
-- currently displayed slideshow file (tracked via refreshCurrentFile).
local function clearVideo(connector)
  if type(connector) ~= "string" or connector == "" then return end

  local path = assignments[connector]
  assignments[connector] = nil
  persist()

  killMpvpaper(connector, function()
    if path then
      extractStaticWallpaper(connector, path)
    else
      forEachOutput(connector, function(name) noctalia.setWallpaperEnabled(name, true) end)
    end
  end)

  publish()
end

-- Assigns a video to a specific monitor or globally ("*").
-- If a slideshow interval is active, this actually starts a playlist beginning
-- at `path`; otherwise it just starts a single-file wallpaper.
local function setVideo(connector, path)
  if not available or type(connector) ~= "string" or connector == "" or type(path) ~= "string" or path == "" then return end

  -- Resolve overlaps: clear specific assignments when applying globally, and vice versa.
  if connector == "*" then
    for conn in pairs(assignments) do
      if conn ~= "*" then clearVideo(conn) end
    end
  else
    if assignments["*"] then clearVideo("*") end
  end

  assignments[connector] = path
  persist()

  startMpvpaper(connector, path)

  publish()
end

-- ==============================================================================
-- ── LIFECYCLE ──────────────────────────────────────────────────────────────
-- ==============================================================================

-- Returns a quick dictionary of currently attached physical monitors.
local function presentOutputs()
  local present = {}
  for _, output in ipairs(noctalia.outputs()) do present[output.name] = true end
  return present
end

-- Applies saved video assignments upon plugin startup.
-- When a slideshow interval is present, this will reapply playlists as needed.
local function applyAll()
  for connector, path in pairs(assignments) do
    startMpvpaper(connector, path)
  end
end

local function ensureSocatChecked()
  if socatAvailable == nil then
    socatAvailable = noctalia.commandExists("socat")
    if not socatAvailable then
      noctalia.log("mpvpaper: socat not found — slideshow static-frame sync disabled")
    end
  end
  return socatAvailable
end

-- Polls mpv over IPC for the currently displayed file while a slideshow is
-- active, keeping `assignments` and the static wallpaper texture in sync.
function update()
  if not available then return end
  if not slideshowInterval() then return end
  if not ensureSocatChecked() then return end
  for connector in pairs(assignments) do
    refreshCurrentFile(connector)
  end
end

-- Triggers when a monitor connects or disconnects.
function onOutputsChanged()
  if not available then return end
  local present = presentOutputs()

  local newMonitor = false
  for conn in pairs(present) do
    if not lastPresent[conn] then newMonitor = true end
  end

  -- Automatically apply wildcard wallpaper to newly connected monitors.
  if newMonitor and assignments["*"] then
    startMpvpaper("*", assignments["*"])
  end

  -- Relaunch specific assignments for monitors that just connected.
  for connector, path in pairs(assignments) do
    if connector ~= "*" then
      if present[connector] and not lastPresent[connector] then
        startMpvpaper(connector, path)
      end
    end
  end

  lastPresent = present
end

-- Called when the plugin is disabled, removed, or Noctalia is shutting down.
-- Terminates every active mpvpaper instance so no orphan processes remain.
-- Handles both direct processes (pkill) and systemd scopes (systemctl stop),
-- including thawing frozen/paused instances before sending SIGTERM.
function onExit(signal)
  for connector in pairs(assignments) do
    killMpvpaper(connector, nil, signal)
  end
end

-- ==============================================================================
-- ── IPC (COMMUNICATION WITH PANEL) ─────────────────────────────────────────
-- ==============================================================================

function onIpc(event, payload)
  if event == "clear-all" then
    for connector, path in pairs(assignments) do
      killMpvpaper(connector, function()
        if path then
          extractStaticWallpaper(connector, path)
        else
          forEachOutput(connector, function(name) noctalia.setWallpaperEnabled(name, true) end)
        end
      end)
    end
    assignments = {}
    persist()
    publish()

  elseif event == "clear" then
    clearVideo(payload)

  elseif event == "pause" or event == "freeze" then
    if type(payload) == "string" and payload ~= "" then
      freezeMpvpaper(payload)
    else
      for conn in pairs(assignments) do freezeMpvpaper(conn) end
    end
    publish()

  elseif event == "resume" or event == "thaw" then
    if type(payload) == "string" and payload ~= "" then
      thawMpvpaper(payload)
    else
      for conn in pairs(assignments) do thawMpvpaper(conn) end
    end
    publish()

  elseif event == "toggle" then
    if type(payload) == "string" and payload ~= "" then
      toggleMpvpaper(payload)
    else
      for conn in pairs(assignments) do toggleMpvpaper(conn) end
    end
    publish()

  elseif event == "slideshow" then
    local minutes = tonumber(payload)
    if minutes == nil then
      noctalia.log("mpvpaper: invalid slideshow IPC payload: " .. tostring(payload))
      return
    end
    slideshowOverride = math.max(0, math.floor(minutes)) * 60
    persistSlideshowOverride()
    noctalia.state.set("slideshowOverride", slideshowOverride)
    applyAll()
  end
end

-- Listen to the panel UI commands.
noctalia.state.watch("command", function(cmd)
  if type(cmd) ~= "table" then return end
  if cmd.action == "set" then setVideo(cmd.connector, cmd.path)
  elseif cmd.action == "clear" then clearVideo(cmd.connector)
  elseif cmd.action == "clear-all" then onIpc("clear-all", nil)
  elseif cmd.action == "freeze" then onIpc("freeze", cmd.connector)
  elseif cmd.action == "thaw" then onIpc("thaw", cmd.connector)
  elseif cmd.action == "toggle" then onIpc("toggle", cmd.connector) end
end)

-- Listen to the picker's slideshow interval slider. This is now the ONLY
-- source of truth for the interval — there is no manifest setting fallback.
-- The slider sends seconds via `slideshowCommand`, which we store and then
-- reapply all assignments so every output picks up the new interval.
noctalia.state.watch("slideshowCommand", function(cmd)
  slideshowOverride = cmd.interval
  persistSlideshowOverride()
  noctalia.state.set("slideshowOverride", slideshowOverride)
  applyAll()
end)

-- ==============================================================================
-- ── BOOT ───────────────────────────────────────────────────────────────────
-- ==============================================================================

noctalia.runAsync("mkdir -p '" .. STATE_DIR:gsub("'", "'\\''") .. "'")
loadAssignments()
loadSlideshowOverride()

available = noctalia.commandExists("mpvpaper")
if available then
  probeAutoModeSupport(function()
    lastPresent = presentOutputs()
    applyAll()
  end)
else
  noctalia.notifyError("Video Wallpaper", "mpvpaper is not installed")
end

publish()
noctalia.state.set("slideshowOverride", slideshowOverride)

-- Called when any configuration setting is changed.
-- Because auto-pause and resource limits affect how mpvpaper is spawned,
-- we simply reapply all assignments so the running instances pick up the
-- new configuration (including slideshow interval changes coming from the
-- slider).
function onConfigChanged(key, value)
  applyAll()
end