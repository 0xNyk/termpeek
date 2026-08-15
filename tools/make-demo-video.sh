#!/usr/bin/env bash
# Build the demo video from real termpeek output.
#
# Frames are generated, not screen-recorded. Recording a terminal captures
# whatever else is on screen and produces something nobody can regenerate; this
# renders the actual bytes each command writes, so the video rebuilds from
# source and contains nothing but the tool's own output.
#
#   tools/make-demo-video.sh [outdir]
#
# Produces demo.mp4 (for X) and demo.gif (for the README).

set -uo pipefail

ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$ROOT/assets/video}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/tp-video.XXXXXX")"
A2S="$ROOT/tools/ansi2svg.py"
TP="$ROOT/scripts/termpeek"

FPS=30
W=1280
H=720

mkdir -p "$OUT" "$WORK/frames"
n=0

# Append the same still for a number of seconds. Cheap: ffmpeg is asked for a
# frame count at the end rather than being run per frame.
hold() {
  local png="$1" secs="$2"
  local count; count=$(python3 -c "print(int($FPS*$secs))")
  local i
  for ((i=0; i<count; i++)); do
    printf -v name '%06d' "$n"
    cp "$png" "$WORK/frames/$name.png"
    n=$((n+1))
  done
}

# Render an ANSI capture to a PNG at video size, letterboxed on the dark ground
# so every frame is exactly WxH and ffmpeg never has to rescale mid-stream.
to_frame() {
  local svg="$1" out="$2"
  rsvg-convert -w $((W-120)) -o "$WORK/tmp.png" "$svg" 2>/dev/null || return 1
  # Bound BOTH dimensions. Scaling on width alone makes a portrait source (a PDF
  # page, say) taller than the frame, and pad cannot shrink — it fails with
  # "padded dimensions cannot be smaller than input dimensions" and the scene
  # silently drops out of the video.
  ffmpeg -y -i "$WORK/tmp.png" -vf \
    "scale=w=$((W-120)):h=$((H-80)):force_original_aspect_ratio=decrease,pad=$W:$H:(ow-iw)/2:(oh-ih)/2:0x0d1117" \
    -frames:v 1 "$out" >/dev/null 2>&1
}

# The README demo assets already carry terminal chrome — a title bar and a
# prompt line. Wrapping them again produced two of each. Scale and letterbox
# them as they are.
raw_frame() {
  local png="$1" out="$2"
  ffmpeg -y -i "$png" -vf \
    "scale=w=$((W-120)):h=$((H-80)):force_original_aspect_ratio=decrease,pad=$W:$H:(ow-iw)/2:(oh-ih)/2:0x0d1117" \
    -frames:v 1 "$out" >/dev/null 2>&1
}

# A typing effect: reveal the command one character at a time. This is the part
# that makes a terminal clip readable — a command that appears instantly gives
# the viewer nothing to follow.
type_line() {
  local text="$1" secs="${2:-1.2}"
  local len=${#text}
  local per; per=$(python3 -c "print(max(1,int($FPS*$secs/max(1,$len))))")
  local i j
  for ((i=1; i<=len; i++)); do
    local shown="${text:0:i}"
    printf '\033[2m$\033[0m %s\033[7m \033[0m\n' "$shown" \
      | python3 "$A2S" --bare --min-cols 74 -o "$WORK/type.svg" >/dev/null
    to_frame "$WORK/type.svg" "$WORK/type.png" || return 1
    for ((j=0; j<per; j++)); do
      printf -v name '%06d' "$n"; cp "$WORK/type.png" "$WORK/frames/$name.png"; n=$((n+1))
    done
  done
}

say() { printf '\033[36m%s\033[0m\n' "$1" >&2; }

# --- scenes -----------------------------------------------------------------
FIX="$ROOT/tests/fixtures"
[[ -s "$FIX/test.png" ]] || "$ROOT/tests/run.sh" >/dev/null 2>&1

# A two-line fixture diff reads as a toy. Build a real one from the repo's own
# history so the scene shows what a working diff actually looks like.
git -C "$ROOT" diff "HEAD~1" -- lib/ > "$WORK/code.diff" 2>/dev/null
[[ -s "$WORK/code.diff" ]] || cp "$FIX/test.diff" "$WORK/code.diff"

say "scene 1: the problem"
{
  printf '\033[2m$\033[0m claude\n\n'
  printf '\033[38;5;114m>\033[0m chart the p95 latency by region\n\n'
  printf '  Wrote \033[1mout/latency.svg\033[0m\n\n'
  printf '\033[31m  Read image (42 KB)\033[0m\n\n'
  printf '\033[2m  ...the agent can see it. you cannot.\033[0m\n'
} | python3 "$A2S" --bare --min-cols 74 -o "$WORK/s1.svg" >/dev/null
to_frame "$WORK/s1.svg" "$WORK/s1.png" && hold "$WORK/s1.png" 3.2

say "scene 2: typing the fix"
type_line "termpeek out/latency.svg" 1.1

say "scene 3: the image, actually rendered"
rsvg-convert -w $((W-160)) -o "$WORK/chart.png" "$ROOT/assets/readme/protocol-frames.svg" 2>/dev/null
python3 "$A2S" --image "$WORK/chart.png" --title "termpeek" \
  --prompt "termpeek out/latency.svg" -o "$WORK/s3.svg" >/dev/null
to_frame "$WORK/s3.svg" "$WORK/s3.png" && hold "$WORK/s3.png" 3.0

say "scene 4: a diff, side by side"
"$TP" --here -g 150x34 "$WORK/code.diff" 2>/dev/null \
  | python3 "$A2S" --bare --min-cols 92 -o "$WORK/s4.svg" >/dev/null
to_frame "$WORK/s4.svg" "$WORK/s4.png" && hold "$WORK/s4.png" 2.6

say "scene 5: a PDF as paper"
raw_frame "$ROOT/assets/readme/demo-pdf.png" "$WORK/s5.png" \
  || { echo "scene 5 failed to render" >&2; exit 1; }
hold "$WORK/s5.png" 2.6

say "scene 6: X posts"
raw_frame "$ROOT/assets/readme/demo-gallery.png" "$WORK/s6.png" && hold "$WORK/s6.png" 2.8

say "scene 7: the sidebar"
raw_frame "$ROOT/assets/readme/demo-sidebar.png" "$WORK/s7.png" && hold "$WORK/s7.png" 3.0

say "scene 8: close"
{
  printf '\n'
  printf '  \033[1mtermpeek\033[0m\n\n'
  printf '  images · video · PDFs · diffs · X posts\n'
  printf '  \033[2minside Claude Code, Codex, Hermes\033[0m\n\n'
  printf '  \033[36mgithub.com/0xNyk/termpeek\033[0m\n'
} | python3 "$A2S" --bare --min-cols 74 -o "$WORK/s8.svg" >/dev/null
to_frame "$WORK/s8.svg" "$WORK/s8.png" && hold "$WORK/s8.png" 3.0

# --- encode -----------------------------------------------------------------
say "encoding $n frames"

# yuv420p and even dimensions, or X and most players refuse to decode it.
ffmpeg -y -framerate $FPS -i "$WORK/frames/%06d.png" \
  -c:v libx264 -pix_fmt yuv420p -profile:v high -level 4.0 \
  -movflags +faststart -crf 20 "$OUT/demo.mp4" >/dev/null 2>&1 \
  || { echo "encode failed" >&2; exit 1; }

# A palette pass, otherwise the gif dithers the terminal background into mush.
ffmpeg -y -i "$OUT/demo.mp4" -vf "fps=15,scale=900:-1:flags=lanczos,palettegen=stats_mode=diff" \
  "$WORK/pal.png" >/dev/null 2>&1
ffmpeg -y -i "$OUT/demo.mp4" -i "$WORK/pal.png" \
  -lavfi "fps=15,scale=900:-1:flags=lanczos[x];[x][1:v]paletteuse=dither=bayer:bayer_scale=3" \
  "$OUT/demo.gif" >/dev/null 2>&1

rm -rf "$WORK"
ls -la "$OUT"
