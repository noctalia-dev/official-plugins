-- [[launcher_provider]] entry: launcher commands with prefix ">au".
--   >au            → list all available updates
--   >au refresh    → trigger update check
--   >au update     → run system update
--   >au <text>     → search updates by name

local function send(action)
  noctalia.state.set("command", { action = action })
end

function onQuery(text)
  local trimmed = string.gsub(text, "^%s+", "")
  trimmed = string.gsub(trimmed, "%s+$", "")

  -- Empty query: show help
  if trimmed == "" then
    launcher.setResults(text, {
      {
        id = "header",
        title = noctalia.tr("launcher.commands"),
        subtitle = ">au refresh, >au update, >au <search>",
        glyph = "info-circle",
      },
    })
    return
  end

  -- Command: refresh
  if trimmed == "refresh" then
    send("refresh")
    launcher.setResults(text, {
      { id = "refreshed", title = noctalia.tr("launcher.refreshing"), glyph = "refresh" },
    })
    return
  end

  -- Command: update
  if trimmed == "update" then
    send("update")
    launcher.setResults(text, {
      { id = "updating", title = noctalia.tr("launcher.updating"), glyph = "arrow-big-down-lines" },
    })
    return
  end

  -- Search updates
  local updates = noctalia.state.get("updates") or {}
  local results = {}
  local queryLower = string.lower(trimmed)

  for _, u in ipairs(updates) do
    if string.find(string.lower(u.name), queryLower, 1, true) then
      local sourceGlyph = if u.source == "flatpak" then "package"
        elseif u.source == "aur" then "package"
        else "terminal"

      table.insert(results, {
        id = u.id,
        title = u.name,
        subtitle = u.oldVer .. " -> " .. u.newVer,
        glyph = sourceGlyph,
        badge = u.source:sub(1, 1):upper(),
      })
    end
  end

  if #results == 0 then
    table.insert(results, {
      id = "noresults",
      title = noctalia.tr("launcher.noResults"),
      glyph = "search-off",
    })
  end

  launcher.setResults(text, results)
end

local function openRepo(id, source)
  if source == "aur" then
    noctalia.runAsync("xdg-open 'https://aur.archlinux.org/packages/" .. id .. "'")
  elseif source == "flatpak" then
    noctalia.runAsync("xdg-open 'https://flathub.org/en/apps/" .. id .. "'")
  else
    noctalia.runAsync("LC_ALL=C pacman -Si " .. id .. " 2>/dev/null | awk '/^Repository/ {print $3; exit}'", function(res)
      local repo = res.stdout:match("^%s*(.-)%s*$")
      if repo == "" then repo = "extra" end
      local url
      if repo == "cachyos-znver4" or repo == "cachyos-extra-znver4" or repo == "cachyos-core-znver4" then
        url = "https://packages.cachyos.org/package/" .. repo .. "/x86_64_v4/" .. id
      elseif repo == "extra" then
        url = "https://archlinux.org/packages/extra/x86_64/" .. id
      elseif repo == "core" then
        url = "https://archlinux.org/packages/core/x86_64/" .. id
      elseif repo == "multilib" then
        url = "https://archlinux.org/packages/multilib/x86_64/" .. id
      else
        url = "https://archlinux.org/packages/" .. repo .. "/x86_64/" .. id
      end
      noctalia.runAsync("xdg-open '" .. url .. "'")
    end)
  end
end

function onActivate(id)
  if id == "refreshed" or id == "updating" or id == "header" or id == "noresults" then
    return
  end

  -- Open package page in browser
  local updates = noctalia.state.get("updates") or {}
  for _, u in ipairs(updates) do
    if u.id == id then
      openRepo(u.id, u.source)
      break
    end
  end
end
