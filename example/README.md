# Example

Example is a minimal reference plugin that demonstrates the common Noctalia
plugin entry types: a bar widget, a headless service, and a control-center
shortcut.

## Plugin

| Field | Value |
| --- | --- |
| ID | `noctalia/example` |
| Entries | Bar widgets: `hello`, `declarative`; service: `ticker`; shortcut: `toggle`; launcher: `finder`; panels: `panel`, `dnd` |
| Launcher Prefix | `/ex` |

## Usage

Add the `hello` widget from the Add-widget picker. The widget displays a
configurable label and glyph, counts clicks, reads `data.txt`, and watches the
shared `tick` state published by the `ticker` service.

Add the `declarative` widget to see the same service tick rendered as a
`ui.*` tree via `barWidget.render()` - a glyph, the live counter in a filled
rounded badge (impossible with the imperative API), and an inline `ui.button`
whose click is handled separately from the widget-level `onClick`. Simple
widgets can keep using `setText`/`setGlyph`; `render()` is the declarative
alternative for composite content.

Add the `toggle` shortcut from Settings -> Control Center shortcuts. It toggles
shared plugin state and shows how shortcut entries can render an active state.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `label` | `string` | `Hello` | Text shown in the bar widget. |
| `glyph` | `glyph` | `puzzle` | Glyph shown before the label. |
| `show_glyph` | `bool` | `true` | Controls whether the glyph is visible. |

## IPC

The `hello` widget exposes two IPC events:

```sh
noctalia msg plugin noctalia/example:hello focused set "Hi there"
noctalia msg plugin noctalia/example:hello focused fetch "https://example.com"
```

`set` updates the widget label at runtime. `fetch` performs an asynchronous HTTP
request and reports the response status in a notification.

You can open the example panel with the following IPC call:

```sh
noctalia msg panel-toggle noctalia/example:panel
noctalia msg panel-toggle noctalia/example:dnd
```

The panel includes a **Color picker** section. Click **Choose color** to open
Noctalia's native dialog; applying a color updates the swatch and displays the
hex value returned to the plugin callback, while cancelling displays the
cancellation result.

The `dnd` panel is the drag-and-drop reference (sortable rows, cross-column
moves, and rejected-type targets).
