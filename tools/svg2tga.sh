#!/bin/sh
# Converts an SVG reaction icon to the exact TGA format this client expects.
# Usage: tools/svg2tga.sh <input.svg> [size] [output-name]
#   size        pixel width/height, default 32 (power-of-2 recommended)
#   output-name defaults to the input file's basename
#
# Requires: rsvg-convert (from librsvg) and magick (from imagemagick).
#   brew install librsvg imagemagick
#
# Output lands in textures/<output-name>.tga, ready to reference from Lua
# as "Interface\\AddOns\\Bubble\\textures\\<output-name>" (no extension --
# see ROADMAP.md §1.4).
#
# Format is verified byte-for-byte against Aegis_Exchange/art/gradient-fill.tga
# -- a TGA already confirmed working in-game on this exact client -- not just
# assumed from general TGA knowledge. Image type 2 (uncompressed truecolor),
# 32 bits/pixel, 8-bit alpha, top-left origin (descriptor byte 0x28). Do not
# change the `magick` flags below without re-checking that match (see
# "Verifying a new conversion" at the bottom of tools/README.md).

set -e

SVG="$1"
SIZE="${2:-32}"
NAME="${3:-$(basename "$SVG" .svg)}"

if [ -z "$SVG" ] || [ ! -f "$SVG" ]; then
  echo "usage: $0 <input.svg> [size] [output-name]" >&2
  exit 1
fi

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
OUT_DIR="$SCRIPT_DIR/../textures"
mkdir -p "$OUT_DIR"

TMP_PNG=$(mktemp -t bubble-icon).png
trap 'rm -f "$TMP_PNG"' EXIT

rsvg-convert -w "$SIZE" -h "$SIZE" -o "$TMP_PNG" "$SVG"
magick "$TMP_PNG" -type TrueColorAlpha -depth 8 -compress none "$OUT_DIR/$NAME.tga"

echo "Wrote $OUT_DIR/$NAME.tga (${SIZE}x${SIZE})"
file "$OUT_DIR/$NAME.tga"
