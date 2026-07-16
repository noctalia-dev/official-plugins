
noctalia.setUpdateInterval(1000)

local function formatTime(seconds)
  local m = seconds // 60
  local s = seconds % 60
  if m >= 60 then
    return `{m // 60}:{string.format("%02d", m % 60)}:{string.format("%02d", s)}`
  end
  return `{m}:{string.format("%02d", s)}`
end

---- Initialize state
noctalia.state.set("timer.state", "IDLE") -- IDLE, NOTIFY, RUNNING
noctalia.state.set("timer.remaining", 0)
noctalia.state.set("timer.formattedTime", 0)

noctalia.state.watch("timer.remaining", function (value)
  noctalia.state.set("timer.formattedTime", formatTime(value))
end)

noctalia.state.watch("timer.cmd", function(cmd)

  local actions = {
    START = function () 
      noctalia.state.set("timer.state", "RUNNING")
    end,
    RESET = function () 
      noctalia.state.set("timer.remaining", 0)
      noctalia.state.set("timer.state", "IDLE")
    end
  }


  local action = actions[cmd]
  if action then
    action()
  else
    noctalia.log(`Unknown command: {cmd}`)
  end

end)

function update()
  local STATE = noctalia.state.get("timer.state")
  local remaining = noctalia.state.get("timer.remaining")

  if STATE == "RUNNING" then
    if remaining > 0 then
      noctalia.state.set("timer.remaining", remaining - 1)
    else
      noctalia.state.set("timer.state", "NOTIFY")
    end

  end
end
