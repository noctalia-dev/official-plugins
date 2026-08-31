--!nonstrict
-- Video wallpaper picker.
-- Browse the configured video directory as a grid, choose a target output, and apply a
-- video. Selection is delivered to the headless service through the shared "command"
-- state channel; the service launches mpvpaper and drops the host wallpaper there.
-- The slideshow interval slider below is panel-local only (no config/state readback,
-- aside from a one-time read on open): it displays minutes, and commits seconds to the
-- service via "slideshowCommand". Its toggle button lives in the output/pause/stop row;
-- the slider itself expands into its own row below (Noctalia's ui.* vocabulary has no
-- floating dropdown/popover primitive, so this is an inline expand/collapse instead).
-- The panel never reads any manifest setting for the slideshow: the slider is the single
-- source of truth, and the service persists the interval so it survives restarts.

local PANEL_WIDTH = 920
local PANEL_PADDING = 28
local COLUMNS = 4
local COLUMN_GAP = 12
local PAGE_SIZE = 24
local THUMB_MAX_CONCURRENT = 4
local TILE_RADIUS = 12
local VIDEO_EXTENSIONS = { mp4 = true, webm = true, mkv = true, mov = true, gif = true }
local CACHE_DIR = (noctalia.getenv("XDG_CACHE_HOME") or ((noctalia.getenv("HOME") or "") .. "/.cache")) .. "/noctalia/mpvpaper"

local SLIDESHOW_MIN_MINUTES = 0
local SLIDESHOW_MAX_MINUTES = 120
local SECONDS_PER_MINUTE = 60

local videos = {}      -- { { path=, name=, ext= }, ... }
local page = 1
local outputsList = {}
local selectedConnectorName = "" -- empty = all outputs
local available = true
local errorMessage = ""
local cmdNonce = 0
local slideshowMinutes = 0      -- authoritative slideshow value, in minutes, panel-local only
local slideshowDraftValue = nil -- local UI value while dragging the slider; nil = not dragging
local slideshowExpanded = false -- whether the slider row is open

local thumbPaths = {}   -- path -> relative cache path (ready)
local thumbPending = {} -- path -> true while generating
local thumbQueue = {}
local thumbActive = 0

local render

local function tr(key)
  return noctalia.tr(key)
end

--- Shell-safe single-quoting.
--- Note: duplicated here because Noctalia sandboxed plugins don't have `require`
--- to share code between scripts (like panel.luau and mpvpaper_service.luau).
local function shellQuote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function videoDirectory()
  local dir = noctalia.getConfig("video_directory")
  if type(dir) == "string" and dir ~= "" then
    return noctalia.expandPath(dir)
  end
  return (noctalia.getenv("HOME") or "/tmp") .. "/Videos"
end

local function extensionOf(name)
  local ext = name:match("%.([%a%d]+)$")
  return ext and ext:lower() or ""
end

-- ── State ──────────────────────────────────────────────────────────────────

local function refreshAvailability()
  available = noctalia.state.get("available") ~= false
end

local function assignmentFor(connector)
  local assignments = noctalia.state.get("assignments")
  if type(assignments) == "table" then
    return assignments[connector]
  end
  return nil
end

-- Check if the selected output has an active video (including wildcard "*").
local function hasActiveVideo()
  local assignments = noctalia.state.get("assignments")
  if type(assignments) ~= "table" then return false end

  if selectedConnectorName == "" then
    for _, v in pairs(assignments) do
      if v ~= nil then return true end
    end
    return false
  end
  return assignments[selectedConnectorName] ~= nil or assignments["*"] ~= nil
end

-- Check if the selected output is currently paused.
local function isPausedForSelection()
  local paused = noctalia.state.get("paused")
  if type(paused) ~= "table" then return false end

  if selectedConnectorName == "" then
    for _, v in pairs(paused) do
      if v == true then return true end
    end
    return false
  end
  return paused[selectedConnectorName] == true or paused["*"] == true
end

-- Returns true when the selected individual connector has no per-connector
-- assignment but inherits a video from the wildcard ("*") assignment.
-- In this case, pause/stop must be done via "All Outputs" instead.
local function isWildcardOnly()
  if selectedConnectorName == "" then return false end
  return assignmentFor(selectedConnectorName) == nil and assignmentFor("*") ~= nil
end

-- Sends a command to the service. Each payload includes a nonce so the service
-- can distinguish consecutive actions even if the payload values repeat.
local function sendCommand(action, connector, path)
  cmdNonce += 1
  noctalia.state.set("command", { action = action, connector = connector, path = path, nonce = cmdNonce })
end

-- Applies a video (or slideshow playlist) to either all outputs ("*") or the
-- currently selected connector. The service decides whether to treat the path
-- as a single file or a playlist based on its slideshow interval.
local function applyVideo(path)
  local target = selectedConnectorName == "" and "*" or selectedConnectorName
  sendCommand("set", target, path)
  render()
end

local function stopSelected()
  if selectedConnectorName == "" then
    sendCommand("clear-all", nil, nil)
  else
    sendCommand("clear", selectedConnectorName, nil)
  end
  render()
end

local function toggleSelected()
  local action = isPausedForSelection() and "thaw" or "freeze"
  sendCommand(action, selectedConnectorName, nil)
  render()
end

-- ── Slideshow interval ───────────────────────────────────────────────────
-- Panel-local only, aside from a one-time read of the service's last-known
-- value in onOpen. Committing sends seconds to the service (mpvpaper
-- --slideshow expects seconds, the slider itself displays minutes).
-- The slider is deliberately kept simple: it always writes seconds into
-- `slideshowCommand.interval`, and the service persists and applies the new
-- interval to all existing assignments.

local function setSlideshowInterval(minutes)
  cmdNonce += 1
  local seconds = minutes * SECONDS_PER_MINUTE
  noctalia.state.set("slideshowCommand", { interval = seconds, nonce = cmdNonce })
end

-- ── Thumbnails (generated by mpv, which mpvpaper already requires) ──────────

local function cachePath(path)
  return CACHE_DIR .. "/" .. path:gsub("[^%w]", "_") .. ".jpg"
end

local function pumpThumbQueue()
  while thumbActive < THUMB_MAX_CONCURRENT and #thumbQueue > 0 do
    local path = table.remove(thumbQueue, 1)
    if thumbPaths[path] == nil and not thumbPending[path] then
      thumbPending[path] = true
      thumbActive += 1
      local dest = cachePath(path)
      local tmpdir = dest .. ".d"
      -- mpv's image VO writes 00000001.jpg into an output dir (the encode path -o
      -- file.jpg is not available on every mpv build); move it to the cache name.
      local cmd = "mkdir -p " .. shellQuote(tmpdir) ..
        " && mpv " .. shellQuote(path) ..
        " --no-config --no-terminal --really-quiet --frames=1 --start=10% --no-audio" ..
        " --vo=image --vo-image-format=jpg --vo-image-outdir=" .. shellQuote(tmpdir) ..
        " && mv " .. shellQuote(tmpdir .. "/00000001.jpg") .. " " .. shellQuote(dest) ..
        "; rm -rf " .. shellQuote(tmpdir)
      noctalia.runAsync(cmd, function(result)
        thumbActive -= 1
        thumbPending[path] = nil
        if result and noctalia.fileExists(dest) then
          thumbPaths[path] = dest
          render()
        end
        pumpThumbQueue()
      end, 20000)
    end
  end
end

local function queueThumb(video)
  if video.ext == "gif" then
    -- Animated GIF: the host decoder shows the first frame directly, no extraction.
    thumbPaths[video.path] = video.path
    return
  end
  if thumbPaths[video.path] ~= nil or thumbPending[video.path] then
    return
  end
  table.insert(thumbQueue, video.path)
  pumpThumbQueue()
end

-- ── Loading ────────────────────────────────────────────────────────────────

local function loadVideos()
  videos = {}
  errorMessage = ""
  local dir = videoDirectory()
  local entries = noctalia.listDir(dir)
  if type(entries) ~= "table" then
    errorMessage = tr("empty")
    return
  end
  for _, name in ipairs(entries) do
    local ext = extensionOf(name)
    if VIDEO_EXTENSIONS[ext] then
      table.insert(videos, { path = dir .. "/" .. name, name = name, ext = ext })
    end
  end
  table.sort(videos, function(a, b) return a.name < b.name end)
  page = 1

  noctalia.runAsync("mkdir -p " .. shellQuote(CACHE_DIR), function()
    for _, video in ipairs(videos) do
      queueThumb(video)
    end
  end)
end

local function refreshOutputs()
  outputsList = noctalia.outputs() or {}
  if selectedConnectorName ~= "" then
    for _, output in ipairs(outputsList) do
      if output.name == selectedConnectorName then
        return
      end
    end
    noctalia.log("mpvpaper: selected output is no longer available: " .. selectedConnectorName)
    selectedConnectorName = ""
  end
end

-- ── Rendering ──────────────────────────────────────────────────────────────

local function totalPages()
  return math.max(1, math.ceil(#videos / PAGE_SIZE))
end

local function outputOptions()
  local options = { tr("all_outputs") }
  for _, output in ipairs(outputsList) do
    table.insert(options, output.name)
  end
  return options
end

local function selectedOutputIndex()
  if selectedConnectorName == "" then
    return 0
  end
  for i, output in ipairs(outputsList) do
    if output.name == selectedConnectorName then
      return i
    end
  end
  return 0
end

local function columnWidth()
  return math.floor(((PANEL_WIDTH - PANEL_PADDING) - COLUMN_GAP * (COLUMNS - 1)) / COLUMNS)
end

local function tileSize()
  local width = columnWidth()
  return width, math.floor(width * 9 / 16)
end

local function isAssignedToSelection(path)
  -- If this video is currently assigned as the wildcard ("*") wallpaper,
  -- it should show as selected regardless of which output the user is looking at.
  if assignmentFor("*") == path then
    return true
  end

  -- Otherwise, check if it's assigned to the currently selected output.
  if selectedConnectorName == "" then
    for _, output in ipairs(outputsList) do
      if assignmentFor(output.name) == path then
        return true
      end
    end
    return false
  end
  return assignmentFor(selectedConnectorName) == path
end

local function videoTile(video)
  local frameWidth, frameHeight = tileSize()
  local path = video.path
  local selected = isAssignedToSelection(path)
  local thumb = thumbPaths[path]
  local onClick = function()
    applyVideo(path)
  end

  local preview
  if thumb ~= nil then
    preview = ui.image({
      width = frameWidth,
      height = frameHeight,
      path = thumb,
      fit = "cover",
      radius = TILE_RADIUS,
      border = selected and "primary" or "outline",
      borderWidth = selected and 3 or 1,
      onClick = onClick,
    })
  else
    preview = ui.box({
      width = frameWidth,
      height = frameHeight,
      fill = "surface_variant",
      radius = TILE_RADIUS,
      border = selected and "primary" or "outline",
      borderWidth = selected and 3 or 1,
      onClick = onClick,
    })
  end

  return ui.column({ gap = 4, key = video.path, flexGrow = 1, align = "center" }, {
    preview,
    ui.label({
      text = video.name,
      fontSize = 11,
      color = selected and "primary" or "on_surface_variant",
      maxLines = 1,
      maxWidth = frameWidth,
      textAlign = "center",
    }),
  })
end

local function videoGrid()
  if #videos == 0 then
    return ui.label({ text = errorMessage ~= "" and errorMessage or tr("empty"), color = "on_surface_variant" })
  end

  local first = (page - 1) * PAGE_SIZE + 1
  local last = math.min(first + PAGE_SIZE - 1, #videos)
  local rows = {}
  local row = {}
  for i = first, last do
    table.insert(row, videoTile(videos[i]))
    if #row == COLUMNS or i == last then
      table.insert(rows, ui.row({ gap = COLUMN_GAP, align = "stretch" }, row))
      row = {}
    end
  end
  return ui.column({ gap = 12, align = "stretch" }, rows)
end

local function slideshowValueLabel(minutes)
  if minutes <= 0 then return tr("slideshow_off") end
  return tostring(minutes) .. "m"
end

local function slideshowToggleButton()
  local current = slideshowDraftValue or slideshowMinutes
  return ui.button({
    text = tr("slideshow") .. ": " .. slideshowValueLabel(current),
    glyph = slideshowExpanded and "chevron-right" or "chevron-left",
    variant = "outline",
    onClick = function()
      slideshowExpanded = not slideshowExpanded
      render()
    end,
  })
end

render = function()
  refreshAvailability()
  refreshOutputs()
  local options = outputOptions()
  local selectedIndex = selectedOutputIndex()

  if not available then
    panel.render(ui.column({ flexGrow = 1, gap = 12, align = "center", justify = "center" }, {
      ui.glyph({ name = "movie-off", size = 48, color = "on_surface_variant" }),
      ui.label({ text = tr("not_installed"), color = "error", textAlign = "center" }),
    }))
    return
  end

  local paused = isPausedForSelection()
  local pauseBtnText = paused and tr("resume") or tr("pause")
  local pauseBtnGlyph = paused and "player-play" or "player-pause"
  local hasVideo = hasActiveVideo()
  local wildcardOnly = isWildcardOnly()
  local pauseEnabled = hasVideo and not wildcardOnly
  local stopEnabled = hasVideo and not wildcardOnly

  -- Lock the output selector if "All Outputs" (*) is currently playing a video.
  local selectEnabled = assignmentFor("*") == nil

  local mainChildren = {
    ui.row({ align = "center", justify = "space_between", gap = 8 }, {
      ui.label({ text = tr("title"), fontSize = 16, fontWeight = "bold", color = "on_surface", flexGrow = 1 }),
      ui.button({ glyph = "close", onClick = "onClose" }),
    }),

    slideshowExpanded and ui.row({ gap = 8, align = "center" }, {
      ui.slider({
        min = SLIDESHOW_MIN_MINUTES,
        max = SLIDESHOW_MAX_MINUTES,
        step = 1,
        value = slideshowDraftValue or slideshowMinutes,
        flexGrow = 1,
        onChange = function(value)
          slideshowDraftValue = tonumber(value) or slideshowDraftValue or 0
          render()
        end,
        onDragEnd = function(_)
          local minutes = slideshowDraftValue or slideshowMinutes
          slideshowDraftValue = nil
          slideshowMinutes = minutes
          setSlideshowInterval(minutes)
          render()
        end,
      }),
      slideshowToggleButton(),
    }) or ui.row({ gap = 8, align = "center" }, {
      ui.label({ text = tr("output"), fontSize = 12, color = "on_surface_variant" }),
      ui.select({
        key = "output",
        options = options,
        selectedIndex = selectedIndex,
        onChange = "onOutputChange",
        flexGrow = 1,
        enabled = selectEnabled,
      }),
      ui.button({ text = pauseBtnText, glyph = pauseBtnGlyph, variant = "outline", onClick = "onToggle", enabled = pauseEnabled }),
      ui.button({ text = tr("stop"), glyph = "player-stop", variant = "outline", onClick = "onStop", enabled = stopEnabled }),
      slideshowToggleButton(),
    }),
  }

  table.insert(mainChildren, ui.scroll({ flexGrow = 1, gap = 12 }, {
    videoGrid(),
  }))

  table.insert(mainChildren, ui.row({ align = "center", justify = "space_between", gap = 8 }, {
    ui.button({ glyph = "chevron-left", variant = "ghost", onClick = "onPrevPage", enabled = page > 1 }),
    ui.label({ text = `{page} / {totalPages()}`, color = "on_surface_variant" }),
    ui.button({ glyph = "chevron-right", variant = "ghost", onClick = "onNextPage", enabled = page < totalPages() }),
  }))

  panel.render(ui.column({ flexGrow = 1, gap = 12, align = "stretch" }, mainChildren))
end

-- ── Callbacks ──────────────────────────────────────────────────────────────

function onOpen(_context)
  -- Seed the slider from the service's last-known interval (seconds). This
  -- ensures the panel shows the right value after restarts.
  local override = noctalia.state.get("slideshowOverride")
  if type(override) == "number" then
    slideshowMinutes = math.floor(override / SECONDS_PER_MINUTE)
  else
    slideshowMinutes = 0
  end

  refreshOutputs()
  loadVideos()
  render()
end

function onOutputChange(index, label)
  local optionIndex = tonumber(index)
  if optionIndex == nil then
    noctalia.log("mpvpaper: invalid output selection index: " .. tostring(index))
    return
  end
  if optionIndex == 0 then
    selectedConnectorName = ""
  elseif type(label) == "string" and label ~= "" then
    selectedConnectorName = label
  else
    noctalia.log("mpvpaper: invalid output selection label: " .. tostring(label))
    return
  end
  render()
end

function onStop()
  stopSelected()
end

function onToggle()
  toggleSelected()
end

function onPrevPage()
  if page > 1 then
    page -= 1
    render()
  end
end

function onNextPage()
  if page < totalPages() then
    page += 1
    render()
  end
end

function onClose()
  panel.close()
end

-- Re-render when the service publishes new assignments (tile highlights).
-- This keeps the UI in sync when the slideshow advances and the service
-- updates the active file for a connector.
noctalia.state.watch("assignments", function(_)
  render()
end)

-- Re-render when the paused state changes (button text).
noctalia.state.watch("paused", function(_)
  render()
end)

noctalia.state.watch("slideshowOverride", function(value)
  if type(value) ~= "number" then return end
  if slideshowDraftValue ~= nil then return end -- don't fight an in-progress drag
  slideshowMinutes = math.floor(value / SECONDS_PER_MINUTE)
  render()
end)
