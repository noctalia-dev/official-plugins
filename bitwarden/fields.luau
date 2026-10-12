--!nonstrict
-- Custom-fields picker panel. The launcher opens it (via the fields_panel
-- state) for entries that carry custom fields; each row copies its field.
-- Digits 1..9/0 then letters a..z (capture_keys in plugin.toml) copy the
-- numbered field.

local item = nil -- { id = "...", name = "...", fields = { { key, label, masked, value } } }

-- Copy shortcuts: digits first, then letters — the same order as the
-- capture_keys list in plugin.toml and the labels the launcher renders.
local fieldChords = {
  "1", "2", "3", "4", "5", "6", "7", "8", "9", "0",
  "a", "b", "c", "d", "e", "f", "g", "h", "i", "j",
  "k", "l", "m", "n", "o", "p", "q", "r", "s", "t",
  "u", "v", "w", "x", "y", "z",
}

local function maskValue(value)
  if type(value) ~= "string" or value == "" then
    return ""
  end
  if #value == 1 then
    return "*"
  end
  return value:sub(1, 1) .. string.rep("*", #value - 1)
end

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
        panel.close()
      end,
    }, {
      ui.label({ text = f.label, fontWeight = "medium", flexGrow = 1 }),
      ui.label({
        text = if f.display ~= nil then f.display else if f.value ~= nil then (if f.masked then maskValue(f.value) else f.value) else "",
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
  panel.close()
end

function onClosePanel()
  panel.close()
end

function onOpen(_context)
  local data = noctalia.state.get("fields_panel")
  if type(data) == "table" and type(data.fields) == "table" and #data.fields > 0 then
    item = data
  else
    item = nil
  end
  render()
end
