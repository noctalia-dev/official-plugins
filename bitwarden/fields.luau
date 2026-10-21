--!nonstrict
-- Custom-fields picker panel. The launcher opens it (via the fields_panel
-- state) for entries that carry custom fields; each row copies its field.
-- Digits 1..9/0 then letters a..z (capture_keys in plugin.toml) copy the
-- numbered field.
--
-- Plaintext lifecycle: the panel state carries keys, labels, and display
-- values (notes and text custom fields arrive unmasked because they are not
-- secret). It is consumed once in onOpen and cleared immediately, cleared on
-- every close path, and re-cleared whenever the vault stops being unlocked —
-- so a picker toggled back open after a lock or logout can never render
-- stale plaintext.

local item = nil -- { id = "...", name = "...", fields = { { key, label, masked, value? } } }

local function clearPanelState()
  item = nil
  noctalia.state.set("fields_panel", nil)
end

local function vaultUnlocked()
  local st = noctalia.state.get("status")
  return type(st) == "table" and st.vault == "unlocked"
end

-- Close the picker (and drop its plaintext) the moment the vault locks or
-- logs out; the service republishes "status" on every transition.
noctalia.state.watch("status", function()
  if item == nil then
    return
  end
  if not vaultUnlocked() then
    clearPanelState()
    panel.close()
  end
end)

-- Copy shortcuts: digits first, then letters — the same order as the
-- capture_keys list in plugin.toml and the labels the launcher renders.
local fieldChords = {
  "1", "2", "3", "4", "5", "6", "7", "8", "9", "0",
  "a", "b", "c", "d", "e", "f", "g", "h", "i", "j",
  "k", "l", "m", "n", "o", "p", "q", "r", "s", "t",
  "u", "v", "w", "x", "y", "z",
}

local HIDDEN_PREVIEW = "••••"

function render()
  if type(item) ~= "table" then
    panel.render(ui.column({ gap = 10 }, {
      ui.label({ text = noctalia.tr("panel.fields-unavailable"), color = "on_surface_variant" }),
    }))
    return
  end

  local rows = {}
  for _, f in item.fields do
    table.insert(rows, ui.row({
      key = "field_" .. f.key,
      gap = 10,
      align = "center",
      onClick = function()
        noctalia.state.set("command", { action = "copy", id = item.id, field = f.key })
        clearPanelState()
        panel.close()
      end,
    }, {
      ui.label({ text = f.label, fontWeight = "medium", flexGrow = 1 }),
      ui.label({
        text = if f.display ~= nil
          then f.display
          elseif f.value ~= nil then f.value
          elseif f.masked then HIDDEN_PREVIEW
          else "",
        color = "on_surface_variant",
      }),
    }))
  end

  panel.render(ui.column({ flexGrow = 1, gap = 10, align = "stretch" }, {
    ui.label({ text = noctalia.tr("panel.fields-title"), fontWeight = "medium" }),
    ui.label({ text = if type(item.name) == "string" then item.name else "", color = "on_surface_variant" }),
    ui.scroll({ flexGrow = 1, gap = 4 }, rows),
    ui.row({ gap = 8, align = "end" }, {
      ui.button({
        text = noctalia.tr("panel.autotype"),
        variant = "primary",
        onClick = function()
          noctalia.state.set("command", { action = "autotype", id = item.id })
          clearPanelState()
          panel.close()
        end,
      }),
      ui.button({
        text = noctalia.tr("panel.close"),
        variant = "ghost",
        onClick = "onClosePanel",
      }),
    }),
  }))
end

function onKey(chord, pressed)
  if not pressed or item == nil then
    return
  end
  local index = nil
  for i, c in fieldChords do
    if c == chord then
      index = i
      break
    end
  end
  if index == nil then
    return
  end
  local f = item.fields[index]
  if type(f) ~= "table" then
    return
  end
  noctalia.state.set("command", { action = "copy", id = item.id, field = f.key })
  clearPanelState()
  panel.close()
end

function onClosePanel()
  clearPanelState()
  panel.close()
end

-- Outside-click and Escape dismissals bypass onClosePanel; drop the item here.
function onClose()
  clearPanelState()
end

function onOpen(_context)
  if not vaultUnlocked() then
    -- never restore plaintext without an unlocked vault behind it
    clearPanelState()
    render()
    return
  end
  local data = noctalia.state.get("fields_panel")
  if type(data) == "table" and type(data.fields) == "table" and #data.fields > 0 then
    item = data
  else
    item = nil
  end
  -- consume the shared state once: from here on the values live only in this
  -- panel's runtime, and a reopen after close/lock starts empty
  noctalia.state.set("fields_panel", nil)
  render()
end
