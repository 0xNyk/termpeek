#!/usr/bin/env bash
# Put a recording inside a presentable frame.
#
#   tools/frame-video.sh <in.mp4> <out.mp4>
#
# A raw terminal capture is a dark rectangle; on a timeline it reads as a
# screenshot someone forgot to crop. This composites it onto an animated mesh
# gradient, genuinely rounds its corners, and adds a title bar.
#
# The chrome is drawn rather than filmed. Window edges are exactly where the
# Dock, tab bars and other windows bleed in, so recording them is the one thing
# worth avoiding.
#
# Env:
#   TP_FRAME_TITLE   title bar text            (default: termpeek)
#   TP_FRAME_STATIC  1 to skip the animation   (default: animated)
#   TP_FRAME_TRIM    crop trailing blank rows  (default: 1)

set -uo pipefail

IN="${1:?usage: frame-video.sh <in.mp4> <out.mp4>}"
OUT="${2:?usage: frame-video.sh <in.mp4> <out.mp4>}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/tp-frame.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

W=1280; H=720
PAD=52
BAR=36
RADIUS=16
TITLE="${TP_FRAME_TITLE:-termpeek}"
BG_FPS=25
BG_SECS=8                       # loop length; longer looks less repetitive

command -v rsvg-convert >/dev/null 2>&1 || { echo "rsvg-convert required" >&2; exit 127; }

IW="$(ffprobe -v error -select_streams v:0 -show_entries stream=width  -of csv=p=0 "$IN")"
IH="$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 "$IN")"
DUR="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$IN")"
[[ -n "$IW" && -n "$IH" ]] || { echo "cannot read $IN" >&2; exit 1; }

# Fit inside the padded area, leaving room for the title bar.
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

# --- animated mesh ----------------------------------------------------------
# Four colour blobs drifting on sine paths. Each frame is a still; the phase is
# a full period across BG_SECS so the loop is seamless rather than jumping.
mkdir -p "$WORK/bg"
FRAMES=$(( BG_FPS * BG_SECS ))
python3 - "$WORK/bg" "$FRAMES" "$W" "$H" <<'PY'
import math, sys
out, frames, W, H = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
blobs = [
    ("#7c3aed", 0.16, 0.20, 0.10, 0.07, 0.00),
    ("#2563eb", 0.84, 0.16, 0.09, 0.08, 1.30),
    ("#06b6d4", 0.80, 0.86, 0.11, 0.06, 2.40),
    ("#db2777", 0.18, 0.84, 0.08, 0.09, 3.60),
]
for f in range(frames):
    t = 2 * math.pi * f / frames
    defs, rects = [], []
    for i, (col, cx, cy, ax, ay, ph) in enumerate(blobs):
        x = cx + ax * math.sin(t + ph)
        y = cy + ay * math.cos(t * 0.8 + ph)
        r = 0.62 + 0.06 * math.sin(t * 1.3 + ph)
        defs.append(
            f'<radialGradient id="g{i}" cx="{x*100:.2f}%" cy="{y*100:.2f}%" r="{r*100:.1f}%">'
            f'<stop offset="0%" stop-color="{col}" stop-opacity="0.95"/>'
            f'<stop offset="100%" stop-color="{col}" stop-opacity="0"/></radialGradient>')
        rects.append(f'<rect width="{W}" height="{H}" fill="url(#g{i})"/>')
    svg = (f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}">'
           f'<defs>{"".join(defs)}</defs>'
           f'<rect width="{W}" height="{H}" fill="#070912"/>'
           f'{"".join(rects)}'
           # A dark wash keeps the card readable against the brightest blobs.
           f'<rect width="{W}" height="{H}" fill="#05070f" opacity="0.34"/>'
           f'</svg>')
    open(f"{out}/{f:04d}.svg", "w").write(svg)
PY

if [[ "${TP_FRAME_STATIC:-0}" == "1" ]]; then
  rsvg-convert -w "$W" -h "$H" -o "$WORK/bg.png" "$WORK/bg/0000.svg"
  BG_INPUT=(-loop 1 -i "$WORK/bg.png")
else
  for f in "$WORK/bg"/*.svg; do
    rsvg-convert -w "$W" -h "$H" -o "${f%.svg}.png" "$f"
  done
  BG_INPUT=(-stream_loop -1 -framerate "$BG_FPS" -i "$WORK/bg/%04d.png")
fi

# --- masks and chrome -------------------------------------------------------
# A real rounded corner needs the VIDEO to carry alpha. Punching a square hole
# in an overlay leaves square corners no matter how round the card beneath is —
# which is exactly how the first version looked.
cat > "$WORK/mask.svg" <<SVG
<svg xmlns="http://www.w3.org/2000/svg" width="$VW" height="$VH">
  <rect width="$VW" height="$VH" fill="#000"/>
  <path d="M0,0 H$VW V$(( VH - RADIUS )) A$RADIUS,$RADIUS 0 0 1 $(( VW - RADIUS )),$VH
           H$RADIUS A$RADIUS,$RADIUS 0 0 1 0,$(( VH - RADIUS )) Z" fill="#fff"/>
</svg>
SVG
rsvg-convert -w "$VW" -h "$VH" -o "$WORK/mask.png" "$WORK/mask.svg"

cat > "$WORK/chrome.svg" <<SVG
<svg xmlns="http://www.w3.org/2000/svg" width="$W" height="$H">
  <defs>
    <filter id="sh" x="-25%" y="-25%" width="150%" height="150%">
      <feDropShadow dx="0" dy="18" stdDeviation="26" flood-color="#000" flood-opacity="0.55"/>
    </filter>
  </defs>
  <g filter="url(#sh)">
    <rect x="$CX" y="$CY" width="$CARD_W" height="$CARD_H" rx="$RADIUS" fill="#0d1117"/>
  </g>
  <path d="M$CX,$(( CY + BAR )) V$(( CY + RADIUS )) A$RADIUS,$RADIUS 0 0 1 $(( CX + RADIUS )),$CY
           H$(( CX + CARD_W - RADIUS )) A$RADIUS,$RADIUS 0 0 1 $(( CX + CARD_W )),$(( CY + RADIUS ))
           V$(( CY + BAR )) Z" fill="#161b22"/>
  <circle cx="$(( CX + 24 ))" cy="$(( CY + BAR/2 ))" r="6" fill="#ff5f57"/>
  <circle cx="$(( CX + 44 ))" cy="$(( CY + BAR/2 ))" r="6" fill="#febc2e"/>
  <circle cx="$(( CX + 64 ))" cy="$(( CY + BAR/2 ))" r="6" fill="#28c840"/>
  <text x="$(( CX + CARD_W/2 ))" y="$(( CY + BAR/2 + 5 ))" text-anchor="middle"
        font-family="ui-monospace, SFMono-Regular, Menlo, monospace"
        font-size="13.5" fill="#9aa4b2">$TITLE</text>
  <rect x="$CX" y="$CY" width="$CARD_W" height="$CARD_H" rx="$RADIUS"
        fill="none" stroke="#ffffff" stroke-opacity="0.13" stroke-width="1.25"/>
</svg>
SVG
rsvg-convert -w "$W" -h "$H" -o "$WORK/chrome.png" "$WORK/chrome.svg"

# --- composite --------------------------------------------------------------
# Order: animated mesh, then the card+shadow+bar, then the video with rounded
# alpha on top. Drawing the card first means its shadow falls on the mesh, and
# the video lands inside it rather than over its border.
ffmpeg -y "${BG_INPUT[@]}" -i "$IN" -i "$WORK/chrome.png" -i "$WORK/mask.png" \
  -filter_complex "\
    [1:v]scale=${VW}:${VH}:flags=lanczos,format=rgba[v]; \
    [3:v]format=gray,scale=${VW}:${VH}[m]; \
    [v][m]alphamerge[va]; \
    [0:v]scale=${W}:${H},format=rgba[bg]; \
    [bg][2:v]overlay=0:0[card]; \
    [card][va]overlay=${VX}:${VY}:shortest=1,format=yuv420p" \
  -t "${DUR:-30}" -r 30 \
  -c:v libx264 -pix_fmt yuv420p -profile:v high -level 4.0 \
  -movflags +faststart -crf 19 "$OUT" >/dev/null 2>&1 || { echo "encode failed" >&2; exit 1; }

echo "$OUT"
