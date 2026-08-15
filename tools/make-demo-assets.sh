#!/usr/bin/env bash
# Regenerate the demo-project media assets.
#
#   tools/make-demo-assets.sh
#
# These are checked in so the README demo and a live `tp-session` walkthrough
# both work from a fresh clone, but they are GENERATED rather than captured —
# a committed binary nobody can rebuild is a dead end the moment the demo
# changes.
#
# render.mp4 used to be the 240x136 mandelbrot test fixture copied into place.
# timg refuses to enlarge a source past its native size, so it drew 15x5 cells
# in a 70x30 pane and read as "the video did not show at all". Demo assets need
# to be bigger than the pane that shows them.

set -uo pipefail

ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/assets/demo-project/out"
W=1280
H=720
FPS=30
SECS=4

for bin in rsvg-convert ffmpeg; do
  command -v "$bin" >/dev/null 2>&1 || { echo "$bin required" >&2; exit 127; }
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/tp-assets.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$OUT"

# The same p95-by-region data the demo's chart and diff talk about, so the
# video is the animated form of the file next to it rather than unrelated
# filler.
REGIONS=(us-east-1 us-west-2 eu-west-1 ap-south-1)
VALUES=(118 104 247 163)
MAXV=280

total=$(( FPS * SECS ))
for (( f = 0; f < total; f++ )); do
  # Ease-out so the bars settle rather than stopping dead, and hold the final
  # frame for the last third instead of looping straight back to zero.
  num=$(( f * 3 ))
  pct=$(( num * 100 / total ))
  (( pct > 100 )) && pct=100
  ease=$(( 100 - (100 - pct) * (100 - pct) / 100 ))

  {
    printf '<svg xmlns="http://www.w3.org/2000/svg" width="%s" height="%s" viewBox="0 0 %s %s">' "$W" "$H" "$W" "$H"
    printf '<rect width="%s" height="%s" fill="#0d1117"/>' "$W" "$H"
    printf '<g font-family="Helvetica, Arial, sans-serif">'
    printf '<text x="80" y="96" fill="#e6edf3" font-size="34" font-weight="600">p95 latency by region</text>'
    printf '<text x="80" y="132" fill="#7d8590" font-size="20">milliseconds · last 24h</text>'

    y=210
    for i in "${!REGIONS[@]}"; do
      v="${VALUES[$i]}"
      shown=$(( v * ease / 100 ))
      barw=$(( shown * (W - 460) / MAXV ))
      (( barw < 1 )) && barw=1
      colour="#3b82f6"
      (( v > 200 )) && colour="#f97316"
      printf '<text x="330" y="%s" fill="#e6edf3" font-size="24" text-anchor="end">%s</text>' \
        "$(( y + 30 ))" "${REGIONS[$i]}"
      printf '<rect x="360" y="%s" width="%s" height="44" rx="6" fill="%s"/>' "$y" "$barw" "$colour"
      printf '<text x="%s" y="%s" fill="#e6edf3" font-size="22" font-weight="600">%s</text>' \
        "$(( 360 + barw + 18 ))" "$(( y + 30 ))" "$shown"
      y=$(( y + 108 ))
    done

    printf '<line x1="360" y1="190" x2="360" y2="%s" stroke="#30363d" stroke-width="2"/>' "$(( y - 40 ))"
    printf '</g></svg>'
  } > "$WORK/f.svg"

  rsvg-convert -w "$W" -h "$H" -o "$(printf '%s/f%04d.png' "$WORK" "$f")" "$WORK/f.svg" 2>/dev/null
done

# yuv420p for players that reject other pixel formats; even dimensions are a
# hard requirement of libx264 and it fails quietly enough to leave a 0-byte
# file behind.
ffmpeg -y -framerate "$FPS" -i "$WORK/f%04d.png" \
  -c:v libx264 -pix_fmt yuv420p -crf 18 -movflags +faststart \
  "$OUT/render.mp4" >/dev/null 2>&1

[[ -s "$OUT/render.mp4" ]] || { echo "render.mp4 was not produced" >&2; exit 1; }
ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 "$OUT/render.mp4" \
  | xargs printf 'render.mp4  %s\n'
du -h "$OUT/render.mp4" | awk '{printf "  %s\n", $1}'
