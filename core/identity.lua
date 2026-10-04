Bubble = Bubble or {}
local B = Bubble
B.identity = {}
local ID = B.identity

-- ROADMAP §0.3: which CHAT_MSG_* events are eligible for reactions.
-- WHISPER is deliberately excluded -- broadcasting a hash of a whisper's
-- sender+text over the hidden channel would leak metadata about a private
-- conversation to anyone else on that channel, even hashed. Anything not
-- a real player chat event (system/addon/combat/loot/skill/...) is
-- excluded because AddMessage also fires for those outside any CHAT_MSG_*
-- event, where the event/arg1/arg2 globals would be stale leftovers from
-- whatever last actually fired.
local ELIGIBLE_EVENTS = {
  CHAT_MSG_SAY          = true,
  CHAT_MSG_YELL         = true,
  CHAT_MSG_EMOTE        = true,
  CHAT_MSG_PARTY        = true,
  CHAT_MSG_PARTY_LEADER = true,
  CHAT_MSG_GUILD        = true,
  CHAT_MSG_OFFICER      = true,
  CHAT_MSG_RAID         = true,
  CHAT_MSG_RAID_LEADER  = true,
  CHAT_MSG_CHANNEL      = true,
}

function ID.IsEligible(evt)
  return ELIGIBLE_EVENTS[evt] == true
end

-- For CHAT_MSG_CHANNEL, two different channels (Trade vs General) can carry
-- the same sender+text at the same moment; arg4 (channel name) tells them
-- apart. Every other eligible event uses its own event name as the
-- "channel" component, which is already a fine differentiator (SAY vs
-- YELL vs GUILD naturally differ).
-- VERIFY ON LIVE CLIENT: arg4 is documented as channelName for
-- CHAT_MSG_CHANNEL across vanilla API references; confirm against this
-- client specifically.
function ID.ChannelComponent()
  if event == "CHAT_MSG_CHANNEL" then
    return arg4 or event
  end
  return event
end

-- Cheap string hash (Lua 5.0 has no bit ops to speak of; a plain
-- polynomial hash over string.byte is enough -- collisions are already an
-- accepted, cosmetic-only case per §0.3, same posture as transport in §0.1).
local function HashString(s)
  local h = 5381
  local len = string.len(s)
  for i = 1, len do
    h = math.mod(h * 33 + string.byte(s, i), 2147483647)
  end
  return h
end

-- CONFIRMED ON LIVE CLIENT (2026-09-29): this returned a Lua NUMBER
-- (HashString's arithmetic result) for a long time, which is fine
-- wherever the key only ever gets *embedded in text* (the hyperlink, the
-- wire protocol) and read back via string.sub -- Lua coerces the number
-- to its decimal string automatically on ".." concatenation. But
-- core/reactions.lua's knownFrames table was keyed directly by whatever
-- RememberFrame(key, frame) received -- the raw NUMBER, straight from
-- MakeKey inside core/chat.lua's AddMessage hook -- while every READ of
-- that table came from R.RenderPill(key, ...), whose `key` always arrives
-- as a STRING (parsed out of a clicked hyperlink or the wire protocol).
-- `t[896802728]` and `t["896802728"]` are different table entries in Lua
-- -- no implicit coercion for indexing, only for concatenation -- so every
-- write was invisible to every read. Debug output showed this directly:
-- a RememberFrame call immediately followed by a RenderPill lookup for
-- the identical key still reported "NONE". Returning a string here makes
-- the key one consistent type from creation all the way through.
function ID.MakeKey(sender, channelComponent, text)
  return tostring(HashString((sender or "") .. "\30" .. (channelComponent or "") .. "\30" .. (text or "")))
end

-- CONFIRMED ON LIVE CLIENT (2026-09-29): an earlier version of this file
-- took a "snapshot" of event/arg1/arg2 from a SEPARATE handler registered
-- on our own dispatcher frame, reasoning that AddMessage runs synchronously
-- within the same event dispatch. That's true for a single isolated event,
-- but WRONG under load: on a busy channel (World chat, LFG spam), multiple
-- CHAT_MSG_CHANNEL occurrences can arrive in the same client tick, and
-- frame dispatch order across DIFFERENT frames for a burst of events is not
-- "per-event, all frames" -- it's apparently "per-frame, all its queued
-- events," so ChatFrame3's own AddMessage calls for several messages can
-- all run before OUR dispatcher frame gets to process any of them. A real
-- test caught this exactly: AddMessage fired for a message from "Hotani"
-- while our snapshot still held an unrelated earlier message from someone
-- else, and by the time our own snapshot for Hotani's message ran, it was
-- already too late.
--
-- The fix: read event/arg1/arg2 DIRECTLY inside the AddMessage hook
-- itself (core/chat.lua), not from a separately-dispatched snapshot. Those
-- globals are set by the client for whichever event is CURRENTLY being
-- dispatched, valid for every frame processing that exact occurrence --
-- there is no cross-frame ordering dependency when the read happens in the
-- same call that's rendering the message. ID.IsEligible + a check that the
-- rendered text actually contains arg1 as a substring is what makes this
-- safe against the original worry (an unrelated later AddMessage call,
-- e.g. core/reactions.lua's own pill line, picking up stale leftover
-- globals): the odds of an unrelated string coincidentally CONTAINING a
-- prior message's exact text verbatim are vanishingly small, and
-- core/chat.lua additionally suppresses tagging explicitly around its own
-- known self-call rather than leaning on that alone.

-- Short-lived ring buffer of keys we've actually seen locally, so a
-- reaction pill doesn't get rendered for a key nobody nearby has actually
-- seen (e.g. a stray broadcast from someone out of range). Not used yet to
-- gate anything hard in Phase 1 -- see core/chat.lua -- but kept here so
-- the eventual "did I actually see this message" check has a home.
local recent = {}
local RECENT_TTL = 60

function ID.Remember(key)
  recent[key] = GetTime() + RECENT_TTL
end

function ID.IsRecent(key)
  local exp = recent[key]
  if not exp then return false end
  if exp < GetTime() then
    recent[key] = nil
    return false
  end
  return true
end

-- Bounds memory growth; call periodically (e.g. off a slow OnUpdate tick)
-- once something drives it. Not wired to anything yet in Phase 1.
function ID.Prune()
  local now = GetTime()
  for k, exp in pairs(recent) do
    if exp < now then recent[k] = nil end
  end
end
