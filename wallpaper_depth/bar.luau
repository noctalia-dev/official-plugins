--!nonstrict
-- Wallpaper Depth bar widget — opens the plugin settings directly.

local function render()
  barWidget.setGlyph("layers-subtract")
  barWidget.setTooltip(noctalia.tr("title"))
end

function update()
  render()
end

function onClick()
  noctalia.openSettings()
end

render()
