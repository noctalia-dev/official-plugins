--!nonstrict
-- unlock password panel

local password = ""
local passwordKey = 0
local busy = false

function render()
  panel.render(ui.column({ gap = 10, align = "stretch" }, {
    ui.label({ text = noctalia.tr("panel.password-label"), fontWeight = "medium" }),
    ui.input({
      key = "pw_" .. tostring(passwordKey),
      value = "",
      placeholder = noctalia.tr("panel.password-placeholder"),
      password = true,
      focus = true, -- type straight away, no Tab needed
      onChange = "onPasswordChange",
      onSubmit = "onUnlock",
    }),
    ui.row({ gap = 8, align = "center" }, {
      ui.button({
        text = noctalia.tr("panel.unlock"),
        variant = "primary",
        enabled = not busy,
        onClick = "onUnlock",
      }),
      ui.button({
        text = noctalia.tr("panel.close"),
        variant = "ghost",
        onClick = "onClosePanel",
      }),
    }),
  }))
end

function onPasswordChange(value)
  password = if type(value) == "string" then value else ""
end

function onUnlock()
  if busy then
    return
  end
  if password == "" then
    noctalia.notifyError(noctalia.tr("title"), noctalia.tr("errors.password-required"))
    return
  end
  busy = true
  local pw = password
  password = ""
  passwordKey += 1
  -- close before async unlock returns
  panel.close()
  noctalia.state.set("command", { action = "unlock", password = pw })
end

function onClosePanel()
  panel.close()
end

function onOpen(_context)
  password = ""
  passwordKey += 1
  busy = false
  noctalia.state.set("command", { action = "ensure_serve" })
  render()
end
