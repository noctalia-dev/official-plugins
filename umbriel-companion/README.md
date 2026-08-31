# Umbriel Companion

Umbriel chooses a layout per workspace, and switching it usually means reaching for a keybind. This plugin puts that
control in the bar: the widget shows the layout of the focused workspace, and its panel switches the layout, runs the
actions that only exist in the active layout, resizes or floats the focused window, and jumps between workspaces.

## Plugin

Manifest id `noctalia/umbriel-companion`.

- `bar` - bar widget. Shows the focused workspace's layout glyph, optionally with the layout and workspace names.
  Click opens the panel; a scroll flick cycles scrolling → dwindle → master. The widget hides itself outside an
  Umbriel session.
- `panel` - the layout panel, attached to the widget. Open it without a widget with
  `noctalia msg panel-toggle noctalia/umbriel-companion:panel`.
- `service` - the only entry that talks to the compositor. It holds `umbriel subscribe workspaces` open, republishes
  every pushed line as the snapshot each UI entry reads, and runs every requested `umbriel msg` action.

## Requirements

- `umbriel` on `PATH`, inside a running Umbriel session, with the `subscribe` verb (Umbriel 0.1.1 or newer). Every
  other compositor gets a hidden widget and an inert panel.

## Usage

Add the **Umbriel Companion** widget to a bar from Settings → Bar, or open the panel through IPC.

The panel targets the workspace Umbriel considers focused - the active workspace of the focused output - and names it
at the top, because that is the workspace `workspace-set-layout` acts on, not the one the panel is drawn over.

- **Layout** - Scrolling, Dwindle, Master. The current layout is highlighted. The override lasts until a config
  reload reasserts the configured mode.
- **Layout actions** - master layout gets the master-count steppers; scrolling gets *Center column*. Dwindle has no
  layout-scoped action, so the row disappears.
- **Focused window** - width presets (⅓, ½, ⅔, full), floating, pinned, fullscreen, maximize, and centering for a
  floating window.
- **Workspaces** - every workspace of every output with its layout. Click switches to it; right-click moves the
  focused window or its whole column there.

Nothing here polls. Umbriel's IPC event stream carries the workspace list with each workspace's layout mode - the one
piece of workspace state no Wayland protocol exposes - and `umbriel subscribe workspaces` is that stream on stdout.
The service reads it line by line, so the bar glyph and the panel change on the same event as the keybind, and an
idle session costs nothing at all.

## Settings

- **Show layout name** (widget) - print the layout next to the glyph on a horizontal bar.
- **Show workspace name** (widget) - print the focused workspace name next to the glyph on a horizontal bar.
- **Scroll cycles the layout** (widget) - turn the scroll gesture off if you would rather not change layouts by
  accident.
