--!nonstrict
-- Region indicator [[layer]]: one copy per output, shown while a region capture runs.
-- The service publishes "regionIndicator" -> { geometry = "WxH+X+Y" } (global layout
-- coords). Dims everything outside the region; the hole is transparent and the ring
-- frames it from outside, so the recording stays pixel-clean. click_through keeps
-- the pointer working.

local DIM = "#00000066"      -- translucent black (~40%)
local RING = "primary"       -- accent ring framing the region, like the annotation tool
local BORDER_THICKNESS = 2   -- in logical px

-- "WxH+X+Y" (global layout px) -> region clipped to this output in ui px
-- (divided by accessibility.ui_scale). nil when off-output.
local function localRegion(geometry)
  if geometry == nil then return nil end

  local outputName = layer.outputName()
  if outputName == nil then return nil end

  local w, h, x, y = geometry:match("^(%d+)x(%d+)%+(-?%d+)%+(-?%d+)$")
  if w == nil then return nil end

  for _, output in ipairs(noctalia.outputs()) do
    if output.name == outputName then
      local hx = math.max(x - output.x, 0)
      local hy = math.max(y - output.y, 0)
      local right = math.min(x + w - output.x, output.width)
      local bottom = math.min(y + h - output.y, output.height)
      local hw = right - hx
      local hh = bottom - hy
      -- Host scales ui.* dims by accessibility.ui_scale (default 1, floor 0.01).
      local s = math.max(tonumber(noctalia.getSetting("accessibility.ui_scale")) or 1, 0.01)
      if hw <= 0 or hh <= 0 then return nil end
      -- Snap the hole outward to whole ui px: fractional band heights get rounded
      --per-band by the layout, and the drift pushed the dim 1px into the recording.
      local x0, y0 = math.floor(hx / s), math.floor(hy / s)
      return x0, y0, math.ceil((hx + hw) / s) - x0, math.ceil((hy + hh) / s) - y0,
        math.floor(output.width / s), math.floor(output.height / s)
    end
  end
  return nil
end

-- The host mirrors ui.row children under RTL; resolve the shell language the same
-- way it does and pre-mirror the hole to keep it at the physical position.
local RTL_LANGS = " ar ckb dv fa he ps sd ug ur yi "
local RTL = false
for _, tag in ipairs({ noctalia.getSetting("shell.lang") or "", noctalia.getenv("LC_ALL") or "",
    noctalia.getenv("LC_MESSAGES") or "", noctalia.getenv("LANG") or "" }) do
  local sub = tag ~= "" and tag:lower():match("^([^%-%._]+)")
  if sub and RTL_LANGS:find(" " .. sub .. " ", 1, true) then
    RTL = true
    break
  end
end

local function render()
  local indicator = noctalia.state.get("regionIndicator")
  local geometry = if type(indicator) == "table" then indicator.geometry else nil

  local hx, hy, hw, hh, outputWidth, outputHeight = localRegion(geometry)
  if hx == nil then
    layer.render(ui.column({}))
    return
  end

  if RTL then hx = outputWidth - hx - hw end

  local top = math.min(BORDER_THICKNESS, hy)
  local bottom = math.max(0, math.min(BORDER_THICKNESS, outputHeight - hy - hh))
  local left = math.min(BORDER_THICKNESS, hx)
  local right = math.max(0, math.min(BORDER_THICKNESS, outputWidth - hx - hw))

  -- the ring's horizontal side
  local function ringRow(height)
    return ui.row({ height = height }, {
      ui.box({ width = hx - left, fill = DIM }),
      ui.box({ width = hw + left + right, fill = RING }),
      ui.box({ flexGrow = 1, fill = DIM }),
    })
  end

  layer.render(ui.column({}, {
    ui.box({ height = hy - top, fill = DIM }),
    ringRow(top),
    ui.row({ height = hh }, {
      ui.box({ width = hx - left, fill = DIM }),
      ui.box({ width = left, fill = RING }),
      ui.box({ width = hw, fill = "#00000000" }),
      ui.box({ width = right, fill = RING }),
      ui.box({ flexGrow = 1, fill = DIM }),
    }),
    ringRow(bottom),
    ui.box({ flexGrow = 1, fill = DIM }),
  }))
end

noctalia.state.watch("regionIndicator", render)
render()
