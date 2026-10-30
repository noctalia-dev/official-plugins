--!nonstrict
-- Umbriel Companion service - the only entry that talks to the compositor.
--
-- Umbriel pushes its workspace list, window list, and active submap over the IPC
-- event stream. `umbriel subscribe workspaces,windows,submap` is that stream on
-- stdout, one JSON object per line, so the service holds it open and republishes
-- each line as a snapshot the UI entries read. A retry tick connects when the
-- socket becomes ready; a connected session only reads the event stream.
-- Actions go straight to the IPC socket as typed requests.
--
--   noctalia.runStream(cmd, onLine)   long-lived child, one callback per line
--   noctalia.umbriel.action(request, cb)              one typed action, no child
--   noctalia.state.set("umbriel.state", snapshot)     one snapshot, one re-render
--   noctalia.state.watch("umbriel.request", handler)  actions from bar and panel

local RECONNECT_INTERVAL_MS = 1000
-- runStream has no exit callback. Report termination on stdout so the next
-- retry can reconnect, including when the child starts but cannot connect.
local STREAM_COMMAND = [[umbriel subscribe workspaces,windows,submap; printf '\n{"event":"umbriel-companion-disconnected"}\n']]

local available = false
local streaming = false
local workspaces = {}
local windows = {}
local submap = ""
local submapReady = false
local streamError = nil

-- A shell started by systemd can inherit WAYLAND_DISPLAY without UMBRIEL_SOCKET.
-- Follow the CLI's fallback, scoped to this display rather than another session.
local function socketPath()
  local explicit = noctalia.getenv("UMBRIEL_SOCKET")
  if explicit ~= nil and explicit ~= "" then
    return explicit
  end
  local runtimeDir = noctalia.getenv("XDG_RUNTIME_DIR")
  local display = noctalia.getenv("WAYLAND_DISPLAY")
  if runtimeDir ~= nil and runtimeDir ~= "" and display ~= nil and display ~= "" then
    return `{runtimeDir}/umbriel-{display}.sock`
  end
  return nil
end

-- A window's `focused` flag is per workspace. `active` would name the one window
-- holding keyboard focus, but the open panel takes that, so the target is the
-- focused window of the focused workspace.
local function findFocusedWindow(workspace)
  for _, window in ipairs(windows) do
    if window.focused == true and window.workspace == workspace.id then
      return window
    end
  end
  return nil
end

local function publish()
  local focused = nil
  for _, workspace in ipairs(workspaces) do
    if workspace.focused == true then
      focused = workspace
      break
    end
  end

  noctalia.state.set("umbriel.state", {
    available = available,
    workspaces = workspaces,
    focused = focused,
    focused_window = focused ~= nil and findFocusedWindow(focused) or nil,
    submap = submap,
    submap_ready = submapReady,
    error = streamError,
  })
end

local function onLine(line)
  local decoded = noctalia.json.decode(line)
  if type(decoded) ~= "table" then
    return
  end
  if decoded.event == "umbriel-companion-disconnected" then
    streaming = false
    available = false
    workspaces = {}
    windows = {}
    submap = ""
    submapReady = false
    streamError = noctalia.tr("error.stream_closed")
    publish()
    return
  end
  -- The stream reports its own rejection on the first line and then closes;
  -- every other line is one subscribed state snapshot.
  if type(decoded.err) == "string" then
    streamError = decoded.err
    publish()
    return
  end
  if decoded.event == "workspaces" and type(decoded.data) == "table" then
    workspaces = decoded.data
  elseif decoded.event == "windows" and type(decoded.data) == "table" then
    windows = decoded.data
  elseif decoded.event == "submap" and (decoded.data == nil or type(decoded.data) == "string") then
    submap = decoded.data or ""
    submapReady = true
  else
    return
  end
  available = true
  streamError = nil
  publish()
end

local function startStream()
  if streaming then
    return
  end
  local path = socketPath()
  if path == nil or not noctalia.fileExists(path) or not noctalia.commandExists("umbriel") then
    return
  end
  streaming = noctalia.runStream(STREAM_COMMAND, onLine)
  if not streaming then
    streamError = noctalia.tr("error.stream_failed")
    publish()
  end
end

-- `request` is Umbriel's typed action request without `cmd`, for example
-- { action = "workspace-set-layout", layout = "dwindle" }.
local function runAction(request)
  -- Nothing to refresh on success: any resulting state change arrives on the
  -- stream by itself.
  local accepted = noctalia.umbriel.action(request, function(ok, err)
    if not ok then
      noctalia.notifyError(noctalia.tr("notify.action_failed", { action = request.action }), err)
    end
  end)
  if not accepted then
    noctalia.notifyError(noctalia.tr("notify.action_failed", { action = request.action }))
  end
end

noctalia.state.watch("umbriel.request", function(value)
  if type(value) ~= "table" then
    return
  end
  startStream()
  if available and type(value.request) == "table" and type(value.request.action) == "string" then
    runAction(value.request)
  end
end)

function update()
  startStream()
end

noctalia.setUpdateInterval(RECONNECT_INTERVAL_MS)
publish()
startStream()
