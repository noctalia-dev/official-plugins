-- SPDX-License-Identifier: MIT
-- Make a selection live: download its files, rewrite the generated include,
-- and keep the change only if Umbriel reports no new diagnostics.
local Config = require("./config.luau")
local Files = require("./files.luau")
local Selection = require("./selection.luau")

local M = {}

local function entriesOf(sel)
  local entries = {}
  for _, entry in pairs(sel.slots) do
    table.insert(entries, entry)
  end
  for _, rule in ipairs(sel.apps) do
    if rule.entry then
      table.insert(entries, rule.entry)
    end
  end
  return entries
end

function M.commit(env, nxt, cb)
  local paths = env.paths
  local jobs = Files.jobsFor(entriesOf(nxt), paths.shaders, noctalia.fileExists)
  Files.download(jobs, function(failed)
    if failed then
      cb(false, noctalia.tr("error.download", { file = failed }))
      return
    end
    Config.guardedWrite(paths.config, paths.generated, Config.render(nxt), true, function(ok, err)
      if ok then
        cb(Selection.save(env.selectionPath, nxt))
      else
        cb(false, err)
      end
    end)
  end)
end

return M
