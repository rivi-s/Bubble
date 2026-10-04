# Roadmap

What Bubble needs to solve before it's real, phased by dependency. Items
marked **Decided** are settled; **Open** items need a call before code starts
on anything that depends on them. Don't build ahead of an Open item that
blocks it.

---

## Phase 0 — Protocol foundations

Nothing in later phases works without these three pieces. All of it is
plumbing; none of it is user-visible.

### 0.1 Transport: hidden channel — **Decided**
Broadcast reactions over a `JoinChannel`'d hidden channel (the same trick
LFG/trade-relay addons use), not guild/party/raid — that's the only way to
reach any nearby addon user regardless of group membership.

Rules that follow from how fragile this mechanism is on 1.12:
- **Never hardcode a channel number.** Numbers are assigned per-session and
  drift; always resolve the channel by name via `GetChannelName`.
- **Rejoin on every `PLAYER_ENTERING_WORLD`**, not just login — zoning and
  `/reload` can silently drop a joined channel.
- **No ack/retry.** Vanilla addon comm is fire-and-forget and the client
  throttles bursts silently. A dropped reaction is an acceptable failure
  mode — chasing guaranteed delivery here is a rabbit hole, not a feature.
- **Rate-limit outgoing reactions per player** (e.g. N per message, cooldown
  between sends) so normal use can't trip the client's chat throttle.

**Superseded by a live-client test — plain `SendChatMessage`/`CHAT_MSG_CHANNEL`
it is.** An earlier pass at this doc proposed `SendAddonMessage(prefix,
payload, "CHANNEL", id)` / `CHAT_MSG_ADDON` instead, reasoning that both
sides of a reaction always have Bubble anyway, so there was no need for
plain chat text. **Testing on the HDBDEV client (2026-09-29) found
`SendAddonMessage` throws `"Unknown addon chat type"` for chat type
`"CHANNEL"` on this client** — addon messages apparently only work over the
fixed group types (GUILD/PARTY/RAID/WHISPER/...), not an arbitrary joined
channel. So the original plan stands: plain `SendChatMessage`/
`CHAT_MSG_CHANNEL`, every payload tagged with a literal wire prefix
(`BubbleRx:`) since there's no separate addon-prefix field this way, and the
channel's display stripped from every chat frame via
`ChatFrame_RemoveChannel` so the raw protocol text never shows up as regular
chat. See `core/channel.lua`. Worth remembering this failed even though it
was reasoned out carefully beforehand — some of this client's API surface
just doesn't match documented/expected vanilla behavior, which is exactly
why the roadmap keeps flagging things `VERIFY ON LIVE CLIENT` rather than
trusting API docs alone.

**Second live-client bug, same test session:** the wire prefix originally
used `|` as its delimiter (`BubbleRx|`), and `SendChatMessage` rejected it —
SuperCleveRoidMacros (installed in the test client) hooks `SendChatMessage`
and validates escape sequences, and `|` is WoW's own escape-code character
(`|c`, `|H`, `|r`, `|T`...). Fixed by switching the delimiter to `:`
(`BubbleRx:`), which has no special meaning to WoW's text formatting and is
already what the rest of the payload uses. General rule going forward:
**never put a literal `|` in outgoing chat text** unless it's a deliberate,
well-formed WoW escape sequence.

**Third live-client bug, same test session — the actual cross-character
blocker:** with two characters ("Rivo" and a second) both confirmed joined
(`Bubble DEBUG: joined channel id = 1` on both) and the broadcast confirmed
sent (`ok=true`), the second character's debug log showed it **did**
receive the `CHAT_MSG_CHANNEL` event with the right payload — but the
reaction still never applied. Cause: `arg4` came back as
`"1. Bubblereact29483"` (lowercase `r`) against our own `CHANNEL_NAME`
constant `"BubbleReact29483"` (capital `R`), and the channel-match filter
was a case-sensitive substring check. `GetChannelName`/`JoinChannelByName`
themselves are apparently case-insensitive (both characters correctly
resolved the same channel id despite the casing mismatch), but the display
name the server reports back is whatever the channel already existed as —
not necessarily the casing this client's join requested. Fixed by
lowercasing both sides of the comparison in `core/channel.lua`. This was
the one silently dropping every cross-character reaction — no error, no
signal, the message just never applied, which is exactly why the debug
instrumentation (rather than guessing from the design alone) was what
found it.

**Fourth bug — self-inflicted, in the debugging itself, and a real lesson
about the hook:** investigating a separate report (World-channel messages
not getting tagged) added a debug print inside `AddMessageWrapper` that
called `DEFAULT_CHAT_FRAME:AddMessage(...)` directly from inside the hook.
That crashed the client with a stack overflow — not from a chat message at
all, but from an XP-gained notification, via a recursion loop through
pfUI's `modules/chatcopy.lua` (which also hooks `AddMessage`). The debug
`:AddMessage` call re-entered the *entire* hook chain, including our own
wrapper, while the `event` global hadn't changed yet — so the same
`if event == "CHAT_MSG_CHANNEL"` condition matched again inside the
re-entrant call, printed again, re-entered again, forever. **Never call
`:AddMessage()` (on any frame) from inside `AddMessageWrapper` itself** —
that's the general rule this incident establishes, not just a debugging
footgun: any future feature that wants to emit a message in response to a
message being displayed needs to do it outside the hook's own call stack
(a deferred call, a different trigger entirely), never synchronously from
inside it. `core/reactions.lua`'s `RenderPill` is safe as written only
because it's invoked from `SetItemRef`/the channel handler, never from
inside `AddMessageWrapper` — that boundary needs to stay intact. Debugging
this class of hook safely from here on uses a table (`B.debugLog`) dumped
on demand via a `/bubbledebug` slash command, never a live print from
inside the hook.

### 0.2 Presence handshake — **Decided**
On join, broadcast a small "I have Bubble vX" message on the hidden
channel and keep a short-lived roster of who responded. This is what lets
the UI show "no one nearby has this yet" instead of silently doing nothing,
which matters for the adoption story — people need to see it's not just
inert.

### 0.3 Message identity — **Decided**
Vanilla chat has no message IDs, so a reaction has to name *which* message
it's for using only data every client already has. Two candidate approaches,
and the tradeoff isn't what it first looked like:

- **Heuristic keying (works on anyone's messages):** every client
  independently derives the same key from the message itself when it
  arrives — no cooperation from the sender required.
- **Cooperative tagging (exact, addon-to-addon only):** the sender's client
  additionally hooks its own outgoing `SendChatMessage` path to broadcast a
  per-message nonce. This was originally assumed to be the *smaller* first
  slice (Phase 1.3 below used to say so); it's actually the larger one — it
  needs an entire second hook surface (the send path) that heuristic keying
  doesn't, for a payoff (exact, collision-free IDs) that only matters
  between two Bubble users in the first place.

**Decision: heuristic keying only, for now.** Key = a hash of
`sender + channelKind/channelName + rawText`, computed from the **raw
`CHAT_MSG_*` event globals** (`arg2` = sender, `arg1` = message text) —
**never from the rendered `AddMessage` text**, because pfUI (timestamps,
class-color, bracket style) and any per-viewer config rewrite that text
differently on every client, which would desync the hash across viewers
computing it from their own screen.

Two refinements past the naive version:
- **No time-bucketing in the key itself.** Clock/network jitter between two
  clients receiving the "same" server broadcast can straddle a bucket
  boundary. Instead, keep a short-lived (~60s) per-key ring buffer of recent
  matches and let a reaction attach to the most recent unmatched instance of
  that key — the residual case (identical repeated text within the window,
  e.g. spammed emotes) is an accepted, cosmetic-only collision, consistent
  with the "best-effort, not guaranteed" posture already set for transport
  in §0.1.
- **Event-type allowlist, and WHISPER is excluded on purpose.** Only
  SAY/YELL/EMOTE/PARTY/GUILD/RAID/CHANNEL messages are eligible for
  reactions. `CHAT_MSG_WHISPER` is deliberately left out: broadcasting a
  hash of a whisper's sender+text over the hidden channel — even hashed —
  leaks metadata about a private conversation to anyone else on that
  channel. That's a privacy regression this feature shouldn't introduce.
  Addon/system/combat/loot messages are excluded because `AddMessage` also
  fires for those outside any real `CHAT_MSG_*` event (e.g. an addon's own
  status line), where the `event`/`arg1`/`arg2` globals would be stale
  leftovers from whatever last fired — reacting to those would attach a
  reaction to the wrong, unrelated message.

**Implementation bug found while scaffolding:** an eligibility check on
`event` alone isn't sufficient, even with the allowlist above — it doesn't
prove *this* `AddMessage` call is the live rendering of that event, only
that some eligible event fired at some earlier point and nothing has
overwritten the globals since. Concretely, `core/reactions.lua`'s own pill
line is rendered via `AddMessage` from a mouse click, not from any
`CHAT_MSG_*` event, and `event` could easily still read as an eligible type
from whatever chat message last arrived.

**First fix attempt (superseded by a live-client bug — see below): a
snapshot.** `core/identity.lua` stored `{sender, text, channel, expires}` at
the moment each eligible event fired (a tight ~0.5s TTL), taken from a
handler on our own separate dispatcher frame, and `core/chat.lua` only
tagged an `AddMessage` call when that snapshot was still fresh and the
rendered text contained the snapshotted raw text.

**Live-client bug (2026-09-29): this snapshot arrives too late under
bursty traffic.** Reported symptom: World-channel messages (a busy,
high-volume channel — LFG/trade spam) never got tagged at all, while SAY
worked fine. `/bubbledebug` (a safe, table-based debug dump — see the
Phase-0.1 "fourth bug" entry above for why it isn't a live print) caught it
directly: `AddMessage` fired for a message from "Hotani" while `pending`
still held an *unrelated earlier* message from someone else, and the
snapshot for Hotani's own message was recorded one entry *later* in the
log — i.e. after `AddMessage` had already run for it. The assumption that
our own dispatcher frame's event handler always runs before the `ChatFrame`
that actually renders the message turned out to be wrong under load:
apparently, when several `CHAT_MSG_CHANNEL` occurrences queue in the same
client tick, dispatch is closer to "per-frame, all its queued events" than
"per-event, all frames" — so a frame like `ChatFrame3` (where pfUI routes
World/Trade/etc.) can run its `AddMessage` for several messages in a row
before our separate dispatcher frame gets a turn at all. SAY worked
because it's rarely bursty enough to hit this.

**Fix: stop using a separately-dispatched snapshot; read `event`/`arg1`/
`arg2` directly inside the `AddMessage` hook itself.** Those globals are
set by the client for whichever event is *currently* being dispatched,
valid for every frame handling that exact occurrence — reading them in the
same call that's rendering the message has no cross-frame ordering
dependency at all. This reintroduces the *original* worry (an unrelated
`AddMessage` call picking up stale globals), now covered by two things
instead of timing: `core/reactions.lua` explicitly suppresses tagging
around its own known self-call (`B.chat.SetSuppressTagging`, deterministic,
not a heuristic), and for everything else, requiring the rendered text to
actually contain `arg1` verbatim as a substring is a strong filter on its
own — an unrelated string coincidentally containing a prior message's exact
wording is vanishingly unlikely. Net effect: `core/identity.lua` lost its
snapshot/TTL machinery entirely; it's back to pure, stateless helper
functions (`IsEligible`, `ChannelComponent`, `MakeKey`).

**Third live-client bug: `%` in a message defeated the substring match
entirely.** Reported symptom: any message containing `%` never got a `[+]`
at all, no error. `/bubbledebug`'s `NOMATCH` logging (added for exactly
this kind of silent failure) showed the cause directly: for a message a
player typed as `"% in my own chat"`, `arg1` arrived as `"%%"` while the
rendered `text` this hook sees had only a single `%`. Something in the
client/network layer doubles `%` at the protocol level and un-escapes it
back to one `%` for display — plausibly a defense against chat text later
being fed into a `string.format`-style call somewhere downstream. Fixed in
`core/chat.lua` by running `arg1` through
`string.gsub(arg1, "%%%%", "%%")` before both the substring match and the
message-key hash, undoing the same doubling the display path already
undoes — confirmed locally with a standalone Lua interpreter before
shipping it back to the test client (`"3%% chance..."` → `"3% chance..."`).

---

## Phase 1 — Minimal proof of concept

Depends on Phase 0 being real and tested in a live client, not just designed.

### 1.1 Click affordance — **Decided (verified against a live pfUI checkout)**
Chat lines in 1.12 are plain `FontString` text with no native per-line click
target — except hyperlinks, which the client already hit-tests for you. The
plan is to append a custom hyperlink token (`|Hbubble:<key>|h[icon]|h`) to
the end of each rendered line before it hits the chat frame, and hook the
global `SetItemRef` dispatcher (the same choke point every hyperlink click
already goes through, item links included) to catch our custom link type and
pop a small reaction picker.

**Verified against a real pfUI install** (the checkout symlinked into
`twmoa_1181-HDBDEV`'s `Interface/AddOns/pfUI`, `modules/chat.lua` +
`modules/chatcopy.lua`): pfUI does **not** replace
`ChatFrame_MessageEventHandler` or intercept messages ahead of the hyperlink
pipeline. It hooks `ChatFrame:AddMessage` per frame — twice, independently,
by two different modules — always by saving whatever `AddMessage` currently
is and calling through at the end, never by full replacement. It does the
identical save-and-chain dance on `SetItemRef`, **twice in the same file**
(once for `url:` links, once for `player:` shift-click links), always
falling through to the saved original for any link type it doesn't
recognize. Neither hook touches unrecognized hyperlink tokens or text it
doesn't specifically pattern-match, so a `|Hbubble:<key>|h[icon]|h` tag
appended to a line passes through pfUI's `AddMessage` untouched.

**What this means for our hook:**
- **Never reuse pfUI's own sentinel field name `HookAddMessage`** for our
  saved original — `chat.lua` uses that exact field to guard against
  double-installing its own hook, and clobbering it breaks pfUI's chat
  entirely.
- **Install our `AddMessage`/`SetItemRef` hooks from `PLAYER_ENTERING_WORLD`,
  not file scope.** pfUI installs its chat hooks from its own module-init
  path; hooking too early races it and we'd end up wrapping the un-hooked
  original instead of chaining on top of pfUI's wrapper (or vice versa,
  depending on load order — chaining from a later event sidesteps the race
  either way).
- pfUI-turtle (the Turtle-content skin addon,
  `Interface/AddOns/pfUI-turtle`) touches none of this — no `chat.lua`
  equivalent, no `AddMessage`/`SetItemRef` reference anywhere in it. Not a
  factor here.

Aside, not actionable: pfUI itself calls `hooksecurefunc` twice in
`chat.lua` on this exact Turtle client, which seems to contradict the
no-hooksecurefunc assumption in [`DEVELOPING.md`](DEVELOPING.md). We still follow
the established save-and-replace convention regardless — it's what pfUI
itself does for `AddMessage`/`SetItemRef` anyway, so it's the
tested-in-practice pattern, not just the cautious one.

**Hover detection rides the same hyperlink, for free.** The Discord-style
ask — hover *this specific message* and a small toolbar appears — sounds
like it needs a chat line's screen position (the thing §3.1 says is
unsolved), but it doesn't. `OnHyperlinkEnter`/`OnHyperlinkLeave` are
per-hyperlink hit-testing events the client already fires — pfUI's own
`chat.lua` (§729-745 in the checkout read above) registers exactly this
pair on every `ChatFrame` to pop `GameTooltip` on an item link. Registering
the same pair for our `bubble:` link type gives real, per-message hover
detection with no line-position problem at all, since the client is doing
the hit-testing, not us. The toolbar itself is a small frame shown
cursor-anchored on `OnHyperlinkEnter` (same anchoring style as that
tooltip) and hidden on `OnHyperlinkLeave` — it only needs "where's the
cursor right now," never "where is this line on screen." Scope for the
toolbar is deliberately narrow: **one button** (add/open the reaction
picker) — Discord's link/reply/pin/edit/`…` icons in the reference
screenshot aren't reaction features and aren't in scope.

### 1.2 Rendering an incoming reaction — **Decided (for now)**
1.12 gives no way to mutate or re-flow an already-added chat line, and no
way to query a line's screen position to anchor a persistent badge on it
the way Discord's reaction pill sits under a message permanently — that
part of §3.1 stays unsolved in general. Phase 1's approximation: render a
reaction as a new chat line directly below the original ("😊 3" in a quiet
color, indented), not an inline badge on the original line. Less polished
— it reads as "the latest tally" rather than an in-place mutating pill, and
old tallies remain above it in scrollback — but it's correct regardless of
scrollback state and sidesteps line-anchoring entirely.

Critically, **the pill line carries its own `bubble:` hyperlink** just
like the original message did, so it goes through the exact same
`SetItemRef` hook from §1.1 — no separate mechanism needed for what you
described (left-click the pill to add another of that same emoji;
right-click the same pill to open the full picker instead). `SetItemRef`'s
third argument is literally `"LeftButton"` or `"RightButton"`, so that
distinction falls out of the hook we already have.

**Live-client bug (2026-09-29): the pill rendered in the wrong window.**
`RenderPill` originally always targeted `DEFAULT_CHAT_FRAME` (typically
`ChatFrame1`), but pfUI routes World/Trade/etc. channel messages onto
`ChatFrame3` ("Loot & Spam") — so a reaction on a World-chat message put
its pill in a completely different window than the message it was reacting
to. Fixed by having `core/chat.lua`'s `AddMessage` hook remember which
frame(s) a message key was actually tagged on
(`core/reactions.lua`'s `R.RememberFrame`, keyed by the frame object
itself), and having `RenderPill` render on those same frame(s) instead of
assuming one fixed frame — falling back to `DEFAULT_CHAT_FRAME` only for a
key this client never saw tagged locally (e.g. a stray broadcast).

**That fix didn't work on the first attempt — a second live-client bug, a
key-type mismatch.** `/bubbledebug` showed `RememberFrame key=896802728
frame=ChatFrame3` immediately followed by `RenderPill key=896802728
knownFrames=NONE` for the *same* key — the write was invisible to the very
next read. Cause: `ID.MakeKey` returned a Lua **number** (arithmetic result
from `HashString`), which is harmless everywhere the key only ever gets
*embedded in text* (the hyperlink, the wire protocol) — `..` concatenation
coerces a number to its decimal string automatically. But
`R.RememberFrame` was called with that raw number directly (inside the
`AddMessage` hook, straight from `MakeKey`), while every *read* of
`knownFrames` came through `RenderPill`, whose `key` always arrives as a
**string** — parsed via `string.sub` out of a clicked hyperlink or the wire
protocol, which never round-trips back to a number. `t[896802728]` and
`t["896802728"]` are different entries in Lua; there's no implicit
coercion for table indexing, only for concatenation. The reaction *counts*
were never affected by this, only slightly by luck — `ApplyLocal`/
`HasReacted`/`Count` happen to only ever be called with string keys
(clicks and the wire protocol are the only two entry points), so that
table was accidentally self-consistent the whole time; `knownFrames` was
the one place actually mixing types. Fixed by having `ID.MakeKey` return
`tostring(...)`, so the key is one consistent type from creation onward.

**Refinement (2026-09-29): a bare "icon count" pill is ambiguous once
other messages interleave.** The reaction usually arrives well after the
original message — over the hidden channel, on the reactor's own schedule
— and nothing guarantees no other messages land in between. A pill reading
just "😊 3" with no connection to what it's about becomes a guess once
scrollback has moved on. Fixed by having `core/chat.lua` also call
`R.RememberOrigin(key, sender, text)` at tag time (same call site as
`RememberFrame`), and having `RenderPill` append who said the reacted-to
message and a short (40-char) snippet of it, dimmed, after the reaction
itself: `😊 3  > Grug: hey does anyone have a...`. Plain `>` as the
connector, deliberately not a Unicode arrow — this client's font already
proved unreliable for anything past basic Latin (see §1.4's emoji saga);
no reason to bet on `→` rendering when `>` says the same thing safely.

### 1.3 Scope for "done"
One reaction type (👍), heuristic keying per §0.3 (works on anyone's
message — there's no smaller slice that's still worth using), a single click
sends the fixed reaction with no picker UI, reaction shown as a new chat
line. This is deliberately narrower than the full pitch — no picker, no
favorites/recents, no bubble — it exists to prove the hidden-channel +
hyperlink-click + raw-event-keying mechanics work end-to-end in a live
client before investing in Phase 2's UI.

### 1.4 Reaction icons are textures, not Unicode emoji — **Decided**
Every 👍/😊 written in this doc so far has been shorthand, not a literal
plan. **1.12's client font predates color emoji entirely** (it's a 2004-era
font file) and vanilla chat doesn't auto-convert `:)`-style text into icons
the way some later clients do — typing or receiving a real Unicode emoji
character would render as a missing-glyph box at best. Reactions have to be
small **textures**, shown via the `|Tpath:size|t` escape sequence (the same
mechanism faction/class icons already use in chat, seen in pfUI's own
`chat.lua`), not text characters.

There's no existing stock WoW icon that reads as "thumbs up" or "heart" —
raid target markers, class icons, spell icons are all the wrong vocabulary
for a reaction. **This is a real, if small, art requirement**, not something
that falls out of the code for free. Phase 1's scope (one reaction type)
needs exactly one shipped texture file (`Interface\AddOns\Bubble\...`);
Phase 2's full picker (§2.2) needs a small curated set — single digits, not
a font's worth — which is the actual scope driver for "how big is the
favorites/more picker," more than any code decision.

**Art format — Decided: TGA, not SVG/PNG/BLP.** SVG isn't supported at
all (the client's texture pipeline has no concept of a vector format);
PNG loading for in-game textures didn't exist yet on this client either
(that's a much later, retail-era addition). BLP is the client's native
format and always works, but needs a conversion step (a BLP encoder) for
every icon — worth it for large/compressed art, not for a 14–16px chat
icon. TGA is the de facto standard for hobbyist/addon-authored icons on
1.12-era clients (Turtle WoW's addon scene included): it loads directly,
no conversion tool needed, exports straight out of any image editor.
Spec: **32-bit, uncompressed (not RLE), power-of-2 dimensions**
(16×16 or 32×32). Path convention: drop it under
`Interface\AddOns\Bubble\textures\<name>.tga` and reference it **without
the extension** (`SetTexture("Interface\\AddOns\\Bubble\\textures\\thumbsup")`
or `|TInterface\AddOns\Bubble\textures\thumbsup:16|t`) — the client tries
`.blp`/`.tga` automatically off the bare path.

**Conversion pipeline built: `tools/svg2tga.sh`.** Takes an SVG (Twemoji/
OpenMoji or similar), rasterizes via `rsvg-convert`, converts to TGA via
`magick`. The exact TGA header this needs (image type, bit depth, origin,
alpha bits) was **verified byte-for-byte against
`Aegis_Exchange/art/gradient-fill.tga`** — a texture already confirmed
working in-game on this exact client — rather than assumed from general
TGA documentation; see `tools/README.md` for the full byte comparison.

**Confirmed live (2026-09-29):** five icons (thumbsup, heart, laugh, wow,
sad) converted from Twemoji 14.0.2 and loaded in-game — the pill renders
the real icon correctly, not just a format-correct file. Both claims
("format is right" and "it actually renders") are now checked, not
assumed. Attribution recorded in `README.md`.

### 1.5 Hover tally tooltip — **Confirmed working live, pulled forward from §2.2**
A live reaction tally on hover, cursor-anchored via `GameTooltip` —
`core/hover.lua`. This came out of a design discussion about wanting a
persistent badge stuck to the original message: that's genuinely not
possible (see §3.1's expanded writeup below for exactly why, including
what was actually checked rather than assumed), but a hover-triggered
tooltip needs no line position at all, since `GameTooltip:SetOwner(this,
"ANCHOR_CURSOR")` anchors to the cursor, not the line. Hovering a pill's
own link shows that emoji's icon, count, and up to 5 reactor names (`+N
more` beyond that); hovering the original message's generic marker shows
the same, once per active emoji, as a breakdown (see §2.2's regression
note below for why the marker case needed its own handling once the
picker landed).

Mechanically this is the same save-and-chain principle as `core/chat.lua`'s
`AddMessage`/`SetItemRef` hooks, just via a different WoW mechanism:
`OnHyperlinkEnter`/`OnHyperlinkLeave` are frame **scripts**, and
`SetScript` replaces whatever was there rather than layering — verified
pfUI's own `chat.lua` sets exactly these two scripts on every `ChatFrame`
for item-link tooltips, so saving via `GetScript` and calling the original
from inside our replacement is what keeps pfUI's own tooltips working
rather than silently breaking them. **Confirmed working on the HDBDEV
client (2026-09-29)** after the required full restart (new `.toc` entry,
not just `/reload`).

---

## Phase 2 — The actual pitch

Depends on 1.1–1.3 being proven live, not just working in theory.

### 2.1 React to anyone's message — **Superseded, see §0.3**
This used to be a separate Phase 2 item ("add heuristic keying later"), but
§0.3 decided heuristic keying is how message identity works from Phase 1
onward — there was never a smaller universal slice, so this shipped as part
of §1.3, not as a follow-up. Left here, marked closed, so the phase list
doesn't quietly imply it's still pending.

### 2.2 Reaction picker — **Built, one gap from the original design**
Beyond a single 👍: a small picker UI, a handful of fixed options (not
freeform emoji — freeform means shipping a font/texture atlas and a much
bigger scope). `core/picker.lua`. Applies uniformly to every eligible
message type (§0.3's allowlist), no per-type split needed — the earlier
draft of this section proposed anchoring to Turtle's native world-space
chat bubbles (`C_ChatBubbles`) for SAY/YELL/PARTY specifically, which was
solving the wrong problem (that came from initially misreading what
"bubble" meant in the pitch — see §3.2 for where that idea still might
earn its keep, later, as a cosmetic option rather than the mechanism).

**Trigger ended up reusing the existing click routing instead of a
separate hover button.** The original plan (below, superseded) called for
§1.5's hover tooltip to also carry a clickable "open picker" button. What
actually shipped: with more than one possible emoji, the original
message's marker (§1.1) can no longer mean "toggle thumbsup" — it's now a
generic `bubble:KEY` link (no emoji baked in) that opens the picker on
either click. A pill's own link (`bubble:KEY:EMOJI`, specific) keeps
quick-toggling that one emoji on left-click, and opens the picker on
right-click instead — `SetItemRef`'s third argument is literally
`"LeftButton"`/`"RightButton"`, so that fell out of the hook already in
place rather than needing a new one. §1.5's `GameTooltip` stays read-only
(showing the tally on hover), not a click target — simpler than adding
interactive elements to a tooltip widget, which vanilla-era `GameTooltip`
isn't really built for.

~~The trigger is the hover toolbar from §1.1 — hovering *any* message's
`bubble:` hyperlink shows one small cursor-anchored button; clicking it
opens the picker for that specific message.~~ *(superseded, see above)*

The picker itself, as built: all five currently-defined icons (§1.4) shown
directly in one row — no separate favorites/recents/"more" distinction
yet, since that only earns its keep once the set is too big to show at
once. `emojiList` is built from `B.icons` and explicitly sorted
(`table.sort`), since `pairs()` gives no ordering guarantee and an
unsorted layout would shuffle between sessions.

**Deferred, not built:** favorites/recents and their SavedVariables
storage (~~per-character, not account-wide, same reasoning as Aegis's
realm-keyed price data~~ — still the right call whenever this is picked
up, just not needed yet with only 5 icons total).

**Idle opacity — built as decided:** the picker frame sits at `0.28` alpha
by default and goes fully opaque on `OnEnter` (back down on `OnLeave`), so
it doesn't compete for attention with the chat text it's sitting over
until someone's actually about to use it. This is the picker *frame*
itself (a real `Frame`/`Texture`, which supports `SetAlpha` normally) —
doesn't apply to the `[+]`/pill *text* markers, which can't do this at all
(WoW's `|cAARRGGBB` alpha byte is effectively ignored for chat text on
this client).

**Positioning is cursor-anchored** (`GetCursorPosition()` divided by
`UIParent:GetEffectiveScale()`, the standard vanilla-addon idiom for this)
— the first Bubble frame with a *computed* on-screen position rather than
a fixed anchor, so unlike everything else built so far this genuinely
can't be trusted without a live-client look: does it land in a sane spot
near the click, does it ever go off-screen near screen edges, does
click-elsewhere-to-close (`BubblePickerCatcher`, a full-screen invisible
frame) actually dismiss it cleanly. (**Later removed, 2026-10-04:** that
catcher swallowed every click while the picker was open, so you couldn't
type or interact with anything else. The picker now closes itself after 10s
with the mouse not over it, on Escape, or on picking an icon.) **Confirmed working live (2026-09-29):
click opens the picker, an icon can be chosen.**

**Regression caught immediately on that same test: hovering the marker
stopped showing a tally.** §1.5's tooltip looks up a tally by parsing
`EMOJI` out of `bubble:KEY:EMOJI` — but the marker's link changed in this
section to the emoji-less `bubble:KEY`, so that lookup had nothing to find
and silently showed nothing. Fixed by giving `core/hover.lua` a second
branch for the no-colon case: instead of one emoji's tally, it shows a
breakdown across every emoji `core/reactions.lua`'s new `R.ActiveEmojis(key)`
finds reacted on that message (one "icon count" + reactor-names block per
emoji, reusing the same rendering as the single-emoji case via a shared
`AddEmojiLines` helper). Arguably better than the old behavior, not just a
restoration of it — the old tooltip could only ever show thumbsup's count,
since that was the only emoji that existed; the marker's hover is now the
one place that shows a message's *entire* reaction picture at a glance.

### 2.3 One reaction per person, per emoji, per message — **Decided**
Matches Discord/Slack/iMessage, not a click counter: a player's own
`(reactor, emoji, messageKey)` tuple is **membership in a set, not a
tally**. Clicking a pill you haven't reacted to adds your membership;
clicking your own again removes it. The displayed count is
`table.getn(reactors)` for that emoji on that message, so it always reads as
"how many distinct people," never "how many times someone clicked."

This resolves what would otherwise be an abuse problem for free: since
membership is idempotent, there's no way to inflate a count by
re-clicking, so no separate anti-spam cap on stacking is needed. The only
remaining rate limit is the transport-level one already in §0.1 (cooldown
between hidden-channel sends) — that one exists to protect the channel from
being flooded by rapid *distinct* reactions (e.g. mashing several different
emoji fast), not to stop stacking, since stacking isn't possible anymore.

### 2.4 Latest-interaction overlay — **Confirmed working live**
`core/overlay.lua`. Came out of a live bug report: a long message on the
narrow "Loot & Spam" panel pushed the §1.1 marker to its own wrapped line
(a `|T...|t` escape wraps as a single unit, same as a long word would, and
there's no way to control where chat text breaks). **This is NOT the
drift-prone per-line badge §3.1 already researched and rejected** — the
key difference is this overlay tracks no line position at all. It's a
small, normal, player-draggable frame (`SetMovable` +
`OnDragStart`/`OnDragStop`, the same idiom every unit frame and minimap
button uses) that always shows the *most recent* reaction event, regardless
of which message it was on — icon (persistent, swaps to whichever emoji
was just used) + a text label (`sender: snippet`, reusing
`core/reactions.lua`'s existing `originOf` data — no new tracking needed)
that fades in fresh on each event and back out over a few seconds
(`FADE_HOLD` = 3s hold, `FADE_DURATION` = 4s fade, driven by `GetTime()`
so it's frame-rate independent rather than a fixed per-tick decrement).
Hovering it shows a short rolling history (last 10 events) via
`GameTooltip`, same mechanism as §1.5's tallies.

**First SavedVariables in this addon.** `BubbleCharDB` (per-character, same
reasoning as §2.2's deferred favorites/recents — a UI layout choice is
personal, shouldn't follow onto an alt), storing just the overlay's saved
position. `core/init.lua` gained an `OnLoad` queue for this (DEVELOPING.md hard
rule #9 — SavedVariables are `nil` until `ADDON_LOADED` fires for this
addon specifically, so DB setup can't happen at file scope), mirroring
`Aegis_Exchange.OnLoad`'s existing pattern in this workspace.

**Confirmed live (2026-09-29):** correctly stays hidden until the first
reaction of the session rather than appearing empty on login — confirms
the lazy-build-inside-`ShowEvent` approach works as intended, not shown
unconditionally at load.

**Confirmed (2026-09-29): dragged position persists across `/reload`.**
`BubbleCharDB` (and the `OnLoad` queue gating it) round-trips through
SavedVariables correctly — the first real test of that mechanism in this
addon, and it held up. Not yet tested across a full client restart
specifically (only `/reload` so far), but `/reload` already proves the
save/load path itself works; a restart is a lower-risk remaining check,
not a different code path.

### 2.5 Chat pill visibility setting — **Built, not yet tested live**
`core/config.lua`. Came out of a live screenshot review: with §2.4's
overlay now covering "what's the latest reaction" as a lighter,
always-visible alternative, the chat pill line was visibly crowding out
real chat in a busy channel — several reactions in a row each add a whole
extra line. **Decided: off by default**, with a `/bubble pills on`/
`/bubble pills off` slash command rather than a graphical options panel —
the practical result (a working toggle, defaulting off) is the same for
far less work, and a real panel is worth building later only if a single
toggle turns out not to be enough.

**The setting gates only the chat `AddMessage` call inside
`core/reactions.lua`'s `RenderPill` — nothing else.** Reaction state
(`state`/`originOf`/`knownFrames`), the overlay, and `core/hover.lua`'s
tooltips are all unconditional and unaffected either way, so turning pills
off never costs any actual tracking, only the extra chat line. `B.config`
is deliberately its own module rather than living inside
`core/reactions.lua` — the natural home for whatever a future graphical
panel would also need, and a sensible place for any settings that come
later (e.g. per-channel-type toggles, if that's ever revisited).

`BubbleCharDB`'s own initialization moved from `core/overlay.lua`'s
`OnLoad` callback to `core/init.lua`'s `ADDON_LOADED` handler directly —
one canonical place for "the DB itself exists" now that a second module
(`core/config.lua`) also depends on it, rather than every module doing its
own redundant `BubbleCharDB = BubbleCharDB or {}`.

**Not yet tested live** — same category as everything new: does the slash
command actually toggle correctly, does `showPills = false` truly suppress
every pill without breaking anything else (overlay/hover/picker should all
still work exactly as before).

### 2.6 Security review: untrusted input, four real findings fixed — **Confirmed working live**
Prompted by a direct question, not a bug report — worth auditing rather
than assuming. `key`/`emoji` reach `core/reactions.lua`'s `ToggleMine`/
`ApplyRemote` from two untrusted sources, and neither was validated before
this pass:

1. **A clicked hyperlink.** WoW's client renders *any* `|H...|h...|h`
   sequence in *any* displayed chat text as a real clickable link,
   regardless of who wrote it or which addon (if any) put it there — this
   isn't specific to our own `AddMessage` hook. A plain message typed in
   ordinary public chat, containing a hand-crafted `bubble:KEY:EMOJI`
   link, renders identically to a real one for every Bubble user who sees
   it.
2. **The hidden channel itself.** §0.1's channel has no access control —
   it's a normal WoW channel, joinable by anyone who knows or guesses the
   name (`/join BubbleReact29483`), addon or not. A hostile client could
   send crafted `BubbleRx:ADD:...` text directly.

Without validation, an attacker-chosen `emoji` was concatenated straight
into a *new* hyperlink `RenderPill` generates for the pill — a hyperlink
injection vulnerability, not theoretical: a crafted value could break out
of the intended `|Hbubble:KEY:EMOJI|h` structure and embed something else
entirely (a fake `url:` link, say) that renders as if it came from us.
**Fixed:** `IsValidEmoji` (whitelist against `B.icons` — not a shape
check, an exact membership check) and `IsValidKey` (digit-only, ≤10 chars
— the only shape `ID.MakeKey` ever actually produces) guard the top of
both `ToggleMine` and `ApplyRemote`, the one choke point every mutation
path — a local click, a picker choice, a remote broadcast — funnels
through, so this covers all of them without duplicating checks in
`core/chat.lua` and `core/channel.lua` separately.

**Second, separate finding: the quoting itself.** `core/reactions.lua`'s
"who said the reacted-to message" quoting (§1.2) takes the *original
speaker's* raw typed text and re-embeds it into a new rendered string (the
pill, and `core/overlay.lua`'s label — `FontString:SetText` interprets the
same escape codes chat text does, so both were equally exposed). If that
speaker's own message contained a literal `|`, it would carry through
unescaped. **Fixed:** `EscapePipes` doubles every `|` to `||` — WoW's own
documented escape for a literal pipe — applied once, at `RememberOrigin`
(where raw message text first becomes something we redisplay), rather
than trusting every consumer to remember to do it themselves.

**Follow-up pass, prompted by "this needs to hold up at scale, not just
against the two bugs already found":** two of the three residual concerns
above turned out to be worth fixing now rather than deferring, once
actually thought through rather than assumed acceptable —

- **`knownFrames`/`originOf` growth turned out to be a bigger deal than
  "flood-only."** They get an entry for *every eligible message ever
  displayed* (`core/chat.lua` tags on arrival, before anyone reacts) — not
  just reacted-to ones. That's unbounded growth from ordinary busy-channel
  traffic alone, no attacker required; a deliberate flood just makes it
  worse. **Fixed:** `core/reactions.lua`'s `TouchKey`, a shared
  first-touched-order tracker with a `MAX_TRACKED_KEYS = 500` cap —
  exceeding it evicts the oldest key's entries from `state`/`originOf`/
  `knownFrames` together (they share the same key, so eviction has to stay
  in sync across all three or they'd drift out of consistency with each
  other).
- **No incoming rate limit.** **Fixed:** `core/channel.lua`'s
  `IsRateLimited`, capped **per sender** (10 messages per 5-second window)
  rather than globally — a global cap would let one hostile client
  silently suppress everyone else's *real* reactions too during a flood,
  which is worse than doing nothing. Runtime-tested with a controllable
  fake clock: confirms exactly 10 pass / 5 blocked within a window for one
  sender, a second sender is unaffected by the first's flood, and the
  limit clears once the window elapses (not a permanent block).

**A real bug caught while implementing the first fix, not shipped:**
`TouchKey`'s first draft referenced `originOf`/`knownFrames` in its body
*before* their own `local` declarations later in the file. That's not a
syntax error — Lua scopes a `local` from its declaration point onward, so
a reference above it silently resolves to a (nil) global instead of
erroring at load time. `luac -p` doesn't catch this either, since it's
semantically valid, just wrong. It wouldn't have manifested until the
501st unique key actually triggered eviction — caught here by re-reading
the diff before trusting it, same category of mistake
`Aegis_Exchange/tests/lint/scoping.py` exists to catch mechanically in
that addon; Bubble doesn't have an equivalent lint pass yet. Fixed by
reordering: both tables now declared together, before anything that
references them.

**Remaining, still knowingly not fixed:** a message with a *valid-format*
but fabricated key (any random digit string within the cap) still passes
validation and creates an "orphan" reaction with no real message behind
it — `originOf[key]` is `nil` for a key nobody legitimately tagged, so it
renders with no quoted context (and, if pills are on, via the
`DEFAULT_CHAT_FRAME` fallback). Not a security hole — the server still
attributes it to the sender's real character (§0.1's server-verified
`arg2`) — just spam, and rate-limited to at most 10 per 5s per sender now
regardless. Not worth more than that without evidence it's actually being
abused.

**Confirmed live (2026-09-30): the validation guard itself.** Tested via
`/run Bubble.reactions.ApplyRemote(...)` directly (more reliable than
hand-typing a `|H` link — the standard chat edit box tends to filter raw
pipes before sending, which would test that filter rather than our own
validation) — a bogus emoji and a bogus (non-digit) key were both silently
rejected (`Count` stayed `0`), while a valid-shaped-but-fabricated key with
a real emoji correctly went through (`Count` became `1`). That contrast
matters: without the accept case, "nothing happened" for the reject cases
could just as easily mean the whole reaction system was broken as mean the
guard was working. All three confirmed correctly discriminating.

**Rate limiter confirmed live (2026-09-30).** Tested via `/run` on a
second character firing a burst of 15 distinct-keyed reactions through
`Broadcast` directly (bypassing the picker, which closes after every pick
and makes manual burst-testing impractical), checked on the receiving
character via `Bubble.reactions.Count` — confirmed roughly 10 of 15 landed,
matching the 10-per-5s cap. Noted beforehand as a real possible confound:
WoW's own client has its own baseline `SendChatMessage` throttle,
independent of ours, so a burst that's naturally paced slower than our
window could make everything eventually land regardless of whether our
limiter works — the ~10-of-15 result rules that out, since the client
itself was clearly not bottlenecking this particular burst.

**Still not tested live:** the 500-key eviction cap specifically — would
need genuinely heavy sustained traffic (500+ distinct eligible messages in
a session) to trigger naturally, lower priority to chase down deliberately
than the other three, which are all now confirmed.

---

## Phase 3 — Stretch / likely-infeasible-on-stock-client

### 3.1 A true in-place pill, not a next-line approximation — **Open, researched, not built**
The real Discord behavior — a badge that sits under the actual message
permanently and updates in place, rather than §1.2's "new line below it"
approximation. Blocked on finding a reliable way to track a `ChatFrame`
line's live screen position in 1.12 across resizes and scrolling; nobody in
this ecosystem has solved that without replacing chat's line rendering
entirely (the Prat-style approach). §1.5's hover tooltip covers the
"which message is this about" need a different way, without this problem
at all — this section is specifically about a *persistent*, always-visible
badge, which the tooltip is not.

**Checked, not assumed: neither ClassicAPI nor Nampower (the two DLLs this
client actually runs) help.** Pulled ClassicAPI's real function/method
dumps from its GitHub repo (`brues-code/ClassicAPI`,
`docs/raw_lua_funcs.txt` + `docs/raw_methods.txt`) and searched
exhaustively for anything chat/message-related: it adds exactly one thing
(`GetCurrentChatGUID()`, sender GUID for the currently-dispatching event —
not useful here) and nothing for reading or mutating a specific line.
Nampower's `EVENTS.md`/`SCRIPTS.md` (`brues-code/nampower`) are entirely
about spell-cast latency/queuing; its only `AddMessage` references are
example debug output in its own docs, not a capability it adds. Also
checked retail WoW's own modern `C_ChatInfo` API (which ClassicAPI is
explicitly backporting) via the "INCOMPLETE" stub list in a different
server's ClassicAPI Lua shim: even retail only exposes read-only line
introspection (`GetChatLineText`, `GetChatLineSenderName`,
`IsChatLineCensored`) with no `SetChatLineText` or equivalent anywhere in
that family. That's stronger evidence than "1.12 can't do it" — Blizzard's
`ScrollingMessageFrame` widget has never supported in-place line mutation,
at any point in the game's history, on any client.

**A cheaper, bounded approximation is possible, but trades accuracy for
cost.** The client's chat widget natively has `GetNumMessages()`,
`GetNumLinesDisplayed()`, and `GetCurrentScroll()` (confirmed present in
ClassicAPI's raw method dump — these are baseline widget methods, not a
ClassicAPI addition). Combined with counting eligible messages ourselves
(already done, in `core/chat.lua`'s hook) at tag time, that's enough to
build a *separate* overlay layer — a small reused pool of frames, not one
per message, positioned by computing roughly how many lines back a tagged
message is from the current scroll position — without replacing
`ChatFrame` itself. Meaningfully smaller than a full rewrite. But: there's
no API to ask how many *visual* lines a given message wrapped to, so the
position math has to either reimplement WoW's text-layout engine (not
"cheap" at all) or assume every message is exactly one line and accept
drift. That drift compounds with every wrapped message between the tagged
one and the current bottom — and busy channels (the exact scenario that
motivated this whole thread, e.g. World chat) are also where wrapped
messages are most frequent, so the approximation is weakest precisely
where it'd be used most. Also needs separate handling for font-size
changes, window resizing, and chat's own fade-out animation to look
consistent. **Not started.** If picked up, it should be built as a clearly
labeled experimental feature, tunable/disable-able, since its visual
quality can't be fully judged without a live client and a human eye — every
other piece of Bubble so far has been verifiable by logic or a byte
comparison; this one genuinely can't be.

### 3.2 World-space bubble anchoring for SAY/YELL/PARTY — **Open, cosmetic, later**
An idea from an earlier pass at this doc, worth keeping as a possible
*addition*, not a replacement for §2.2's hover toolbar: for message types
that spawn a native chat bubble above the speaker's head, Turtle's client
exposes `C_ChatBubbles.GetAllChatBubbles()` — a real, positioned `Frame`,
unlike anything inside `ChatFrame`. pfUI's `modules/bubbles.lua` uses it
(to skin bubbles), which is worth reading as a reference for the mechanics
only — it calls that API, it doesn't define it, so nothing here is a pfUI
dependency. The idea would be a purely cosmetic extra: mirroring the
reaction pill onto the world bubble as well, for players standing nearby.
Two unresolved questions if this is ever picked up: whether
`C_ChatBubbles` exists without a DLL and across every target server, and
how to correlate a given bubble to the sender/message that spawned it (no
owner field visible in what pfUI uses). Not needed for the core feature to
work — §2.2 covers every message type without it.

### 3.3 pfUI-native visual integration — **Open**
Once §1.1's hook-chaining is proven live, consider a pfUI-specific skin
(mirroring [`Aegis_Exchange/pfui/`](../Aegis_Exchange/pfui)'s pattern) so the
reaction picker and pills match pfUI's chat styling instead of looking
bolted-on.
