# Timer

An all-in-one timekeeping suite — Alarms, Stopwatch, Countdown Timer, and a configurable Pomodoro, with bar widgets, a unified panel, desktop widgets, and full IPC command support.

## Plugin

| Field | Value |
| --- | --- |
| ID | `noctalia/timer` |
| Entries | Service: `timer`; Bar widget: `bar`; Panel: `panel`; Desktop widgets: `desktop`, `stopwatch`, `pomodoro` |

## Features

- **Alarms** — One-time or repeating alarms with a countdown to the next one. Toggle, edit or delete them; alarms missed while the machine was off or asleep are reported.
- **Stopwatch** — Start / Pause / Resume / Reset / Lap Flagging.
- **Timer** — Set any duration via text input (e.g. `2500` → 25:00) or one-click presets. Adjust time by +/- buttons while running or paused.
- **Pomodoro** — Focus/break cycle with stage-dot indicator, loop mode, auto-start option, session counter. Skip, Reset current stage, or Reset All.
- **Flags / Laps** — Record and rename flags across all timed modes.
- **Alerts / Ringing** — Looping sound and notification alerts with automatic or manual dismissal.

---

## Desktop Widgets

Add desktop widgets from Noctalia's desktop-widget editor (`noctalia msg desktop-widgets-edit`):

1. **`noctalia/timer:desktop`** (Unified / Countdown Timer):
   - Supports setting `mode` (`timer`, `stopwatch`, `pomodoro`, `smart`). Default is `timer`.
   - Large formatted time display, progress bar, quick `-5m`/`-1m`/`-30s`/`+30s`/`+1m`/`+5m` adjust buttons, Reset, Start/Pause, and Flag controls.
2. **`noctalia/timer:stopwatch`** (Dedicated Stopwatch):
   - Direct stopwatch display with Reset, Start/Pause toggle, and Lap Flag button.
   - Shows latest laps when enabled.
3. **`noctalia/timer:pomodoro`** (Dedicated Pomodoro):
   - Stage header (Focus/Break icon, label, cycle count, loop toggle), stage dots, time display, progress bar, `-1m`/`+1m` adjusters, and Skip/Reset/Start/Pause controls.

All desktop widgets reflect live state from the headless service and display an interactive dismiss banner whenever an alert is ringing.

---

## Usage

Open the panel from a keybind or script:

```sh
noctalia msg panel-toggle noctalia/timer:panel
```

### IPC

Every command is `<mode> <action> [args]`:

```sh
noctalia msg plugin noctalia/timer:timer all <mode> <action> [args]
```

| Mode | Actions |
| --- | --- |
| `timer` | `start [time]`, `pause`, `toggle`, `resume`, `reset`, `set <time>`, `adjust <±time>`, `flag [name]` |
| `sw` (or `stopwatch`) | `start`, `pause`, `toggle`, `resume`, `reset`, `flag [name]` |
| `pomo` (or `pomodoro`) | `start`, `pause`, `toggle`, `resume`, `skip`, `reset`, `reset_all`, `loop`, `adjust <±time>`, `flag [name]` |
| `alarm` | `add <HH:MM> [label] [days]`, `toggle <n>`, `remove <n>` |
| `ring` | `stop` |

A mode on its own toggles it.

- **Times** are `40` (minutes), `25m`, `90s`, `1h30m` or `25:00`. Adjustments take a sign: `+5m`, `-30s`.
- **Alarm days** are none (once), `daily` (or `everyday`), `weekdays`, `weekend` (or `weekends`) or numbers like `1,3,5` (1 = Mon, 7 = Sun). Quote a label that ends in a number. `<n>` is the `#` shown in the panel.

**A few examples:**
```sh
noctalia msg plugin noctalia/timer:timer all timer start 25m
noctalia msg plugin noctalia/timer:timer all sw flag "Lap 1"
noctalia msg plugin noctalia/timer:timer all pomo skip
noctalia msg plugin noctalia/timer:timer all alarm add 07:30 "Wake up" weekdays
noctalia msg plugin noctalia/timer:timer all ring stop
```

---

## Bar Widget

- **Smart Auto** shows only the highest-priority active item, chosen by **Priority Order** (six fixed orderings of **T**imer, **S**topwatch, **P**omodoro; default `T > S > P`).
- **Show All Active** lists every running item separated by bullets.
- **Show time in bar** off gives a glyph-only widget in either mode.
- Clicking while an alert rings immediately stops the sound and opens the panel.

---

## Settings

Per-widget settings are set in the widget's own settings; the rest are plugin-wide.

### Bar Widget Settings

| Setting | Default | Description |
|---------|---------|-------------|
| `bar_display_mode` | Smart Auto | Smart Auto (`smart`) or Show All Active (`all`) |
| `priority_order` | T > S > P | Priority ordering for Smart Auto mode |
| `show_time` | On | Show live time next to the bar icon |

### Desktop Widget Settings

| Setting | Default | Description |
|---------|---------|-------------|
| `mode` | `timer` | Display mode for `desktop`: `timer`, `stopwatch`, `pomodoro`, `smart` |
| `color` | `primary` | Accent color role for time and progress |
| `show_progress` | `true` | Show progress bar |
| `show_flags` | `false`/`true` | Show latest lap or flag |
| `show_dots` | `true` | Show Pomodoro stage indicator dots |

### Plugin Settings

| Setting | Default | Description |
|---------|---------|-------------|
| `alert_mode` | Both | Notification (`notify`), looping sound (`sound`), or both |
| `ring_timeout` | 120 | Silence a ring automatically after this long; `0` = never |
| `alarm_missed_grace` | 10 min | An alarm found later than this is reported as missed instead of ringing; `0` = always ring |
| `pomo_alert_mode` | Inherit | Use a different alert mode for Pomodoro |
| `pomo_work` | 25 min | Focus duration (1-240 min) |
| `pomo_short_break` | 5 min | Short break length (1-240 min) |
| `pomo_long_break` | 15 min | Long break at end of a cycle (0 = disabled, max 240) |
| `pomo_sessions` | 4 | Focus sessions per cycle (1-12) |
| `pomo_auto_start` | Off | Start the next stage automatically once the alert is dismissed |

---

## Requirements

- Noctalia with `plugin_api` ≥ 43.
