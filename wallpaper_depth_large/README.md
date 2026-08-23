# Wallpaper Depth

Wallpaper Depth generates a foreground mask for each image wallpaper, allowing
Noctalia desktop widgets to pass behind nearby scenery.

Depth estimation runs locally with
[Depth Anything V2 Small](https://huggingface.co/onnx-community/depth-anything-v2-small).
Wallpapers are never uploaded.

## Plugin

| Field | Value |
| --- | --- |
| ID | `noctalia/wallpaper_depth` |
| Entries | Service: `service`; panel: `manager` |

## Requirements

Install `python3` version 3.11–3.14 with `venv` and `pip` support. Initial setup
requires network access, and shell offline mode must be disabled.

From the plugin panel, setup creates an isolated Python environment in the
plugin data directory and downloads the 99 MB Apache-2.0 Depth Anything V2
Small ONNX model from Hugging Face. The runtime contains pinned versions of
NumPy, ONNX Runtime, and Pillow; it does not modify the system Python
environment.

## Usage

1. Open the **Wallpaper Depth** panel, or toggle it from a terminal:

   ```sh
   noctalia msg panel-toggle noctalia/wallpaper_depth:manager
   ```

2. Select **Install model** and wait for setup to finish.
3. Apply an image wallpaper to each desired output.
4. Select **Generate masks**, or leave **Generate automatically** enabled.
5. Adjust **Foreground threshold** and **Edge feather** in the plugin settings
   when the default mask does not match the scene.

The panel reports generation state for every connected output. **Clear cache**
removes saved depth maps and masks; the plugin regenerates them when needed.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `auto_generate` | `bool` | `true` | Regenerates masks when a wallpaper or mask parameter changes. |
| `threshold` | `int` | `50` | Normalized depth cutoff from 0–100. Lower values place more of the scene in front of desktop widgets. |
| `feather` | `int` | `8` | Soft-transition width around the depth cutoff, from 0–50. |

## How it works

The service processes each output independently. It preserves the wallpaper's
aspect ratio during inference, normalizes the relative depth prediction, and
refines it against the source image before applying the configured threshold
and feather. The resulting mask is restored to the wallpaper's original
resolution and registered with Noctalia for that output.

Depth predictions are cached separately from masks, so changing threshold or
feather can reuse the expensive model result. Cache entries are keyed by the
wallpaper contents, model revision, and processing version, and old entries are
pruned automatically.

## Licensing and privacy

The plugin is MIT-licensed. Depth Anything V2 Small is downloaded at setup time
under the Apache-2.0 license. Model inference, depth caches, and generated masks
remain in the local plugin data directory; only the model download contacts
Hugging Face.
