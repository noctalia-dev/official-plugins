--!nonstrict
-- Headless [[service]] entry: runs in the background with no UI, ticking once a
-- second and publishing an incrementing counter to the plugin's shared state.
-- Any of this plugin's entries (the hello widget) can read it with
-- noctalia.state.get / noctalia.state.watch.

local count = 0

-- Drive this service's own tick rate
noctalia.setUpdateInterval(1000)

function update()
  count += 1
  noctalia.state.set("tick", count)
end

-- Drives the `banner` [[layer]] entry (banner.luau). Layers are shown, hidden and
-- reconfigured by local entry id from any entry of the same plugin.
--   noctalia msg plugin noctalia/example:ticker all layer-toggle
--   noctalia msg plugin noctalia/example:ticker all layer-move
--   noctalia msg plugin noctalia/example:ticker all layer-idle
local layerShown = false
local layerAtBottom = false
local idleWatch = nil

local function setLayerShown(shown)
  layerShown = shown
  if shown then
    noctalia.layer.show("banner")
  else
    noctalia.layer.hide("banner")
  end
end

-- banner.luau's close button hides the layer itself and reports it here.
noctalia.state.watch("bannerClosed", function()
  layerShown = false
end)

function onIpc(event, payload)
  if event == "layer-toggle" then
    setLayerShown(not layerShown)
  elseif event == "layer-move" then
    layerAtBottom = not layerAtBottom
    noctalia.layer.configure("banner", {
      anchors = { layerAtBottom and "bottom" or "top", "left", "right" },
    })
  elseif event == "layer-idle" then
    -- noctalia.idle.watch (plugin_api 35): callback(true) after 5 s without input,
    -- callback(false) on the next input. A second layer-idle turns the demo off.
    if idleWatch ~= nil then
      noctalia.idle.unwatch(idleWatch)
      idleWatch = nil
      noctalia.notify(noctalia.tr("title"), "Idle demo off")
      return
    end
    idleWatch = noctalia.idle.watch(5, function(idle)
      setLayerShown(idle)
    end)
    noctalia.notify(noctalia.tr("title"), "Idle demo on: stop touching input for 5 s")
  end
end
