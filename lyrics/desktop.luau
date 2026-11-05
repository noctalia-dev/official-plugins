--!nonstrict
-- Lyrics desktop widget: a [[desktop_widget]] client of the lyrics service.
--
-- The service publishes the lyrics for the active player in noctalia.state
-- ("lyrics"); this widget only follows playback. It reads the position from
-- noctalia.mediaPlayer(), picks the line to show, sweeps it with ui.fillLabel
-- and scrolls between lines. Frame ticks run only while a line is being swept
-- or a scroll is in flight; otherwise update() wakes when the next line is due.

local function clamp(value, low, high)
  return math.max(low, math.min(high, value))
end

local LINE_COUNT = clamp(math.floor(noctalia.getConfig("line_count") or 3), 1, 15)
local SYNC_OFFSET_MS = clamp(noctalia.getConfig("sync_offset_ms") or 0, -10000, 10000)
local COLOR = noctalia.getConfig("color")
local ACTIVE_COLOR = noctalia.getConfig("active_color")
local SHADOW = noctalia.getConfig("shadow") == true
local HIDE_WHEN_NO_MEDIA = noctalia.getConfig("hide_when_no_media") == true
local HIDE_WHEN_IDLE = noctalia.getConfig("hide_when_idle") == true
local FONT_SIZE = clamp(noctalia.getConfig("font_size") or 22, 8, 96)
local WIDTH = clamp(noctalia.getConfig("width") or 640, 100, 4000)

-- The core widget used 38 px rows for 22 px text.
local ROW_HEIGHT = FONT_SIZE * 38 / 22
local HEIGHT = ROW_HEIGHT * LINE_COUNT
local LINE_PADDING = 4
local TEXT_WIDTH = WIDTH - 2 * LINE_PADDING
-- Rows rendered: one above the visible window (scrolls out) plus the visible rows.
-- The window itself spans LINE_COUNT + 2 rows so the active line sits in the same
-- place as in the core widget.
local WINDOW_ROWS = LINE_COUNT + 2
local MIDDLE_ROW = math.floor((WINDOW_ROWS - 1) / 2) + 1 -- 1-based
local SCROLL_MS = 200
-- How far before the shown line a position may fall before it counts as a seek; smaller moves are jitter.
local BACKWARD_SLACK_MS = 500
local MAX_LINE_LEAD_MS = 250
local IDLE_INTERVAL_MS = 250

-- Lyrics published by the service, and what is derived from them once per change.
local lyrics = nil
local generation = 0
local lineRanges = {} -- [line] = flat fillRanges for word-timed lines, false otherwise
local lastWordEnd = {} -- [line] = end of the last word, false for line-timed lines

-- Display state.
local rows = table.create(WINDOW_ROWS, "")
local activeRow = nil
local shownLine = nil
local shownGeneration = 0
local rowsKey = ""
local progress = 0
local animating = false
local visible = true
local frameMs = 0

-- Scroll animation: rows still sit `scrollRows` rows below their resting place.
local scrollRows = 0
local scrollFrom = 0
local scrollStartMs = 0
local scrollDurationMs = 0

local tickingFrames = false
local intervalMs = 0
local renderedKey = nil

local function lineLeadMs()
  return clamp(math.floor(frameMs + 0.5), 0, MAX_LINE_LEAD_MS)
end

local function lineHoldMs()
  return math.floor(frameMs * 2 + 0.5)
end

local function onLyrics(value)
  lyrics = value
  generation += 1
  table.clear(lineRanges)
  table.clear(lastWordEnd)
  local lines = value and value.lines
  if lines then
    for i, line in lines do
      local words = line.words
      if words and #words > 0 then
        local ranges = table.create(#words * 2)
        for _, word in words do
          table.insert(ranges, word.first)
          table.insert(ranges, word.last)
        end
        lineRanges[i] = ranges
        lastWordEnd[i] = words[#words].endMs
      else
        lineRanges[i] = false
        lastWordEnd[i] = false
      end
    end
  end
end

-- The service re-publishes a continuing track with the current player's identity,
-- so a mismatch means the track changed and the result is stale.
local function lyricsApply(player)
  return lyrics ~= nil
    and lyrics.key ~= ""
    and lyrics.busName == player.busName
    and (lyrics.trackId == player.trackId or lyrics.title == player.title)
end

-- Index of the last line due at `positionMs`, or nil before the first line.
local function dueLine(lines, positionMs)
  local low, high = 1, #lines
  local found = nil
  while low <= high do
    local mid = (low + high) // 2
    if lines[mid].timeMs <= positionMs then
      found = mid
      low = mid + 1
    else
      high = mid - 1
    end
  end
  return found
end

-- The line to show: the one due one lead from now, but a word-timed line already on screen stays until its
-- last word has been sung and shown filled for the hold time, even when the next line is already due.
local function selectLine(lines, positionMs)
  local lead = lineLeadMs()
  local target = dueLine(lines, positionMs + lead)
  local shown = shownGeneration == generation and shownLine or nil
  if shown and shown <= #lines then
    -- Position corrections must not bounce the view back a line; only a seek moves it backwards.
    local backwards = target == nil or target < shown
    if backwards and positionMs + lead >= lines[shown].timeMs - BACKWARD_SLACK_MS then
      return shown
    end
    local wordsEnd = lastWordEnd[shown]
    if target and target > shown and wordsEnd and positionMs < wordsEnd + lineHoldMs() then
      return shown
    end
  end
  return target
end

-- Filled segments of a line: whole words plus the fraction of the word being sung, or for a line-timed line the
-- fraction of the line, finishing a little early so the full line is seen before the next one replaces it.
local function lineProgress(lines, index, positionMs)
  local line = lines[index]
  local words = line.words
  if words and #words > 0 then
    for i, word in words do
      if positionMs < word.startMs then
        return i - 1
      end
      if positionMs < word.endMs then
        return i - 1 + (positionMs - word.startMs) / (word.endMs - word.startMs)
      end
    end
    return #words
  end
  local nextLine = lines[index + 1]
  local finish = line.endMs or (nextLine and nextLine.timeMs)
  if not finish or finish <= line.timeMs then
    return 1
  end
  local early = clamp(lineLeadMs() + lineHoldMs(), 0, (finish - line.timeMs) // 2)
  local sweepEnd = finish - early
  return clamp((positionMs - line.timeMs) / (sweepEnd - line.timeMs), 0, 1)
end

local function startScroll(durationMs)
  -- A scroll interrupted by the next line continues from where it is.
  scrollFrom = math.min(scrollRows + 1, 2)
  scrollRows = scrollFrom
  scrollStartMs = noctalia.nowMs()
  scrollDurationMs = durationMs
end

local function stopScroll()
  scrollRows = 0
  scrollDurationMs = 0
end

local function advanceScroll()
  if scrollDurationMs <= 0 then
    return
  end
  local t = (noctalia.nowMs() - scrollStartMs) / scrollDurationMs
  if t >= 1 then
    stopScroll()
    return
  end
  -- EaseOutCubic from scrollFrom to 0.
  local inv = 1 - math.max(0, t)
  scrollRows = scrollFrom * inv * inv * inv
end

local function setStatusRows(text)
  table.clear(rows)
  for i = 1, WINDOW_ROWS do
    rows[i] = ""
  end
  rows[MIDDLE_ROW] = text
  activeRow = nil
end

local function shouldBeVisible(player)
  if not player then
    return not HIDE_WHEN_NO_MEDIA
  end
  return not HIDE_WHEN_IDLE or player.status == "Playing"
end

local function rowLabel(index)
  local active = index == activeRow and shownLine ~= nil
  return ui.fillLabel({
    text = rows[index],
    fontSize = FONT_SIZE,
    color = COLOR,
    fillColor = ACTIVE_COLOR,
    fillRanges = active and lineRanges[shownLine] or nil,
    fillProgress = active and progress or 0,
    maxWidth = TEXT_WIDTH,
    textAlign = "center",
    baseline = "textFixedHeight",
    shadow = SHADOW,
  })
end

-- A row's label centred in a full row; the slot around it may be shorter while it scrolls past an edge.
local function rowCell(index)
  return ui.column({ height = ROW_HEIGHT, width = WIDTH, align = "center", justify = "center" }, { rowLabel(index) })
end

-- The widget keeps one fixed size: the spacer above the rows and the rows below it always add up to HEIGHT.
-- Scrolling grows the spacer (sliding the rows down by `scrollRows` rows) and shortens the bottom slots by the
-- same amount; a slot's visible share sets its opacity, standing in for clipping.
local function render()
  local key = string.format("%.4f|%.4f|", progress, scrollRows) .. rowsKey
  if key == renderedKey then
    return
  end
  renderedKey = key
  -- Flex treats a zero height as unconstrained, so empty slots are hidden instead.
  local spacerRows = math.min(scrollRows, LINE_COUNT)
  local children = table.create(LINE_COUNT + 1)
  -- Window row 1 is the line scrolling out above the visible rows; it sits at the bottom of the spacer.
  children[1] = ui.column({
    key = "top",
    height = spacerRows * ROW_HEIGHT,
    width = WIDTH,
    justify = "end",
    visible = spacerRows > 0,
    opacity = clamp(2 * scrollRows - 1, 0, 1),
  }, { rowCell(1) })
  for k = 1, LINE_COUNT do
    local share = clamp(LINE_COUNT - (k - 1) - scrollRows, 0, 1)
    children[k + 1] = ui.column({
      key = "row" .. k,
      height = share * ROW_HEIGHT,
      width = WIDTH,
      visible = share > 0,
      opacity = share,
    }, { rowCell(k + 1) })
  end
  desktopWidget.render(ui.column({ width = WIDTH, height = HEIGHT }, children))
end

local function refresh()
  local player = noctalia.mediaPlayer()
  local nextVisible = shouldBeVisible(player)
  if nextVisible ~= visible then
    visible = nextVisible
    -- The host hides the whole widget, background included, keeping its place.
    desktopWidget.setVisible(visible)
  end

  -- Same condition as the service: a title, or a local file whose sidecar may hold lyrics.
  local hasTrack = player ~= nil
    and player.status ~= "Stopped"
    and (player.title ~= "" or string.sub(player.url, 1, 7) == "file://")
  local status = hasTrack and lyricsApply(player) and lyrics.status or nil
  local lines = lyrics and lyrics.lines or {}
  local plain = lyrics and lyrics.plain or {}
  local newLine = nil
  local newKey
  local wakeMs = IDLE_INTERVAL_MS
  animating = false
  progress = 0

  if not hasTrack then
    newKey = "status:nothing-playing"
  elseif status == nil or status == "idle" or status == "loading" then
    newKey = "status:loading"
  elseif status == "not_found" or status == "offline" or status == "error" then
    newKey = "status:" .. status
  elseif lyrics.instrumental then
    newKey = "status:instrumental"
  elseif #lines > 0 then
    local positionMs = player.positionMs + SYNC_OFFSET_MS
    newLine = selectLine(lines, positionMs)
    newKey = "line:" .. generation .. ":" .. tostring(newLine)
    local playing = player.status == "Playing"
    if newLine then
      local line = lines[newLine]
      progress = lineProgress(lines, newLine, positionMs)
      if playing and line.text ~= "" then
        local nextLine = lines[newLine + 1]
        local finish = line.endMs or (nextLine and nextLine.timeMs)
        local wordsEnd = lastWordEnd[newLine]
        animating = (finish ~= nil and positionMs < finish) or (wordsEnd and positionMs < wordsEnd) or false
      end
    end
    -- Wake when the next line is due, or when the current word-timed line finishes and may hand over early.
    local nextIndex = newLine and newLine + 1 or 1
    if playing and nextIndex <= #lines and (player.rate or 1) > 0 then
      local remaining = lines[nextIndex].timeMs - (positionMs + lineLeadMs())
      local wordsEnd = newLine and lastWordEnd[newLine]
      if wordsEnd and wordsEnd + lineHoldMs() > positionMs then
        remaining = math.min(remaining, wordsEnd + lineHoldMs() - positionMs)
      end
      wakeMs = clamp(math.ceil(remaining / (player.rate or 1)), 16, IDLE_INTERVAL_MS)
    end
  elseif #plain > 0 then
    newKey = "plain:" .. generation
  else
    newKey = "status:not_found"
  end

  -- Scroll one row when playback moves on to the next line of the same lyrics; any other change jumps.
  if newLine and shownLine and shownGeneration == generation and newLine == shownLine + 1 then
    local gap = lines[newLine + 1] and (lines[newLine + 1].timeMs - lines[newLine].timeMs) // 2 or SCROLL_MS
    startScroll(clamp(gap, 1, SCROLL_MS))
  elseif newLine ~= shownLine or shownGeneration ~= generation then
    stopScroll()
  end
  shownLine = newLine
  shownGeneration = generation

  if newKey ~= rowsKey then
    rowsKey = newKey
    if string.sub(newKey, 1, 7) == "status:" then
      setStatusRows(noctalia.tr("status." .. string.sub(newKey, 8)))
    elseif string.sub(newKey, 1, 6) == "plain:" then
      -- Plain lyrics show their first rows, starting in the first visible row.
      table.clear(rows)
      rows[1] = ""
      for i = 2, WINDOW_ROWS do
        rows[i] = plain[i - 1] or ""
      end
      activeRow = nil
    else
      -- The current line in the middle row; before the first line the opening lyric waits there, unhighlighted.
      local current = newLine or 1
      table.clear(rows)
      for i = 1, WINDOW_ROWS do
        local line = lines[current + i - MIDDLE_ROW]
        rows[i] = line and line.text or ""
      end
      activeRow = newLine and MIDDLE_ROW or nil
    end
  end

  local needsTick = visible and (animating or scrollDurationMs > 0)
  if needsTick ~= tickingFrames then
    tickingFrames = needsTick
    desktopWidget.setNeedsFrameTick(needsTick)
  end
  if needsTick then
    -- Frame ticks already follow the position; update() only needs to notice player changes.
    wakeMs = IDLE_INTERVAL_MS
  end
  if wakeMs ~= intervalMs then
    intervalMs = wakeMs
    noctalia.setUpdateInterval(wakeMs)
  end
  render()
end

function update()
  advanceScroll()
  refresh()
end

function onFrameTick(deltaMs)
  local delta = tonumber(deltaMs) or 0
  if delta > 2 and delta < 100 then
    frameMs = frameMs > 0 and frameMs * 0.9 + delta * 0.1 or delta
  end
  advanceScroll()
  refresh()
end

noctalia.state.watch("lyrics", function(value)
  onLyrics(value)
  refresh()
end)

onLyrics(noctalia.state.get("lyrics"))
refresh()
