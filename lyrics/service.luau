--!nonstrict
-- Lyrics lookup service: follows the active media player, finds lyrics for the playing track and publishes them as
-- noctalia.state "lyrics" for the desktop widget:
--
--   { key, busName, trackId, title, lengthMs,
--     status = "idle" | "loading" | "ready" | "not_found" | "error" | "offline",
--     source, recordingDurationMs, offsetMs,
--     instrumental, lines = { { timeMs, endMs?, text, words = { { first, last, startMs, endMs } } } }, plain }
--
-- A `<name>.lrc` file beside a local track wins. Otherwise the track is identified on Deezer (MusicBrainz as a
-- fallback) and lrcmux, LyricsPlus and LRCLIB are asked in turn, stopping as soon as synced lyrics made for a recording
-- of the playing length are found. When none match that length, KuGou and NetEase are asked as well and the synced
-- lyrics whose line timings agree with the other sources win. Results are cached in memory and on disk so replays and
-- restarts do not query again. Per-track timing offsets set over IPC are kept on disk too.

local catalog = require("./catalog.luau")
local lrc = require("./lrc.luau")
local providers = require("./providers.luau")
local text = require("./text.luau")

local POLL_MS = 250
local USER_AGENT = "User-Agent: NoctaliaLyrics/1.0 (https://noctalia.dev)"

local SECOND_MS = 1000
local MINUTE_MS = 60 * SECOND_MS
local HOUR_MS = 60 * MINUTE_MS
local DAY_MS = 24 * HOUR_MS

-- Completed lookups kept in memory; pending ones are never dropped.
local MAX_ENTRIES = 64
-- Lookups kept on disk, least recently used dropped first.
local MAX_DISK_ENTRIES = 200
local READY_LIFETIME_MS = 30 * DAY_MS
local NOT_FOUND_LIFETIME_MS = DAY_MS
-- A failed lookup is retried after 30 s, doubling up to 10 min.
local RETRY_BASE_MS = 30 * SECOND_MS
local RETRY_MAX_MS = 10 * MINUTE_MS
-- A source that failed is skipped for this long; one that asked to slow down (429/503) for the shorter pause.
local PROVIDER_BACKOFF_MS = 10 * MINUTE_MS
local RATE_LIMIT_PAUSE_MS = MINUTE_MS
-- Lyrics timed for a recording this close to the player's length were made for what is playing.
local MIN_LENGTH_SLACK_MS = 2000
-- Playback that lands this close to where it was expected to be has not changed track.
local POSITION_CONTINUITY_MS = 3000
-- How long a track keeps showing "no lyrics" when it has no artist to search for, before its sidecar is checked again.
local LOCAL_ONLY_RETRY_MS = 5 * MINUTE_MS
local MAX_SIDECAR_BYTES = 512 * 1024
-- Remembered per-player details are forgotten once a player has not been active for this long.
local PLAYER_MEMORY_MS = 10 * MINUTE_MS
local PRUNE_INTERVAL_MS = 30 * SECOND_MS
-- Line timings from two sources further apart than this disagree.
local AGREE_MS = 1000
local MAX_OFFSETS = 500
local MAX_OFFSET_MS = 30 * SECOND_MS

local offline = noctalia.getSetting("shell.offline_mode") == true

-- ── Track identity ──────────────────────────────────────────────────────────

local function trackKey(player)
  return noctalia.json.encode({ player.busName, player.trackId, player.title, player.artists })
end

local function joinedArtists(player)
  return table.concat(player.artists or {}, ", ")
end

local function lookupTrack(player, staleLength)
  return {
    title = player.title,
    artist = joinedArtists(player),
    album = player.album or "",
    durationMs = if staleLength then 0 else (player.lengthMs or 0),
  }
end

-- An album that appeared or changed, or a length that appeared or moved by a second, can change the lookup's outcome.
local function meaningfulMetadataChanged(previous, current)
  if current.album ~= "" and current.album ~= previous.album then
    return true
  end
  if current.durationMs <= 0 then
    return false
  end
  if previous.durationMs <= 0 then
    return true
  end
  return math.abs(current.durationMs - previous.durationMs) >= 1000
end

-- Whether `player` is still on the track whose lyrics were found. Requires the same track id, plus one of: a title
-- that wraps the old one; a paused player with the same length; or the same length with playback continuing from
-- `expectedPositionMs`. Chromium reports hover-preview videos this way while the real video keeps playing.
local function continuesTrack(player, trackId, title, lengthMs, expectedPositionMs)
  if player.trackId ~= trackId then
    return false
  end
  if catalog.titleContinues(title, player.title) then
    return true
  end
  local sameLength = lengthMs > 0 and player.lengthMs == lengthMs
  if sameLength and player.status == "Paused" then
    return true
  end
  return sameLength
    and player.status == "Playing"
    and expectedPositionMs ~= nil
    and math.abs(player.positionMs - expectedPositionMs) <= POSITION_CONTINUITY_MS
end

local function isFileUrl(url)
  return type(url) == "string" and string.sub(url, 1, 7) == "file://"
end

-- ── Per-player memory ───────────────────────────────────────────────────────

-- Players such as Chromium keep reporting the previous track's length after in-page navigation.
local lastLengths = {} -- busName -> { trackKey, lengthMs, stale, seenAt }
-- The last track each player had lyrics for, so a title that wraps it keeps them.
local lastReady = {} -- busName -> { key, trackId, title, seenAt }
local lastPrune = 0

local function staleLengthFor(player, key, now)
  local last = lastLengths[player.busName]
  if last == nil then
    last = { trackKey = "", lengthMs = 0, stale = false }
    lastLengths[player.busName] = last
  end
  local lengthMs = player.lengthMs or 0
  if last.trackKey ~= key then
    last.stale = lengthMs > 0 and lengthMs == last.lengthMs
    last.trackKey = key
  elseif lengthMs ~= last.lengthMs then
    last.stale = false
  end
  last.lengthMs = lengthMs
  last.seenAt = now
  return last.stale
end

local function prunePlayers(activeBus, now)
  if now - lastPrune < PRUNE_INTERVAL_MS then
    return
  end
  lastPrune = now
  for _, map in ipairs({ lastLengths, lastReady }) do
    for bus, item in pairs(map) do
      if bus == activeBus then
        item.seenAt = now
      elseif now - (item.seenAt or 0) > PLAYER_MEMORY_MS then
        map[bus] = nil
      end
    end
  end
end

-- ── Sidecar lyrics ──────────────────────────────────────────────────────────

-- `<name>.lrc` beside the local file a file:// url names, the way std::filesystem::replace_extension builds it.
local function sidecarPath(url)
  if not isFileUrl(url) then
    return nil
  end
  local path = string.sub(url, 8)
  if string.sub(path, 1, 10) == "localhost/" then
    path = string.sub(path, 10)
  elseif path ~= "" and string.sub(path, 1, 1) ~= "/" then
    local slash = string.find(path, "/", 1, true)
    path = if slash then string.sub(path, slash) else ""
  end
  path = text.decodeComponent(path)
  local dir, name = string.match(path, "^(.*/)([^/]*)$")
  if dir == nil or name == "" or name == "." or name == ".." then
    return nil
  end
  local stem = string.match(name, "^(.+)%.[^.]*$") or name
  return dir .. stem .. ".lrc"
end

local function sidecarLyrics(url)
  local path = sidecarPath(url)
  if path == nil then
    return nil
  end
  local info = noctalia.fileInfo(path)
  if info == nil or info.isDir or info.size == 0 or info.size > MAX_SIDECAR_BYTES then
    return nil
  end
  local body = noctalia.readFile(path)
  if body == nil then
    return nil
  end
  local result = lrc.parseSidecar(body)
  if result.status ~= "ready" then
    return nil
  end
  result.source = "sidecar"
  return result
end

-- ── Disk cache ──────────────────────────────────────────────────────────────
-- One line per lookup: the JSON metadata, a tab, then the JSON result. Results are decoded only when used, so loading
-- and saving the file stays cheap however much lyrics text it holds.

local diskPath = nil
local disk = {} -- key -> { status, savedAt, usedAt, album, durationMs, result = json string }
local diskCount = 0

local function diskExpired(record, now)
  local lifetime = if record.status == "ready" then READY_LIFETIME_MS else NOT_FOUND_LIFETIME_MS
  return now - record.savedAt > lifetime
end

local function loadDisk()
  local dir = noctalia.pluginDataDir()
  if dir == nil then
    return
  end
  diskPath = dir .. "/cache.jsonl"
  local body = noctalia.readFile(diskPath)
  if body == nil then
    return
  end
  local now = noctalia.nowMs()
  for _, line in ipairs(lrc.splitLines(body)) do
    local tab = string.find(line, "\t", 1, true)
    local meta = if tab then noctalia.json.decode(string.sub(line, 1, tab - 1)) else nil
    if
      type(meta) == "table"
      and type(meta.key) == "string"
      and (meta.status == "ready" or meta.status == "not_found")
      and type(meta.savedAt) == "number"
      and type(meta.usedAt) == "number"
      and type(meta.album) == "string"
      and type(meta.durationMs) == "number"
    then
      meta.result = string.sub(line, tab + 1)
      if not diskExpired(meta, now) then
        if disk[meta.key] == nil then
          diskCount += 1
        end
        disk[meta.key] = meta
      end
    end
  end
end

local function saveDisk()
  if diskPath == nil then
    return
  end
  local lines = {}
  for key, record in pairs(disk) do
    local meta = noctalia.json.encode({
      key = key,
      status = record.status,
      savedAt = record.savedAt,
      usedAt = record.usedAt,
      album = record.album,
      durationMs = record.durationMs,
    })
    table.insert(lines, meta .. "\t" .. record.result)
  end
  local temporary = diskPath .. ".tmp"
  local written, err = noctalia.writeFile(temporary, table.concat(lines, "\n"))
  if written then
    written, err = noctalia.renameFile(temporary, diskPath)
  end
  if not written then
    noctalia.log(`lyrics: cannot save cache: {err}`)
  end
end

local function storeDisk(key, rawTrack, result, now)
  if result.status ~= "ready" and result.status ~= "not_found" then
    return
  end
  if disk[key] == nil then
    diskCount += 1
  end
  disk[key] = {
    status = result.status,
    savedAt = now,
    usedAt = now,
    album = rawTrack.album,
    durationMs = rawTrack.durationMs,
    result = noctalia.json.encode({
      lines = result.lines,
      plain = result.plain,
      instrumental = result.instrumental,
      recordingDurationMs = result.recordingDurationMs,
      source = result.source,
    }),
  }
  while diskCount > MAX_DISK_ENTRIES do
    local oldestKey, oldest = nil, nil
    for candidateKey, record in pairs(disk) do
      if oldest == nil or record.usedAt < oldest.usedAt then
        oldestKey, oldest = candidateKey, record
      end
    end
    disk[oldestKey] = nil
    diskCount -= 1
  end
  saveDisk()
end

-- The cached result for `key`, or nil when there is none, it expired or it failed to decode.
local function loadDiskResult(key, now)
  local record = disk[key]
  if record == nil then
    return nil
  end
  local decoded = if diskExpired(record, now) then nil else noctalia.json.decode(record.result)
  if type(decoded) ~= "table" then
    disk[key] = nil
    diskCount -= 1
    return nil
  end
  record.usedAt = now
  local result = lrc.newResult(record.status)
  result.lines = decoded.lines or {}
  result.plain = decoded.plain or {}
  result.instrumental = decoded.instrumental == true
  result.recordingDurationMs = decoded.recordingDurationMs or 0
  result.source = decoded.source or ""
  for _, line in ipairs(result.lines) do
    line.words = line.words or {}
  end
  return result, record
end

-- ── Per-track offsets ───────────────────────────────────────────────────────
-- Timing corrections for a recording whose lyrics run early or late, e.g. a music video with a longer intro. Keyed on
-- the media url (without playback position parameters) or else the title and artists, never the player's bus name,
-- so they survive browser restarts.

local offsetsPath = nil
local offsets = {} -- offset key -> { offsetMs, usedAt }
local offsetCount = 0

local function offsetKey(player)
  local url = player.url or ""
  if url ~= "" and not isFileUrl(url) then
    url = string.gsub(url, "#.*$", "")
    for _, param in ipairs({ "t", "start", "time_continue" }) do
      url = string.gsub(url, "([?&])" .. param .. "=[^&]*&?", "%1")
    end
    url = string.gsub(url, "[?&]$", "")
  end
  if url ~= "" then
    return "url:" .. url
  end
  return "track:" .. text.matchKey(player.title or "") .. "\0" .. text.matchKey(joinedArtists(player))
end

local function loadOffsets()
  local dir = noctalia.pluginDataDir()
  if dir == nil then
    return
  end
  offsetsPath = dir .. "/offsets.json"
  local body = noctalia.readFile(offsetsPath)
  local decoded = if body ~= nil then noctalia.json.decode(body) else nil
  if type(decoded) ~= "table" then
    return
  end
  for key, record in pairs(decoded) do
    if type(key) == "string" and type(record) == "table" and type(record.offsetMs) == "number" then
      offsets[key] = { offsetMs = record.offsetMs, usedAt = tonumber(record.usedAt) or 0 }
      offsetCount += 1
    end
  end
end

local function saveOffsets()
  if offsetsPath == nil then
    return
  end
  local temporary = offsetsPath .. ".tmp"
  local written, err = noctalia.writeFile(temporary, noctalia.json.encode(offsets))
  if written then
    written, err = noctalia.renameFile(temporary, offsetsPath)
  end
  if not written then
    noctalia.log(`lyrics: cannot save offsets: {err}`)
  end
end

local function trackOffset(player)
  local record = offsets[offsetKey(player)]
  return if record ~= nil then record.offsetMs else 0
end

local function setTrackOffset(player, offsetMs, now)
  local key = offsetKey(player)
  offsetMs = math.clamp(math.floor(offsetMs + 0.5), -MAX_OFFSET_MS, MAX_OFFSET_MS)
  if offsetMs == 0 then
    if offsets[key] ~= nil then
      offsets[key] = nil
      offsetCount -= 1
    end
  else
    if offsets[key] == nil then
      offsetCount += 1
    end
    offsets[key] = { offsetMs = offsetMs, usedAt = now }
    while offsetCount > MAX_OFFSETS do
      local oldestKey, oldest = nil, nil
      for candidateKey, record in pairs(offsets) do
        if oldest == nil or record.usedAt < oldest.usedAt then
          oldestKey, oldest = candidateKey, record
        end
      end
      offsets[oldestKey] = nil
      offsetCount -= 1
    end
  end
  saveOffsets()
  return offsetMs
end

-- ── Lookups ─────────────────────────────────────────────────────────────────

local entries = {} -- track key -> entry
local entryCount = 0
local queue = {} -- keys of entries waiting for their next request
local busy = false
local priorityCounter = 0
local nextRequestAt = {} -- slot -> ms
local backoffUntil = {} -- slot -> ms

local requestCatalog, requestLyrics, enqueue, startNext, complete

local function newEntry(key, player, rawTrack)
  return {
    key = key,
    busName = player.busName,
    trackId = player.trackId,
    rawTrack = rawTrack,
    track = rawTrack,
    pendingTrack = nil,
    isrc = "",
    deezerId = 0,
    provider = nil,
    url = nil,
    hadError = false,
    -- Whether a lyrics source answered (found or not), and whether one was skipped while backed off.
    answered = false,
    skipped = false,
    best = nil,
    bestProvider = nil,
    -- Every synced result so far, compared against each other when no single one matches the playing length.
    candidates = {},
    -- Lyrics-only sources already retried with the short query.
    retriedShort = {},
    sourceDurationMs = 0,
    result = nil,
    expiresAt = 0,
    usedAt = 0,
    failures = 0,
    priority = 0,
    callbacks = {},
  }
end

-- Clears the lookup progress so the chain runs again for `rawTrack`.
local function resetLookup(entry, rawTrack)
  entry.rawTrack = rawTrack
  entry.track = rawTrack
  entry.pendingTrack = nil
  entry.isrc = ""
  entry.deezerId = 0
  entry.hadError = false
  entry.answered = false
  entry.skipped = false
  entry.best = nil
  entry.bestProvider = nil
  entry.candidates = {}
  entry.retriedShort = {}
  entry.sourceDurationMs = 0
  entry.result = nil
end

local function trimEntries()
  while entryCount > MAX_ENTRIES do
    local oldestKey, oldest = nil, nil
    for key, entry in pairs(entries) do
      if entry.result ~= nil and (oldest == nil or entry.usedAt < oldest.usedAt) then
        oldestKey, oldest = key, entry
      end
    end
    if oldestKey == nil then
      return
    end
    entries[oldestKey] = nil
    entryCount -= 1
  end
end

local function lengthMatches(result, wantedMs)
  if wantedMs <= 0 or result.recordingDurationMs <= 0 then
    return false
  end
  return math.abs(result.recordingDurationMs - wantedMs) <= math.max(MIN_LENGTH_SLACK_MS, wantedMs // 100)
end

-- Word timing beats line timing beats plain text.
local function lyricsQuality(result)
  if result.status ~= "ready" then
    return 0
  end
  for _, line in ipairs(result.lines) do
    if #line.words > 0 then
      return 3
    end
  end
  if #result.lines > 0 then
    return 2
  end
  return if #result.plain > 0 then 1 else 0
end

local function wantedMs(entry)
  return math.floor(entry.rawTrack.durationMs)
end

local function consider(entry, provider, result)
  local quality = lyricsQuality(result)
  if quality == 0 then
    return
  end
  if quality >= 2 then
    table.insert(entry.candidates, { result = result, provider = provider })
  end
  local wanted = wantedMs(entry)
  local function rank(lyrics, source)
    local q = lyricsQuality(lyrics)
    return {
      if lengthMatches(lyrics, wanted) and q >= 2 then 1 else 0,
      if q >= 2 then 1 else 0,
      if q >= 1 then 1 else 0,
      -providers.sourceOrder(source),
    }
  end
  if entry.best == nil then
    entry.best, entry.bestProvider = result, provider
    return
  end
  local mine, theirs = rank(result, provider), rank(entry.best, entry.bestProvider)
  for i = 1, #mine do
    if mine[i] ~= theirs[i] then
      if mine[i] > theirs[i] then
        entry.best, entry.bestProvider = result, provider
      end
      return
    end
  end
end

local function settled(entry)
  if entry.best == nil or lyricsQuality(entry.best) < 2 then
    return false
  end
  local wanted = wantedMs(entry)
  return wanted <= 0 or lengthMatches(entry.best, wanted)
end

-- Line start times keyed on the line's words, in order of appearance, so repeated chorus lines pair up by occurrence.
local function lineTimes(result)
  local times = {}
  for _, line in ipairs(result.lines) do
    local key = text.matchKey(line.text)
    if key ~= "" then
      local list = times[key]
      if list == nil then
        list = {}
        times[key] = list
      end
      table.insert(list, line.timeMs)
    end
  end
  return times
end

-- For each candidate, the number of its lines that more of the other sources contradict than confirm.
local function disputedLines(candidates)
  local maps = {}
  for i, candidate in ipairs(candidates) do
    maps[i] = lineTimes(candidate.result)
  end
  local counts = {}
  for i, map in ipairs(maps) do
    local disputed = 0
    for key, list in pairs(map) do
      for occurrence, timeMs in ipairs(list) do
        local agree, disagree = 0, 0
        for j, other in ipairs(maps) do
          local otherTime = if j ~= i and other[key] ~= nil then other[key][occurrence] else nil
          if otherTime ~= nil then
            if math.abs(otherTime - timeMs) <= AGREE_MS then
              agree += 1
            else
              disagree += 1
            end
          end
        end
        if disagree > agree then
          disputed += 1
        end
      end
    end
    counts[i] = disputed
  end
  return counts
end

-- Among several synced results: one made for the playing length, then the one the other sources agree with most,
-- then the preferred source.
local function mostTrusted(entry)
  local candidates = entry.candidates
  local disputed = disputedLines(candidates)
  local wanted = wantedMs(entry)
  local bestIndex, bestRank = nil, nil
  for i, candidate in ipairs(candidates) do
    local rank = {
      if lengthMatches(candidate.result, wanted) then 1 else 0,
      -disputed[i],
      -providers.sourceOrder(candidate.provider),
    }
    local better = bestRank == nil
    if not better then
      for k = 1, #rank do
        if rank[k] ~= bestRank[k] then
          better = rank[k] > bestRank[k]
          break
        end
      end
    end
    if better then
      bestIndex, bestRank = i, rank
    end
  end
  local summary = {}
  for i, candidate in ipairs(candidates) do
    table.insert(summary, `{candidate.provider}={disputed[i]}`)
  end
  local chosen = candidates[bestIndex]
  noctalia.log(`lyrics: compared sources (disputed lines: {table.concat(summary, ", ")}), using {chosen.provider}`)
  return chosen.result
end

local function finishBest(entry)
  local result
  if #entry.candidates >= 2 then
    result = mostTrusted(entry)
  elseif entry.best ~= nil then
    result = entry.best
  elseif entry.hadError or entry.skipped or not entry.answered then
    -- Not every source could be asked, so the lyrics may still exist.
    result = lrc.newResult("error")
  else
    result = lrc.newResult("not_found")
  end
  complete(entry, result)
end

-- Search terms for lyrics-only sources: the catalog's names when the track was identified, else the cleaned title.
local function sourceQuery(entry)
  if entry.isrc ~= "" or entry.deezerId ~= 0 then
    return entry.track.title .. " " .. entry.track.artist
  end
  return catalog.searchText(entry.rawTrack)
end

-- A narrower query for a source whose search found nothing. For a track identified in a catalog: the catalog title and
-- the one catalog artist the player's metadata also names (else the first). Otherwise: the cleaned player title alone,
-- without the uploader and without "by", e.g. "crazy chomin" for a "Crazy (feat. Yina) by chomin" video from the
-- "DJMAX ARCHIVE" channel. Matching still scores results against the full metadata, so a loose query cannot pick
-- another song.
local function shortQuery(entry)
  if entry.track == entry.rawTrack or entry.track.title == "" then
    local words = {}
    for _, word in ipairs(text.tokens(catalog.searchText({ title = entry.rawTrack.title, artist = "" }))) do
      if word ~= "by" then
        table.insert(words, word)
      end
    end
    return if #words > 0 then table.concat(words, " ") else nil
  end
  local artists = {}
  for artist in string.gmatch(entry.track.artist, "[^,]+") do
    artist = string.match(artist, "^%s*(.-)%s*$")
    if artist ~= "" then
      table.insert(artists, artist)
    end
  end
  if #artists == 0 then
    return nil
  end
  local mentioned = text.matchKey(entry.rawTrack.title .. " " .. entry.rawTrack.artist)
  for _, artist in ipairs(artists) do
    local key = text.matchKey(artist)
    if key ~= "" and string.find(mentioned, key, 1, true) then
      return entry.track.title .. " " .. artist
    end
  end
  return entry.track.title .. " " .. artists[1]
end

local function requestMusicBrainz(entry)
  enqueue(entry, providers.MUSICBRAINZ, providers.musicBrainzUrl(entry.rawTrack))
end

function requestCatalog(entry)
  local query = catalog.searchText(entry.rawTrack)
  if query == "" then
    requestMusicBrainz(entry)
  else
    enqueue(entry, providers.DEEZER_SEARCH, providers.deezerSearchUrl(query))
  end
end

function requestLyrics(entry)
  enqueue(entry, providers.LRCMUX, providers.lrcmuxUrl(entry.track, entry.isrc))
end

local function requestLyricsPlus(entry)
  enqueue(entry, providers.LYRICSPLUS, providers.lyricsPlusUrl(entry.track))
end

local function requestLrclib(entry)
  enqueue(entry, providers.LRCLIB, providers.lrclibUrl(catalog.searchText(entry.track)))
end

local function requestKugou(entry)
  entry.sourceDurationMs = 0
  enqueue(entry, providers.KUGOU_SONG, providers.kugouSongUrl(sourceQuery(entry)))
end

local function requestNetease(entry)
  entry.sourceDurationMs = 0
  enqueue(entry, providers.NETEASE_SEARCH, providers.neteaseSearchUrl(sourceQuery(entry)))
end

-- Moves on after `provider` gave nothing usable (or was skipped).
local function advance(entry, provider)
  if provider == providers.DEEZER_SEARCH then
    requestMusicBrainz(entry)
    return
  end
  if provider == providers.MUSICBRAINZ or provider == providers.DEEZER_TRACK then
    requestLyrics(entry)
    return
  end
  if settled(entry) then
    finishBest(entry)
  elseif provider == providers.LRCMUX then
    requestLyricsPlus(entry)
  elseif provider == providers.LYRICSPLUS then
    requestLrclib(entry)
  elseif provider == providers.LRCLIB then
    -- No synced lyrics for a recording of the playing length so far: KuGou and NetEase either supply some or let the
    -- sources be compared.
    requestKugou(entry)
  elseif
    provider == providers.KUGOU_SONG
    or provider == providers.KUGOU_SEARCH
    or provider == providers.KUGOU_LYRIC
  then
    requestNetease(entry)
  else
    finishBest(entry)
  end
end

function enqueue(entry, provider, url)
  local slot = providers.slot(provider)
  if noctalia.nowMs() < (backoffUntil[slot] or 0) then
    if
      provider ~= providers.MUSICBRAINZ
      and provider ~= providers.DEEZER_SEARCH
      and provider ~= providers.DEEZER_TRACK
    then
      entry.skipped = true
    end
    advance(entry, provider)
    return
  end
  entry.provider = provider
  entry.url = url
  table.insert(queue, entry.key)
  startNext()
end

local function markError(entry, provider, now, reason)
  entry.hadError = true
  local slot = providers.slot(provider)
  if (backoffUntil[slot] or 0) < now + PROVIDER_BACKOFF_MS then
    noctalia.log(`lyrics: {provider} failed ({reason}), skipping it for 10 minutes`)
    backoffUntil[slot] = now + PROVIDER_BACKOFF_MS
  end
end

local function handleResponse(entry, provider, response)
  local now = noctalia.nowMs()
  local slot = providers.slot(provider)
  nextRequestAt[slot] = now + providers.spacingMs(provider)
  if offline then
    complete(entry, lrc.newResult("offline"))
    return
  end
  local status = response.status or 0
  local transportOk = response.ok == true
  local responseOk = transportOk and status == 200
  if status == 429 or status == 503 then
    -- Rate limited: pause the source and carry on with the next one instead of waiting.
    entry.hadError = true
    backoffUntil[slot] = math.max(backoffUntil[slot] or 0, now + RATE_LIMIT_PAUSE_MS)
  elseif not responseOk and (not transportOk or status ~= 404) then
    markError(entry, provider, now, if transportOk then `HTTP {status}` else "unreachable")
  end

  if provider == providers.MUSICBRAINZ or provider == providers.DEEZER_SEARCH then
    if responseOk then
      local matcher = if provider == providers.MUSICBRAINZ then catalog.matchMusicBrainz else catalog.matchDeezer
      local match, err = matcher(response.body, entry.rawTrack)
      if err ~= nil then
        markError(entry, provider, now, err)
      elseif match ~= nil then
        entry.track = match.track
        entry.isrc = match.isrc
        entry.deezerId = match.deezerId
        if entry.isrc == "" and entry.deezerId ~= 0 then
          enqueue(entry, providers.DEEZER_TRACK, providers.deezerTrackUrl(entry.deezerId))
        else
          requestLyrics(entry)
        end
        return
      end
    end
    advance(entry, provider)
    return
  end

  if provider == providers.DEEZER_TRACK then
    if responseOk then
      entry.isrc = providers.deezerIsrc(response.body, entry.deezerId) or entry.isrc
    end
    requestLyrics(entry)
    return
  end

  local answered = responseOk or (transportOk and status == 404)

  if provider == providers.KUGOU_SONG or provider == providers.NETEASE_SEARCH then
    local kugou = provider == providers.KUGOU_SONG
    if responseOk then
      local match, err = (if kugou then catalog.matchKugou else catalog.matchNetease)(response.body, entry.track)
      if err ~= nil then
        markError(entry, provider, now, err)
      else
        entry.answered = true
        if match ~= nil then
          entry.sourceDurationMs = match.track.durationMs
          if kugou then
            enqueue(entry, providers.KUGOU_SEARCH, providers.kugouSearchUrl(match.sourceId))
          else
            enqueue(entry, providers.NETEASE_LYRIC, providers.neteaseLyricUrl(match.sourceId))
          end
          return
        end
        local short = if entry.retriedShort[provider] then nil else shortQuery(entry)
        if short ~= nil and short ~= sourceQuery(entry) then
          entry.retriedShort[provider] = true
          enqueue(entry, provider, (if kugou then providers.kugouSongUrl else providers.neteaseSearchUrl)(short))
          return
        end
      end
    elseif answered then
      entry.answered = true
    end
    advance(entry, provider)
    return
  end

  if provider == providers.KUGOU_SEARCH then
    if responseOk then
      local candidate, err = catalog.pickKugouLyrics(response.body)
      if err ~= nil then
        markError(entry, provider, now, err)
      elseif candidate ~= nil then
        enqueue(entry, providers.KUGOU_LYRIC, providers.kugouLyricUrl(candidate))
        return
      else
        entry.answered = true
      end
    elseif answered then
      entry.answered = true
    end
    advance(entry, provider)
    return
  end

  local result = lrc.newResult()
  if responseOk then
    if provider == providers.LRCMUX then
      result = lrc.parseLrcmux(response.body, entry.track, entry.isrc)
    elseif provider == providers.LYRICSPLUS then
      result = lrc.parseLyricsPlus(response.body, entry.track)
    elseif provider == providers.KUGOU_LYRIC then
      result = lrc.parseKugou(response.body)
    elseif provider == providers.NETEASE_LYRIC then
      result = lrc.parseNetease(response.body)
    else
      result = lrc.parseLrclibSearch(response.body, entry.track)
    end
    if result.status == "error" then
      markError(entry, provider, now, "unexpected response")
    else
      entry.answered = true
    end
    if
      result.recordingDurationMs <= 0
      and (provider == providers.KUGOU_LYRIC or provider == providers.NETEASE_LYRIC)
    then
      result.recordingDurationMs = entry.sourceDurationMs
    end
  elseif answered then
    entry.answered = true
  end
  if provider == providers.LRCLIB and responseOk and result.status == "not_found" and not entry.retriedShort[provider] then
    local short = shortQuery(entry)
    if short ~= nil and short ~= catalog.searchText(entry.track) then
      entry.retriedShort[provider] = true
      enqueue(entry, provider, providers.lrclibUrl(short))
      return
    end
  end
  result.source = provider
  if result.status == "ready" and result.instrumental then
    complete(entry, result)
    return
  end
  consider(entry, provider, result)
  advance(entry, provider)
end

function startNext()
  if busy or #queue == 0 then
    return
  end
  if offline then
    local pending = queue
    queue = {}
    for _, key in ipairs(pending) do
      local entry = entries[key]
      if entry ~= nil then
        complete(entry, lrc.newResult("offline"))
      end
    end
    return
  end
  local now = noctalia.nowMs()
  -- Serve the most recently requested track first so stale lookups from earlier metadata never delay it.
  local nextIndex = nil
  for index, key in ipairs(queue) do
    local entry = entries[key]
    if
      (nextRequestAt[providers.slot(entry.provider)] or 0) <= now
      and (nextIndex == nil or entry.priority > entries[queue[nextIndex]].priority)
    then
      nextIndex = index
    end
  end
  if nextIndex == nil then
    return -- the next poll tries again once a slot's spacing has passed
  end
  local key = table.remove(queue, nextIndex)
  local entry = entries[key]
  local provider = entry.provider
  busy = true
  local accepted = noctalia.http({ url = entry.url, headers = { USER_AGENT } }, function(response)
    busy = false
    if entries[key] == entry then
      handleResponse(entry, provider, response)
    end
    startNext()
  end)
  if not accepted then
    busy = false
    handleResponse(entry, provider, { ok = false, status = 0, body = "" })
  end
end

function complete(entry, result)
  if result.status ~= "ready" and entry.pendingTrack ~= nil and not offline then
    resetLookup(entry, entry.pendingTrack)
    requestCatalog(entry)
    return
  end
  local now = noctalia.nowMs()
  entry.pendingTrack = nil
  entry.result = result
  entry.usedAt = now
  if result.status == "error" then
    if entry.hadError then
      entry.failures += 1
      entry.expiresAt = now + math.min(RETRY_BASE_MS * 2 ^ (entry.failures - 1), RETRY_MAX_MS)
    else
      -- Only skipped sources kept it from completing: retry once the first of them is available again.
      local reopens = math.huge
      for _, reopensAt in pairs(backoffUntil) do
        if reopensAt > now then
          reopens = math.min(reopens, reopensAt)
        end
      end
      entry.expiresAt = math.max(now + RETRY_BASE_MS, if reopens < math.huge then reopens else now)
    end
  else
    entry.failures = 0
    if result.status == "ready" then
      entry.expiresAt = now + READY_LIFETIME_MS
      lastReady[entry.busName] = { key = entry.key, trackId = entry.trackId, title = entry.rawTrack.title, seenAt = now }
    elseif result.status == "not_found" then
      entry.expiresAt = now + NOT_FOUND_LIFETIME_MS
    else
      entry.expiresAt = now
    end
    storeDisk(entry.key, entry.rawTrack, result, now)
  end
  local callbacks = entry.callbacks
  entry.callbacks = {}
  for _, callback in ipairs(callbacks) do
    callback(result, entry.expiresAt)
  end
  trimEntries()
  startNext()
end

-- A still valid ready result for `key` from memory or disk, or nil.
local function cachedReady(key, now)
  local entry = entries[key]
  if entry ~= nil then
    if entry.result ~= nil and entry.result.status == "ready" and entry.expiresAt > now then
      entry.usedAt = now
      return entry.result
    end
    return nil
  end
  local result = loadDiskResult(key, now)
  return if result ~= nil and result.status == "ready" then result else nil
end

-- Looks up lyrics for the player's track and calls `callback(result, retryAt)`, now or when the lookup completes.
local function request(player, callback)
  local now = noctalia.nowMs()
  local localLyrics = sidecarLyrics(player.url)
  if localLyrics ~= nil then
    callback(localLyrics, math.huge)
    return
  end
  local key = trackKey(player)
  local rawTrack = lookupTrack(player, staleLengthFor(player, key, now))
  -- Without an artist there is nothing to search for; only a sidecar file can provide lyrics.
  if rawTrack.title == "" or rawTrack.artist == "" then
    callback(lrc.newResult("not_found"), now + LOCAL_ONLY_RETRY_MS)
    return
  end
  if offline then
    callback(lrc.newResult("offline"), math.huge)
    return
  end
  -- A title that wraps the last found one (e.g. a scraped page title) is the same track. Weaker evidence needs the
  -- playback history the poll loop tracks, so it is not applied here.
  local last = lastReady[player.busName]
  if
    last ~= nil
    and last.key ~= key
    and last.trackId == player.trackId
    and catalog.titleContinues(last.title, player.title)
  then
    local kept = cachedReady(last.key, now)
    if kept ~= nil then
      callback(kept, math.huge)
      return
    end
  end

  local entry = entries[key]
  if entry ~= nil and entry.result ~= nil then
    local retryWithMetadata = entry.result.status ~= "ready" and meaningfulMetadataChanged(entry.rawTrack, rawTrack)
    if retryWithMetadata or entry.expiresAt <= now then
      priorityCounter += 1
      entry.priority = priorityCounter
      table.insert(entry.callbacks, callback)
      resetLookup(entry, rawTrack)
      requestCatalog(entry)
      return
    end
    entry.usedAt = now
    callback(entry.result, entry.expiresAt)
    return
  end
  if entry ~= nil then
    local previous = entry.pendingTrack or entry.rawTrack
    if meaningfulMetadataChanged(previous, rawTrack) then
      entry.pendingTrack = rawTrack
    end
    priorityCounter += 1
    entry.priority = priorityCounter
    table.insert(entry.callbacks, callback)
    return
  end

  entry = newEntry(key, player, rawTrack)
  priorityCounter += 1
  entry.priority = priorityCounter
  table.insert(entry.callbacks, callback)
  entries[key] = entry
  entryCount += 1

  local cached, record = loadDiskResult(key, now)
  if
    cached ~= nil
    and not (cached.status ~= "ready" and meaningfulMetadataChanged({ album = record.album, durationMs = record.durationMs }, rawTrack))
  then
    entry.result = cached
    entry.usedAt = now
    entry.expiresAt = record.savedAt + (if cached.status == "ready" then READY_LIFETIME_MS else NOT_FOUND_LIFETIME_MS)
    entry.callbacks = {}
    if cached.status == "ready" then
      lastReady[entry.busName] = { key = key, trackId = entry.trackId, title = rawTrack.title, seenAt = now }
    end
    callback(cached, entry.expiresAt)
    trimEntries()
    return
  end
  requestCatalog(entry)
end

-- ── Following the player ────────────────────────────────────────────────────

-- The lookup the published state belongs to.
local subject = {
  requestKey = "",
  generation = 0,
  result = nil,
  retryAt = 0,
  offline = offline,
  bus = "",
  trackId = "",
  title = "",
  album = "",
  lengthMs = 0,
}
local lastSeen = nil -- { busName, positionMs, rate, playing, at }
local published = nil

local function publish(player, hasTrack)
  local value
  if not hasTrack then
    value = { key = "", busName = "", trackId = "", title = "", lengthMs = 0, status = "idle", offsetMs = 0 }
  else
    local result = subject.result
    value = {
      key = subject.requestKey,
      busName = player.busName,
      trackId = player.trackId,
      title = player.title,
      lengthMs = player.lengthMs or 0,
      status = if result == nil then "loading" else result.status,
      offsetMs = trackOffset(player),
    }
  end
  local result = if hasTrack then subject.result else nil
  local signature =
    `{value.key}\0{value.status}\0{value.busName}\0{value.trackId}\0{value.title}\0{value.lengthMs}\0{value.offsetMs}`
  if published ~= nil and published.signature == signature and published.result == result then
    return
  end
  if result ~= nil and result.status == "ready" and (published == nil or published.result ~= result) then
    noctalia.log(
      `lyrics: "{value.title}" from {providers.displayName(result.source)}`
        .. ` (recording {result.recordingDurationMs // 1000} s, track {value.lengthMs // 1000} s,`
        .. ` offset {value.offsetMs} ms)`
    )
  end
  published = { signature = signature, result = result }
  value.instrumental = result ~= nil and result.instrumental or false
  value.lines = if result ~= nil and result.status == "ready" then result.lines else {}
  value.plain = if result ~= nil and result.status == "ready" then result.plain else {}
  value.source = if result ~= nil and result.status == "ready" then result.source or "" else ""
  value.recordingDurationMs = if result ~= nil then result.recordingDurationMs or 0 else 0
  noctalia.state.set("lyrics", value)
end

local warnedNoPlayerApi = false

local function poll()
  local now = noctalia.nowMs()
  local player = nil
  if noctalia.mediaPlayer ~= nil then
    player = noctalia.mediaPlayer()
  elseif not warnedNoPlayerApi then
    warnedNoPlayerApi = true
    noctalia.log("lyrics: this Noctalia version has no noctalia.mediaPlayer()")
  end
  prunePlayers(if player then player.busName else nil, now)

  local hasTrack = player ~= nil
    and player.status ~= "Stopped"
    and ((player.title or "") ~= "" or isFileUrl(player.url))
  local playerKey = if hasTrack then trackKey(player) else ""

  local expectedPositionMs = nil
  if player ~= nil and lastSeen ~= nil and lastSeen.busName == player.busName then
    expectedPositionMs = lastSeen.positionMs
    if lastSeen.playing then
      expectedPositionMs += (now - lastSeen.at) * lastSeen.rate
    end
  end
  if player ~= nil then
    lastSeen = {
      busName = player.busName,
      positionMs = player.positionMs or 0,
      rate = player.rate or 1,
      playing = player.status == "Playing",
      at = now,
    }
  else
    lastSeen = nil
  end

  -- Players such as Chromium report other metadata for the same track (a scraped page title, or a hover-preview
  -- video while the real one keeps playing or is paused). Keep the lyrics only while that holds; it is re-checked on
  -- every poll, so a real change is looked up as soon as the evidence stops matching.
  local holding = hasTrack
    and playerKey ~= subject.requestKey
    and subject.result ~= nil
    and subject.result.status == "ready"
    and player.busName == subject.bus
    and continuesTrack(player, subject.trackId, subject.title, subject.lengthMs, expectedPositionMs)
  local key = if holding then subject.requestKey else playerKey
  local sameTrack = key ~= "" and key == subject.requestKey
  local lengthMs = if player then player.lengthMs or 0 else 0
  local metadataImproved = hasTrack
    and (
      (subject.album == "" and (player.album or "") ~= "")
      or (subject.lengthMs <= 0 and lengthMs > 0)
      or math.abs(lengthMs - subject.lengthMs) >= 1000
    )
  local missingLyrics = subject.result == nil or subject.result.status ~= "ready"
  local retry = subject.result ~= nil and missingLyrics and not offline and now >= subject.retryAt
  if
    key ~= subject.requestKey
    or offline ~= subject.offline
    or retry
    or (sameTrack and metadataImproved and missingLyrics and not offline)
  then
    subject.requestKey = key
    subject.offline = offline
    if not sameTrack or missingLyrics then
      subject.result = nil
    end
    if hasTrack then
      subject.album = player.album or ""
      subject.title = player.title
      subject.bus = player.busName
      subject.trackId = player.trackId
      subject.lengthMs = lengthMs
    end
    subject.generation += 1
    local generation = subject.generation
    if hasTrack then
      request(player, function(result, retryAt)
        if generation ~= subject.generation then
          return
        end
        -- Keep a usable snapshot while an unchanged track is refreshed or taken offline.
        if subject.result == nil or subject.result.status ~= "ready" or result.status == "ready" then
          subject.result = result
        end
        subject.retryAt = retryAt
      end)
    end
  end
  startNext()
  publish(player, hasTrack)
end

loadDisk()
loadOffsets()
poll()
noctalia.setUpdateInterval(POLL_MS)

function update()
  poll()
end

function onConfigChanged()
  offline = noctalia.getSetting("shell.offline_mode") == true
  poll()
end

local function formatOffset(offsetMs)
  return string.format("%+.1f s", offsetMs / 1000)
end

-- noctalia msg plugin noctalia/lyrics:service all offset +250|-250|<ms>|reset
-- noctalia msg plugin noctalia/lyrics:service all status
function onIpc(event, payload)
  local player = noctalia.mediaPlayer()
  if player == nil then
    noctalia.notify(noctalia.tr("ipc.title"), noctalia.tr("status.nothing-playing"))
    return
  end
  if event == "offset" then
    local arg = payload or ""
    local current = trackOffset(player)
    local target
    if arg == "reset" then
      target = 0
    elseif string.match(arg, "^[+-]%d+$") then
      target = current + tonumber(arg)
    elseif string.match(arg, "^%d+$") then
      target = tonumber(arg)
    else
      noctalia.notifyError(noctalia.tr("ipc.title"), noctalia.tr("ipc.offset_usage"))
      return
    end
    local applied = setTrackOffset(player, target, noctalia.nowMs())
    noctalia.osd.show("clock", noctalia.tr("ipc.offset", { value = formatOffset(applied) }))
    poll()
  elseif event == "status" then
    local result = subject.result
    local source = if result ~= nil and result.status == "ready" then providers.displayName(result.source) else "-"
    noctalia.notify(
      noctalia.tr("ipc.title"),
      noctalia.tr("ipc.status", {
        title = player.title,
        source = source,
        recording = tostring(if result ~= nil then (result.recordingDurationMs or 0) // 1000 else 0),
        track = tostring((player.lengthMs or 0) // 1000),
        offset = formatOffset(trackOffset(player)),
      })
    )
  else
    noctalia.notifyError(noctalia.tr("ipc.title"), noctalia.tr("ipc.unknown", { event = event }))
  end
end
