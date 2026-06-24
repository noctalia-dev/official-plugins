-- Launcher provider for the example plugin.
--
-- Type `/ex` in the launcher. The top level lists categories; pressing Enter on
-- one calls launcher.setQuery() to rewrite the input (e.g. `/ex fruits `) and
-- drill into it WITHOUT closing the launcher. Pressing Enter on a leaf item
-- copies it and lets the launcher close normally.
--
-- launcher.setQuery() takes effect when called from a handler while the launcher
-- is open. Called synchronously from onActivate it keeps the panel open and
-- rewrites the input instead of closing — the basis for autocomplete / drill-in.

local PREFIX = "/ex"

local CATEGORIES = {
  fruits = { "Apple", "Apricot", "Banana", "Cherry" },
  animals = { "Aardvark", "Bear", "Cat", "Dolphin" },
  colors = { "Amber", "Azure", "Crimson", "Teal" },
}

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Top level: one row per category. Activating a row drills into it.
local function categoryRows()
  local rows = {}
  for name in CATEGORIES do
    table.insert(rows, {
      id = "category:" .. name,
      title = name,
      subtitle = "Browse " .. name .. " — press Enter to open",
      glyph = "folder",
    })
  end
  return rows
end

-- Inside a category: the items matching the text typed after the category name.
local function itemRows(category, filter)
  local rows = {}
  for _, item in CATEGORIES[category] do
    if filter == "" or item:lower():find(filter:lower(), 1, true) then
      table.insert(rows, {
        id = item,
        title = item,
        subtitle = category .. " — press Enter to copy",
        glyph = "tag",
      })
    end
  end
  if #rows == 0 then
    rows[1] = { id = "", title = "No matches", subtitle = category, glyph = "mood-empty" }
  end
  return rows
end

-- `query` is the launcher text after the `/ex` prefix, leading space trimmed.
function onQuery(query)
  local text = trim(query)
  local category, rest = text:match("^(%S+)%s*(.*)$")
  if category and CATEGORIES[category] then
    launcher.setResults(query, itemRows(category, trim(rest)))
  else
    launcher.setResults(query, categoryRows())
  end
end

function onActivate(id)
  local category = id:match("^category:(.+)$")
  if category then
    -- Drill in: rewrite the launcher input (note the prefix and trailing space)
    -- and stay open so the user can keep filtering within the category.
    launcher.setQuery(PREFIX .. " " .. category .. " ")
    return
  end
  if id ~= "" then
    noctalia.copyToClipboard(id, "text/plain")
    noctalia.notify("Example", id .. " copied to clipboard")
  end
end
