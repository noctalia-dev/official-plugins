--!nonstrict
-- World Clock service - owns the timezone list and publishes live times.
--
-- Persistence: pluginDataDir()/zones.json = array of
-- { id = "<IANA>", label = "<custom or empty>", on_bar = true|false }
-- Legacy files (plain IANA strings) load as label = "", on_bar = true.
-- State: world_clock.zones = { { id, label, time, offset, on_bar }, ... }
-- Commands: world_clock.cmd = { op = "add"|"remove"|"reorder"|"label"|"bar",
-- zone = "...", index? = N, label? = "...", on_bar? = bool }
-- IPC: add / remove / list / clear

noctalia.setUpdateInterval(1000)

local DEFAULT_ZONES = { "UTC", "America/New_York", "Europe/Berlin", "Asia/Tokyo" }

local zones = {} -- ordered list of { id, label, on_bar }

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

-- A stored zone: id is the IANA name, label is the user's custom label
-- ("" = derive the short name from the id), on_bar gates the bar widget.
local function makeZone(id, label, onBar)
  return {
    id = id,
    label = noctalia.string.trim(label or ""),
    on_bar = onBar ~= false,
  }
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
        for _, entry in ipairs(decoded) do
          local id, label, onBar
          if type(entry) == "string" then
            -- Legacy zones.json: plain IANA strings.
            id, label = entry, ""
          elseif type(entry) == "table" and type(entry.id) == "string" then
            id = entry.id
            if type(entry.label) == "string" then
              label = entry.label
            end
            onBar = entry.on_bar
          end
          if id ~= nil and id ~= "" and noctalia.isValidTimezone(id) then
            table.insert(zones, makeZone(id, label, onBar))
          end
        end
      end
    end
  end
  if #zones == 0 then
    for _, zone in ipairs(DEFAULT_ZONES) do
      if noctalia.isValidTimezone(zone) then
        table.insert(zones, makeZone(zone))
      end
    end
    saveZones()
  end
end

local function indexOf(zone)
  zone = noctalia.string.trim(zone or "")
  for i, row in ipairs(zones) do
    if row.id == zone then
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
      id = zone.id,
      label = zone.label ~= "" and zone.label or shortLabel(zone.id),
      time = noctalia.formatTime(format, nil, zone.id),
      offset = noctalia.formatTime("%z", nil, zone.id),
      on_bar = zone.on_bar ~= false,
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
  table.insert(zones, makeZone(zone))
  saveZones()
  publish()
  return true
end

local function removeZone(zone)
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
  local fromIdx = indexOf(zone)
  if fromIdx == nil then
    return false
  end
  local insertAt = tonumber(index)
  if insertAt == nil then
    return false
  end
  local row = table.remove(zones, fromIdx)
  if fromIdx < insertAt then
    insertAt -= 1
  end
  insertAt = math.max(1, math.min(insertAt, #zones + 1))
  table.insert(zones, insertAt, row)
  saveZones()
  publish()
  return true
end

local function setLabel(zone, label)
  local idx = indexOf(zone)
  if idx == nil then
    return false
  end
  zones[idx].label = noctalia.string.trim(label or "")
  saveZones()
  publish()
  return true
end

local function setOnBar(zone, onBar)
  local idx = indexOf(zone)
  if idx == nil then
    return false
  end
  zones[idx].on_bar = onBar ~= false
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
    local ids = {}
    for _, zone in ipairs(zones) do
      table.insert(ids, zone.id)
    end
    local body = table.concat(ids, "\n")
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
  elseif op == "label" then
    setLabel(zone, cmd.label)
  elseif op == "bar" then
    setOnBar(zone, cmd.on_bar)
  end
  noctalia.state.set("world_clock.cmd", nil)
end)

function update()
  publish()
end

loadZones()
publish()
