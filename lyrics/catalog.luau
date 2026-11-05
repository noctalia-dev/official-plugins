--!nonstrict
-- Track identification: cleaning messy player metadata (video titles, uploader channels), scoring catalog and lyrics
-- records against it, and picking the best match from Deezer, MusicBrainz, NetEase and KuGou search responses.
--
-- A track is { title, artist, album, durationMs } with durationMs = 0 when unknown. Matchers return
-- (match, nil) on a match, (nil, nil) when nothing matches and (nil, err) for an unusable response.

local text = require("./text.luau")

local M = {}

local tokens = text.tokens
local contains = text.contains
local has = text.has

local EXACT_DURATION_MS = 3000
-- Music videos often add intros/outros around the audio recording.
local LOOSE_DURATION_MS = 30000
-- A title only counts as a decorated version of the previous one when it adds at least this many words.
local MIN_DECORATION_WORDS = 3
-- Words in the player title that neither the matched recording nor video decoration explains, e.g. an unlisted guest.
local MAX_UNEXPLAINED_TITLE_WORDS = 2

local CONNECTORS = {
  x = true,
  feat = true,
  ft = true,
  featuring = true,
  mit = true,
  with = true,
  vs = true,
  prod = true,
  ["and"] = true,
  und = true,
}

local NOISE = {
  video = true,
  audio = true,
  ["4k"] = true,
  hd = true,
  hq = true,
  mv = true,
  clip = true,
  performance = true,
  explicit = true,
  version = true,
  edit = true,
  live = true,
  prod = true,
  musikvideo = true,
  music = true,
  topic = true,
  feat = true,
  ft = true,
  featuring = true,
}
local NOISE_PREFIXES = { "official", "offiziel", "remaster", "visuali", "lyric" }

local ALTERNATE_TAKES = { "instrumental", "karaoke", "live", "acoustic", "remix", "cover" }

local function isConnector(token)
  return CONNECTORS[token] == true
end

local function isNoise(token)
  if NOISE[token] or string.find(token, "^%d+$") then
    return true
  end
  for _, prefix in ipairs(NOISE_PREFIXES) do
    if string.sub(token, 1, #prefix) == prefix then
      return true
    end
  end
  return false
end

local function compact(words)
  return table.concat(words)
end

-- Whether consecutive words spell `glued`, e.g. {outline, in, color} for the channel name "OutlineInColor".
local function spells(words, glued)
  if glued == "" then
    return false
  end
  for start = 1, #words do
    local joined = ""
    local i = start
    while i <= #words and #joined < #glued do
      joined ..= words[i]
      i += 1
    end
    if joined == glued then
      return true
    end
  end
  return false
end

-- A channel-name token without its "VEVO" suffix, or nil for pure decoration (`VEVO`, `Topic`, `Official`).
local function artistToken(token)
  if #token > 4 and string.sub(token, -4) == "vevo" then
    token = string.sub(token, 1, -5)
  end
  if token == "vevo" or token == "topic" or token == "official" then
    return nil
  end
  return token
end

local artistTokensCache = {}
local artistPartsCache = {}
local artistCacheSize = 0

local function trimArtistCaches()
  artistCacheSize += 1
  if artistCacheSize > 512 then
    table.clear(artistTokensCache)
    table.clear(artistPartsCache)
    artistCacheSize = 0
  end
end

-- Strips `VEVO`, ` - Topic` and `Official` decorations that video platforms add to channel names.
local function artistTokens(artist)
  local cached = artistTokensCache[artist]
  if cached ~= nil then
    return cached
  end
  local result = {}
  for _, token in ipairs(tokens(artist)) do
    local kept = artistToken(token)
    if kept ~= nil then
      table.insert(result, kept)
    end
  end
  trimArtistCaches()
  artistTokensCache[artist] = result
  return result
end

-- Individually credited performers, e.g. "Swiss & Die Andern, Diggen" -> {swiss}, {die andern}, {diggen}.
local function artistParts(artist)
  local cached = artistPartsCache[artist]
  if cached ~= nil then
    return cached
  end
  local scanned = text.scan(artist)
  local parts = { {} }
  for i, raw in ipairs(scanned.words) do
    local token = artistToken(raw)
    if token ~= nil then
      local connector = isConnector(token)
      if (scanned.separated[i] or connector) and #parts[#parts] > 0 then
        table.insert(parts, {})
      end
      if not connector then
        table.insert(parts[#parts], token)
      end
    end
  end
  if #parts[#parts] == 0 then
    table.remove(parts)
  end
  trimArtistCaches()
  artistPartsCache[artist] = parts
  return parts
end

local function noiseGroup(value, requireAll)
  local words = tokens(value)
  if #words == 0 then
    return false
  end
  for _, word in ipairs(words) do
    local noise = isNoise(word)
    if requireAll and not noise then
      return false
    elseif not requireAll and noise then
      return true
    end
  end
  return requireAll
end

local CLOSERS = { ["("] = ")", ["["] = "]", ["{"] = "}" }
local TITLE_SEPARATORS = { " - ", " \u{2013} ", " \u{2014} ", " | ", " // " }

-- Removes "(Official Video)"-style groups and " - Remastered 2011"-style suffixes. Returns the cleaned words joined
-- by spaces and whether the title also names the artist.
local function cleanTitle(title)
  local pieces = {}
  local i = 1
  local length = #title
  while i <= length do
    local open = string.sub(title, i, i)
    local close = CLOSERS[open]
    if close == nil then
      -- Copy the run up to the next bracket in one piece.
      local nextOpen = string.find(title, "[%(%[{]", i + 1) or (length + 1)
      table.insert(pieces, string.sub(title, i, nextOpen - 1))
      i = nextOpen
    else
      local finish = string.find(title, close, i + 1, true)
      local content = string.sub(title, i + 1, if finish then finish - 1 else length)
      table.insert(pieces, " ")
      if not noiseGroup(content, false) then
        table.insert(pieces, content)
        table.insert(pieces, " ")
      end
      i = if finish then finish + 1 else length + 1
    end
  end
  local rest = table.concat(pieces)

  local out = {}
  local namesArtist = false
  local kept = 0
  while rest ~= "" do
    local cut, width = nil, 0
    for _, separator in ipairs(TITLE_SEPARATORS) do
      local at = string.find(rest, separator, 1, true)
      if at ~= nil and (cut == nil or at < cut) then
        cut = at
        width = #separator
      end
    end
    local segment
    if cut == nil then
      segment = rest
      rest = ""
    else
      segment = string.sub(rest, 1, cut - 1)
      rest = string.sub(rest, cut + width)
    end
    local words = tokens(segment)
    if #words > 0 and not (kept > 0 and noiseGroup(segment, true)) then
      kept += 1
      for index, token in ipairs(words) do
        local between = index > 1 and index < #words
        if token == "x" and between then
          namesArtist = true
        end
        if not (isConnector(token) and (token ~= "x" or between)) then
          table.insert(out, token)
        end
      end
    end
  end
  return table.concat(out, " "), namesArtist or kept > 1
end

-- The title with bracketed qualifiers and dash suffixes removed, e.g. "Song - Remastered 2011" -> "Song".
local function baseTitle(title)
  for _, marker in ipairs({ "(", "[", " - ", " \u{2013} " }) do
    local at = string.find(title, marker, 1, true)
    if at ~= nil and at > 1 then
      title = string.sub(title, 1, at - 1)
    end
  end
  return tokens(title)
end

local function validIsrc(isrc)
  return type(isrc) == "string" and string.find(isrc, "^%u%u[%u%d][%u%d][%u%d]%d%d%d%d%d%d%d$") ~= nil
end
M.validIsrc = validIsrc

-- Free-text search terms with video/channel noise, version suffixes and collaborator connectors removed.
function M.searchText(raw)
  local cleaned, namesArtist = cleanTitle(raw.title)
  local titleWords = tokens(raw.title)
  local parts = artistParts(raw.artist)
  local artistInTitle = spells(titleWords, compact(artistTokens(raw.artist)))
  for _, part in ipairs(parts) do
    if contains(titleWords, part) then
      artistInTitle = true
      break
    end
  end
  if namesArtist or artistInTitle then
    return cleaned
  end
  local out = { cleaned }
  for _, part in ipairs(parts) do
    for _, word in ipairs(part) do
      table.insert(out, word)
    end
  end
  if out[1] == "" then
    table.remove(out, 1)
  end
  return table.concat(out, " ")
end

-- Whether `current` is still the track titled `previous`: equal, or the same title wrapped in extra text such as a
-- scraped page title.
function M.titleContinues(previous, current)
  local before = tokens(previous)
  local after = tokens(current)
  if #before == 0 or #after == 0 then
    return false
  end
  return text.equal(before, after) or (#after >= #before + MIN_DECORATION_WORDS and contains(after, before))
end

-- Scores `candidate` against messy player metadata, or nil when it is not the same song.
function M.scoreTrack(wanted, candidate)
  local wantedTitle = tokens(wanted.title)
  local actualTitle = tokens(candidate.title)
  if #actualTitle == 0 then
    return nil
  end
  local score = {
    titleConfidence = 0,
    titleSpecificity = 0,
    durationConfidence = 0,
    artistConfidence = 0,
    artistSpecificity = 0,
    durationDifferenceMs = 0,
  }
  if text.equal(wantedTitle, actualTitle) then
    score.titleConfidence = 3
  elseif contains(wantedTitle, actualTitle) then
    score.titleConfidence = 2
  else
    local base = baseTitle(candidate.title)
    local alternateTake = false
    for _, word in ipairs(actualTitle) do
      if has(ALTERNATE_TAKES, word) and not has(wantedTitle, word) then
        alternateTake = true
        break
      end
    end
    if #base == 0 or text.equal(base, actualTitle) or alternateTake or not contains(wantedTitle, base) then
      return nil
    end
    score.titleConfidence = 1
    score.titleSpecificity = #base
  end
  if score.titleSpecificity == 0 then
    score.titleSpecificity = #actualTitle
  end

  local wantedArtist = artistTokens(wanted.artist)
  local actualArtist = artistTokens(candidate.artist)
  local candidateParts = artistParts(candidate.artist)
  if contains(wantedArtist, actualArtist) or (#actualArtist > 0 and compact(wantedArtist) == compact(actualArtist)) then
    score.artistConfidence = 3
    score.artistSpecificity = #actualArtist
  else
    for _, part in ipairs(candidateParts) do
      local confidence = if contains(wantedArtist, part) then 2 elseif contains(wantedTitle, part) then 1 else 0
      if
        confidence > score.artistConfidence
        or (confidence == score.artistConfidence and #part > score.artistSpecificity)
      then
        score.artistConfidence = confidence
        score.artistSpecificity = #part
      end
    end
    if score.artistConfidence == 0 then
      return nil
    end
  end

  -- A match must account for the whole player title, so a long scraped page title cannot match an unrelated song
  -- whose title and artist merely occur inside it.
  local unexplained = {}
  for _, word in ipairs(wantedTitle) do
    local explained = has(actualTitle, word)
      or has(actualArtist, word)
      or has(wantedArtist, word)
      or isConnector(word)
      or isNoise(word)
    if not explained then
      for _, part in ipairs(candidateParts) do
        if has(part, word) then
          explained = true
          break
        end
      end
    end
    if not explained and not has(unexplained, word) then
      table.insert(unexplained, word)
    end
  end
  if #unexplained > MAX_UNEXPLAINED_TITLE_WORDS then
    return nil
  end

  if wanted.durationMs > 0 and candidate.durationMs > 0 then
    score.durationDifferenceMs = math.abs(candidate.durationMs - wanted.durationMs)
    if score.durationDifferenceMs > LOOSE_DURATION_MS then
      return nil
    end
    score.durationConfidence = if score.durationDifferenceMs <= EXACT_DURATION_MS then 2 else 1
  end
  return score
end

-- Whether `left` is a strictly better match than `right`; fields are compared in priority order.
function M.stronger(left, right)
  if left.titleConfidence ~= right.titleConfidence then
    return left.titleConfidence > right.titleConfidence
  end
  if left.titleSpecificity ~= right.titleSpecificity then
    return left.titleSpecificity > right.titleSpecificity
  end
  if left.durationConfidence ~= right.durationConfidence then
    return left.durationConfidence > right.durationConfidence
  end
  if left.artistConfidence ~= right.artistConfidence then
    return left.artistConfidence > right.artistConfidence
  end
  if left.artistSpecificity ~= right.artistSpecificity then
    return left.artistSpecificity > right.artistSpecificity
  end
  return left.durationDifferenceMs < right.durationDifferenceMs
end

local QUERY_RESERVED = {}
for i = 1, #'+-&|!(){}[]^"~*?:\\/' do
  QUERY_RESERVED[string.sub('+-&|!(){}[]^"~*?:\\/', i, i)] = true
end

local function isAsciiSpace(c)
  return c == " " or c == "\t" or c == "\n" or c == "\v" or c == "\f" or c == "\r"
end

-- Escapes Lucene syntax and the AND/OR/NOT operators.
local function escapeQuery(input)
  local out = {}
  for i = 1, #input do
    local c = string.sub(input, i, i)
    if i == 1 or isAsciiSpace(string.sub(input, i - 1, i - 1)) then
      local finish = string.find(input, "[ \t\r\n]", i)
      local word = string.sub(input, i, if finish then finish - 1 else #input)
      if word == "AND" or word == "OR" or word == "NOT" then
        table.insert(out, "\\")
      end
    end
    if QUERY_RESERVED[c] then
      table.insert(out, "\\")
    end
    table.insert(out, c)
  end
  return table.concat(out)
end

-- MusicBrainz recording search query constraining title, artist and length.
function M.catalogQuery(raw)
  local title = escapeQuery(raw.title)
  local artists = title
  if raw.artist ~= "" and not contains(tokens(raw.title), tokens(raw.artist)) then
    artists ..= " " .. escapeQuery(raw.artist)
  end
  local query = `recording:({title}) AND artistname:({artists})`
  if raw.durationMs > 0 then
    local durationMs = math.floor(raw.durationMs)
    local upperMs = if raw.durationMs > durationMs then durationMs + 1 else durationMs
    query ..= string.format(
      " AND dur:[%d TO %d]",
      math.max(0, durationMs - LOOSE_DURATION_MS),
      upperMs + LOOSE_DURATION_MS
    )
  end
  return query
end

-- Response validation raises through these; matchers turn the raised message into their error result.
local function fail(message)
  error({ message = message }, 0)
end

local function isArray(value)
  return type(value) == "table" and (value[1] ~= nil or next(value) == nil)
end

local function isInteger(value)
  return type(value) == "number" and value == math.floor(value) and value == value
end

local function field(record, key, kind)
  local value = if type(record) == "table" then record[key] else nil
  if type(value) ~= kind then
    fail(`{key} must be a {kind}`)
  end
  return value
end

local function optional(record, key, kind, default)
  local value = record[key]
  if value == nil then
    return default
  end
  if type(value) ~= kind then
    fail(`{key} must be a {kind}`)
  end
  return value
end

local function decode(body)
  local value = noctalia.json.decode(body)
  if value == nil then
    fail("invalid JSON")
  end
  return value
end

-- Runs a matcher body, converting raised validation failures into (nil, message).
local function guarded(fn, ...)
  local ok, result = pcall(fn, ...)
  if ok then
    return result, nil
  end
  if type(result) == "table" and result.message ~= nil then
    return nil, result.message
  end
  return nil, tostring(result)
end

-- Equally strong candidates share title, performer and timing, so the catalog's own ranking breaks the tie.
local function choose(candidates)
  if #candidates == 0 then
    return nil
  end
  local best = candidates[1]
  for i = 2, #candidates do
    local candidate = candidates[i]
    local better
    if M.stronger(candidate.score, best.score) then
      better = true
    elseif M.stronger(best.score, candidate.score) then
      better = false
    elseif (candidate.match.isrc == "") ~= (best.match.isrc == "") then
      better = candidate.match.isrc ~= ""
    else
      better = candidate.catalogScore > best.catalogScore
    end
    if better then
      best = candidate
    end
  end
  return best.match
end

local function addCandidate(candidates, match, raw, catalogScore)
  local score = M.scoreTrack(raw, match.track)
  if score ~= nil then
    table.insert(candidates, { match = match, score = score, catalogScore = catalogScore })
  end
end

local function newMatch(title, artist, album, durationMs)
  return {
    track = { title = title, artist = artist, album = album or "", durationMs = durationMs },
    isrc = "",
    deezerId = 0,
    sourceId = "",
  }
end

-- Best recording in a MusicBrainz `ws/2/recording` search response.
function M.matchMusicBrainz(body, raw)
  return guarded(function()
    local recordings = field(decode(body), "recordings", "table")
    if not isArray(recordings) then
      fail("catalog recordings must be an array")
    end
    local candidates = {}
    for _, recording in ipairs(recordings) do
      if type(recording) ~= "table" or isArray(recording) and next(recording) ~= nil then
        fail("catalog recording must be an object")
      end
      local title = field(recording, "title", "string")
      local credits = field(recording, "artist-credit", "table")
      if not isArray(credits) then
        fail("catalog artist credit must be an array")
      end
      local milliseconds = 0
      local length = recording.length
      if isInteger(length) and length >= 0 then
        milliseconds = length
      end
      local isrc = ""
      local isrcs = recording.isrcs
      if isrcs ~= nil then
        if not isArray(isrcs) then
          fail("catalog ISRCs must be an array")
        end
        for _, value in ipairs(isrcs) do
          if type(value) ~= "string" then
            fail("catalog ISRC must be a string")
          end
          if validIsrc(value) and (isrc == "" or value < isrc) then
            isrc = value
          end
        end
      end
      local catalogScore = if type(recording.score) == "number" then recording.score else 0
      -- Each artist credit is an independently attributed performer, not an uploader alias.
      for _, credit in ipairs(credits) do
        local artist = field(field(credit, "artist", "table"), "name", "string")
        local match = newMatch(title, artist, "", milliseconds)
        match.isrc = isrc
        addCandidate(candidates, match, raw, catalogScore)
      end
    end
    return choose(candidates)
  end)
end

-- Best track in a Deezer `search` response.
function M.matchDeezer(body, raw)
  return guarded(function()
    local recordings = field(decode(body), "data", "table")
    if not isArray(recordings) then
      fail("catalog data must be an array")
    end
    local candidates = {}
    for _, recording in ipairs(recordings) do
      local id = field(recording, "id", "number")
      local seconds = field(recording, "duration", "number")
      if id > 0 and seconds > 0 and seconds <= 86400 then
        local match = newMatch(
          field(recording, "title", "string"),
          field(field(recording, "artist", "table"), "name", "string"),
          field(field(recording, "album", "table"), "title", "string"),
          math.floor(seconds) * 1000
        )
        match.deezerId = math.floor(id)
        if validIsrc(recording.isrc) then
          match.isrc = recording.isrc
        end
        addCandidate(candidates, match, raw, 0)
      end
    end
    return choose(candidates)
  end)
end

-- Best song in a NetEase `search/get` response.
function M.matchNetease(body, raw)
  return guarded(function()
    local result = decode(body).result
    if type(result) ~= "table" or (isArray(result) and next(result) ~= nil) then
      return nil
    end
    local songs = result.songs
    if songs == nil then
      return nil
    end
    if not isArray(songs) then
      fail("catalog songs must be an array")
    end
    local candidates = {}
    for _, song in ipairs(songs) do
      local id = field(song, "id", "number")
      local milliseconds = field(song, "duration", "number")
      if id > 0 and milliseconds > 0 and milliseconds <= 86400000 then
        local names = {}
        for _, artist in ipairs(field(song, "artists", "table")) do
          table.insert(names, field(artist, "name", "string"))
        end
        local match = newMatch(field(song, "name", "string"), table.concat(names, ", "), "", math.floor(milliseconds))
        match.sourceId = string.format("%.0f", id)
        addCandidate(candidates, match, raw, 0)
      end
    end
    return choose(candidates)
  end)
end

-- Best song in a KuGou `api/v3/search/song` response.
function M.matchKugou(body, raw)
  return guarded(function()
    local data = decode(body).data
    if type(data) ~= "table" or data.info == nil then
      return nil
    end
    local songs = data.info
    if not isArray(songs) then
      fail("catalog songs must be an array")
    end
    local candidates = {}
    for _, song in ipairs(songs) do
      if type(song) ~= "table" then
        fail("catalog song must be an object")
      end
      local hash = optional(song, "hash", "string", "")
      local seconds = optional(song, "duration", "number", 0)
      if hash ~= "" and seconds > 0 and seconds <= 86400 then
        local match = newMatch(
          optional(song, "songname", "string", ""),
          optional(song, "singername", "string", ""),
          "",
          math.floor(seconds) * 1000
        )
        match.sourceId = hash
        addCandidate(candidates, match, raw, 0)
      end
    end
    return choose(candidates)
  end)
end

-- The first downloadable entry of a KuGou lyrics `search` response: { id, accessKey, durationMs }.
function M.pickKugouLyrics(body)
  return guarded(function()
    local candidates = decode(body).candidates
    if candidates == nil then
      return nil
    end
    if not isArray(candidates) then
      fail("lyrics candidates must be an array")
    end
    for _, entry in ipairs(candidates) do
      if type(entry) ~= "table" then
        fail("lyrics candidate must be an object")
      end
      local candidate = {
        id = optional(entry, "id", "string", ""),
        accessKey = optional(entry, "accesskey", "string", ""),
        durationMs = optional(entry, "duration", "number", 0),
      }
      if candidate.id ~= "" and candidate.accessKey ~= "" then
        return candidate
      end
    end
    return nil
  end)
end

return M
