--!nonstrict

    local M = {}

    function M.getImageConfig()
      -- 1. Дістань налаштування через noctalia.getConfig:
        local path = noctalia.getConfig("path")
        local size = noctalia.getConfig("size") or 24
        local radius = noctalia.getConfig("radius") or 6

        if path and path ~= "" and noctalia.fileExists(path) then
            return path, size, radius
        else
            return nil, size, radius

      -- 2. Перевір, чи файл існує через noctalia.fileExists(path):
      --    якщо існує -> поверни: return path, size, radius
      --    якщо НЕ існує -> поверни: return nil, size, radius
    end
end

    return M