--!nonstrict

noctalia.setUpdateInterval(1000)

local MODEL_SIZE = 1336922232
local helperPath = noctalia.pluginDir() .. "/depth_helper.py"
local dataDir = noctalia.pluginDataDir()
if dataDir == nil then
  error("Wallpaper Depth requires a plugin data directory")
end
local operationPath = dataDir .. "/setup-operation.json"
local runtimePython = dataDir .. "/runtime/.venv/bin/python"

local setupState = "checking"
local setupMessage = ""
local activeJob = nil
local cacheOperation = false
local pending = {}
local queued = {}
local outputs = {}
local lastParametersKey = nil
local lastAutoGenerate = nil
local pythonAvailable = noctalia.commandExists("python3")

local function decodeObject(raw)
  if type(raw) ~= "string" or raw == "" then
    return nil
  end
  local value = noctalia.json.decode(raw)
  if type(value) ~= "table" then
    return nil
  end
  return value
end

local function shortError(result, fallback)
  local message = ""
  if type(result) == "table" then
    message = noctalia.string.trim(result.stderr or "")
    if message == "" then
      message = noctalia.string.trim(result.stdout or "")
    end
  end
  if message == "" then
    message = fallback
  end
  if #message > 300 then
    message = string.sub(message, 1, 297) .. "..."
  end
  return message
end

local function parameters()
  local threshold = noctalia.getConfig("threshold")
  local feather = noctalia.getConfig("feather")
  local autoGenerate = noctalia.getConfig("auto_generate")
  if type(threshold) ~= "number" or type(feather) ~= "number" or type(autoGenerate) ~= "boolean" then
    return nil, noctalia.tr("service.invalid_settings")
  end
  threshold = math.max(0, math.min(100, threshold)) / 100
  feather = math.max(0, math.min(50, feather)) / 100
  return {
    threshold = threshold,
    feather = feather,
    autoGenerate = autoGenerate,
    key = string.format("%.4f:%.4f", threshold, feather),
  }, nil
end

local function publish()
  local rows = {}
  for _, row in pairs(outputs) do
    table.insert(rows, {
      name = row.name,
      wallpaperPath = row.wallpaperPath,
      state = row.state,
      message = row.message,
      cacheHit = row.cacheHit,
      elapsedMs = row.elapsedMs,
    })
  end
  table.sort(rows, function(left, right)
    return left.name < right.name
  end)
  local params, parameterError = parameters()
  noctalia.state.set("wallpaper_depth.status", {
    setupState = setupState,
    setupMessage = setupMessage ~= "" and setupMessage or parameterError,
    busy = setupState == "running" or activeJob ~= nil or cacheOperation,
    offline = noctalia.getSetting("shell.offline_mode"),
    pythonAvailable = pythonAvailable,
    modelSize = MODEL_SIZE,
    threshold = params ~= nil and params.threshold or 0,
    feather = params ~= nil and params.feather or 0,
    autoGenerate = params ~= nil and params.autoGenerate or false,
    outputs = rows,
  })
end

local function setSetupState(state, message)
  setupState = state
  setupMessage = message or ""
  publish()
end

local function readOperation()
  return decodeObject(noctalia.readFile(operationPath))
end

local function enqueue(outputName, wallpaperPath, params)
  if setupState ~= "ready" or type(wallpaperPath) ~= "string" or wallpaperPath == "" then
    return
  end
  local key = wallpaperPath .. "\n" .. params.key
  if queued[outputName] == key then
    return
  end
  if activeJob ~= nil and activeJob.outputName == outputName and activeJob.key == key then
    return
  end
  queued[outputName] = key
  table.insert(pending, {
    outputName = outputName,
    wallpaperPath = wallpaperPath,
    threshold = params.threshold,
    feather = params.feather,
    parametersKey = params.key,
    key = key,
  })
end

local runNext

runNext = function()
  if activeJob ~= nil or cacheOperation or setupState ~= "ready" then
    return
  end
  local params = parameters()
  if params == nil then
    return
  end

  local job = nil
  while #pending > 0 do
    local candidate = table.remove(pending, 1)
    queued[candidate.outputName] = nil
    local currentPath = noctalia.wallpaperPath(candidate.outputName)
    if currentPath == candidate.wallpaperPath and candidate.parametersKey == params.key then
      job = candidate
      break
    end
  end
  if job == nil then
    publish()
    return
  end

  activeJob = job
  local row = outputs[job.outputName]
  if row ~= nil then
    row.state = "processing"
    row.message = ""
    row.cacheHit = nil
    row.elapsedMs = nil
  end
  publish()

  local accepted = noctalia.runAsync({
    runtimePython,
    helperPath,
    "--data-dir",
    dataDir,
    "generate",
    "--wallpaper",
    job.wallpaperPath,
    "--threshold",
    tostring(job.threshold),
    "--feather",
    tostring(job.feather),
  }, function(result)
    local completedJob = activeJob
    activeJob = nil
    if completedJob == nil then
      runNext()
      return
    end

    local currentParameters = parameters()
    local currentPath = noctalia.wallpaperPath(completedJob.outputName)
    local currentRow = outputs[completedJob.outputName]
    local stale = currentParameters == nil
      or currentParameters.key ~= completedJob.parametersKey
      or currentPath ~= completedJob.wallpaperPath
    if stale then
      if currentRow ~= nil then
        currentRow.state = currentPath ~= nil and "waiting" or "no_wallpaper"
      end
      if currentParameters ~= nil and currentPath ~= nil then
        enqueue(completedJob.outputName, currentPath, currentParameters)
      end
      publish()
      runNext()
      return
    end

    if result.exitCode ~= 0 or result.timedOut then
      noctalia.setWallpaperMask(completedJob.outputName, nil)
      if currentRow ~= nil then
        currentRow.state = "error"
        currentRow.message = shortError(result, noctalia.tr("service.generation_failed"))
      end
    else
      local generated = decodeObject(result.stdout)
      if generated == nil
        or type(generated.maskPath) ~= "string"
        or generated.maskPath == ""
        or generated.wallpaperPath ~= completedJob.wallpaperPath
      then
        noctalia.setWallpaperMask(completedJob.outputName, nil)
        if currentRow ~= nil then
          currentRow.state = "error"
          currentRow.message = noctalia.tr("service.invalid_result")
        end
      else
        noctalia.setWallpaperMask(completedJob.outputName, {
          path = generated.maskPath,
          wallpaperPath = completedJob.wallpaperPath,
        })
        if currentRow ~= nil then
          currentRow.state = "ready"
          currentRow.message = ""
          currentRow.cacheHit = generated.cacheHit == true
          currentRow.elapsedMs = tonumber(generated.elapsedMs)
        end
      end
    end
    publish()
    runNext()
  end, 60000)

  if not accepted then
    activeJob = nil
    noctalia.setWallpaperMask(job.outputName, nil)
    if row ~= nil then
      row.state = "error"
      row.message = noctalia.tr("service.start_helper_failed")
    end
    publish()
    runNext()
  end
end

local function enqueueAll(force)
  local params, parameterError = parameters()
  if params == nil then
    setSetupState(setupState, parameterError)
    return
  end
  for outputName, row in pairs(outputs) do
    if type(row.wallpaperPath) == "string" and row.wallpaperPath ~= "" then
      if force then
        noctalia.setWallpaperMask(outputName, nil)
        row.state = "waiting"
        row.message = ""
      end
      enqueue(outputName, row.wallpaperPath, params)
    end
  end
  publish()
  runNext()
end

local function verifySetup()
  if not pythonAvailable then
    setSetupState("missing", noctalia.tr("service.python_missing"))
    return
  end
  setSetupState("checking", "")
  local accepted = noctalia.runAsync({
    "python3",
    helperPath,
    "--data-dir",
    dataDir,
    "status",
  }, function(result)
    if result.exitCode ~= 0 or result.timedOut then
      setSetupState("missing", shortError(result, noctalia.tr("service.validation_failed")))
      return
    end
    local value = decodeObject(result.stdout)
    if value ~= nil and value.ready == true then
      setSetupState("ready", "")
      enqueueAll(false)
    else
      setSetupState("missing", noctalia.tr("service.setup_missing"))
    end
  end, 60000)
  if not accepted then
    setSetupState("error", noctalia.tr("service.start_validation_failed"))
  end
end

local function startSetup()
  if noctalia.getSetting("shell.offline_mode") then
    setSetupState("error", noctalia.tr("service.offline"))
    return
  end
  if not pythonAvailable then
    setSetupState("error", noctalia.tr("service.python_missing"))
    return
  end
  if activeJob ~= nil or cacheOperation then
    setSetupState("error", noctalia.tr("service.busy"))
    return
  end

  noctalia.writeFile(operationPath, '{"state":"starting"}\n')
  setSetupState("running", noctalia.tr("service.setup_running"))
  local accepted = noctalia.runAsync({
    "python3",
    helperPath,
    "--data-dir",
    dataDir,
    "setup",
  })
  if not accepted then
    setSetupState("error", noctalia.tr("service.start_setup_failed"))
  end
end

local function pollSetup()
  if setupState ~= "running" then
    return
  end
  local operation = readOperation()
  if operation == nil or operation.state == "starting" or operation.state == "running" then
    return
  end
  if operation.state == "ready" then
    verifySetup()
  elseif operation.state == "error" then
    setSetupState(
      "error", type(operation.message) == "string" and operation.message or noctalia.tr("service.setup_failed")
    )
  end
end

local function clearCache()
  if activeJob ~= nil or cacheOperation or setupState == "running" then
    return
  end
  cacheOperation = true
  pending = {}
  queued = {}
  for outputName, row in pairs(outputs) do
    noctalia.setWallpaperMask(outputName, nil)
    row.state = row.wallpaperPath ~= nil and "waiting" or "no_wallpaper"
    row.message = ""
  end
  publish()
  local accepted = noctalia.runAsync({
    "python3",
    helperPath,
    "--data-dir",
    dataDir,
    "clear-cache",
  }, function(result)
    cacheOperation = false
    if result.exitCode ~= 0 or result.timedOut then
      setupMessage = shortError(result, noctalia.tr("service.clear_cache_failed"))
    else
      setupMessage = ""
    end
    publish()
    local params = parameters()
    if params ~= nil and params.autoGenerate then
      enqueueAll(false)
    end
  end, 60000)
  if not accepted then
    cacheOperation = false
    setupMessage = noctalia.tr("service.start_clear_cache_failed")
    publish()
  end
end

local function syncOutputs()
  local params, parameterError = parameters()
  if params == nil then
    setupMessage = parameterError
    publish()
    return
  end
  local current = {}
  for _, output in ipairs(noctalia.outputs()) do
    current[output.name] = true
    local wallpaperPath = noctalia.wallpaperPath(output.name)
    if wallpaperPath ~= nil and not noctalia.fileExists(wallpaperPath) then
      wallpaperPath = nil
    end
    local row = outputs[output.name]
    if row == nil then
      row = { name = output.name, state = "no_wallpaper", message = "" }
      outputs[output.name] = row
    end
    if row.wallpaperPath ~= wallpaperPath then
      noctalia.setWallpaperMask(output.name, nil)
      row.wallpaperPath = wallpaperPath
      row.state = wallpaperPath ~= nil and "waiting" or "no_wallpaper"
      row.message = ""
      row.cacheHit = nil
      row.elapsedMs = nil
      queued[output.name] = nil
      if params.autoGenerate and wallpaperPath ~= nil then
        enqueue(output.name, wallpaperPath, params)
      end
    end
  end
  for outputName, _ in pairs(outputs) do
    if current[outputName] ~= true then
      outputs[outputName] = nil
      queued[outputName] = nil
    end
  end

  if lastParametersKey ~= nil and lastParametersKey ~= params.key then
    for outputName, row in pairs(outputs) do
      noctalia.setWallpaperMask(outputName, nil)
      row.state = row.wallpaperPath ~= nil and "waiting" or "no_wallpaper"
      row.message = ""
    end
    pending = {}
    queued = {}
    if params.autoGenerate then
      enqueueAll(false)
    end
  end
  if lastAutoGenerate == false and params.autoGenerate then
    for outputName, row in pairs(outputs) do
      if row.state == "waiting" and row.wallpaperPath ~= nil then
        enqueue(outputName, row.wallpaperPath, params)
      end
    end
  end
  lastParametersKey = params.key
  lastAutoGenerate = params.autoGenerate
  publish()
  runNext()
end

noctalia.state.watch("wallpaper_depth.command", function(command)
  if type(command) ~= "table" then
    return
  end
  noctalia.state.set("wallpaper_depth.command", nil)
  if command.action == "setup" then
    startSetup()
  elseif command.action == "generate" then
    enqueueAll(true)
  elseif command.action == "clear_cache" then
    clearCache()
  end
end)

function onIpc(event, _payload)
  if event == "setup" then
    startSetup()
  elseif event == "generate" then
    enqueueAll(true)
  elseif event == "clear-cache" then
    clearCache()
  end
end

function onConfigChanged()
  syncOutputs()
end

function update()
  pollSetup()
  syncOutputs()
end

local operation = readOperation()
if operation ~= nil and (operation.state == "running" or operation.state == "starting") then
  setupState = "running"
  setupMessage = noctalia.tr("service.setup_running")
else
  verifySetup()
end
syncOutputs()
