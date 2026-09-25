--!nonstrict
-- Bitwarden launcher /bw

local RESULT_LIMIT = 100
local pending = {}
local vaultStatus = "offline"
local lastQuery = ""

local function hint(id, title, subtitle, glyph)
  return { id = id or "", title = title, subtitle = subtitle, glyph = glyph or "lock" }
end

local function actionRows()
  local rows = {
    hint("action:generate", noctalia.tr("launcher.generate"), noctalia.tr("launcher.generate-hint"), "password"),
    hint(
      "action:generate-passphrase",
      noctalia.tr("launcher.generate-passphrase"),
      noctalia.tr("launcher.generate-passphrase-hint"),
      "align-justified"
    ),
  }
  if vaultStatus == "unlocked" then
    table.insert(rows, hint("action:lock", noctalia.tr("launcher.lock"), noctalia.tr("launcher.lock-hint"), "lock"))
    table.insert(rows, hint("action:logout", noctalia.tr("launcher.logout"), noctalia.tr("launcher.logout-hint"), "logout"))
    table.insert(rows, hint("action:sync", noctalia.tr("launcher.sync"), noctalia.tr("launcher.sync-hint"), "refresh"))
  elseif vaultStatus == "unauthenticated" then
    table.insert(
      rows,
      hint("action:login", noctalia.tr("launcher.login"), noctalia.tr("launcher.login-hint"), "user-plus")
    )
  elseif vaultStatus == "offline" then
    table.insert(
      rows,
      hint("action:serve", noctalia.tr("launcher.start-serve"), noctalia.tr("launcher.serve-down-hint"), "plug-connected")
    )
    table.insert(
      rows,
      hint("action:unlock", noctalia.tr("launcher.unlock"), noctalia.tr("launcher.unlock-hint"), "lock-open")
    )
    table.insert(
      rows,
      hint("action:logout", noctalia.tr("launcher.logout"), noctalia.tr("launcher.logout-hint"), "logout")
    )
  else
    table.insert(
      rows,
      hint("action:unlock", noctalia.tr("launcher.unlock"), noctalia.tr("launcher.unlock-hint"), "lock-open")
    )
    table.insert(
      rows,
      hint("action:logout", noctalia.tr("launcher.logout"), noctalia.tr("launcher.logout-hint"), "logout")
    )
  end
  return rows
end

local function publishActions()
  -- drop in-flight search so late responses can't repaint
  pending = {}
  launcher.setResults(lastQuery, actionRows())
end

local function applyStatus(st)
  local nextStatus = vaultStatus
  if type(st) == "table" and type(st.vault) == "string" then
    nextStatus = st.vault
  end
  local wasUnlocked = vaultStatus == "unlocked"
  vaultStatus = nextStatus
  if wasUnlocked and vaultStatus ~= "unlocked" then
    publishActions()
  end
end

applyStatus(noctalia.state.get("status"))
noctalia.state.watch("status", applyStatus)

local function itemSubtitle(item)
  local parts = {}
  local login = item.login
  if type(login) == "table" and type(login.username) == "string" and login.username ~= "" then
    table.insert(parts, login.username)
  end
  if type(login) == "table" and type(login.uris) == "table" then
    for _, u in login.uris do
      if type(u) == "table" and type(u.uri) == "string" and u.uri ~= "" then
        table.insert(parts, u.uri)
        break
      end
    end
  end
  if #parts == 0 then
    return noctalia.tr("launcher.press-enter")
  end
  return table.concat(parts, " · ")
end

local function itemGlyph(item)
  local t = item.type
  if t == 1 then
    return "key"
  elseif t == 2 then
    return "notes"
  elseif t == 3 then
    return "credit-card"
  elseif t == 4 then
    return "id"
  end
  return "lock"
end

local function itemRows(list)
  local rows = {}
  if type(list) ~= "table" then
    return rows
  end
  for _, item in list do
    if #rows >= RESULT_LIMIT then
      break
    end
    if type(item) == "table" and type(item.id) == "string" and type(item.name) == "string" then
      table.insert(rows, {
        id = "item:" .. item.id,
        title = item.name,
        subtitle = itemSubtitle(item),
        glyph = itemGlyph(item),
      })
    end
  end
  return rows
end

local function hideActionsWhenSearching()
  return noctalia.getConfig("hide_actions_when_searching") == true
end

local function servePort()
  local port = noctalia.getConfig("serve_port")
  if type(port) == "number" and port >= 1024 and port <= 65535 then
    return math.floor(port)
  end
  return 8087
end

local function unwrapList(decoded)
  if type(decoded) ~= "table" then
    return nil, noctalia.tr("errors.invalid-response")
  end
  if decoded.success == false then
    local msg = decoded.message
    if type(msg) ~= "string" or msg == "" then
      msg = noctalia.tr("errors.request-failed")
    end
    return nil, msg
  end
  local data = decoded.data
  if type(data) == "table" and type(data.data) == "table" then
    return data.data, nil
  end
  if type(data) == "table" then
    return data, nil
  end
  return {}, nil
end

local function searchItems(query, search)
  local url = `http://127.0.0.1:{servePort()}/list/object/items`
  if search ~= "" then
    url = url .. "?search=" .. noctalia.string.urlEncode(search)
  end
  noctalia.http({
    method = "GET",
    url = url,
    headers = { "Accept: application/json" },
  }, function(res)
    if pending[query] ~= true then
      return
    end
    pending[query] = nil
    if vaultStatus ~= "unlocked" then
      launcher.setResults(query, actionRows())
      return
    end
    local rows = (search == "" or not hideActionsWhenSearching()) and actionRows() or {}
    if not res.ok then
      noctalia.state.set("command", { action = "ensure_serve" })
      table.insert(
        rows,
        hint("", noctalia.tr("launcher.serve-down"), noctalia.tr("launcher.serve-down-hint"), "plug-connected")
      )
      launcher.setResults(query, rows)
      return
    end
    local items, err = unwrapList(noctalia.json.decode(res.body))
    if err ~= nil then
      if string.find(string.lower(err), "locked", 1, true) then
        table.insert(rows, hint("action:unlock", noctalia.tr("launcher.vault-locked"), err, "lock"))
      else
        table.insert(rows, hint("", err, "", "alert-triangle"))
      end
      launcher.setResults(query, rows)
      return
    end
    local found = itemRows(items)
    if #found == 0 and search ~= "" then
      table.insert(rows, hint("", noctalia.tr("launcher.no-matches"), noctalia.tr("launcher.try-different"), "search-off"))
    end
    for _, row in found do
      table.insert(rows, row)
    end
    launcher.setResults(query, rows)
  end)
end

function onQuery(query)
  lastQuery = query
  local text = noctalia.string.trim(query)
  local rows = actionRows()

  if vaultStatus == "unauthenticated" then
    launcher.setResults(query, rows)
    return
  end

  if vaultStatus ~= "unlocked" then
    if text ~= "" then
      table.insert(rows, hint("action:unlock", noctalia.tr("launcher.vault-locked"), noctalia.tr("launcher.unlock-hint"), "lock"))
    end
    launcher.setResults(query, rows)
    return
  end

  pending[query] = true
  launcher.setResults(query, (text == "" or not hideActionsWhenSearching()) and rows or {})
  searchItems(query, text)
end

function onActivate(id)
  if type(id) ~= "string" or id == "" then
    return
  end
  if id == "action:unlock" then
    noctalia.state.set("command", { action = "ensure_serve" })
    noctalia.togglePanel("noctalia/bitwarden:unlock")
    return
  end
  if id == "action:login" then
    noctalia.togglePanel("noctalia/bitwarden:login")
    return
  end
  if id == "action:lock" then
    noctalia.state.set("command", { action = "lock" })
    return
  end
  if id == "action:logout" then
    noctalia.state.set("command", { action = "logout" })
    return
  end
  if id == "action:sync" then
    noctalia.state.set("command", { action = "sync" })
    return
  end
  if id == "action:serve" then
    noctalia.state.set("command", { action = "ensure_serve" })
    return
  end
  if id == "action:generate" then
    noctalia.state.set("command", { action = "generate", mode = "password" })
    return
  end
  if id == "action:generate-passphrase" then
    noctalia.state.set("command", { action = "generate", mode = "passphrase" })
    return
  end
  if id:sub(1, 5) == "item:" then
    local itemId = id:sub(6)
    if itemId ~= "" then
      noctalia.state.set("command", { action = "copy", id = itemId })
    end
  end
end
