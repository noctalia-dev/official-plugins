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

export type Noctalia = {
  log: (msg: string) -> (),

  -- Subprocess. With no callback, runAsync is a detached fire-and-forget launch.
  -- With a callback it runs async and delivers a CommandResult; timeoutMs is
  -- clamped to [50, 60000].
  runAsync: (cmd: string, onResult: ((result: CommandResult) -> ())?, timeoutMs: number?) -> boolean,
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

  -- Panels.
  togglePanel: (panelId: string) -> (), -- "author/plugin:panel"

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
  formatTime: (pattern: string, unixSeconds: number?) -> string,

  -- Tick rate: how often update() fires (clamped to >= 16ms).
  setUpdateInterval: (ms: number) -> (),

  -- Filesystem (paths resolve ~ -> $HOME, absolute verbatim, else plugin-relative).
  readFile: (path: string) -> (string?, string?), -- contents, or (nil, err)
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
  -- cancelled on script reload. Requires plugin_api >= 4. Returns nil when the
  -- stream could not be started.
  httpStream: (
    req: HttpRequest,
    onLine: (line: string) -> (),
    onClose: (result: HttpStreamResult) -> ()
  ) -> HttpStreamHandle?,
  download: (url: string, destPath: string, onDone: (success: boolean) -> ()) -> boolean,

  fuzzyScore: (pattern: string, text: string) -> number?, -- nil if no match

  -- String maps ({[string]: string}) require plugin_api >= 6.
  getConfig: (key: string) -> any, -- string | number | boolean | {string} | {[string]: string} | nil

  state: NoctaliaState,
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

-- ── shortcut.* — [[shortcut]] quick-toggle tile ──────────────────────────────

declare shortcut: {
  setLabel: (label: string) -> (),
  setIcon: (on: string, off: string?) -> (),
  setActive: (active: boolean) -> (),
  setEnabled: (enabled: boolean) -> (),
}

-- ── ui.* — declarative control tree (bar widgets, desktop widgets, panels) ───

type UiCtor = (props: { [string]: any }?, children: { UiNode }?) -> UiNode

-- Pointer props name global functions in your script. onClick is accepted by
-- row, column, box, image and button (button also takes onRightClick); the
-- global takes no arguments. onHover is accepted by the same five and makes the
-- node a hover target: the global receives (state, key), where state is "true"
-- on enter and "false" on leave, and key is the node's key prop ("" when it has
-- none), so one handler can serve a keyed list. Only the innermost hovered node
-- reports, and every "true" is matched by a "false". An empty callback name
-- counts as unset. onClick on row/column/box/image makes the node a click
-- target that also joins the tab order (Enter/Space); a node with only onHover
-- passes clicks through to an enclosing click target.
declare ui: {
  column: UiCtor,
  row: UiCtor,
  box: UiCtor,
  label: UiCtor,
  glyph: UiCtor,
  image: UiCtor,
  separator: UiCtor,
  spacer: UiCtor,
  progress: UiCtor,
  button: UiCtor,
  graph: UiCtor,
  input: UiCtor,
  select: UiCtor,
  slider: UiCtor,
  toggle: UiCtor,
  scroll: UiCtor,
  -- Drag and drop (plugin panels only, plugin_api >= 5). dragSource props:
  -- dragType/payload (required strings), enabled, tooltip, previewAncestor
  -- (0-8), liftFromLayout. dropZone props: accepts (string array), value,
  -- onDrop (required), direction, enabled, expandOnDrag, hitSlop. The onDrop
  -- global receives (payload, value) after a completed drop.
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
  setWantsSecondTicks: (wants: boolean) -> (),
}

-- ── Entry-point callbacks ────────────────────────────────────────────────────
--
-- Your entry defines the globals the host calls, as plain global functions — the
-- host only calls a callback if the entry defines it:
--
--   function update() end                       -- bar/desktop widget, service tick
--   function onIpc(event, payload) end          -- any entry (payload: string?)
--   function onClick() / onRightClick() end     -- shortcut
--   function onScroll(axis, steps) end          -- bar widget scroll; axis is "vertical" | "horizontal",
--                                               -- steps is whole wheel detents (negative = up / left)
--   function onQuery(text) / onActivate(id) end -- launcher provider
--   function onFrameTick(deltaMs) end           -- continuous animation (setNeedsFrameTick)
--   function onAudioSpectrum(valuesCsv, stateCsv) end -- audio-reactive bar widget
--   function onOpen(context) / onClose() end    -- panel lifecycle
--   function onConfigChanged() end              -- service: plugin settings changed; getConfig() now returns new values
--   function onExit(signal) end                  -- any entry teardown (0 normally, 2 for SIGINT, 15 for SIGTERM)
--
-- These are intentionally NOT declared here: declaring them as globals makes
-- luau-lsp treat your definition as overwriting a built-in.
