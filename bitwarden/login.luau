--!nonstrict
-- API-key login panel

local clientId = ""
local clientSecret = ""
local clientIdKey = 0
local clientSecretKey = 0
local busy = false

function render()
  panel.render(ui.column({ gap = 10, align = "stretch" }, {
    ui.label({ text = noctalia.tr("panel.login-blurb"), color = "on_surface_variant" }),
    ui.label({ text = noctalia.tr("panel.client-id-label"), fontWeight = "medium" }),
    ui.input({
      key = "cid_" .. tostring(clientIdKey),
      value = "",
      placeholder = noctalia.tr("panel.client-id-placeholder"),
      focus = true,
      onChange = "onClientIdChange",
    }),
    ui.label({ text = noctalia.tr("panel.client-secret-label"), fontWeight = "medium" }),
    ui.input({
      key = "csec_" .. tostring(clientSecretKey),
      value = "",
      placeholder = noctalia.tr("panel.client-secret-placeholder"),
      password = true,
      onChange = "onClientSecretChange",
      onSubmit = "onLogin",
    }),
    ui.row({ gap = 8, align = "center" }, {
      ui.button({
        text = noctalia.tr("panel.login"),
        variant = "primary",
        enabled = not busy,
        onClick = "onLogin",
      }),
      ui.button({
        text = noctalia.tr("panel.close"),
        variant = "ghost",
        onClick = "onClosePanel",
      }),
    }),
  }))
end

function onClientIdChange(value)
  clientId = if type(value) == "string" then value else ""
end

function onClientSecretChange(value)
  clientSecret = if type(value) == "string" then value else ""
end

function onLogin()
  if busy then
    return
  end
  local id = noctalia.string.trim(clientId)
  local secret = noctalia.string.trim(clientSecret)
  if id == "" or secret == "" then
    noctalia.notifyError(noctalia.tr("title"), noctalia.tr("errors.api-key-required"))
    return
  end
  busy = true
  clientId = ""
  clientSecret = ""
  clientIdKey += 1
  clientSecretKey += 1
  panel.close()
  noctalia.state.set("command", { action = "login", clientId = id, clientSecret = secret })
end

function onClosePanel()
  panel.close()
end

function onOpen(_context)
  clientId = ""
  clientSecret = ""
  clientIdKey += 1
  clientSecretKey += 1
  busy = false
  render()
end
