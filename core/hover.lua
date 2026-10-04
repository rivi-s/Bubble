Bubble = Bubble or {}
local B = Bubble
B.hover = {}

-- ROADMAP §2.2 (pulled forward from Phase 2): a live tally shown on hover,
-- cursor-anchored via GameTooltip -- deliberately NOT a persistent badge.
-- GameTooltip:SetOwner(this, "ANCHOR_CURSOR") needs no chat-line screen
-- position at all, unlike anything permanently attached to a specific
-- line (see ROADMAP's "overlay" discussion -- that's a separate, still
-- experimental follow-up, not this file).
--
-- OnHyperlinkEnter/OnHyperlinkLeave are frame SCRIPTS, not a plain Lua
-- field like AddMessage -- SetScript REPLACES whatever handler was there,
-- it doesn't chain. pfUI's own chat.lua sets these on every ChatFrame for
-- item-link tooltips (verified by reading it directly, same as core/chat.lua's
-- AddMessage/SetItemRef hooks), so clobbering them here would silently
-- break pfUI's own tooltips. Save via GetScript, call the saved original
-- from inside our replacement -- same save-and-chain principle as
-- core/chat.lua, just via the script-handler mechanism instead of a table
-- field.

local MAX_NAMES_SHOWN = 5

-- Adds one emoji's "icon count" + dimmed reactor-name line to the
-- currently-open GameTooltip. Shared by both branches of ShowTally below
-- -- the same two lines, just called once (a specific pill) or several
-- times in a row (the marker's all-emoji breakdown).
local function AddEmojiLines(key, emoji)
  local count = B.reactions.Count(key, emoji)
  local names = B.reactions.ReactorNames(key, emoji)
  local shown = table.getn(names)
  local nameList = table.concat(names, ", ", 1, (shown < MAX_NAMES_SHOWN) and shown or MAX_NAMES_SHOWN)
  if shown > MAX_NAMES_SHOWN then
    nameList = nameList .. ", +" .. (shown - MAX_NAMES_SHOWN) .. " more"
  end
  GameTooltip:AddLine((B.icons[emoji] or "") .. " " .. count)
  GameTooltip:AddLine(nameList, 0.6, 0.6, 0.6, true)
end

-- Returns true if this link was ours and something was shown, false
-- otherwise -- the caller uses this to decide whether to fall through to
-- whatever handler was already there (item tooltips, etc).
local function ShowTally(link)
  if not link or string.sub(link, 1, 7) ~= "bubble:" then return false end
  local rest = string.sub(link, 8)
  local colon = string.find(rest, ":", 1, true)

  if colon then
    -- bubble:KEY:EMOJI -- a pill's own link, one specific emoji.
    local key = string.sub(rest, 1, colon - 1)
    local emoji = string.sub(rest, colon + 1)
    if B.reactions.Count(key, emoji) <= 0 then return false end
    GameTooltip:SetOwner(this, "ANCHOR_CURSOR")
    AddEmojiLines(key, emoji)
    GameTooltip:Show()
    return true
  end

  -- bubble:KEY -- the original message's generic marker (§2.2's picker
  -- trigger). No single emoji to look up here -- since §2.2, a message can
  -- carry more than one -- so this shows a breakdown across all of them.
  local key = rest
  local emojis = B.reactions.ActiveEmojis(key)
  if table.getn(emojis) <= 0 then return false end -- nothing reacted yet

  GameTooltip:SetOwner(this, "ANCHOR_CURSOR")
  for i = 1, table.getn(emojis) do
    AddEmojiLines(key, emojis[i])
  end
  GameTooltip:Show()
  return true
end

local function HookHyperlinkScripts(frame)
  if not frame or frame.BubbleHookedHover then return end
  frame.BubbleHookedHover = true

  local origEnter = frame:GetScript("OnHyperlinkEnter")
  frame:SetScript("OnHyperlinkEnter", function()
    if not ShowTally(arg1) and origEnter then
      origEnter()
    end
  end)

  local origLeave = frame:GetScript("OnHyperlinkLeave")
  frame:SetScript("OnHyperlinkLeave", function()
    GameTooltip:Hide()
    if origLeave then origLeave() end
  end)
end

-- Installed from PLAYER_ENTERING_WORLD, not file scope, same reasoning as
-- core/chat.lua's AddMessage/SetItemRef hooks -- chains onto whatever
-- pfUI (or nothing) has already installed by the time we run.
B.RegisterEvent("PLAYER_ENTERING_WORLD", function()
  for i = 1, NUM_CHAT_WINDOWS do
    HookHyperlinkScripts(_G["ChatFrame" .. i])
  end
end)
