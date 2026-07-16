--!nonstrict
-- TODO add descriptions

local STATE = "IDLE"
local formattedTime = "05:00"

local function render()
  local container = barWidget.isVertical() and ui.column or ui.row

  -- Idle state: timer at zero, just show hourglass icon
  if STATE == "IDLE" and barWidget.getConfig("show_idle") then
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
