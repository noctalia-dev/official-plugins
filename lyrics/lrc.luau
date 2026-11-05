--!nonstrict
-- Lyrics parsing: LRC files and the responses of the lyrics providers.
--
-- Parsers return a result { status, lines, plain, instrumental, recordingDurationMs } where status is "ready",
-- "not_found" or "error", `lines` are synced lines sorted by time
-- ({ timeMs, endMs?, text, words = { { first, last, startMs, endMs } } } with 1-based inclusive byte indices into
-- text), `plain` the unsynced text and recordingDurationMs the length of the recording the timing was made for
-- (0 when the source does not say).

local catalog = require("./catalog.luau")
local text = require("./text.luau")

local M = {}

local KUGOU_INSTRUMENTAL = "纯音乐"
-- Lengths further apart than this belong to different recordings.
local SAME_TIMING_LENGTH_GAP_MS = 2000

function M.newResult(status)
  return { status = status or "not_found", lines = {}, plain = {}, instrumental = false, recordingDurationMs = 0 }
end

-- Response validation raises through these; parsers turn the raised failure into an "error" result.
local function fail(message)
  error({ message = message }, 0)
end

local function isArray(value)
  return type(value) == "table" and (value[1] ~= nil or next(value) == nil)
end

local function isInteger(value)
  return type(value) == "number" and value == math.floor(value)
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

-- Runs a parser body; validation failures become an "error" result.
local function guarded(fn, ...)
  local ok, result = pcall(fn, ...)
  if ok then
    return result
  end
  if type(result) ~= "table" or result.message == nil then
    noctalia.log(`lyrics: parser failed: {result}`)
  end
  return M.newResult("error")
end

-- Sorts lines by time, keeping the file order of equal times.
local function sortLines(lines)
  for i, line in ipairs(lines) do
    line._order = i
  end
  table.sort(lines, function(a, b)
    if a.timeMs ~= b.timeMs then
      return a.timeMs < b.timeMs
    end
    return a._order < b._order
  end)
  for _, line in ipairs(lines) do
    line._order = nil
  end
end

-- A whole decimal integer, or nil.
local function integer(value)
  if not string.find(value, "^%-?%d+$") or #value > 19 then
    return nil
  end
  return tonumber(value)
end

-- `mm:ss`, `mm:ss.f`, `mm:ss.ff` or `mm:ss.fff` in milliseconds.
local function timestamp(value)
  if not string.find(value, "^[%d:%.]*$") then
    return nil
  end
  local colon = string.find(value, ":", 1, true)
  if colon == nil then
    return nil
  end
  local minutes = integer(string.sub(value, 1, colon - 1))
  local rest = string.sub(value, colon + 1)
  local dot = string.find(rest, ".", 1, true)
  local seconds = integer(if dot then string.sub(rest, 1, dot - 1) else rest)
  if minutes == nil or seconds == nil or minutes < 0 or minutes > 1440 or seconds < 0 or seconds >= 60 then
    return nil
  end
  local fraction = 0
  if dot ~= nil then
    local digits = string.sub(rest, dot + 1)
    if #digits == 0 or #digits > 3 then
      return nil
    end
    local parsed = integer(digits)
    if parsed == nil or parsed < 0 then
      return nil
    end
    fraction = parsed * (if #digits == 1 then 100 elseif #digits == 2 then 10 else 1)
  end
  return minutes * 60000 + seconds * 1000 + fraction
end
M.timestamp = timestamp

-- Lines of `body` without a UTF-8 BOM or CR line endings.
function M.splitLines(body)
  local lines = {}
  if string.sub(body, 1, 3) == "\xEF\xBB\xBF" then
    body = string.sub(body, 4)
  end
  local length = #body
  local pos = 1
  while pos <= length do
    local finish = string.find(body, "\n", pos, true)
    local line = string.sub(body, pos, if finish then finish - 1 else length)
    if string.byte(line, -1) == 13 then
      line = string.sub(line, 1, -2)
    end
    table.insert(lines, line)
    if finish == nil then
      break
    end
    pos = finish + 1
  end
  return lines
end

-- Timed lines of an LRC file; repeated time tags yield one line each and `[offset:]` shifts every line.
function M.parseLrc(body)
  local lines = {}
  local offsetMs = 0
  for _, raw in ipairs(M.splitLines(body)) do
    if string.sub(raw, 1, 8) == "[offset:" and string.sub(raw, -1) == "]" then
      local value = string.sub(raw, 9, -2)
      if string.sub(value, 1, 1) == "+" then
        value = string.sub(value, 2)
      end
      local offset = integer(value)
      if offset ~= nil and offset >= -86400000 and offset <= 86400000 then
        offsetMs = offset
      end
    else
      local times = {}
      local pos = 1
      while string.byte(raw, pos) == 91 do -- [
        local close = string.find(raw, "]", pos, true)
        if close == nil then
          break
        end
        local time = timestamp(string.sub(raw, pos + 1, close - 1))
        if time == nil then
          break
        end
        table.insert(times, time)
        pos = close + 1
      end
      if #times > 0 then
        local lyric = string.match(raw, "^[ \t]*(.*)$", pos)
        for _, time in ipairs(times) do
          table.insert(lines, { timeMs = time, text = lyric, words = {} })
        end
      end
    end
  end
  -- Positive LRC offsets advance the lyrics relative to the audio.
  if offsetMs ~= 0 then
    for _, line in ipairs(lines) do
      line.timeMs -= offsetMs
    end
  end
  sortLines(lines)
  return lines
end

-- Whether two lyric files share their opening lines at the same times.
local function sameTiming(a, b)
  local count = math.min(#a, #b, 8)
  if count < 4 then
    return false
  end
  for i = 1, count do
    if math.abs(a[i].timeMs - b[i].timeMs) > 50 or text.matchKey(a[i].text) ~= text.matchKey(b[i].text) then
      return false
    end
  end
  return true
end

-- KuGou escapes its LRC bodies as HTML, e.g. "I&apos;m".
local ENTITIES = {
  ["&apos;"] = "'",
  ["&#39;"] = "'",
  ["&quot;"] = '"',
  ["&lt;"] = "<",
  ["&gt;"] = ">",
  ["&amp;"] = "&",
}

local function htmlUnescape(value)
  return (string.gsub(value, "&#?%w+;", ENTITIES))
end

local BASE64 = {}
do
  local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  for i = 1, #alphabet do
    BASE64[string.byte(alphabet, i)] = i - 1
  end
end

-- Lenient base64 decoding: characters outside the alphabet are skipped, padding ends the data.
local function base64Decode(value)
  local out = buffer.create(#value * 3 // 4 + 3)
  local size = 0
  local accumulator, bits = 0, 0
  for i = 1, #value do
    local byte = string.byte(value, i)
    if byte == 61 then -- =
      break
    end
    local digit = BASE64[byte]
    if digit ~= nil then
      accumulator = bit32.bor(bit32.lshift(bit32.band(accumulator, 0xFFFF), 6), digit)
      bits += 6
      if bits >= 8 then
        bits -= 8
        buffer.writeu8(out, size, bit32.band(bit32.rshift(accumulator, bits), 0xFF))
        size += 1
      end
    end
  end
  return buffer.readstring(out, 0, size)
end

-- The "title - artist" row and "role：name" credits KuGou puts before the lyrics.
local function kugouHeaderLine(value, first)
  return string.find(value, ":", 1, true) ~= nil
    or string.find(value, "：", 1, true) ~= nil
    or (first and string.find(value, " - ", 1, true) ~= nil)
end

-- Credit rows such as "作词 : Name" that NetEase stores as ordinary lyric lines.
local CREDIT_LABELS = {
  "作词",
  "作曲",
  "编曲",
  "制作人",
  "制作",
  "混音",
  "母带",
  "监制",
  "录音",
  "Lyrics by",
  "Composed by",
  "Produced by",
  "Written by",
  "Composer",
  "Producer",
  "Arranger",
  "Lyricist",
}

local function creditLine(value)
  for _, label in ipairs(CREDIT_LABELS) do
    if string.sub(value, 1, #label) == label then
      local rest = string.match(value, "^ *(.*)$", #label + 1)
      if string.sub(rest, 1, 1) == ":" or string.sub(rest, 1, 3) == "：" then
        return true
      end
    end
  end
  return false
end

-- `(start,duration,flag)` at `pos`: returns start, duration and the position after the tag, or nil.
local function yrcTag(raw, pos)
  if string.byte(raw, pos) ~= 40 then -- (
    return nil
  end
  local close = string.find(raw, ")", pos, true)
  if close == nil then
    return nil
  end
  local a, b, c = string.match(string.sub(raw, pos + 1, close - 1), "^([^,]*),([^,]*),(.*)$")
  if a == nil then
    return nil
  end
  local start, duration = integer(a), integer(b)
  if start == nil or duration == nil or integer(c) == nil then
    return nil
  end
  return start, duration, close + 1
end

-- `[start,duration](start,duration,0)word(start,duration,0)word`
local function parseYrcLine(raw)
  if string.byte(raw, 1) ~= 91 then -- [
    return nil
  end
  local close = string.find(raw, "]", 1, true)
  local comma = string.find(raw, ",", 1, true)
  if close == nil or comma == nil or comma > close then
    return nil
  end
  local start = integer(string.sub(raw, 2, comma - 1))
  local duration = integer(string.sub(raw, comma + 1, close - 1))
  if start == nil or duration == nil or start < 0 or duration < 0 then
    return nil
  end
  local line = { timeMs = start, text = "", words = {} }
  if duration > 0 then
    line.endMs = start + duration
  end
  local pieces = {}
  local size = 0
  local pos = close + 1
  local length = #raw
  while pos <= length do
    local tagStart, tagDuration, after = yrcTag(raw, pos)
    if tagStart == nil or tagStart < 0 or tagDuration < 0 then
      return nil
    end
    -- The segment runs to the next "(" that opens a valid tag; other parentheses are lyric text.
    local finish = after
    while true do
      local paren = string.find(raw, "(", finish, true)
      if paren == nil then
        finish = length + 1
        break
      end
      if yrcTag(raw, paren) ~= nil then
        finish = paren
        break
      end
      finish = paren + 1
    end
    local segment = string.sub(raw, after, finish - 1)
    pos = finish
    local begin = size
    table.insert(pieces, segment)
    size += #segment
    local first = string.find(segment, "[^ \t]")
    if first ~= nil then
      local last = #string.match(segment, "^(.-)[ \t]*$")
      local previous = line.words[#line.words]
      if previous ~= nil and tagStart < previous.startMs then
        return nil
      end
      table.insert(line.words, {
        first = begin + first,
        last = begin + last,
        startMs = tagStart,
        endMs = tagStart + tagDuration,
      })
    end
  end
  if #line.words == 0 then
    return nil
  end
  line.text = table.concat(pieces)
  return line
end

-- LRCLIB `api/search` response: the candidate that best fits the track, preferring synced lyrics.
function M.parseLrclibSearch(body, track)
  return guarded(function()
    local result = M.newResult()
    if not string.find(body, "^%s*%[") then
      fail("search response must be an array")
    end
    local candidates = decode(body)
    local album = text.matchKey(track.album or "")
    local bestScore = nil
    local parsedSynced = {}
    for index, candidate in ipairs(candidates) do
      local duration = field(candidate, "duration", "number")
      local match = nil
      if duration >= 0 and duration <= 86400 then
        match = catalog.scoreTrack(track, {
          title = field(candidate, "trackName", "string"),
          artist = field(candidate, "artistName", "string"),
          durationMs = math.floor(duration * 1000 + 0.5),
        })
      end
      if match ~= nil then
        local instrumental = field(candidate, "instrumental", "boolean")
        local lines = {}
        local plain = {}
        if type(candidate.syncedLyrics) == "string" then
          lines = M.parseLrc(candidate.syncedLyrics)
          parsedSynced[index] = lines
        end
        if type(candidate.plainLyrics) == "string" then
          plain = M.splitLines(candidate.plainLyrics)
        end
        local quality = if #lines > 0 then 2 elseif #plain > 0 then 1 else 0
        if quality > 0 or instrumental then
          local sameAlbum = album ~= "" and text.matchKey(field(candidate, "albumName", "string")) == album
          local score = {
            match.durationConfidence,
            quality,
            match.titleConfidence,
            if sameAlbum then 1 else 0,
            -match.durationDifferenceMs,
          }
          local better = bestScore == nil
          if not better then
            for i = 1, #score do
              if score[i] ~= bestScore[i] then
                better = score[i] > bestScore[i]
                break
              end
            end
          end
          if better then
            bestScore = score
            result.status = "ready"
            result.lines = lines
            result.plain = plain
            result.instrumental = instrumental
            result.recordingDurationMs = math.floor(duration * 1000 + 0.5)
          end
        end
      end
    end
    -- Identical timing cannot fit two recordings of different lengths, so such a length claim is not trusted.
    if #result.lines > 0 then
      for index, candidate in ipairs(candidates) do
        if type(candidate.syncedLyrics) == "string" and type(candidate.duration) == "number" then
          local otherMs = math.floor(candidate.duration * 1000 + 0.5)
          if otherMs > 0 and math.abs(otherMs - result.recordingDurationMs) > SAME_TIMING_LENGTH_GAP_MS then
            local other = parsedSynced[index] or M.parseLrc(candidate.syncedLyrics)
            if sameTiming(result.lines, other) then
              result.recordingDurationMs = 0
              break
            end
          end
        end
      end
    end
    return result
  end)
end

-- lrcmux `get` response, accepted only for the expected ISRC (or, without one, a record matching the track).
function M.parseLrcmux(body, track, expectedIsrc)
  return guarded(function()
    local result = M.newResult()
    local json = decode(body)
    local recording = field(json, "track", "table")
    local sameRecording
    if expectedIsrc == "" then
      local duration = field(recording, "duration", "number")
      sameRecording = duration >= 0
        and duration <= 86400
        and catalog.scoreTrack(track, {
            title = field(recording, "title", "string"),
            artist = field(recording, "artist", "string"),
            durationMs = math.floor(duration * 1000 + 0.5),
          })
          ~= nil
    else
      sameRecording = field(recording, "isrc", "string") == expectedIsrc
    end
    if not sameRecording then
      return result
    end
    if type(recording.duration) == "number" then
      result.recordingDurationMs = math.floor(math.clamp(recording.duration, 0, 86400) * 1000 + 0.5)
    end
    local level = field(field(json, "meta", "table"), "level", "string")
    if level ~= "none" and level ~= "line" and level ~= "word" then
      return M.newResult("error")
    end
    for _, item in ipairs(field(json, "lines", "table")) do
      local lyric = field(item, "text", "string")
      table.insert(result.plain, lyric)
      if level ~= "none" then
        local line = { timeMs = optional(item, "start", "number", 0), text = lyric, words = {} }
        if line.timeMs < 0 then
          return M.newResult("error")
        end
        if isInteger(item["end"]) and item["end"] > line.timeMs then
          line.endMs = item["end"]
        end
        if isArray(item.words) then
          local offset = 1
          for _, word in ipairs(item.words) do
            local token = field(word, "text", "string")
            local first = if token ~= "" then string.find(lyric, token, offset, true) else nil
            local startMs = field(word, "start", "number")
            local endMs = field(word, "end", "number")
            local previous = line.words[#line.words]
            if
              first == nil
              or startMs < line.timeMs
              or endMs < startMs
              or (previous ~= nil and startMs < previous.startMs)
            then
              return M.newResult("error")
            end
            offset = first + #token
            table.insert(line.words, { first = first, last = offset - 1, startMs = startMs, endMs = endMs })
          end
        end
        table.insert(result.lines, line)
      end
    end
    sortLines(result.lines)
    if #result.lines > 0 or #result.plain > 0 then
      result.status = "ready"
    end
    return result
  end)
end

-- NetEase `song/lyric/v1` response: word-timed `yrc` when present, otherwise timed or plain `lrc`.
function M.parseNetease(body)
  return guarded(function()
    local result = M.newResult()
    local json = decode(body)
    if field(json, "code", "number") ~= 200 then
      return M.newResult("error")
    end
    if json.pureMusic == true then
      result.instrumental = true
      result.status = "ready"
      return result
    end
    local function group(name)
      local value = json[name]
      if type(value) == "table" and type(value.lyric) == "string" then
        return value.lyric
      end
      return ""
    end
    local lines = {}
    local wordTimed = true
    for _, raw in ipairs(M.splitLines(group("yrc"))) do
      if raw ~= "" and string.sub(raw, 1, 1) ~= "{" then
        local line = parseYrcLine(raw)
        if line == nil then
          wordTimed = false
          break
        end
        if not creditLine(line.text) then
          table.insert(lines, line)
        end
      end
    end
    local plain = group("lrc")
    if not wordTimed or #lines == 0 then
      lines = {}
      for _, line in ipairs(M.parseLrc(plain)) do
        if not creditLine(line.text) then
          table.insert(lines, line)
        end
      end
    end
    sortLines(lines)
    for _, line in ipairs(lines) do
      table.insert(result.plain, line.text)
    end
    if #lines == 0 then
      for _, lyric in ipairs(M.splitLines(plain)) do
        if lyric ~= "" and not creditLine(lyric) then
          table.insert(result.plain, lyric)
        end
      end
    end
    result.lines = lines
    if #result.lines > 0 or #result.plain > 0 then
      result.status = "ready"
    end
    return result
  end)
end

-- LyricsPlus `v2/lyrics/get` response, accepted only when its metadata names the same track.
function M.parseLyricsPlus(body, track)
  return guarded(function()
    local result = M.newResult()
    local json = decode(body)
    local items = json.lyrics
    if not isArray(items) or #items == 0 then
      return result
    end
    local metadata = field(json, "metadata", "table")
    if type(metadata.totalDuration) == "string" then
      result.recordingDurationMs = timestamp(metadata.totalDuration) or 0
    end
    local found = {
      title = optional(metadata, "title", "string", ""),
      artist = optional(metadata, "artist", "string", ""),
      durationMs = result.recordingDurationMs,
    }
    if catalog.scoreTrack(track, found) == nil then
      return result
    end
    local kind = optional(json, "type", "string", "")
    local timed = kind == "Word" or kind == "Line"
    for _, item in ipairs(items) do
      local line = { timeMs = 0, text = "", words = {} }
      local syllables = item.syllabus
      if kind == "Word" and isArray(syllables) and #syllables > 0 then
        local pieces = {}
        local size = 0
        for _, syllable in ipairs(syllables) do
          if syllable.isBackground ~= true and isInteger(field(syllable, "time", "number")) then
            local piece = field(syllable, "text", "string")
            local start = syllable.time
            local finish = start + math.max(0, optional(syllable, "duration", "number", 0))
            local begin = size
            table.insert(pieces, piece)
            size += #piece
            local first = string.find(piece, "[^ \t]")
            local previous = line.words[#line.words]
            if first ~= nil and start >= 0 and not (previous ~= nil and start < previous.startMs) then
              local last = #string.match(piece, "^(.-)[ \t]*$")
              table.insert(line.words, { first = begin + first, last = begin + last, startMs = start, endMs = finish })
            end
          end
        end
        line.text = string.match(table.concat(pieces), "^(.-) *$")
      else
        line.text = optional(item, "text", "string", "")
      end
      table.insert(result.plain, line.text)
      local time = item.time
      if timed and isInteger(time) and time >= 0 then
        line.timeMs = time
        local duration = optional(item, "duration", "number", 0)
        if duration > 0 then
          line.endMs = line.timeMs + duration
        end
        if #line.words > 0 and line.words[1].startMs < line.timeMs then
          line.timeMs = line.words[1].startMs
        end
        table.insert(result.lines, line)
      end
    end
    sortLines(result.lines)
    if #result.lines > 0 or #result.plain > 0 then
      result.status = "ready"
    end
    return result
  end)
end

-- KuGou `download?fmt=lrc` response: base64 LRC with a "title - artist" row and credits before the lyrics.
function M.parseKugou(body)
  return guarded(function()
    local result = M.newResult()
    local content = decode(body).content
    if type(content) ~= "string" or content == "" then
      return result
    end
    local lines = M.parseLrc(htmlUnescape(base64Decode(content)))
    if #lines == 1 and string.find(lines[1].text, KUGOU_INSTRUMENTAL, 1, true) then
      result.instrumental = true
      result.status = "ready"
      return result
    end
    local header = 0
    while header < #lines and kugouHeaderLine(lines[header + 1].text, header == 0) do
      header += 1
    end
    for i = header + 1, #lines do
      table.insert(result.lines, lines[i])
      table.insert(result.plain, lines[i].text)
    end
    if #result.lines > 0 then
      result.status = "ready"
    end
    return result
  end)
end

-- Lyrics stored beside a local audio file: synced when the file has time tags, otherwise its plain lines.
function M.parseSidecar(body)
  local result = M.newResult()
  result.lines = M.parseLrc(body)
  if #result.lines == 0 then
    result.plain = M.splitLines(body)
  end
  if #result.lines > 0 or #result.plain > 0 then
    result.status = "ready"
  end
  return result
end

return M
