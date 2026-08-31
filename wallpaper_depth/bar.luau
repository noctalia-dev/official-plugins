--!nonstrict
-- Wallpaper Depth bar widget - left click opens the panel; right click opens settings.

local function render()
  barWidget.setGlyph("layers-subtract")
  barWidget.setTooltip(noctalia.tr("title"))
end

function update()
  render()
end

function onClick()
  noctalia.togglePanel("noctalia/wallpaper_depth:manager")
end

function onRightClick()
  noctalia.openSettings()
end

render()
