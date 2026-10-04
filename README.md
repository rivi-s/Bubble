# Bubble

**Emoji/"like" reactions for chat, without typing.**

> Not to be confused with WoW's own world-space "chat bubbles" (the speech
> bubbles that float above a character's head for SAY/YELL/PARTY) — this
> addon reacts to text in the chat *window*. See [`ROADMAP.md`](ROADMAP.md)
> §3.2 for the one place those two concepts actually intersect.

> Built for **Turtle WoW-style 1.12 (vanilla) clients** — same environment as
> Aegis: Exchange, Altoholic and Link in this workspace. Not Classic, not
> retail. See [`DEVELOPING.md`](DEVELOPING.md) for the hard client/language rules
> before touching any code.

Phase 1 works end-to-end, confirmed on a live two-character test — see
[Status](#status). The idea: let a
player hover or click on a chat line and drop a lightweight reaction (👍 ❤️ 😂
etc.) on it instead of typing a reply. Other players running the addon see
the reaction; players without it just see the plain message, unaffected.

The interesting problems are not the UI — they're the constraints of a
20+ year old chat protocol that has no concept of message IDs, reactions, or
per-line click targets. See [`ROADMAP.md`](ROADMAP.md) for how each of those
is being worked through, and what's still an open call.

## Why this might actually get adopted

Chat reactions are a familiar, zero-effort way to acknowledge something —
people are used to them from every modern chat client. The risk isn't the
concept, it's the vanilla-client mechanics: reactions only render for people
who also have the addon, so it lives or dies on organic spread through a
guild/community rather than a server-wide feature. The design leans on
piggybacking off existing "hidden channel" comm patterns (the same trick
LFG-style addons use) so it doesn't need any server buy-in — just the addon.

## Status

**Phase 1 is working, confirmed live on two characters on the HDBDEV
client, including on a busy World-chat channel and messages containing
`%`:** react to a message, the pill renders on the same chat frame as the
message (quoting who said it and a snippet, so it's unambiguous even if
other messages interleave) and broadcasts to the other character
correctly. Real reaction icons (five, converted from Twemoji — see
[Art credits](#art-credits)), click-to-toggle, one reaction per person per
message. Ten real bugs turned up during testing and are fixed — from a
client API limitation to a key-type mismatch to a debugging mistake that
crashed the client — all written up in `ROADMAP.md`, since the
wrong-first-guess reasoning is worth keeping alongside each fix.

**Confirmed working live:** `core/hover.lua` (live tally on hover, single
emoji or a full breakdown when hovering the marker) and `core/picker.lua`
(the full emoji picker — click the marker or right-click a pill to choose
from all 5 icons, confirmed with two different reactions on the same
message at once). The marker itself is now a real icon, not literal `[+]`
text.

**Known cosmetic limitation:** a long message can push the marker onto its
own wrapped line (a texture escape wraps as a single unit, same as a long
word would) — inherent to how chat text reflows, no fix available. This is
what led to the next item.

**Confirmed working live:** `core/overlay.lua` — a small movable "latest
interaction" indicator (drag to reposition, position saved per-character).
Correctly stays hidden until the first reaction of the session — it's
built lazily, not shown unconditionally on load. Shows the most recent
reaction's icon plus a `sender: snippet` label that fades in and back out,
with a hover history of the last 10. Deliberately *not* the persistent
per-line badge idea below — tracks no line position, so it doesn't have
that idea's drift problem. First use of SavedVariables in this addon.

**Still open:** a *persistent, per-message* (always visible on that exact
line, not hover-only) reaction badge was researched in depth — checked
ClassicAPI's and Nampower's actual exposed functions, not assumed — and
found genuinely not possible without either a full chat-rendering rewrite
or an approximate, drift-prone overlay; see `ROADMAP.md` §3.1 for the full
tradeoff. Not yet tested: `SetItemRef`'s fallthrough against a genuinely
foreign hyperlink, and an actual pfUI co-install (verification so far is
source-reading, not live).

**Newly added, not yet tested live:** chat pill lines are now **off by
default** (`core/config.lua`) — a live screenshot showed them crowding out
real chat once the overlay covered the same information more lightly.
`/bubble pills on` / `/bubble pills off` to toggle. Reactions stay fully
trackable via the overlay and hover tooltips either way; this only gates
the extra chat line.

**Security review — confirmed working live:** `key`/`emoji` are untrusted
whenever they arrive from a clicked hyperlink (anyone can hand-craft one in
plain public chat — WoW renders any `|H...|h` sequence as a real link
regardless of who wrote it) or the hidden channel (no access control,
joinable by anyone). Four real issues found and fixed across two passes —
an unvalidated `emoji` could inject a fake hyperlink into our own generated
pill text; quoted message snippets re-embedded the original speaker's raw
text without escaping; `knownFrames`/`originOf` grew unbounded from
ordinary busy-channel traffic, not just a deliberate flood; and there was
no rate limit on incoming messages (now per-sender, so one flooder can't
drown out everyone else's real reactions). **Confirmed live (2026-09-30):**
a bogus emoji and a bogus key were both silently rejected while a
valid-shaped fabricated key correctly went through (proving the guard
discriminates, not just always fails), and a 15-message burst from a
second character landed roughly 10 of 15 — matching the rate limiter's cap.
Only the 500-key eviction cap is still unconfirmed live, lowest priority of
the four since it needs genuinely heavy sustained traffic to trigger. See
`ROADMAP.md` §2.6 for the full writeup, including a real scoping bug
caught while building the fix.

## Art credits

Reaction icons (`textures/thumbsup.tga`, `heart.tga`, `laugh.tga`, `wow.tga`,
`sad.tga`) and the "add a reaction" marker icon (`textures/add.tga`, from
Twemoji's "heavy plus sign") are converted from
[Twemoji](https://github.com/twitter/twemoji) 14.0.2 via `tools/svg2tga.sh`
— see `ROADMAP.md` §1.4 for why TGA and how the conversion was verified.
Twemoji graphics are Copyright 2020 Twitter, Inc and other contributors,
licensed under [CC-BY 4.0](https://creativecommons.org/licenses/by/4.0/).
