--!nonstrict
-- Reference [[layer]] entry: a plugin-owned layer-shell surface (plugin_api 36).
--
-- A layer is lazy. Nothing exists until an entry of this plugin calls
-- noctalia.layer.show("banner"); then the host creates one surface and one copy of this
-- script per target output, and noctalia.layer.hide("banner") destroys both. The
-- ticker service drives it (see ticker.luau):
--
--   noctalia msg plugin noctalia/example:ticker all layer-toggle   show / hide
--   noctalia msg plugin noctalia/example:ticker all layer-move     top <-> bottom edge
--   noctalia msg plugin noctalia/example:ticker all layer-idle     show after 5 s idle
--
--   layer.render(tree)            replace this surface's UI tree (same ui.* as panels)
--   layer.setNeedsFrameTick(on)   per-frame onFrameTick(deltaMs) while shown
--   layer.outputName()            connector of the output this copy draws on
--
-- The manifest anchors it to the top edge with height 0, so it stretches across the
-- output and takes the content's height; exclusive_zone = "auto" reserves that height
-- so windows move out of the way.

local tick = noctalia.state.get("tick") or 0
local elapsedMs = 0

local function render()
  layer.render(ui.row({ fill = "primary", paddingH = 16, paddingV = 8, gap = 12, align = "center" }, {
    ui.glyph({ name = "layers-intersect", size = 18, color = "on_primary" }),
    ui.label({
      text = `Example layer on {layer.outputName() or "?"} - tick {tick} - shown {math.floor(elapsedMs / 1000)} s`,
      color = "on_primary",
      fontWeight = "medium",
      flexGrow = 1,
    }),
    ui.button({
      glyph = "close",
      onClick = function()
        noctalia.layer.hide("banner")
        noctalia.state.set("bannerClosed", os.clock())
      end,
    }),
  }))
end

noctalia.state.watch("tick", function(value)
  tick = value
  render()
end)

-- Frame ticks only to show that per-frame animation runs while the layer is up.
function onFrameTick(deltaMs)
  local before = math.floor(elapsedMs / 1000)
  elapsedMs += tonumber(deltaMs)
  if math.floor(elapsedMs / 1000) ~= before then
    render()
  end
end

layer.setNeedsFrameTick(true)
render()
