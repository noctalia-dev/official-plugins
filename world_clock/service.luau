--!nonstrict
-- World Clock service - owns the timezone list and publishes live times.
--
-- Persistence: pluginDataDir()/zones.json (ordered IANA zone names).
-- State: world_clock.zones = { { id, label, time, offset }, ... }
-- Commands: world_clock.cmd = { op = "add"|"remove"|"reorder", zone = "...", index? = N }
-- IPC: add / remove / list / clear

noctalia.setUpdateInterval(1000)

local DEFAULT_ZONES = { "UTC", "America/New_York", "Europe/Berlin", "Asia/Tokyo" }

local zones = {} -- ordered list of IANA ids

local function dataPath()
  local dir = noctalia.pluginDataDir()
  if dir == nil then
    return nil
  end
  return dir .. "/zones.json"
end

local function shortLabel(zone)
  local slash = zone:match(".*/(.*)$")
  if slash ~= nil then
    return slash:gsub("_", " ")
  end
  return zone
end

local function saveZones()
  local path = dataPath()
  if path == nil then
    return
  end
  local encoded = noctalia.json.encode(zones)
  if encoded == nil then
    return
  end
  noctalia.writeFile(path, encoded)
end

local function loadZones()
  zones = {}
  local path = dataPath()
  if path ~= nil then
    local raw = noctalia.readFile(path)
    if raw ~= nil then
      local decoded = noctalia.json.decode(raw)
      if type(decoded) == "table" then
        for _, zone in ipairs(decoded) do
          if type(zone) == "string" and zone ~= "" and noctalia.isValidTimezone(zone) then
            table.insert(zones, zone)
          end
        end
      end
    end
  end
  if #zones == 0 then
    for _, zone in ipairs(DEFAULT_ZONES) do
      if noctalia.isValidTimezone(zone) then
        table.insert(zones, zone)
      end
    end
    saveZones()
  end
end

local function indexOf(zone)
  for i, id in ipairs(zones) do
    if id == zone then
      return i
    end
  end
  return nil
end

local function publish()
  local rows = {}
  local format = noctalia.timeFormat()
  for _, zone in ipairs(zones) do
    table.insert(rows, {
      id = zone,
      label = shortLabel(zone),
      time = noctalia.formatTime(format, nil, zone),
      offset = noctalia.formatTime("%z", nil, zone),
    })
  end
  noctalia.state.set("world_clock.zones", rows)
end

local function addZone(zone)
  zone = noctalia.string.trim(zone or "")
  if zone == "" then
    return false, "empty"
  end
  if not noctalia.isValidTimezone(zone) then
    return false, "invalid"
  end
  if indexOf(zone) ~= nil then
    return false, "duplicate"
  end
  table.insert(zones, zone)
  saveZones()
  publish()
  return true
end

local function removeZone(zone)
  zone = noctalia.string.trim(zone or "")
  local idx = indexOf(zone)
  if idx == nil then
    return false
  end
  table.remove(zones, idx)
  saveZones()
  publish()
  return true
end

local function clearZones()
  zones = {}
  saveZones()
  publish()
end

-- Move `zone` so it ends up at 1-based `index` in the final list.
local function reorderZone(zone, index)
  zone = noctalia.string.trim(zone or "")
  local fromIdx = indexOf(zone)
  if fromIdx == nil then
    return false
  end
  local insertAt = tonumber(index)
  if insertAt == nil then
    return false
  end
  table.remove(zones, fromIdx)
  if fromIdx < insertAt then
    insertAt -= 1
  end
  insertAt = math.max(1, math.min(insertAt, #zones + 1))
  table.insert(zones, insertAt, zone)
  saveZones()
  publish()
  return true
end

function onIpc(event, payload)
  if event == "add" then
    local ok, reason = addZone(payload or "")
    if not ok then
      if reason == "invalid" then
        noctalia.notifyError(noctalia.tr("title"), noctalia.tr("ipc.invalid_zone", { zone = payload or "" }))
      elseif reason == "duplicate" then
        noctalia.notifyError(noctalia.tr("title"), noctalia.tr("ipc.duplicate_zone", { zone = payload or "" }))
      end
    end
  elseif event == "remove" then
    if not removeZone(payload or "") then
      noctalia.notifyError(noctalia.tr("title"), noctalia.tr("ipc.missing_zone", { zone = payload or "" }))
    end
  elseif event == "clear" then
    clearZones()
  elseif event == "list" then
    local body = table.concat(zones, "\n")
    if body == "" then
      body = noctalia.tr("ipc.empty_list")
    end
    noctalia.notify(noctalia.tr("title"), body)
  end
end

noctalia.state.watch("world_clock.cmd", function(cmd)
  if type(cmd) ~= "table" then
    return
  end
  local op = cmd.op
  local zone = cmd.zone
  if op == "add" then
    local ok, reason = addZone(zone)
    if not ok and reason == "invalid" then
      noctalia.notifyError(noctalia.tr("title"), noctalia.tr("ipc.invalid_zone", { zone = zone or "" }))
    elseif not ok and reason == "duplicate" then
      noctalia.notifyError(noctalia.tr("title"), noctalia.tr("ipc.duplicate_zone", { zone = zone or "" }))
    end
  elseif op == "remove" then
    removeZone(zone)
  elseif op == "reorder" then
    reorderZone(zone, cmd.index)
  end
  noctalia.state.set("world_clock.cmd", nil)
end)

function update()
  publish()
end

loadZones()
publish()
