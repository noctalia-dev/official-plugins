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
    -- drop the field picker's shared state too: it can carry decrypted
    -- values and must not survive a lock or logout
    noctalia.state.set("fields_panel", nil)
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

-- Fetch one item and decide how to copy it: entries without custom fields
-- keep the old single-keypress flow; entries with custom fields open the
-- field picker panel (mirrors the entry detail in the Bitwarden apps).
local function fetchItemFields(itemId)
  local url = `http://127.0.0.1:{servePort()}/object/item/{noctalia.string.urlEncode(itemId)}`
  noctalia.http({
    method = "GET",
    url = url,
    headers = { "Accept: application/json" },
  }, function(res)
    if vaultStatus ~= "unlocked" then
      -- late response after a lock/logout: never open the picker on it
      return
    end
    if not res.ok then
      noctalia.state.set("command", { action = "copy", id = itemId })
      return
    end
    local decoded = noctalia.json.decode(res.body)
    local item = type(decoded) == "table" and decoded.data or nil
    if type(item) ~= "table" then
      noctalia.state.set("command", { action = "copy", id = itemId })
      return
    end

    local fields = {}
    -- Copy shortcuts: digits first, then letters. Both the labels here and
    -- the panel's capture_keys/onKey mapping in fields.luau use this order.
    local fieldChords = {
      "1", "2", "3", "4", "5", "6", "7", "8", "9", "0",
      "a", "b", "c", "d", "e", "f", "g", "h", "i", "j",
      "k", "l", "m", "n", "o", "p", "q", "r", "s", "t",
      "u", "v", "w", "x", "y", "z",
    }
    local fieldIndex = 0
    local function addField(field)
      fieldIndex += 1
      local chord = fieldChords[fieldIndex]
      if chord ~= nil then
        field.label = "[" .. chord .. "] " .. field.label
      end
      table.insert(fields, field)
    end
    local login = item.login
    if type(login) == "table" then
      if type(login.username) == "string" and login.username ~= "" then
        addField({ key = "username", label = noctalia.tr("launcher.field-username"), masked = false })
      end
      if type(login.password) == "string" and login.password ~= "" then
        addField({
          key = "password",
          label = noctalia.tr("launcher.field-password"),
          masked = true,
          -- Masked values never leave the launcher: the panel only carries
          -- keys/labels, and the service resolves the value by key on copy.
        })
      end
      if type(login.totp) == "string" and login.totp ~= "" then
        addField({ key = "totp", label = noctalia.tr("launcher.field-totp"), masked = false })
      end
      if type(login.uris) == "table" then
        local shown = 0
        for i, u in login.uris do
          if type(u) == "table" and type(u.uri) == "string" and u.uri ~= "" then
            shown += 1
            addField({
              -- key carries the original array index so each row always
              -- copies the URI it displays (skipped/empty entries keep their
              -- position); display numbering counts shown rows separately
              key = "uri:" .. tostring(i),
              label = if shown == 1 then noctalia.tr("launcher.field-uri") else noctalia.tr("launcher.field-uri") .. " " .. tostring(shown),
              masked = false,
              value = u.uri,
            })
          end
        end
      end
    end
    if type(item.notes) == "string" and item.notes ~= "" then
      addField({
        key = "notes",
        label = noctalia.tr("launcher.field-notes"),
        masked = false,
        value = item.notes,
        -- multiline notes flattened for the one-line panel display; the copy
        -- keeps the full text
        display = item.notes:gsub("\r?\n", " · "),
      })
    end
    if type(item.fields) == "table" then
      for i, f in item.fields do
        if type(f) == "table" and type(f.name) == "string" and f.name ~= "" and type(f.value) == "string" and f.value ~= "" then
          local hidden = f.type == 1 or f.type == "hidden"
          addField({
            -- key by array index: duplicate names must not shadow each other
            -- (the service resolves the index strictly by position)
            key = "custom:" .. tostring(i),
            label = f.name,
            -- bw serve types custom fields as ints (0 = text, 1 = hidden);
            -- accept the string form too in case the API ever grows one.
            masked = hidden,
            -- Hidden custom fields are resolved by key on copy, same as the
            -- login password; text fields are not secret and preview inline.
            value = if not hidden then f.value else nil,
          })
        end
      end
    end

    local hasCustom = type(item.fields) == "table" and #item.fields > 0
    if not hasCustom then
      noctalia.state.set("command", { action = "copy", id = itemId })
      return
    end

    noctalia.state.set("fields_panel", {
      id = itemId,
      name = if type(item.name) == "string" then item.name else "",
      fields = fields,
    })
    noctalia.togglePanel("noctalia/bitwarden:fields")
  end)
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
      fetchItemFields(itemId)
    end
  end
end
