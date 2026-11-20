-- SPDX-License-Identifier: MIT
-- What the user has chosen. Changes are pure: each returns a new selection
-- that remembers the previous slots, apps and timing for one-level undo.
local Files = require("./files.luau")
local Slots = require("./slots.luau")

local M = {}

function M.empty()
  return { version = 1, slots = {}, apps = {}, timing = {}, imports = {} }
end

function M.copy(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for key, item in pairs(value) do
    out[key] = M.copy(item)
  end
  return out
end

function M.load(path)
  local raw = noctalia.readFile(path)
  local data = raw and noctalia.json.decode(raw)
  if type(data) ~= "table" or data.version ~= 1 then
    return M.empty()
  end
  for _, key in ipairs({ "slots", "apps", "timing", "imports" }) do
    if type(data[key]) ~= "table" then
      data[key] = {}
    end
  end
  return data
end

function M.save(path, sel)
  return Files.writeAtomic(path, noctalia.json.encode(sel, true))
end

-- Every entry in use: slots in display order, then app rules.
function M.entries(sel)
  local out = {}
  for _, slot in ipairs(Slots.list) do
    if sel.slots[slot] then
      table.insert(out, sel.slots[slot])
    end
  end
  for _, rule in ipairs(sel.apps) do
    if rule.entry then
      table.insert(out, rule.entry)
    end
  end
  return out
end

function M.change(sel, fn)
  local nxt = M.copy(sel)
  nxt.previous = { slots = M.copy(sel.slots), apps = M.copy(sel.apps), timing = M.copy(sel.timing) }
  fn(nxt)
  return nxt
end

-- Imports are not part of the undo snapshot, so drop slots and app rules that
-- reference an import no longer in `n.imports`.
local function dropDangling(n)
  local current = {}
  for _, effect in ipairs(n.imports) do
    current[effect.id] = true
  end
  local function dangling(entry)
    return entry ~= nil
      and type(entry.id) == "string"
      and entry.id:sub(1, 7) == "import/"
      and not current[entry.id]
  end
  for slot, entry in pairs(n.slots) do
    if dangling(entry) then
      n.slots[slot] = nil
    end
  end
  for i = #n.apps, 1, -1 do
    if dangling(n.apps[i].entry) then
      table.remove(n.apps, i)
    end
  end
end

function M.undo(sel)
  local previous = sel.previous
  if not previous then
    return nil
  end
  return M.change(sel, function(n)
    n.slots = M.copy(previous.slots or {})
    n.apps = M.copy(previous.apps or {})
    n.timing = M.copy(previous.timing or {})
    dropDangling(n)
  end)
end

function M.clearAll(n)
  n.slots, n.apps, n.timing = {}, {}, {}
end

-- `entry` nil means "No effect" for that application.
function M.setApp(n, appId, slot, entry)
  for _, rule in ipairs(n.apps) do
    if rule.app_id == appId and rule.slot == slot then
      rule.entry = entry
      return
    end
  end
  table.insert(n.apps, { app_id = appId, slot = slot, entry = entry })
end

function M.removeApp(n, appId, slot)
  for i, rule in ipairs(n.apps) do
    if rule.app_id == appId and rule.slot == slot then
      table.remove(n.apps, i)
      return
    end
  end
end

function M.removeImport(n, id)
  for i, effect in ipairs(n.imports) do
    if effect.id == id then
      table.remove(n.imports, i)
      break
    end
  end
  dropDangling(n)
end

local function trim(s)
  return (s or ""):match("^%s*(.-)%s*$")
end

-- Empty fields mean "use the shader's own value".
function M.parseTiming(durationText, curveText)
  local timing = {}
  local duration = trim(durationText)
  if duration ~= "" then
    local n = tonumber(duration)
    if not n or n ~= math.floor(n) or n < 0 or n > 60000 then
      return nil, "error.duration"
    end
    timing.duration_ms = n
  end
  local curve = trim(curveText)
  if curve ~= "" then
    timing.curve = curve
  end
  return timing
end

return M
