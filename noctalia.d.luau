--!strict
-- Type definitions for the Noctalia plugin API (plugin_api 30).
--
-- luau-lsp *definition file*: it declares the host-injected globals (noctalia.*,
-- barWidget.*, shortcut.*, launcher.*, desktopWidget.*, panel.*, ui.*) so authors
-- get autocomplete and typo diagnostics. Annotations are a runtime no-op.
-- See README.md ("Editor setup") for pointing luau-lsp at this file.
--
-- Prop tables are exhaustive: the host logs and skips any prop not listed here.
-- "API n" marks the plugin_api level a member requires.

-- ── Shared value shapes ──────────────────────────────────────────────────────

export type CommandResult = {
  exitCode: number,
  stdout: string,
  stderr: string,
  timedOut: boolean,
  stdoutTruncated: boolean,
  stderrTruncated: boolean,
}

export type HttpRequest = {
  url: string,
  method: string?, -- defaults to "GET"
  headers: { string }?, -- each entry is a full "Header: value" line
  body: string?,
  basic_username: string?,
  basic_password: string?,
  follow_redirects: boolean?,
  -- Disables origin certificate and hostname verification; trusted endpoints only. API 7.
  allow_insecure_tls: boolean?,
}

export type HttpResponse = {
  ok: boolean, -- transport success (not the HTTP status)
  status: number,
  body: string,
}

export type HttpStreamResult = {
  ok: boolean, -- transport success (not the HTTP status)
  status: number, -- HTTP status code (0 when ok is false)
}

export type HttpStreamHandle = {
  stop: () -> (), -- cancel the stream; idempotent, suppresses onClose
}

export type Output = {
  name: string,
  description: string,
  width: number,
  height: number,
  x: number,
  y: number,
  scale: number,
  focused: boolean,
}

export type WallpaperMask = {
  path: string,
  wallpaperPath: string,
}

export type PanelContextMenuAction = {
  kind: "item"?, -- may be omitted for action rows
  id: string,
  label: string,
  enabled: boolean?, -- defaults to true
}

export type PanelContextMenuHeader = {
  kind: "header",
  label: string,
}

export type PanelContextMenuSeparator = {
  kind: "separator",
}

export type PanelContextMenuItem = PanelContextMenuAction | PanelContextMenuHeader | PanelContextMenuSeparator

export type PanelContextMenuRequest = {
  items: { PanelContextMenuItem },
  onActivate: string,
  context: (string | number | boolean)?,
  maxVisible: number?, -- defaults to 12, valid range 1..30
}

-- A tooltip row: { key, value } or the positional array form { key, value }.
export type TooltipRow = { key: string?, value: string? }

export type LauncherResult = {
  id: string?,
  title: string?,
  subtitle: string?,
  glyph: string?,
  icon: string?,
  badge: string?,
  category: string?, -- must match a [[launcher_provider.category]] label
  presentation: string?,
  query: string?, -- on activate, set this provider's query to this sub-query (host adds the prefix)
  score: number?,
}

export type SystemStats = {
  sampledAtMs: number?, -- epoch ms of the latest aggregate sample (API 16)
  -- Absent sensors are nil rather than 0, so "no probe" is distinguishable from "idle".
  cpu: { usagePercent: number, tempC: number?, freqMhz: number?, maxFreqMhz: number? },
  ram: { usagePercent: number, usedMb: number, totalMb: number },
  swap: { usedMb: number, totalMb: number },
  gpu: { tempC: number?, usagePercent: number?, vramUsedBytes: number?, vramTotalBytes: number? },
  net: {
    rxBytesPerSec: number,
    txBytesPerSec: number,
    interfaces: { [string]: { rxBytesPerSec: number, txBytesPerSec: number } },
  },
  loadAvg: { number }, -- 1, 5 and 15 minute averages
}

export type DiskMount = {
  path: string,
  source: string,
  filesystem: string,
}

export type DiskStats = {
  usagePercent: number,
  totalBytes: number,
  freeBytes: number,
  availableBytes: number,
}

-- Noctalia provides Luau's built-in `require(path: string): any` for explicit relative `.luau` modules (API 22).

-- ── noctalia.* - shared across every entry type ──────────────────────────────

export type NoctaliaState = {
  set: (key: string, value: any) -> (),
  get: (key: string) -> any,
  watch: (key: string, callback: (value: any) -> ()) -> (),
}

export type NoctaliaJson = {
  decode: (str: string) -> (any, string?), -- value, or (nil, err)
  encode: (value: any, pretty: boolean?) -> (string?, string?),
}

export type NoctaliaString = {
  trim: (s: string) -> string,
  urlEncode: (s: string) -> string,
  urlDecode: (s: string) -> string,
}

-- API 20. Paths resolve like the filesystem APIs. `load` returning true means the
-- request was accepted, not that decoding succeeded; at most eight loads may be
-- pending. Names and pending callbacks are released when this runtime reloads.
export type NoctaliaSound = {
  load: (name: string, path: string, onLoaded: (ok: boolean, error: string?) -> ()) -> boolean,
  play: (name: string) -> (),
}

export type Noctalia = {
  log: (msg: string) -> (),

  -- Subprocess. A string runs through /bin/sh -c; an argv table (API 24) executes
  -- the program directly. With no callback, runAsync is a detached fire-and-forget
  -- launch; timeoutMs is clamped to [50, 60000].
  runAsync: (cmdOrArgv: string | { string }, onResult: ((result: CommandResult) -> ())?, timeoutMs: number?) -> boolean,
  runStream: (cmd: string, onLine: (line: string) -> ()) -> boolean,
  runInTerminal: (cmd: string) -> boolean,
  commandExists: (name: string) -> boolean,
  -- onResult(true) iff a running process command line matches all needles.
  processMatches: (onResult: (matched: boolean) -> (), ...string) -> boolean,
  flatpakAppInstalled: (appId: string) -> boolean,
  portalAvailable: () -> boolean,

  -- Outputs / display.
  focusedOutputName: () -> string?,
  outputs: () -> { Output },
  isDarkMode: () -> boolean,
  -- Effective shell config by dotted path ("bar.main.position", "shell.offline_mode").
  -- Array indices are zero-based ("bar.order[0]"); nil when the path matches nothing. API 26.
  getSetting: (path: string) -> any,

  -- Resolves an app id (desktop-entry id / StartupWMClass), or a raw icon name when no
  -- entry matches, to an icon path for ui.image. nil when nothing resolves.
  appIconPath: (appIdOrIconName: string, sizePx: number?) -> string?,

  -- Wallpaper. setWallpaper(path) targets all outputs; setWallpaper(connector, path) targets one.
  setWallpaperEnabled: (connector: string, enabled: boolean) -> (),
  setWallpaper: (connectorOrPath: string, path: string?) -> (),
  wallpaperDirectory: () -> string?,
  -- Source-aligned output mask: 0 keeps desktop widgets visible, 255 erases them to
  -- reveal the wallpaper. API 25.
  wallpaperPath: (connector: string) -> string?,
  setWallpaperMask: (connector: string, mask: WallpaperMask?) -> (),

  togglePanel: (panelId: string) -> (), -- "author/plugin:panel"
  -- Opens the settings window at this plugin's settings; no-op without settings. API 15.
  openSettings: () -> (),
  -- The callback receives the canonical #RRGGBB color, or nil when cancelled.
  openColorPicker: (initialColor: string, onClose: (color: string?) -> ()) -> boolean,

  notify: (title: string, body: string?) -> (),
  notifyError: (title: string, body: string?) -> (),

  copyToClipboard: (text: string, mimeType: string) -> boolean,
  clipboardText: () -> string?, -- nil when empty or non-text
  getenv: (name: string) -> string?,
  expandPath: (path: string) -> string,
  formatTime: (pattern: string, unixSeconds: number?, timezone: string?) -> string,
  timeFormat: () -> string, -- [shell].time_format, e.g. "{:%H:%M}" (API 19)
  dateFormat: () -> string, -- [shell].date_format, e.g. "%A, %x" (API 19)
  -- True when `name` is empty (system local) or names a zone in the active database. API 19.
  isValidTimezone: (name: string) -> boolean,
  nowMs: () -> number, -- the only sub-second clock; formatTime and os.time are whole-second (API 12)

  -- System monitor. nil when [system.monitor] is disabled. The first systemStats call
  -- opts this plugin into its optional CPU/GPU probes. API 12.
  systemStats: () -> SystemStats?,
  -- Per-core usage in /proc/stat order; nil until the first delta lands. Offline cores are
  -- absent, so length can change and an index is not a core id.
  cpuCores: () -> { number }?,
  -- Physical block-device filesystems, deduped by source, sorted by mount path. API 16.
  diskMounts: () -> { DiskMount },
  -- statvfs snapshot for an absolute or ~/ path; the path is retained for sampling. API 16.
  diskStats: (path: string) -> DiskStats?,

  setUpdateInterval: (ms: number) -> (), -- update() tick rate, clamped to >= 16ms

  -- Filesystem (paths resolve ~ -> $HOME, absolute verbatim, else plugin-relative).
  readFile: (path: string) -> (string?, string?), -- contents, or (nil, err)
  readFileAsync: (path: string, onResult: (contents: string?, err: string?) -> ()) -> boolean, -- API 23
  writeFile: (path: string, contents: string) -> (boolean, string?),
  mkdirAll: (path: string) -> (boolean, string?), -- like mkdir -p; existing dir is success
  removeFile: (path: string) -> (boolean, string?), -- files only, refuses directories
  renameFile: (from: string, to: string) -> (boolean, string?),
  fileExists: (path: string) -> boolean,
  fileInfo: (path: string) -> ({ size: number, mtime: number, isDir: boolean }?, string?),
  listDir: (path: string) -> ({ string }?, string?),
  pluginDir: () -> string?,
  -- Per-plugin persistent data dir, created on demand; survives updates, honors
  -- NOCTALIA_STATE_HOME. Use for durable data (state is in-memory only).
  pluginDataDir: () -> (string?, string?),

  -- Registers a font file so its family works in setFont / a label's fontFamily.
  -- Returns the family name, or (nil, err); visible to every surface once loaded.
  loadFont: (path: string) -> (string?, string?),

  -- Translation against the plugin's own translations/<lang>.json.
  tr: (key: string, subst: { [string]: string | number | boolean }?) -> string,
  trp: (key: string, count: number, subst: { [string]: string | number | boolean }?) -> string,

  -- HTTP (honors shell.offline_mode; download dest resolves like readFile).
  http: (req: HttpRequest, onResponse: (response: HttpResponse) -> ()) -> boolean,
  -- Long-lived stream (e.g. SSE). onLine fires per line (CR trimmed); onClose fires once
  -- unless stopped through the handle. Non-2xx bodies stream to onLine and the status
  -- arrives in onClose. Cancelled on script reload; nil when it could not start. API 4.
  httpStream: (
    req: HttpRequest,
    onLine: (line: string) -> (),
    onClose: (result: HttpStreamResult) -> ()
  ) -> HttpStreamHandle?,
  download: (url: string, destPath: string, onDone: (success: boolean) -> ()) -> boolean,

  fuzzyScore: (pattern: string, text: string) -> number?, -- nil if no match

  getConfig: (key: string) -> any, -- string | number | boolean | {string} | {[string]: string} | nil

  state: NoctaliaState,
  sound: NoctaliaSound,
  json: NoctaliaJson,
  string: NoctaliaString,
}

declare noctalia: Noctalia

-- ── ui.* - declarative control tree (bar widgets, desktop widgets, panels) ───

-- One node of a ui.* tree.
export type UiNode = {
  type: string,
  props: { [string]: any },
  children: { UiNode },
}

-- A palette role ("primary", "on_surface"), a role with alpha ("primary/0.6",
-- resolved live against the palette), or a hex value ("#rrggbb" / "#rrggbbaa").
export type UiColor = string

-- A callback prop takes the name of a plugin global, or a function (API 9) that is
-- render-scoped: re-rendering replaces it, and an event on a node the current tree no
-- longer contains does nothing. An empty name counts as unset. Every argument arrives
-- as a string, for named handlers and closures alike.
export type UiClickHandler = string | (() -> ())
-- state is "true" on enter and "false" on leave; key is the node's `key` ("" when unset).
-- Only the innermost hovered node reports, and every "true" is matched by a "false".
export type UiHoverHandler = string | ((state: string, key: string) -> ())
export type UiChangeHandler = string | ((value: string) -> ())
export type UiSelectHandler = string | ((index: string, text: string) -> ())
export type UiScrollHandler = string | ((offset: string, maxOffset: string) -> ())
-- Pointer position normalized to the graph's own box, "0.0000".."1.0000", 0,0 top-left.
export type UiPointerHandler = string | ((normX: string, normY: string) -> ())
export type UiDropHandler = string | ((payload: string, value: string) -> ())

-- Common to every node. `opacity` is a group opacity: it fades children too, so use a
-- translucent `fill` for a translucent background. `key` gives a child stable identity
-- across renders (keeps input text, hover state, and closures aligned with their row).
export type UiCommonProps = {
  key: string?,
  width: number?,
  height: number?,
  flexGrow: number?,
  opacity: number?,
  visible: boolean?,
}

-- ui.column / ui.row. Children stretch across the cross axis unless `align` says otherwise.
-- onClick makes the whole container a click target and joins the tab order (Enter/Space);
-- a container with only onHover passes clicks through to an enclosing target.
export type UiFlexProps = {
  key: string?,
  width: number?,
  height: number?,
  flexGrow: number?,
  opacity: number?,
  visible: boolean?,
  gap: number?,
  padding: number?,
  paddingH: number?,
  paddingV: number?,
  align: ("start" | "center" | "end" | "stretch")?,
  justify: ("start" | "center" | "end" | "space_between")?,
  fill: UiColor?,
  radius: number?,
  border: UiColor?,
  borderWidth: number?,
  minWidth: number?,
  minHeight: number?,
  onClick: UiClickHandler?,
  onHover: UiHoverHandler?,
}

-- ui.box. Leaf node: it takes no children (use a column/row for content).
export type UiBoxProps = {
  key: string?,
  width: number?,
  height: number?,
  flexGrow: number?,
  opacity: number?,
  visible: boolean?,
  fill: UiColor?,
  radius: number?,
  border: UiColor?,
  borderWidth: number?,
  softness: number?,
  onClick: UiClickHandler?,
  onHover: UiHoverHandler?,
}

-- ui.label. Unset text props inherit the host defaults (in a bar, the bar's or widget's
-- font_family/font_weight and scale). fontFamily needs noctalia.loadFont first.
-- baseline "pictographic" centers art/icon fonts anchored at the ink top.
export type UiLabelProps = {
  key: string?,
  width: number?,
  height: number?,
  flexGrow: number?,
  opacity: number?,
  visible: boolean?,
  text: string?,
  fontSize: number?,
  color: UiColor?,
  fontWeight: ("thin" | "light" | "normal" | "medium" | "semibold" | "bold" | "heavy")?,
  fontFamily: string?,
  baseline: ("text" | "textFixedHeight" | "inkCentered" | "pictographic")?,
  maxWidth: number?,
  maxLines: number?,
  textAlign: ("start" | "center" | "end")?,
}

-- ui.markdown. Read-only block; re-parsed only when text or the surface scale changes. API 21.
export type UiMarkdownProps = {
  key: string?,
  width: number?,
  height: number?,
  flexGrow: number?,
  opacity: number?,
  visible: boolean?,
  text: string?,
}

-- ui.glyph. `name` is a Tabler/Nerd-Font glyph; `size` is a glyph size in px.
export type UiGlyphProps = {
  key: string?,
  width: number?,
  height: number?,
  flexGrow: number?,
  opacity: number?,
  visible: boolean?,
  name: string?,
  size: number?,
  color: UiColor?,
}

-- ui.image. Local files only: download remote previews first, then pass the saved path.
export type UiImageProps = {
  key: string?,
  width: number?,
  height: number?,
  flexGrow: number?,
  opacity: number?,
  visible: boolean?,
  path: string?, -- plugin-relative, ~, or absolute
  radius: number?,
  fit: ("contain" | "cover" | "stretch")?,
  border: UiColor?,
  borderWidth: number?,
  onClick: UiClickHandler?,
  onHover: UiHoverHandler?,
}

export type UiSeparatorProps = {
  key: string?,
  width: number?,
  height: number?,
  flexGrow: number?,
  opacity: number?,
  visible: boolean?,
  thickness: number?,
  color: UiColor?,
  spacing: number?,
  orientation: ("auto" | "horizontal" | "vertical")?,
}

-- ui.spacer: flexible filler, sized with flexGrow.
export type UiSpacerProps = UiCommonProps

export type UiProgressProps = {
  key: string?,
  width: number?,
  height: number?,
  flexGrow: number?,
  opacity: number?,
  visible: boolean?,
  progress: number?, -- 0..1
  fill: UiColor?,
  track: UiColor?,
  radius: number?,
}

-- ui.button. Setting only `glyph` clears a retained button's previous text. `tooltip`
-- shows in bar widgets and panels, never on desktop widgets; dropping it clears it.
-- In bar widgets a button hugs its content unless sized with width/height/controlSize.
export type UiButtonProps = {
  key: string?,
  width: number?,
  height: number?,
  flexGrow: number?,
  opacity: number?,
  visible: boolean?,
  text: string?,
  glyph: string?,
  fontSize: number?,
  glyphSize: number?,
  variant: ("default" | "primary" | "secondary" | "destructive" | "outline" | "ghost")?,
  contentAlign: ("start" | "center" | "end")?,
  controlSize: ("sm" | "md" | "lg")?, -- 32 / 38 / 44px tiers; `height` wins when both are set
  tooltip: string?,
  enabled: boolean?,
  selected: boolean?,
  onClick: UiClickHandler?,
  onRightClick: UiClickHandler?, -- the only place panel.openContextMenu may be called
  onHover: UiHoverHandler?,
}

-- ui.graph. Takes no clicks. The pointer callbacks (API 29) are coalesced on one shared
-- stream, so the newest event wins and a leave never arrives ahead of a position it
-- followed. Every entered graph reports its leave, including when the graph is dropped or
-- rewired - but that teardown leave only reaches a *named* handler, since a closure from
-- the render that dropped the graph is already superseded.
export type UiGraphProps = {
  key: string?,
  width: number?,
  height: number?,
  flexGrow: number?,
  opacity: number?,
  visible: boolean?,
  values: { number }?, -- 0..1, clamped
  values2: { number }?,
  color: UiColor?,
  color2: UiColor?,
  lineWidth: number?,
  fillOpacity: number?,
  onPointerMove: UiPointerHandler?,
  onPointerLeave: UiClickHandler?,
}

-- ui.input (panels only; skipped with a warning in the bar). Uncontrolled: `value` seeds
-- the field once, then the host owns the text - keep a stable `key` so edits survive a
-- re-render, and read them through onChange/onSubmit. `focus` grabs the keyboard when the
-- control is *created*, never on a later render; a fresh `key` focuses again.
-- multiline and password are mutually exclusive; multiline submits on Ctrl+Enter, or on
-- Enter with submitOnEnter (Shift+Enter then inserts the newline).
export type UiInputProps = {
  key: string?,
  width: number?,
  height: number?,
  flexGrow: number?,
  opacity: number?,
  visible: boolean?,
  value: string?,
  placeholder: string?,
  fontSize: number?,
  controlSize: ("sm" | "md" | "lg")?,
  password: boolean?,
  multiline: boolean?,
  submitOnEnter: boolean?, -- API 21
  frameVisible: boolean?, -- false hides the native background/border, keeps editing (API 27)
  focus: boolean?,
  enabled: boolean?,
  onChange: UiChangeHandler?,
  onSubmit: UiChangeHandler?,
}

-- ui.select (panels only; no dropdowns inside a persistent panel). Value-driven:
-- pass selectedIndex on every render and update it from onChange, which receives the
-- selected index and its text.
export type UiSelectProps = {
  key: string?,
  width: number?,
  height: number?,
  flexGrow: number?,
  opacity: number?,
  visible: boolean?,
  options: { string }?,
  selectedIndex: number?,
  placeholder: string?,
  controlSize: ("sm" | "md" | "lg")?,
  enabled: boolean?,
  onChange: UiSelectHandler?,
}

-- ui.slider. Value-driven, but `value` is re-applied only while not dragging, so
-- re-rendering mid-drag with a draft value is safe. onChange reports every change
-- (coalesced); onDragEnd fires with no arguments when the interaction ends - pointer
-- release and keyboard adjustment. The wheel does not adjust plugin sliders.
export type UiSliderProps = {
  key: string?,
  width: number?,
  height: number?,
  flexGrow: number?,
  opacity: number?,
  visible: boolean?,
  min: number?,
  max: number?,
  step: number?,
  value: number?,
  controlSize: ("sm" | "md" | "lg")?,
  enabled: boolean?,
  onChange: UiChangeHandler?,
  onDragEnd: UiClickHandler?,
}

-- ui.toggle. Value-driven; onChange receives "true" / "false".
export type UiToggleProps = {
  key: string?,
  width: number?,
  height: number?,
  flexGrow: number?,
  opacity: number?,
  visible: boolean?,
  checked: boolean?,
  enabled: boolean?,
  onChange: UiChangeHandler?,
}

-- ui.scroll (panels only; skipped with a warning in the bar). Vertical scrolling
-- container with a column's layout props. stickToBottom, onScroll and
-- scrollToBottomRev are API 21.
export type UiScrollProps = {
  key: string?,
  width: number?,
  height: number?,
  flexGrow: number?,
  opacity: number?,
  visible: boolean?,
  gap: number?,
  padding: number?,
  paddingH: number?,
  paddingV: number?,
  align: ("start" | "center" | "end" | "stretch")?,
  justify: ("start" | "center" | "end" | "space_between")?,
  fill: UiColor?,
  radius: number?,
  border: UiColor?,
  borderWidth: number?,
  stickToBottom: boolean?, -- stay pinned to the bottom until the user scrolls away
  scrollToBottomRev: number?, -- jumps to the bottom on first sight and on every change
  onScroll: UiScrollHandler?,
}

-- ui.dragSource (panels only, API 5). Marks a subtree draggable: a grip glyph, or a whole
-- row through previewAncestor. dragType and payload are required - a missing, mistyped,
-- empty or over-limit value disables the control for that render. Limits: payload 16 KiB,
-- dragType 256 bytes.
export type UiDragSourceProps = {
  key: string?,
  width: number?,
  height: number?,
  flexGrow: number?,
  opacity: number?,
  visible: boolean?,
  gap: number?,
  padding: number?,
  paddingH: number?,
  paddingV: number?,
  align: ("start" | "center" | "end" | "stretch")?,
  justify: ("start" | "center" | "end" | "space_between")?,
  fill: UiColor?,
  radius: number?,
  border: UiColor?,
  borderWidth: number?,
  minWidth: number?,
  minHeight: number?,
  dragType: string, -- matched against a dropZone's `accepts`
  payload: string, -- opaque; first onDrop argument
  enabled: boolean?,
  tooltip: string?,
  previewAncestor: number?, -- integer 0..8 parent levels the ghost shows; 1 previews the row around a grip
  liftFromLayout: boolean?, -- remove the previewed row from layout while dragging
}

-- ui.dropZone (panels only, API 5). Flex container that accepts drops; accepts, value and
-- onDrop are required (`accepts = {}` accepts nothing). Nested zones resolve to the
-- deepest accepting zone, hitSlop zones first, closest wins. The host moves nothing: the
-- callback mutates the plugin's model and re-renders. Limits: value/onDrop/each accepts
-- entry 256 bytes, at most 16 accepts entries.
export type UiDropZoneProps = {
  key: string?,
  width: number?,
  height: number?,
  flexGrow: number?,
  opacity: number?,
  visible: boolean?,
  gap: number?,
  padding: number?,
  paddingH: number?,
  paddingV: number?,
  align: ("start" | "center" | "end" | "stretch")?,
  justify: ("start" | "center" | "end" | "space_between")?,
  fill: UiColor?,
  radius: number?,
  border: UiColor?,
  borderWidth: number?,
  minWidth: number?,
  minHeight: number?,
  accepts: { string }, -- drag types
  value: string, -- opaque; second onDrop argument
  onDrop: UiDropHandler,
  direction: ("column" | "row")?,
  enabled: boolean?,
  expandOnDrag: boolean?, -- a fixed-height zone animates to the dragged row's height
  hitSlop: number?, -- extra drag-only hit distance, without changing layout or clicks
}

-- Only column, row, scroll, dragSource and dropZone host children; the rest are leaves.
declare ui: {
  column: (props: UiFlexProps?, children: { UiNode }?) -> UiNode,
  row: (props: UiFlexProps?, children: { UiNode }?) -> UiNode,
  scroll: (props: UiScrollProps?, children: { UiNode }?) -> UiNode,
  dragSource: (props: UiDragSourceProps, children: { UiNode }?) -> UiNode,
  dropZone: (props: UiDropZoneProps, children: { UiNode }?) -> UiNode,
  box: (props: UiBoxProps?) -> UiNode,
  label: (props: UiLabelProps?) -> UiNode,
  markdown: (props: UiMarkdownProps?) -> UiNode,
  glyph: (props: UiGlyphProps?) -> UiNode,
  image: (props: UiImageProps?) -> UiNode,
  separator: (props: UiSeparatorProps?) -> UiNode,
  spacer: (props: UiSpacerProps?) -> UiNode,
  progress: (props: UiProgressProps?) -> UiNode,
  button: (props: UiButtonProps?) -> UiNode,
  graph: (props: UiGraphProps?) -> UiNode,
  input: (props: UiInputProps?) -> UiNode,
  select: (props: UiSelectProps?) -> UiNode,
  slider: (props: UiSliderProps?) -> UiNode,
  toggle: (props: UiToggleProps?) -> UiNode,
}

-- ── barWidget.* - [[widget]] presentation ────────────────────────────────────

declare barWidget: {
  setText: (text: string) -> (),
  setGlyph: (name: string) -> (),
  setImage: (path: string, watch: boolean?, width: number?, height: number?) -> (),
  setTooltip: (tooltip: (string | TooltipRow | { TooltipRow })?) -> (),
  clearTooltip: () -> (),
  -- family: a font family name (load a file with noctalia.loadFont first).
  -- baseline: "text" (default) | "textFixedHeight" | "inkCentered" | "pictographic".
  setFont: (family: string, baseline: string?) -> (),
  setColor: (role: string, mode: string?) -> (),
  setGlyphColor: (role: string, mode: string?) -> (),
  isVertical: () -> boolean,
  -- Connector of the output this widget instance's bar is on; per-instance, unlike
  -- noctalia.focusedOutputName(). nil when unknown.
  outputName: () -> string?,
  setVisible: (visible: boolean) -> (),
  -- Declarative alternative to setText/setGlyph: the tree replaces the built-in
  -- glyph/text row. ui.input/ui.select/ui.scroll are not supported in the bar.
  render: (tree: UiNode) -> (),
}

-- Gestures are configuration, not code: the user binds them per widget instance in
-- [widget.<id>.actions] (left, right, middle, back, forward, scroll_up, scroll_down,
-- scroll_left, scroll_right), and a binding wins over the matching callback. An action is
-- an IPC command ("media toggle"), `exec <command line>`, or `none`. Manifests declare
-- their own defaults in [widget.actions] (API 14).
--
-- Middle click is the one to know about: every widget defaults to
-- `middle = "settings-open-widget"`, so onMiddleClick does not fire until the manifest or
-- the user binds `middle = "none"`. Scroll has one extra gate: `enable_scroll = false`
-- turns onScroll off regardless of bindings.

-- ── shortcut.* - [[shortcut]] quick-toggle tile ──────────────────────────────

declare shortcut: {
  setLabel: (label: string) -> (),
  setIcon: (on: string, off: string?) -> (),
  setActive: (active: boolean) -> (),
  setEnabled: (enabled: boolean) -> (),
}

-- ── launcher.* - [[launcher_provider]] results ───────────────────────────────

declare launcher: {
  setResults: (query: string, results: { LauncherResult }) -> (),
  setQuery: (text: string) -> (), -- prefix + text (stays in provider); "" resets to root
}

-- ── desktopWidget.* - [[desktop_widget]] declarative UI ──────────────────────

declare desktopWidget: {
  render: (tree: UiNode) -> (),
  setWantsSecondTicks: (wants: boolean) -> (), -- run update() on second boundaries
  setNeedsFrameTick: (needs: boolean) -> (), -- deliver onFrameTick(deltaMs) every frame
}

-- ── panel.* - [[panel]] declarative UI ───────────────────────────────────────

declare panel: {
  render: (tree: UiNode) -> (),
  close: () -> (),
  -- Opens a native menu at the originating direct pointer callback; false outside a live
  -- one. onActivate receives (actionId, context) in the panel script. API 28.
  openContextMenu: (request: PanelContextMenuRequest) -> boolean,
  setWantsSecondTicks: (wants: boolean) -> (),
  setNeedsFrameTick: (needs: boolean) -> (), -- onFrameTick(deltaMs) while open (API 18)
}

-- ── Entry-point callbacks ────────────────────────────────────────────────────
--
-- Your entry defines the globals the host calls, as plain global functions - the
-- host only calls a callback if the entry defines it:
--
--   function update() end                       -- bar/desktop widget, service tick
--   function onIpc(event, payload) end          -- any entry (payload: string?)
--   function onClick() / onRightClick() end     -- shortcut, bar widget
--   function onMiddleClick() end                -- bar widget (see "Gestures" above)
--   function onHover(entered) end               -- bar widget pointer enter / leave
--   function onScroll(axis, steps, startsGesture) end -- bar widget scroll; axis is "vertical" | "horizontal",
--                                               -- steps is whole wheel detents (negative = up / left),
--                                               -- startsGesture is true only on the first step of a flick
--   function onQuery(text) / onActivate(id) end -- launcher provider
--   function onFrameTick(deltaMs) end           -- desktop widget, or open panel (API 18); after
--                                               -- setNeedsFrameTick(true), frames coalesced
--   function onAudioSpectrum(valuesCsv, stateCsv) end -- audio-reactive bar widget
--   function onOpen(context) / onClose() end    -- panel lifecycle
--   function onKey(chord, pressed) end          -- panel: a capture_keys chord, verbatim from the
--                                               -- manifest (API 13)
--   function onConfigChanged() end              -- service: settings changed; getConfig() is now new
--   function onEnable() end                     -- service: plugin explicitly enabled (API 17)
--   function onOutputsChanged() end             -- service: output set or geometry changed
--   function onExit(signal, reason) end         -- any entry teardown; signal is 0 normally, 2 SIGINT,
--                                               -- 15 SIGTERM; reason is "reload" | "disable" |
--                                               -- "uninstall" | "shutdown" (API 17)
--
-- These are intentionally NOT declared here: declaring them as globals makes
-- luau-lsp treat your definition as overwriting a built-in.
