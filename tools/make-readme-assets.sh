#!/usr/bin/env bash
# Regenerate README demo images that show composed output.
#
#   tools/make-readme-assets.sh
#
# CONTRIBUTING requires a script for every image in the README. The gallery shot
# predated that rule and went stale: it showed three X cards in a row, which is
# only what a WIDE pane produces. The sidebar is the default transport, and it
# stacks them. An image advertising a layout the tool no longer picks is worse
# than no image.
#
# What this does is run the real composition path — tp__montage, the same
# function the gallery and PDF contact sheet call — at real sidebar geometry,
# then frame the result with the command that produces it. The picture is the
# tool's actual output, not a mock of it.

set -uo pipefail

ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/assets/readme"
A2S="$ROOT/tools/ansi2svg.py"

for bin in rsvg-convert ffmpeg python3; do
  command -v "$bin" >/dev/null 2>&1 || { echo "$bin required" >&2; exit 127; }
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/tp-readme.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$OUT"

# shellcheck source=../lib/render.sh
source "$ROOT/lib/render.sh"

# A 45% sidebar in a 180-column window, minus the rows the runner reserves.
# These are the numbers a real tp-session produces, not round ones chosen to
# flatter the result.
export TERMPEEK_CELL_PX="${TERMPEEK_CELL_PX:-8x16}"
TP_GEOMETRY="${TERMPEEK_GEOMETRY:-81x40}"

cards=()
for f in "$ROOT/assets/demo-project/posts/post-"*.svg; do
  [[ -e "$f" ]] || continue
  img="$(tp_resolve_to_image "$f")" && [[ -n "$img" ]] && cards+=("$img")
done
(( ${#cards[@]} )) || { echo "no post cards found" >&2; exit 1; }

# `auto` is what the gallery passes, so the layout below is chosen by the same
# code that runs in a session.
if ! tp__montage "$WORK/grid.png" auto "${cards[@]}"; then
  echo "montage failed" >&2
  exit 1
fi

python3 "$A2S" --image "$WORK/grid.png" \
  --prompt 'termpeek --gallery posts/*.svg' \
  --title 'termpeek — sidebar' \
  -o "$WORK/gallery.svg" || { echo "framing failed" >&2; exit 1; }

rsvg-convert -z 2 -o "$OUT/demo-gallery.png" "$WORK/gallery.svg" \
  || { echo "rasterise failed" >&2; exit 1; }
cp "$WORK/gallery.svg" "$OUT/demo-gallery.svg"

printf 'demo-gallery.png  %s  %s  (layout chosen by tp__montage at %s)\n' \
  "$(du -h "$OUT/demo-gallery.png" | cut -f1)" \
  "$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 "$OUT/demo-gallery.png" 2>/dev/null)" \
  "$TP_GEOMETRY"
