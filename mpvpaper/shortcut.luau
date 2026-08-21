--!nonstrict
-- Tile in the control center that opens the video wallpaper picker.

local function render()
    shortcut.setLabel(noctalia.tr("title"))
    shortcut.setIcon("movie")
end

render()

function onClick()
  noctalia.togglePanel("noctalia/mpvpaper:picker")
end
