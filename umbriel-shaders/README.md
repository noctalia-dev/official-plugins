# Umbriel Shaders

Browse the [community shader catalogue](https://github.com/noctalia-dev/community-umbriel-shaders)
and apply shaders to Umbriel's effect and animation slots from Noctalia.

## Plugin

Manifest ID: `barrulus/umbriel-shaders`.

- `shaders` — the panel.
- `shaders-bar` — bar widget that opens the panel.
- `open` — control-center shortcut to the panel.

```sh
noctalia msg panel-toggle barrulus/umbriel-shaders:shaders
```

## Requirements

- Noctalia with plugin API 43 or later.
- `umbriel` on Noctalia's `PATH`, with the preset effects API and `umbriel config validate --json`.

## Setup

The plugin writes one file, `~/.config/umbriel/noctalia-shaders.toml`, and keeps shader
files next to it in `~/.config/umbriel/noctalia-shaders/`. Umbriel loads it once your
configuration includes it:

```toml
[include.optional]
files = ["noctalia-shaders.toml"]
```

The panel offers **Add for me**, which saves `config.toml.bak`, adds the file to your
`[include.optional]` table (or creates the table), and keeps the change only if
`umbriel config validate` reports nothing new. **Add for me** overwrites any existing
`config.toml.bak`. If your configuration is managed by Nix or home-manager, add the line
yourself.

A custom `umbriel -c` configuration is not supported by the setup check, which reads
`~/.config/umbriel/config.toml`. The workaround is to include the generated file by absolute
path (`~/.config/umbriel/noctalia-shaders.toml`) from that configuration. The panel will
still show the setup banner; use **Copy** or ignore it.

## Usage

- **Slots** lists every destination: cursor, border, window, screen and the animation
  events. **Change** opens Browse filtered to that slot; **Clear** removes the shader.
- **Details** on an animation slot overrides its duration and curve. Leave a field empty
  to use the shader's own value. Timing overrides stay with the slot when you change its
  shader; clear them by emptying the fields and saving.
- **Details** on Border and Window adds per-application rules: pick an open application,
  then a shader or **No effect**. Rules match the exact app ID and cover all its windows.
- **Browse** searches the catalogue. Each card has one button per slot the shader supports.
- **Import GLSL** copies a standalone `.glsl` file (up to 256 KiB) into your library for one
  slot. The file must define that slot's entry point (`cursor`, `border`, `window`,
  `screen` or `animation`). Imported shaders appear first in Browse and work offline.
- **Families** applies a coordinated set of shaders in one step.
- **Undo** reverts the last change. **Clear all** empties the generated file.

Every change downloads any missing files, rewrites the generated file, and asks
`umbriel config validate` whether anything new is wrong. If so, the previous file is put
back and the message is shown. Umbriel reloads the file by itself.

Your own `config.toml` is applied after the generated file, so anything you set there —
an `[effects]` selector, animation timing, a window rule — takes precedence. If a slot
does not change, check your own configuration for the same key.

## Upgrading from 0.6

If you upgraded without pressing **Restore original**, run
`umbriel config-replace "$HOME/.config/umbriel/config.toml"` (or restart Umbriel) so it
stops watching the 0.6 wrapper file.

## Downloads and stored data

The catalogue is read from the `catalogue` branch of
`noctalia-dev/community-umbriel-shaders` and cached for a day; **Refresh** fetches it now.
Shader files and previews are downloaded from `raw.githubusercontent.com` at the
catalogue's pinned commit. Umbriel compiles and runs the downloaded GLSL when its effect
is used.

The plugin data directory holds `selection.json`, the cached catalogue and previews.

## Removing the plugin

Selections stay active after the plugin is disabled. Use **Clear all** first, or remove
the include line from your `config.toml`.
