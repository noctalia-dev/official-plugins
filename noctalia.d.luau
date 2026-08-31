--!strict
-- Type definitions for the Noctalia plugin API.
--
-- This is a luau-lsp *definition file*: it declares the host-injected globals
-- (noctalia.*, barWidget.*, shortcut.*, launcher.*, desktopWidget.*, panel.*,
-- ui.*) and the entry-point callbacks the host calls (update, onIpc, onClick, …)
-- so authors get autocomplete and typo diagnostics. Annotations are a runtime
-- no-op — the Luau VM compiles them away — so this file changes nothing about
-- how a plugin runs; it only feeds the editor.
--
-- See README.md ("Editor setup") for how to point luau-lsp at this file.

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
  -- Disables origin certificate and hostname verification. Defaults to false.
  -- Use only for explicitly trusted endpoints.
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

-- Noctalia provides Luau's built-in `require(path: string): any` for explicit relative `.luau` modules.

-- ── noctalia.* — shared across every entry type ──────────────────────────────

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

export type NoctaliaSound = {
  -- Paths resolve like filesystem APIs: ~ through $HOME, absolute paths unchanged,
  -- and other paths relative to the plugin directory. The return value means the
  -- request was accepted, not that decoding succeeded. At most eight loads may be
  -- pending; a duplicate pending name returns false. Accepted callbacks are cancelled
  -- when this runtime reloads or stops.
  load: (name: string, path: string, onLoaded: (ok: boolean, error: string?) -> ()) -> boolean,
  -- Names belong to this runtime instance and are released when it reloads or stops.
  play: (name: string) -> (),
}

export type SystemStats = {
  -- Unix epoch milliseconds for the latest aggregate sample. Plugin API 16.
  sampledAtMs: number?,
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

export type Noctalia = {
  log: (msg: string) -> (),

  -- Subprocess. A string runs through /bin/sh -c; an argv table executes the
  -- program directly, so dynamic values remain single arguments. With no
  -- callback, runAsync is a detached fire-and-forget launch. With a callback
  -- it delivers a CommandResult; timeoutMs is clamped to [50, 60000].
  -- The argv-table form requires plugin_api >= 24.
  runAsync: (cmdOrArgv: string | { string }, onResult: ((result: CommandResult) -> ())?, timeoutMs: number?) -> boolean,
  runStream: (cmd: string, onLine: (line: string) -> ()) -> boolean,
  runInTerminal: (cmd: string) -> boolean,
  commandExists: (name: string) -> boolean,
  -- processMatches(onResult, needle1, needle2, …) — onResult(true) iff a running
  -- process command line matches all needles.
  processMatches: (onResult: (matched: boolean) -> (), ...string) -> boolean,
  flatpakAppInstalled: (appId: string) -> boolean,
  portalAvailable: () -> boolean,

  -- Outputs / display.
  focusedOutputName: () -> string?,
  outputs: () -> { Output },
  isDarkMode: () -> boolean,
  -- Read any effective shell config value by dotted path, e.g.
  -- getSetting("shell.offline_mode"), getSetting("bar.main.position"),
  -- getSetting("widget.clock"). Tables/arrays convert to Lua tables; array
  -- indices inside the path are zero-based ("bar.order[0]"). nil when the
  -- path matches nothing. Requires plugin_api >= 26.
  getSetting: (path: string) -> any,

  -- App icons. Resolves an app id (desktop-entry id / StartupWMClass) — or a
  -- raw icon name when no entry matches — to an icon file path via the host's
  -- XDG icon-theme resolver, for use with ui.image. sizePx is the intended
  -- on-screen pixel size; nil when nothing resolves.
  appIconPath: (appIdOrIconName: string, sizePx: number?) -> string?,

  -- Wallpaper. setWallpaper(path) targets all outputs; setWallpaper(connector,
  -- path) targets one.
  setWallpaperEnabled: (connector: string, enabled: boolean) -> (),
  setWallpaper: (connectorOrPath: string, path: string?) -> (),
  wallpaperDirectory: () -> string?,
  -- Source-aligned output mask. 0 keeps desktop widgets visible; 255 erases
  -- them to reveal the wallpaper. Requires plugin_api >= 25.
  wallpaperPath: (connector: string) -> string?,
  setWallpaperMask: (connector: string, mask: WallpaperMask?) -> (),

  -- Panels.
  togglePanel: (panelId: string) -> (), -- "author/plugin:panel"

  -- Open the settings window at this plugin's own settings, closing any open panel.
  -- Does nothing when the plugin declares no settings.
  openSettings: () -> (),

  -- Dialogs. The callback receives the selected canonical #RRGGBB color, or nil
  -- when the dialog is cancelled.
  openColorPicker: (initialColor: string, onClose: (color: string?) -> ()) -> boolean,

  -- Notifications.
  notify: (title: string, body: string?) -> (),
  notifyError: (title: string, body: string?) -> (),

  copyToClipboard: (text: string, mimeType: string) -> boolean,
  clipboardText: () -> string?, -- latest text clipboard content (nil when empty or non-text)
  getenv: (name: string) -> string?,
  expandPath: (path: string) -> string,
  formatTime: (pattern: string, unixSeconds: number?, timezone: string?) -> string,
  -- [shell].time_format / date_format (e.g. "{:%H:%M}", "%A, %x"). Plugin API 19.
  timeFormat: () -> string,
  dateFormat: () -> string,
  -- True when `name` is empty (system local) or names a zone in the active timezone database.
  -- Plugin API 19.
  isValidTimezone: (name: string) -> boolean,
  -- Wall-clock milliseconds since the Unix epoch. formatTime and os.time are both
  -- whole-second, so this is the only sub-second clock. Plugin API 12.
  nowMs: () -> number,

  -- System monitor. systemStats and cpuCores return nil when [system.monitor] is disabled.
  -- The first systemStats call opts this plugin into its optional CPU/GPU probes.
  systemStats: () -> SystemStats?,
  -- Per-core usage in /proc/stat order, nil until the first delta lands (up to a second
  -- after the first call). The first call opts this plugin into per-core sampling, which
  -- costs one extra /proc/stat read per second while it stays loaded. Offline cores are
  -- absent from /proc/stat, so the length can change and an index is not a core id.
  cpuCores: () -> { number }?,
  -- Physical block-device-backed filesystems, deduped by source and sorted by mount path.
  -- Pseudo filesystems, loop/squashfs mounts and boot mounts are excluded. Plugin API 16.
  diskMounts: () -> { DiskMount },
  -- Latest statvfs snapshot for an absolute or ~/ path. The first call retains each valid
  -- path for sampling until the plugin unloads. Nil when unavailable. Plugin API 16.
  diskStats: (path: string) -> DiskStats?,

  -- Tick rate: how often update() fires (clamped to >= 16ms).
  setUpdateInterval: (ms: number) -> (),

  -- Filesystem (paths resolve ~ -> $HOME, absolute verbatim, else plugin-relative).
  readFile: (path: string) -> (string?, string?), -- contents, or (nil, err)
  readFileAsync: (path: string, onResult: (contents: string?, err: string?) -> ()) -> boolean,
  writeFile: (path: string, contents: string) -> (boolean, string?),
  mkdirAll: (path: string) -> (boolean, string?), -- like mkdir -p; existing dir is success
  removeFile: (path: string) -> (boolean, string?), -- files only, refuses directories
  renameFile: (from: string, to: string) -> (boolean, string?),
  fileExists: (path: string) -> boolean,
  fileInfo: (path: string) -> ({ size: number, mtime: number, isDir: boolean }?, string?),
  listDir: (path: string) -> ({ string }?, string?),
  pluginDir: () -> string?,
  -- Per-plugin persistent data dir, created on demand. Survives plugin updates
  -- and honors the NOCTALIA_STATE_HOME override. Use for durable data (state is
  -- in-memory only). Returns the absolute path, or (nil, err).
  pluginDataDir: () -> (string?, string?),

  -- Register a font file (path resolves like readFile) so its family becomes
  -- usable in setFont / a ui label's fontFamily. Returns the family name, or
  -- (nil, err). The family is visible to every surface once loaded.
  loadFont: (path: string) -> (string?, string?),

  -- Translation against the plugin's own translations/<lang>.json.
  tr: (key: string, subst: { [string]: string | number | boolean }?) -> string,
  trp: (key: string, count: number, subst: { [string]: string | number | boolean }?) -> string,

  -- HTTP (honors shell.offline_mode; download dest resolves like readFile).
  http: (req: HttpRequest, onResponse: (response: HttpResponse) -> ()) -> boolean,
  -- Long-lived streaming request (e.g. SSE). onLine fires per received line (CR
  -- trimmed); onClose fires exactly once when the transfer ends, unless the
  -- stream was stopped via the handle. Non-2xx responses are not special-cased:
  -- their body streams to onLine and the status arrives in onClose. Streams are
  -- cancelled on script reload. Returns nil when the stream could not be started.
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

-- One node of a declarative ui.* control tree (bar widgets, desktop widgets, panels).
export type UiNode = {
  type: string,
  props: { [string]: any },
  children: { UiNode },
}

-- ── barWidget.* — [[widget]] presentation ────────────────────────────────────

declare barWidget: {
  setText: (text: string) -> (),
  setGlyph: (name: string) -> (),
  setImage: (path: string, watch: boolean?, width: number?, height: number?) -> (),
  setTooltip: (tooltip: (string | TooltipRow | { TooltipRow })?) -> (),
  clearTooltip: () -> (),
  -- family: a font family name (load a file first with noctalia.loadFont).
  -- baseline: "text" (default) | "textFixedHeight" | "inkCentered" | "pictographic"
  -- ("pictographic" centers art/icon fonts anchored at the ink top, e.g. bongocat).
  setFont: (family: string, baseline: string?) -> (),
  setColor: (role: string, mode: string?) -> (),
  setGlyphColor: (role: string, mode: string?) -> (),
  isVertical: () -> boolean,
  -- Connector name of the output this widget instance's bar is on (nil when
  -- unknown). Per-instance, unlike noctalia.focusedOutputName().
  outputName: () -> string?,
  setVisible: (visible: boolean) -> (),
  -- Declarative alternative to setText/setGlyph: the tree replaces the built-in
  -- glyph/text row. ui.input/ui.select/ui.scroll are not supported in the bar.
  render: (tree: UiNode) -> (),
}

-- ── Gestures on a bar widget ─────────────────────────────────────────────────
--
-- What a bar widget does on a click or scroll is configuration, not code. The
-- user binds gestures per widget instance:
--
--   [widget.my-widget.actions]
--   right = "media toggle"
--   scroll_up = "none"
--
-- A binding wins over your script: bind `right` and onRightClick stops firing
-- for that instance. Gestures the user has not bound still reach your callbacks.
-- The gesture keys are left, right, middle, back, forward, scroll_up,
-- scroll_down, scroll_left and scroll_right. An action is an IPC command with
-- its arguments ("media toggle"), `exec <command line>`, or `none`.
--
-- Declare your own defaults in plugin.toml (plugin_api 14+), and they show up in
-- the settings editor as the widget's defaults, overridable like any other:
--
--   [[widget]]
--   id = "my-widget"
--   entry = "my-widget.luau"
--
--   [widget.actions]
--   middle = "media toggle"
--
-- Middle click is the one to know about: every widget gets a built-in
-- `middle = "settings-open-widget"` default, so onMiddleClick does NOT fire out
-- of the box. Binding middle to an action does not help either - the action runs
-- instead of your callback. What frees the button is binding it to nothing:
--
--   [widget.actions]
--   middle = "none"
--
-- Declare that in your manifest if your widget implements onMiddleClick; users
-- can do the same per instance. Consider whether you want it: middle click opens
-- the widget's settings everywhere else in the shell, and a declared action is
-- visible in the settings editor where a Luau callback is not.
--
-- Scroll has one extra gate: `enable_scroll = false` on the widget instance turns
-- onScroll off entirely, independently of any binding.

-- ── shortcut.* — [[shortcut]] quick-toggle tile ──────────────────────────────

declare shortcut: {
  setLabel: (label: string) -> (),
  setIcon: (on: string, off: string?) -> (),
  setActive: (active: boolean) -> (),
  setEnabled: (enabled: boolean) -> (),
}

-- ── ui.* — declarative control tree (bar widgets, desktop widgets, panels) ───

type UiCtor = (props: { [string]: any }?, children: { UiNode }?) -> UiNode

-- Pointer props take a function or the name of a global function in your script.
-- onClick is accepted by row, column, box, image, and button (button also takes
-- onRightClick); the handler takes no arguments.
-- onHover is accepted by the same five and makes the node a hover target: the
-- handler receives (state, key), where state is "true" on enter and "false" on
-- leave, and key is the node's key prop ("" when it has none), so one named
-- handler can serve a keyed list (a closure captures its row instead). Only the
-- innermost hovered node reports, and every "true" is matched by a "false". An
-- empty callback name counts as unset. A function handler belongs to the render
-- that produced it: re-rendering replaces it, and a click on a node the current
-- tree no longer contains does nothing. onClick on row/column/box/image makes
-- the node a click target that also joins the tab order (Enter/Space); a node
-- with only onHover passes clicks through to an enclosing click target.
declare ui: {
  column: UiCtor,
  row: UiCtor,
  box: UiCtor,
  label: UiCtor,
  markdown: UiCtor,
  glyph: UiCtor,
  image: UiCtor,
  separator: UiCtor,
  spacer: UiCtor,
  progress: UiCtor,
  button: UiCtor,
  graph: UiCtor,
  input: UiCtor,
  select: UiCtor,
  -- Slider props: min, max, step, value (numbers), enabled (bool), controlSize.
  -- onChange reports the new value on every change (coalesced). onDragEnd fires
  -- when the interaction ends — pointer release and keyboard adjustments
  -- (arrows, PageUp/PageDown, Home, End); wheel scroll does not adjust plugin
  -- sliders. `value` is re-applied only while not dragging, so re-rendering
  -- mid-drag with a draft value is safe; commit on onDragEnd for a
  -- draft-then-commit pattern.
  slider: UiCtor,
  toggle: UiCtor,
  scroll: UiCtor,
  -- Drag and drop (plugin panels only). dragSource props:
  -- dragType/payload (required strings), enabled, tooltip, previewAncestor
  -- (0-8), liftFromLayout. dropZone props: accepts (string array), value,
  -- onDrop (required), direction, enabled, expandOnDrag, hitSlop. The onDrop
  -- handler receives (payload, value) after a completed drop.
  dragSource: UiCtor,
  dropZone: UiCtor,
}

-- ── launcher.* — [[launcher_provider]] results ───────────────────────────────

declare launcher: {
  setResults: (query: string, results: { LauncherResult }) -> (),
  setQuery: (text: string) -> (), -- set input to this provider's prefix + text (stays in provider); "" resets to root
}

-- ── desktopWidget.* — [[desktop_widget]] declarative UI ──────────────────────

declare desktopWidget: {
  render: (tree: UiNode) -> (),
  setWantsSecondTicks: (wants: boolean) -> (),
  setNeedsFrameTick: (needs: boolean) -> (),
}

-- ── panel.* — [[panel]] declarative UI ───────────────────────────────────────

declare panel: {
  render: (tree: UiNode) -> (),
  close: () -> (),
  -- Opens a native menu at the originating direct pointer callback. Returns
  -- false outside a live pointer callback. onActivate receives
  -- (actionId, context) in the panel script. Requires plugin_api >= 28.
  openContextMenu: (request: PanelContextMenuRequest) -> boolean,
  setWantsSecondTicks: (wants: boolean) -> (),
  setNeedsFrameTick: (needs: boolean) -> (),
}

-- ── Entry-point callbacks ────────────────────────────────────────────────────
--
-- Your entry defines the globals the host calls, as plain global functions — the
-- host only calls a callback if the entry defines it:
--
--   function update() end                       -- bar/desktop widget, service tick
--   function onIpc(event, payload) end          -- any entry (payload: string?)
--   function onClick() / onRightClick() end     -- shortcut, bar widget
--   function onMiddleClick() end                -- bar widget (see "Gestures" below)
--   function onHover(entered) end               -- bar widget pointer enter / leave
--   function onScroll(axis, steps, startsGesture) end -- bar widget scroll; axis is "vertical" | "horizontal",
--                                               -- steps is whole wheel detents (negative = up / left).
--                                               -- startsGesture is true only on the first step of a flick
--                                               -- in that direction: check it to step a list once per
--                                               -- flick, ignore it to ramp a value per notch.
--   function onQuery(text) / onActivate(id) end -- launcher provider
--   function onFrameTick(deltaMs) end           -- desktop widget, or open panel (API 18+); continuous
--                                               -- animation, after setNeedsFrameTick(true)
--   function onAudioSpectrum(valuesCsv, stateCsv) end -- audio-reactive bar widget
--   function onOpen(context) / onClose() end    -- panel lifecycle
--   function onKey(chord, pressed) end          -- panel: a capture_keys chord, verbatim from the
--                                               -- manifest; pressed is true on press, false on release
--   function onConfigChanged() end              -- service: plugin settings changed; getConfig() now returns new values
--   function onEnable() end                     -- service: plugin explicitly enabled successfully (API 17+)
--   function onExit(signal, reason) end          -- any entry teardown; signal is 0 normally, 2 for SIGINT, 15 for SIGTERM
--                                               -- reason is "reload" | "disable" | "uninstall" | "shutdown" (API 17+)
--
-- These are intentionally NOT declared here: declaring them as globals makes
-- luau-lsp treat your definition as overwriting a built-in.
