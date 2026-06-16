-- Privacy Indicator — headless service.
-- Ticks every second, queries PipeWire and /sys/class/video4linux for active
-- microphone, camera, and screen-sharing streams, then publishes to "status".

local pwCmd = [[pw-dump | jq '{
  nodes: [.[] | select(.type == "PipeWire:Interface:Node") | {id: .id, class: .info.props."media.class", name: .info.props."node.name", app: .info.props."application.name", capture_sink: .info.props."stream.capture.sink", media_name: .info.props."media.name"}],
  links: [.[] | select(.type == "PipeWire:Interface:Link" and .info.state == "active") | {source: .info."output-node-id", target: .info."input-node-id"}]
}']]

local camCmd = [[for dev in /sys/class/video4linux/video*; do [ -e "$dev/name" ] && grep -qv 'Metadata' "$dev/name" && dev_name=$(basename "$dev") && find /proc/[0-9]*/fd -lname "/dev/$dev_name" 2>/dev/null; done | cut -d/ -f3 | xargs -r ps -o comm= -p | sort -u | tr '\n' ',' | sed 's/,$//']]

noctalia.setUpdateInterval(1000)

local lastMicActive = false
local lastCamActive = false
local lastScrActive = false

local function hasNodeLinks(nodeId, links)
    for _, link in ipairs(links) do
        if link.source == nodeId or link.target == nodeId then
            return true
        end
    end
    return false
end

function update()
    local pwDone = false
    local camDone = false
    local pwResult = nil
    local camResult = nil

    local function processResults()
        if not (pwDone and camDone) then return end

        local status = {
            micActive = false,
            micApps = {},
            camActive = false,
            camApps = {},
            scrActive = false,
            scrApps = {}
        }

        if pwResult and pwResult.exitCode == 0 then
            local data = noctalia.json.decode(pwResult.stdout)
            if data and data.nodes and data.links then
                local nodes = data.nodes
                local links = data.links

                local activeNodeIds = {}
                for _, link in ipairs(links) do
                    if link.source then activeNodeIds[link.source] = true end
                    if link.target then activeNodeIds[link.target] = true end
                end

                for _, node in ipairs(nodes) do
                    if activeNodeIds[node.id] then
                        if node.class == "Stream/Input/Audio" and node.capture_sink ~= "true" and node.capture_sink ~= true then
                            status.micActive = true
                            local appName = node.app or node.name or "Unknown"
                            if not table.find(status.micApps, appName) then
                                table.insert(status.micApps, appName)
                            end
                        end

                        local class = node.class or ""
                        local isVideo = string.find(class, "Video")
                        local isAudio = string.find(class, "Audio")
                        if isVideo and not isAudio then
                            local mediaName = string.lower(node.media_name or "")
                            if string.match(mediaName, "^xdph%-streaming") or
                               string.match(mediaName, "^gsr%-default") or
                               string.match(mediaName, "^game capture") or
                               string.match(mediaName, "^screen") or
                               string.match(mediaName, "^desktop") or
                               string.match(mediaName, "^display") or
                               string.match(mediaName, "^cast") or
                               string.match(mediaName, "^webrtc") or
                               string.match(mediaName, "^v4l2") or
                               mediaName == "gsr-default_output" or
                               string.find(mediaName, "screen%-cast") or
                               string.find(mediaName, "screen%-capture") or
                               string.find(mediaName, "desktop%-capture") or
                               string.find(mediaName, "monitor%-capture") or
                               string.find(mediaName, "window%-capture") or
                               string.find(mediaName, "game%-capture") then

                                status.scrActive = true
                                local appName = node.app or node.name or "Unknown"
                                if not table.find(status.scrApps, appName) then
                                    table.insert(status.scrApps, appName)
                                end
                            end
                        end
                    end
                end
            end
        end

        if camResult and camResult.exitCode == 0 then
            local appsStr = string.gsub(camResult.stdout, "%s+", "")
            if #appsStr > 0 then
                for app in string.gmatch(appsStr, "([^,]+)") do
                    status.camActive = true
                    if not table.find(status.camApps, app) then
                        table.insert(status.camApps, app)
                    end
                end
            end
        end

        local enableToast = noctalia.getConfig("enable_toast")
        if enableToast ~= false then
            if status.micActive and not lastMicActive then
                local appList = #status.micApps > 0 and (" by " .. table.concat(status.micApps, ", ")) or ""
                noctalia.notify("Microphone Active", "Microphone is being used" .. appList)
            end
            if status.camActive and not lastCamActive then
                local appList = #status.camApps > 0 and (" by " .. table.concat(status.camApps, ", ")) or ""
                noctalia.notify("Camera Active", "Camera is being used" .. appList)
            end
            if status.scrActive and not lastScrActive then
                local appList = #status.scrApps > 0 and (" by " .. table.concat(status.scrApps, ", ")) or ""
                noctalia.notify("Screen Sharing Active", "Screen sharing is active" .. appList)
            end
        end

        lastMicActive = status.micActive
        lastCamActive = status.camActive
        lastScrActive = status.scrActive

        noctalia.state.set("status", status)
    end

    noctalia.runAsync(pwCmd, function(res)
        pwResult = res
        pwDone = true
        processResults()
    end)

    noctalia.runAsync(camCmd, function(res)
        camResult = res
        camDone = true
        processResults()
    end)
end
