--!nonstrict
-- Video wallpaper — headless service.
-- This service handles active video wallpaper assignments and lifecycle.
-- Note: Noctalia plugin scripts run in an isolated sandbox without `require`.
-- Therefore, all logic (supervisor, IPC, state management) must reside here.

noctalia.setUpdateInterval(1000)

-- ==============================================================================
-- ── PATHS AND STATE ────────────────────────────────────────────────────────
-- ==============================================================================

local CACHE_DIR = (noctalia.getenv("XDG_CACHE_HOME") or ((noctalia.getenv("HOME") or "") .. "/.cache")) .. "/noctalia/mpvpaper"
local STATE_DIR = (noctalia.getenv("XDG_STATE_HOME") or ((noctalia.getenv("HOME") or "") .. "/.local/state")) .. "/noctalia/mpvpaper"
local STATE_FILE = STATE_DIR .. "/assignments.json"

local assignments = {}  -- Map of connector -> video path ("*" for all outputs)
local lastPresent = {}  -- Map of connector -> true (monitors seen last tick)
local isPaused = {}     -- Map of connector -> true (paused monitors)
local available = false -- Is mpvpaper binary installed?

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

-- ==============================================================================
-- ── STATE PERSISTENCE ──────────────────────────────────────────────────────
-- ==============================================================================

local function persist()
  noctalia.runAsync("mkdir -p " .. shellQuote(STATE_DIR))
  noctalia.writeFile(STATE_FILE, noctalia.json.encode(assignments) or "")
end

local function loadAssignments()
  local content = noctalia.readFile(STATE_FILE)
  if type(content) == "string" and content ~= "" then
    local decoded = noctalia.json.decode(content)
    if type(decoded) == "table" then assignments = decoded end
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
local function mpvOptions()
  local parts = { "loop-file=inf", "panscan=1.0" }
  if cfg("mute") then table.insert(parts, "no-audio") end
  table.insert(parts, "hwdec=" .. (cfg("hardware_decode") and "auto" or "no"))
  
  local extra = cfg("mpv_options")
  if type(extra) == "string" and extra ~= "" then table.insert(parts, extra) end
  return table.concat(parts, " ")
end

local function mpvpaperFlags()
  if cfg("auto_pause") then return "--auto-pause" end
  return ""
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

-- ==============================================================================
-- ── PROCESS MANAGEMENT ─────────────────────────────────────────────────────
-- ==============================================================================

-- Kills the mpvpaper process.
-- Note on pkill: The sandboxed noctalia.runAsync API does not return PIDs. Thus,
-- without systemd, matching by command line via pkill is the only reliable way to terminate it.
local function killMpvpaper(connector, callback)
  local killCmd
  local pattern = pkillPattern(connector)
  if cfg("run_as_systemd") then
    local unitName = unitNameFor(connector)
    if isPaused[connector] then
      -- A frozen cgroup ignores SIGTERM. We must thaw it right before stopping.
      killCmd = "systemctl --user thaw " .. shellQuote(unitName) .. " ; systemctl --user stop " .. shellQuote(unitName)
    else
      killCmd = "systemctl --user stop " .. shellQuote(unitName)
    end
  elseif isPaused[connector] then
    -- A SIGSTOP'd process ignores SIGTERM. We must resume it right before killing.
    killCmd = "pkill -CONT -f -- " .. pattern .. " ; pkill -f -- " .. pattern
  else
    killCmd = "pkill -f -- " .. pattern
  end
  
  isPaused[connector] = false

  if callback then
    noctalia.runAsync(killCmd, callback)
  else
    noctalia.runAsync(killCmd)
  end
end

-- Spawns a new mpvpaper instance for the given connector.
local function startMpvpaper(connector, path)
  -- Temporarily set the cached thumbnail as the background to prevent black screens during startup.
  local thumb = CACHE_DIR .. "/" .. path:gsub("[^%w]", "_") .. ".jpg"
  if noctalia.fileExists(thumb) then
    forEachOutput(connector, function(name) 
      noctalia.setWallpaper(name, thumb) 
      noctalia.setWallpaperEnabled(name, true)
    end)
  end

  killMpvpaper(connector, function()
    local flags = mpvpaperFlags()
    local cmd = "mpvpaper "
    if flags ~= "" then cmd = cmd .. flags .. " " end
    cmd = cmd .. "-o " .. shellQuote(mpvOptions()) .. " " .. shellQuote(connector) .. " " .. shellQuote(path) -- mpvpaper -o [mpv-options] [connector] [video-path]
    
    local nice = cfg("nice")
    if type(nice) == "number" and nice ~= 0 then
      cmd = "nice -n " .. tostring(nice) .. " " .. cmd
    end
    
    if cfg("run_as_systemd") then
      local unitName = unitNameFor(connector)
      local propsCmd = ""
      for _, prop in ipairs(systemdProperties()) do
        propsCmd = propsCmd .. "--property=" .. shellQuote(prop) .. " "
      end
      cmd = "systemd-run --user --scope " .. propsCmd .. "--unit=" .. shellQuote(unitName) .. " " .. cmd
    end

    -- Run mpvpaper
    noctalia.runStream("exec " .. cmd .. " 2>/dev/null", function() end)
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
local function applyAll()
  for connector, path in pairs(assignments) do
    startMpvpaper(connector, path)
  end
end

function update() end

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

-- ==============================================================================
-- ── BOOT ───────────────────────────────────────────────────────────────────
-- ==============================================================================

noctalia.runAsync("mkdir -p '" .. STATE_DIR:gsub("'", "'\\''") .. "'")
loadAssignments()

available = noctalia.commandExists("mpvpaper")
if available then
  lastPresent = presentOutputs()
  applyAll()
else
  noctalia.notifyError("Video Wallpaper", "mpvpaper is not installed")
end

publish()
