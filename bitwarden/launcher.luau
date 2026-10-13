--!nonstrict
-- Bitwarden launcher /bw

local RESULT_LIMIT = 100
-- Subtracted from action scores unless the text names whole words of the
-- title. fuzzyScore (fzy) docks ~0.005 per trailing character, so a short
-- title like "Log Out" would otherwise beat every longer item starting with
-- "lo". 0.2 outweighs ~40 characters of length difference but not a
-- word-start bonus (0.6+), so an action still wins when it matches clearly
-- better ("unl" -> Unlock Vault), and "sync" picks Sync Vault over a
-- "Syncthing" item.
local ACTION_HANDICAP = 0.2
local vaultStatus = "offline"
local lastQuery = ""
-- Full item list from bw serve, fuzzy-matched locally. Refetched when the
-- query is empty (each fresh /bw), dropped on lock and when a sync completes.
local itemCache = nil
-- At most one list request runs at a time. Bumping fetchGen discards the
-- response of the one in flight.
local fetching = false
local fetchGen = 0

local function dropFetch()
  fetching = false
  fetchGen += 1
end

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
  dropFetch()
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

-- A sync from anywhere (launcher, panel, IPC) makes the cached list stale.
-- A list request started before the sync finished may be stale too.
noctalia.state.watch("synced", function()
  itemCache = nil
  dropFetch()
end)

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

-- True when `text` is one or more whole words of `title` ("sync", "log out").
local function namesWholeWords(text, title)
  local padded = " " .. string.lower(title) .. " "
  return string.find(padded, " " .. string.lower(text) .. " ", 1, true) ~= nil
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
  local function add(row, score, isItem)
    row.score = score
    table.insert(scored, { row = row, score = score, isItem = isItem, order = #scored })
  end
  local actions = if text ~= "" and hideActionsWhenSearching() then {} else actionRows()
  for _, row in actions do
    local score = if text == "" then 0 else bestScore(text, row.title)
    if score ~= nil then
      if text ~= "" and not namesWholeWords(text, row.title) then
        score -= ACTION_HANDICAP
      end
      add(row, score, false)
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
          }, score, true)
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
  -- RESULT_LIMIT caps vault items only; matching actions always show
  local rows = {}
  local itemCount = 0
  for _, entry in scored do
    if entry.isItem then
      itemCount += 1
    end
    if not entry.isItem or itemCount <= RESULT_LIMIT then
      table.insert(rows, entry.row)
    end
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

-- Results for whatever the user has typed by the time the list arrives.
local function publishItems()
  local rows = rankRows(noctalia.string.trim(lastQuery), itemCache)
  if #rows == 0 then
    table.insert(rows, hint("", noctalia.tr("launcher.no-matches"), noctalia.tr("launcher.try-different"), "search-off"))
  end
  launcher.setResults(lastQuery, rows)
end

local function fetchItems()
  fetching = true
  local gen = fetchGen
  noctalia.http({
    method = "GET",
    url = `http://127.0.0.1:{servePort()}/list/object/items`,
    headers = { "Accept: application/json" },
  }, function(res)
    if gen ~= fetchGen then
      return
    end
    fetching = false
    -- errors are shown against the latest query too
    local query = lastQuery
    local text = noctalia.string.trim(query)
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
    publishItems()
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
    publishItems()
    return
  end

  -- actions (and any cached items) right away; the list fills in when it lands
  launcher.setResults(query, rankRows(text, itemCache))
  -- a request already in flight answers this query when it returns
  if not fetching then
    fetchItems()
  end
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
    -- the cache is dropped when the sync completes, via the "synced" state
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
