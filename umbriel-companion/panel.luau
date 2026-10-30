--!nonstrict
-- Umbriel Companion panel - layout control for the focused workspace.
--
-- Umbriel applies `workspace-set-layout` to the active workspace of the focused
-- output, so the header names that workspace instead of leaving the target
-- implicit. Everything else in here is the same deal: a button is one typed
-- Umbriel action request, sent through the service on the "umbriel.request"
-- channel, and the answer arrives as a fresh "umbriel.state" snapshot.

local LAYOUTS = {
  { id = "scrolling", glyph = "columns-3", key = "layout.scrolling" },
  { id = "dwindle", glyph = "binary-tree", key = "layout.dwindle" },
  { id = "master", glyph = "layout-sidebar", key = "layout.master" },
  { id = "stacking", glyph = "app-window", key = "layout.stacking" },
}
local LAYOUT_GLYPHS = {
  scrolling = "columns-3",
  dwindle = "binary-tree",
  master = "layout-sidebar",
  stacking = "app-window",
}
local LAYOUT_KEYS = {
  scrolling = "layout.scrolling",
  dwindle = "layout.dwindle",
  master = "layout.master",
  stacking = "layout.stacking",
}
local WIDTH_PRESETS = { 1 / 3, 0.5, 2 / 3, 1 }
local WIDTH_LABELS = { "⅓", "½", "⅔", "1" }
local WINDOW_ACTIONS = {
  { glyph = "app-window", action = "window-toggle-floating", key = "panel.float", state = "floating" },
  { glyph = "pin", action = "window-toggle-pinned", key = "panel.pin" },
  { glyph = "arrows-maximize", action = "window-toggle-fullscreen", key = "panel.fullscreen" },
  { glyph = "maximize", action = "window-toggle-maximize", key = "panel.maximize" },
  { glyph = "focus-centered", action = "window-center", key = "panel.center_window" },
}

local closeButton = true

local snapshot = { available = false, workspaces = {} }

local function tr(key, subst)
  return noctalia.tr(key, subst)
end

local function layoutLabel(layout)
  return tr(LAYOUT_KEYS[layout] or "layout.unknown")
end

-- `request` is Umbriel's typed action request without `cmd`.
local function request(actionRequest)
  noctalia.state.set("umbriel.request", { request = actionRequest })
end

-- Workspace-scoped actions take a position number or an exact name; the output
-- keeps either unambiguous across outputs.
local function workspaceRequest(action, workspace)
  return {
    action = action,
    workspace = workspace.named == true and workspace.name or workspace.index,
    output = workspace.output,
  }
end

local function selectorLabel(workspace)
  return `{workspace.name} ({workspace.output})`
end

local function sectionTitle(key)
  return ui.label({ text = tr(key), fontWeight = "bold", fontSize = 13 })
end

local function unavailableCard()
  return ui.row({ gap = 10, align = "center", padding = 10, radius = 8, fill = "surface_container/0.35" }, {
    ui.glyph({ name = "alert-triangle", size = 20, color = "error" }),
    ui.label({ text = tr("panel.unavailable"), color = "on_surface_variant", fontSize = 12, wrap = true, flexGrow = 1 }),
  })
end

local function targetCard(focused)
  if focused == nil then
    return ui.row({ gap = 10, align = "center", padding = 10, radius = 8, fill = "surface_container/0.35" }, {
      ui.glyph({ name = "layout-board", size = 20, color = "on_surface_variant" }),
      ui.label({ text = tr("panel.no_workspace"), color = "on_surface_variant", fontSize = 12, flexGrow = 1 }),
    })
  end

  return ui.row({ gap = 10, align = "center", padding = 10, radius = 8, fill = "surface_container/0.35" }, {
    ui.glyph({ name = LAYOUT_GLYPHS[focused.layout] or "layout-board", size = 20, color = "primary" }),
    ui.column({ gap = 2, flexGrow = 1 }, {
      ui.label({ text = `{focused.output} · {focused.name}`, fontWeight = "bold", fontSize = 13 }),
      ui.label({ text = tr("panel.target"), color = "on_surface_variant", fontSize = 11 }),
    }),
    ui.label({ text = layoutLabel(focused.layout), color = "primary", fontWeight = "bold", fontSize = 13 }),
  })
end

local function layoutPicker(focused)
  local buttons = {}
  for _, layout in ipairs(LAYOUTS) do
    table.insert(buttons, ui.button({
      text = tr(layout.key),
      glyph = layout.glyph,
      selected = focused ~= nil and focused.layout == layout.id,
      enabled = focused ~= nil,
      flexGrow = 1,
      onClick = function()
        request({ action = "workspace-set-layout", layout = layout.id })
      end,
    }))
  end
  return ui.column({ gap = 6 }, {
    ui.row({ gap = 6 }, { buttons[1], buttons[2] }),
    ui.row({ gap = 6 }, { buttons[3], buttons[4] }),
  })
end

-- Master count and column centering exist in exactly one layout each; Umbriel
-- answers the others with an IPC error, so the row follows the active layout.
local function layoutExtras(focused)
  local layout = focused ~= nil and focused.layout or nil

  if layout == "master" then
    return ui.row({ gap = 6, align = "center" }, {
      ui.label({ text = tr("panel.master_count"), color = "on_surface_variant", fontSize = 12, flexGrow = 1 }),
      ui.button({
        glyph = "minus",
        tooltip = tr("panel.master_decrease"),
        onClick = function()
          request({ action = "layout-master-count-decrease" })
        end,
      }),
      ui.button({
        glyph = "plus",
        tooltip = tr("panel.master_increase"),
        onClick = function()
          request({ action = "layout-master-count-increase" })
        end,
      }),
    })
  end

  if layout == "scrolling" then
    return ui.row({ gap = 6, align = "center" }, {
      ui.button({
        text = tr("panel.center_column"),
        glyph = "layout-align-center",
        variant = "outline",
        flexGrow = 1,
        onClick = function()
          request({ action = "column-center" })
        end,
      }),
    })
  end

  return nil
end

local function windowIdentity(window)
  if window == nil then
    return ui.label({ text = tr("panel.no_window"), color = "on_surface_variant", fontSize = 12 })
  end
  return ui.column({ gap = 2 }, {
    ui.label({ text = window.title, fontSize = 12, maxLines = 1 }),
    ui.label({
      text = `{window.app_id} · {window.w} × {window.h}`,
      color = "on_surface_variant",
      fontSize = 11,
      maxLines = 1,
    }),
  })
end

local function windowSection(window, layout)
  local widths = {}
  for index, fraction in ipairs(WIDTH_PRESETS) do
    table.insert(widths, ui.button({
      text = WIDTH_LABELS[index],
      variant = "outline",
      flexGrow = 1,
      tooltip = tr("panel.width_tooltip", { percent = math.floor(fraction * 100 + 0.5) }),
      onClick = function()
        request({ action = "window-set-primary-extent", fraction = fraction })
      end,
    }))
  end

  local actions = {}
  for _, entry in ipairs(WINDOW_ACTIONS) do
    table.insert(actions, ui.button({
      glyph = entry.glyph,
      tooltip = tr(entry.key),
      selected = window ~= nil and window[entry.state] == true,
      -- A stacking workspace cannot tile individual windows.
      enabled = entry.action ~= "window-toggle-floating" or layout ~= "stacking",
      flexGrow = 1,
      onClick = function()
        request({ action = entry.action })
      end,
    }))
  end

  return ui.column({ gap = 6 }, {
    sectionTitle("panel.window_section"),
    windowIdentity(window),
    ui.row({ gap = 6, align = "center" }, {
      ui.label({ text = tr("panel.width"), color = "on_surface_variant", fontSize = 12 }),
      ui.row({ gap = 6, flexGrow = 1 }, widths),
    }),
    ui.row({ gap = 6 }, actions),
  })
end

local function workspaceRows()
  local rows = {}
  local currentOutput = nil

  for _, workspace in ipairs(snapshot.workspaces or {}) do
    if workspace.output ~= currentOutput then
      currentOutput = workspace.output
      table.insert(rows, ui.label({
        text = currentOutput,
        color = "on_surface_variant",
        fontSize = 11,
        fontWeight = "medium",
      }))
    end

    local selector = workspaceRequest("workspace-switch", workspace)
    table.insert(rows, ui.button({
      key = `ws-{workspace.id}`,
      text = `{workspace.name} - {layoutLabel(workspace.layout)}`,
      glyph = LAYOUT_GLYPHS[workspace.layout] or "layout-board",
      contentAlign = "start",
      selected = workspace.focused == true,
      variant = workspace.active == true and "outline" or "ghost",
      tooltip = tr("panel.row_tooltip"),
      onClick = function()
        request(selector)
      end,
      onRightClick = function()
        panel.openContextMenu({
          items = {
            { kind = "header", label = selectorLabel(workspace) },
            { id = "switch", label = tr("panel.switch") },
            { id = "move-window", label = tr("panel.move_window") },
            { id = "move-column", label = tr("panel.move_column") },
          },
          onActivate = "onWorkspaceMenu",
          context = workspace.id,
        })
      end,
    }))
  end

  if #rows == 0 then
    table.insert(rows, ui.label({ text = tr("panel.no_workspaces"), color = "on_surface_variant", fontSize = 12 }))
  end
  return rows
end

local function render()
  local headerContent = {
    ui.glyph({ name = "layout-columns", size = 20, color = "primary" }),
    ui.label({ text = tr("title"), fontSize = 16, fontWeight = "bold", flexGrow = 1 }),
    ui.button({ glyph = "settings", variant = "ghost", tooltip = tr("panel.settings"), onClick = "onSettings" }),
  }
  if closeButton then
    table.insert(headerContent, ui.button({ glyph = "close", variant = "ghost", onClick = "onCloseClicked" }))
  end

  local header = ui.row({ align = "center", gap = 8 }, headerContent)

  if snapshot.available ~= true then
    panel.render(ui.column({ flexGrow = 1, gap = 8, padding = 10 }, { header, unavailableCard() }))
    return
  end

  local focused = snapshot.focused
  local children = {
    header,
    -- The target card already names the layout, so the picker needs no title.
    targetCard(focused),
    layoutPicker(focused),
  }

  local extras = layoutExtras(focused)
  if extras ~= nil then
    table.insert(children, extras)
  end

  table.insert(children, ui.separator({}))
  table.insert(children, windowSection(snapshot.focused_window, focused ~= nil and focused.layout or nil))
  table.insert(children, ui.separator({}))
  table.insert(children, sectionTitle("panel.workspaces"))
  table.insert(children, ui.scroll({ flexGrow = 1, gap = 4 }, workspaceRows()))

  if type(snapshot.error) == "string" and snapshot.error ~= "" then
    table.insert(children, ui.label({ text = snapshot.error, color = "error", fontSize = 11, wrap = true }))
  end

  panel.render(ui.column({ flexGrow = 1, gap = 8, padding = 10 }, children))
end

local MENU_ACTIONS = {
  ["switch"] = "workspace-switch",
  ["move-window"] = "window-move-to-workspace",
  ["move-column"] = "column-move-to-workspace",
}

function onWorkspaceMenu(actionId, context)
  local action = MENU_ACTIONS[actionId]
  if action == nil then
    return
  end
  for _, workspace in ipairs(snapshot.workspaces or {}) do
    if workspace.id == tostring(context) then
      request(workspaceRequest(action, workspace))
      return
    end
  end
end

function onSettings()
  noctalia.openSettings()
end

function onCloseClicked()
  panel.close()
end

function onOpen(_context)
  closeButton = noctalia.getSetting("shell.show_close_buttons") ~= false
  snapshot = noctalia.state.get("umbriel.state") or snapshot
  -- Opening the panel also retries a disconnected stream immediately.
  noctalia.state.set("umbriel.request", {})
  render()
end

noctalia.state.watch("umbriel.state", function(value)
  if type(value) == "table" then
    snapshot = value
    render()
  end
end)
