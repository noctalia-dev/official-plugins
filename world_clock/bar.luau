--!nonstrict
-- World Clock bar widget - icon that opens the panel, or the live clocks
-- themselves when the "show_clocks" widget setting is on.

local zones = noctalia.state.get("world_clock.zones") or {}

local function render()
  -- Read on every render: a settings change repaints the widget.
  local glyph = ui.glyph({ name = "world" })
  if noctalia.getConfig("show_clocks") ~= true then
    barWidget.render(glyph)
    return
  end

  -- Only zones the user left visible in the panel (per-zone eye toggle).
  local visible = {}
  for _, row in ipairs(zones) do
    if row.on_bar ~= false then
      table.insert(visible, row)
    end
  end
  if #visible == 0 then
    barWidget.render(glyph)
    return
  end

  if barWidget.isVertical() then
    -- Side bar capsule is bar-thick so time only one zones per line
    local rows = {}
    for _, row in ipairs(visible) do
      table.insert(rows, ui.label({ text = row.time or "", fontWeight = "bold", maxLines = 1 }))
    end
    barWidget.render(ui.column({ gap = 1, align = "center" }, rows))
    return
  end

  local children = { glyph }
  for _, row in ipairs(visible) do
    table.insert(children, ui.label({ text = `{row.label or row.id} {row.time}`, maxLines = 1 }))
  end
  barWidget.render(ui.row({ gap = 8, align = "center" }, children))
end

noctalia.state.watch("world_clock.zones", function(value)
  zones = value or {}
  render()
end)

function update()
  render()
end

function onClick()
  noctalia.togglePanel("noctalia/world_clock:panel")
end

render()
