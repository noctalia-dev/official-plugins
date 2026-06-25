-- Video wallpaper — headless service.
-- Owns the mpvpaper supervisor (one long-lived helper process driven through a FIFO)
-- and the per-output video assignments. The picker panel drives it through the shared
-- "command" state channel; the service publishes "assignments"/"available" back so the
-- panel and widget can mirror the current state.

noctalia.setUpdateInterval(1000)

local RUNTIME = noctalia.getenv("XDG_RUNTIME_DIR") or "/tmp"
local FIFO = RUNTIME .. "/noctalia-mpvpaper.fifo"
local STATE_DIR = (noctalia.getenv("XDG_STATE_HOME") or (noctalia.getenv("HOME") .. "/.local/state")) .. "/noctalia/mpvpaper"
local STATE_FILE = STATE_DIR .. "/assignments.json"

local assignments = {} -- connector -> video path
local lastPresent = {} -- connector -> true, outputs seen on the last reconcile
local pending = {}     -- FIFO command lines awaiting a ready supervisor
local available = false
local supervisorStarted = false

-- ── Helpers ──────────────────────────────────────────────────────────────

local function cfg(key)
  return noctalia.getConfig(key)
end

local function shellQuote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function mpvOptions()
  local parts = { "loop-file=inf", "panscan=1.0" }
  if cfg("mute") then
    table.insert(parts, "no-audio")
  end
  table.insert(parts, "hwdec=" .. (cfg("hardware_decode") and "auto" or "no"))
  local extra = cfg("mpv_options")
  if type(extra) == "string" and extra ~= "" then
    table.insert(parts, extra)
  end
  return table.concat(parts, " ")
end

local function mpvpaperFlags()
  if cfg("auto_pause") then
    return "--auto-pause"
  end
  return ""
end

-- Write any queued commands once the supervisor has created the FIFO. Small line
-- writes to a pipe are atomic, so concurrent runAsync writes never interleave.
local function flush()
  if not noctalia.fileExists(FIFO) then
    return
  end
  for _, line in ipairs(pending) do
    noctalia.runAsync("printf '%s\\n' " .. shellQuote(line) .. " > " .. shellQuote(FIFO))
  end
  pending = {}
end

local function fifo(line)
  table.insert(pending, line)
  flush()
end

local function startSupervisor()
  if supervisorStarted then
    return
  end
  local script = noctalia.pluginDir() .. "/supervisor.sh"
  local cmd = string.format(
    "exec sh %s %s %s %s",
    shellQuote(script), shellQuote(FIFO), shellQuote(mpvpaperFlags()), shellQuote(mpvOptions())
  )
  supervisorStarted = noctalia.runStream(cmd, function(_) end)
  if not supervisorStarted then
    noctalia.notifyError("Video Wallpaper", "Could not start the mpvpaper supervisor")
  end
end

local function persist()
  noctalia.runAsync("mkdir -p " .. shellQuote(STATE_DIR))
  noctalia.writeFile(STATE_FILE, noctalia.json.encode(assignments))
end

local function loadAssignments()
  local content = noctalia.readFile(STATE_FILE)
  if type(content) == "string" and content ~= "" then
    local decoded = noctalia.json.decode(content)
    if type(decoded) == "table" then
      assignments = decoded
    end
  end
end

local function publish()
  noctalia.state.set("assignments", assignments)
  noctalia.state.set("available", available)
end

-- ── Commands ──────────────────────────────────────────────────────────────

local function setVideo(connector, path)
  if not available or type(connector) ~= "string" or connector == "" or type(path) ~= "string" or path == "" then
    return
  end
  assignments[connector] = path
  persist()
  noctalia.setWallpaperEnabled(connector, false)
  fifo("set " .. connector .. " " .. path)
  publish()
end

local function clearVideo(connector)
  if type(connector) ~= "string" or connector == "" then
    return
  end
  assignments[connector] = nil
  persist()
  noctalia.setWallpaperEnabled(connector, true)
  fifo("clear " .. connector)
  publish()
end

-- ── Lifecycle ──────────────────────────────────────────────────────────────

local function presentOutputs()
  local present = {}
  for _, output in ipairs(noctalia.outputs()) do
    present[output.name] = true
  end
  return present
end

-- Apply every persisted assignment. mpvpaper simply exits for a not-yet-connected
-- output; onOutputsChanged re-applies when it appears.
local function applyAll()
  for connector, path in pairs(assignments) do
    noctalia.setWallpaperEnabled(connector, false)
    fifo("set " .. connector .. " " .. path)
  end
end

function update()
  flush()
end

-- Relaunch mpvpaper for an assigned output only when it (re)appears, so a routine
-- geometry change does not restart playback.
function onOutputsChanged()
  if not available then
    return
  end
  local present = presentOutputs()
  for connector, path in pairs(assignments) do
    if present[connector] and not lastPresent[connector] then
      noctalia.setWallpaperEnabled(connector, false)
      fifo("set " .. connector .. " " .. path)
    end
  end
  lastPresent = present
end

function onIpc(event, payload)
  if event == "clear-all" then
    for connector in pairs(assignments) do
      noctalia.setWallpaperEnabled(connector, true)
    end
    assignments = {}
    persist()
    fifo("clear-all")
    publish()
  end
end

-- The picker panel publishes { action, connector, path } to drive the service.
noctalia.state.watch("command", function(cmd)
  if type(cmd) ~= "table" then
    return
  end
  if cmd.action == "set" then
    setVideo(cmd.connector, cmd.path)
  elseif cmd.action == "clear" then
    clearVideo(cmd.connector)
  end
end)

-- ── Boot ──────────────────────────────────────────────────────────────────

noctalia.runAsync("mkdir -p " .. shellQuote(STATE_DIR))
loadAssignments()
available = noctalia.commandExists("mpvpaper")
if available then
  lastPresent = presentOutputs()
  startSupervisor()
  applyAll()
else
  noctalia.notifyError("Video Wallpaper", "mpvpaper is not installed")
end
publish()
