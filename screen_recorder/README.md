# Screen Recorder

Screen Recorder records the current screen with `gpu-screen-recorder`. It also
supports a replay buffer that can be started, stopped, and saved from the bar or
Control Center.

## Plugin

| Field | Value |
| --- | --- |
| ID | `noctalia/screen_recorder` |
| Entries | Service: `service`; bar widget: `recorder`; shortcut: `toggle` |

## Requirements

Install `gpu-screen-recorder` on `PATH`, or install the Flatpak app
`com.dec05eba.gpu_screen_recorder`. Portal capture also requires
`xdg-desktop-portal` and one supported backend, such as
`xdg-desktop-portal-wlr`, `xdg-desktop-portal-hyprland`,
`xdg-desktop-portal-gnome`, or `xdg-desktop-portal-kde`.

- **[gpu-screen-recorder](https://git.dec05eba.com/gpu-screen-recorder/about/)** — Hardware-accelerated screen recording

Recordings are saved to the configured output directory. When the directory is
empty, the plugin uses `~/Videos/Recordings`.

## Usage

The headless `service` owns recording and replay processes for the whole
session. The `recorder` bar widget and `toggle` Control Center shortcut mirror
the service state and send commands through shared plugin state.

Widget controls:

| Action | Behavior |
| --- | --- |
| Left click | Start or stop recording. |
| Right click | Start the replay buffer, stop a pending replay buffer, or save an active replay. |
| Middle click | Save an active replay buffer. |

Shortcut controls:

| Action | Behavior |
| --- | --- |
| Left click | Toggle recording. |
| Right click | Toggle the replay buffer. |

Replay controls are available only when `replay_enabled` is true.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `video_source` | `select` | `portal` | Capture `focused`, `portal`, or `region`. |
| `directory` | `folder` | `~/Videos/Recordings` | Output folder, falling back to `~/Videos/Recordings`. |
| `filename_pattern` | `string` | `recording_%Y%m%d_%H%M%S` | Date-format filename pattern without extension. |
| `frame_rate` | `int` | `60` | Capture frame rate from 1 to 240. |
| `video_codec` | `select` | `h264` | Video codec: `h264`, `hevc`, `av1`, `vp8`, or `vp9`. |
| `quality` | `select` | `very_high` | GPU Screen Recorder quality preset. |
| `resolution` | `string` | `original` | `original` or a size like `1920x1080`. |
| `audio_source` | `select` | `default_output` | Audio source: output, input, both, or none. |
| `audio_codec` | `select` | `opus` | Audio codec: `opus`, `aac`, or `flac`. |
| `show_cursor` | `bool` | `true` | Includes the cursor in recordings. |
| `color_range` | `select` | `limited` | Uses limited or full color range. |
| `copy_to_clipboard` | `bool` | `false` | Copies the saved recording URI to the clipboard. |
| `hide_inactive` | `bool` | `false` | Hides the bar widget while idle. |
| `replay_enabled` | `bool` | `false` | Enables replay-buffer controls. |
| `replay_duration` | `int` | `30` | Replay buffer duration in seconds. |
| `replay_storage` | `select` | `ram` | Stores replay data in RAM or on disk. |
| `restore_portal` | `bool` | `false` | Asks GPU Screen Recorder to restore the portal session. |

## IPC

Recording runs in a headless **service**, which is a singleton with no output, so
the IPC target is always `all`:

```sh
noctalia msg plugin noctalia/screen_recorder:service all start
noctalia msg plugin noctalia/screen_recorder:service all stop
noctalia msg plugin noctalia/screen_recorder:service all toggle
noctalia msg plugin noctalia/screen_recorder:service all replay-start
noctalia msg plugin noctalia/screen_recorder:service all replay-stop
noctalia msg plugin noctalia/screen_recorder:service all replay-toggle
noctalia msg plugin noctalia/screen_recorder:service all replay-save
```

### Capture source override

`start` and `replay-start` accept an optional payload that overrides the
`video_source` setting for that capture: `focused`, `portal`, or `region`. Any
other value is ignored and the configured source is used.

```sh
noctalia msg plugin noctalia/screen_recorder:service all start focused
noctalia msg plugin noctalia/screen_recorder:service all start portal
noctalia msg plugin noctalia/screen_recorder:service all replay-start region
```

Here `all` is the IPC target (which instance receives the event) and the trailing
word is the capture source — two separate fields.
