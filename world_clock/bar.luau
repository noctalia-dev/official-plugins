--!nonstrict
-- World Clock bar widget - icon that opens the panel.

local function render()
  barWidget.render(ui.glyph({ name = "world" }))
end

function update()
  render()
end

function onClick()
  noctalia.togglePanel("noctalia/world_clock:panel")
end

render()
