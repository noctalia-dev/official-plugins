# World Clock

World Clock tracks multiple IANA timezones in a panel opened from the bar. The
headless service owns the zone list and publishes live times; the bar widget and
panel are thin clients of that shared state.

## Plugin

| Field | Value |
| --- | --- |
| ID | `noctalia/world_clock` |
| Entries | Service: `service`; bar widget: `bar`; panel: `panel` |

## Usage

### Bar widget

Add the `bar` widget to your bar. It shows a world glyph; click it to open the
world-clock panel.

### Panel

The panel lists every configured timezone with its current time and UTC offset.
Type an IANA zone name (for example `Europe/Berlin`) and press Enter or the plus
button to add it. Use the trash control to remove a zone (confirm with the check).
Drag the grip on the left of a row to reorder.

On first run the list is seeded with:

- `UTC`
- `America/New_York`
- `Europe/Berlin`
- `Asia/Tokyo`

Zones are stored under the plugin data directory and survive plugin updates.

### IPC

```sh
# Open the panel
noctalia msg panel-toggle noctalia/world_clock:panel

# Manage zones
noctalia msg plugin noctalia/world_clock:service all add "America/Los_Angeles"
noctalia msg plugin noctalia/world_clock:service all remove "UTC"
noctalia msg plugin noctalia/world_clock:service all list
noctalia msg plugin noctalia/world_clock:service all clear
```

`list` shows the configured zones in a notification.

## Notes

Requires `plugin_api = 19` for timezone formatting and `noctalia.timeFormat()` /
`noctalia.isValidTimezone()`. Display times follow `[shell].time_format`.
