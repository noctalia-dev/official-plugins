--!nonstrict
-- Markdown notes in a full-height side panel.
--
-- Notes are plain text files (.md by default) in the configured notes
-- directory. The panel shows a note list and a multiline editor with idle
-- autosave (flushes after a short pause in typing, on navigation, and on panel
-- close).

local AUTOSAVE_IDLE_TICKS = 2 -- 1s panel ticks with no edits before a flush
local SCRATCHPAD_BASE = "scratchpad"

local dirs = require("./dirs.luau")
local merge = require("./merge.luau")

local notesDir = ""
local suffixes = { ".md" } -- "." .. each configured extension, resolved in onOpen
local defaultSuffix = ".md"
local files = {}
local view = "list" -- "list" | "editor"
local current = nil -- filename ("foo.md") while the editor is open
local buffer = ""
local loadedContent = "" -- what the file held when we last read/wrote it
local editorRev = 0 -- bumped to reseed the editor input after external changes
local dirty = false
local idleTicks = 0
local pendingDelete = nil -- filename awaiting the second (confirm) click
local sortByDate = false
local pins = {} -- filename -> true; persisted in a sidecar next to the notes
local hoveredKey = nil
local cornerRadiusScale = 1.0
local closeButton = true
local watchedSignature = "" -- note directory signature when it was last checked
local conflictNote = nil -- note whose conflict is being reported
local conflictRemote = nil -- remote text of that conflict
local conflictCopyState = nil -- "saved" | "failed" for that (note, remote)
local readErrorPath = nil -- note whose last read failed, to avoid repeat notifications

local render
local checkExternalChanges -- declared here: update() calls it before it is defined

local function tr(key)
  return noctalia.tr(key)
end

-- The configured suffix `file` ends with, or nil when it matches none.
local function matchSuffix(file)
  for _, s in ipairs(suffixes) do
    if #file > #s and file:sub(-#s) == s then
      return s
    end
  end
  return nil
end

local function displayName(file)
  local s = matchSuffix(file)
  return s ~= nil and file:sub(1, #file - #s) or file
end

local function hasSuffix(name)
  return matchSuffix(name) ~= nil
end

local function notePath(file)
  return notesDir .. "/" .. file
end

-- The watch setting only controls polling. Saves always merge with the disk
-- version, and the launcher's "notes_bump" signal is handled either way.
local function watchEnabled()
  return noctalia.getConfig("watch") ~= false
end

-- Cheap fingerprint of the note directory: name, mtime and size of every note.
-- Comparing it once per tick costs one listDir + one fileInfo per note and
-- catches new, deleted, renamed and edited notes without filesystem watches.
local function dirSignature()
  local list = noctalia.listDir(notesDir)
  if list == nil then
    return ""
  end
  local parts = {}
  for _, name in ipairs(list) do
    if hasSuffix(name) and name:sub(1, 1) ~= "." then
      local info = noctalia.fileInfo(notePath(name))
      local mtime = info ~= nil and info.mtime or 0
      local size = info ~= nil and info.size or 0
      table.insert(parts, name .. ":" .. tostring(mtime) .. ":" .. tostring(size))
    end
  end
  table.sort(parts)
  return table.concat(parts, "|")
end

-- Writes the editor text to a copy under .conflicts/ so nothing is lost when the
-- note changed on disk in a way that cannot be merged. Returns the copy path.
local function conflictCopy(file, contents)
  local dir = notesDir .. "/.conflicts"
  if not noctalia.mkdirAll(dir) then
    return nil
  end
  local base = displayName(file)
  local suffix = matchSuffix(file) or defaultSuffix
  local stamp = noctalia.formatTime("%Y-%m-%d %H.%M.%S")
  local name = base .. " (" .. stamp .. ")" .. suffix
  local path = dir .. "/" .. name
  local counter = 2
  while noctalia.fileExists(path) do
    name = base .. " (" .. stamp .. " " .. counter .. ")" .. suffix
    path = dir .. "/" .. name
    counter += 1
  end
  local ok = noctalia.writeFile(path, contents)
  return ok and path or nil
end

-- Copies the current editor text to .conflicts/ and tells the user. The copy is
-- refreshed on every conflicting save, so text typed after the first report is
-- not lost; only the notification is deduplicated per (note, remote text).
-- Returns the copy path when the text is safe on disk.
local function reportConflict(remote)
  local same = conflictNote == current and conflictRemote == remote
  local path = conflictCopy(current, buffer)
  if path == nil then
    conflictNote = current
    conflictRemote = remote
    if not same or conflictCopyState ~= "failed" then
      conflictCopyState = "failed"
      noctalia.notifyError(tr("title"), tr("conflict_copy_failed"))
    end
    return nil
  end
  if not same or conflictCopyState ~= "saved" then
    noctalia.notifyError(tr("title"), tr("conflict"))
    noctalia.notify(tr("title"), tr("conflict_saved"))
  end
  conflictNote = current
  conflictRemote = remote
  conflictCopyState = "saved"
  return path
end

-- Resolves a conflict once the copy exists: the disk text takes over the
-- editor, and the unsaved local text stays in .conflicts/. When the copy cannot
-- be written the buffer is kept and the next save retries.
local function settleConflict(remote)
  if reportConflict(remote) == nil then
    return false
  end
  buffer = remote
  loadedContent = remote
  dirty = false
  idleTicks = 0
  editorRev += 1
  conflictNote = nil
  conflictRemote = nil
  conflictCopyState = nil
  return true
end

-- Reads a note, treating a missing file as empty. A nil result means the file
-- exists but could not be read right now (sync tools, permissions, a rewrite in
-- progress); callers must skip instead of assuming the note was emptied.
local function readNote(path)
  local contents, err = noctalia.readFile(path)
  if contents ~= nil then
    return contents, nil
  end
  if not noctalia.fileExists(path) then
    return "", nil
  end
  return nil, err
end

local function scratchName()
  return SCRATCHPAD_BASE .. defaultSuffix
end

-- Pins live in a hidden sidecar inside the notes directory so they sync and
-- survive restarts with the notes themselves.
local function pinsPath()
  return notesDir .. "/.pinned.json"
end

local function loadPins()
  pins = {}
  local raw = noctalia.readFile(pinsPath())
  if raw ~= nil then
    local decoded = noctalia.json.decode(raw)
    if type(decoded) == "table" then
      for name, value in pairs(decoded) do
        if type(name) == "string" and value == true then
          pins[name] = true
        end
      end
    end
  end
end

local function savePins()
  local encoded = noctalia.json.encode(pins)
  if encoded == nil then
    return
  end
  local ok, err = noctalia.writeFile(pinsPath(), encoded)
  if not ok then
    noctalia.notifyError(tr("title"), err or "")
  end
end

local function refreshFiles()
  files = {}
  local list = noctalia.listDir(notesDir)
  if list ~= nil then
    for _, name in ipairs(list) do
      if hasSuffix(name) and name ~= scratchName() and name:sub(1, 1) ~= "." then
        table.insert(files, name)
      end
    end
  end
  -- Pinned notes first, then the selected order within each group.
  local mtimes = {}
  if sortByDate then
    for _, name in ipairs(files) do
      local info = noctalia.fileInfo(notePath(name))
      mtimes[name] = info ~= nil and info.mtime or 0
    end
  end
  table.sort(files, function(a, b)
    local aPinned = pins[a] == true
    local bPinned = pins[b] == true
    if aPinned ~= bPinned then
      return aPinned
    end
    if sortByDate and mtimes[a] ~= mtimes[b] then
      return mtimes[a] > mtimes[b]
    end
    return a < b
  end)
end

-- Saves the editor. If the file changed on disk since it was last read or
-- written, a 3-way merge decides first: compatible appends are folded into the
-- buffer; an incompatible change saves the local text under .conflicts/ and
-- only then loads the disk version. Returns true when the buffer is safe to
-- discard (saved or copied), false when navigation must keep it.
local function flush()
  if not dirty or current == nil then
    return true
  end
  local path = notePath(current)
  local remote, readErr = readNote(path)
  if remote == nil then
    -- Do not write over a file we cannot read: keep the buffer and retry on the
    -- next autosave instead of reporting a bogus save.
    if readErrorPath ~= path then
      readErrorPath = path
      noctalia.notifyError(tr("title"), readErr or tr("save_failed"))
    end
    return false
  end
  readErrorPath = nil
  if remote ~= loadedContent then
    local r = merge.resolve(loadedContent, buffer, remote)
    if r.status == "conflict" then
      return settleConflict(remote)
    end
    if r.content ~= buffer then
      buffer = r.content
      editorRev += 1
    end
  end
  local ok, err = noctalia.writeFile(path, buffer)
  if not ok then
    noctalia.notifyError(tr("title"), err or tr("save_failed"))
    return false
  end
  loadedContent = buffer
  dirty = false
  conflictNote = nil
  conflictRemote = nil
  conflictCopyState = nil
  return true
end

local function openNote(file)
  if not flush() then
    return
  end
  local contents, err = readNote(notePath(file))
  if contents == nil then
    noctalia.notifyError(tr("title"), err or tr("save_failed"))
    return
  end
  buffer = contents
  loadedContent = buffer
  current = file
  view = "editor"
  dirty = false
  idleTicks = 0
  pendingDelete = nil
  conflictNote = nil
  conflictRemote = nil
  conflictCopyState = nil
  render()
end

local function resetEditor()
  view = "list"
  current = nil
  buffer = ""
  dirty = false
  pendingDelete = nil
  conflictNote = nil
  conflictRemote = nil
  conflictCopyState = nil
end

-- Saves pending edits and returns to the note list.
local function showList()
  if not flush() then
    render()
    return
  end
  resetEditor()
  refreshFiles()
  render()
end

local function deleteNote(file)
  -- A draft opened via `note:<name>` has no file until its first save.
  if noctalia.fileExists(notePath(file)) then
    local ok, err = noctalia.removeFile(notePath(file))
    if not ok then
      noctalia.notifyError(tr("title"), err or "")
    end
  end
  if pins[file] ~= nil then
    pins[file] = nil
    savePins()
  end
  if current == file then
    resetEditor()
  else
    pendingDelete = nil
  end
  refreshFiles()
  render()
end

local function uniqueNoteName()
  local base = noctalia.formatTime("%Y-%m-%d %H.%M.%S")
  local name = base .. defaultSuffix
  local counter = 2
  while noctalia.fileExists(notePath(name)) do
    name = base .. " (" .. counter .. ")" .. defaultSuffix
    counter += 1
  end
  return name
end

local function findNote(name)
  for _, file in ipairs(files) do
    if file == name or displayName(file) == name then
      return file
    end
  end
  return nil
end

-- Resolves a `note:<name>` context. A name that matches no file opens an
-- empty editor under that name instead; the first edit creates the file.
local function noteFromContext(name)
  -- Leading dots would create a hidden file that the note list never shows.
  name = noctalia.string.trim(name):gsub("/", ""):gsub("^%.+", "")
  if name == "" then
    return nil
  end
  return findNote(name) or (hasSuffix(name) and name or name .. defaultSuffix)
end

-- Explicit panel context, e.g. `panel-toggle noctalia/notes:panel scratchpad`.
local function applyContext(context)
  local target = noctalia.string.trim(context or "")
  if target == "home" or target == "list" then
    showList()
    return
  end
  if target == "scratchpad" then
    openNote(scratchName())
    return
  end
  local name = target:match("^note:(.+)$")
  if name ~= nil then
    local file = noteFromContext(name)
    if file ~= nil then
      openNote(file)
    else
      render()
    end
    return
  end
  local file = findNote(target)
  if file ~= nil then
    openNote(file)
    return
  end
  -- Unknown context: fall back to the note list
  showList()
end

local function deleteControls(file)
  return {
    ui.label({ text = tr("confirm_delete"), color = "error" }),
    ui.button({
      glyph = "check",
      variant = "primary",
      onClick = function()
        deleteNote(file)
      end,
    }),
    ui.button({
      glyph = "close",
      variant = "ghost",
      onClick = function()
        pendingDelete = nil
        render()
      end,
    }),
  }
end

local function togglePin(file)
  pins[file] = not pins[file] and true or nil
  savePins()
  refreshFiles()
  render()
end

local function listRow(file)
  local pinned = pins[file] == true
  local isHovered = hoveredKey == file
  -- Label elides natively with maxLines=1; the row wrapper supplies the click target.
  local titleChildren = {
    ui.label({
      text = displayName(file),
      maxLines = 1,
      flexGrow = 1,
      color = isHovered and "surface" or "on_surface",
    }),
  }
  if pinned then
    table.insert(titleChildren, 1, ui.glyph({
      name = "pinned",
      size = 14,
      color = isHovered and "surface" or "on_surface",
    }))
  end
  local children = {
    ui.row({
      key = file,
      flexGrow = 1,
      gap = 6,
      align = "center",
      padding = 8,
      paddingH = 12,
      fill = isHovered and "tertiary" or "surface",
      radius = 6 * cornerRadiusScale,
      onHover = "onRowHover",
      onClick = function()
        openNote(file)
      end,
    }, titleChildren),
  }
  if pendingDelete == file then
    for _, node in ipairs(deleteControls(file)) do
      table.insert(children, node)
    end
  else
    table.insert(children, ui.button({
      glyph = pinned and "pinned-off" or "pin",
      variant = "ghost",
      onClick = function()
        togglePin(file)
      end,
    }))
    table.insert(children, ui.button({
      glyph = "trash",
      variant = "ghost",
      onClick = function()
        pendingDelete = file
        render()
      end,
    }))
  end
  -- Pin state is part of the key: retained buttons keep a previously set
  -- glyph, so the row is recreated when it flips.
  return ui.row({ key = "note-" .. file .. (pinned and "-pinned" or ""), gap = 6, align = "center" }, children)
end

local function listView()
  local scratchFile = scratchName()
  local isHovered = hoveredKey == scratchFile
  local rows = {
    -- The scratchpad is always present (created on first write) and not deletable from here.
    ui.row({ key = "scratchpad", gap = 6, align = "center" }, {
      ui.row({
        key = scratchFile,
        flexGrow = 1,
        gap = 6,
        align = "center",
        padding = 8,
        paddingH = 12,
        fill = isHovered and "tertiary" or "surface",
        radius = 6 * cornerRadiusScale,
        onHover = "onRowHover",
        onClick = "onOpenScratchpad",
      }, {
        ui.glyph({
            name = "pinned",
            size = 14,
            color = isHovered and "surface" or "on_surface",
          }),
        ui.label({
            text = tr("scratchpad"),
            maxLines = 1,
            flexGrow = 1,
            color = isHovered and "surface" or "on_surface",
          }),
      }),
    }),
  }
  for _, file in ipairs(files) do
    table.insert(rows, listRow(file))
  end
  if #files == 0 then
    table.insert(rows, ui.label({ text = tr("empty"), color = "on_surface_variant" }))
  end
  return ui.scroll({ flexGrow = 1, gap = 4 }, rows)
end

local function editorStatusLine()
  local words = select(2, buffer:gsub("%S+", ""))
  local chars = utf8.len(buffer) or #buffer
  local status = dirty and tr("editing") or tr("saved")
  return status .. "  ·  " .. noctalia.tr("counts", { words = words, chars = chars })
end

local function editorHeader()
  local trailing
  if pendingDelete == current then
    trailing = deleteControls(current, "noteEditorDelete", 0)
  else
    trailing = {
      ui.button({ glyph = "trash", variant = "ghost", onClick = "onEditorDelete" }),
    }
  end
  local children = {
    ui.button({ glyph = "arrow-left", variant = "ghost", onClick = "onBack" }),
    ui.input({
      key = "rename-" .. current,
      value = displayName(current),
      onSubmit = "onRename",
      -- The scratchpad's identity is its name; renaming it would just respawn it.
      enabled = current ~= scratchName(),
      flexGrow = 1,
    }),
  }
  for _, node in ipairs(trailing) do
    table.insert(children, node)
  end
  return ui.row({ gap = 6, align = "center" }, children)
end

local function editorView()
  return ui.column({ flexGrow = 1, gap = 8, align = "stretch" }, {
    editorHeader(),
    ui.input({
      -- The rev reseeds the (uncontrolled) editor when the file changed under us.
      key = "editor-" .. current .. "-" .. editorRev,
      value = buffer,
      multiline = true,
      focus = true,
      flexGrow = 1,
      placeholder = tr("editor_placeholder"),
      onChange = "onEdited",
      onSubmit = "onFlushNow",
    }),
    ui.label({
      text = editorStatusLine(),
      fontSize = 11,
      color = "on_surface_variant",
    }),
  })
end

render = function()
  local isEditor = view == "editor" and current ~= nil
  local header = {
    ui.label({ text = tr("title"), fontSize = 16, fontWeight = "bold", color = "on_surface", flexGrow = 1 }),
  }
  if not isEditor then
    table.insert(header, ui.button({
      key = "header-sort",
      glyph = sortByDate and "history" or "sort-ascending-letters",
      variant = "ghost",
      onClick = "onToggleSort",
    }))
  end
  table.insert(header, ui.button({ key = "header-new", glyph = "plus", variant = "primary", onClick = "onNewNote" }))
  if closeButton then
    table.insert(header, ui.button({ key = "header-close", glyph = "close", variant = "ghost", onClick = "onClosePanel" }))
  end
  panel.render(ui.column({ flexGrow = 1, gap = 12, align = "stretch" }, {
    ui.row({ align = "center", gap = 8 }, header),
    isEditor and editorView() or listView(),
  }))
end

function onOpen(context)
  notesDir = dirs.resolveNotesDir()
  cornerRadiusScale = noctalia.getSetting("shell.corner_radius_scale")
  closeButton = noctalia.getSetting("shell.show_close_buttons") ~= false
  local rawExt = noctalia.string.trim(noctalia.getConfig("extension"))
  suffixes = {}
  for ext in rawExt:gmatch("[^,%s]+") do
    local clean = ext:gsub("^%.", "")
    if clean ~= "" then
      table.insert(suffixes, "." .. clean)
    end
  end
  if #suffixes == 0 then
    noctalia.notifyError(tr("title"), tr("bad_extension"))
    suffixes = { ".md" }
  end
  defaultSuffix = suffixes[1]
  -- A note left open under a different extension setting no longer matches.
  if current ~= nil and not hasSuffix(current) then
    resetEditor()
  end
  local ok, err = noctalia.mkdirAll(notesDir)
  if not ok then
    noctalia.notifyError(tr("title"), err or "")
  end
  loadPins()
  refreshFiles()
  watchedSignature = dirSignature()
  conflictNote = nil
  conflictRemote = nil
  conflictCopyState = nil
  readErrorPath = nil
  pendingDelete = nil
  panel.setWantsSecondTicks(true)
  -- An explicit IPC context wins over the launcher handoff below.
  if noctalia.string.trim(context or "") ~= "" then
    noctalia.state.set("open_home", false)
    noctalia.state.set("open_note", "")
    applyContext(context)
    return
  end
  -- The launcher entry hands over a target through the shared state: either
  -- the note list ("open_home") or a specific note ("open_note").
  if noctalia.state.get("open_home") == true then
    noctalia.state.set("open_home", false)
    showList()
    return
  end
  local target = noctalia.state.get("open_note")
  if type(target) == "string" and target ~= "" then
    noctalia.state.set("open_note", "")
    openNote(target)
    return
  end
  render()
end

function onOpenScratchpad()
  openNote(scratchName())
end

function onClose()
  flush()
  panel.setWantsSecondTicks(false)
end

function update()
  checkExternalChanges()
  if dirty then
    idleTicks += 1
    if idleTicks >= AUTOSAVE_IDLE_TICKS then
      flush()
      render()
    end
  end
end

function onEdited(value)
  buffer = value
  idleTicks = 0
  dirty = true
  -- Re-render on every edit: the status line carries the live word/char count.
  render()
end

function onToggleSort()
  sortByDate = not sortByDate
  refreshFiles()
  render()
end

function onFlushNow(value)
  buffer = value
  dirty = true
  flush()
  render()
end

function onNewNote()
  if not flush() then
    return
  end
  local name = uniqueNoteName()
  local ok, err = noctalia.writeFile(notePath(name), "")
  if not ok then
    noctalia.notifyError(tr("title"), err or tr("save_failed"))
    return
  end
  refreshFiles()
  watchedSignature = dirSignature()
  openNote(name)
end

function onRename(value)
  if current == nil then
    return
  end
  local name = noctalia.string.trim(value):gsub("/", "")
  if name == "" or name == displayName(current) then
    render()
    return
  end
  local target = name .. (matchSuffix(current) or defaultSuffix)
  if noctalia.fileExists(notePath(target)) then
    noctalia.notifyError(tr("title"), tr("rename_exists"))
    render()
    return
  end
  if not flush() then
    render()
    return
  end
  -- An unsaved draft (no file yet) is renamed in place; the first save creates it.
  if noctalia.fileExists(notePath(current)) then
    local ok, err = noctalia.renameFile(notePath(current), notePath(target))
    if not ok then
      noctalia.notifyError(tr("title"), err or "")
      render()
      return
    end
  end
  if pins[current] ~= nil then
    pins[current] = nil
    pins[target] = true
    savePins()
  end
  current = target
  refreshFiles()
  watchedSignature = dirSignature()
  render()
end

function onEditorDelete()
  pendingDelete = current
  render()
end

function onBack()
  showList()
end

function onClosePanel()
  panel.close()
end

function onRowHover(state, key)
  hoveredKey = (state == "true") and key or nil
  render()
end

-- The launcher entry bumps "notes_bump" after writing note files (quick-capture
-- appends, new notes). Fold external changes into the open editor: a disk text
-- that is the old content plus a tail is grafted onto whatever is being typed,
-- and a real conflict saves a copy and only then loads the disk text.
local function handleExternalChange()
  if notesDir == "" then
    return -- never opened; nothing resolved yet
  end
  refreshFiles()
  if current == nil then
    render()
    return
  end

  local path = notePath(current)
  local remote = readNote(path)
  if remote == nil then
    -- Keep the editor as it is; the next tick or notes_bump retries.
    render()
    return
  end
  readErrorPath = nil
  if remote == loadedContent then
    render()
    return
  end

  local r = merge.resolve(loadedContent, buffer, remote)
  if r.status == "conflict" then
    settleConflict(remote)
    render()
    return
  end

  conflictNote = nil
  conflictRemote = nil
  conflictCopyState = nil
  local before = buffer
  buffer = r.content
  -- Whatever is on disk was what the merge started from; a merged result is
  -- newer than the disk, so it stays dirty and the autosave writes it back.
  loadedContent = remote
  dirty = buffer ~= remote
  idleTicks = 0
  if buffer ~= before then
    editorRev += 1
  end
  render()
end

checkExternalChanges = function()
  if notesDir == "" or not watchEnabled() then
    return
  end
  local sig = dirSignature()
  if sig ~= watchedSignature then
    watchedSignature = sig
    handleExternalChange()
    return
  end
  if current == nil or not noctalia.fileExists(notePath(current)) then
    return
  end
  -- The signature has second granularity, so an in-place rewrite of the same
  -- size within the same second is only visible by reading the open note.
  local remote = noctalia.readFile(notePath(current))
  if remote ~= nil and remote ~= loadedContent then
    handleExternalChange()
  end
end

noctalia.state.watch("notes_bump", function(_value)
  handleExternalChange()
end)
