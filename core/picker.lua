Bubble = Bubble or {}
local B = Bubble
B.picker = {}

-- ROADMAP §2.2: a small picker showing every defined reaction (B.icons,
-- currently 5 -- see §1.4) so a click can choose WHICH emoji instead of
-- always reacting with one hardcoded default. No separate
-- favorites/recents/"more" distinction yet -- that only earns its keep
-- once the icon set is bigger than fits in one row; five icons just show
-- directly, all at once. Trigger: right-click on any bubble: link opens
-- this; left-click on the bare marker (no emoji chosen yet) also opens
-- it, since there's nothing to quick-toggle without a specific emoji
-- already visible. Left-click on an EXISTING pill still quick-toggles
-- that one specific emoji directly, without opening this at all --
-- core/chat.lua's HookSetItemRef is what routes those cases apart.

local ICON_SIZE = 20
local PADDING = 4

-- Idle opacity -- Decided in ROADMAP §2.2: low until hovered, so the
-- picker doesn't compete with the chat text it's sitting over. This is
-- the picker FRAME itself (a real Frame/Texture, which supports SetAlpha
-- normally) -- unlike the [+]/pill chat TEXT, which can't do this at all
-- (WoW's |cAARRGGBB alpha byte is effectively ignored for chat text).
local IDLE_ALPHA = 0.28

-- No click-outside-to-close catcher on purpose: a full-screen mouse frame
-- swallowed every click (chat box, world, other UI) while the picker was
-- up, so you couldn't type or interact until you dismissed it. Instead the
-- picker closes itself after IDLE_CLOSE seconds with the mouse not over it,
-- picking an icon closes it, and Escape closes it (UISpecialFrames).
local IDLE_CLOSE = 10

local frame = nil
local idleElapsed = 0
local currentKey = nil

local function ClosePicker()
  if frame then frame:Hide() end
  currentKey = nil
end

local function BuildFrame()
  if frame then return end
  frame = CreateFrame("Frame", "BubblePickerFrame", UIParent)
  frame:SetFrameStrata("FULLSCREEN_DIALOG")
  frame:EnableMouse(true)
  frame:SetBackdrop({
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 12,
    insets = { left = 3, right = 3, top = 3, bottom = 3 },
  })
  frame:SetBackdropColor(0, 0, 0, 0.9)
  frame:SetAlpha(IDLE_ALPHA)
  frame:SetScript("OnEnter", function() frame:SetAlpha(1) end)
  frame:SetScript("OnLeave", function() frame:SetAlpha(IDLE_ALPHA) end)
  frame:SetScript("OnUpdate", function()
    if MouseIsOver(frame) then
      idleElapsed = 0
      return
    end
    idleElapsed = idleElapsed + arg1
    if idleElapsed >= IDLE_CLOSE then ClosePicker() end
  end)
  frame:Hide()
  tinsert(UISpecialFrames, "BubblePickerFrame")

  -- Fixed, sorted iteration order -- B.icons is a plain table, and pairs()
  -- gives no ordering guarantee, which would otherwise make the picker's
  -- button layout shuffle between sessions.
  local emojiList = {}
  for name in pairs(B.icons) do
    table.insert(emojiList, name)
  end
  table.sort(emojiList)

  local count = table.getn(emojiList)
  frame:SetWidth(count * ICON_SIZE + (count + 1) * PADDING)
  frame:SetHeight(ICON_SIZE + 2 * PADDING)

  for i = 1, count do
    local emoji = emojiList[i]
    local btn = CreateFrame("Button", "BubblePickerBtn" .. i, frame)
    btn:SetWidth(ICON_SIZE)
    btn:SetHeight(ICON_SIZE)
    btn:SetPoint("LEFT", frame, "LEFT", PADDING + (i - 1) * (ICON_SIZE + PADDING), 0)

    local tex = btn:CreateTexture(nil, "ARTWORK")
    tex:SetAllPoints(btn)
    -- B.icons stores a |T...|t escape string for embedding in chat TEXT --
    -- not usable as a Texture:SetTexture() argument, which needs the bare
    -- path. Built directly here instead of reusing B.icons.
    tex:SetTexture("Interface\\AddOns\\Bubble\\textures\\" .. emoji)

    btn:SetScript("OnEnter", function()
      frame:SetAlpha(1)
      tex:SetVertexColor(1.3, 1.3, 1.3)
    end)
    btn:SetScript("OnLeave", function()
      tex:SetVertexColor(1, 1, 1)
    end)
    btn:SetScript("OnClick", function()
      if currentKey then
        B.reactions.ToggleMine(currentKey, emoji)
      end
      ClosePicker()
    end)
  end
end

-- CONFIRMED (bounded logic, cursor-anchoring is a well-established vanilla
-- addon idiom -- GetCursorPosition() returns screen pixels that need
-- dividing by UIParent's effective scale to convert to frame-positioning
-- units): needs a live-client check regardless, same as everything new
-- here, since this is the first Bubble frame with a computed on-screen
-- position rather than a fixed anchor.
function B.picker.Open(key)
  BuildFrame()
  currentKey = key
  idleElapsed = 0

  local scale = UIParent:GetEffectiveScale()
  local x, y = GetCursorPosition()
  x, y = x / scale, y / scale

  -- Centered on the cursor, then clamped so the whole picker stays on
  -- screen -- a click near the right/top/bottom edge (or the screen's
  -- left edge) would otherwise open it partly or fully off-screen.
  local w, h = frame:GetWidth(), frame:GetHeight()
  --
  -- CONFIRMED ON LIVE CLIENT (2026-10-04): bounds come from
  -- GetScreenWidth/Height, NOT UIParent:GetWidth/Height. On the test client
  -- (UI scale 0.9) UIParent:GetWidth() reported 1228.8 while the real
  -- visible width in UI units was 1365.3 (GetScreenWidth) -- clamping to
  -- UIParent's size parked the picker ~136 units short of the right edge.
  local maxX = GetScreenWidth() - w
  local maxY = GetScreenHeight() - h
  local left = x - w / 2
  local bottom = y - h / 2
  if left > maxX then left = maxX end
  if left < 0 then left = 0 end
  if bottom > maxY then bottom = maxY end
  if bottom < 0 then bottom = 0 end

  frame:ClearAllPoints()
  frame:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", left, bottom)

  frame:Show()
  frame:SetAlpha(IDLE_ALPHA)
end
