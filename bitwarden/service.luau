--!nonstrict
-- Bitwarden service: bw serve, status poll, unlock/lock/sync/copy

noctalia.setUpdateInterval(500)

local STATUS_TICKS = 4 -- 4 * 500ms = 2s between status polls when serve is up
local SLOW_POLL_TICKS = 60 -- 30s when serve is down or user is logged out
local SERVE_START_COOLDOWN_TICKS = 10
local tickCount = 0
local serveStartCooldown = 0
local nextSlowPollTick = 0
local statusInFlight = false
local opInFlight = false
local lastStatusKey = ""
local pendingClear = nil -- { text, ticksLeft }
local weStartedServe = false
local sessionUnlocked = false
local unlockDeadlineTick = nil
local pendingQuietLock = false

local status = {
  vault = "offline", -- offline | unauthenticated | locked | unlocked
  email = "",
  serverUrl = "",
  serveUp = false,
  bwAvailable = false,
  error = "",
}

local function cfg(key)
  return noctalia.getConfig(key)
end

local function vaultTimeoutMode()
  local mode = cfg("vault_timeout")
  if type(mode) ~= "string" or mode == "" then
    return "on_restart"
  end
  return mode
end

local function vaultTimeoutMinutes()
  local mode = vaultTimeoutMode()
  if mode == "never" or mode == "on_restart" then
    return nil
  end
  if mode == "custom" then
    local minutes = cfg("vault_timeout_custom_minutes")
    if type(minutes) ~= "number" then
      minutes = 15
    end
    return math.clamp(math.floor(minutes), 1, 10080)
  end
  local minutes = tonumber(mode)
  if minutes == nil or minutes <= 0 then
    return nil
  end
  return math.floor(minutes)
end

local function clearUnlockTimer()
  unlockDeadlineTick = nil
  sessionUnlocked = false
end

local function touchUnlockActivity()
  local minutes = vaultTimeoutMinutes()
  if minutes == nil then
    unlockDeadlineTick = nil
    return
  end
  unlockDeadlineTick = tickCount + minutes * 120
end

local function log(msg)
  noctalia.log(`bitwarden: {msg}`)
end

local function servePort()
  local port = cfg("serve_port")
  if type(port) == "number" and port >= 1024 and port <= 65535 then
    return math.floor(port)
  end
  return 8087
end

local function baseUrl()
  return `http://127.0.0.1:{servePort()}`
end

local function publishStatus()
  local key = `{status.vault}|{status.email}|{if status.serveUp then "1" else "0"}|{status.error}`
  if key == lastStatusKey then
    return
  end
  lastStatusKey = key
  noctalia.state.set("status", {
    vault = status.vault,
    email = status.email,
    serverUrl = status.serverUrl,
    serveUp = status.serveUp,
    bwAvailable = status.bwAvailable,
    error = status.error,
  })
end

local function setStatus(patch)
  for k, v in pairs(patch) do
    status[k] = v
  end
  publishStatus()
end

local function parseBwResponse(body)
  if type(body) ~= "string" or body == "" then
    return nil, "empty response"
  end
  local decoded = noctalia.json.decode(body)
  if type(decoded) ~= "table" then
    return nil, "invalid JSON"
  end
  if decoded.success == false then
    local msg = decoded.message
    if type(msg) ~= "string" or msg == "" then
      msg = "request failed"
    end
    return nil, msg
  end
  return decoded.data, nil
end

local function httpJson(method, path, body, onDone)
  local headers = { "Accept: application/json" }
  if body ~= nil then
    table.insert(headers, "Content-Type: application/json")
  end
  noctalia.http({
    method = method,
    url = baseUrl() .. path,
    headers = headers,
    body = body,
  }, function(res)
    if not res.ok then
      onDone(nil, "serve unreachable")
      return
    end
    -- 400 + {success:false} is locked/login, not transport failure
    local data, err = parseBwResponse(res.body)
    if err ~= nil then
      onDone(nil, err)
      return
    end
    onDone(data, nil)
  end)
end

local function applyStatusPayload(data)
  if type(data) ~= "table" then
    setStatus({ serveUp = true, vault = "locked", error = "" })
    return
  end
  -- status lives under data.template or data.data
  local payload = data
  if type(data.template) == "table" then
    payload = data.template
  elseif type(data.data) == "table" and type(data.data.status) == "string" then
    payload = data.data
  end
  local vault = payload.status
  if type(vault) ~= "string" or vault == "" then
    log("status payload missing vault status; treating as locked")
    vault = "locked"
  end
  setStatus({
    serveUp = true,
    vault = vault,
    email = if type(payload.userEmail) == "string" then payload.userEmail else "",
    serverUrl = if type(payload.serverUrl) == "string" then payload.serverUrl else "",
    error = "",
  })
  if vault == "unlocked" then
    if vaultTimeoutMode() == "on_restart" and not sessionUnlocked then
      pendingQuietLock = true
    elseif vaultTimeoutMinutes() ~= nil and unlockDeadlineTick == nil then
      touchUnlockActivity()
    end
  else
    unlockDeadlineTick = nil
  end
end

local function startServe()
  if not status.bwAvailable then
    return
  end
  if serveStartCooldown > 0 then
    return
  end
  serveStartCooldown = SERVE_START_COOLDOWN_TICKS
  local port = servePort()
  -- loopback only, detached (never --hostname all)
  local cmd = `bw serve --hostname 127.0.0.1 --port {port} >/dev/null 2>&1 &`
  log(`starting serve on 127.0.0.1:{port}`)
  weStartedServe = true
  noctalia.runAsync(cmd)
end

local function ensureServe(forceStart)
  local auto = cfg("auto_serve")
  if forceStart or (type(auto) == "boolean" and auto) or auto == nil then
    startServe()
  end
end

local function shellQuote(s)
  return "'" .. string.gsub(tostring(s), "'", "'\\''") .. "'"
end

local function applyCliStatusResult(result, serveErr)
  local vault = "offline"
  if type(result) == "table" and result.exitCode == 0 then
    local decoded = noctalia.json.decode(result.stdout or "")
    if type(decoded) == "table" and type(decoded.status) == "string" and decoded.status ~= "" then
      if decoded.status == "unauthenticated" then
        vault = "unauthenticated"
      elseif decoded.status == "locked" or decoded.status == "unlocked" then
        -- logged in, serve down: stay offline so launcher offers Start serve
        vault = "offline"
      else
        vault = decoded.status
      end
    end
  end
  setStatus({
    serveUp = false,
    vault = vault,
    email = "",
    serverUrl = "",
    error = serveErr or "",
  })
  if vault == "unauthenticated" then
    nextSlowPollTick = tickCount + SLOW_POLL_TICKS
  elseif vault == "offline" and cfg("auto_serve") ~= false then
    ensureServe(false)
  end
end

local function pollCliStatus(serveErr)
  noctalia.runAsync("bw status", function(result)
    statusInFlight = false
    applyCliStatusResult(result, serveErr)
  end, 10000)
end

local function pollStatus()
  if statusInFlight then
    return
  end
  if not status.bwAvailable then
    setStatus({ serveUp = false, vault = "offline", error = "bw not found" })
    return
  end

  -- logged out: slow CLI poll, skip HTTP warn spam
  if status.vault == "unauthenticated" then
    if tickCount < nextSlowPollTick then
      return
    end
    nextSlowPollTick = tickCount + SLOW_POLL_TICKS
    statusInFlight = true
    pollCliStatus("")
    return
  end

  -- serve down: back off HTTP
  if not status.serveUp and tickCount < nextSlowPollTick then
    return
  end

  statusInFlight = true
  httpJson("GET", "/status", nil, function(data, err)
    if err ~= nil then
      nextSlowPollTick = tickCount + SLOW_POLL_TICKS
      pollCliStatus(err)
      return
    end
    statusInFlight = false
    nextSlowPollTick = 0
    applyStatusPayload(data)
  end)
end

local function stopServe(onDone)
  local port = servePort()
  -- nix wraps bw as node bw.js: kill by port first
  local cmd = table.concat({
    `fuser -k {port}/tcp >/dev/null 2>&1 || true`,
    `pkill -f 'bw\\.js serve' >/dev/null 2>&1 || true`,
    `pkill -f 'bw serve' >/dev/null 2>&1 || true`,
  }, "; ")
  log(`stopping serve (port {port})`)
  noctalia.runAsync(cmd, function()
    if onDone ~= nil then
      onDone()
    end
  end, 5000)
end

local function restartServe(onDone)
  local port = servePort()
  serveStartCooldown = SERVE_START_COOLDOWN_TICKS
  log(`restarting serve on 127.0.0.1:{port}`)
  stopServe(function()
    noctalia.runAsync(
      `sleep 0.3; bw serve --hostname 127.0.0.1 --port {port} >/dev/null 2>&1 &`,
      function()
        weStartedServe = true
        if onDone ~= nil then
          onDone()
        end
      end,
      5000
    )
  end)
end

local function doLogin(clientId, clientSecret)
  if opInFlight then
    return
  end
  if type(clientId) ~= "string" or noctalia.string.trim(clientId) == "" then
    noctalia.notifyError(noctalia.tr("title"), noctalia.tr("errors.api-key-required"))
    return
  end
  if type(clientSecret) ~= "string" or noctalia.string.trim(clientSecret) == "" then
    noctalia.notifyError(noctalia.tr("title"), noctalia.tr("errors.api-key-required"))
    return
  end
  clientId = noctalia.string.trim(clientId)
  clientSecret = noctalia.string.trim(clientSecret)
  noctalia.state.set("command", { action = "ack" })

  local serverUrl = cfg("server_url")
  if type(serverUrl) == "string" then
    serverUrl = noctalia.string.trim(serverUrl)
  else
    serverUrl = ""
  end

  local loginCmd =
    `BW_CLIENTID={shellQuote(clientId)} BW_CLIENTSECRET={shellQuote(clientSecret)} bw login --apikey`
  if serverUrl ~= "" then
    loginCmd = `bw config server {shellQuote(serverUrl)} && {loginCmd}`
  end

  opInFlight = true
  noctalia.runAsync(loginCmd, function(result)
    if type(result) ~= "table" or result.timedOut or result.exitCode ~= 0 then
      opInFlight = false
      local err = noctalia.tr("errors.login-failed")
      if type(result) == "table" and type(result.stderr) == "string" and result.stderr ~= "" then
        err = result.stderr
      elseif type(result) == "table" and type(result.stdout) == "string" and result.stdout ~= "" then
        err = result.stdout
      end
      noctalia.notifyError(noctalia.tr("title"), err)
      pollStatus()
      return
    end
    -- restart serve to pick up session
    restartServe(function()
      opInFlight = false
      setStatus({ serveUp = true, vault = "locked", error = "" })
      noctalia.notify(noctalia.tr("title"), noctalia.tr("logged-in"))
      noctalia.togglePanel("noctalia/bitwarden:unlock")
      pollStatus()
    end)
  end, 60000)
end

local function scheduleClipboardClear(text)
  local secs = cfg("clear_clipboard_seconds")
  if type(secs) ~= "number" or secs <= 0 then
    pendingClear = nil
    return
  end
  pendingClear = {
    text = text,
    ticksLeft = math.max(1, math.floor(secs * 2)), -- 500ms ticks
  }
end

local function copySecret(value, notifyKey)
  if type(value) ~= "string" or value == "" then
    return false
  end
  noctalia.copyToClipboard(value, "text/plain;charset=utf-8")
  scheduleClipboardClear(value)
  if cfg("notify_on_copy") ~= false then
    noctalia.notify(noctalia.tr("title"), noctalia.tr(notifyKey or "copied"))
  end
  return true
end

local function parseSecretValue(data)
  if type(data) == "string" and data ~= "" then
    return data
  end
  if type(data) ~= "table" then
    return nil
  end
  if type(data.data) == "string" and data.data ~= "" then
    return data.data
  end
  if type(data.data) == "table" and type(data.data.data) == "string" and data.data.data ~= "" then
    return data.data.data
  end
  return nil
end

local function buildGenerateQuery(mode)
  if mode == "passphrase" then
    local words = cfg("gen_passphrase_words")
    if type(words) ~= "number" then
      words = 4
    end
    words = math.clamp(math.floor(words), 3, 20)
    local sep = cfg("gen_passphrase_separator")
    if type(sep) ~= "string" or sep == "" then
      sep = "-"
    end
    -- bw serve treats flag presence as on
    local parts = {
      "passphrase=true",
      `words={words}`,
      `separator={noctalia.string.urlEncode(sep)}`,
    }
    if cfg("gen_passphrase_capitalize") == true then
      table.insert(parts, "capitalize=true")
    end
    if cfg("gen_passphrase_include_number") == true then
      table.insert(parts, "includeNumber=true")
    end
    return table.concat(parts, "&")
  end

  local length = cfg("gen_length")
  if type(length) ~= "number" then
    length = 20
  end
  length = math.clamp(math.floor(length), 5, 128)
  local upper = cfg("gen_uppercase") ~= false
  local lower = cfg("gen_lowercase") ~= false
  local number = cfg("gen_number") ~= false
  local special = cfg("gen_special") == true
  if not upper and not lower and not number and not special then
    lower = true
  end
  local parts = { `length={length}` }
  if upper then
    table.insert(parts, "uppercase=true")
  end
  if lower then
    table.insert(parts, "lowercase=true")
  end
  if number then
    table.insert(parts, "number=true")
  end
  if special then
    table.insert(parts, "special=true")
  end
  return table.concat(parts, "&")
end

local function buildGenerateCmd(mode)
  if mode == "passphrase" then
    local words = cfg("gen_passphrase_words")
    if type(words) ~= "number" then
      words = 4
    end
    words = math.clamp(math.floor(words), 3, 20)
    local sep = cfg("gen_passphrase_separator")
    if type(sep) ~= "string" or sep == "" then
      sep = "-"
    end
    local cmd = `bw generate --passphrase --words {words} --separator {shellQuote(sep)}`
    if cfg("gen_passphrase_capitalize") == true then
      cmd ..= " --capitalize"
    end
    if cfg("gen_passphrase_include_number") == true then
      cmd ..= " --includeNumber"
    end
    return cmd
  end

  local length = cfg("gen_length")
  if type(length) ~= "number" then
    length = 20
  end
  length = math.clamp(math.floor(length), 5, 128)
  local upper = cfg("gen_uppercase") ~= false
  local lower = cfg("gen_lowercase") ~= false
  local number = cfg("gen_number") ~= false
  local special = cfg("gen_special") == true
  if not upper and not lower and not number and not special then
    lower = true
  end
  local cmd = `bw generate --length {length}`
  if upper then
    cmd ..= " --uppercase"
  end
  if lower then
    cmd ..= " --lowercase"
  end
  if number then
    cmd ..= " --number"
  end
  if special then
    cmd ..= " --special"
  end
  return cmd
end

local generateInFlight = false

local function doGenerate(mode)
  if generateInFlight then
    return
  end
  if not status.bwAvailable and not noctalia.commandExists("bw") then
    noctalia.notifyError(noctalia.tr("title"), noctalia.tr("errors.generate-failed"))
    return
  end
  local passphrase = mode == "passphrase"
  noctalia.state.set("command", { action = "ack" })
  generateInFlight = true

  local function finish(value, err)
    generateInFlight = false
    if err ~= nil or type(value) ~= "string" or value == "" then
      noctalia.notifyError(noctalia.tr("title"), err or noctalia.tr("errors.generate-failed"))
      return
    end
    copySecret(value, if passphrase then "generated-passphrase" else "generated")
  end

  local function viaCli()
    noctalia.runAsync(buildGenerateCmd(if passphrase then "passphrase" else "password"), function(result)
      if type(result) ~= "table" or result.timedOut or result.exitCode ~= 0 then
        local err = noctalia.tr("errors.generate-failed")
        if type(result) == "table" and type(result.stderr) == "string" and result.stderr ~= "" then
          err = result.stderr
        end
        finish(nil, err)
        return
      end
      finish(noctalia.string.trim(result.stdout or ""), nil)
    end, 15000)
  end

  -- prefer serve /generate (no node cold start), CLI fallback
  local function viaHttp()
    httpJson("GET", `/generate?{buildGenerateQuery(if passphrase then "passphrase" else "password")}`, nil, function(data, err)
      if err ~= nil then
        viaCli()
        return
      end
      local value = parseSecretValue(data)
      if value == nil then
        viaCli()
        return
      end
      finish(value, nil)
    end)
  end

  if not status.serveUp then
    ensureServe(true)
  end
  viaHttp()
end

local function extractField(item, field)
  if type(item) ~= "table" then
    return nil
  end
  local login = item.login
  if field == "password" then
    if type(login) == "table" and type(login.password) == "string" then
      return login.password
    end
    if type(item.notes) == "string" and item.notes ~= "" then
      return item.notes
    end
    return nil
  end
  if field == "username" then
    if type(login) == "table" and type(login.username) == "string" then
      return login.username
    end
    return nil
  end
  if field == "totp" then
    if type(login) == "table" and type(login.totp) == "string" then
      return login.totp
    end
    return nil
  end
  if field == "uri" then
    if type(login) == "table" and type(login.uris) == "table" then
      for _, u in login.uris do
        if type(u) == "table" and type(u.uri) == "string" and u.uri ~= "" then
          return u.uri
        end
      end
    end
    return nil
  end
  return nil
end

local function copyItemField(itemId)
  if type(itemId) ~= "string" or itemId == "" then
    return
  end
  if status.vault ~= "unlocked" then
    noctalia.notifyError(noctalia.tr("title"), noctalia.tr("errors.vault-locked"))
    return
  end
  local field = cfg("copy_field")
  if type(field) ~= "string" or field == "" then
    field = "password"
  end
  -- try /object/<field>, else full item
  local path = `/object/{field}/{noctalia.string.urlEncode(itemId)}`
  httpJson("GET", path, nil, function(data, err)
    local value = if err == nil then parseSecretValue(data) else nil
    if value ~= nil then
      touchUnlockActivity()
      copySecret(value, "copied")
      return
    end
    httpJson("GET", `/object/item/{noctalia.string.urlEncode(itemId)}`, nil, function(itemData, itemErr)
      if itemErr ~= nil then
        noctalia.notifyError(noctalia.tr("title"), itemErr)
        return
      end
      local item = itemData
      if type(itemData) == "table" and type(itemData.data) == "table" and itemData.id == nil then
        item = itemData.data
      end
      value = extractField(item, field)
      if value == nil or value == "" then
        noctalia.notifyError(noctalia.tr("title"), noctalia.tr("errors.field-empty"))
        return
      end
      touchUnlockActivity()
      copySecret(value, "copied")
    end)
  end)
end

local function curlPost(path, onDone)
  local port = servePort()
  local cmd = `curl -sS -m 15 -X POST http://127.0.0.1:{port}{path} -H 'Accept: application/json'`
  noctalia.runAsync(cmd, function(result)
    if type(result) ~= "table" then
      onDone(false, "no result")
      return
    end
    if result.timedOut then
      onDone(false, "timed out")
      return
    end
    if result.exitCode ~= 0 then
      onDone(false, if result.stderr ~= "" then result.stderr else "curl failed")
      return
    end
    local data, err = parseBwResponse(result.stdout)
    if err ~= nil then
      onDone(false, err)
      return
    end
    onDone(true, nil)
  end, 20000)
end

local function doUnlock(password)
  if opInFlight then
    return
  end
  if type(password) ~= "string" or password == "" then
    noctalia.notifyError(noctalia.tr("title"), noctalia.tr("errors.password-required"))
    return
  end
  local body = noctalia.json.encode({ password = password })
  noctalia.state.set("command", { action = "ack" })
  if body == nil then
    noctalia.notifyError(noctalia.tr("title"), noctalia.tr("errors.encode-failed"))
    return
  end
  opInFlight = true
  httpJson("POST", "/unlock", body, function(_data, err)
    opInFlight = false
    if err ~= nil then
      noctalia.notifyError(noctalia.tr("title"), err)
      setStatus({ error = err })
      return
    end
    sessionUnlocked = true
    pendingQuietLock = false
    touchUnlockActivity()
    setStatus({ serveUp = true, vault = "unlocked", error = "" })
    noctalia.notify(noctalia.tr("title"), noctalia.tr("unlocked"))
    pollStatus()
  end)
end

local function doLock(quiet)
  if opInFlight then
    return
  end
  -- curl not noctalia.http: POST /lock froze the shell
  noctalia.state.set("command", { action = "ack" })
  opInFlight = true
  curlPost("/lock", function(ok, err)
    opInFlight = false
    clearUnlockTimer()
    if not ok then
      if not quiet then
        noctalia.notifyError(noctalia.tr("title"), err or noctalia.tr("errors.lock-failed"))
      end
      pollStatus()
      return
    end
    setStatus({ serveUp = true, vault = "locked", error = "" })
    if not quiet then
      noctalia.notify(noctalia.tr("title"), noctalia.tr("locked"))
    end
  end)
end

local function doLogout()
  if opInFlight then
    return
  end
  noctalia.state.set("command", { action = "ack" })
  opInFlight = true
  clearUnlockTimer()
  -- lock, kill serve (holds session), then bw logout
  curlPost("/lock", function()
    stopServe(function()
      noctalia.runAsync("bw logout", function(result)
        opInFlight = false
        if type(result) == "table" and result.exitCode ~= 0 and not result.timedOut then
          local err = noctalia.tr("errors.logout-failed")
          if type(result.stderr) == "string" and result.stderr ~= "" then
            err = result.stderr
          elseif type(result.stdout) == "string" and result.stdout ~= "" then
            err = result.stdout
          end
          log(`bw logout: {err}`)
        end
        setStatus({
          serveUp = false,
          vault = "unauthenticated",
          email = "",
          serverUrl = "",
          error = "",
        })
        nextSlowPollTick = tickCount + SLOW_POLL_TICKS
        noctalia.notify(noctalia.tr("title"), noctalia.tr("logged-out"))
      end, 20000)
    end)
  end)
end

local function doSync()
  if opInFlight then
    return
  end
  noctalia.state.set("command", { action = "ack" })
  opInFlight = true
  curlPost("/sync", function(ok, err)
    opInFlight = false
    if not ok then
      noctalia.notifyError(noctalia.tr("title"), err or noctalia.tr("errors.sync-failed"))
      return
    end
    if status.vault == "unlocked" then
      touchUnlockActivity()
    end
    noctalia.notify(noctalia.tr("title"), noctalia.tr("synced"))
    pollStatus()
  end)
end

function onIpc(event, payload)
  if event == "unlock" then
    local password = payload
    if type(payload) == "table" then
      password = payload.password
    end
    doUnlock(password)
  elseif event == "lock" then
    doLock()
  elseif event == "logout" then
    doLogout()
  elseif event == "sync" then
    doSync()
  elseif event == "ensure_serve" or event == "serve" then
    ensureServe(true)
    pollStatus()
  elseif event == "status" then
    pollStatus()
  elseif event == "copy" then
    local id = payload
    if type(payload) == "table" then
      id = payload.id
    end
    copyItemField(id)
  elseif event == "generate" then
    local mode = "password"
    if type(payload) == "table" then
      if type(payload.mode) == "string" and payload.mode ~= "" then
        mode = payload.mode
      end
    elseif type(payload) == "string" and payload ~= "" then
      local trimmed = noctalia.string.trim(payload)
      if trimmed == "passphrase" or trimmed == "password" then
        mode = trimmed
      else
        local decoded = noctalia.json.decode(trimmed)
        if type(decoded) == "table" and type(decoded.mode) == "string" and decoded.mode ~= "" then
          mode = decoded.mode
        end
      end
    end
    doGenerate(mode)
  elseif event == "login" then
    local clientId = nil
    local clientSecret = nil
    if type(payload) == "table" then
      clientId = payload.clientId
      clientSecret = payload.clientSecret
    end
    doLogin(clientId, clientSecret)
  elseif event == "open_panel" then
    noctalia.togglePanel("noctalia/bitwarden:unlock")
  elseif event == "open_login" then
    noctalia.togglePanel("noctalia/bitwarden:login")
  elseif event == "ack" then
    -- noop scrub
  else
    log(`unknown command '{event}'`)
  end
end

noctalia.state.watch("command", function(cmd)
  local action = if type(cmd) == "table" and cmd.action ~= nil then cmd.action else cmd
  if type(action) == "string" then
    onIpc(action, if type(cmd) == "table" then cmd else nil)
  end
end)

function update()
  tickCount += 1
  if serveStartCooldown > 0 then
    serveStartCooldown -= 1
  end

  if pendingClear ~= nil then
    pendingClear.ticksLeft -= 1
    if pendingClear.ticksLeft <= 0 then
      local current = noctalia.clipboardText()
      if current == pendingClear.text then
        noctalia.copyToClipboard("", "text/plain;charset=utf-8")
      end
      pendingClear = nil
    end
  end

  if pendingQuietLock and not opInFlight then
    pendingQuietLock = false
    doLock(true)
  elseif
    status.vault == "unlocked"
    and unlockDeadlineTick ~= nil
    and tickCount >= unlockDeadlineTick
    and not opInFlight
  then
    unlockDeadlineTick = nil
    log("vault timeout: locking")
    doLock(false)
  end

  if tickCount == 1 then
    status.bwAvailable = noctalia.commandExists("bw")
    if not status.bwAvailable then
      setStatus({ vault = "offline", serveUp = false, error = "bw not found" })
      log("bw not found on PATH")
      return
    end
    publishStatus()
    pollStatus()
  elseif tickCount % STATUS_TICKS == 0 then
    pollStatus()
  end
end

function onExit(_signal)
  -- detached lock only for on_restart; awaiting HTTP on teardown can stall the host
  if vaultTimeoutMode() == "on_restart" and status.vault == "unlocked" then
    local port = servePort()
    noctalia.runAsync(`curl -sS -m 5 -X POST http://127.0.0.1:{port}/lock >/dev/null 2>&1 &`)
  end
end

publishStatus()
