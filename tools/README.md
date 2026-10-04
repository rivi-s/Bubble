# tools/

Build-time scripts. **Nothing here ships.** No file in `tools/` is listed in
`Bubble.toc`, the 1.12 client never loads any of it, and adding a file here
is never a version bump.

## `svg2tga.sh` — reaction icon source art → in-game texture

```sh
brew install librsvg imagemagick   # once
tools/svg2tga.sh path/to/icon.svg [size] [output-name]
```

Rasterizes an SVG (e.g. a Twemoji/OpenMoji icon — see `ROADMAP.md` §1.4 for
why those are the recommended source) via `rsvg-convert`, then converts to
TGA via `magick` with flags chosen to match this client's actual TGA
expectations, not general TGA knowledge. Output lands in `textures/`,
referenced from Lua without the extension:

```lua
"|TInterface\\AddOns\\Bubble\\textures\\thumbsup:16|t"
```

### Why these specific `magick` flags, not just "export as TGA"

TGA has header-level choices (image type, bit depth, origin, alpha bits)
that don't all round-trip the same across tools, and a wrong one can mean a
texture that loads but renders wrong (or not at all) with no error message
telling you why. Rather than guess from documentation, the flags here were
verified against a texture already confirmed working in-game on this exact
client: `Aegis_Exchange/art/gradient-fill.tga` (see that addon's
`ROADMAP.md`, "A gradient out of a file" entry, and `ui/frame.lua` around
`fill_art`). Its header:

```
00 00 02 00 00 00 00 00 00 00 00 00 08 00 00 01 20 28
```

— byte 2 = `02` (uncompressed truecolor), byte 16 = `20` (32 bits/pixel),
byte 17 = `28` (8-bit alpha + top-left origin bit set). `magick <png>
-type TrueColorAlpha -depth 8 -compress none <tga>` reproduces this exactly
(checked with `xxd -l 18`, diffing against the reference file) — no extra
flags needed for origin or channel order, ImageMagick's plain TGA writer
already matches.

### What's verified and what isn't

**Verified:** the file *format* — byte-for-byte header match against a
texture already proven to load and render correctly in this exact client.
**Not yet verified:** that a texture built by *this pipeline specifically*
actually displays correctly in-game — format-correct and
renders-correctly-in-game are different claims, and only the first has been
checked so far. First real icon built with this script should be loaded
in-game and eyeballed before trusting the pipeline for a whole icon set.
