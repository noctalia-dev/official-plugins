# Example

Example is a minimal reference plugin that demonstrates the common Noctalia
plugin entry types: a bar widget, a headless service, and a control-center
shortcut.

## Plugin

| Field | Value |
| --- | --- |
| ID | `noctalia/example` |
| Entries | Bar widget: `hello`; service: `ticker`; shortcut: `toggle` |

## Usage

Add the `hello` widget from the Add-widget picker. The widget displays a
configurable label and glyph, counts clicks, reads `data.txt`, and watches the
shared `tick` state published by the `ticker` service.

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
