-- SPDX-License-Identifier: MIT
-- The published community catalogue: fetch, cache, index, search, resolve.
local Slots = require("./slots.luau")

local M = {}

M.url =
  "https://raw.githubusercontent.com/noctalia-dev/community-umbriel-shaders/catalogue/catalogue.json"
M.maxAgeSeconds = 24 * 60 * 60

local function safe(path)
  return type(path) == "string"
    and path ~= ""
    and path:sub(1, 1) ~= "/"
    and not path:find("..", 1, true)
end

local function allSafe(paths)
  if paths == nil then
    return true
  end
  if type(paths) ~= "table" then
    return false
  end
  for _, path in ipairs(paths) do
    if not safe(path) then
      return false
    end
  end
  return true
end

local function byName(a, b)
  return a.name:lower() < b.name:lower()
end

-- Settings become TOML: keys must be bare-key-safe dotted paths and values scalars.
local function validSettings(settings)
  for key, value in pairs(settings) do
    local t = type(value)
    if
      type(key) ~= "string"
      or not key:match("^[%w_%-]+[%w_.%-]*$")
      or (t ~= "string" and t ~= "number" and t ~= "boolean")
    then
      return false
    end
  end
  return true
end

local function hasEntryFields(effect)
  return type(effect) == "table"
    and type(effect.id) == "string"
    and type(effect.name) == "string"
    and type(effect.preset) == "string"
end

local function isListable(effect)
  local activation = effect.activation
  return effect.role == "effect"
    and type(effect.uses) == "table"
    and type(activation) == "table"
    and type(activation.include) == "table"
    and type(activation.settings) == "table"
    and validSettings(activation.settings)
    and (effect.dependencies == nil or type(effect.dependencies) == "table")
end

local function isFamily(family)
  return type(family) == "table"
    and type(family.name) == "string"
    and type(family.activation) == "table"
    and type(family.activation.settings) == "table"
    and validSettings(family.activation.settings)
end

function M.index(data)
  if type(data) ~= "table" or data.schema_version ~= 1 or type(data.effects) ~= "table" then
    return nil, "unsupported catalogue"
  end
  local revision = type(data.source) == "table" and data.source.revision
  if type(revision) ~= "string" or not revision:match("^%x+$") then
    return nil, "unsupported catalogue revision"
  end
  local cat = { revision = revision, effects = {}, byId = {}, byPreset = {}, families = {} }
  for _, effect in ipairs(data.effects) do
    local usable = hasEntryFields(effect)
    if usable then
      local image = type(effect.preview) == "table" and effect.preview.image or nil
      local include = type(effect.activation) == "table" and effect.activation.include or nil
      usable = allSafe(effect.install_files) and allSafe(include) and (image == nil or safe(image))
    end
    if usable then
      cat.byId[effect.id] = effect
      cat.byPreset[effect.preset] = effect
      if isListable(effect) then
        table.insert(cat.effects, effect)
      end
    end
  end
  -- An effect is only offered when every dependency it names is indexed.
  local listed = {}
  for _, effect in ipairs(cat.effects) do
    local complete = true
    for _, depId in ipairs(effect.dependencies or {}) do
      if cat.byId[depId] == nil then
        complete = false
      end
    end
    if complete then
      table.insert(listed, effect)
    end
  end
  cat.effects = listed
  table.sort(cat.effects, byName)
  for _, family in ipairs(type(data.families) == "table" and data.families or {}) do
    if isFamily(family) then
      table.insert(cat.families, family)
    end
  end
  table.sort(cat.families, byName)
  return cat
end

function M.search(effects, query, slot)
  local needle = (query or ""):lower()
  local out = {}
  for _, effect in ipairs(effects) do
    if slot == nil or table.find(effect.uses or {}, slot) then
      local haystack = table
        .concat({
          effect.name,
          effect.description or "",
          effect.author or "",
          table.concat(effect.tags or {}, " "),
        }, " ")
        :lower()
      if needle == "" or haystack:find(needle, 1, true) then
        table.insert(out, effect)
      end
    end
  end
  return out
end

-- A self-contained selection entry: everything needed to render, download and
-- undo without the catalogue.
function M.resolve(cat, effect, slot, shadersDir)
  if effect.imported then
    return {
      id = effect.id,
      name = effect.name,
      preset = effect.preset,
      include = table.clone(effect.include),
      deps = {},
      files = {},
      settings = Slots.selector(slot, effect.preset),
    }
  end
  local files, seen, deps = {}, {}, {}
  local function addFiles(e)
    for _, path in ipairs(e.install_files or {}) do
      if not seen[path] then
        seen[path] = true
        table.insert(files, path)
      end
    end
  end
  addFiles(effect)
  for _, depId in ipairs(effect.dependencies or {}) do
    local dep = cat.byId[depId]
    if dep then
      addFiles(dep)
      table.insert(deps, depId)
    end
  end
  local base = shadersDir .. "/" .. cat.revision .. "/"
  local include = {}
  for _, path in ipairs(effect.activation.include) do
    table.insert(include, base .. path)
  end
  local settings = Slots.filter(effect.activation.settings, slot)
  for key, value in pairs(Slots.selector(slot, effect.preset)) do
    if settings[key] == nil then
      settings[key] = value
    end
  end
  return {
    id = effect.id,
    name = effect.name,
    preset = effect.preset,
    revision = cat.revision,
    files = files,
    include = include,
    deps = deps,
    settings = settings,
  }
end

-- The member effect a family selects for each slot, read from its activation.
function M.familySlots(cat, family)
  local out = {}
  for key, value in pairs(family.activation.settings) do
    local slot = key:match("^(effects%.[%w_]+)$") or key:match("^(animation%.[%w_]+)%.effect$")
    local effect = slot and type(value) == "string" and cat.byPreset[value]
    if effect and table.find(Slots.list, slot) then
      out[slot] = effect
    end
  end
  return out
end

local function cachePath(dataDir)
  return dataDir .. "/catalogue.json"
end

function M.readCache(dataDir)
  local raw = noctalia.readFile(cachePath(dataDir))
  if not raw then
    return nil
  end
  return (M.index(noctalia.json.decode(raw)))
end

function M.isStale(dataDir)
  local info = noctalia.fileInfo(cachePath(dataDir))
  return not info or os.time() - info.mtime > M.maxAgeSeconds
end

function M.fetch(dataDir, cb)
  local started = noctalia.http({ url = M.url }, function(response)
    if not response.ok or response.status ~= 200 then
      cb(nil, "HTTP " .. tostring(response.status))
      return
    end
    local cat, err = M.index(noctalia.json.decode(response.body))
    if not cat then
      cb(nil, err)
      return
    end
    noctalia.writeFile(cachePath(dataDir), response.body)
    cb(cat)
  end)
  if not started then
    cb(nil, "request not started")
  end
end

return M
