-- [[widget]] entry: bar widget showing update count.
-- Reads state published by the updater [[service]].

local function send(action)
  noctalia.state.set("command", { action = action })
end

local function tooltipText()
  local updates = noctalia.state.get("updates")
  if not updates or #updates == 0 then
    return noctalia.tr("tooltip.noUpdates")
  end

  local noctaliaHighlight = noctalia.state.get("noctalia_update")
  local header = if noctaliaHighlight
    then noctalia.tr("tooltip.noctaliaUpdates")
    else noctalia.tr("tooltip.availableUpdates")

  local lines = { header, "---" }
  local maxShown = 30
  local shown = 0
  for _, u in ipairs(updates) do
    if shown >= maxShown then
      table.insert(lines, "...")
      break
    end
    table.insert(lines, u.name .. " " .. u.oldVer .. " -> " .. u.newVer)
    shown = shown + 1
  end

  return table.concat(lines, "\n")
end

local function render()
  local count = noctalia.state.get("count") or 0
  local refreshing = noctalia.state.get("refreshing") or false
  local noctaliaHighlight = noctalia.state.get("noctalia_update") or false
  local configGlyph = barWidget.getConfig("glyph")
  local hideEmpty = barWidget.getConfig("hide_on_empty")
  local bold = barWidget.getConfig("bold_count")
  local tooltipEnabled = barWidget.getConfig("tooltip_enabled")

  -- Hide on empty
  if hideEmpty and count == 0 and not refreshing then
    barWidget.setVisible(false)
    return
  end
  barWidget.setVisible(true)

  -- Glyph
  if refreshing then
    barWidget.setGlyph("loader")
  else
    barWidget.setGlyph(configGlyph)
  end

  -- Color
  if noctaliaHighlight and count > 0 then
    barWidget.setGlyphColor("tertiary")
    barWidget.setColor("tertiary")
  elseif refreshing then
    barWidget.setGlyphColor("on_surface_variant")
    barWidget.setColor("on_surface_variant")
  else
    barWidget.setGlyphColor("primary")
    barWidget.setColor("primary")
  end

  barWidget.setText(tostring(count))

  -- Tooltip
  if tooltipEnabled then
    local tt = tooltipText()
    if tt and tt ~= "" then
      barWidget.setTooltip(tt)
    else
      barWidget.clearTooltip()
    end
  else
    barWidget.clearTooltip()
  end
end

-- Watch shared state for changes
noctalia.state.watch("count", render)
noctalia.state.watch("refreshing", render)
noctalia.state.watch("noctalia_update", render)

function update()
  -- State watches handle re-renders on change; no polling needed.
  render()
end

function onClick()
  noctalia.log("refreshing from widget...")
  send("refresh")
end

function onRightClick()
  noctalia.log("toggling desktop widget...")
  local visible = noctalia.state.get("desktop_visible") or false
  noctalia.state.set("desktop_visible", not visible)
end

function onMiddleClick()
  noctalia.log("updating from widget...")
  send("update")
end

function onIpc(event, payload)
  if event == "set" then
    -- Allow setting update command via IPC
    noctalia.state.set("command", { action = "refresh" })
  elseif event == "fetch" then
    send("refresh")
  end
end
