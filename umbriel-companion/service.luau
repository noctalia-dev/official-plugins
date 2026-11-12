--!nonstrict
-- Umbriel Companion service - the only entry that talks to the compositor.
--
-- Umbriel pushes its workspace list, window list, and active submap over the IPC
-- event stream. noctalia.compositor.subscribe opens a connection to that stream
-- for this service alone; Umbriel answers with a snapshot of each family, then
-- every change, and the service republishes the state the UI entries read.
-- Actions go straight to the IPC socket as typed requests.
--
--   noctalia.compositor.subscribe(options, onEvent)   the event stream, no child
--   noctalia.umbriel.action(request, cb)              one typed action, no child
--   noctalia.state.set("umbriel.state", snapshot)     one snapshot, one re-render
--   noctalia.state.watch("umbriel.request", handler)  actions from bar and panel

local available = false
local workspaces = {}
local windows = {}
local submap = ""
local submapReady = false
local streamError = nil

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

local function onEvent(event, data)
  -- The connection to the compositor dropped; the shell reconnects on its own
  -- and Umbriel sends fresh snapshots once the stream is back.
  if event == "reset" then
    available = false
    workspaces = {}
    windows = {}
    submap = ""
    submapReady = false
    if streamError == nil then
      streamError = noctalia.tr("error.stream_closed")
    end
    publish()
    return
  end
  -- Umbriel rejected the subscription; a "reset" follows and the retry sends the
  -- same request.
  if event == "error" then
    streamError = if type(data) == "string" and data ~= "" then data else noctalia.tr("error.stream_closed")
    publish()
    return
  end
  if event == "workspaces" and type(data) == "table" then
    workspaces = data
  elseif event == "windows" and type(data) == "table" then
    windows = data
  elseif event == "submap" and (data == nil or type(data) == "string") then
    submap = data or ""
    submapReady = true
  else
    return
  end
  available = true
  streamError = nil
  publish()
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
  if available and type(value.request) == "table" and type(value.request.action) == "string" then
    runAction(value.request)
  end
end)

publish()
-- Other compositors have event streams too, with their own event names (Hyprland
-- also sends "submap"), so only Umbriel's is read.
if noctalia.compositor.name() == "umbriel" then
  noctalia.compositor.subscribe({ events = { "workspaces", "windows", "submap" } }, onEvent)
end
