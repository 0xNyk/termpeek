#!/usr/bin/env bash
# Put a recording inside a presentable frame.
#
#   tools/frame-video.sh <in.mp4> <out.mp4>
#
# A raw terminal capture is a dark rectangle; on a timeline it reads as a
# screenshot someone forgot to crop. This composites it onto a mesh gradient,
# rounds the corners, and adds a title bar — the look people expect from a
# product clip, without recording any actual window chrome.
#
# Not recording the chrome is the point: window edges are where the Dock, the
# menu bar and other windows bleed in. The frame here is drawn, so it cannot
# contain anything but the terminal.

set -uo pipefail

IN="${1:?usage: frame-video.sh <in.mp4> <out.mp4>}"
OUT="${2:?usage: frame-video.sh <in.mp4> <out.mp4>}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/tp-frame.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

W=1280; H=720
PAD="${TP_FRAME_PAD:-56}"        # gradient visible around the terminal
BAR=34                            # title bar height
RADIUS=14
TITLE="${TP_FRAME_TITLE:-termpeek}"

command -v rsvg-convert >/dev/null 2>&1 || { echo "rsvg-convert required" >&2; exit 127; }

IW="$(ffprobe -v error -select_streams v:0 -show_entries stream=width  -of csv=p=0 "$IN")"
IH="$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 "$IN")"
[[ -n "$IW" && -n "$IH" ]] || { echo "cannot read $IN" >&2; exit 1; }

# Fit the capture inside the padded area, leaving room for the title bar.
AVAIL_W=$(( W - PAD * 2 ))
AVAIL_H=$(( H - PAD * 2 - BAR ))
VW=$AVAIL_W
VH=$(( IH * VW / IW ))
if (( VH > AVAIL_H )); then
  VH=$AVAIL_H
  VW=$(( IW * VH / IH ))
fi
VW=$(( VW / 2 * 2 )); VH=$(( VH / 2 * 2 ))     # even, or libx264 refuses

CARD_W=$VW
CARD_H=$(( VH + BAR ))
CX=$(( (W - CARD_W) / 2 ))
CY=$(( (H - CARD_H) / 2 ))
VX=$CX
VY=$(( CY + BAR ))

# The frame: a full-canvas mesh gradient with a hole punched where the video
# goes, plus the title bar drawn on top. Overlaying this ABOVE the video means
# the rounded corners and the bar mask the capture rather than being composited
# under it, which is what makes the corners actually look round.
cat > "$WORK/frame.svg" <<SVG
<svg xmlns="http://www.w3.org/2000/svg" width="$W" height="$H" viewBox="0 0 $W $H">
  <defs>
    <radialGradient id="g1" cx="12%" cy="18%" r="70%">
      <stop offset="0%" stop-color="#7c3aed"/><stop offset="100%" stop-color="#7c3aed" stop-opacity="0"/>
    </radialGradient>
    <radialGradient id="g2" cx="88%" cy="12%" r="65%">
      <stop offset="0%" stop-color="#2563eb"/><stop offset="100%" stop-color="#2563eb" stop-opacity="0"/>
    </radialGradient>
    <radialGradient id="g3" cx="80%" cy="92%" r="70%">
      <stop offset="0%" stop-color="#0ea5e9"/><stop offset="100%" stop-color="#0ea5e9" stop-opacity="0"/>
    </radialGradient>
    <radialGradient id="g4" cx="18%" cy="88%" r="65%">
      <stop offset="0%" stop-color="#db2777"/><stop offset="100%" stop-color="#db2777" stop-opacity="0"/>
    </radialGradient>
    <mask id="hole">
      <rect width="$W" height="$H" fill="#fff"/>
      <rect x="$VX" y="$VY" width="$VW" height="$VH" fill="#000"/>
    </mask>
  </defs>

  <g mask="url(#hole)">
    <rect width="$W" height="$H" fill="#0b1020"/>
    <rect width="$W" height="$H" fill="url(#g1)"/>
    <rect width="$W" height="$H" fill="url(#g2)"/>
    <rect width="$W" height="$H" fill="url(#g3)"/>
    <rect width="$W" height="$H" fill="url(#g4)"/>
    <rect width="$W" height="$H" fill="#000" opacity="0.30"/>
    <!-- the card: rounded, so its corners cover the square video beneath -->
    <rect x="$CX" y="$CY" width="$CARD_W" height="$CARD_H" rx="$RADIUS" fill="#0d1117"/>
  </g>

  <rect x="$CX" y="$CY" width="$CARD_W" height="$BAR" fill="#161b22"/>
  <rect x="$CX" y="$CY" width="$CARD_W" height="$BAR" rx="$RADIUS" fill="#161b22"/>
  <rect x="$CX" y="$(( CY + BAR - RADIUS ))" width="$CARD_W" height="$RADIUS" fill="#161b22"/>
  <circle cx="$(( CX + 22 ))" cy="$(( CY + BAR/2 ))" r="6" fill="#ff5f57"/>
  <circle cx="$(( CX + 42 ))" cy="$(( CY + BAR/2 ))" r="6" fill="#febc2e"/>
  <circle cx="$(( CX + 62 ))" cy="$(( CY + BAR/2 ))" r="6" fill="#28c840"/>
  <text x="$(( CX + CARD_W/2 ))" y="$(( CY + BAR/2 + 5 ))" text-anchor="middle"
        font-family="ui-monospace, SFMono-Regular, Menlo, monospace"
        font-size="13" fill="#8b949e">$TITLE</text>
  <rect x="$CX" y="$CY" width="$CARD_W" height="$CARD_H" rx="$RADIUS"
        fill="none" stroke="#ffffff" stroke-opacity="0.10" stroke-width="1.5"/>
</svg>
SVG

rsvg-convert -w "$W" -h "$H" -o "$WORK/frame.png" "$WORK/frame.svg" || { echo "frame render failed" >&2; exit 1; }

ffmpeg -y -f lavfi -i "color=c=0x0b1020:s=${W}x${H}" -i "$IN" -i "$WORK/frame.png" \
  -filter_complex "[1:v]scale=${VW}:${VH}:flags=lanczos[v];[0:v][v]overlay=${VX}:${VY}:shortest=1[b];[b][2:v]overlay=0:0" \
  -c:v libx264 -pix_fmt yuv420p -profile:v high -level 4.0 \
  -movflags +faststart -crf 20 "$OUT" >/dev/null 2>&1 || { echo "encode failed" >&2; exit 1; }

echo "$OUT"
