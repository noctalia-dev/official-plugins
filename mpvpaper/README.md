# Video Wallpaper

Animated and video wallpapers for Noctalia, powered by
[mpvpaper](https://github.com/GhostNaN/mpvpaper).

Noctalia does not decode video itself. This plugin runs `mpvpaper`, which draws its own
`wlr-layer-shell` background surface, and asks Noctalia to drop its wallpaper on the
outputs you assign a video to — so the video shows through, with the bar and dock still
drawn above it.

## Plugin

| Field | Value |
| --- | --- |
| ID | `noctalia/mpvpaper` |
| Entries | Service: `service`; Panel: `picker`; bar widget: `mpvpaper` |

## Requirements

Install `mpvpaper` and `mpv` on `PATH`. `mpvpaper` renders the wallpaper
surface, and `mpv` renders picker thumbnails.

The plugin works on `wlr-layer-shell` compositors (Niri, Hyprland, Sway, Mango).

## Usage

1. Set **Video directory** in the plugin settings (defaults to `~/Videos`).
2. Add the **Video Wallpaper** bar widget, or open the picker with

   ```sh
   noctalia msg panel-toggle noctalia/mpvpaper:picker
   ```

3. Choose a target output (or **All outputs**), then click a video to apply it.
   Use **Stop** to restore Noctalia's own wallpaper on that output.

Assignments persist across restarts. Supported files: `mp4`, `webm`, `mkv`, `mov`, `gif`.

## IPC Commands

You can control the video wallpaper externally via Noctalia's IPC mechanism. Replace `[connector]` with your display name (e.g. `DP-1`), or omit it to target all monitors:

- `noctalia msg plugin noctalia/mpvpaper:service all pause [connector]` - Pauses playback via cgroups freezer.
- `noctalia msg plugin noctalia/mpvpaper:service all resume [connector]` - Resumes playback.
- `noctalia msg plugin noctalia/mpvpaper:service all toggle [connector]` - Toggles playback between paused and resumed state.
- `noctalia msg plugin noctalia/mpvpaper:service all clear <connector>` - Stops the wallpaper on the specified monitor and extracts a frame as a static wallpaper.
- `noctalia msg plugin noctalia/mpvpaper:service all clear-all` - Stops all active video wallpapers.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `video_directory` | `folder` | *(empty)* | Folder scanned for wallpaper videos; defaults to `~/Videos` when empty. |
| `mute` | `bool` | `true` | Starts video wallpapers muted. |
| `hardware_decode` | `bool` | `true` | Uses `mpv` hardware decoding. |
| `auto_pause` | `bool` | `true` | Pauses playback while a fullscreen window covers the wallpaper. |
| `mpv_options` | `string` | *(empty)* | Additional space-separated `mpv` options. |
| `run_as_systemd` | `bool` | `false` | Runs instances inside systemd transient scopes (`systemd-run`) for resource control. |
| `extract_last_frame` | `bool` | `true` | Extracts a static frame to use as a wallpaper when video playback is stopped or paused. |
| `cpu_quota` | `number` | `0` | Systemd `CPUQuota=` limit in percentage. Requires `run_as_systemd`. |
| `allowed_cpus` | `string` | *(empty)* | Systemd `AllowedCPUs=` limits (e.g., `0-3`). Requires `run_as_systemd`. |
| `memory_max` | `string` | *(empty)* | Systemd `MemoryMax=` limits (e.g., `500M`). Requires `run_as_systemd`. |
| `cpu_weight` | `number` | `0` | Systemd `CPUWeight=` priority. Requires `run_as_systemd`. |
| `nice` | `number` | `0` | Process `nice` priority level. Requires `run_as_systemd`. |
| `glyph` | `glyph` | `movie` | Bar widget icon. |

## How it works

A headless service natively supervises `mpvpaper` instances (one per output), either launching them directly or wrapping them in systemd transient scopes (`systemd-run`) for strict CPU and memory resource limits. The picker panel and bar widget are thin clients that drive the service through the plugin's shared state. When the plugin is disabled or Noctalia exits, the service's `onExit` hook terminates every running `mpvpaper` instance — including frozen or paused ones — so no orphan processes remain.
