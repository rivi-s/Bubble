Bubble = Bubble or {}
local B = Bubble
B.chat = {}

-- The original message's marker icon -- "add a reaction," not a reaction
-- choice itself, so it's deliberately NOT in core/reactions.lua's
-- B.icons: picker.lua iterates that table to build its selectable row,
-- and this icon showing up as a 6th "choosable emoji" there would be a
-- real bug, not a cosmetic one. Twemoji's "heavy plus sign" (U+2795,
-- 2795.svg), converted the same way as every other icon -- see
-- ROADMAP.md §1.4/README.md "Art credits".
local MARKER_ICON = "|TInterface\\AddOns\\Bubble\\textures\\add:16|t"

-- ROADMAP §1.1: append a custom hyperlink to every eligible message before
-- it hits the chat frame, and hook SetItemRef (the dispatcher every
-- hyperlink click already goes through) to catch clicks on it.
--
-- Verified against a live pfUI checkout before writing this: pfUI hooks
-- ChatFrame:AddMessage and SetItemRef the same way -- save whatever's
-- currently installed, call through at the end, never a full replacement
-- -- and does so more than once in its own codebase without conflict. This
-- follows the identical pattern, so it chains onto pfUI (or nothing)
-- either way.

-- CONFIRMED ON LIVE CLIENT (2026-09-29): an earlier version of this hook
-- checked a "pending" snapshot taken by a handler on a SEPARATE frame
-- (our own event dispatcher), reasoning that it would always run before
-- AddMessage for the same event. On a busy channel (World chat) that's
-- false -- see core/identity.lua's comment for the full incident. The fix
-- is to read event/arg1/arg2 DIRECTLY here instead: those globals are set
-- by the client for whichever event is CURRENTLY being dispatched, valid
-- for every frame handling that exact occurrence, so there is no
-- cross-frame ordering to depend on when the read happens in the same
-- call that's rendering the message.
--
-- That reintroduces the ORIGINAL worry this file used to solve a
-- different way: an unrelated AddMessage call (core/reactions.lua's own
-- pill line, or another addon's status message) could pick up stale
-- leftover globals from some earlier event. Two guards now cover that
-- instead of timing: `suppressTagging` is set explicitly by
-- core/reactions.lua around its own known self-call (deterministic, not a
-- heuristic), and for everything else, requiring the rendered text to
-- actually CONTAIN arg1 verbatim as a substring is a strong enough filter
-- on its own -- the odds of an unrelated string coincidentally containing
-- a prior chat message's exact wording are vanishingly small.
local suppressTagging = false
function B.chat.SetSuppressTagging(v)
  suppressTagging = v
end

-- AddMessage's own args (text, r, g, b, and whatever trailing extras a
-- given caller passes -- pfUI's own hook forwards as many as 17) are
-- captured the Lua 5.0 way, via the implicit `arg` table from `(...)`, and
-- forwarded with unpack(arg, 1, arg.n) so nothing gets silently dropped by
-- guessing a fixed arity. Note this function's own `arg` (its vararg table)
-- is unrelated to the globals `arg1`/`arg2` from hard rule #6 (a CHAT_MSG_*
-- event's text/sender) -- same name, different thing, and this hook DOES
-- read those globals directly, per the comment above.
local function AddMessageWrapper(frame, ...)
  local text = arg[1]
  if not text then
    return frame.BubbleOriginalAddMessage(frame, unpack(arg, 1, arg.n))
  end

  -- CONFIRMED ON LIVE CLIENT (2026-09-29): arg1 for a message containing
  -- "%" arrives DOUBLED at the protocol level ("%%" for a literal "%"
  -- someone typed once), while the rendered `text` this hook sees has
  -- already been un-escaped back to a single "%" -- likely a defense
  -- somewhere in the client/network layer against chat text later being
  -- used as a string.format pattern. rawText undoes that same doubling so
  -- the substring match (and the message key, which needs to be stable
  -- and match what's actually displayed) line up with what's on screen.
  local eligible = not suppressTagging and B.identity.IsEligible(event) and arg1 and arg2
  local rawText = eligible and string.gsub(arg1, "%%%%", "%%")
  local matched = eligible and string.find(text, rawText, 1, true)

  if matched then
    local key = B.identity.MakeKey(arg2, B.identity.ChannelComponent(), rawText)
    B.identity.Remember(key)
    B.reactions.RememberFrame(key, frame)
    B.reactions.RememberOrigin(key, arg2, rawText)

    -- ROADMAP §2.2: with more than one possible emoji, this marker can no
    -- longer mean "toggle thumbsup" -- it opens the picker so the click
    -- can choose. It's deliberately just MARKER_ICON always, not a
    -- per-emoji toggle state (core/reactions.lua's pill lines already show
    -- per-emoji state once something's been picked). The link carries no
    -- emoji at all (`bubble:KEY`, no trailing `:emoji`) -- see
    -- HookSetItemRef below for how that's told apart from a pill's own
    -- `bubble:KEY:emoji` link.
    --
    -- No space before the marker, on purpose: chat only wraps at spaces, so
    -- " " + a texture escape let the marker land alone as the first thing
    -- on a wrapped line. Glued to the last word, it wraps WITH that word.
    -- The visible gap comes from transparent padding baked into
    -- textures/add.tga instead of a space.
    arg[1] = text .. "|Hbubble:" .. key .. "|h" .. MARKER_ICON .. "|h"
  end

  return frame.BubbleOriginalAddMessage(frame, unpack(arg, 1, arg.n))
end

-- Never reuse pfUI's own sentinel field name (frame.HookAddMessage) for our
-- saved original -- pfUI/modules/chat.lua uses that exact field to guard
-- its own one-time hook install; reusing it collides with pfUI's
-- bookkeeping, not just cosmetically.
local function HookFrame(frame)
  if not frame or frame.BubbleOriginalAddMessage then return end
  frame.BubbleOriginalAddMessage = frame.AddMessage
  frame.AddMessage = function(self, ...)
    return AddMessageWrapper(self, unpack(arg, 1, arg.n))
  end
end

local originalSetItemRef = nil

local function HookSetItemRef()
  if originalSetItemRef then return end
  originalSetItemRef = SetItemRef
  _G.SetItemRef = function(link, text, button)
    if string.sub(link, 1, 7) == "bubble:" then
      local rest = string.sub(link, 8)
      local colon = string.find(rest, ":", 1, true)
      if colon then
        -- bubble:KEY:EMOJI -- a pill's own link (core/reactions.lua's
        -- RenderPill). Left-click quick-toggles that specific emoji;
        -- right-click opens the picker to choose a different one instead.
        local key = string.sub(rest, 1, colon - 1)
        local emoji = string.sub(rest, colon + 1)
        if button == "RightButton" then
          B.picker.Open(key)
        else
          B.reactions.ToggleMine(key, emoji)
        end
      else
        -- bubble:KEY -- the original message's generic marker (no emoji
        -- chosen yet), either click just opens the picker.
        B.picker.Open(rest)
      end
      return
    end
    originalSetItemRef(link, text, button)
  end
end

-- Installed from PLAYER_ENTERING_WORLD, not file scope, so this chains on
-- top of whatever pfUI (or nothing) has already installed by the time we
-- run, rather than racing pfUI's own module init.
B.RegisterEvent("PLAYER_ENTERING_WORLD", function()
  for i = 1, NUM_CHAT_WINDOWS do
    HookFrame(_G["ChatFrame" .. i])
  end
  HookSetItemRef()
end)
