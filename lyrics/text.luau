--!nonstrict
-- Text normalization shared by the lyrics matchers: Unicode-aware word splitting that approximates the core's
-- NFKC + casefold + alphanumeric filter without ICU or GLib. Covers Latin, Greek, Cyrillic, Armenian, Hangul and kana
-- composition, fullwidth forms and the usual punctuation blocks; other scripts pass through as word characters.

local M = {}

-- Canonical compositions as "mark: base=composed ..." in hex, generated from Python's unicodedata for Latin, Greek,
-- Cyrillic and kana, so decomposed metadata (e.g. "Cafe" + U+0301) matches its composed form.
local COMPOSITIONS = [[
300: 41=c0 45=c8 49=cc 4f=d2 55=d9 61=e0 65=e8 69=ec 6f=f2 75=f9 dc=1db fc=1dc 4e=1f8 6e=1f9 415=400 418=40d
435=450 438=45d 112=1e14 113=1e15 14c=1e50 14d=1e51 57=1e80 77=1e81 c2=1ea6 e2=1ea7 102=1eb0 103=1eb1 ca=1ec0
ea=1ec1 d4=1ed2 f4=1ed3 1a0=1edc 1a1=1edd 1af=1eea 1b0=1eeb 59=1ef2 79=1ef3
301: 41=c1 45=c9 49=cd 4f=d3 55=da 59=dd 61=e1 65=e9 69=ed 6f=f3 75=fa 79=fd 43=106 63=107 4c=139 6c=13a 4e=143
6e=144 52=154 72=155 53=15a 73=15b 5a=179 7a=17a dc=1d7 fc=1d8 47=1f4 67=1f5 c5=1fa e5=1fb c6=1fc e6=1fd d8=1fe
f8=1ff a8=385 391=386 395=388 397=389 399=38a 39f=38c 3a5=38e 3a9=38f 3ca=390 3b1=3ac 3b5=3ad 3b7=3ae 3b9=3af
3cb=3b0 3bf=3cc 3c5=3cd 3c9=3ce 3d2=3d3 413=403 41a=40c 433=453 43a=45c c7=1e08 e7=1e09 112=1e16 113=1e17 cf=1e2e
ef=1e2f 4b=1e30 6b=1e31 4d=1e3e 6d=1e3f d5=1e4c f5=1e4d 14c=1e52 14d=1e53 50=1e54 70=1e55 168=1e78 169=1e79
57=1e82 77=1e83 c2=1ea4 e2=1ea5 102=1eae 103=1eaf ca=1ebe ea=1ebf d4=1ed0 f4=1ed1 1a0=1eda 1a1=1edb 1af=1ee8
1b0=1ee9
302: 41=c2 45=ca 49=ce 4f=d4 55=db 61=e2 65=ea 69=ee 6f=f4 75=fb 43=108 63=109 47=11c 67=11d 48=124 68=125 4a=134
6a=135 53=15c 73=15d 57=174 77=175 59=176 79=177 5a=1e90 7a=1e91 1ea0=1eac 1ea1=1ead 1eb8=1ec6 1eb9=1ec7 1ecc=1ed8
1ecd=1ed9
303: 41=c3 4e=d1 4f=d5 61=e3 6e=f1 6f=f5 49=128 69=129 55=168 75=169 56=1e7c 76=1e7d c2=1eaa e2=1eab 102=1eb4
103=1eb5 45=1ebc 65=1ebd ca=1ec4 ea=1ec5 d4=1ed6 f4=1ed7 1a0=1ee0 1a1=1ee1 1af=1eee 1b0=1eef 59=1ef8 79=1ef9
304: 41=100 61=101 45=112 65=113 49=12a 69=12b 4f=14c 6f=14d 55=16a 75=16b dc=1d5 fc=1d6 c4=1de e4=1df 226=1e0
227=1e1 c6=1e2 e6=1e3 1ea=1ec 1eb=1ed d6=22a f6=22b d5=22c f5=22d 22e=230 22f=231 59=232 79=233 418=4e2 438=4e3
423=4ee 443=4ef 47=1e20 67=1e21 1e36=1e38 1e37=1e39 1e5a=1e5c 1e5b=1e5d
306: 41=102 61=103 45=114 65=115 47=11e 67=11f 49=12c 69=12d 4f=14e 6f=14f 55=16c 75=16d 423=40e 418=419 438=439
443=45e 416=4c1 436=4c2 410=4d0 430=4d1 415=4d6 435=4d7 228=1e1c 229=1e1d 1ea0=1eb6 1ea1=1eb7
307: 43=10a 63=10b 45=116 65=117 47=120 67=121 49=130 5a=17b 7a=17c 41=226 61=227 4f=22e 6f=22f 42=1e02 62=1e03
44=1e0a 64=1e0b 46=1e1e 66=1e1f 48=1e22 68=1e23 4d=1e40 6d=1e41 4e=1e44 6e=1e45 50=1e56 70=1e57 52=1e58 72=1e59
53=1e60 73=1e61 15a=1e64 15b=1e65 160=1e66 161=1e67 1e62=1e68 1e63=1e69 54=1e6a 74=1e6b 57=1e86 77=1e87 58=1e8a
78=1e8b 59=1e8e 79=1e8f 17f=1e9b
308: 41=c4 45=cb 49=cf 4f=d6 55=dc 61=e4 65=eb 69=ef 6f=f6 75=fc 79=ff 59=178 399=3aa 3a5=3ab 3b9=3ca 3c5=3cb
3d2=3d4 415=401 406=407 435=451 456=457 410=4d2 430=4d3 4d8=4da 4d9=4db 416=4dc 436=4dd 417=4de 437=4df 418=4e4
438=4e5 41e=4e6 43e=4e7 4e8=4ea 4e9=4eb 42d=4ec 44d=4ed 423=4f0 443=4f1 427=4f4 447=4f5 42b=4f8 44b=4f9 48=1e26
68=1e27 d5=1e4e f5=1e4f 16a=1e7a 16b=1e7b 57=1e84 77=1e85 58=1e8c 78=1e8d 74=1e97
309: 41=1ea2 61=1ea3 c2=1ea8 e2=1ea9 102=1eb2 103=1eb3 45=1eba 65=1ebb ca=1ec2 ea=1ec3 49=1ec8 69=1ec9 4f=1ece
6f=1ecf d4=1ed4 f4=1ed5 1a0=1ede 1a1=1edf 55=1ee6 75=1ee7 1af=1eec 1b0=1eed 59=1ef6 79=1ef7
30a: 41=c5 61=e5 55=16e 75=16f 77=1e98 79=1e99
30b: 4f=150 6f=151 55=170 75=171 423=4f2 443=4f3
30c: 43=10c 63=10d 44=10e 64=10f 45=11a 65=11b 4c=13d 6c=13e 4e=147 6e=148 52=158 72=159 53=160 73=161 54=164
74=165 5a=17d 7a=17e 41=1cd 61=1ce 49=1cf 69=1d0 4f=1d1 6f=1d2 55=1d3 75=1d4 dc=1d9 fc=1da 47=1e6 67=1e7 4b=1e8
6b=1e9 1b7=1ee 292=1ef 6a=1f0 48=21e 68=21f
30f: 41=200 61=201 45=204 65=205 49=208 69=209 4f=20c 6f=20d 52=210 72=211 55=214 75=215 474=476 475=477
311: 41=202 61=203 45=206 65=207 49=20a 69=20b 4f=20e 6f=20f 52=212 72=213 55=216 75=217
31b: 4f=1a0 6f=1a1 55=1af 75=1b0
323: 42=1e04 62=1e05 44=1e0c 64=1e0d 48=1e24 68=1e25 4b=1e32 6b=1e33 4c=1e36 6c=1e37 4d=1e42 6d=1e43 4e=1e46
6e=1e47 52=1e5a 72=1e5b 53=1e62 73=1e63 54=1e6c 74=1e6d 56=1e7e 76=1e7f 57=1e88 77=1e89 5a=1e92 7a=1e93 41=1ea0
61=1ea1 45=1eb8 65=1eb9 49=1eca 69=1ecb 4f=1ecc 6f=1ecd 1a0=1ee2 1a1=1ee3 55=1ee4 75=1ee5 1af=1ef0 1b0=1ef1
59=1ef4 79=1ef5
324: 55=1e72 75=1e73
325: 41=1e00 61=1e01
326: 53=218 73=219 54=21a 74=21b
327: 43=c7 63=e7 47=122 67=123 4b=136 6b=137 4c=13b 6c=13c 4e=145 6e=146 52=156 72=157 53=15e 73=15f 54=162 74=163
45=228 65=229 44=1e10 64=1e11 48=1e28 68=1e29
328: 41=104 61=105 45=118 65=119 49=12e 69=12f 55=172 75=173 4f=1ea 6f=1eb
32d: 44=1e12 64=1e13 45=1e18 65=1e19 4c=1e3c 6c=1e3d 4e=1e4a 6e=1e4b 54=1e70 74=1e71 55=1e76 75=1e77
32e: 48=1e2a 68=1e2b
330: 45=1e1a 65=1e1b 49=1e2c 69=1e2d 55=1e74 75=1e75
331: 42=1e06 62=1e07 44=1e0e 64=1e0f 4b=1e34 6b=1e35 4c=1e3a 6c=1e3b 4e=1e48 6e=1e49 52=1e5e 72=1e5f 54=1e6e
74=1e6f 5a=1e94 7a=1e95 68=1e96
3099: 304b=304c 304d=304e 304f=3050 3051=3052 3053=3054 3055=3056 3057=3058 3059=305a 305b=305c 305d=305e
305f=3060 3061=3062 3064=3065 3066=3067 3068=3069 306f=3070 3072=3073 3075=3076 3078=3079 307b=307c 3046=3094
309d=309e 30ab=30ac 30ad=30ae 30af=30b0 30b1=30b2 30b3=30b4 30b5=30b6 30b7=30b8 30b9=30ba 30bb=30bc 30bd=30be
30bf=30c0 30c1=30c2 30c4=30c5 30c6=30c7 30c8=30c9 30cf=30d0 30d2=30d3 30d5=30d6 30d8=30d9 30db=30dc 30a6=30f4
30ef=30f7 30f0=30f8 30f1=30f9 30f2=30fa 30fd=30fe
309a: 306f=3071 3072=3074 3075=3077 3078=307a 307b=307d 30cf=30d1 30d2=30d4 30d5=30d7 30d8=30da 30db=30dd
]]

local compose = {}
do
  local mark = nil
  for token in string.gmatch(COMPOSITIONS, "[^%s]+") do
    if string.sub(token, -1) == ":" then
      mark = tonumber(string.sub(token, 1, -2), 16)
    else
      local base, composed = string.match(token, "^(%x+)=(%x+)$")
      compose[tonumber(base, 16) * 0x110000 + mark] = tonumber(composed, 16)
    end
  end
end

-- NFKC compatibility mappings that turn symbols into word characters.
local COMPAT = {
  [0xAA] = "a",
  [0xB2] = "2",
  [0xB3] = "3",
  [0xB9] = "1",
  [0xBA] = "o",
  [0x2122] = "TM",
  [0xFB00] = "ff",
  [0xFB01] = "fi",
  [0xFB02] = "fl",
  [0xFB03] = "ffi",
  [0xFB04] = "ffl",
  [0xFB05] = "st",
  [0xFB06] = "st",
}

local SEPARATORS = {
  [0x2C] = true, -- ,
  [0x26] = true, -- &
  [0x2B] = true, -- +
  [0x2F] = true, -- /
  [0x3B] = true, -- ;
  [0x7C] = true, -- |
  [0x2D] = true, -- -
  [0x2013] = true,
  [0x2014] = true,
  [0x3001] = true,
  [0xFF0C] = true,
}

-- Appends the compatibility-mapped code points of `cp` to `out`.
local function appendCompat(out, cp)
  local mapped = COMPAT[cp]
  if mapped ~= nil then
    for i = 1, #mapped do
      table.insert(out, string.byte(mapped, i))
    end
  elseif cp >= 0xFF01 and cp <= 0xFF5E then
    table.insert(out, cp - 0xFEE0)
  elseif cp == 0x3000 or cp == 0xA0 then
    table.insert(out, 0x20)
  elseif cp >= 0x2080 and cp <= 0x2089 then
    table.insert(out, cp - 0x2080 + 0x30)
  elseif cp == 0x2070 or (cp >= 0x2074 and cp <= 0x2079) then
    table.insert(out, cp - 0x2070 + 0x30)
  else
    table.insert(out, cp)
  end
end

-- Composes `cp` onto the previous code point when Unicode has a precomposed form.
local function composeWith(previous, cp)
  if previous >= 0x1100 and previous <= 0x1112 and cp >= 0x1161 and cp <= 0x1175 then
    return 0xAC00 + ((previous - 0x1100) * 21 + (cp - 0x1161)) * 28
  end
  if previous >= 0xAC00 and previous <= 0xD7A3 and (previous - 0xAC00) % 28 == 0 and cp >= 0x11A8 and cp <= 0x11C2 then
    return previous + (cp - 0x11A7)
  end
  return compose[previous * 0x110000 + cp]
end

-- Simple case folding for the cased scripts; returns a code point, or a string for multi-character folds.
local function foldCase(cp)
  if cp < 0x80 then
    if cp >= 0x41 and cp <= 0x5A then
      return cp + 32
    end
    return cp
  end
  if cp < 0x100 then
    if cp >= 0xC0 and cp <= 0xDE and cp ~= 0xD7 then
      return cp + 32
    elseif cp == 0xB5 then
      return 0x3BC
    elseif cp == 0xDF then
      return "ss"
    end
    return cp
  end
  if cp < 0x180 then
    if cp == 0x130 then
      return "i\u{307}"
    elseif cp == 0x178 then
      return 0xFF
    elseif cp == 0x17F then
      return 0x73
    elseif cp == 0x131 or cp == 0x138 or cp == 0x149 then
      return cp
    elseif (cp >= 0x139 and cp <= 0x148) or (cp >= 0x179 and cp <= 0x17E) then
      return if cp % 2 == 1 then cp + 1 else cp
    end
    return if cp % 2 == 0 then cp + 1 else cp
  end
  if cp < 0x250 then
    if cp == 0x1C4 or cp == 0x1C5 then
      return 0x1C6
    elseif cp == 0x1C7 or cp == 0x1C8 then
      return 0x1C9
    elseif cp == 0x1CA or cp == 0x1CB then
      return 0x1CC
    elseif cp == 0x1F1 or cp == 0x1F2 then
      return 0x1F3
    elseif cp == 0x1F4 then
      return 0x1F5
    elseif cp >= 0x1CD and cp <= 0x1DC then
      return if cp % 2 == 1 then cp + 1 else cp
    elseif
      (cp >= 0x1DE and cp <= 0x1EF)
      or (cp >= 0x1F8 and cp <= 0x21F)
      or (cp >= 0x222 and cp <= 0x233)
      or (cp >= 0x246 and cp <= 0x24F)
    then
      return if cp % 2 == 0 then cp + 1 else cp
    end
    return cp
  end
  if cp >= 0x370 and cp < 0x400 then
    if cp == 0x386 then
      return 0x3AC
    elseif cp >= 0x388 and cp <= 0x38A then
      return cp + 37
    elseif cp == 0x38C then
      return 0x3CC
    elseif cp == 0x38E or cp == 0x38F then
      return cp + 63
    elseif cp >= 0x391 and cp <= 0x3AB and cp ~= 0x3A2 then
      return cp + 32
    elseif cp == 0x3C2 then
      return 0x3C3
    elseif cp >= 0x3D8 and cp <= 0x3EF then
      return if cp % 2 == 0 then cp + 1 else cp
    end
    return cp
  end
  if cp >= 0x400 and cp < 0x530 then
    if cp <= 0x40F then
      return cp + 80
    elseif cp <= 0x42F then
      return cp + 32
    elseif (cp >= 0x460 and cp <= 0x481) or (cp >= 0x48A and cp <= 0x4BF) or cp >= 0x4D0 then
      return if cp % 2 == 0 then cp + 1 else cp
    elseif cp == 0x4C0 then
      return 0x4CF
    elseif cp >= 0x4C1 and cp <= 0x4CE then
      return if cp % 2 == 1 then cp + 1 else cp
    end
    return cp
  end
  if cp >= 0x531 and cp <= 0x556 then
    return cp + 48
  end
  if cp >= 0x1E00 and cp <= 0x1EFF then
    if cp == 0x1E9E then
      return "ss"
    elseif cp <= 0x1E95 or cp >= 0x1EA0 then
      return if cp % 2 == 0 then cp + 1 else cp
    end
    return cp
  end
  return cp
end

-- Whether a folded code point is a letter, digit or mark (the core keeps marks inside words).
local function isWordChar(cp)
  if cp < 0x80 then
    return (cp >= 0x30 and cp <= 0x39) or (cp >= 0x61 and cp <= 0x7A) or (cp >= 0x41 and cp <= 0x5A)
  end
  if cp < 0xC0 then
    return false
  end
  if cp == 0xD7 or cp == 0xF7 then
    return false
  end
  if cp < 0x370 then
    return true
  end
  if cp < 0x2000 then
    return not (
      cp == 0x37E
      or cp == 0x387
      or cp == 0x3F6
      or cp == 0x482
      or (cp >= 0x55A and cp <= 0x55F)
      or cp == 0x589
      or cp == 0x58A
      or cp == 0x5BE
      or cp == 0x5C0
      or cp == 0x5C3
      or cp == 0x5C6
      or cp == 0x5F3
      or cp == 0x5F4
      or (cp >= 0x600 and cp <= 0x60F)
      or cp == 0x61B
      or (cp >= 0x61D and cp <= 0x61F)
      or (cp >= 0x66A and cp <= 0x66D)
      or cp == 0x6D4
      or cp == 0x6DD
      or cp == 0x6DE
      or cp == 0x6E9
      or cp == 0x964
      or cp == 0x965
      or cp == 0x970
      or cp == 0xE3F
      or cp == 0xE4F
      or cp == 0xE5A
      or cp == 0xE5B
      or (cp >= 0x104A and cp <= 0x104F)
      or cp == 0x10FB
      or cp == 0x1680
      or (cp >= 0x16EB and cp <= 0x16ED)
    )
  end
  if cp < 0x2070 then
    return false
  end
  if cp < 0x20A0 then
    return true
  end
  if cp < 0x20D0 then
    return false
  end
  if cp < 0x2100 then
    return true
  end
  if cp < 0x2150 then
    return false
  end
  if cp < 0x2190 then
    return true
  end
  if cp < 0x2460 then
    return false
  end
  if cp < 0x2500 then
    return true
  end
  if cp < 0x2C00 then
    return false
  end
  if cp >= 0x2E00 and cp <= 0x2E7F then
    return false
  end
  if cp >= 0x2FF0 and cp <= 0x3004 then
    return false
  end
  if
    (cp >= 0x3008 and cp <= 0x3020)
    or cp == 0x3030
    or (cp >= 0x303D and cp <= 0x303F)
    or cp == 0x309B
    or cp == 0x309C
    or cp == 0x30A0
    or cp == 0x30FB
  then
    return false
  end
  if cp >= 0xD800 and cp <= 0xF8FF then
    return false
  end
  if
    cp == 0xFD3E
    or cp == 0xFD3F
    or (cp >= 0xFE10 and cp <= 0xFE1F)
    or (cp >= 0xFE30 and cp <= 0xFE6F)
    or cp == 0xFEFF
    or (cp >= 0xFF00 and cp <= 0xFF0F)
    or (cp >= 0xFF1A and cp <= 0xFF20)
    or (cp >= 0xFF3B and cp <= 0xFF40)
    or (cp >= 0xFF5B and cp <= 0xFF65)
    or cp >= 0xFFE0 and cp <= 0xFFFF
  then
    return false
  end
  if (cp >= 0x1D100 and cp <= 0x1D1FF) or (cp >= 0x1F000 and cp <= 0x1FAFF) or cp >= 0xE0000 then
    return false
  end
  return true
end

-- Decoded, compatibility-mapped and composed code points of valid UTF-8, or nil.
local function codepoints(text)
  if utf8.len(text) == nil then
    return nil
  end
  local out = {}
  for _, cp in utf8.codes(text) do
    local before = #out
    appendCompat(out, cp)
    -- Only a single mapped code point can combine with the one before it.
    if #out == before + 1 and before > 0 then
      local composed = composeWith(out[before], out[before + 1])
      if composed ~= nil then
        out[before] = composed
        out[before + 1] = nil
      end
    end
  end
  return out
end

local scanCache = {}
local scanCacheSize = 0

-- Casefolded alphanumeric words of `text`; `separated[i]` marks list punctuation (`,&+/;|` or a dash) before word i.
-- Results are shared and must not be modified.
function M.scan(text)
  local cached = scanCache[text]
  if cached ~= nil then
    return cached
  end
  local words = {}
  local separated = {}
  local result = { words = words, separated = separated }
  local points = if text ~= "" then codepoints(text) else nil
  if points ~= nil then
    local word = {}
    local separator = false
    local function flush()
      if #word > 0 then
        table.insert(words, table.concat(word))
        table.insert(separated, separator)
        table.clear(word)
        separator = false
      end
    end
    for _, cp in ipairs(points) do
      local folded = foldCase(cp)
      if type(folded) == "string" then
        table.insert(word, folded)
      elseif isWordChar(folded) then
        table.insert(word, utf8.char(folded))
      else
        flush()
        if SEPARATORS[folded] then
          separator = true
        end
      end
    end
    flush()
  end
  if scanCacheSize >= 2048 then
    table.clear(scanCache)
    scanCacheSize = 0
  end
  scanCache[text] = result
  scanCacheSize += 1
  return result
end

-- The casefolded words of `text`. Shared; do not modify.
function M.tokens(text)
  return M.scan(text).words
end

-- All words glued together: a spelling- and punctuation-insensitive comparison key.
function M.matchKey(text)
  return table.concat(M.tokens(text))
end

-- Whether `needle` occurs as a contiguous run of words in `haystack`.
function M.contains(haystack, needle)
  local n = #needle
  if n == 0 then
    return false
  end
  for start = 1, #haystack - n + 1 do
    local found = true
    for i = 1, n do
      if haystack[start + i - 1] ~= needle[i] then
        found = false
        break
      end
    end
    if found then
      return true
    end
  end
  return false
end

function M.equal(a, b)
  if #a ~= #b then
    return false
  end
  for i = 1, #a do
    if a[i] ~= b[i] then
      return false
    end
  end
  return true
end

function M.has(list, value)
  return table.find(list, value) ~= nil
end

-- Percent-decodes `text` without treating "+" as a space.
function M.decodeComponent(text)
  return (string.gsub(text, "%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end))
end

return M
