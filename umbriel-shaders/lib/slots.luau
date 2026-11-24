-- SPDX-License-Identifier: MIT
-- The Umbriel destinations a shader can be assigned to, in display order.
local M = {}

M.list = {
  "effects.cursor",
  "effects.border",
  "effects.window",
  "effects.screen",
  "animation.windows_in",
  "animation.windows_out",
  "animation.windows_move",
  "animation.workspaces",
  "animation.overview",
  "animation.scratchpad",
  "animation.layers",
  "animation.border",
  "animation.dim_unfocused",
}

-- Slots that can also be set per application, and their [[window_rule]] key.
M.appSlots = { ["effects.border"] = "border_effect", ["effects.window"] = "window_effect" }

function M.isAnimation(slot)
  return slot:sub(1, 10) == "animation."
end

function M.kind(slot)
  if M.isAnimation(slot) then
    return "animation"
  end
  return (slot:gsub("^effects%.", ""))
end

function M.key(slot)
  return (slot:gsub("%.", "_"))
end

-- Settings that turn `preset` on in `slot`.
function M.selector(slot, preset)
  if M.isAnimation(slot) then
    return {
      ["animation.enabled"] = true,
      [slot .. ".enabled"] = true,
      [slot .. ".effect"] = preset,
    }
  end
  return { [slot] = preset }
end

-- Only the settings that belong to `slot` (plus the animation master switch).
function M.filter(settings, slot)
  local out = {}
  local prefix = slot .. "."
  for key, value in pairs(settings) do
    if
      key == slot
      or key:sub(1, #prefix) == prefix
      or (key == "animation.enabled" and M.isAnimation(slot))
    then
      out[key] = value
    end
  end
  return out
end

return M
