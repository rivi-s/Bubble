Bubble = Bubble or {}
local B = Bubble
B.channel = {}
local CH = B.channel

-- ROADMAP §0.1: an obscure hidden-channel name, joined the same way
-- LFG/trade-relay addons do. There's no negotiation protocol for this --
-- every Bubble install just compiles in the same constant. If it ever
-- collides with a real channel someone creates, the fix is to change this
-- string in a release, not to invent naming at runtime.
local CHANNEL_NAME = "BubbleReact29483"

-- CONFIRMED ON LIVE CLIENT (2026-09-29): SendAddonMessage with chat type
-- "CHANNEL" throws "Unknown addon chat type" on this client -- addon
-- messages apparently only work over the fixed group types (GUILD, PARTY,
-- RAID, WHISPER, ...), not an arbitrary joined channel. So this sends
-- plain chat text over the hidden channel instead (the original §0.1 plan,
-- before an in-progress "refinement" assumed SendAddonMessage would work
-- here -- it doesn't, on this client). Every payload carries WIRE_PREFIX so
-- it's unambiguous even though it's not going through the addon-message
-- system, and the channel's display is stripped from every chat frame
-- (HideChannelDisplay) so the raw protocol text never shows up as regular
-- chat.
--
-- CONFIRMED ON LIVE CLIENT (2026-09-29): the prefix originally used "|" as
-- its delimiter ("BubbleRx|") and SendChatMessage rejected it --
-- SuperCleveRoidMacros (installed in the test client) hooks SendChatMessage
-- and validates for well-formed escape sequences, and "|" is WoW's own
-- escape-code character (|c, |H, |r, |T...). A literal "|" not forming one
-- of those is an "Invalid escape code in chat message" as far as that
-- validator is concerned. Lesson for any future wire-format change: never
-- put a literal "|" in outgoing chat text unless it's a deliberate,
-- well-formed WoW escape sequence -- ":" has no such meaning and is what
-- the rest of this payload already uses.
local WIRE_PREFIX = "BubbleRx:"

-- CONFIRMED ON LIVE CLIENT (2026-09-29): arg4's channel-name casing doesn't
-- reliably match what JoinChannelByName was called with -- a two-character
-- test saw arg4 = "1. Bubblereact29483" (lowercase "r") against our own
-- CHANNEL_NAME = "BubbleReact29483" (capital "R"), which made a
-- case-sensitive match silently drop every incoming reaction: the sender's
-- own broadcast echoed back to them (correctly ignored via the
-- self-message guard below) while the *other* character's copy failed the
-- channel filter and was dropped, with no error -- just a reaction that
-- never showed up. Apparent cause: channel names are case-insensitive for
-- joining, and the display casing the server reports back is whatever the
-- channel already existed as, not necessarily what this client requested.
-- Fixed by comparing lowercased.
local CHANNEL_NAME_LOWER = string.lower(CHANNEL_NAME)

-- Never hardcoded: channel numbers are assigned per-session and drift, so
-- this is re-resolved by name every time we might need it, never cached
-- across a zone/reload boundary without re-checking.
local currentId = nil

local function ResolveId()
  local id = GetChannelName(CHANNEL_NAME)
  if id and id > 0 then
    currentId = id
  else
    currentId = nil
  end
  return currentId
end

local function HideChannelDisplay()
  for i = 1, NUM_CHAT_WINDOWS do
    ChatFrame_RemoveChannel(_G["ChatFrame" .. i], CHANNEL_NAME)
  end
end

-- Rejoin on every PLAYER_ENTERING_WORLD, not just login -- zoning and
-- /reload can silently drop a joined channel on this client.
function CH.EnsureJoined()
  ResolveId()
  if not currentId then
    JoinChannelByName(CHANNEL_NAME)
    ResolveId()
  end
  if currentId then
    HideChannelDisplay()
  end
  return currentId ~= nil
end

-- Fire-and-forget by design (§0.1): no ack, no retry. A dropped reaction
-- is an accepted failure mode, not a bug to chase.
function CH.Broadcast(key, emoji, added)
  if not currentId and not CH.EnsureJoined() then
    return false
  end
  local verb = added and "ADD" or "DEL"
  local payload = WIRE_PREFIX .. verb .. ":" .. key .. ":" .. emoji
  SendChatMessage(payload, "CHANNEL", nil, currentId)
  return true
end

B.RegisterEvent("PLAYER_ENTERING_WORLD", function()
  if CH.EnsureJoined() then
    -- §0.2 presence handshake stub. Nothing consumes "HI" yet -- see the
    -- CHAT_MSG_CHANNEL handler below -- this exists so the wire format is
    -- settled before a roster UI is built on top of it.
    SendChatMessage(WIRE_PREFIX .. "HI:" .. B.version, "CHANNEL", nil, currentId)
  end
end)

-- SECURITY: this hidden channel has no access control -- it's a normal
-- WoW channel, joinable by anyone who knows or guesses the name, addon or
-- not. Nothing stops a hostile client from sending as fast as its own
-- SendChatMessage throttle allows, and every message we accept costs
-- table growth downstream (core/reactions.lua's TouchKey caps the total,
-- but a single sender flooding distinct keys would still evict everyone
-- else's legitimate entries faster than organic traffic would). Rate
-- limiting per SENDER, not globally -- a global cap would let one hostile
-- client silently suppress everyone else's real reactions too, which is
-- worse than doing nothing.
local RATE_LIMIT_WINDOW = 5  -- seconds
local RATE_LIMIT_MAX = 10    -- max accepted messages per sender per window
local senderWindow = {}      -- sender -> { count = n, start = GetTime() }

local function IsRateLimited(sender)
  local now = GetTime()
  local rec = senderWindow[sender]
  if not rec or now - rec.start >= RATE_LIMIT_WINDOW then
    senderWindow[sender] = { count = 1, start = now }
    return false
  end
  rec.count = rec.count + 1
  return rec.count > RATE_LIMIT_MAX
end

-- CONFIRMED ON LIVE CLIENT (2026-09-29): arg4 is the channel name for
-- CHAT_MSG_CHANNEL (format "1. Bubblereact29483"), matching what
-- core/identity.lua's ChannelComponent assumes -- confirmed via the
-- case-sensitivity bug above, not just documentation.
B.RegisterEvent("CHAT_MSG_CHANNEL", function()
  if not arg4 or string.find(string.lower(arg4), CHANNEL_NAME_LOWER, 1, true) == nil then return end
  if not arg1 or string.sub(arg1, 1, string.len(WIRE_PREFIX)) ~= WIRE_PREFIX then return end
  if arg2 == UnitName("player") then return end -- ignore our own message, if the server echoes it back
  if IsRateLimited(arg2) then return end -- silently drop; no ack/nak protocol to tell them why

  local rest = string.sub(arg1, string.len(WIRE_PREFIX) + 1)
  local colon = string.find(rest, ":", 1, true)
  if not colon then return end
  local verb = string.sub(rest, 1, colon - 1)
  local rest2 = string.sub(rest, colon + 1)

  if verb == "ADD" or verb == "DEL" then
    local c2 = string.find(rest2, ":", 1, true)
    if not c2 then return end
    local key = string.sub(rest2, 1, c2 - 1)
    local emoji = string.sub(rest2, c2 + 1)
    B.reactions.ApplyRemote(arg2, key, emoji, verb == "ADD")
  end
  -- "HI" (presence) intentionally unhandled for now -- see the §0.2 stub
  -- note above; a roster UI is what would give it a reason to exist.
end)
