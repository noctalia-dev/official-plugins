-- SPDX-License-Identifier: MIT
-- Make a selection live: download its files, rewrite the generated include,
-- and keep the change only if Umbriel reports no new diagnostics.
local Config = require("./config.luau")
local Files = require("./files.luau")
local Selection = require("./selection.luau")

local M = {}

function M.commit(env, nxt, cb)
  local paths = env.paths
  local jobs = Files.jobsFor(Selection.entries(nxt), paths.shaders, noctalia.fileExists)
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
