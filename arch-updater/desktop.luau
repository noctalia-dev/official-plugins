-- [[desktop_widget]] entry: desktop widget showing the full update list.
-- Uses the ui.* tree API to render content.

function doRefresh()
  noctalia.state.set("command", { action = "refresh" })
end

function doUpdate()
  noctalia.state.set("command", { action = "update" })
end

function doCopy()
  local updates = noctalia.state.get("updates") or {}
  local lines = {}
  for _, u in ipairs(updates) do
    table.insert(lines, u.name .. "  " .. u.oldVer .. " -> " .. u.newVer)
  end
  local text = table.concat(lines, "\n")
  if text == "" then
    text = noctalia.tr("desktop.noUpdates")
  end
  local cmd = desktopWidget.getConfig("copy_cmd")
  local escaped = string.gsub(text, "'", "'\\''")
  noctalia.runAsync("echo '" .. escaped .. "' | " .. cmd .. " 2>/dev/null", function(_res) end)
end

local function perRepoLabel()
  local sc = noctalia.state.get("system_count") or 0
  local ac = noctalia.state.get("aur_count") or 0
  local fc = noctalia.state.get("flatpak_count") or 0
  local parts = {}
  if sc > 0 then table.insert(parts, "System: " .. sc) end
  if ac > 0 then table.insert(parts, "AUR: " .. ac) end
  if fc > 0 then table.insert(parts, "Flatpak: " .. fc) end
  return table.concat(parts, "  ")
end

local function render()
  local show = noctalia.state.get("desktop_visible") or false
  if not show then
    desktopWidget.render(ui.column({ gap = 0, padding = 0 }, {}))
    return
  end

  local updates = noctalia.state.get("updates") or {}
  local refreshing = noctalia.state.get("refreshing") or false
  local errorMsg = noctalia.state.get("error")
  local count = #updates
  local bold = desktopWidget.getConfig("bold_ver")
  local showHelp = desktopWidget.getConfig("show_help")
  local perRepo = desktopWidget.getConfig("per_repo_counts")
  local children = {}

  -- Header
  table.insert(children, ui.label({
    text = if refreshing
      then noctalia.tr("desktop.refreshing")
      elseif errorMsg
      then noctalia.tr("desktop.checkFailed")
      elseif count == 0
      then noctalia.tr("desktop.upToDate")
      else tostring(count) .. " " .. noctalia.trp("desktop.header", count),
    fontSize = 18,
    fontWeight = "bold",
    color = if errorMsg then "error" elseif count == 0 then "on_surface_variant" else "on_surface",
  }))

  -- Error message
  if errorMsg and not refreshing then
    table.insert(children, ui.label({
      text = errorMsg,
      fontSize = 11,
      color = "error",
    }))
  end

  -- Per-repo counts
  if perRepo and count > 0 and not refreshing then
    local repoLabel = perRepoLabel()
    if repoLabel ~= "" then
      table.insert(children, ui.label({
        text = repoLabel,
        fontSize = 11,
        color = "on_surface_variant",
      }))
    end
  end

  table.insert(children, ui.separator({ spacing = 8, thickness = 1, color = "surface_variant" }))

  -- Empty state
  if count == 0 and not refreshing and not errorMsg then
    table.insert(children, ui.label({
      text = noctalia.tr("desktop.noUpdatesDesc"),
      fontSize = 12,
      color = "on_surface_variant",
    }))
    desktopWidget.render(ui.column({
      gap = 6,
      padding = 12,
      fill = true,
    }, children))
    return
  end

  -- Error state (but still show existing data if any)
  if errorMsg and count == 0 and not refreshing then
    desktopWidget.render(ui.column({
      gap = 6,
      padding = 12,
      fill = true,
    }, children))
    return
  end

  -- Column headers
  table.insert(children, ui.row({ gap = 8, fill = true }, {
    ui.label({
      text = noctalia.tr("desktop.name"),
      fontSize = 13,
      fontWeight = "bold",
      color = "on_surface_variant",
      flexGrow = 2,
    }),
    ui.label({
      text = noctalia.tr("desktop.oldVer"),
      fontSize = 13,
      fontWeight = "bold",
      color = "on_surface_variant",
      flexGrow = 1,
      textAlign = "center",
    }),
    ui.label({
      text = noctalia.tr("desktop.newVer"),
      fontSize = 13,
      fontWeight = "bold",
      color = "on_surface_variant",
      flexGrow = 1,
      textAlign = "center",
    }),
  }))

  -- Update rows
  for _, u in ipairs(updates) do
    local sourceColor = if u.source == "flatpak"
      then "tertiary"
      elseif u.source == "system"
      then "secondary"
      else "primary"

    table.insert(children, ui.row({ gap = 8, fill = true }, {
      ui.label({
        text = u.name,
        fontSize = 12,
        color = sourceColor,
        flexGrow = 2,
        maxLines = 1,
      }),
      ui.label({
        text = u.oldVer,
        fontSize = 12,
        color = sourceColor,
        flexGrow = 1,
        textAlign = "center",
        maxLines = 1,
      }),
      ui.label({
        text = u.newVer,
        fontSize = 12,
        fontWeight = if bold then "bold" else "normal",
        color = sourceColor,
        flexGrow = 1,
        textAlign = "center",
        maxLines = 1,
      }),
    }))
  end

  -- Action buttons
  table.insert(children, ui.separator({ spacing = 8, thickness = 1, color = "surface_variant" }))

  table.insert(children, ui.row({ gap = 8, justify = "center" }, {
    ui.button({
      text = noctalia.tr("desktop.copy"),
      variant = "secondary",
      onClick = "doCopy",
    }),
    ui.button({
      text = noctalia.tr("desktop.refresh"),
      variant = "secondary",
      onClick = "doRefresh",
    }),
    ui.button({
      text = noctalia.tr("desktop.update"),
      variant = "primary",
      onClick = "doUpdate",
    }),
  }))

  -- Help section
  if showHelp then
    table.insert(children, ui.separator({ spacing = 6, thickness = 1, color = "surface_variant" }))
    table.insert(children, ui.label({
      text = noctalia.tr("desktop.help"),
      fontSize = 10,
      color = "on_surface_variant",
    }))
  end

  desktopWidget.render(ui.column({
    gap = 6,
    padding = 12,
    fill = true,
  }, children))
end

noctalia.state.watch("updates", render)
noctalia.state.watch("refreshing", render)
noctalia.state.watch("error", render)
noctalia.state.watch("desktop_visible", render)

function update()
  desktopWidget.setWantsSecondTicks(false)
  render()
end
