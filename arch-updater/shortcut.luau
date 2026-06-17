-- [[shortcut]] entry: control-center quick tile.
-- Mirrors the updater service state and triggers refresh/update.

local function render()
  local count = noctalia.state.get("count") or 0
  local refreshing = noctalia.state.get("refreshing") or false
  local noctaliaHighlight = noctalia.state.get("noctalia_update") or false

  if refreshing then
    shortcut.setLabel(noctalia.tr("shortcut.refreshing"))
    shortcut.setIcon("loader")
    shortcut.setActive(false)
    shortcut.setEnabled(false)
    return
  end

  if count > 0 then
    if noctaliaHighlight then
      shortcut.setLabel(noctalia.trp("shortcut.updates", count) .. " *")
    else
      shortcut.setLabel(noctalia.trp("shortcut.updates", count))
    end
    shortcut.setIcon("arrow-big-down-lines")
    shortcut.setActive(true)
  else
    shortcut.setLabel(noctalia.tr("shortcut.noUpdates"))
    shortcut.setIcon("check")
    shortcut.setActive(false)
  end
  shortcut.setEnabled(true)
end

noctalia.state.watch("count", render)
noctalia.state.watch("refreshing", render)
noctalia.state.watch("noctalia_update", render)

render()

function onClick()
  noctalia.state.set("command", { action = "refresh" })
end

function onRightClick()
  noctalia.state.set("command", { action = "update" })
end
