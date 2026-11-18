# Wallhaven

Browse [Wallhaven](https://wallhaven.cc), preview a wallpaper at full size, then save it to your Noctalia wallpaper directory and apply it.

## Plugin

| Field | Value |
| --- | --- |
| ID | `noctalia/wallhaven` |
| Entries | Panel: `browser`; bar widget: `wallhaven`; shortcut: `shortcut` |

## Requirements

- `python3` — runs `crop_stream.py`, which draws the draggable crop box over the preview.
- `imagemagick` — ImageMagick 7 (`magick`) or ImageMagick 6 (`convert` + `identify`) for the Fit preview and crop.

## Usage

1. Enable the plugin in Settings → Plugins.
2. Add the `wallhaven` bar widget, the control center shortcut, or run:

   ```sh
   noctalia msg panel-toggle noctalia/wallhaven:browser
   ```

3. Search by tags, adjust category and purity filters, filter by resolution or aspect ratio (including your focused monitor's resolution and aspect ratio), paginate results (or click the page counter, type a page number, and press Enter), then click a wallpaper to preview it. **Apply** saves the full-resolution image and sets it as your wallpaper; **Back** discards it.
4. Toggle **Fit** to show the full image with a highlighted monitor-aspect box. Drag the box over the part you want to keep, then press **Apply**: the plugin crops that area and saves it at the focused monitor's resolution. The box is capped at the monitor's native size, so on larger images it can be moved in both directions. Toggle **Fit** off to return to the normal full-image preview. A fitted Apply targets the focused output, so the crop matches the monitor it was chosen on; a normal Apply keeps the existing all-monitor behavior.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `api_key` | `string` | *(empty)* | Optional Wallhaven API key for higher rate limits and NSFW access. |
| `download_dir` | `folder` | *(empty)* | Optional download override; defaults to your configured wallpaper directory. |

Thumbnails are cached under `$XDG_STATE_HOME/noctalia/wallhaven/thumbs` (`~/.local/state/noctalia/wallhaven/thumbs` by default). The full image being previewed is kept there too, until you apply or discard it; one left behind by a crash or reload is removed the next time the panel opens. With **Fit** enabled, the saved file is the selected crop at the monitor resolution; the original full-size download is only used for the preview and is removed after a successful save. The Fit preview runs `crop_stream.py` as a short-lived helper and keeps its socket, state file, and PID file under `$XDG_STATE_HOME/noctalia/wallhaven/crop`. The socket is created with mode `0600` and the helper accepts only connections from the same user. The helper exits when the preview closes (or after ten minutes without a client) and removes them; leftovers from a crash are swept the next time the panel opens. Downloads write a temporary `<name>.part` file in the cache while they run; it is removed on success and swept at panel open if a crash leaves it behind. The plugin reads its settings and the configured wallpaper directory, and writes saved wallpapers there.

## Notes

- Requires plugin API 43.
- The panel close button respects `shell.show_close_buttons`; if the setting is missing, the button remains visible.
- Requires network access to `wallhaven.cc` for the API and images (`[shell].offline_mode` must be off).
- NSFW results require a Wallhaven API key.
- Normal applies use `noctalia.setWallpaper(path)` (all outputs); fitted applies use the focused output connector so the selected crop is not stretched onto monitors with a different shape.
