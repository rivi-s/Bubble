Bubble = Bubble or {}
local B = Bubble
B.reactions = {}
local R = B.reactions

-- ROADMAP §1.4: reaction icons are textures, not Unicode -- 1.12's client
-- font has no color-emoji glyphs. Converted from Twemoji via
-- tools/svg2tga.sh (see README.md "Art credits" for attribution). All five
-- are choosable now via core/picker.lua (§2.2).
B.icons = {
  thumbsup = "|TInterface\\AddOns\\Bubble\\textures\\thumbsup:16|t",
  heart    = "|TInterface\\AddOns\\Bubble\\textures\\heart:16|t",
  laugh    = "|TInterface\\AddOns\\Bubble\\textures\\laugh:16|t",
  wow      = "|TInterface\\AddOns\\Bubble\\textures\\wow:16|t",
  sad      = "|TInterface\\AddOns\\Bubble\\textures\\sad:16|t",
}

-- ROADMAP §2.3: one reaction per person per emoji per message -- set
-- membership, not a click counter. state[key][emoji] is a set of reactor
-- names; the displayed count is the set's size.
-- state[key] = { [emoji] = { [reactorName] = true, ... }, ... }
local state = {}

local function EnsureEmojiSet(key, emoji)
  state[key] = state[key] or {}
  state[key][emoji] = state[key][emoji] or {}
  return state[key][emoji]
end

function R.Count(key, emoji)
  local set = state[key] and state[key][emoji]
  if not set then return 0 end
  local n = 0
  for _ in pairs(set) do n = n + 1 end
  return n
end

function R.HasReacted(key, emoji, name)
  local set = state[key] and state[key][emoji]
  return set ~= nil and set[name] == true
end

-- For core/hover.lua's tooltip on the original message's generic marker
-- (bubble:KEY, no emoji) -- which emoji actually have a nonzero count on
-- this message, sorted for a stable display order. A key can have MULTIPLE
-- active emoji now that §2.2's picker exists, unlike Phase 1's single
-- hardcoded thumbsup.
function R.ActiveEmojis(key)
  local list = {}
  if not state[key] then return list end
  for emoji, set in pairs(state[key]) do
    local hasAny = false
    for _ in pairs(set) do
      hasAny = true
      break
    end
    if hasAny then table.insert(list, emoji) end
  end
  table.sort(list)
  return list
end

-- For core/hover.lua's tooltip -- who's reacted, not just how many.
function R.ReactorNames(key, emoji)
  local set = state[key] and state[key][emoji]
  local names = {}
  if not set then return names end
  for name in pairs(set) do
    table.insert(names, name)
  end
  return names
end

local function ApplyLocal(key, emoji, name, added)
  local set = EnsureEmojiSet(key, emoji)
  if added then
    set[name] = true
  else
    set[name] = nil
  end
end

-- SECURITY: `key`/`emoji` are untrusted whenever they arrive from a
-- CLICKED hyperlink or the hidden channel -- NOT just from our own
-- broadcasts. WoW's client renders any |H...|h...|h sequence in ANY
-- displayed chat text as a real clickable link, regardless of who wrote
-- it -- so a plain typed message in ordinary public chat can contain a
-- hand-crafted bubble:KEY:EMOJI link, no addon-comm channel needed at
-- all. And our hidden channel (core/channel.lua) has no access control --
-- it's a normal WoW channel, anyone can /join it and send crafted
-- BubbleRx:ADD:... text directly. Without validation, an attacker-chosen
-- `emoji` gets concatenated straight into a NEW hyperlink we generate for
-- the pill (RenderPill below), which could break out of the intended
-- |Hbubble:KEY:EMOJI|h structure and inject something else entirely (a
-- fake url: link, say) that other players see rendered as if it came from
-- us. ToggleMine/ApplyRemote are the one place every mutation path
-- (a local click, a picker choice, a remote broadcast) funnels through,
-- so validating here covers all of them at once rather than duplicating
-- checks in core/chat.lua and core/channel.lua separately.
local function IsValidEmoji(emoji)
  return B.icons[emoji] ~= nil -- whitelist, not a shape/length check
end

-- ID.MakeKey (core/identity.lua) only ever produces tostring(number) --
-- decimal digits, capped well under 11 characters (math.mod's modulus is
-- 2147483647). Anything else arriving as `key` is not a key we generated,
-- whatever produced it.
local function IsValidKey(key)
  return type(key) == "string" and string.len(key) <= 10 and string.find(key, "^%d+$") ~= nil
end

-- knownFrames: which chat frame(s) a key was tagged on.
-- originOf: who said the reacted-to message, and a short snippet of what
-- -- so the pill line stays unambiguous even if other messages interleave
-- between the original message and someone reacting to it. Both declared
-- here, together, BEFORE TouchKey below -- TouchKey's body references
-- both, and a local referenced above its own declaration silently
-- resolves to a global instead (nil, in this case) rather than erroring
-- at load time, so this ordering is load-bearing, not cosmetic.
local knownFrames = {}
local originOf = {}
local SNIPPET_MAX = 40

-- SECURITY / memory hygiene: knownFrames and originOf get an entry for
-- EVERY eligible message ever displayed (core/chat.lua tags on arrival,
-- before anyone reacts) -- not just ones that get a reaction. That's
-- unbounded growth from ordinary busy-channel traffic alone, no attacker
-- required, and it compounds if someone deliberately floods distinct fake
-- keys (see core/channel.lua's rate limit for the other half of that).
-- Bounded here with simple oldest-first eviction across all three tables
-- together (state/originOf/knownFrames all share the same key, so they
-- need to stay in sync) -- not true LRU, just first-touched order, which
-- is a fine approximation since relevance already decays as a message
-- scrolls out of the log anyway.
local MAX_TRACKED_KEYS = 500
local keyOrder = {}
local keyOrderSet = {}

local function TouchKey(key)
  if keyOrderSet[key] then return end
  keyOrderSet[key] = true
  table.insert(keyOrder, key)
  if table.getn(keyOrder) > MAX_TRACKED_KEYS then
    local evict = table.remove(keyOrder, 1)
    keyOrderSet[evict] = nil
    state[evict] = nil
    originOf[evict] = nil
    knownFrames[evict] = nil
  end
end

function R.RememberFrame(key, frame)
  TouchKey(key)
  knownFrames[key] = knownFrames[key] or {}
  knownFrames[key][frame] = true
end

-- SECURITY: the message being quoted was typed by whoever sent it -- ANY
-- player, not necessarily a trustworthy one. `|` is WoW's own escape-code
-- trigger (|c, |H, |r, |T...), and a message containing one, quoted back
-- verbatim into a NEW rendered string (the pill, core/overlay.lua's
-- label), could inject a fake link or malformed sequence into text that
-- reads as if it came from us. Doubling every `|` to `||` is WoW's own
-- documented escape for a literal pipe -- neutralizes this at the one
-- place raw message text gets turned into something we redisplay, rather
-- than trusting every consumer to do it themselves.
local function EscapePipes(s)
  return string.gsub(s or "", "|", "||")
end

function R.RememberOrigin(key, sender, text)
  TouchKey(key)
  if originOf[key] then return end -- first tag wins; text doesn't change per key
  local snippet = text
  if string.len(snippet) > SNIPPET_MAX then
    snippet = string.sub(snippet, 1, SNIPPET_MAX) .. "..."
  end
  originOf[key] = { sender = EscapePipes(sender), snippet = EscapePipes(snippet) }
end

-- Called when the local player clicks a reaction link (either the
-- original message's marker or a pill's own link -- both route here).
-- `key`/`emoji` may have come straight from a clicked hyperlink -- see the
-- SECURITY note on IsValidEmoji/IsValidKey above for why they're not
-- trusted just because a click reached this far.
function R.ToggleMine(key, emoji)
  if not (IsValidKey(key) and IsValidEmoji(emoji)) then return end
  local me = UnitName("player")
  local wasReacted = R.HasReacted(key, emoji, me)
  ApplyLocal(key, emoji, me, not wasReacted)
  B.channel.Broadcast(key, emoji, not wasReacted)
  R.RenderPill(key, emoji)
  if B.overlay then B.overlay.ShowEvent(emoji, originOf[key]) end
end

-- Called from core/channel.lua when a remote ADD/DEL arrives -- the
-- hidden channel has no access control, so this is untrusted input every
-- bit as much as a clicked hyperlink. Same validation, same reason.
function R.ApplyRemote(sender, key, emoji, added)
  if not (IsValidKey(key) and IsValidEmoji(emoji)) then return end
  ApplyLocal(key, emoji, sender, added)
  R.RenderPill(key, emoji)
  if B.overlay then B.overlay.ShowEvent(emoji, originOf[key]) end
end

-- ROADMAP §1.2: no way to mutate an existing chat line or anchor a
-- persistent badge to it on 1.12, so a reaction renders as a new line
-- below the original -- it reads as "the latest tally," not an in-place
-- pill. Critically, the pill line carries its own bubble: hyperlink, so
-- clicking IT goes through the exact same SetItemRef hook as the original
-- message (see core/chat.lua) -- left-click quick-toggles this specific
-- emoji, right-click opens §2.2's picker instead.
--
-- CONFIRMED ON LIVE CLIENT (2026-09-29): this used to always target
-- DEFAULT_CHAT_FRAME, which put the pill in the wrong window for any
-- message pfUI routes off ChatFrame1 (World/Trade/etc. land on ChatFrame3,
-- "Loot & Spam"). Fixed by rendering on whichever frame(s) this key was
-- actually tagged on (knownFrames above), falling back to
-- DEFAULT_CHAT_FRAME only if we never saw it tagged anywhere ourselves.
-- CONFIRMED USEFUL ON LIVE CLIENT (2026-09-29): a bare "icon count" pill
-- reads as ambiguous once other messages land between the original message
-- and the reaction -- nothing ties the two together by eye. Appending who
-- said the reacted-to message and a snippet of it (originOf above) fixes
-- that without needing anything 1.12 can't do. Plain ">" as the
-- connector, not a Unicode arrow -- this client's font already proved
-- unreliable for anything past basic Latin (see §1.4's whole emoji saga).
-- CONFIRMED live (2026-09-29): the pill line was crowding out real chat
-- once core/overlay.lua existed as a lighter always-visible alternative --
-- see ROADMAP.md. B.config.Get("showPills") gates ONLY the AddMessage
-- call below -- count/state/originOf/knownFrames all stay fully tracked
-- regardless, so turning this off never costs any actual functionality,
-- only the extra chat line. Default is off (core/config.lua); /bubble
-- pills on to restore it.
function R.RenderPill(key, emoji)
  local count = R.Count(key, emoji)
  if count <= 0 then return end -- last remover: nothing left worth showing
  if not B.config.Get("showPills") then return end
  local icon = B.icons[emoji] or ""
  local text = "  |cffffff00|Hbubble:" .. key .. ":" .. emoji .. "|h" ..
               icon .. " " .. count .. "|h|r"

  local origin = originOf[key]
  if origin then
    text = text .. "  |cff888888> " .. origin.sender .. ": " .. origin.snippet .. "|r"
  end

  -- core/chat.lua's AddMessage hook now reads event/arg1/arg2 directly
  -- (see its comment for why), which means THIS call -- not driven by any
  -- live CHAT_MSG_* event -- must not be mistaken for one. Suppress
  -- explicitly around it rather than relying on the substring check alone.
  B.chat.SetSuppressTagging(true)
  local frames = knownFrames[key]
  if frames then
    for f in pairs(frames) do
      f:AddMessage(text)
    end
  else
    DEFAULT_CHAT_FRAME:AddMessage(text)
  end
  B.chat.SetSuppressTagging(false)
end
