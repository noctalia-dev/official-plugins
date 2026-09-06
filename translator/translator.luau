--!nonstrict
-- Translator launcher provider.
--
-- Usage from the launcher: `/tr <lang> <text>` - e.g. `/tr es hello world`.
-- If the first word is not a language, the whole query is translated to the
-- configured default target. Press Enter on a result to copy it to the clipboard.
-- Translation uses Google Translate's public `translate_a/single` endpoint or DeepL's `v2/translate` endpoint.

-- Common language aliases → ISO code. Any other 2–3 letter token is passed
-- through to Google as-is, so uncommon languages still work.
local LANGUAGES = {
  ar = { "arabic", "arabe" },
  bg = { "bulgarian", "bulgare" },
  cs = { "czech", "tcheque" },
  da = { "danish", "danois" },
  de = { "german", "allemand", "deutsch" },
  el = { "greek", "grec" },
  en = { "english", "anglais" },
  es = { "spanish", "espagnol", "espanol" },
  et = { "estonian", "estonien" },
  fa = { "persian", "farsi", "persan" },
  fi = { "finnish", "finnois" },
  fr = { "french", "francais" },
  he = { "hebrew", "hebreu" },
  hi = { "hindi" },
  hu = { "hungarian", "hongrois" },
  id = { "indonesian", "indonesien" },
  it = { "italian", "italien" },
  ja = { "japanese", "japonais" },
  ko = { "korean", "coreen" },
  lt = { "lithuanian", "lituanien" },
  lv = { "latvian", "letton" },
  nl = { "dutch", "neerlandais" },
  no = { "norwegian", "norvegien" },
  pl = { "polish", "polonais" },
  pt = { "portuguese", "portugais" },
  ro = { "romanian", "roumain" },
  ru = { "russian", "russe" },
  sk = { "slovak", "slovaque" },
  sl = { "slovenian", "slovène", "slovene" },
  sv = { "swedish", "suedois" },
  th = { "thai", "thailandais" },
  tr = { "turkish", "turc" },
  uk = { "ukrainian", "ukrainien" },
  vi = { "vietnamese", "vietnamien" },
  zh = { "chinese", "chinois", "mandarin" },
}

-- target|text -> translation; pending guards against duplicate in-flight fetches.
local cache = {}
local pending = {}

-- Resolve a token to a language code: a known alias, or a bare 2–3 letter code.
local function resolveLang(token)
  local lower = token:lower()
  for code, aliases in LANGUAGES do
    if code == lower or table.find(aliases, lower) then
      return code
    end
  end
  if lower:match("^%a%a%a?$") then
    return lower
  end
  return nil
end

-- Google returns [[[ "segment", "orig", ... ], ...], ...]; the translation is the
-- concatenation of segment[1] across the first array.
local function parseGoogle(body)
  local decoded = noctalia.json.decode(body)
  if type(decoded) ~= "table" or type(decoded[1]) ~= "table" then
    return nil
  end
  local parts = {}
  for _, segment in decoded[1] do
    if type(segment) ~= "table" or type(segment[1]) ~= "string" then
      continue
    end
    table.insert(parts, segment[1])
  end
  if #parts == 0 then
    return nil
  end
  return table.concat(parts)
end

local function fetchGoogle(text, target, onDone)
  -- stylua: ignore 
  local url = `https://translate.googleapis.com/translate_a/single?client=dict-chrome-ex&sl=auto&tl={noctalia.string.urlEncode(target)}&dt=t&q={noctalia.string.urlEncode(text)}`
  noctalia.http({ url = url }, function(res)
    if not res.ok or (res.status and res.status >= 400) then
      local errorMsg = "Translation error"

      if res.status == 400 then
        errorMsg = "Invalid target language code"
      elseif res.status == 429 then
        errorMsg = "Rate limit exceeded: Please slow down"
      end

      onDone(nil, errorMsg)
      return
    end
    local translated = parseGoogle(res.body)
    if translated then
      onDone(translated, nil)
    else
      onDone(nil, "Translation error")
    end
  end)
end

local function fetchDeepL(text, target, onDone)
  local apiKey = noctalia.getConfig("deepl_api_key")

  -- validate API key
  if type(apiKey) ~= "string" or noctalia.string.trim(apiKey) == "" then
    onDone(nil, "DeepL API Key is not present")
    return
  end

  local url = "https://api.deepl.com/v2/translate"
  if apiKey:match(":fx$") then
    url = "https://api-free.deepl.com/v2/translate"
  end

  local headers = {
    "Authorization: DeepL-Auth-Key " .. apiKey,
    "Content-Type: application/json",
  }

  local targetLang = string.upper(target)

  -- DeepL uses NB for Norwegian Bokmål, and doesn't support NO
  if targetLang == "NO" then
    targetLang = "NB"
  end

  local body = noctalia.json.encode({
    text = { text },
    target_lang = targetLang,
  })

  noctalia.http({ method = "POST", url = url, headers = headers, body = body }, function(res)
    if not res.ok or (res.status and res.status >= 400) then
      local errorMsg = "Translation error"

      if res.status == 400 then
        errorMsg = "Invalid target language code"
      elseif res.status == 403 then
        errorMsg = "Authorization failed: Invalid DeepL API key"
      elseif res.status == 429 then
        errorMsg = "Rate limit exceeded: Please slow down"
      elseif res.status == 456 then
        errorMsg = "Quota exceeded: DeepL limit reached"
      end

      onDone(nil, errorMsg)
      return
    end

    local decoded = noctalia.json.decode(res.body)
    if decoded and decoded.translations and type(decoded.translations[1]) == "table" then
      onDone(decoded.translations[1].text, nil)
    else
      onDone(nil, "Translation error")
    end
  end)
end

local function hintRow(title, subtitle, glyph)
  return { id = title, title = title, subtitle = subtitle, glyph = glyph }
end

local function resultRow(translated, target)
  return {
    id = translated,
    title = translated,
    subtitle = `Translation ({target}) - press Enter to copy`,
    glyph = "language",
    presentation = "detail",
  }
end

function onQuery(query)
  local defaultTarget = noctalia.getConfig("target_lang")
  defaultTarget = if type(defaultTarget) == "string" and defaultTarget ~= "" then defaultTarget else "en"

  local text = noctalia.string.trim(query)
  if text == "" then
    launcher.setResults(query, { hintRow("Translate text", "Type: <lang> <text> - e.g. es hello", "language") })
    return
  end

  local first, rest = text:match("^(%S+)%s+([%s%S]*)$")
  local target, content
  if first then
    local code = resolveLang(first)
    if code then
      target = code
      content = rest
    else
      target = defaultTarget
      content = text
    end
  else
    if resolveLang(text) then
      launcher.setResults(query, { hintRow("Type text to translate", `Target language: {text}`, "language") })
      return
    end
    target = defaultTarget
    content = text
  end

  if noctalia.string.trim(content) == "" then
    launcher.setResults(query, { hintRow("Type text to translate", `Target language: {target}`, "language") })
    return
  end

  local provider = noctalia.getConfig("provider") or "google"
  local fetchProvider = fetchGoogle
  if provider == "deepl" then
    fetchProvider = fetchDeepL
  end

  -- helper func: isFallback -> tells if this is an auto retry attempt or not
  local function requestTranslation(reqTarget, reqContent, isFallback)
    local reqKey = `{provider}|{reqTarget}|{reqContent}`

    if cache[reqKey] then
      launcher.setResults(query, { resultRow(cache[reqKey], reqTarget) })
      return
    end

    launcher.setResults(query, { hintRow("Translating…", reqContent, "loader") })

    if pending[reqKey] then
      return
    end

    pending[reqKey] = true

    fetchProvider(reqContent, reqTarget, function(translated, err)
      pending[reqKey] = nil

      if not translated and err == "Invalid target language code" and not isFallback then
        -- if the request failed, try it once more, using the enitre input string, with default lang target
        requestTranslation(defaultTarget, text, true)
        return
      end

      if translated then
        cache[reqKey] = translated
        launcher.setResults(query, { resultRow(translated, reqTarget) })
      else
        launcher.setResults(query, { hintRow(err or "Translation error", reqContent, "alert-triangle") })
      end
    end)
  end

  requestTranslation(target, content, false)
end

function onActivate(id)
  if id ~= "" then
    noctalia.copyToClipboard(id, "text/plain")
    noctalia.notify("Translator", "Copied to clipboard")
  end
end
