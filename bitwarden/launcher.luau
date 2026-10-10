--!nonstrict
-- Bitwarden launcher /bw

local RESULT_LIMIT = 100
local pending = {}
local vaultStatus = "offline"
local lastQuery = ""
-- Full item list from bw serve, fuzzy-matched locally. Refetched when the
-- query is empty (each fresh /bw), after a sync, and dropped on lock.
local itemCache = nil

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
    itemCache = nil
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

local function hideActionsWhenSearching()
  return noctalia.getConfig("hide_actions_when_searching") == true
end

-- Best fuzzy score of `text` over the given fields; nil when none match.
local function bestScore(text, ...)
  local best = nil
  for _, field in { ... } do
    if type(field) == "string" and field ~= "" then
      local score = noctalia.fuzzyScore(text, field)
      if score ~= nil and (best == nil or score > best) then
        best = score
      end
    end
  end
  return best
end

local function firstUri(item)
  local login = item.login
  if type(login) == "table" and type(login.uris) == "table" then
    for _, u in login.uris do
      if type(u) == "table" and type(u.uri) == "string" and u.uri ~= "" then
        return u.uri
      end
    end
  end
  return nil
end

-- Actions and items scored against `text` and sorted best first. An empty
-- text keeps the plain order: actions, then items. With
-- hide_actions_when_searching, a non-empty text ranks items only.
local function rankRows(text, items)
  local scored = {}
  local function add(row, score)
    row.score = score
    table.insert(scored, { row = row, score = score, order = #scored })
  end
  local actions = if text ~= "" and hideActionsWhenSearching() then {} else actionRows()
  for _, row in actions do
    local score = if text == "" then 0 else bestScore(text, row.title)
    if score ~= nil then
      add(row, score)
    end
  end
  if type(items) == "table" then
    for _, item in items do
      if type(item) == "table" and type(item.id) == "string" and type(item.name) == "string" then
        local login = if type(item.login) == "table" then item.login else {}
        local score = if text == "" then 0 else bestScore(text, item.name, login.username, firstUri(item))
        if score ~= nil then
          add({
            id = "item:" .. item.id,
            title = item.name,
            subtitle = itemSubtitle(item),
            glyph = itemGlyph(item),
          }, score)
        end
      end
    end
  end
  table.sort(scored, function(a, b)
    if a.score ~= b.score then
      return a.score > b.score
    end
    return a.order < b.order
  end)
  local rows = {}
  for _, entry in scored do
    if #rows >= RESULT_LIMIT then
      break
    end
    table.insert(rows, entry.row)
  end
  return rows
end

-- Keep only what ranking and the subtitle read. bw serve returns items fully
-- decrypted (passwords, TOTP seeds, notes, cards); the cache must not hold
-- those for the whole session. Copy fetches the secret by id when needed.
local function slimItems(list)
  local out = {}
  if type(list) ~= "table" then
    return out
  end
  for _, item in list do
    if type(item) == "table" and type(item.id) == "string" and type(item.name) == "string" then
      local login = nil
      if type(item.login) == "table" then
        local uri = firstUri(item)
        login = {
          username = if type(item.login.username) == "string" then item.login.username else nil,
          uris = if uri ~= nil then { { uri = uri } } else nil,
        }
      end
      table.insert(out, { id = item.id, name = item.name, type = item.type, login = login })
    end
  end
  return out
end

local function fetchItems(query, text)
  noctalia.http({
    method = "GET",
    url = `http://127.0.0.1:{servePort()}/list/object/items`,
    headers = { "Accept: application/json" },
  }, function(res)
    if pending[query] ~= true then
      return
    end
    pending[query] = nil
    if vaultStatus ~= "unlocked" then
      launcher.setResults(query, rankRows(text, nil))
      return
    end
    if not res.ok then
      noctalia.state.set("command", { action = "ensure_serve" })
      local rows = rankRows(text, nil)
      table.insert(
        rows,
        hint("", noctalia.tr("launcher.serve-down"), noctalia.tr("launcher.serve-down-hint"), "plug-connected")
      )
      launcher.setResults(query, rows)
      return
    end
    local items, err = unwrapList(noctalia.json.decode(res.body))
    if err ~= nil then
      local rows = rankRows(text, nil)
      if string.find(string.lower(err), "locked", 1, true) then
        table.insert(rows, hint("action:unlock", noctalia.tr("launcher.vault-locked"), err, "lock"))
      else
        table.insert(rows, hint("", err, "", "alert-triangle"))
      end
      launcher.setResults(query, rows)
      return
    end
    itemCache = slimItems(items)
    -- the user may have typed on while the list was loading
    if query == lastQuery then
      local rows = rankRows(text, itemCache)
      if #rows == 0 then
        table.insert(rows, hint("", noctalia.tr("launcher.no-matches"), noctalia.tr("launcher.try-different"), "search-off"))
      end
      launcher.setResults(query, rows)
    end
  end)
end

function onQuery(query)
  lastQuery = query
  local text = noctalia.string.trim(query)

  if vaultStatus ~= "unlocked" then
    local rows = rankRows(text, nil)
    if #rows == 0 and vaultStatus ~= "unauthenticated" then
      table.insert(rows, hint("action:unlock", noctalia.tr("launcher.vault-locked"), noctalia.tr("launcher.unlock-hint"), "lock"))
    end
    launcher.setResults(query, rows)
    return
  end

  if text ~= "" and itemCache ~= nil then
    local rows = rankRows(text, itemCache)
    if #rows == 0 then
      table.insert(rows, hint("", noctalia.tr("launcher.no-matches"), noctalia.tr("launcher.try-different"), "search-off"))
    end
    launcher.setResults(query, rows)
    return
  end

  pending[query] = true
  launcher.setResults(query, rankRows(text, itemCache))
  fetchItems(query, text)
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
    itemCache = nil
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
