# Image on Panel

Image on Panel adds a customizable bar widget that renders any local image directly on your Noctalia bar with configurable dimensions and corner rounding.

## Plugin

| Field | Value |
| --- | --- |
| ID | `justadux/image-on-panel` |
| Entry | Bar widget: `image` |

## Usage

Add the `image` widget to a bar from Noctalia's widget picker. Open the widget settings and select a local image file in `path` to display it on the bar.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `path` | `file` | `""` | Path to an image file to display on the bar. |
| `size` | `int` | `24` | Width and height of the image on the bar in pixels (`12`–`64`). |
| `radius` | `int` | `6` | Corner rounding in pixels (`0`–`32`). |
