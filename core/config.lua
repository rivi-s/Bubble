Bubble = Bubble or {}
local B = Bubble
B.config = {}

-- Per-character settings -- centralized here rather than scattered across
-- modules, since this is the natural home for whatever a future graphical
-- options panel would also read/write. BubbleCharDB ITSELF is initialized
-- centrally in core/init.lua's ADDON_LOADED handler; this module only owns
-- the specific fields under it that are genuinely settings (as opposed to,
-- say, core/overlay.lua's own overlayPoint, which isn't a "setting" in the
-- configurable sense).

local DEFAULTS = {
  -- CONFIRMED live (2026-09-29): the chat pill line was crowding out real
  -- chat once core/overlay.lua existed as a lighter always-visible
  -- alternative -- see ROADMAP.md's write-up of the screenshot that
  -- prompted this. Off by default; reactions are still fully trackable
  -- via the overlay and core/hover.lua's tooltips either way -- this
  -- setting only gates the extra chat LINE, never the underlying state.
  showPills = false,
}

-- Explicit nil-check, not `BubbleCharDB[name] or DEFAULTS[name]` -- a
-- boolean setting explicitly set to `false` must stay `false`, not fall
-- through to whatever the default happens to be.
function B.config.Get(name)
  local v = BubbleCharDB[name]
  if v == nil then return DEFAULTS[name] end
  return v
end

function B.config.Set(name, value)
  BubbleCharDB[name] = value
end

SLASH_BUBBLE1 = "/bubble"
SlashCmdList["BUBBLE"] = function(msg)
  msg = string.lower(msg or "")

  if msg == "pills on" then
    B.config.Set("showPills", true)
    DEFAULT_CHAT_FRAME:AddMessage("Bubble: chat pill lines are now ON.")
  elseif msg == "pills off" then
    B.config.Set("showPills", false)
    DEFAULT_CHAT_FRAME:AddMessage("Bubble: chat pill lines are now OFF.")
  else
    local state = B.config.Get("showPills") and "ON" or "OFF"
    DEFAULT_CHAT_FRAME:AddMessage("Bubble: chat pill lines are currently " ..
      state .. ". Use /bubble pills on or /bubble pills off to change.")
  end
end
