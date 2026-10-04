# DEVELOPING.md — Bubble

A World of Warcraft addon (folder + `.toc` name: **`Bubble`**) for
**Turtle WoW-style 1.18.1 servers**, which run the **ORIGINAL WoW 1.12
(vanilla) client on Lua 5.0** — the same environment as Aegis: Exchange,
Altoholic and Link elsewhere in this workspace.

> This is **NOT** WoW Classic and **NOT** retail. Do **not** use any API
> newer than patch **1.12**. When in doubt, assume the API does not exist.

**Phase 1 is working and confirmed on a live client** (see
[`README.md`](README.md) Status). Read [`ROADMAP.md`](ROADMAP.md) before
changing anything — it records the design decisions and the bugs found during
live testing. Code carrying a `-- VERIFY ON LIVE CLIENT` comment is still
unconfirmed.

---

## HARD RULES — never violate these

These come from the 1.12 / Lua 5.0 client itself, not style preference.
Breaking any of them produces a runtime error or silent breakage. (Carried
over verbatim from `Aegis_Exchange/DEVELOPING.md`
— same client, same rules.)

### Language (Lua 5.0)

1. **Lua 5.0 only.** **NO** `string.match`, **NO** `string.gmatch`, **NO**
   `:match()`. Use **`string.find`** (with captures) and **`string.gfind`**
   (5.0's name for what later Lua calls `string.gmatch`).
2. **NO `#` length operator.** Use **`table.getn(t)`**. **NO `table.setn`.**
3. **NO `%` modulo operator.** Use **`math.mod(a, b)`**. No integer division
   either — combine `math.floor` with `math.mod`.
4. **Varargs use the `arg` table and `arg.n`** — not `...` expansion.
   `select()` does not exist.
5. `string.gsub`, `string.find`, `string.gfind`, `string.format`,
   `string.sub`, `string.lower`/`upper` are fine. The banned ones are
   strictly the `match`/`gmatch` family.

### Events

6. **Event handlers read the GLOBALS `event`, `arg1`, `arg2`, …** — **NOT**
   `function(self, event, ...)`. The OnEvent script receives no arguments on
   this client; the client sets `this`, `event`, and `arg1..argN` as globals.
   This matters a lot here specifically: the hidden-channel comm layer
   (`CHAT_MSG_CHANNEL`, `CHAT_MSG_ADDON`) and every chat-line hook read
   through this same global convention.

### Hooking

7. **NO `hooksecurefunc` and NO secure hooks.** Hook by **saving the
   original function and replacing it**, then call the saved original from
   your replacement. Secure-hook infrastructure does not exist in 1.12. This
   applies to `SetItemRef` (the hyperlink-click dispatcher this addon plans
   to hook — see `ROADMAP.md` §1.1) exactly as it would to anything else.

### The 32-upvalue ceiling

8. **A function may read at most 32 file-scope locals. Lua 5.0 refuses to
   LOAD a file that breaks this** (`too many upvalues (limit=32)`), which
   kills the whole addon, not just one feature. **Nothing local catches
   this** — `luac5.1 -p` and any 5.1 test harness compile it happily because
   5.1's limit is 60. Check with:
   ```
   luac5.1 -l -p file.lua | grep upvalues
   ```
   Fix by grouping constants into one table instead of adding another
   file-scope local.

### SavedVariables

9. **SavedVariables are `nil` until `ADDON_LOADED` fires for this addon's
   name.** `core/init.lua`'s `ADDON_LOADED` handler is where
   `BubbleCharDB` itself gets initialized (`BubbleCharDB = BubbleCharDB or
   {}`) — one canonical place, not every module doing it redundantly.
   Modules that need DB setup of their own beyond that queue it via
   `Bubble.OnLoad(fn)`, never at file scope. In use since §2.4/§2.5:
   `BubbleCharDB` (per-character — `## SavedVariablesPerCharacter` in
   `Bubble.toc`) holds the overlay's saved position and settings
   (currently just `showPills`, read via `B.config.Get`/`Set` in
   `core/config.lua`, never read/written directly elsewhere).

### Frames & globals

10. Use **`getglobal()` / `setglobal()`** for dynamic frame names.
11. Build frames with **`CreateFrame`** using **vanilla templates only**.

### Event handler cost

12. **A handler for an event that can fire in a burst must be O(1),
    state-gated, or coalesced behind a once-per-frame flush** — never an
    unbounded rescan inline. The hidden-channel reaction handler is exactly
    this kind of handler: a busy channel could deliver many reactions in a
    few frames, and each one must be a cheap, bounded lookup (hash the
    message key, touch one counter), never a rescan of chat history.

---

## New-to-this-project concerns (not covered by Aegis's rules)

These are specific to a chat-comm addon and don't have a precedent in the
other addons in this workspace yet:

- **Hidden-channel plumbing** (`JoinChannel`, resolving by name not number,
  rejoining on `PLAYER_ENTERING_WORLD`) — see `ROADMAP.md` §0.1.
- **Custom hyperlink tokens** (`|Hbubble:<key>|h...|h`) routed through
  `SetItemRef` — see `ROADMAP.md` §1.1. Any custom hyperlink type must be
  validated defensively in the `SetItemRef` hook (malformed/foreign links
  should fall through to the saved original, never error) since that
  dispatcher is shared with every other hyperlink in the client, including
  ones from other addons. **Verified against a live pfUI checkout**: pfUI
  itself chain-hooks `SetItemRef` twice (once for `url:` links, once for
  `player:` links), always falling through for anything else — same pattern,
  proven to coexist with itself in practice.
- **Do not reuse pfUI's `AddMessage` hook sentinel field name
  (`frame.HookAddMessage`)** for our own saved-original — `pfUI/modules/chat.lua`
  uses that exact field to guard its own one-time hook install, and reusing
  it collides with pfUI's bookkeeping, not just cosmetically. Install our
  `AddMessage`/`SetItemRef` hooks from `PLAYER_ENTERING_WORLD`, not file
  scope, so we chain on top of whatever pfUI (or nothing) has already
  installed rather than racing its module init.
- **No chat-frame line mutation or position query exists on 1.12** — see
  `ROADMAP.md` §1.2 and §3.1 for what this rules out and the workaround.
- **`SendAddonMessage` does not accept chat type `"CHANNEL"` on this
  client** — confirmed by live testing (`"Unknown addon chat type"`), not
  just documentation. Addon-message traffic only works over the fixed group
  types (GUILD/PARTY/RAID/WHISPER/...); a hidden custom channel has to use
  plain `SendChatMessage`/`CHAT_MSG_CHANNEL` instead. See `ROADMAP.md` §0.1
  and `core/channel.lua`.
- **Never put a literal `|` in outgoing chat text** unless it's a
  deliberate, well-formed WoW escape sequence (`|c`, `|H...|h...|h`, `|r`,
  `|T...|t`). Confirmed live: SuperCleveRoidMacros hooks `SendChatMessage`
  and rejects a naked `|` as an "Invalid escape code." Any future wire-format
  field separator should be something with no meaning to WoW's text
  formatting — `:` is already what this addon's payloads use.
- **NEVER call `:AddMessage()` (on any chat frame) from inside
  `AddMessageWrapper` in `core/chat.lua` itself.** Confirmed live: a debug
  print doing exactly that caused a real stack-overflow crash (2026-09-29,
  see `ROADMAP.md`'s §0.3 addendum for the full incident) — it re-entered
  the entire hook chain (ours plus pfUI's `chatcopy.lua`) while `event`
  hadn't changed, matching the same condition again on every re-entry,
  forever. This applies to any future code inside that hook, not just
  debugging — emitting a message in response to a message being displayed
  has to happen outside the hook's own call stack. `core/reactions.lua`'s
  `RenderPill` is safe only because it's called from `SetItemRef`/the
  channel handler, never from inside `AddMessageWrapper`; keep that
  boundary. Debug that hook with a table dumped on demand (see
  `B.debugLog` / `/bubbledebug` in `core/chat.lua`), never a live print
  from inside it.

---

## Project layout

```
Bubble/
  Bubble.toc          -- Interface 11200; ## SavedVariablesPerCharacter:
                      -- BubbleCharDB (§2.4's overlay position, §2.5's
                      -- settings -- the only things persisted so far)
  core/init.lua       -- namespace (Bubble) + central event dispatcher, same
                      -- pattern as Aegis_Exchange/core/init.lua; also the
                      -- OnLoad queue (hard rule #9) AND BubbleCharDB's own
                      -- initialization -- one canonical place for "the DB
                      -- exists," not each module doing it redundantly
  core/identity.lua   -- §0.3 message keying: eligible-event allowlist, the
                      -- raw-event hash, the short-lived recent-key buffer
  core/config.lua     -- §2.5 per-character settings (currently just
                      -- showPills) + the /bubble slash command
  core/channel.lua    -- §0.1 hidden channel join/rejoin + §0.2 presence stub;
                      -- SendChatMessage/CHAT_MSG_CHANNEL wire format (NOT
                      -- SendAddonMessage -- confirmed on the HDBDEV client
                      -- that "CHANNEL" isn't a recognized addon chat type)
  core/reactions.lua  -- §2.3 reaction state (set membership, not a counter)
                      -- + §1.2 pill rendering (§2.5: gated behind
                      -- B.config.Get("showPills"), off by default --
                      -- state/overlay/hover all stay unconditional)
  core/picker.lua     -- §2.2 the emoji picker -- all 5 icons in one row,
                      -- cursor-anchored, click-outside-to-close
  core/overlay.lua    -- §2.4 movable "latest interaction" indicator +
                      -- fading label + hover history; NOT the drift-prone
                      -- per-line badge §3.1 rejected -- tracks no line
                      -- position at all
  core/chat.lua       -- §1.1 AddMessage/SetItemRef hooks (the click
                      -- affordance; routes left/right-click between a
                      -- quick toggle and opening the picker)
  core/hover.lua      -- §1.5 live tally on hover, via GameTooltip
```

**Confirmed working end-to-end on the HDBDEV client, cross-character,
across busy channels (World chat) and `%`-containing messages, as of
2026-09-29.** Eight real bugs surfaced during testing and were fixed
(recorded in `ROADMAP.md` §0.1/§0.3/§1.2 for the full story, since the
reasoning behind each *wrong* first attempt is worth keeping, not just the
fix):
1. `SendAddonMessage` doesn't accept chat type `"CHANNEL"` on this client
   (`"Unknown addon chat type"`) — switched to plain
   `SendChatMessage`/`CHAT_MSG_CHANNEL`, with the channel's display stripped
   via `ChatFrame_RemoveChannel`.
2. A literal `|` in the wire-format prefix got the message rejected by
   SuperCleveRoidMacros' `SendChatMessage` hook (`|` is WoW's own
   escape-code character) — switched the delimiter to `:`.
3. `CHAT_MSG_CHANNEL`'s `arg4` came back in different casing than
   `JoinChannelByName` was called with, and a case-sensitive match was
   silently dropping every cross-character reaction with no error at all —
   fixed by lowercasing both sides of the comparison.
4. A debug print called `:AddMessage()` from inside the `AddMessage` hook
   itself, which re-entered the whole hook chain (ours plus pfUI's
   `chatcopy.lua`) and crashed with a stack overflow. Established the hard
   rule below.
5. The original message-identity mechanism (a snapshot taken by a handler
   on a separate dispatcher frame) silently failed to tag messages on busy
   channels (World chat) — frame dispatch order under bursty traffic put
   `AddMessage` before our own snapshot, not after. Fixed by reading
   `event`/`arg1`/`arg2` directly inside the hook instead.
6. The reaction pill always rendered on `DEFAULT_CHAT_FRAME`, which is the
   wrong window for any message pfUI routes off `ChatFrame1` (World/Trade
   land on `ChatFrame3`). Fixed by remembering which frame(s) a message was
   actually tagged on and rendering there instead.
7. That fix didn't work on the first attempt: `ID.MakeKey` returned a Lua
   *number*, but every other entry point into a message key (a clicked
   hyperlink, the wire protocol) only ever produces a *string* — `t[123]`
   and `t["123"]` are different table entries in Lua, so `knownFrames`
   writes were invisible to its own reads. Fixed by having `MakeKey` return
   `tostring(...)`.
8. A message containing `%` never got tagged at all — the raw `CHAT_MSG_*`
   event text arrives with `%` doubled (`"%%"` for a literal `%`), while
   the rendered text has already been un-escaped to a single `%`. Fixed by
   running the same un-escape (`string.gsub(arg1, "%%%%", "%%")`) before
   matching.

All temporary debug instrumentation from that round (`B.debugLog`,
`/bubbledebug`, the `NOMATCH` logging) was removed once those eight were
confirmed fixed.

**Since then, in a follow-up session:** real icon art (five Twemoji-derived
TGAs, confirmed rendering in-game, not just format-correct — see §1.4),
two more live-client bugs found and fixed (the pill rendering on the wrong
chat frame, then a key-type mismatch that broke the first fix's own
tracking — see ROADMAP.md §1.2), and a design refinement (the pill quotes
who said the reacted-to message and a snippet of it, so it stays
unambiguous even if other messages interleave). `core/hover.lua` (§1.5,
live tally on hover via `GameTooltip`) is added and **confirmed working
live**, after the full restart its new `.toc` entry required.

**Retested and confirmed working (2026-09-29):** the earlier Cyrillic-text
`[+]` click issue no longer reproduces — closed, likely a casualty of one
of the bugs already fixed since that first observation rather than a
distinct problem. Still not yet tested: clicking a genuinely foreign
hyperlink (an item link, a `url:` link) to confirm the `SetItemRef`
fallthrough behaves, and behavior when pfUI is actually installed alongside
this (the pfUI verification so far is source-reading, not a live
co-install test).

A persistent, always-visible reaction badge (rather than the hover
tooltip) was researched in depth — checked ClassicAPI's and Nampower's
actual exposed functions rather than assuming, see ROADMAP.md §3.1 — and
found genuinely not possible without either a full chat-rendering rewrite
or an approximate, drift-prone overlay. Not built; §3.1 has the full
tradeoff if it's ever picked up.

**`core/picker.lua` (§2.2): the full emoji picker — confirmed working
live**, including a real case with two different emoji reacted on the same
message, each with its own correctly-quoted pill. The original message's
marker (§1.1) is now a generic `bubble:KEY` link (no emoji baked in) that
opens the picker on either click; a pill's own `bubble:KEY:EMOJI` link
keeps quick-toggling that one emoji on left-click, opens the picker on
right-click. Also confirmed: hovering the marker now shows a
multi-emoji breakdown via `core/hover.lua` (a real regression caught and
fixed the same session — see ROADMAP.md §2.2).

**The marker itself is now a real icon, not literal `[+]` text**
(Twemoji's "heavy plus sign", `textures/add.tga`) — deliberately kept out
of `core/reactions.lua`'s `B.icons` table since `core/picker.lua` iterates
that to build its selectable row, and the marker icon showing up there
would make it a bogus 6th "reaction choice."

**Known cosmetic limitation, not a bug in our code:** a `|T...|t` texture
escape wraps as a single unit, same as a long word — a long message
(especially in the narrower "Loot & Spam" panel) can push the marker onto
its own wrapped line. No fix available; this is inherent to how chat text
reflows and there's no layout control to work around it. This is exactly
what motivated §2.4 below.

**`core/overlay.lua` (§2.4): a movable "latest interaction" indicator —
confirmed working live (2026-09-29).** Correctly stays hidden until the
first reaction of the session, since it's built lazily inside `ShowEvent`
rather than unconditionally at load. Genuinely different from, and NOT a
revival of, the per-line badge §3.1 already rejected — this tracks no line
position at all, it's a normal draggable frame showing only the most
recent reaction (icon + fading `sender: snippet` label), with a hover
history. First use of SavedVariables in this addon (`BubbleCharDB`,
per-character); see hard rule #9 above.

**`core/config.lua` (§2.5) added: chat pills are now off by default.**
A live screenshot review showed the pill line crowding out real chat once
the overlay existed as a lighter always-visible alternative. `/bubble
pills on`/`/bubble pills off` toggles it — a slash command chosen over a
graphical options panel for now, since it gets the same practical result
for far less work. Gates only the chat `AddMessage` call in
`RenderPill` — reaction state, the overlay, and hover tooltips are all
unconditional regardless of this setting. **Not yet tested live.**

**Security review (§2.6), prompted by a direct question, not a bug
report, then a follow-up pass once asked to think at scale:** four real
findings, all fixed. `key`/`emoji` reaching `ToggleMine`/`ApplyRemote`
were never validated, and they're untrusted from two sources — a clicked
hyperlink (WoW renders `|H...|h` as a clickable link in *any* chat text,
not just ours, so a plain typed message in public chat can carry a
hand-crafted `bubble:` link) and the hidden channel itself (no access
control, anyone can `/join` it). Unvalidated `emoji` could inject a fake
hyperlink into text rendered as if it came from us. Fixed with
`IsValidEmoji` (whitelist) / `IsValidKey` (digit-only, ≤10 chars) guarding
both functions. Quoted message snippets (§1.2) re-embed the *original
speaker's* raw text into new rendered strings without escaping — fixed
with `EscapePipes` (doubles `|`, WoW's own literal-pipe convention) at
`RememberOrigin`. On the follow-up pass: `knownFrames`/`originOf` tag
*every* eligible message ever displayed, not just reacted-to ones — that's
unbounded growth from ordinary busy-channel traffic alone, no attacker
required — fixed with `TouchKey`, a 500-key cap with oldest-first eviction
kept in sync across `state`/`originOf`/`knownFrames`. No incoming rate
limit — fixed, per-sender (not global, so one flooder can't suppress
everyone else's real reactions too), 10 messages per 5s window. **A real
scoping bug was caught and fixed while building the eviction cap** — see
`ROADMAP.md` §2.6 for what happened and why `luac -p` wouldn't have caught
it. **Validation confirmed live (2026-09-30)** via
`/run Bubble.reactions.ApplyRemote(...)` with bogus emoji/key (both
silently rejected) and a valid-shaped fabricated key (correctly accepted —
the contrast case that proves the guard discriminates rather than just
always failing). **Rate limiter also confirmed live (2026-09-30)** — a
15-message burst via `/run`-driven `Broadcast` on a second character
landed roughly 10 of 15 on the receiver, matching the cap (and ruling out
the client's own baseline chat throttle as a confound, since the burst
clearly wasn't being bottlenecked there). Only the 500-key eviction cap is
still unconfirmed live — needs genuinely heavy sustained traffic to
trigger naturally, lower priority than the other three.
