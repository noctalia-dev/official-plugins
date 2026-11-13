--!nonstrict

local backend = require("./backend.luau")

local function renderWidget(imagePath: string?, size: number, radius: number)
  if imagePath and imagePath ~= "" then
    barWidget.render(ui.row({ align = "center" }, {
      ui.image({
        path = imagePath,
        width = size,
        height = size,
        radius = radius,
        fit = "cover",
      }),
    }))
  else
    barWidget.render(ui.row({ align = "center" }, {
      ui.glyph({ name = "photo", size = 16, color = "on_surface" }),
    }))
  end
end

function update()
  local path, size, radius = backend.getImageConfig()
  renderWidget(path, size, radius)
end

function onClick()
  update()
end
