-- SPDX-License-Identifier: MIT
local Apply = require("./lib/apply.luau")
local Catalogue = require("./lib/catalogue.luau")
local Config = require("./lib/config.luau")
local Files = require("./lib/files.luau")
local Selection = require("./lib/selection.luau")
local Slots = require("./lib/slots.luau")

local PAGE_SIZE = 8
local tr = noctalia.tr

local dataDir = assert(noctalia.pluginDataDir())
local env = { paths = Config.paths(), selectionPath = dataDir .. "/selection.json" }
local hasUmbriel = noctalia.commandExists("umbriel")

local sel = Selection.load(env.selectionPath)
local cat = Catalogue.readCache(dataDir)
local catState = cat and "ok" or "loading" -- ok | loading | offline | error
local fetching = false
local setupState = "present" -- present | insert | manual
local busy = false
local message, messageIsError = nil, false
local tab = "slots" -- slots | browse | families
local query, slotFilter, page = "", nil, 1
local picking = nil -- { slot = string, app_id = string? } while choosing a shader
local previews = {} -- destination path -> "pending" | "ok" | "failed"
local timingDraft = {} -- slot -> { duration = string, curve = string }, cleared after each commit
local timingError = {} -- slot -> message for a timing draft that did not parse
local draftGeneration = 0 -- bumped after each commit so timing inputs reseed from the saved values

local render

-- Child list without holes: nil/false arguments are skipped.
local function nodes(...)
  local out = {}
  for i = 1, select("#", ...) do
    local node = select(i, ...)
    if node then
      table.insert(out, node)
    end
  end
  return out
end

local function append(out, list)
  for _, node in ipairs(list) do
    table.insert(out, node)
  end
end

-- A small button; `opts` adds variant, enabled, glyph, tooltip, key and so on.
local function button(text, onClick, opts)
  local props = { text = text, onClick = onClick, controlSize = "sm" }
  for key, value in pairs(opts or {}) do
    props[key] = value
  end
  return ui.button(props)
end

local function slotLabel(slot)
  return tr("slot." .. Slots.key(slot))
end

-- Slot names for a ui.select, optionally after a leading `first` choice.
local function slotOptions(first)
  local options = { first }
  for _, slot in ipairs(Slots.list) do
    table.insert(options, slotLabel(slot))
  end
  return options
end

local function say(text, isError)
  message, messageIsError = text, isError == true
end

local function canApply()
  return hasUmbriel and setupState == "present" and not busy
end

local function commitSelection(nxt, okText, onOk)
  if busy then
    return
  end
  busy = true
  say(tr("status.working"))
  render()
  Apply.commit(env, nxt, function(ok, err)
    busy = false
    if ok then
      sel = nxt
      timingDraft, timingError = {}, {}
      draftGeneration += 1
      say(okText or tr("status.applied"))
      if onOk then
        onOk()
      end
    else
      say(tr("status.failed", { error = tostring(err) }), true)
    end
    render()
  end)
end

local function commit(change, okText, onOk)
  commitSelection(Selection.change(sel, change), okText, onOk)
end

local function refreshSetup()
  setupState = Config.includeState(noctalia.readFile(env.paths.config))
end

local function runSetup()
  if busy then
    return
  end
  busy = true
  say(tr("status.working"))
  render()
  Config.setup(env.paths, function(ok, err)
    busy = false
    refreshSetup()
    if ok then
      say(tr("setup.done"))
    else
      say(tr("setup.failed", { error = tostring(err) }), true)
    end
    render()
  end)
end

local function fetchCatalogue()
  if fetching then
    return
  end
  fetching = true
  if not cat then
    catState = "loading"
  end
  Catalogue.fetch(dataDir, function(fresh, err)
    fetching = false
    if fresh then
      if catState == "error" then
        message = nil
      end
      cat, catState = fresh, "ok"
    elseif cat then
      catState = "offline"
    else
      catState = "error"
      say(tr("banner.catalogue_error", { error = tostring(err) }), true)
    end
    render()
  end)
end

local function previewFor(effect)
  local image = cat and not effect.imported and effect.preview and effect.preview.image
  if not image then
    return nil
  end
  local dest = dataDir .. "/previews/" .. cat.revision .. "/" .. image
  if previews[dest] == nil then
    if noctalia.fileExists(dest) then
      previews[dest] = "ok"
    else
      previews[dest] = "pending"
      local synchronous = true
      local job = { url = Files.raw .. cat.revision .. "/" .. image, dest = dest }
      Files.download({ job }, function(failed)
        previews[dest] = failed and "failed" or "ok"
        if not synchronous then
          render()
        end
      end)
      synchronous = false
    end
  end
  return previews[dest] == "ok" and dest or nil
end

local function pick(slot, appId)
  picking = { slot = slot, app_id = appId }
  tab, query, page = "browse", "", 1
  render()
end

local function applyEffect(effect, slot)
  local target = picking
  if target then
    picking, tab, query = nil, "slots", ""
  end
  local entry = Catalogue.resolve(cat, effect, slot, env.paths.shaders)
  if target and target.app_id then
    commit(function(n)
      Selection.setApp(n, target.app_id, slot, entry)
    end)
  else
    commit(function(n)
      n.slots[slot] = entry
    end)
  end
end

local function removeImport(effect)
  commit(
    function(n)
      Selection.removeImport(n, effect.id)
    end,
    tr("status.import_removed"),
    function()
      Files.removeImport(effect)
    end
  )
end

local function applyFamily(family)
  local entries = {}
  for slot, effect in pairs(Catalogue.familySlots(cat, family)) do
    entries[slot] = Catalogue.resolve(cat, effect, slot, env.paths.shaders)
  end
  commit(function(n)
    for slot, entry in pairs(entries) do
      n.slots[slot] = entry
    end
  end, tr("status.family_applied", { name = family.name }))
end

local function card(key, children)
  return ui.column(
    { key = key, gap = 6, padding = 10, radius = 8, fill = "surface_container/0.5" },
    children
  )
end

local function hint(text)
  return ui.label({ text = text, fontSize = 11, color = "on_surface_variant" })
end

local expanded = nil -- slot whose details are open
local openApps = nil -- sorted app IDs of open windows, nil until read

local function loadOpenApps()
  local started = noctalia.runAsync({ "umbriel", "windows", "--json" }, function(result)
    local windows = noctalia.json.decode(result.stdout or "")
    local seen, apps = {}, {}
    for _, window in ipairs(type(windows) == "table" and windows or {}) do
      local app = window.app_id
      if type(app) == "string" and app ~= "" and not seen[app] then
        seen[app] = true
        table.insert(apps, app)
      end
    end
    table.sort(apps)
    openApps = apps
    render()
  end)
  if not started then
    openApps = {}
    render()
  end
end

local function toggleDetails(slot)
  expanded = expanded ~= slot and slot or nil
  if expanded and Slots.appSlots[slot] then
    openApps = nil
    loadOpenApps()
  end
  render()
end

local function applyTiming(slot)
  local draft = timingDraft[slot] or {}
  local timing, err = Selection.parseTiming(draft.duration, draft.curve)
  if not timing then
    timingError[slot] = tr(err)
    render()
    return
  end
  commit(function(n)
    n.timing[slot] = next(timing) and timing or nil
  end, tr("status.timing_saved"))
end

local function timingNodes(slot, entry)
  local draft = timingDraft[slot]
  if not draft then
    local saved = sel.timing[slot] or {}
    draft = {
      duration = saved.duration_ms and tostring(saved.duration_ms) or "",
      curve = saved.curve or "",
    }
    timingDraft[slot] = draft
  end
  local ownDuration = entry.settings[slot .. ".duration_ms"]
  local ownCurve = entry.settings[slot .. ".curve"]
  local function edited(field)
    return function(value)
      draft[field] = value
      if timingError[slot] then
        timingError[slot] = nil
        render()
      end
    end
  end
  return nodes(
    ui.row({ gap = 8, align = "center" }, {
      ui.input({
        key = slot .. ":duration:" .. draftGeneration,
        value = draft.duration,
        placeholder = ownDuration and tr("timing.duration_own", { value = tostring(ownDuration) })
          or tr("timing.duration"),
        controlSize = "sm",
        width = 190,
        onChange = edited("duration"),
      }),
      ui.input({
        key = slot .. ":curve:" .. draftGeneration,
        value = draft.curve,
        placeholder = ownCurve and tr("timing.curve_own", { value = tostring(ownCurve) })
          or tr("timing.curve"),
        controlSize = "sm",
        flexGrow = 1,
        onChange = edited("curve"),
      }),
      button(tr("timing.apply"), function()
        applyTiming(slot)
      end, { enabled = canApply() }),
    }),
    timingError[slot] and ui.label({ text = timingError[slot], color = "error", fontSize = 12 }),
    hint(tr("timing.hint"))
  )
end

local function appNodes(slot)
  local out = { ui.label({ text = tr("apps.title"), fontWeight = "bold", fontSize = 12 }) }
  local assigned = {}
  for _, rule in ipairs(sel.apps) do
    if rule.slot == slot then
      assigned[rule.app_id] = true
      table.insert(
        out,
        ui.row({ key = slot .. ":" .. rule.app_id, gap = 8, align = "center" }, {
          ui.label({ text = rule.app_id, flexGrow = 1 }),
          ui.label({
            text = rule.entry and rule.entry.name or tr("apps.off"),
            color = "primary",
            fontSize = 12,
          }),
          button(tr("slots.change"), function()
            pick(slot, rule.app_id)
          end, { enabled = canApply() }),
          button(tr("apps.remove"), function()
            commit(function(n)
              Selection.removeApp(n, rule.app_id, slot)
            end)
          end, { variant = "ghost", enabled = canApply() }),
        })
      )
    end
  end
  if openApps == nil then
    table.insert(out, hint(tr("apps.loading")))
  else
    local choices, labels = {}, { tr("apps.add") }
    for _, app in ipairs(openApps) do
      if not assigned[app] then
        table.insert(choices, app)
        table.insert(labels, app)
      end
    end
    if #choices > 0 then
      table.insert(
        out,
        ui.select({
          key = slot .. ":add",
          options = labels,
          selectedIndex = 0,
          controlSize = "sm",
          enabled = canApply(),
          onChange = function(value)
            local index = tonumber(value) or 0
            if index > 0 then
              pick(slot, choices[index])
            end
          end,
        })
      )
    end
  end
  table.insert(out, hint(tr("apps.hint")))
  return out
end

local function slotsTab()
  local out = {}
  for _, slot in ipairs(Slots.list) do
    local entry = sel.slots[slot]
    local hasDetails = Slots.appSlots[slot] ~= nil or (entry ~= nil and Slots.isAnimation(slot))
    local children = {
      ui.row(
        { gap = 8, align = "center" },
        nodes(
          ui.column({ gap = 2, flexGrow = 1 }, {
            ui.label({ text = slotLabel(slot), fontWeight = "bold" }),
            ui.label({
              text = entry and entry.name or tr("slots.none"),
              color = entry and "primary" or "on_surface_variant",
              fontSize = 12,
            }),
          }),
          button(tr("slots.change"), function()
            pick(slot, nil)
          end, { enabled = canApply() }),
          entry
            and button(tr("slots.clear"), function()
              commit(function(n)
                n.slots[slot] = nil
                n.timing[slot] = nil
              end)
              if expanded == slot and not Slots.appSlots[slot] then
                expanded = nil
              end
            end, { variant = "ghost", enabled = canApply() }),
          hasDetails
            and button(expanded == slot and tr("slots.hide") or tr("slots.details"), function()
              toggleDetails(slot)
            end, { variant = "ghost" })
        )
      ),
    }
    if expanded == slot then
      if entry and Slots.isAnimation(slot) then
        append(children, timingNodes(slot, entry))
      end
      if Slots.appSlots[slot] then
        append(children, appNodes(slot))
      end
    end
    table.insert(out, card(slot, children))
  end
  return out
end

local function allEffects()
  local list = table.clone(sel.imports)
  for _, effect in ipairs(cat and cat.effects or {}) do
    table.insert(list, effect)
  end
  return list
end

local function effectCard(effect)
  local buttons = {}
  for _, slot in ipairs(picking and { picking.slot } or effect.uses) do
    table.insert(
      buttons,
      button(picking and tr("browse.apply") or slotLabel(slot), function()
        applyEffect(effect, slot)
      end, { key = effect.id .. ":" .. slot, variant = "secondary", enabled = canApply() })
    )
  end
  if effect.imported and not picking then
    table.insert(
      buttons,
      button(tr("import.remove"), function()
        removeImport(effect)
      end, { key = effect.id .. ":remove", variant = "ghost", enabled = canApply() })
    )
  end
  local image = previewFor(effect)
  return ui.row(
    { key = effect.id, gap = 12, padding = 10, radius = 8, fill = "surface_container/0.5" },
    {
      image and ui.image({ path = image, width = 144, height = 81, radius = 6, fit = "cover" })
        or ui.box({ width = 144, height = 81, radius = 6, fill = "surface_container" }),
      ui.column({ gap = 4, flexGrow = 1 }, {
        ui.label({ text = effect.name, fontWeight = "bold" }),
        ui.label({
          text = effect.imported and tr("browse.imported")
            or tr("browse.by", { author = effect.author or "" }),
          fontSize = 12,
          color = "on_surface_variant",
        }),
        ui.label({ text = effect.description or "", fontSize = 12, maxLines = 2 }),
        ui.row({ gap = 6 }, buttons),
      }),
    }
  )
end

local importOpen = false
local importForm = { path = "", name = "", slot = 1 }

local function importShader()
  if busy then
    return
  end
  local taken = {}
  for _, effect in ipairs(sel.imports) do
    taken[effect.id] = true
  end
  local slot = Slots.list[importForm.slot]
  local effect, err = Files.import(env.paths.shaders, importForm.path, importForm.name, slot, taken)
  if not effect then
    say(tr("import.failed", { error = tostring(err) }), true)
    render()
    return
  end
  local nxt = Selection.copy(sel)
  table.insert(nxt.imports, effect)
  local ok, saveErr = Selection.save(env.selectionPath, nxt)
  if ok then
    sel = nxt
    importOpen = false
    importForm = { path = "", name = "", slot = importForm.slot }
    say(tr("status.imported", { name = effect.name }))
  else
    Files.removeImport(effect)
    say(tr("import.failed", { error = tostring(saveErr) }), true)
  end
  render()
end

-- The open GLSL import form, shown under the search row.
local function importCard()
  return card("import", {
    ui.label({ text = tr("import.title"), fontWeight = "bold" }),
    ui.input({
      key = "import:path",
      value = importForm.path,
      placeholder = tr("import.path"),
      controlSize = "sm",
      onChange = function(value)
        importForm.path = value
      end,
    }),
    ui.input({
      key = "import:name",
      value = importForm.name,
      placeholder = tr("import.name"),
      controlSize = "sm",
      onChange = function(value)
        importForm.name = value
      end,
    }),
    ui.select({
      key = "import:slot",
      options = slotOptions(),
      selectedIndex = importForm.slot - 1,
      controlSize = "sm",
      onChange = function(value)
        importForm.slot = (tonumber(value) or 0) + 1
        render()
      end,
    }),
    hint(tr("import.hint")),
    ui.row({ gap = 6, justify = "end" }, {
      button(tr("browse.cancel"), function()
        importOpen = false
        render()
      end, { variant = "ghost" }),
      button(tr("import.save"), importShader, { variant = "primary", enabled = not busy }),
    }),
  })
end

local function browseTab()
  local out = {}
  if picking then
    local target = picking
    local text = target.app_id
        and tr("browse.picking_app", { app = target.app_id, slot = slotLabel(target.slot) })
      or tr("browse.picking", { slot = slotLabel(target.slot) })
    table.insert(
      out,
      ui.row(
        { gap = 8, align = "center" },
        nodes(
          ui.label({ text = text, flexGrow = 1 }),
          target.app_id
            and button(tr("apps.off"), function()
              picking, tab, query = nil, "slots", ""
              commit(function(n)
                Selection.setApp(n, target.app_id, target.slot, nil)
              end)
            end, { enabled = canApply() }),
          button(tr("browse.cancel"), function()
            picking, tab, query = nil, "slots", ""
            render()
          end, { variant = "ghost" })
        )
      )
    )
  end
  table.insert(
    out,
    ui.row(
      { gap = 8 },
      nodes(
        ui.input({
          key = "search:" .. (picking and (picking.slot .. (picking.app_id or "")) or "all"),
          value = query,
          placeholder = tr("browse.search"),
          controlSize = "sm",
          flexGrow = 1,
          onChange = function(value)
            query, page = value, 1
            render()
          end,
        }),
        not picking
          and ui.select({
            key = "slot-filter",
            options = slotOptions(tr("browse.all_slots")),
            selectedIndex = slotFilter and table.find(Slots.list, slotFilter) or 0,
            controlSize = "sm",
            width = 200,
            onChange = function(value)
              local index = tonumber(value) or 0
              slotFilter, page = index > 0 and Slots.list[index] or nil, 1
              render()
            end,
          }),
        not picking
          and not importOpen
          and button(tr("import.open"), function()
            importOpen = true
            render()
          end, { glyph = "plus", variant = "outline" })
      )
    )
  )
  if importOpen and not picking then
    table.insert(out, importCard())
  end
  local effects = allEffects()
  if #effects == 0 then
    local key = catState == "error" and "banner.catalogue_failed" or "banner.loading"
    table.insert(out, ui.label({ text = tr(key), color = "on_surface_variant" }))
  else
    local results = Catalogue.search(effects, query, picking and picking.slot or slotFilter)
    local pages = math.max(1, math.ceil(#results / PAGE_SIZE))
    page = math.clamp(page, 1, pages)
    if #results == 0 then
      table.insert(out, ui.label({ text = tr("browse.empty"), color = "on_surface_variant" }))
    end
    for i = (page - 1) * PAGE_SIZE + 1, math.min(page * PAGE_SIZE, #results) do
      table.insert(out, effectCard(results[i]))
    end
    if pages > 1 then
      table.insert(
        out,
        ui.row({ gap = 8, align = "center", justify = "center" }, {
          button(tr("browse.previous"), function()
            page -= 1
            render()
          end, { enabled = page > 1 }),
          ui.label({ text = tr("browse.page", { page = tostring(page), pages = tostring(pages) }) }),
          button(tr("browse.next"), function()
            page += 1
            render()
          end, { enabled = page < pages }),
        })
      )
    end
  end
  return out
end

local function familiesTab()
  if not cat then
    return { ui.label({ text = tr("banner.loading"), color = "on_surface_variant" }) }
  end
  if #cat.families == 0 then
    return { ui.label({ text = tr("families.empty"), color = "on_surface_variant" }) }
  end
  local out = {}
  for _, family in ipairs(cat.families) do
    local members = {}
    for slot, effect in pairs(Catalogue.familySlots(cat, family)) do
      table.insert(members, slotLabel(slot) .. ": " .. effect.name)
    end
    table.sort(members)
    table.insert(
      out,
      card(family.id, {
        ui.label({ text = family.name, fontWeight = "bold" }),
        ui.label({ text = family.description or "", fontSize = 12, maxLines = 3 }),
        hint(table.concat(members, " · ")),
        ui.row({ justify = "end" }, {
          button(tr("families.apply"), function()
            applyFamily(family)
          end, { variant = "primary", enabled = canApply() }),
        }),
      })
    )
  end
  return out
end

local function banner(text, actions)
  return ui.column({ gap = 8, padding = 10, radius = 8, border = "primary", borderWidth = 1 }, {
    ui.label({ text = text }),
    ui.row({ gap = 6, justify = "end" }, actions),
  })
end

local function banners()
  local out = {}
  if not hasUmbriel then
    table.insert(out, banner(tr("banner.no_umbriel"), {}))
  end
  if setupState ~= "present" then
    local actions = nodes(
      setupState == "insert"
        and button(tr("setup.add"), runSetup, {
          variant = "primary",
          enabled = not busy,
        }),
      button(tr("setup.copy"), function()
        noctalia.copyToClipboard(Config.snippet, "text/plain")
        say(tr("setup.copied"))
        render()
      end),
      button(tr("setup.check"), function()
        refreshSetup()
        render()
      end, { variant = "ghost" })
    )
    table.insert(
      out,
      banner(tr("setup.text", { path = env.paths.config }) .. "\n\n" .. Config.snippet, actions)
    )
  end
  if catState == "offline" then
    table.insert(out, banner(tr("banner.offline"), {}))
  end
  return out
end

local function header()
  return ui.row({ gap = 6, align = "center" }, {
    ui.label({
      text = tr("title"),
      fontSize = 16,
      fontWeight = "bold",
      color = "primary",
      flexGrow = 1,
    }),
    button(tr("header.undo"), function()
      local nxt = Selection.undo(sel)
      if nxt then
        commitSelection(nxt, tr("status.undone"))
      end
    end, { variant = "ghost", enabled = canApply() and sel.previous ~= nil }),
    button(tr("header.clear_all"), function()
      commit(Selection.clearAll, tr("status.cleared"))
    end, { variant = "ghost", enabled = canApply() }),
    button(nil, function()
      for dest, state in pairs(previews) do
        if state == "failed" then
          previews[dest] = nil
        end
      end
      fetchCatalogue()
      render()
    end, {
      glyph = "refresh",
      tooltip = tr("header.refresh"),
      variant = "ghost",
      enabled = not fetching,
    }),
    button(nil, function()
      panel.close()
    end, { glyph = "x", tooltip = tr("header.close"), variant = "ghost" }),
  })
end

local function tabs()
  local function tabButton(id)
    return button(tr("tabs." .. id), function()
      tab, picking, query = id, nil, ""
      render()
    end, { variant = tab == id and "primary" or "ghost" })
  end
  return ui.row({ gap = 6 }, { tabButton("slots"), tabButton("browse"), tabButton("families") })
end

render = function()
  local body
  if tab == "browse" then
    body = browseTab()
  elseif tab == "families" then
    body = familiesTab()
  else
    body = slotsTab()
  end
  local children = { header(), tabs() }
  append(children, banners())
  if message then
    table.insert(
      children,
      ui.label({
        text = message,
        color = messageIsError and "error" or "on_surface_variant",
        fontSize = 12,
        maxLines = 4,
      })
    )
  end
  table.insert(children, ui.scroll({ key = "body:" .. tab, flexGrow = 1, gap = 8 }, body))
  panel.render(ui.column({ flexGrow = 1, gap = 10, padding = 16 }, children))
end

function onOpen()
  sel = Selection.load(env.selectionPath)
  refreshSetup()
  if not cat or Catalogue.isStale(dataDir) then
    fetchCatalogue()
  end
  render()
end
