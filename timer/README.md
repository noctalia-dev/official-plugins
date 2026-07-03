# Timer

Timer adds a desktop countdown widget with start, pause, reset, and optional
progress display.

## Plugin

| Field | Value |
| --- | --- |
| ID | `noctalia/timer` |
| Entry | Desktop widget: `timer` |

## Usage

Add the `timer` desktop widget from Noctalia's desktop-widget editor. The widget
counts down from the configured duration, can be paused and reset, and sends a
notification when the countdown reaches zero.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `duration` | `int` | `300` | Countdown duration in seconds, from 10 to 7200. |
| `color` | `color` | `primary` | Accent color for the time and progress bar. |
| `show_progress` | `bool` | `true` | Shows or hides the progress bar. |

## Notes

This plugin is also a reference implementation for `[[desktop_widget]]` entries
and Noctalia's declarative `ui.*` widget tree.
