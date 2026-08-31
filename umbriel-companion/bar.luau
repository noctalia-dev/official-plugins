--!nonstrict
-- Umbriel Companion bar widget — the focused workspace's layout, at a glance.
--
-- Click opens the panel; a scroll flick cycles scrolling → dwindle → master.
-- Every compositor call goes through the service, so several bars on several
-- outputs still share one poller.

local LAYOUT_ORDER = { "scrolling", "dwindle", "master" }
local LAYOUT_GLYPHS = {
  scrolling = "columns-3",
  dwindle = "binary-tree",
  master = "layout-sidebar",
}
local LAYOUT_KEYS = {
  scrolling = "layout.scrolling",
  dwindle = "layout.dwindle",
  master = "layout.master",
}

local snapshot = { available = false, workspaces = {} }
local hasTooltip = false

local function layoutLabel(layout)
  return noctalia.tr(LAYOUT_KEYS[layout] or "layout.unknown")
end

local function updateTooltip(focused, explainEmpty)
  if focused == nil then
    -- A visible widget with no data has a reason: the stream failed to start, or
    -- the compositor answered and nothing is focused yet. Say which on hover
    -- instead of leaving a mute glyph.
    if explainEmpty then
      local detail = noctalia.tr("tooltip.waiting")
      if type(snapshot.error) == "string" and snapshot.error ~= "" then
        detail = snapshot.error
      end
      barWidget.setTooltip(detail)
      hasTooltip = true
      return
    end
    if hasTooltip then
      barWidget.clearTooltip()
      hasTooltip = false
    end
    return
  end

  barWidget.setTooltip({
    { key = noctalia.tr("tooltip.workspace"), value = `{focused.output} · {focused.name}` },
    { key = noctalia.tr("tooltip.layout"), value = layoutLabel(focused.layout) },
  })
  hasTooltip = true
end

local function render()
  -- The plugin only means anything on an Umbriel session: take no bar space
  -- anywhere else instead of showing a dead icon.
  if snapshot.available ~= true then
    updateTooltip(nil, false)
    barWidget.setVisible(false)
    return
  end
  barWidget.setVisible(true)

  local focused = snapshot.focused
  local layout = focused ~= nil and focused.layout or nil
  local glyph = ui.glyph({ name = LAYOUT_GLYPHS[layout] or "layout-board" })
  updateTooltip(focused, true)

  -- A vertical bar has no room for labels, so it stays a single glyph.
  if barWidget.isVertical() then
    barWidget.render(ui.column({ align = "center" }, { glyph }))
    return
  end

  local children = { glyph }
  if focused ~= nil and noctalia.getConfig("show_layout_name") == true then
    table.insert(children, ui.label({ text = layoutLabel(layout), fontWeight = "medium" }))
  end
  if focused ~= nil and noctalia.getConfig("show_workspace_name") == true then
    table.insert(children, ui.label({ text = focused.name or "", color = "on_surface_variant" }))
  end
  barWidget.render(ui.row({ gap = 6, align = "center" }, children))
end

function update()
  render()
end

function onClick()
  noctalia.togglePanel("noctalia/umbriel-companion:panel")
end

function onScroll(_axis, steps, startsGesture)
  -- One step per flick: cycling a layout per wheel notch would fly past the
  -- layout the user aimed for.
  if not startsGesture or noctalia.getConfig("scroll_cycles_layout") ~= true then
    return
  end

  local focused = snapshot.focused
  if focused == nil then
    return
  end

  local index = 1
  for i, layout in ipairs(LAYOUT_ORDER) do
    if layout == focused.layout then
      index = i
      break
    end
  end

  local delta = steps >= 0 and 1 or -1
  local target = LAYOUT_ORDER[((index - 1 + delta) % #LAYOUT_ORDER) + 1]
  noctalia.state.set("umbriel.request", { action = `workspace-set-layout:{target}` })
end

noctalia.state.watch("umbriel.state", function(value)
  if type(value) == "table" then
    snapshot = value
    render()
  end
end)

snapshot = noctalia.state.get("umbriel.state") or snapshot
render()
