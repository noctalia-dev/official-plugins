--!nonstrict
-- Countdown timer desktop widget — the reference [[desktop_widget]] entry.
--
-- Desktop widgets describe their UI declaratively: build a tree with the ui.*
-- constructors and hand it to desktopWidget.render(). The host diffs the tree
-- against the previous one and updates the retained native controls, so calling
-- render() with an unchanged tree is free.
--
--   desktopWidget.render(tree)            replace the widget's UI tree
--   desktopWidget.setWantsSecondTicks(b)  tick update() on second boundaries
--   noctalia.getConfig(key)               settings (seeded from the manifest)
--   button onClick = "name"               calls the plugin global of that name

local duration = noctalia.getConfig("duration")
local color = noctalia.getConfig("color")
local showProgress = noctalia.getConfig("show_progress")

local remaining = duration
local running = false
local deadline = 0 -- os.clock() timestamp when the countdown hits zero

local function formatTime(seconds)
  local m = seconds // 60
  local s = seconds % 60
  if m >= 60 then
    return `{m // 60}:{string.format("%02d", m % 60)}:{string.format("%02d", s)}`
  end
  return `{m}:{string.format("%02d", s)}`
end

local function render()
  local rows = {
    ui.label({
      text = formatTime(remaining),
      fontSize = 34,
      fontWeight = "bold",
      color = remaining == 0 and "error" or color,
    }),
  }

  if showProgress then
    table.insert(rows, ui.progress({
      progress = duration > 0 and remaining / duration or 0,
      fill = color,
      width = 160,
      height = 6,
      radius = 3,
    }))
  end

  table.insert(rows, ui.row({ gap = 8 }, {
    ui.button({
      text = running and "Pause" or "Start",
      variant = "primary",
      onClick = "toggleTimer",
    }),
    ui.button({
      text = "Reset",
      variant = "outline",
      onClick = "resetTimer",
    }),
  }))

  desktopWidget.render(ui.column({ gap = 10, align = "center" }, rows))
end

function update()
  desktopWidget.setWantsSecondTicks(true)
  if running then
    remaining = math.max(0, math.ceil(deadline - os.clock()))
    if remaining == 0 then
      running = false
      noctalia.notify("Timer", `Time's up — {formatTime(duration)} elapsed`)
    end
  end
  render()
end

function toggleTimer()
  if remaining == 0 then
    remaining = duration
  end
  running = not running
  if running then
    deadline = os.clock() + remaining
  end
  render()
end

function resetTimer()
  running = false
  remaining = duration
  render()
end
