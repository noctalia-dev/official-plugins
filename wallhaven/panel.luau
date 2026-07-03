--!nonstrict
-- Wallhaven wallpaper browser panel.
--
-- Browse search results with category and purity filters and pagination, download the full
-- image into the configured wallpaper directory, then apply it via noctalia.setWallpaper.

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

local query = ""
local page = 1
local totalPages = 1
local wallpapers = {}
local loading = false
local errorMessage = ""
local selectedId = ""
local applying = false

local puritySfw = true
local puritySketchy = false
local purityNsfw = false

local categoryGeneral = true
local categoryAnime = true
local categoryPeople = true

local thumbPaths = {} -- id -> cache file path
local thumbPending = {} -- id -> true while downloading
local thumbQueue = {} -- wallpapers waiting for a download slot
local thumbActive = 0
local pickSlots = {} -- slot index -> wallpaper id for the current render

local render
local fetchWallpapers
local applyWallpaper

local sortOptions = { "date_added", "relevance", "views", "favorites", "random" }
local sortIndex = 0

local function tr(key)
  return noctalia.tr(key)
end

local function sortLabelList()
  return {
    tr("sort.options.date_added"),
    tr("sort.options.relevance"),
    tr("sort.options.views"),
    tr("sort.options.favorites"),
    tr("sort.options.random"),
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

local function filterChip(label, active, onClick, key, enabled)
  return ui.button({
    key = key,
    text = label,
    variant = if active then "primary" else "outline",
    onClick = onClick,
    enabled = if enabled == nil then true else enabled,
  })
end

local function filterGroup(title, content)
  return ui.row({ gap = 6, align = "center" }, {
    ui.label({
      text = title,
      fontSize = 12,
      color = "on_surface_variant",
    }),
    content,
  })
end

local function filtersPanel()
  return ui.row({ gap = 16, align = "center" }, {
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
    ui.row({ gap = 6, align = "center", flexGrow = 1 }, {
      ui.label({
        text = tr("filter_sort"),
        fontSize = 12,
        color = "on_surface_variant",
      }),
      ui.select({
        key = "sort",
        options = sortLabelList(),
        selectedIndex = sortIndex,
        onChange = "onSort",
        flexGrow = 1,
      }),
    }),
  })
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

local function onPickAt(index)
  local id = pickSlots[index]
  if id ~= nil then
    selectedId = id
    applyWallpaper(id)
  end
end

local function fileExtension(wallpaper)
  if wallpaper.file_type == "image/png" then
    return ".png"
  end
  return ".jpg"
end

local function findWallpaper(id)
  for _, wallpaper in wallpapers do
    if wallpaper.id == id then
      return wallpaper
    end
  end
  return nil
end

applyWallpaper = function(id)
  if applying then
    return
  end
  local wallpaper = findWallpaper(id)
  if wallpaper == nil then
    return
  end
  local imageUrl = wallpaper.path
  if type(imageUrl) ~= "string" or imageUrl == "" then
    noctalia.notifyError(tr("title"), tr("download_failed"))
    return
  end

  applying = true
  render()

  local destDir = downloadDir()
  local dest = `{destDir}/wallhaven-{id}{fileExtension(wallpaper)}`
  noctalia.runAsync(`mkdir -p {shellQuote(destDir)}`, function(mkdirRes)
    if mkdirRes == nil or mkdirRes.exitCode ~= 0 then
      applying = false
      noctalia.notifyError(tr("title"), tr("download_failed"))
      render()
      return
    end

    noctalia.download(imageUrl, dest, function(downloadOk)
      if not downloadOk then
        applying = false
        noctalia.notifyError(tr("title"), tr("download_failed"))
        render()
        return
      end

      noctalia.setWallpaper(dest)
      applying = false
      noctalia.notify(tr("title"), tr("applied"))
      render()
    end)
  end)
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
    `page={page}`,
    `sorting={sortValue()}`,
    "order=desc",
  }
  local trimmed = noctalia.string.trim(query)
  if trimmed ~= "" then
    table.insert(params, `q={noctalia.string.urlEncode(trimmed)}`)
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

    wallpapers = data
    totalPages = lastPage
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
  return "outline", TILE_BORDER_SFW
end

local function wallpaperPreview(wallpaper, slotIndex, frameWidth, frameHeight, borderColor, borderWidth)
  local id = wallpaper.id
  local thumb = thumbPaths[id]
  local onClick = `onPick{slotIndex}`
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
    fill = "surface_variant",
    radius = TILE_FRAME_RADIUS,
    border = borderColor,
    borderWidth = borderWidth,
    onClick = onClick,
  })
end

local function wallpaperTile(wallpaper, slotIndex)
  local id = wallpaper.id
  local resolution = wallpaper.resolution or id
  local selected = selectedId == id
  local borderColor, borderWidth = tileBorder(wallpaper, selected)
  local frameWidth, frameHeight = tileThumbSize()
  pickSlots[slotIndex] = id

  return ui.column({
    gap = TILE_LABEL_GAP,
    key = id,
    flexGrow = 1,
    align = "center",
  }, {
    wallpaperPreview(wallpaper, slotIndex, frameWidth, frameHeight, borderColor, borderWidth),
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
  for slotIndex, wallpaper in ipairs(wallpapers) do
    table.insert(row, wallpaperTile(wallpaper, slotIndex - 1))
    if #row == COLUMNS or slotIndex == #wallpapers then
      table.insert(rows, ui.row({ gap = COLUMN_GAP, align = "stretch" }, row))
      row = {}
    end
  end
  return ui.column({ gap = 12, align = "stretch" }, rows)
end

render = function()
  normalizePurityFilters()
  pickSlots = {}
  local pageLabel = if applying then tr("applying") else `Page {page} / {totalPages}`
  panel.render(ui.column({ flexGrow = 1, gap = 12, align = "stretch" }, {
    ui.row({ align = "center", justify = "space_between", gap = 8 }, {
      ui.label({ text = tr("title"), fontSize = 16, fontWeight = "bold", color = "on_surface", flexGrow = 1 }),
      ui.button({ glyph = "close", onClick = "onCloseClicked" }),
    }),

    ui.row({ gap = 8, align = "center" }, {
      ui.input({
        key = "search",
        placeholder = tr("search_placeholder"),
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
        ui.label({ text = pageLabel, color = "on_surface_variant" }),
        ui.button({
          key = "next_page",
          glyph = "chevron-right",
          variant = "ghost",
          onClick = "onNextPage",
          enabled = not loading and page < totalPages,
        }),
      }),
    }),
  }))
end

function onOpen(_context)
  normalizePurityFilters()
  page = 1
  fetchWallpapers()
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

function onCloseClicked()
  panel.close()
end

-- Wallhaven returns at most 24 wallpapers per page; each slot gets a fixed callback name.
function onPick0() onPickAt(0) end
function onPick1() onPickAt(1) end
function onPick2() onPickAt(2) end
function onPick3() onPickAt(3) end
function onPick4() onPickAt(4) end
function onPick5() onPickAt(5) end
function onPick6() onPickAt(6) end
function onPick7() onPickAt(7) end
function onPick8() onPickAt(8) end
function onPick9() onPickAt(9) end
function onPick10() onPickAt(10) end
function onPick11() onPickAt(11) end
function onPick12() onPickAt(12) end
function onPick13() onPickAt(13) end
function onPick14() onPickAt(14) end
function onPick15() onPickAt(15) end
function onPick16() onPickAt(16) end
function onPick17() onPickAt(17) end
function onPick18() onPickAt(18) end
function onPick19() onPickAt(19) end
function onPick20() onPickAt(20) end
function onPick21() onPickAt(21) end
function onPick22() onPickAt(22) end
function onPick23() onPickAt(23) end
