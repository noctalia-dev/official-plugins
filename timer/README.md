# Timer

Timer offers two independent timer experiences: a bar widget with panel for
interactive countdown control, and a standalone desktop widget with its own
built-in start, pause, reset, and progress display.

## Plugin

| Field | Value |
| --- | --- |
| ID | `noctalia/timer` |
| Entries | Service: `timer`; bar widget: `bar`; panel: `panel`; desktop widget: `desktop` |

## Bar Widget and Panel

The headless `timer` service owns countdown logic and state. The `bar` widget
and `panel` communicate with the service through shared plugin state.

Add the `bar` bar widget to your bar. It displays an hourglass icon when idle,
or the formatted countdown when running. Click the widget to open the timer
panel for duration input and controls. When the timer completes, clicking the
bar widget resets it.

On vertical bars, the widget shows an hourglass with the time as a tooltip.
On horizontal bars, the widget shows the hourglass and countdown side by side,
with an option to hide the countdown when idle.

## Desktop Widget

Add the `desktop` desktop widget from Noctalia's desktop-widget editor. The
widget counts down from the configured duration, can be paused and reset, and
sends a notification when the countdown reaches zero.

The desktop widget manages its own state independently and does not interact
with the bar widget or service.

## Settings

### Bar Widget

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `show_idle_on_horizontal` | `bool` | `true` | Shows or hides the countdown on horizontal bars when idle. |

### Desktop Widget

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `duration` | `int` | `300` | Countdown duration in seconds, from 10 to 7200. |
| `color` | `color` | `primary` | Accent color for the time and progress bar. |
| `show_progress` | `bool` | `true` | Shows or hides the progress bar. |

## Notes

This plugin is a reference implementation for `[[desktop_widget]]` entries,
`[[widget]]` bar widget entries, and Noctalia's declarative `ui.*` widget tree.
