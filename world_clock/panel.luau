--!nonstrict
-- World Clock panel - list of configured timezones with live times.
-- Add IANA zones (e.g. Europe/Berlin); remove with trash; reorder via drag grip.
-- Rename with the pencil (empty label = derived short name); the eye shows or
-- hides a zone in the bar.

local DRAG_TYPE = "world-clock-zone"

local zones = {}
local draft = ""
local draftKey = 0
local pendingDelete = nil
local editingLabel = nil
local labelDraft = ""
local labelKey = 0

local function insertionZone(index)
  return ui.dropZone({
    key = "gap-" .. index,
    accepts = { DRAG_TYPE },
    value = tostring(index),
    onDrop = "onZoneDropped",
    height = 3,
    radius = 4,
    expandOnDrag = true,
    hitSlop = 24,
  })
end

local function zoneRow(id)
  for _, row in ipairs(zones) do
    if row.id == id then
      return row
    end
  end
  return nil
end

function onZoneDropped(payload, value)
  local insertAt = tonumber(value)
  if type(payload) ~= "string" or payload == "" or insertAt == nil then
    return
  end
  noctalia.state.set("world_clock.cmd", { op = "reorder", zone = payload, index = insertAt })
end

local function render()
  local rows = {}
  if #zones == 0 then
    table.insert(rows, ui.label({
      text = noctalia.tr("ui.empty"),
      color = "on_surface_variant",
      fontSize = 13,
    }))
  else
    for i, row in ipairs(zones) do
      local id = row.id
      local deleting = pendingDelete == id
      local editing = editingLabel == id
      local actions
      if deleting then
        actions = ui.row({ gap = 4, align = "center" }, {
          ui.button({
            glyph = "check",
            variant = "destructive",
            onClick = function()
              noctalia.state.set("world_clock.cmd", { op = "remove", zone = id })
              pendingDelete = nil
            end,
          }),
          ui.button({
            glyph = "close",
            variant = "ghost",
            onClick = function()
              pendingDelete = nil
              render()
            end,
          }),
        })
      elseif editing then
        actions = ui.row({ gap = 4, align = "center" }, {
          ui.button({
            glyph = "check",
            variant = "primary",
            onClick = "onLabelSubmit",
          }),
          ui.button({
            glyph = "close",
            variant = "ghost",
            onClick = function()
              editingLabel = nil
              render()
            end,
          }),
        })
      else
        actions = ui.row({ gap = 2, align = "center" }, {
          ui.button({
            glyph = row.on_bar ~= false and "eye" or "eye-off",
            variant = "ghost",
            onClick = function()
              noctalia.state.set("world_clock.cmd", { op = "bar", zone = id, on_bar = row.on_bar == false })
              render()
            end,
          }),
          ui.button({
            glyph = "pencil",
            variant = "ghost",
            onClick = function()
              editingLabel = id
              labelDraft = row.label or ""
              labelKey += 1
              pendingDelete = nil
              render()
            end,
          }),
          ui.button({
            glyph = "trash",
            variant = "ghost",
            onClick = function()
              pendingDelete = id
              editingLabel = nil
              render()
            end,
          }),
        })
      end

      local nameColumn
      if editing then
        nameColumn = ui.input({
          key = "label-" .. labelKey,
          value = labelDraft,
          placeholder = noctalia.tr("ui.label_placeholder"),
          flexGrow = 1,
          focus = true,
          onChange = function(value)
              labelDraft = value
          end,
          onSubmit = "onLabelSubmit",
        })
      else
        nameColumn = ui.column({ flexGrow = 1, gap = 1 }, {
          ui.label({ text = row.label or id, fontWeight = "bold", fontSize = 13 }),
          ui.label({ text = id, color = "on_surface_variant", fontSize = 10 }),
        })
      end

      table.insert(rows, insertionZone(i))
      table.insert(
        rows,
        ui.row({
          key = "zone-" .. id,
          gap = 6,
          align = "center",
          paddingV = 3,
          paddingH = 6,
          fill = "surface_variant/0.35",
          radius = 6,
          opacity = row.on_bar ~= false and 1 or 0.55,
        }, {
          ui.dragSource({
            key = "grip-" .. id,
            dragType = DRAG_TYPE,
            payload = id,
            previewAncestor = 1,
            liftFromLayout = true,
            width = 20,
            height = 20,
            align = "center",
            justify = "center",
            tooltip = noctalia.tr("ui.drag_tooltip"),
          }, {
            ui.glyph({ name = "menu-2", size = 14, color = "on_surface_variant" }),
          }),
          nameColumn,
          ui.column({ align = "end", gap = 1 }, {
            ui.label({ text = row.time or "", fontWeight = "bold", fontSize = 15, color = "primary" }),
            ui.label({ text = row.offset or "", color = "on_surface_variant", fontSize = 10 }),
          }),
          actions,
        })
      )
    end
    table.insert(rows, insertionZone(#zones + 1))
  end

  panel.render(ui.column({ flexGrow = 1, gap = 8, padding = 8 }, {
    ui.row({ align = "center", justify = "space_between" }, {
      ui.label({ text = noctalia.tr("title"), fontSize = 16, fontWeight = "bold", flexGrow = 1 }),
      ui.button({ glyph = "close", onClick = function()
        panel.close()
      end }),
    }),
    ui.row({ gap = 6, align = "center" }, {
      ui.input({
        key = "add-" .. draftKey,
        value = draft,
        placeholder = noctalia.tr("ui.add_placeholder"),
        flexGrow = 1,
        onChange = function(value)
          draft = value
        end,
        onSubmit = "onAdd",
      }),
      ui.button({
        glyph = "plus",
        variant = "primary",
        onClick = "onAdd",
      }),
    }),
    ui.scroll({ flexGrow = 1, gap = 0 }, rows),
  }))
end

function onAdd()
  local zone = noctalia.string.trim(draft)
  draft = ""
  draftKey += 1
  pendingDelete = nil
  editingLabel = nil
  if zone ~= "" then
    noctalia.state.set("world_clock.cmd", { op = "add", zone = zone })
  end
  render()
end

function onLabelSubmit()
    local id = editingLabel
    if id == nil then
      return
    end
    editingLabel = nil
    noctalia.state.set("world_clock.cmd", { op = "label", zone = id, label = labelDraft })
    render()
end

function onOpen(_context)
  zones = noctalia.state.get("world_clock.zones") or {}
  pendingDelete = nil
  editingLabel = nil
  draft = ""
  draftKey += 1
  panel.setWantsSecondTicks(true)
  render()
end

noctalia.state.watch("world_clock.zones", function(value)
  if type(value) == "table" then
    zones = value
  else
    zones = {}
  end
  if pendingDelete ~= nil and zoneRow(pendingDelete) == nil then
    pendingDelete = nil
  end
  if editingLabel ~= nil and zoneRow(editingLabel) == nil then
    editingLabel = nil
  end
  render()
end)
