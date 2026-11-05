--!nonstrict
-- The lookup sources: request URLs, throttle slots and the preference between sources whose lyrics are otherwise
-- equal. The chain itself (which source is asked next) lives in service.luau.
--
-- Order: Deezer search (identifies the recording and its ISRC), MusicBrainz when Deezer has no match, then lrcmux,
-- LyricsPlus and LRCLIB, and KuGou then NetEase as a last resort when nobody had synced lyrics.

local catalog = require("./catalog.luau")

local M = {}

M.MUSICBRAINZ = "musicbrainz"
M.DEEZER_SEARCH = "deezer-search"
M.DEEZER_TRACK = "deezer-track"
M.LRCMUX = "lrcmux"
M.LYRICSPLUS = "lyricsplus"
M.LRCLIB = "lrclib"
M.KUGOU_SONG = "kugou-song"
M.KUGOU_SEARCH = "kugou-search"
M.KUGOU_LYRIC = "kugou-lyric"
M.NETEASE_SEARCH = "netease-search"
M.NETEASE_LYRIC = "netease-lyric"

-- Requests to one host share a slot: spacing and backoff apply per slot.
local SLOTS = {
  [M.MUSICBRAINZ] = "musicbrainz",
  [M.DEEZER_SEARCH] = "deezer",
  [M.DEEZER_TRACK] = "deezer",
  [M.LRCMUX] = "lrcmux",
  [M.NETEASE_SEARCH] = "netease",
  [M.NETEASE_LYRIC] = "netease",
  [M.LRCLIB] = "lrclib",
  [M.LYRICSPLUS] = "lyricsplus",
  [M.KUGOU_SONG] = "kugou",
  [M.KUGOU_SEARCH] = "kugou",
  [M.KUGOU_LYRIC] = "kugou",
}

function M.slot(provider)
  return SLOTS[provider]
end

-- MusicBrainz asks clients to stay below one request per second.
function M.spacingMs(provider)
  return if provider == M.MUSICBRAINZ then 1100 else 300
end

local SOURCE_ORDER = {
  [M.LRCMUX] = 0,
  [M.LYRICSPLUS] = 1,
  [M.LRCLIB] = 2,
  [M.KUGOU_LYRIC] = 3,
  [M.NETEASE_LYRIC] = 4,
}

-- Preference between lyrics that are otherwise equal; lower wins.
function M.sourceOrder(provider)
  return SOURCE_ORDER[provider] or 5
end

-- Providers that return lyrics rather than catalog data.
function M.isLyricsSource(provider)
  return SOURCE_ORDER[provider] ~= nil
end

local DISPLAY_NAMES = {
  sidecar = "local .lrc file",
  [M.LRCMUX] = "lrcmux",
  [M.LYRICSPLUS] = "LyricsPlus",
  [M.LRCLIB] = "LRCLIB",
  [M.KUGOU_LYRIC] = "KuGou",
  [M.NETEASE_LYRIC] = "NetEase",
}

-- The name of a lyrics source as shown to users.
function M.displayName(source)
  return DISPLAY_NAMES[source] or source or "?"
end

local function encode(value)
  return noctalia.string.urlEncode(value)
end

-- Seconds rounded half up, as the lyrics APIs expect.
local function seconds(durationMs)
  return math.floor(durationMs / 1000 + 0.5)
end

function M.deezerSearchUrl(query)
  return "https://api.deezer.com/search?limit=25&q=" .. encode(query)
end

function M.deezerTrackUrl(id)
  return string.format("https://api.deezer.com/track/%.0f", id)
end

function M.musicBrainzUrl(rawTrack)
  return "https://musicbrainz.org/ws/2/recording/?fmt=json&limit=25&query=" .. encode(catalog.catalogQuery(rawTrack))
end

function M.lrcmuxUrl(track, isrc)
  local url = "https://api.lrcmux.dev/get?format=json&level=word"
  if isrc ~= "" then
    return url .. "&isrc=" .. encode(isrc)
  end
  url ..= "&title=" .. encode(track.title) .. "&artist=" .. encode(track.artist)
  if track.album ~= "" then
    url ..= "&album=" .. encode(track.album)
  end
  if track.durationMs > 0 then
    url ..= `&duration={seconds(track.durationMs)}`
  end
  return url
end

function M.lyricsPlusUrl(track)
  local url = "https://lyricsplus.binimum.org/v2/lyrics/get?title="
    .. encode(track.title)
    .. "&artist="
    .. encode(track.artist)
  if track.album ~= "" then
    url ..= "&album=" .. encode(track.album)
  end
  if track.durationMs > 0 then
    url ..= `&duration={seconds(track.durationMs)}`
  end
  return url
end

function M.lrclibUrl(query)
  return "https://lrclib.net/api/search?q=" .. encode(query)
end

function M.kugouSongUrl(query)
  return "https://mobileservice.kugou.com/api/v3/search/song?version=9108&plat=0&pagesize=8&showtype=0&keyword="
    .. encode(query)
end

function M.kugouSearchUrl(hash)
  return "https://lyrics.kugou.com/search?ver=1&man=yes&client=pc&hash=" .. encode(hash)
end

function M.kugouLyricUrl(candidate)
  return "https://lyrics.kugou.com/download?ver=1&client=pc&charset=utf8&fmt=lrc&id="
    .. encode(candidate.id)
    .. "&accesskey="
    .. encode(candidate.accessKey)
end

function M.neteaseSearchUrl(query)
  return "https://music.163.com/api/search/get?type=1&limit=10&s=" .. encode(query)
end

function M.neteaseLyricUrl(id)
  return `https://music.163.com/api/song/lyric/v1?id={id}&lv=1&yv=1&tv=-1`
end

-- The ISRC of a Deezer `track/<id>` response for the expected id, uppercased, or nil.
function M.deezerIsrc(body, expectedId)
  local record = noctalia.json.decode(body)
  if type(record) ~= "table" or record.id ~= expectedId or type(record.isrc) ~= "string" then
    return nil
  end
  local isrc = string.upper(record.isrc)
  return if catalog.validIsrc(isrc) then isrc else nil
end

return M
