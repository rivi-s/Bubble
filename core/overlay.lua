Bubble = Bubble or {}
local B = Bubble
B.overlay = {}

-- A small movable "latest interaction" indicator. Deliberately NOT
-- anchored to any specific chat line -- that's the drift-prone idea
-- already researched and rejected in ROADMAP §3.1 (no way to track a
-- wrapped message's line count without reimplementing text layout, and it
-- gets WORSE in exactly the busy channels it'd be used in). This sidesteps
-- that entirely: it's a normal draggable addon frame, positioned once by
-- the player like any unit frame or minimap button, that always shows the
-- MOST RECENT reaction event regardless of which message it was on. No
-- line position, nothing to drift. Hovering it shows a short rolling
-- history via GameTooltip, same mechanism as core/hover.lua's tallies.

local FADE_HOLD = 3      -- seconds fully visible before fading starts
local FADE_DURATION = 4  -- seconds to fade from opaque to hidden
local HISTORY_MAX = 10

local frame, icon, label
local history = {}
local fadeStart = nil -- GetTime() the current fade began, or nil if idle

local function SavePosition()
  local point, _, relPoint, x, y = frame:GetPoint()
  BubbleCharDB.overlayPoint = { point = point, relPoint = relPoint, x = x, y = y }
end

local function ApplyPosition()
  frame:ClearAllPoints()
  local p = BubbleCharDB.overlayPoint
  if p then
    frame:SetPoint(p.point, UIParent, p.relPoint, p.x, p.y)
  else
    frame:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", 20, 200)
  end
end

local function BuildFrame()
  if frame then return end

  frame = CreateFrame("Frame", "BubbleOverlay", UIParent)
  frame:SetWidth(220)
  frame:SetHeight(18)
  frame:SetFrameStrata("MEDIUM")
  frame:EnableMouse(true)
  frame:SetMovable(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", function() frame:StartMoving() end)
  frame:SetScript("OnDragStop", function()
    frame:StopMovingOrSizing()
    SavePosition()
  end)

  icon = frame:CreateTexture(nil, "ARTWORK")
  icon:SetWidth(16)
  icon:SetHeight(16)
  icon:SetPoint("LEFT", frame, "LEFT", 0, 0)

  label = frame:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
  label:SetPoint("LEFT", icon, "RIGHT", 4, 0)
  label:SetJustifyH("LEFT")

  frame:SetScript("OnEnter", function()
    if table.getn(history) <= 0 then return end
    GameTooltip:SetOwner(frame, "ANCHOR_TOPLEFT")
    GameTooltip:AddLine("Recent reactions")
    for i = table.getn(history), 1, -1 do
      local h = history[i]
      GameTooltip:AddLine(h.icon .. " > " .. h.text, 1, 1, 1)
    end
    GameTooltip:Show()
  end)
  frame:SetScript("OnLeave", function()
    GameTooltip:Hide()
  end)

  -- Frame-rate-independent fade, driven by GetTime() rather than a fixed
  -- per-tick decrement -- OnUpdate's own tick rate varies with FPS, a
  -- fixed decrement would fade faster on a faster machine.
  frame:SetScript("OnUpdate", function()
    if not fadeStart then return end
    local elapsed = GetTime() - fadeStart
    if elapsed < FADE_HOLD then
      label:SetAlpha(1)
    elseif elapsed < FADE_HOLD + FADE_DURATION then
      label:SetAlpha(1 - (elapsed - FADE_HOLD) / FADE_DURATION)
    else
      label:SetAlpha(0)
      fadeStart = nil
    end
  end)

  ApplyPosition()
end

-- Called from core/reactions.lua's ToggleMine/ApplyRemote -- both already
-- have `emoji` and the message's origin (sender/snippet, the same data
-- core/reactions.lua's own pill quoting uses) in hand at the point they'd
-- call this, so no new tracking is needed here.
function B.overlay.ShowEvent(emoji, origin)
  BuildFrame()

  icon:SetTexture("Interface\\AddOns\\Bubble\\textures\\" .. emoji)
  local iconEscape = (B.icons and B.icons[emoji]) or ""

  local text = origin and (origin.sender .. ": " .. origin.snippet) or "?"
  label:SetText(text)
  label:SetAlpha(1)
  fadeStart = GetTime()

  table.insert(history, { icon = iconEscape, text = text })
  if table.getn(history) > HISTORY_MAX then
    table.remove(history, 1)
  end

  frame:Show()
end
