--!nonstrict
-- Umbriel Companion service - the only entry that talks to the compositor.
--
-- Umbriel pushes its workspace list, layout mode included, over the IPC event
-- stream. `umbriel subscribe workspaces` is that stream on stdout, one JSON
-- object per line, so the service holds it open and republishes each line as a
-- snapshot the UI entries read. No timer, no polling: the bar glyph changes in
-- the same breath as the keybind that changed the layout.
--
--   noctalia.runStream(cmd, onLine)   long-lived child, one callback per line
--   noctalia.state.set("umbriel.state", snapshot)     one snapshot, one re-render
--   noctalia.state.watch("umbriel.request", handler)  actions from bar and panel

local COMMAND_TIMEOUT_MS = 2000

-- Both halves matter: the socket variable proves this is an Umbriel session, the
-- binary is what the service actually runs.
local available = noctalia.getenv("UMBRIEL_SOCKET") ~= nil and noctalia.commandExists("umbriel")

local streaming = false

local function publish(workspaces, err)
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
    error = err,
  })
end

local function onLine(line)
  local decoded = noctalia.json.decode(line)
  if type(decoded) ~= "table" then
    return
  end
  -- The stream reports its own rejection on the first line and then closes; every
  -- other line is a workspaces snapshot.
  if type(decoded.err) == "string" then
    publish({}, decoded.err)
    return
  end
  if decoded.event == "workspaces" and type(decoded.data) == "table" then
    publish(decoded.data, nil)
  end
end

local function startStream()
  if not available or streaming then
    return
  end
  streaming = noctalia.runStream("umbriel subscribe workspaces", onLine)
  if not streaming then
    publish({}, noctalia.tr("error.stream_failed"))
  end
end

-- runStream never reports its child exiting, and an idle stream is silent, so
-- silence cannot be told from death. Rather than poll for it, re-check when a UI
-- entry asks: if no subscriber survives, arm a new stream.
local function verifyStream()
  if not available then
    return
  end
  local started = noctalia.processMatches(function(matched)
    if not matched then
      streaming = false
      startStream()
    end
  end, "umbriel", "subscribe")
  if not started then
    streaming = false
    startStream()
  end
end

local function runAction(action)
  noctalia.runAsync({ "umbriel", "msg", action }, function(result)
    -- Nothing to refresh on success: a change to the workspace list arrives on the
    -- stream by itself.
    if result.exitCode ~= 0 or result.timedOut then
      local reason = noctalia.string.trim(result.stderr)
      noctalia.notifyError(noctalia.tr("notify.action_failed", { action = action }), reason)
    end
  end, COMMAND_TIMEOUT_MS)
end

noctalia.state.watch("umbriel.request", function(value)
  if not available or type(value) ~= "table" then
    return
  end
  if type(value.action) == "string" and value.action ~= "" then
    runAction(value.action)
  else
    verifyStream()
  end
end)

publish({}, nil)
startStream()
