--!nonstrict
-- Wallhaven wallpaper browser panel.
--
-- Browse search results with category and purity filters and pagination. Clicking a result
-- previews the full image from the cache; only applying it moves it into the configured
-- wallpaper directory and calls noctalia.setWallpaper.

local API_BASE = "https://wallhaven.cc/api/v1"
local CACHE_DIR = (noctalia.getenv("XDG_STATE_HOME") or ((noctalia.getenv("HOME") or "") .. "/.local/state")) .. "/noctalia/wallhaven/thumbs"
local PANEL_WIDTH = 920
local PANEL_PADDING = 28 -- Style::panelPadding * 2 on the host surface
local COLUMNS = 4
local COLUMN_GAP = 12
local THUMB_MAX_CONCURRENT = 6 -- host allows 8 async HTTP ops per plugin
local TILE_FRAME_RADIUS = 12
local TILE_BORDER_SFW = 1
local TILE_BORDER_RATED = 3
local TILE_BORDER_SELECTED = 3
local TILE_LABEL_GAP = 4
local TILE_LABEL_FONT = 11
local PREVIEW_HEIGHT = 640 -- what the panel leaves between its header and the preview buttons
local PREVIEW_PROGRESS_MS = 100
local PREVIEW_PROGRESS_WIDTH = 240

local closeButton = true

local query = ""
local page = 1
local totalPages = 1
local wallpapers = {}
local loading = false
local errorMessage = ""
local selectedId = ""
local preview = nil -- wallpaper being previewed
local previewPath = nil -- its full image, once downloaded
local previewProgress = 0 -- 0..1 while downloading
local previewTickMs = 0
local applying = false
local fitEnabled = false
local cropX = 0.5
local cropY = 0.5
local cropDragX = 0
local cropDragY = 0
local cropDragging = false
local cropSession = 0
local cropProducerActive = false
local cropProducerStartedAt = 0
local previewStreaming = false
local previewImageW = nil
local previewImageH = nil

local puritySfw = true
local puritySketchy = false
local purityNsfw = false

local categoryGeneral = true
local categoryAnime = true
local categoryPeople = true

local resolutionMode = "atleast" -- "atleast" or "exact"
local resolutionWidth = ""
local resolutionHeight = ""
local aspectRatioIndex = 0
local clearCounter = 0
local pageInputCounter = 0
local pageEditing = false

local thumbPaths = {} -- id -> cache file path
local thumbPending = {} -- id -> true while downloading
local thumbQueue = {} -- wallpapers waiting for a download slot
local thumbActive = 0
local needsInitialFetch = false

local render
local fetchWallpapers
local openPreview
local focusedOutputSize
local parsePositiveInt

local sortOptions = { "relevance", "random", "date_added", "views", "favorites", "toplist", "hot" }
local sortIndex = 2
local sortOrder = "desc"

local function tr(key, subst)
  return noctalia.tr(key, subst)
end

local function sortLabelList()
  return {
    tr("sort.options.relevance"),
    tr("sort.options.random"),
    tr("sort.options.date_added"),
    tr("sort.options.views"),
    tr("sort.options.favorites"),
    tr("sort.options.toplist"),
    tr("sort.options.hot")
  }
end

local function shellQuote(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function apiKey()
  local key = noctalia.getConfig("api_key")
  if type(key) == "string" then
    return key
  end
  return ""
end

local function nsfwAllowed()
  return apiKey() ~= ""
end

local function normalizePurityFilters()
  if not nsfwAllowed() then
    purityNsfw = false
  end
end

local function downloadDir()
  local dir = noctalia.getConfig("download_dir")
  if type(dir) == "string" and dir ~= "" then
    return noctalia.expandPath(dir)
  end
  local wallpaperDir = noctalia.wallpaperDirectory()
  if type(wallpaperDir) == "string" and wallpaperDir ~= "" then
    return noctalia.expandPath(wallpaperDir)
  end
  return noctalia.expandPath("~/Pictures/Wallpapers")
end

local function buildPurity()
  local sfw = puritySfw and "1" or "0"
  local sketchy = puritySketchy and "1" or "0"
  local nsfw = purityNsfw and nsfwAllowed() and "1" or "0"
  local purity = sfw .. sketchy .. nsfw
  if purity == "000" then
    return "100"
  end
  return purity
end

local function buildCategories()
  local general = categoryGeneral and "1" or "0"
  local anime = categoryAnime and "1" or "0"
  local people = categoryPeople and "1" or "0"
  local categories = general .. anime .. people
  if categories == "000" then
    return "100"
  end
  return categories
end

local function sortValue()
  return sortOptions[sortIndex + 1] or "date_added"
end

local function sortIsRandom()
  return sortValue() == "random"
end

-- Wallhaven returns an empty first page for relevance when no search query is set.
local function relevanceWithoutQuery()
  return sortValue() == "relevance" and noctalia.string.trim(query) == ""
end

local function apiPage()
  if relevanceWithoutQuery() then
    return page + 1
  end
  return page
end

local function normalizeTotalPages(lastPage)
  if relevanceWithoutQuery() then
    return math.max(1, lastPage - 1)
  end
  return lastPage
end

local function aspectRatioOptions()
  return {
    "",
    "mine",
    "wide",
    "portrait",
    "16x9",
    "16x10",
    "21x9",
    "32x9",
    "48x9",
    "9x16",
    "10x16",
    "9x18",
    "1x1",
    "3x2",
    "4x3",
    "5x4",
  }
end

local function aspectRatioOption()
  return aspectRatioOptions()[aspectRatioIndex + 1] or ""
end

local function monitorAspectRatioStandard()
  local width, height = focusedOutputSize()
  if width == nil or height == nil then
    return nil
  end
  local ratio = width / height
  local standards = {
    { 16, 9 },
    { 16, 10 },
    { 21, 9 },
    { 32, 9 },
    { 48, 9 },
    { 9, 16 },
    { 10, 16 },
    { 9, 18 },
    { 1, 1 },
    { 3, 2 },
    { 4, 3 },
    { 5, 4 },
  }
  local bestWidth, bestHeight, bestDiff = nil, nil, nil
  for _, standard in ipairs(standards) do
    local diff = math.abs(ratio - standard[1] / standard[2])
    if bestDiff == nil or diff < bestDiff then
      bestWidth, bestHeight, bestDiff = standard[1], standard[2], diff
    end
  end
  if bestWidth ~= nil and bestDiff <= 0.12 then
    return `{bestWidth}x{bestHeight}`
  end
  local a, b = width, height
  while b ~= 0 do
    a, b = b, a % b
  end
  local divisor = math.max(1, a)
  return `{math.floor(width / divisor)}x{math.floor(height / divisor)}`
end

local function monitorAspectRatioLabel()
  local ratio = monitorAspectRatioStandard()
  if ratio == nil then
    return tr("ratio_mine_unknown")
  end
  return tr("ratio_mine", { ratio = ratio:gsub("x", ":") })
end

local function aspectRatioLabelList()
  return {
    tr("ratio_any"),
    monitorAspectRatioLabel(),
    tr("ratio_wide"),
    tr("ratio_portrait"),
    "16:9",
    "16:10",
    "21:9",
    "32:9",
    "48:9",
    "9:16",
    "10:16",
    "9:18",
    "1:1",
    "3:2",
    "4:3",
    "5:4",
  }
end

local function aspectRatioFilterValue()
  if aspectRatioOption() == "mine" then
    local width, height = focusedOutputSize()
    if width ~= nil and height ~= nil then
      return `{width}x{height}`
    end
    return ""
  end
  return aspectRatioOption()
end

local function aspectRatioParamValue()
  local ratio = aspectRatioOption()
  if ratio == "" then return nil end
  if ratio == "mine" then return monitorAspectRatioStandard() end
  if ratio == "wide" then return "landscape" end
  if ratio == "portrait" then return "portrait" end
  return ratio
end

local function aspectRatioTolerance()
  return if aspectRatioOption() == "mine" then 0.08 else 0.05
end

local function monitorResolutionText()
  local width, height = focusedOutputSize()
  if width == nil or height == nil then
    return nil
  end
  return `{width}x{height}`
end

local function monitorResolutionLabel()
  local resolution = monitorResolutionText()
  if resolution == nil then
    return tr("resolution_mode_mine_unknown")
  end
  return tr("resolution_mode_mine", { resolution = resolution })
end

local function monitorAtLeastResolutionLabel()
  local resolution = monitorResolutionText()
  if resolution == nil then
    return tr("resolution_mode_mine_unknown")
  end
  return tr("resolution_mode_atleast_mine", { resolution = resolution })
end

local function resolutionUsesMonitor()
  return resolutionMode == "mine" or resolutionMode == "atleast_mine"
end

local function resolutionModeOptions()
  return { "atleast", "exact", "mine", "atleast_mine" }
end

local function resolutionModeLabelList()
  return {
    tr("resolution_mode_atleast"),
    tr("resolution_mode_exact"),
    monitorResolutionLabel(),
    monitorAtLeastResolutionLabel(),
  }
end

local function resolutionModeIndex()
  if resolutionMode == "exact" then
    return 1
  end
  if resolutionMode == "mine" then
    return 2
  end
  if resolutionMode == "atleast_mine" then
    return 3
  end
  return 0
end

parsePositiveInt = function(s)
  local n = tonumber(s)
  if n == nil or n < 1 or math.floor(n) ~= n then
    return nil
  end
  return n
end

local function buildResolutionParam()
  if resolutionUsesMonitor() then
    local monitorWidth, monitorHeight = focusedOutputSize()
    if monitorWidth ~= nil and monitorHeight ~= nil then
      local resolution = `{monitorWidth}x{monitorHeight}`
      if resolutionMode == "atleast_mine" then
        return "atleast", resolution
      end
      return "resolutions", resolution
    end
    return nil, nil
  end
  local w = parsePositiveInt(resolutionWidth)
  local h = parsePositiveInt(resolutionHeight)
  if w ~= nil and h ~= nil then
    local resolution = tostring(w) .. "x" .. tostring(h)
    if resolutionMode == "atleast" then
      return "atleast", resolution
    else
      return "resolutions", resolution
    end
  end
  return nil, nil
end

local function filterChip(label, active, onClick, key, enabled)
  return ui.button({
    key = key,
    text = label,
    variant = if active then "primary" else "outline",
    onClick = onClick,
    enabled = if enabled == nil then true else enabled,
  })
end

local function filterGroup(title, content, flexGrow)
  return ui.row({ gap = 6, align = "center", flexGrow = flexGrow }, {
    ui.label({
      text = title,
      fontSize = 12,
      color = "on_surface_variant",
    }),
    content,
  })
end

local function filtersPanel()
  local resolutionControls = {
    ui.select({
      -- Recreate the select when its width mode changes; otherwise the widget
      -- keeps the expanded width after switching back from a monitor mode.
      key = if resolutionUsesMonitor() then "resolution_mode_mine" else "resolution_mode_compact",
      options = resolutionModeLabelList(),
      selectedIndex = resolutionModeIndex(),
      onChange = "onResolutionModeChange",
      width = if resolutionUsesMonitor() then nil else 210,
      flexGrow = if resolutionUsesMonitor() then 1 else 0,
    }),
  }
  if not resolutionUsesMonitor() then
    table.insert(resolutionControls, ui.input({
      key = `resolution_width_{clearCounter}`,
      placeholder = tr("resolution_width_placeholder"),
      value = resolutionWidth,
      onChange = "onResolutionWidthChange",
      onSubmit = "onResolutionWidthSubmit",
      flexGrow = 1,
    }))
    table.insert(resolutionControls, ui.label({
      text = "×",
      fontSize = 14,
      color = "on_surface_variant",
    }))
    table.insert(resolutionControls, ui.input({
      key = `resolution_height_{clearCounter}`,
      placeholder = tr("resolution_height_placeholder"),
      value = resolutionHeight,
      onChange = "onResolutionHeightChange",
      onSubmit = "onResolutionHeightSubmit",
      flexGrow = 1,
    }))
  end

  local rows = {
    ui.row({ gap = 16, align = "center" }, {
      filterGroup(tr("filter_categories"), ui.row({ gap = 6, align = "center" }, {
        filterChip(tr("category_general"), categoryGeneral, "onCategoryGeneral", "filter_cat_general"),
        filterChip(tr("category_anime"), categoryAnime, "onCategoryAnime", "filter_cat_anime"),
        filterChip(tr("category_people"), categoryPeople, "onCategoryPeople", "filter_cat_people"),
      })),
      filterGroup(tr("filter_purity"), ui.row({ gap = 6, align = "center" }, {
        filterChip(tr("purity_sfw"), puritySfw, "onPuritySfw", "filter_purity_sfw"),
        filterChip(tr("purity_sketchy"), puritySketchy, "onPuritySketchy", "filter_purity_sketchy"),
        filterChip(tr("purity_nsfw"), purityNsfw, "onPurityNsfw", "filter_purity_nsfw", nsfwAllowed()),
      })),
      filterGroup(tr("filter_sort"), ui.row({ gap = 4, align = "center", flexGrow = 1 }, {
        ui.select({
          key = "sort",
          options = sortLabelList(),
          selectedIndex = sortIndex,
          onChange = "onSort",
          flexGrow = 1,
        }),
        ui.button({
          key = "sort_order",
          glyph = if sortIsRandom() then "arrows-shuffle" elseif sortOrder == "desc" then "arrow-down" else "arrow-up",
          tooltip = if sortIsRandom() then tr("sort_shuffle") elseif sortOrder == "desc" then tr("sort_desc") else tr("sort_asc"),
          variant = "outline",
          onClick = "onToggleSortOrder",
        }),
      }), 1),
    }),
    ui.row({ gap = 12, align = "center" }, {
      filterGroup(tr("filter_aspect_ratio"), ui.row({ flexGrow = 0 }, {
        ui.select({
          key = "aspect_ratio",
          options = aspectRatioLabelList(),
          selectedIndex = aspectRatioIndex,
          onChange = "onAspectRatioChange",
          width = 210,
        })
      })),
      filterGroup(tr("filter_resolution"), ui.row({ gap = 8, align = "center", flexGrow = 1 }, resolutionControls), 1),
      ui.button({
        key = "clear_resolution",
        text = tr("clear_resolution"),
        variant = "destructive",
        onClick = "onClearResolution",
      }),
    }),
  }

  return ui.column({ gap = 12, align = "stretch" }, rows)
end

local function httpHeaders()
  local headers = { "Accept: application/json" }
  local key = apiKey()
  if key ~= "" then
    table.insert(headers, "X-API-Key: " .. key)
  end
  return headers
end

local function ensureCacheDir(done)
  noctalia.runAsync(`mkdir -p {shellQuote(CACHE_DIR)}`, done)
end

local function thumbCachePath(id)
  return `{CACHE_DIR}/{id}.jpg`
end

local function columnWidth()
  local gridWidth = PANEL_WIDTH - PANEL_PADDING
  return math.floor((gridWidth - COLUMN_GAP * (COLUMNS - 1)) / COLUMNS)
end

local function tileThumbSize()
  local width = columnWidth()
  local height = math.floor(width * 9 / 16)
  return width, height
end

local function pumpThumbQueue()
  while thumbActive < THUMB_MAX_CONCURRENT and #thumbQueue > 0 do
    local wallpaper = table.remove(thumbQueue, 1)
    local id = wallpaper.id
    if thumbPaths[id] == nil and not thumbPending[id] then
      local thumbUrl = wallpaper.thumbs and wallpaper.thumbs.large
      if type(thumbUrl) == "string" and thumbUrl ~= "" then
        thumbPending[id] = true
        thumbActive += 1
        local dest = thumbCachePath(id)
        local started = noctalia.download(thumbUrl, dest, function(ok)
          thumbActive -= 1
          thumbPending[id] = nil
          if ok then
            thumbPaths[id] = dest
            render()
          end
          pumpThumbQueue()
        end)
        if not started then
          thumbActive -= 1
          thumbPending[id] = nil
          table.insert(thumbQueue, 1, wallpaper)
          break
        end
      end
    end
  end
end

local function queueThumbDownload(wallpaper)
  local id = wallpaper.id
  if thumbPaths[id] ~= nil or thumbPending[id] then
    return
  end
  local thumbUrl = wallpaper.thumbs and wallpaper.thumbs.large
  if type(thumbUrl) ~= "string" or thumbUrl == "" then
    return
  end
  table.insert(thumbQueue, wallpaper)
  pumpThumbQueue()
end

local function pickWallpaper(id)
  selectedId = id
  openPreview(id)
end

local function fileExtension(wallpaper)
  if wallpaper.file_type == "image/png" then
    return ".png"
  end
  return ".jpg"
end

focusedOutputSize = function()
  local outputs = noctalia.outputs()
  if type(outputs) ~= "table" then
    return nil
  end
  local focusedName = noctalia.focusedOutputName()
  local fallback = nil
  for _, output in ipairs(outputs) do
    if output.focused then
      return output.width, output.height
    end
    if fallback == nil then
      fallback = output
    end
  end
  if focusedName ~= nil then
    for _, output in ipairs(outputs) do
      if output.name == focusedName then
        return output.width, output.height
      end
    end
  end
  if fallback ~= nil then
    return fallback.width, fallback.height
  end
  return nil
end

local function clamp(value, low, high)
  if value < low then
    return low
  end
  if value > high then
    return high
  end
  return value
end

local function cropImageRect()
  local imageWidth, imageHeight = previewImageW, previewImageH
  if imageWidth == nil or imageHeight == nil then
    return nil
  end
  local width = PANEL_WIDTH - PANEL_PADDING
  local height = PREVIEW_HEIGHT
  local scale = math.min(width / imageWidth, height / imageHeight)
  local displayWidth = imageWidth * scale
  local displayHeight = imageHeight * scale
  return (width - displayWidth) / 2, (height - displayHeight) / 2, displayWidth, displayHeight
end

local function cropBoxNormalized()
  local imageWidth, imageHeight = previewImageW, previewImageH
  local monitorWidth, monitorHeight = focusedOutputSize()
  if imageWidth == nil or imageHeight == nil or monitorWidth == nil or monitorHeight == nil then
    return nil
  end
  local scale = math.min(1, imageWidth / monitorWidth, imageHeight / monitorHeight)
  return (monitorWidth * scale) / imageWidth, (monitorHeight * scale) / imageHeight
end

local function clampCropCenter()
  local boxWidth, boxHeight = cropBoxNormalized()
  if boxWidth == nil or boxHeight == nil then
    return
  end
  local minX = math.min(0.5, boxWidth / 2)
  local maxX = math.max(0.5, 1 - boxWidth / 2)
  local minY = math.min(0.5, boxHeight / 2)
  local maxY = math.max(0.5, 1 - boxHeight / 2)
  cropX = clamp(cropX, minX, maxX)
  cropY = clamp(cropY, minY, maxY)
end

local function cropRect()
  local imageWidth, imageHeight = previewImageW, previewImageH
  local monitorWidth, monitorHeight = focusedOutputSize()
  if imageWidth == nil or imageHeight == nil or monitorWidth == nil or monitorHeight == nil then
    return nil
  end
  local scale = math.min(1, imageWidth / monitorWidth, imageHeight / monitorHeight)
  local width = math.floor(monitorWidth * scale + 0.5)
  local height = math.floor(monitorHeight * scale + 0.5)
  width = math.max(1, math.min(width, imageWidth))
  height = math.max(1, math.min(height, imageHeight))
  local x = math.floor(cropX * imageWidth - width / 2 + 0.5)
  local y = math.floor(cropY * imageHeight - height / 2 + 0.5)
  x = math.max(0, math.min(x, imageWidth - width))
  y = math.max(0, math.min(y, imageHeight - height))
  return x, y, width, height, monitorWidth, monitorHeight
end

local function cropDirectory()
  local stateHome = noctalia.getenv("XDG_STATE_HOME") or ((noctalia.getenv("HOME") or "") .. "/.local/state")
  return stateHome .. "/noctalia/wallhaven/crop"
end

local function cropSocketPath()
  local id = if preview ~= nil then preview.id else "idle"
  return `{cropDirectory()}/stream-{id}-{cropSession}.sock`
end

local function cropStatePath()
  local id = if preview ~= nil then preview.id else "idle"
  return `{cropDirectory()}/state-{id}-{cropSession}.json`
end

local function writeCropState()
  if preview == nil or previewImageW == nil or previewImageH == nil then
    return
  end
  noctalia.mkdirAll(cropDirectory())
  local monitorWidth, monitorHeight = focusedOutputSize()
  local data = noctalia.json.encode({
    fit = fitEnabled,
    cx = cropX,
    cy = cropY,
    monitorWidth = monitorWidth or 0,
    monitorHeight = monitorHeight or 0,
  })
  if data ~= nil then
    noctalia.writeFile(cropStatePath(), data)
  end
end

local function stopCropProducer()
  cropProducerActive = false
  if preview == nil then
    return
  end
  local data = noctalia.json.encode({ quit = true })
  if data ~= nil then
    noctalia.mkdirAll(cropDirectory())
    noctalia.writeFile(cropStatePath(), data)
  end
end

local function startCropProducer()
  if previewPath == nil or previewImageW == nil or previewImageH == nil then
    return
  end
  if not noctalia.commandExists("python3") or not noctalia.commandExists("magick") then
    return
  end
  cropSession += 1
  cropProducerActive = true
  cropProducerStartedAt = noctalia.nowMs()
  writeCropState()
  local script = (noctalia.pluginDir() or "") .. "/crop_stream.py"
  -- Detached: this process lives as long as the preview. Passing a callback
  -- would make runAsync wait and kill it at the command timeout.
  local started = noctalia.runAsync({
    "python3",
    script,
    "--socket", cropSocketPath(),
    "--state", cropStatePath(),
    "--image", previewPath,
    "--image-width", tostring(previewImageW),
    "--image-height", tostring(previewImageH),
    "--width", tostring(PANEL_WIDTH - PANEL_PADDING),
    "--height", tostring(PREVIEW_HEIGHT),
  })
  if not started then
    cropProducerActive = false
  end
end

local function ensureCropProducer()
  if cropProducerActive then
    -- A missing socket right after launch means the producer is still loading
    -- the image. Only replace a producer that has had time to start and whose
    -- socket is gone (idle exit or crash).
    if noctalia.fileExists(cropSocketPath()) or noctalia.nowMs() - cropProducerStartedAt < 5000 then
      writeCropState()
      return
    end
    cropProducerActive = false
  end
  startCropProducer()
end

local function pointerToImage(normX, normY)
  local displayX, displayY, displayWidth, displayHeight = cropImageRect()
  if displayX == nil then
    return nil
  end
  local x = (tonumber(normX) or 0) * (PANEL_WIDTH - PANEL_PADDING)
  local y = (tonumber(normY) or 0) * PREVIEW_HEIGHT
  return (x - displayX) / displayWidth, (y - displayY) / displayHeight
end

function onCropDown(normX, normY)
  if not fitEnabled or previewPath == nil then
    return
  end
  local x, y = pointerToImage(normX, normY)
  if x == nil then
    return
  end
  local boxWidth, boxHeight = cropBoxNormalized()
  if boxWidth ~= nil
      and math.abs(x - cropX) <= boxWidth / 2
      and math.abs(y - cropY) <= boxHeight / 2 then
    cropDragX = cropX - x
    cropDragY = cropY - y
  else
    cropDragX = 0
    cropDragY = 0
    cropX = clamp(x, 0, 1)
    cropY = clamp(y, 0, 1)
    clampCropCenter()
    writeCropState()
  end
  cropDragging = true
end

function onCropMove(normX, normY)
  if not cropDragging or not fitEnabled then
    return
  end
  local x, y = pointerToImage(normX, normY)
  if x == nil then
    return
  end
  cropX = clamp(x + cropDragX, 0, 1)
  cropY = clamp(y + cropDragY, 0, 1)
  clampCropCenter()
  writeCropState()
end

function onCropUp(_normX, _normY)
  cropDragging = false
end

function onCropCancel()
  cropDragging = false
end

local function findWallpaper(id)
  for _, wallpaper in wallpapers do
    if wallpaper.id == id then
      return wallpaper
    end
  end
  return nil
end

local function previewCachePath(wallpaper)
  return `{CACHE_DIR}/{wallpaper.id}-full{fileExtension(wallpaper)}`
end

local function closePreview()
  if preview == nil or applying then
    return
  end
  stopCropProducer()
  if previewPath ~= nil then
    noctalia.removeFile(previewPath)
  end
  preview = nil
  previewPath = nil
  previewImageW = nil
  previewImageH = nil
  cropDragging = false
end

openPreview = function(id)
  local wallpaper = findWallpaper(id)
  local imageUrl = wallpaper and wallpaper.path
  if type(imageUrl) ~= "string" or imageUrl == "" then
    noctalia.notifyError(tr("title"), tr("download_failed"))
    return
  end

  local dest = previewCachePath(wallpaper)
  preview = wallpaper
  previewPath = nil
  previewProgress = 0
  previewImageW = nil
  previewImageH = nil
  cropX = 0.5
  cropY = 0.5
  cropDragging = false
  fitEnabled = false
  previewStreaming = false
  if type(wallpaper.resolution) == "string" then
    local width, height = wallpaper.resolution:match("^(%d+)x(%d+)$")
    if width ~= nil and height ~= nil then
      previewImageW = tonumber(width)
      previewImageH = tonumber(height)
    end
  end
  render()

  local started = noctalia.download(imageUrl, dest, function(ok)
    if preview == nil or preview.id ~= id then
      noctalia.removeFile(dest) -- left the preview while this was downloading
      return
    end
    if ok then
      previewPath = dest
      noctalia.runAsync({ "magick", "identify", "-format", "%w %h", dest }, function(res)
        if previewPath ~= dest or res == nil or res.exitCode ~= 0 then
          return
        end
        local width, height = res.stdout:match("(%d+)%s+(%d+)")
        if width ~= nil and height ~= nil then
          previewImageW = tonumber(width)
          previewImageH = tonumber(height)
          ensureCropProducer()
          render()
        end
      end)
    else
      closePreview()
      noctalia.notifyError(tr("title"), tr("download_failed"))
    end
    render()
  end)
  if not started then
    closePreview()
    noctalia.notifyError(tr("title"), tr("download_failed"))
    render()
    return
  end
  panel.setNeedsFrameTick(true)
end

local function parseSearchResponse(body)
  local decoded = noctalia.json.decode(body)
  if type(decoded) ~= "table" then
    return nil, tr("error")
  end
  if type(decoded.data) ~= "table" then
    local err = decoded.error or tr("error")
    return nil, tostring(err)
  end
  local meta = decoded.meta
  local lastPage = 1
  if type(meta) == "table" and type(meta.last_page) == "number" then
    lastPage = math.max(1, math.floor(meta.last_page))
  end
  return decoded.data, nil, lastPage
end

fetchWallpapers = function()
  if loading then
    return
  end
  loading = true
  errorMessage = ""
  render()

  local params = {
    `categories={buildCategories()}`,
    `purity={buildPurity()}`,
    `page={apiPage()}`,
    `sorting={sortValue()}`,
    `order={sortOrder}`,
  }

  local trimmed = noctalia.string.trim(query)
  if trimmed ~= "" then
    table.insert(params, `q={noctalia.string.urlEncode(trimmed)}`)
  end

  local resolutionParamName, resolutionValue = buildResolutionParam()
  if resolutionParamName ~= nil and resolutionValue ~= nil then
    table.insert(params, `{resolutionParamName}={resolutionValue}`)
  end

  local aspectRatio = aspectRatioParamValue()
  if aspectRatio ~= nil then
    table.insert(params, `ratios={aspectRatio}`)
  end

  local url = API_BASE .. "/search?" .. table.concat(params, "&")

  noctalia.http({ url = url, headers = httpHeaders() }, function(res)
    loading = false
    if not res.ok then
      errorMessage = tr("error")
      wallpapers = {}
      render()
      return
    end

    local data, err, lastPage = parseSearchResponse(res.body)
    if data == nil then
      errorMessage = err or tr("error")
      wallpapers = {}
      render()
      return
    end

    local filteredWallpapers = {}
    local selectedRatio = aspectRatioFilterValue()
    local ratioTolerance = aspectRatioTolerance()

    for _, wallpaper in ipairs(data) do
      local include = true

      -- Client-side aspect ratio check since API's ratio filter is often inaccurate
      if selectedRatio ~= "" then
        local res = wallpaper.resolution
        if type(res) == "string" then
          local w, h = res:match("(%d+)x(%d+)")
          if w and h then
            w, h = tonumber(w), tonumber(h)
            local ratio = w / h
            local isWide = ratio > 1
            local isPortrait = ratio < 1

            if selectedRatio == "wide" and not isWide then
              include = false
            elseif selectedRatio == "portrait" and not isPortrait then
              include = false
            elseif selectedRatio:find("x") then
              local rw, rh = selectedRatio:match("(%d+)x(%d+)")
              if rw and rh then
                local targetRatio = tonumber(rw) / tonumber(rh)
                if math.abs(ratio - targetRatio) > ratioTolerance then
                  include = false
                end
              end
            end
          end
        end
      end

      if include then
        table.insert(filteredWallpapers, wallpaper)
      end
    end

    wallpapers = filteredWallpapers
    totalPages = normalizeTotalPages(lastPage)
    if page > totalPages then
      page = totalPages
    end
    render()
    ensureCacheDir(function()
      thumbQueue = {}
      for _, wallpaper in ipairs(wallpapers) do
        queueThumbDownload(wallpaper)
      end
    end)
  end)
end

local function persistAndRefetch()
  page = 1
  fetchWallpapers()
end

local function tileBorder(wallpaper, selected)
  if selected then
    return "primary", TILE_BORDER_SELECTED
  end
  local purity = wallpaper.purity
  if purity == "nsfw" then
    return "error", TILE_BORDER_RATED
  end
  if purity == "sketchy" then
    return "tertiary", TILE_BORDER_RATED
  end
  return "outline_variant", TILE_BORDER_SFW
end

local function wallpaperPreview(wallpaper, frameWidth, frameHeight, borderColor, borderWidth)
  local id = wallpaper.id
  local thumb = thumbPaths[id]
  local onClick = function()
    pickWallpaper(id)
  end
  if thumb ~= nil then
    return ui.image({
      width = frameWidth,
      height = frameHeight,
      path = thumb,
      fit = "cover",
      radius = TILE_FRAME_RADIUS,
      border = borderColor,
      borderWidth = borderWidth,
      onClick = onClick,
    })
  end
  return ui.box({
    width = frameWidth,
    height = frameHeight,
    fill = "surface_container",
    radius = TILE_FRAME_RADIUS,
    border = borderColor,
    borderWidth = borderWidth,
    onClick = onClick,
  })
end

local function wallpaperTile(wallpaper)
  local id = wallpaper.id
  local resolution = wallpaper.resolution or id
  local selected = selectedId == id
  local borderColor, borderWidth = tileBorder(wallpaper, selected)
  local frameWidth, frameHeight = tileThumbSize()
  return ui.column({
    gap = TILE_LABEL_GAP,
    key = id,
    flexGrow = 1,
    align = "center",
  }, {
    wallpaperPreview(wallpaper, frameWidth, frameHeight, borderColor, borderWidth),
    ui.label({
      text = resolution,
      fontSize = TILE_LABEL_FONT,
      color = "on_surface_variant",
      maxLines = 1,
      maxWidth = frameWidth,
      textAlign = "center",
    }),
  })
end

local function wallpaperGrid()
  if loading then
    return ui.label({ text = tr("loading"), color = "on_surface_variant" })
  end
  if errorMessage ~= "" then
    return ui.label({ text = errorMessage, color = "error" })
  end
  if #wallpapers == 0 then
    return ui.label({ text = tr("empty"), color = "on_surface_variant" })
  end

  local rows = {}
  local row = {}
  for index, wallpaper in ipairs(wallpapers) do
    table.insert(row, wallpaperTile(wallpaper))
    if #row == COLUMNS or index == #wallpapers then
      table.insert(rows, ui.row({ gap = COLUMN_GAP, align = "stretch" }, row))
      row = {}
    end
  end
  return ui.column({ gap = 12, align = "stretch" }, rows)
end

local function previewView()
  local media
  if previewStreaming and previewPath ~= nil and previewImageW ~= nil and previewImageH ~= nil then
    media = ui.pixelStream({
      key = "crop_preview",
      width = PANEL_WIDTH - PANEL_PADDING,
      height = PREVIEW_HEIGHT,
      path = cropSocketPath(),
      radius = 0,
      onPointerDown = "onCropDown",
      onPointerMove = "onCropMove",
      onPointerUp = "onCropUp",
      onPointerCancel = "onCropCancel",
    })
  else
    media = ui.image({
      width = PANEL_WIDTH - PANEL_PADDING,
      height = PREVIEW_HEIGHT,
      path = previewPath or thumbPaths[preview.id],
      fit = "contain",
    })
  end

  return ui.column({ flexGrow = 1, gap = 12, align = "stretch" }, {
    -- Scrolls when a short screen shrinks the panel, so the buttons stay reachable.
    ui.scroll({ flexGrow = 1 }, {
      media,
    }),
    ui.row({ align = "center", justify = "space_between", gap = 8 }, {
      ui.button({
        key = "preview_back",
        text = tr("preview_back"),
        glyph = "chevron-left",
        variant = "ghost",
        onClick = "onPreviewBack",
        enabled = not applying,
      }),
      if previewPath == nil then
        ui.row({ gap = 8, align = "center" }, {
          ui.label({ text = tr("applying"), color = "on_surface_variant" }),
          ui.progress({
            width = PREVIEW_PROGRESS_WIDTH,
            height = 6,
            radius = 3,
            progress = previewProgress,
            fill = "primary",
            track = "surface_container",
          }),
        })
      else
        ui.row({ align = "center", justify = "end", gap = 8, flexGrow = 1 }, {
          ui.label({ text = preview.resolution or preview.id, color = "on_surface_variant" }),
          ui.button({
            key = "preview_fit",
            text = tr("preview_fit"),
            variant = if fitEnabled then "primary" else "outline",
            selected = fitEnabled,
            tooltip = tr("preview_fit_tooltip"),
            onClick = "onPreviewFitToggle",
            enabled = previewPath ~= nil and not applying and previewImageW ~= nil,
          }),
          ui.button({
            key = "preview_apply",
            text = tr("preview_apply"),
            variant = "primary",
            onClick = "onPreviewApply",
            enabled = previewPath ~= nil and not applying,
          }),
        }),
    }),
  })
end

render = function()
  normalizePurityFilters()

  local headerContent = {
    ui.label({ text = tr("title"), fontSize = 16, fontWeight = "bold", color = "on_surface", flexGrow = 1 }),
  }
  if closeButton then
    table.insert(headerContent, ui.button({ glyph = "close", onClick = "onCloseClicked" }))
  end

  local header = ui.row({ align = "center", justify = "space_between", gap = 8 }, headerContent)
  -- Hidden rather than dropped during a preview, so the grid keeps its scroll position.
  local browse = ui.column({ key = "browse", visible = preview == nil, flexGrow = 1, gap = 12, align = "stretch" }, {
    ui.row({ gap = 8, align = "center" }, {
      ui.input({
        key = "search",
        placeholder = tr("search_placeholder"),
        value = query,
        flexGrow = 1,
        onChange = "onSearchChange",
        onSubmit = "onSearchSubmit",
      }),
      ui.button({ text = tr("search"), variant = "primary", onClick = "onSearchClicked", enabled = not loading }),
    }),

    filtersPanel(),

    ui.scroll({ flexGrow = 1, gap = 12 }, {
      wallpaperGrid(),
    }),

    ui.row({ align = "center", justify = "center" }, {
      ui.row({ gap = 8, align = "center" }, {
        ui.button({
          key = "prev_page",
          glyph = "chevron-left",
          variant = "ghost",
          onClick = "onPrevPage",
          enabled = not loading and page > 1,
        }),
        (if pageEditing then
          ui.input({
            key = `page_jump_{pageInputCounter}`,
            placeholder = tostring(page),
            width = 72,
            focus = true,
            onSubmit = "onPageEditSubmit",
          })
        else
          ui.button({
            key = "page_label",
            text = `Page {page}`,
            variant = "ghost",
            tooltip = tr("page_jump_tooltip"),
            onClick = "onPageLabelClicked",
            enabled = not loading,
          })),
        ui.label({ text = `/ {totalPages}`, color = "on_surface_variant" }),
        ui.button({
          key = "next_page",
          glyph = "chevron-right",
          variant = "ghost",
          onClick = "onNextPage",
          enabled = not loading and page < totalPages,
        }),
      }),
    }),
  })

  local children = { header, browse }
  if preview ~= nil then
    table.insert(children, previewView())
  end
  panel.render(ui.column({ flexGrow = 1, gap = 12, align = "stretch" }, children))
end

-- A crash or a reload mid-download can leave a finished <id>-full.<ext> behind; `.part`
-- files belong to downloads that may still be running, so they are left alone. The sweep
-- runs detached: listing thousands of cached thumbs can blow the callback CPU budget.
-- Plain globs only — runAsync's quoting strips backslashes, so escapes like `\( \)` break.
local function sweepPreviewLeftovers()
  if preview ~= nil then
    return
  end
  noctalia.runAsync(`rm -f {shellQuote(CACHE_DIR)}/*-full.jpg {shellQuote(CACHE_DIR)}/*-full.png`)
end

function onOpen(_context)
  closeButton = noctalia.getSetting("shell.show_close_buttons") ~= false
  normalizePurityFilters()
  sweepPreviewLeftovers()
  -- A freshly loaded script has little CPU budget left; fetch on the next frame, whose
  -- callback gets a full budget.
  needsInitialFetch = true
  panel.setNeedsFrameTick(true)
end

function onClose()
  closePreview()
  render() -- a reopened panel starts from the last tree, which must not name the deleted file
end

function onExit()
  closePreview() -- a script reload or shell exit may not run onClose
end

function onFrameTick(deltaMs)
  if needsInitialFetch then
    needsInitialFetch = false
    fetchWallpapers()
  end
  if preview == nil or previewPath ~= nil then
    panel.setNeedsFrameTick(false)
    return
  end
  previewTickMs += deltaMs
  if previewTickMs < PREVIEW_PROGRESS_MS then
    return
  end
  previewTickMs = 0
  -- noctalia.download reports no progress, but it writes to <dest>.part until it finishes.
  local info = noctalia.fileInfo(`{previewCachePath(preview)}.part`)
  local total = preview.file_size
  if info ~= nil and type(total) == "number" and total > 0 then
    previewProgress = math.min(1, info.size / total)
    render()
  end
end

function onPreviewBack()
  closePreview()
  render()
end

local function applyPreview()
  if applying or previewPath == nil then
    return
  end
  applying = true
  render()

  local function finishApply(dest)
    noctalia.setWallpaper(dest)
    stopCropProducer()
    preview = nil
    previewPath = nil
    previewImageW = nil
    previewImageH = nil
    noctalia.notify(tr("title"), tr("applied"))
    render()
  end

  local destDir = downloadDir()
  local dest = `{destDir}/wallhaven-{preview.id}{fileExtension(preview)}`
  if not fitEnabled then
    -- mv, not noctalia.renameFile: the wallpaper directory can be on another filesystem.
    noctalia.runAsync(`mkdir -p {shellQuote(destDir)} && mv -f {shellQuote(previewPath)} {shellQuote(dest)}`, function(res)
      applying = false
      if res == nil or res.exitCode ~= 0 then
        noctalia.notifyError(tr("title"), tr("apply_failed"))
        render()
        return
      end
      finishApply(dest)
    end)
    return
  end

  local x, y, width, height, monitorWidth, monitorHeight = cropRect()
  if x == nil then
    applying = false
    noctalia.notifyError(tr("title"), tr("fit_failed"))
    render()
    return
  end
  local geometry = `{width}x{height}+{x}+{y}`
  local resolution = `{monitorWidth}x{monitorHeight}`
  -- A fitted crop gets its own file name, so re-applying the same wallpaper
  -- in either mode changes the path and makes Noctalia reload the wallpaper.
  dest = `{destDir}/wallhaven-{preview.id}-fit-{width}x{height}-{x}-{y}{fileExtension(preview)}`
  noctalia.runAsync(`mkdir -p {shellQuote(destDir)} && magick {shellQuote(previewPath)} -crop {geometry} +repage -resize {resolution}! {shellQuote(dest)}`, function(res)
    applying = false
    if res == nil or res.exitCode ~= 0 then
      noctalia.notifyError(tr("title"), tr("fit_failed"))
      render()
      return
    end
    noctalia.removeFile(previewPath)
    finishApply(dest)
  end, 30000)
end

function onPreviewApply()
  applyPreview()
end

function onPreviewFitToggle()
  if previewPath == nil or applying then
    return
  end
  fitEnabled = not fitEnabled
  if fitEnabled then
    previewStreaming = true
  end
  if previewStreaming then
    ensureCropProducer()
  end
  render()
end

function onSearchChange(value)
  query = value
end

function onSearchSubmit(value)
  query = value
  page = 1
  fetchWallpapers()
end

function onSearchClicked()
  page = 1
  fetchWallpapers()
end

function onPuritySfw()
  if puritySfw and not puritySketchy and not purityNsfw then
    return
  end
  puritySfw = not puritySfw
  persistAndRefetch()
end

function onCategoryGeneral()
  if categoryGeneral and not categoryAnime and not categoryPeople then
    return
  end
  categoryGeneral = not categoryGeneral
  persistAndRefetch()
end

function onCategoryAnime()
  if categoryAnime and not categoryGeneral and not categoryPeople then
    return
  end
  categoryAnime = not categoryAnime
  persistAndRefetch()
end

function onCategoryPeople()
  if categoryPeople and not categoryGeneral and not categoryAnime then
    return
  end
  categoryPeople = not categoryPeople
  persistAndRefetch()
end

function onPuritySketchy()
  if puritySketchy and not puritySfw and not purityNsfw then
    return
  end
  puritySketchy = not puritySketchy
  persistAndRefetch()
end

function onPurityNsfw()
  if not nsfwAllowed() then
    return
  end
  if purityNsfw and not puritySfw and not puritySketchy then
    return
  end
  purityNsfw = not purityNsfw
  persistAndRefetch()
end

function onSort(index, _text)
  sortIndex = tonumber(index) or 0
  persistAndRefetch()
end

function onToggleSortOrder()
  if sortIsRandom() then
    persistAndRefetch()
    return
  end
  sortOrder = if sortOrder == "desc" then "asc" else "desc"
  persistAndRefetch()
end

function onResolutionModeChange(index, _text)
  local modes = resolutionModeOptions()
  resolutionMode = modes[(tonumber(index) or 0) + 1] or "atleast"
  persistAndRefetch()
end

function onResolutionWidthChange(value)
  resolutionWidth = noctalia.string.trim(value)
end

function onResolutionHeightChange(value)
  resolutionHeight = noctalia.string.trim(value)
end

function handleResolutionSubmit(value, isWidth)
  local trimmedValue = noctalia.string.trim(value)
  if isWidth then
    resolutionWidth = trimmedValue
  else
    resolutionHeight = trimmedValue
  end
  page = 1
  fetchWallpapers()
end

function onResolutionWidthSubmit(value)
  handleResolutionSubmit(value, true)
end

function onResolutionHeightSubmit(value)
  handleResolutionSubmit(value, false)
end

function onAspectRatioChange(index, _text)
  aspectRatioIndex = tonumber(index) or 0
  persistAndRefetch()
end

function onClearResolution()
  if resolutionMode == "atleast" and resolutionWidth == "" and resolutionHeight == "" then
    return
  end
  resolutionMode = "atleast"
  resolutionWidth = ""
  resolutionHeight = ""
  clearCounter += 1
  persistAndRefetch()
end

function onPrevPage()
  if page > 1 then
    page -= 1
    fetchWallpapers()
  end
end

function onNextPage()
  if page < totalPages then
    page += 1
    fetchWallpapers()
  end
end

function onPageLabelClicked()
  pageEditing = true
  pageInputCounter += 1
  render()
end

function onPageEditSubmit(value)
  pageEditing = false
  pageInputCounter += 1
  if not loading then
    local target = parsePositiveInt(noctalia.string.trim(value))
    if target ~= nil then
      if target > totalPages then
        target = totalPages
      end
      if target ~= page then
        page = target
        fetchWallpapers()
        return
      end
    end
  end
  render()
end

function onCloseClicked()
  panel.close()
end
