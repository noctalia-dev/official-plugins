--!nonstrict
-- World Clock panel - list of configured timezones with live times.
-- Add IANA zones (e.g. Europe/Berlin); remove with trash; reorder via drag grip.
-- Rename with the pencil (empty label = derived short name); the eye shows or
-- hides a zone in the bar.
-- text_size scales the panel text and show_add_zone hides the add-timezone
-- input; both are manifest settings read at render time.
--
-- Plan mode (header toggle): pick a local day and hour and every row shows
-- that moment instead of now, shaded by whether it falls inside that zone's
-- waking hours. Nothing is persisted; closing the panel returns to live time.

local DRAG_TYPE = "world-clock-zone"

local closeButton = true

local zones = {}
local draft = ""
local draftKey = 0
local pendingDelete = nil
local editingLabel = nil
local labelDraft = ""
local labelKey = 0

-- Plan mode state. planDay is days from today, planHalf is half-hours from
-- local midnight (0..47).
local planning = false
local planDay = 0
local planHalf = 0

-- With highlight_working_hours on, rows are shaded when the zone's local hour is
-- within [working_hours_start, working_hours_end); all three are panel settings.
local function planWindow()
  if noctalia.getConfig("highlight_working_hours") == false then
    return nil
  end
  local from = tonumber(noctalia.getConfig("working_hours_start")) or 8
  local to = tonumber(noctalia.getConfig("working_hours_end")) or 20
  return from, to
end

-- Multipliers for text_size setting, unset/unknown value renders 1:1
local TEXT_SCALES = { small = 0.85, large = 1.25 }

-- Same mapping the service uses, so plan-mode times honour time_format.
local TIME_FORMATS = {
  ["12h"] = "{:%I:%M %p}",
  ["24h"] = "{:%H:%M}",
}

local function timeFormat()
  return TIME_FORMATS[noctalia.getConfig("time_format")] or noctalia.timeFormat()
end

-- Epoch seconds of local midnight for the calendar day containing `at`.
local function localMidnight(at)
  local h = tonumber(noctalia.formatTime("%H", at)) or 0
  local m = tonumber(noctalia.formatTime("%M", at)) or 0
  local s = tonumber(noctalia.formatTime("%S", at)) or 0
  return at - h * 3600 - m * 60 - s
end

-- Epoch seconds for the planned moment. The target day is found by stepping
-- in whole days from today's midnight and re-anchoring to that day's own
-- midnight, so a DST change in between does not shift the slider's hour.
local function planTarget()
  local now = tonumber(noctalia.formatTime("%s")) or 0
  local today = localMidnight(now)
  local day = localMidnight(today + planDay * 86400 + 12 * 3600)
  return day + planHalf * 1800
end

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
  local scale = TEXT_SCALES[noctalia.getConfig("text_size")] or 1
  local function sized(size)
      return math.floor(size * scale + 0.5)
  end
  local target = planning and planTarget() or nil
  local rows = {}
  if #zones == 0 then
    table.insert(rows, ui.label({
      text = noctalia.tr("ui.empty"),
      color = "on_surface_variant",
      fontSize = sized(13),
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
          ui.label({ text = row.label or id, fontWeight = "bold", fontSize = sized(13) }),
          ui.label({ text = id, color = "on_surface_variant", fontSize = sized(10) }),
        })
      end

      -- Live: the service's time and UTC offset. Planning: the planned
      -- moment in this zone and its weekday, shaded when it lands inside the working_hours_start..working_hours_end window.
      local timeText = row.time or ""
      local subText = row.offset or ""
      local timeColor = "primary"
      local fill = "surface_container/0.35"
      if planning then
        timeText = noctalia.formatTime(timeFormat(), target, id)
        subText = noctalia.formatTime("%a", target, id)
        local from, to = planWindow()
        if from ~= nil then
          local hour = tonumber(noctalia.formatTime("%H", target, id)) or 0
          if hour >= from and hour < to then
            fill = "primary/0.18"
          else
            timeColor = "on_surface_variant"
          end
        end
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
          fill = fill,
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
            ui.label({ text = timeText, fontWeight = "bold", fontSize = sized(15), color = timeColor }),
            ui.label({ text = subText, color = "on_surface_variant", fontSize = sized(10) }),
          }),
          actions,
        })
      )
    end
    table.insert(rows, insertionZone(#zones + 1))
  end

  local headerContent = {
    ui.label({ text = noctalia.tr("title"), fontSize = sized(16), fontWeight = "bold", flexGrow = 1 }),
    ui.button({
      glyph = "calendar-time",
      variant = "ghost",
      selected = planning,
      tooltip = noctalia.tr("ui.plan_tooltip"),
      onClick = "onPlanToggle",
    }),
  }
  if closeButton then
    table.insert(headerContent, ui.button({ glyph = "close", onClick = function() panel.close() end }))
  end

  local sections = {
    ui.row({ align = "center", justify = "space_between", gap = 4 }, headerContent),
  }
  if planning then
    table.insert(sections, ui.row({ gap = 6, align = "center" }, {
      ui.button({
        glyph = "chevron-left",
        variant = "ghost",
        controlSize = "sm",
        onClick = function()
          planDay -= 1
          render()
        end,
      }),
      ui.label({
        text = noctalia.formatTime("%a %d %b", target),
        fontSize = sized(12),
        width = 76,
        textAlign = "center",
      }),
      ui.button({
        glyph = "chevron-right",
        variant = "ghost",
        controlSize = "sm",
        onClick = function()
          planDay += 1
          render()
        end,
      }),
      ui.slider({
        min = 0,
        max = 47,
        step = 1,
        value = planHalf,
        controlSize = "sm",
        flexGrow = 1,
        onChange = function(value)
          planHalf = math.floor((tonumber(value) or 0) + 0.5)
          render()
        end,
      }),
      ui.label({
        text = noctalia.formatTime(timeFormat(), target),
        fontWeight = "bold",
        fontSize = sized(13),
        color = "primary",
        width = 64,
        textAlign = "end",
      }),
    }))
  end
  if noctalia.getConfig("show_add_zone") ~= false then
    table.insert(sections, ui.row({ gap = 6, align = "center" }, {
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
    }))
  end
  table.insert(sections, ui.scroll({ flexGrow = 1, gap = 0 }, rows))
  panel.render(ui.column({ flexGrow = 1, gap = 8, padding = 8 }, sections))
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

-- Toggle plan mode. Entering it starts from today at the next half hour.
function onPlanToggle()
  planning = not planning
  if planning then
    local now = tonumber(noctalia.formatTime("%s")) or 0
    planDay = 0
    planHalf = math.min(47, math.ceil((now - localMidnight(now)) / 1800))
  end
  pendingDelete = nil
  editingLabel = nil
  render()
end

function onOpen(_context)
  closeButton = noctalia.getSetting("shell.show_close_buttons") ~= false
  zones = noctalia.state.get("world_clock.zones") or {}
  pendingDelete = nil
  editingLabel = nil
  planning = false
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
