--!nonstrict
-- Umbriel Companion panel - layout control for the focused workspace.
--
-- Umbriel applies `workspace-set-layout` to the active workspace of the focused
-- output, so the header names that workspace instead of leaving the target
-- implicit. Everything else in here is the same deal: a button is one
-- `umbriel msg` action, sent through the service on the "umbriel.request"
-- channel, and the answer arrives as a fresh "umbriel.state" snapshot.

local LAYOUTS = {
  { id = "scrolling", glyph = "columns-3", key = "layout.scrolling" },
  { id = "dwindle", glyph = "binary-tree", key = "layout.dwindle" },
  { id = "master", glyph = "layout-sidebar", key = "layout.master" },
}
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
local WIDTH_PRESETS = { "0.333", "0.5", "0.667", "1.0" }
local WIDTH_LABELS = { "⅓", "½", "⅔", "1" }
local WINDOW_ACTIONS = {
  { glyph = "app-window", action = "window-toggle-floating", key = "panel.float" },
  { glyph = "pin", action = "window-toggle-pinned", key = "panel.pin" },
  { glyph = "arrows-maximize", action = "window-toggle-fullscreen", key = "panel.fullscreen" },
  { glyph = "maximize", action = "window-toggle-maximize", key = "panel.maximize" },
  { glyph = "focus-centered", action = "window-center", key = "panel.center_window" },
}

local snapshot = { available = false, workspaces = {} }

local function tr(key, subst)
  return noctalia.tr(key, subst)
end

local function layoutLabel(layout)
  return tr(LAYOUT_KEYS[layout] or "layout.unknown")
end

local function request(action)
  noctalia.state.set("umbriel.request", { action = action })
end

-- Workspace selector accepted by every workspace-scoped action: the name is
-- ambiguous across outputs, "<name>/<output>" never is.
local function selectorOf(workspace)
  return `{workspace.name}/{workspace.output}`
end

local function sectionTitle(key)
  return ui.label({ text = tr(key), fontWeight = "bold", fontSize = 13 })
end

local function unavailableCard()
  return ui.row({ gap = 10, align = "center", padding = 10, radius = 8, fill = "surface_variant/0.35" }, {
    ui.glyph({ name = "alert-triangle", size = 20, color = "error" }),
    ui.label({ text = tr("panel.unavailable"), color = "on_surface_variant", fontSize = 12, wrap = true, flexGrow = 1 }),
  })
end

local function targetCard(focused)
  if focused == nil then
    return ui.row({ gap = 10, align = "center", padding = 10, radius = 8, fill = "surface_variant/0.35" }, {
      ui.glyph({ name = "layout-board", size = 20, color = "on_surface_variant" }),
      ui.label({ text = tr("panel.no_workspace"), color = "on_surface_variant", fontSize = 12, flexGrow = 1 }),
    })
  end

  return ui.row({ gap = 10, align = "center", padding = 10, radius = 8, fill = "surface_variant/0.35" }, {
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
        request(`workspace-set-layout:{layout.id}`)
      end,
    }))
  end
  return ui.row({ gap = 6 }, buttons)
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
          request("master-count-decrease")
        end,
      }),
      ui.button({
        glyph = "plus",
        tooltip = tr("panel.master_increase"),
        onClick = function()
          request("master-count-increase")
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
          request("column-center")
        end,
      }),
    })
  end

  return nil
end

local function windowSection()
  local widths = {}
  for index, fraction in ipairs(WIDTH_PRESETS) do
    table.insert(widths, ui.button({
      text = WIDTH_LABELS[index],
      variant = "outline",
      flexGrow = 1,
      tooltip = tr("panel.width_tooltip", { percent = math.floor(tonumber(fraction) * 100 + 0.5) }),
      onClick = function()
        request(`window-set-width:{fraction}`)
      end,
    }))
  end

  local actions = {}
  for _, entry in ipairs(WINDOW_ACTIONS) do
    table.insert(actions, ui.button({
      glyph = entry.glyph,
      tooltip = tr(entry.key),
      flexGrow = 1,
      onClick = function()
        request(entry.action)
      end,
    }))
  end

  return ui.column({ gap = 6 }, {
    sectionTitle("panel.window_section"),
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

    local selector = selectorOf(workspace)
    table.insert(rows, ui.button({
      key = `ws-{workspace.id}`,
      text = `{workspace.name} - {layoutLabel(workspace.layout)}`,
      glyph = LAYOUT_GLYPHS[workspace.layout] or "layout-board",
      contentAlign = "start",
      selected = workspace.focused == true,
      variant = workspace.active == true and "outline" or "ghost",
      tooltip = tr("panel.row_tooltip"),
      onClick = function()
        request(`workspace-switch:{selector}`)
      end,
      onRightClick = function()
        panel.openContextMenu({
          items = {
            { kind = "header", label = selector },
            { id = "switch", label = tr("panel.switch") },
            { id = "move-window", label = tr("panel.move_window") },
            { id = "move-column", label = tr("panel.move_column") },
          },
          onActivate = "onWorkspaceMenu",
          context = selector,
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
  local header = ui.row({ align = "center", gap = 8 }, {
    ui.glyph({ name = "layout-columns", size = 20, color = "primary" }),
    ui.label({ text = tr("title"), fontSize = 16, fontWeight = "bold", flexGrow = 1 }),
    ui.button({ glyph = "settings", variant = "ghost", tooltip = tr("panel.settings"), onClick = "onSettings" }),
    ui.button({ glyph = "close", variant = "ghost", onClick = "onCloseClicked" }),
  })

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
  table.insert(children, windowSection())
  table.insert(children, ui.separator({}))
  table.insert(children, sectionTitle("panel.workspaces"))
  table.insert(children, ui.scroll({ flexGrow = 1, gap = 4 }, workspaceRows()))

  if type(snapshot.error) == "string" and snapshot.error ~= "" then
    table.insert(children, ui.label({ text = snapshot.error, color = "error", fontSize = 11, wrap = true }))
  end

  panel.render(ui.column({ flexGrow = 1, gap = 8, padding = 10 }, children))
end

function onWorkspaceMenu(actionId, context)
  local selector = tostring(context)
  if actionId == "switch" then
    request(`workspace-switch:{selector}`)
  elseif actionId == "move-window" then
    request(`window-move-to-workspace:{selector}`)
  elseif actionId == "move-column" then
    request(`column-move-to-workspace:{selector}`)
  end
end

function onSettings()
  noctalia.openSettings()
end

function onCloseClicked()
  panel.close()
end

function onOpen(_context)
  snapshot = noctalia.state.get("umbriel.state") or snapshot
  -- The snapshot is whatever the stream last pushed. An empty request asks the
  -- service to confirm the stream is still alive before the user acts on it.
  noctalia.state.set("umbriel.request", {})
  render()
end

noctalia.state.watch("umbriel.state", function(value)
  if type(value) == "table" then
    snapshot = value
    render()
  end
end)
