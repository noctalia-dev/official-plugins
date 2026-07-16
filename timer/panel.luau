--!nonstrict
-- Panel: input, Start/Pause, Reset controls.

local inputDigits = "500"
local remaining = 300
local formattedTime = "5:00"
local STATE = "IDLE"
-- used to update input value programatically
local inputKey = 0

local function parseDigits(digits)
  digits = digits:gsub("%s", "")
  if digits == "" then
    return 0
  end
  digits = digits:gsub("[^0-9]", "")
  if digits == "" then
    return 0
  end

  local secs = 0
  local mins = 0
  local hours = 0

  if #digits <= 2 then
    secs = tonumber(digits)
  elseif #digits <= 4 then
    local ssStr = digits:sub(-2)
    local mmStr = digits:sub(1, -3)
    secs = tonumber(ssStr) or 0
    mins = tonumber(mmStr) or 0
  else
    local ssStr = digits:sub(-2)
    local mmStr = digits:sub(-4, -3)
    local hhStr = digits:sub(1, -5)

    secs = math.min(59, math.max(0, tonumber(ssStr) or 0))
    mins = math.min(59, math.max(0, tonumber(mmStr) or 0))
    hours = math.max(0, tonumber(hhStr) or 0)
  end

  return hours * (60 ^ 2) + mins * 60 + secs
end

local function render()
  local remainingText = remaining > 0 and formattedTime or "--:--"

  local btnText = STATE == "RUNNING" and "Pause" or "Start"
  local btnVariant = STATE == "RUNNING" and "secondary" or "primary"

  panel.render(ui.column({ gap = 12, padding = 16 }, {
    ui.label({ text = "Timer duration", fontSize = 16, fontWeight = "bold", color = "primary" }),
    ui.column({ gap = 8, padding = 8, fill = "surface_variant/0.4", radius = 8 }, {
      ui.row({ justify = "center" }, {
        ui.label({
          text = remainingText,
          fontSize = 36,
          fontWeight = "bold",
          color = remaining > 0 and "primary" or "outline",
        }),
      }),
      ui.input({
        key = "dur-" .. inputKey,
        value = inputDigits,
        placeholder = "e.g. 400 → 4:00",
        fontSize = 14,
        focus = true,
        onChange = "onInputChange",
        onSubmit = "onInputSubmit",
        enabled = STATE == "IDLE" and true or false
      }),
    }),
    ui.row({ gap = 8, justify = "space_between" }, {
      ui.button({
        text = "Reset",
        variant = "destructive",
        onClick = "onReset",
      }),
      ui.button({
        text = btnText,
        variant = btnVariant,
        onClick = "onToggle",
      }),
    }),
  }))
end

function onOpen(_context)
  STATE = noctalia.state.get("timer.state")
  render()
end

function updateInputDigits()
  inputKey = inputKey + 1
end

noctalia.state.watch("timer.state", function(value)
  STATE = value
  render()
end)

noctalia.state.watch("timer.formattedTime", function(value)
  formattedTime = value
  render()
end)

noctalia.state.watch("timer.remaining", function(value)
  remaining = value
  updateInputDigits()
  render()
end)

function onReset()
  noctalia.state.set("timer.cmd", "RESET")
  inputDigits = ""
end

function onInputChange(value)
  if STATE == "IDLE" then
    noctalia.state.set("timer.remaining", parseDigits(value))
    inputDigits = value
    updateInputDigits()
    render()
  end
end

function onInputSubmit()
  if STATE == "IDLE" then
    noctalia.state.set("timer.cmd", "START")
  end
end

function onToggle()
  if STATE == "RUNNING" then
    noctalia.state.set("timer.state", "IDLE")
  elseif STATE == "IDLE" then
    noctalia.state.set("timer.state", "RUNNING")
  end
end
