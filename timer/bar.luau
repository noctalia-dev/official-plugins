--!nonstrict
-- Timer bar widget — the [[widget]] entry for the status bar.
--
-- The bar widget displays the timer's current state: an hourglass
-- icon when idle, or the formatted countdown when running. Click
-- the widget to open the panel for duration input and controls.
--
--   barWidget.render(tree)             declarative UI tree
--   barWidget.isVertical()             branch on bar orientation
--   barWidget.getConfig(key)           per-placement settings
--   noctalia.togglePanel(id)           open/close the timer panel

local STATE = "IDLE"
local formattedTime = "00:00"

local function render()
  local container = barWidget.isVertical() and ui.column or ui.row
  local showCounterWhenIdle = barWidget.getConfig("show_idle")

  -- Idle state: timer at zero, just show hourglass icon
  if STATE == "IDLE" and showCounterWhenIdle == false then
    barWidget.render(container({ align = "center" }, {
      ui.glyph({ name = "hourglass", color = "on_surface" }),
    }))
    return
  end

  -- Running or paused with time remaining
  local color = STATE == "NOTIFY" and "primary" or "on_surface"
  barWidget.render(container({ gap = 6, align = "center" }, {
    ui.glyph({ name = "hourglass", color = color }),
    ui.label({ text = formattedTime, fontWeight = "bold", color = color }),
  }))

end

function update()
  render()
end

noctalia.state.watch("timer.state", function(value)
  STATE = value
end)

noctalia.state.watch("timer.formattedTime", function(value)
  formattedTime = value
  if STATE == "RUNNING" then
    render()
  end
end)

function onClick()
  if STATE == "NOTIFY" then
    noctalia.state.set("timer.cmd", "RESET")
    return
  end
  noctalia.togglePanel("noctalia/timer:panel")
end
