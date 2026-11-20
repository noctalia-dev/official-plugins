-- SPDX-License-Identifier: MIT
-- Shader files on disk: commit-pinned downloads and the personal import library.
local Slots = require("./slots.luau")

local M = {}

M.raw = "https://raw.githubusercontent.com/noctalia-dev/community-umbriel-shaders/"
M.maxImportBytes = 256 * 1024
local CONCURRENCY = 4

local function dirname(path)
  return path:match("^(.*)/[^/]*$")
end

function M.jobsFor(entries, shadersDir, exists)
  local jobs, seen = {}, {}
  for _, entry in ipairs(entries) do
    for _, path in ipairs(entry.files or {}) do
      local dest = shadersDir .. "/" .. entry.revision .. "/" .. path
      if not seen[dest] and not exists(dest) then
        table.insert(jobs, { url = M.raw .. entry.revision .. "/" .. path, dest = dest })
      end
      seen[dest] = true
    end
  end
  return jobs
end

-- Download into `<dest>.part` and rename, so a file on disk is always complete.
function M.download(jobs, cb)
  local nextJob, active, failed, finished = 1, 0, nil, false
  local pump
  pump = function()
    while failed == nil and active < CONCURRENCY and nextJob <= #jobs do
      local job = jobs[nextJob]
      nextJob += 1
      local part = job.dest .. ".part"
      noctalia.mkdirAll(dirname(job.dest))
      active += 1
      local started = noctalia.download(job.url, part, function(ok)
        active -= 1
        if ok then
          ok = noctalia.renameFile(part, job.dest)
        end
        if not ok then
          noctalia.removeFile(part)
          failed = failed or job.url
        end
        pump()
      end)
      if not started then
        active -= 1
        failed = failed or job.url
      end
    end
    if not finished and active == 0 and (failed ~= nil or nextJob > #jobs) then
      finished = true
      cb(failed)
    end
  end
  pump()
end

function M.slug(name)
  local slug = name:lower():gsub("[^%w]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
  return slug ~= "" and slug or "shader"
end

-- Copy a standalone GLSL file into the import library with a generated preset.
-- `taken` is a set of existing import ids.
function M.import(shadersDir, path, name, slot, taken)
  if not table.find(Slots.list, slot) then
    return nil, "unknown slot"
  end
  local fullPath = noctalia.expandPath((path or ""):match("^%s*(.-)%s*$"))
  local source, readErr = noctalia.readFile(fullPath)
  if not source then
    return nil, readErr or ("cannot read " .. fullPath)
  end
  if #source > M.maxImportBytes then
    return nil, "file is larger than 256 KiB"
  end
  local display = (name or ""):match("^%s*(.-)%s*$")
  if display == "" then
    display = (fullPath:match("([^/]+)$") or "shader"):gsub("%.glsl$", "")
  end
  local base = M.slug(display)
  local id, n = base, 1
  while taken["import/" .. id] do
    n += 1
    id = base .. "-" .. n
  end
  local dir = shadersDir .. "/imports/" .. id
  local preset = "import." .. id
  noctalia.mkdirAll(dir)
  local ok, err = noctalia.writeFile(dir .. "/shader.glsl", source)
  if ok then
    local toml = string.format(
      '[effects.preset."%s"]\nkind = "%s"\nshader = "shader.glsl"\n',
      preset,
      Slots.kind(slot)
    )
    ok, err = noctalia.writeFile(dir .. "/effect.toml", toml)
  end
  if not ok then
    return nil, err
  end
  return {
    id = "import/" .. id,
    name = display,
    description = fullPath,
    author = "",
    tags = { "imported" },
    uses = { slot },
    preset = preset,
    imported = true,
    include = { dir .. "/effect.toml" },
  }
end

function M.removeImport(effect)
  local dir = effect.include[1]:match("^(.*)/effect%.toml$")
  if dir then
    noctalia.removeFile(dir .. "/shader.glsl")
    noctalia.removeFile(dir .. "/effect.toml")
  end
end

return M
