# Video Wallpaper

Animated and video wallpapers for Noctalia, powered by
[mpvpaper](https://github.com/GhostNaN/mpvpaper).

Noctalia does not decode video itself. This plugin runs `mpvpaper`, which draws its own
`wlr-layer-shell` background surface, and asks Noctalia to drop its wallpaper on the
outputs you assign a video to — so the video shows through, with the bar and dock still
drawn above it.

## Requirements

- `mpvpaper` (which pulls in `mpv`). `mpv` is also used to render the picker thumbnails.

The plugin works on `wlr-layer-shell` compositors (Niri, Hyprland, Sway, Mango).

## Usage

1. Set **Video directory** in the plugin settings (defaults to `~/Videos`).
2. Add the **Video Wallpaper** bar widget, or open the picker with
   `noctalia msg panel-toggle noctalia/mpvpaper:picker`.
3. Choose a target output (or **All outputs**), then click a video to apply it.
   Use **Stop** to restore Noctalia's own wallpaper on that output.

Assignments persist across restarts. Supported files: `mp4`, `webm`, `mkv`, `mov`, `gif`.

## How it works

A headless service supervises one long-lived helper process (`supervisor.sh`) that owns
every `mpvpaper` instance, one per output. The picker panel and bar widget are thin
clients that drive the service through the plugin's shared state. When the plugin is
disabled or Noctalia exits, the supervisor and all `mpvpaper` instances are torn down
together.
