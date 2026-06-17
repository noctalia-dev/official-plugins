-- Headless [[service]]: runs update checks in the background and publishes
-- results to the plugin's shared state channel. All other entries
-- (widget, desktop, shortcut, launcher) read from this state.

local NOCTALIA_PKGS = { "noctalia-qs", "noctalia-shell" }
local allUpdates = {}
local initialized = false

local perSourceCounts = { system = 0, aur = 0, flatpak = 0 }

local function checkNoctalia()
  local highlight = noctalia.getConfig("noctalia_highlight")
  if not highlight then
    noctalia.state.set("noctalia_update", false)
    return
  end
  for _, u in ipairs(allUpdates) do
    for _, n in ipairs(NOCTALIA_PKGS) do
      if string.find(u.name, n) then
        noctalia.state.set("noctalia_update", true)
        return
      end
    end
  end
  noctalia.state.set("noctalia_update", false)
end

local function publishState()
  checkNoctalia()
  noctalia.state.set("updates", allUpdates)
  noctalia.state.set("count", #allUpdates)
  noctalia.state.set("system_count", perSourceCounts.system)
  noctalia.state.set("aur_count", perSourceCounts.aur)
  noctalia.state.set("flatpak_count", perSourceCounts.flatpak)
  noctalia.state.set("refreshing", false)
  noctalia.state.set("error", nil)
end

local function setError(msg)
  noctalia.log("ERROR: " .. msg)
  noctalia.state.set("error", msg)
  noctalia.state.set("refreshing", false)
  noctalia.state.set("updates", allUpdates)
  noctalia.state.set("count", #allUpdates)
  noctalia.state.set("system_count", perSourceCounts.system)
  noctalia.state.set("aur_count", perSourceCounts.aur)
  noctalia.state.set("flatpak_count", perSourceCounts.flatpak)
end

local function parseUpdates(output, source)
  local results = {}
  for line in string.gmatch(output, "[^\r\n]+") do
    local parts = {}
    for word in string.gmatch(line, "%S+") do
      table.insert(parts, word)
    end
    if #parts >= 4 then
      table.insert(results, {
        id = parts[1],
        name = parts[1],
        oldVer = parts[2],
        newVer = parts[4],
        source = source,
      })
    end
  end
  return results
end

local function parseFlatpakUpdates(output)
  local results = {}
  for line in string.gmatch(output, "[^\r\n]+") do
    local parts = {}
    for word in string.gmatch(line, "%S+") do
      table.insert(parts, word)
    end
    -- Expected tab-separated format: application\tname\tnewver\toldver
    if #parts >= 4 then
      table.insert(results, {
        id = parts[1],
        name = parts[2] or parts[1],
        oldVer = parts[4],
        newVer = parts[3],
        source = "flatpak",
      })
    elseif #parts >= 2 then
      table.insert(results, {
        id = parts[1],
        name = parts[2] or parts[1],
        oldVer = "",
        newVer = parts[3] or "",
        source = "flatpak",
      })
    end
  end
  return results
end

local function runFlatpakCheck(cbOk, cbErr)
  -- Refresh remote metadata first, then get updates with old+new versions
  local cmd = "flatpak update --no-deploy --noninteractive >/dev/null 2>&1; awk 'NR==FNR{a[$1]=$2; next} $1 in a{print $0 \"\t\" a[$1]}' <(flatpak list --columns=application,version 2>/dev/null) <(flatpak remote-ls --updates --columns=application,name,version 2>/dev/null)"
  noctalia.runAsync(cmd, function(res)
    if res.exitCode ~= 0 and not res.stdout then
      cbErr("flatpak check failed (exit " .. res.exitCode .. ")")
      return
    end
    local updates = parseFlatpakUpdates(res.stdout)
    cbOk(updates)
  end)
end

local refreshToast = false

local function doFinalizeStep()
  table.sort(allUpdates, function(a, b)
    if a.source ~= b.source then
      local order = { system = 1, aur = 2, flatpak = 3 }
      return (order[a.source] or 99) < (order[b.source] or 99)
    end
    return a.name < b.name
  end)

  perSourceCounts = { system = 0, aur = 0, flatpak = 0 }
  for _, u in ipairs(allUpdates) do
    perSourceCounts[u.source] = (perSourceCounts[u.source] or 0) + 1
  end

  publishState()

  if refreshToast then
    local count = #allUpdates
    local msg = tostring(count) .. " " .. noctalia.trp("toast.refreshed", count)
    noctalia.notify("Arch Updater", msg)
  end
end

local function doAurCheckStep()
  local cmd = noctalia.getConfig("aur_cmd")
  noctalia.runAsync(cmd, function(res)
    if res.exitCode ~= 0 and not res.stdout then
      noctalia.log("AUR check exit code: " .. res.exitCode)
    end
    local existing = {}
    for _, u in ipairs(allUpdates) do
      existing[u.id] = true
    end
    local aurUpdates = parseUpdates(res.stdout, "aur")
    for _, u in ipairs(aurUpdates) do
      if not existing[u.id] then
        table.insert(allUpdates, u)
      end
    end

    local flatpakEnabled = noctalia.getConfig("flatpak_enabled")
    if flatpakEnabled then
      runFlatpakCheck(function(flatpakUpdates)
        for _, u in ipairs(flatpakUpdates) do
          table.insert(allUpdates, u)
        end
        doFinalizeStep()
      end, function(err)
        setError(err)
      end)
    else
      doFinalizeStep()
    end
  end)
end

local function doSystemCheckStep()
  local cmd = noctalia.getConfig("system_cmd")
  noctalia.runAsync(cmd, function(res)
    if res.exitCode ~= 0 and not res.stdout then
      setError("system check failed (exit " .. res.exitCode .. ")")
      return
    end
    local systemUpdates = parseUpdates(res.stdout, "system")
    for _, u in ipairs(systemUpdates) do
      table.insert(allUpdates, u)
    end
    doAurCheckStep()
  end)
end

local function refresh()
  if noctalia.state.get("refreshing") then
    noctalia.log("refresh already in progress, skipping")
    return
  end

  noctalia.log("refreshing updates...")
  allUpdates = {}
  perSourceCounts = { system = 0, aur = 0, flatpak = 0 }
  noctalia.state.set("refreshing", true)
  noctalia.state.set("error", nil)

  refreshToast = noctalia.getConfig("toast_enabled")
  if refreshToast then
    noctalia.notify("Arch Updater", noctalia.tr("toast.refreshing"))
  end

  doSystemCheckStep()
end

local function runUpdate()
  local cmd = noctalia.getConfig("update_cmd")
  noctalia.log("running update command: " .. cmd)
  noctalia.runInTerminal(cmd)
end

-- Watch for commands from other entries
noctalia.state.watch("command", function(cmd)
  if type(cmd) == "table" then
    if cmd.action == "refresh" then
      refresh()
    elseif cmd.action == "update" then
      runUpdate()
    end
  end
end)

-- First update tick: do initial refresh and set up the timer
function update()
  if not initialized then
    initialized = true
    refresh()
  end

  local interval = noctalia.getConfig("refresh_interval")
  noctalia.setUpdateInterval(interval * 60000)
end

function onIpc(event, _payload)
  if event == "refresh" then
    refresh()
  elseif event == "update" then
    runUpdate()
  end
end
