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

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `video_directory` | `folder` | *(empty)* | Folder scanned for wallpaper videos; defaults to `~/Videos` when empty. |
| `mute` | `bool` | `true` | Starts video wallpapers muted. |
| `hardware_decode` | `bool` | `true` | Uses `mpv` hardware decoding. |
| `auto_pause` | `bool` | `true` | Pauses playback while a fullscreen window covers the wallpaper. |
| `mpv_options` | `string` | *(empty)* | Additional space-separated `mpv` options. |
| `glyph` | `glyph` | `movie` | Bar widget icon. |

## Notes

A headless service supervises one long-lived helper process (`supervisor.sh`) that owns
every `mpvpaper` instance, one per output. The picker panel and bar widget are thin
clients that drive the service through the plugin's shared state. When the plugin is
disabled or Noctalia exits, the supervisor and all `mpvpaper` instances are torn down
together.
