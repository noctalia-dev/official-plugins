--!nonstrict
local M = {}

local dataFile = nil
local function dataPath()
    if dataFile then return dataFile end
    local dir = noctalia.pluginDataDir()
    if dir then
        dataFile = dir .. "/timer_data.json"
    end
    return dataFile
end

function M.loadData()
    local path = dataPath()
    if path == nil then return nil end
    local raw = noctalia.readFile(path)
    if raw == nil or raw == "" then return nil end
    local decoded = noctalia.json.decode(raw)
    return type(decoded) == "table" and decoded or nil
end

function M.persist(alarms)
    local path = dataPath()
    if path == nil then return end
    local encoded = noctalia.json.encode({ alarms = alarms }, true)
    if encoded then noctalia.writeFile(path, encoded) end
end

return M
