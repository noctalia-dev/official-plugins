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
  query: string?, -- echo the onQuery text so late async results map back
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

  -- Wallpaper. setWallpaper(path) targets all outputs; setWallpaper(connector,
  -- path) targets one.
  setWallpaperEnabled: (connector: string, enabled: boolean) -> (),
  setWallpaper: (connectorOrPath: string, path: string?) -> (),
  wallpaperDirectory: () -> string?,

  -- Panels.
  togglePanel: (panelId: string) -> (), -- "author/plugin:panel"

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

  -- Translation against the plugin's own translations/<lang>.json.
  tr: (key: string, subst: { [string]: string | number | boolean }?) -> string,
  trp: (key: string, count: number, subst: { [string]: string | number | boolean }?) -> string,

  -- HTTP (honors shell.offline_mode; download dest resolves like readFile).
  http: (req: HttpRequest, onResponse: (response: HttpResponse) -> ()) -> boolean,
  download: (url: string, destPath: string, onDone: (success: boolean) -> ()) -> boolean,

  fuzzyScore: (pattern: string, text: string) -> number?, -- nil if no match

  getConfig: (key: string) -> any, -- string | number | boolean | {string} | nil

  state: NoctaliaState,
  json: NoctaliaJson,
  string: NoctaliaString,
}

declare noctalia: Noctalia

-- ── barWidget.* — [[widget]] presentation ────────────────────────────────────

declare barWidget: {
  setText: (text: string) -> (),
  setGlyph: (name: string) -> (),
  setImage: (path: string, watch: boolean?, width: number?, height: number?) -> (),
  setTooltip: (tooltip: (string | TooltipRow | { TooltipRow })?) -> (),
  clearTooltip: () -> (),
  setFont: (family: string) -> (), -- family name or plugin-relative .otf/.ttf/.woff2
  setColor: (role: string, mode: string?) -> (),
  setGlyphColor: (role: string, mode: string?) -> (),
  isVertical: () -> boolean,
  setVisible: (visible: boolean) -> (),
  getConfig: (key: string) -> any, -- string | number | boolean | {string} | nil
}

-- ── shortcut.* — [[shortcut]] quick-toggle tile ──────────────────────────────

declare shortcut: {
  setLabel: (label: string) -> (),
  setIcon: (on: string, off: string?) -> (),
  setActive: (active: boolean) -> (),
  setEnabled: (enabled: boolean) -> (),
}

-- ── ui.* — declarative control tree (desktop widgets + panels) ───────────────

export type UiNode = {
  type: string,
  props: { [string]: any },
  children: { UiNode },
}

type UiCtor = (props: { [string]: any }?, children: { UiNode }?) -> UiNode

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
}

-- ── launcher.* — [[launcher_provider]] results ───────────────────────────────

declare launcher: {
  setResults: (query: string, results: { LauncherResult }) -> (),
  setQuery: (text: string) -> (),
  getConfig: (key: string) -> any, -- string | number | boolean | {string} | nil
}

-- ── desktopWidget.* — [[desktop_widget]] declarative UI ──────────────────────

declare desktopWidget: {
  render: (tree: UiNode) -> (),
  setWantsSecondTicks: (wants: boolean) -> (),
  setNeedsFrameTick: (needs: boolean) -> (),
  getConfig: (key: string) -> any, -- string | number | boolean | {string} | nil
}

-- ── panel.* — [[panel]] declarative UI ───────────────────────────────────────

declare panel: {
  render: (tree: UiNode) -> (),
  close: () -> (),
  setWantsSecondTicks: (wants: boolean) -> (),
  getConfig: (key: string) -> any, -- string | number | boolean | {string} | nil
}

-- ── Entry-point callbacks ────────────────────────────────────────────────────
--
-- Your entry defines the globals the host calls, as plain global functions — the
-- host only calls a callback if the entry defines it:
--
--   function update() end                       -- bar/desktop widget, service tick
--   function onIpc(event, payload) end          -- any entry (payload: string?)
--   function onClick() / onRightClick() end     -- shortcut
--   function onQuery(text) / onActivate(id) end -- launcher provider
--   function onFrameTick(deltaMs) end           -- continuous animation (setNeedsFrameTick)
--   function onAudioSpectrum(valuesCsv, stateCsv) end -- audio-reactive bar widget
--   function onOpen(context) / onClose() end    -- panel lifecycle
--
-- These are intentionally NOT declared here: declaring them as globals makes
-- luau-lsp treat your definition as overwriting a built-in.
