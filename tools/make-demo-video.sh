#!/usr/bin/env bash
# Build the demo video from real termpeek output, scene by scene.
#
#   tools/make-demo-video.sh [outdir]
#
# Each scene is rendered at its own natural size and framed individually, so
# nothing is scaled up to fill a shape it does not fit. The screen-capture
# recorder has to guess where content ends; here the size is known, so there is
# no crop step and nothing can be clipped — which is what made an earlier cut
# look zoomed in.
#
# Frames are generated, not screen-recorded: recording a terminal captures
# whatever else is on screen, and produces a bitmap nobody can regenerate.

set -uo pipefail

ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$ROOT/assets/video}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/tp-video.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

A2S="$ROOT/tools/ansi2svg.py"
TP="$ROOT/scripts/termpeek"
FIX="$ROOT/tests/fixtures"
FPS=30

command -v rsvg-convert >/dev/null 2>&1 || { echo "rsvg-convert required" >&2; exit 127; }
mkdir -p "$OUT" "$WORK/clips"
say() { printf '\033[36m%s\033[0m\n' "$1" >&2; }

# A still held for N seconds, at its own size. Dimensions are forced even for
# x264; nothing is stretched.
still_clip() {
  local png="$1" secs="$2" out="$3"
  ffmpeg -y -loop 1 -i "$png" -t "$secs" -r "$FPS" \
    -vf "scale=trunc(iw/2)*2:trunc(ih/2)*2" \
    -c:v libx264 -pix_fmt yuv420p -crf 18 "$out" >/dev/null 2>&1
}

# ANSI text -> PNG at natural size, rendered at 2x for crisp type.
ansi_png() {
  local out="$1" cols="$2"
  python3 "$A2S" --bare --min-cols "$cols" -o "$WORK/t.svg" >/dev/null || return 1
  rsvg-convert -z 2 -o "$out" "$WORK/t.svg"
}

# Stack a prompt line above an image, both padded onto the terminal background.
# vstack requires both inputs to be the SAME width, and pad can only grow. So
# pad BOTH to whichever is wider — padding only the body fails whenever the
# prompt line happens to be longer, which silently dropped a whole scene.
stack() {
  local head="$1" body="$2" out="$3"
  local hw bw w
  hw="$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of csv=p=0 "$head")"
  bw="$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of csv=p=0 "$body")"
  [[ -n "$hw" && -n "$bw" ]] || return 1
  w=$(( hw > bw ? hw : bw ))
  ffmpeg -y -i "$head" -i "$body" -filter_complex \
    "[0:v]pad=${w}:ih+26:0:8:0x0d1117[h];[1:v]pad=${w}:ih:0:0:0x0d1117[b];[h][b]vstack=inputs=2,pad=iw+52:ih+44:26:22:0x0d1117" \
    -frames:v 1 "$out" >/dev/null 2>&1
}

# --- content ----------------------------------------------------------------
[[ -s "$FIX/test.png" ]] || "$ROOT/tests/run.sh" >/dev/null 2>&1

mkdir -p "$WORK/before" "$WORK/after" "$WORK/cards"
cat > "$WORK/before/auth.ts" <<'BEFORE'
export async function authenticate(token: string) {
  const payload = verify(token);
  if (!payload) {
    return null;
  }
  return { userId: payload.sub, scopes: [] };
}
BEFORE
cat > "$WORK/after/auth.ts" <<'AFTER'
export async function authenticate(token: string): Promise<Session | null> {
  const payload = verify(token);
  if (!payload || payload.exp * 1000 < Date.now()) {
    return null;
  }
  const scopes = await getRoles(payload.sub);
  return { userId: payload.sub, scopes, expiresAt: payload.exp * 1000 };
}
AFTER
( cd "$WORK" && diff -u before/auth.ts after/auth.ts ) > "$WORK/change.diff" 2>/dev/null

i=1
while IFS='|' read -r text likes replies reposts; do
  cat > "$WORK/cards/c$i.json" <<CARD
{"name":"Nyk","handle":"nykdotdev","verified":true,"avatar":"","text":"$text",
 "created":"2026-08-1${i}T09:41:00.000Z","likes":$likes,"replies":$replies,"reposts":$reposts,"media":[]}
CARD
  "$ROOT/scripts/tweet-card" --from-json "$WORK/cards/c$i.json" --width 700 \
    --out "$WORK/cards/p$i.svg" >/dev/null 2>&1
  rsvg-convert -w 700 -o "$WORK/cards/p$i.png" "$WORK/cards/p$i.svg" 2>/dev/null
  i=$((i+1))
done <<'ROWS'
termpeek v0.2 - preview images, video, PDFs and diffs from inside Claude Code.|128|9|21
The terminal always supported graphics. The agent TUI was the thing in the way.|246|17|38
Added X post previews - paste a link, see the card. No API key required.|181|12|29
ROWS

# --- scenes -----------------------------------------------------------------
say "composing scenes"

{
  printf '\033[38;5;114m>\033[0m chart p95 latency by region\n\n'
  printf '  Wrote \033[1mout/latency.svg\033[0m\n\n'
  printf '\033[31m  Read image (42 KB)\033[0m\n'
  printf '\033[2m  the agent can see it. you cannot.\033[0m\n'
} | ansi_png "$WORK/s1.png" 58
still_clip "$WORK/s1.png" 3.4 "$WORK/clips/1-problem.mp4"

printf '\033[2m$\033[0m termpeek out/latency.svg\n' | ansi_png "$WORK/h2.png" 58
rsvg-convert -w 1000 -o "$WORK/chart.png" "$ROOT/assets/readme/protocol-frames.svg"
stack "$WORK/h2.png" "$WORK/chart.png" "$WORK/s2.png" \
  && still_clip "$WORK/s2.png" 3.6 "$WORK/clips/2-image.mp4"

"$TP" --here -g 150x40 "$WORK/change.diff" 2>/dev/null | ansi_png "$WORK/s3.png" 92
still_clip "$WORK/s3.png" 3.8 "$WORK/clips/3-diff.mp4"

if [[ -s "$OUT/report.pdf" ]]; then
  pdftoppm -r 150 -png -f 1 -l 1 -aa yes -aaVector yes "$OUT/report.pdf" "$WORK/pg" 2>/dev/null
  page_src="$(find "$WORK" -maxdepth 1 -name 'pg-*.png' -print -quit)"
  if [[ -n "$page_src" ]]; then
    ( source "$ROOT/lib/render.sh"; tp__pdf_frame "$page_src" "$WORK/page.png" ) >/dev/null 2>&1 \
      || cp "$page_src" "$WORK/page.png"
    printf '\033[2m$\033[0m termpeek q3-report.pdf\n' | ansi_png "$WORK/h4.png" 44
    stack "$WORK/h4.png" "$WORK/page.png" "$WORK/s4.png" \
      && still_clip "$WORK/s4.png" 3.6 "$WORK/clips/4-pdf.mp4"
  fi
fi

if [[ -s "$WORK/cards/p3.png" ]]; then
  printf '\033[2m$\033[0m termpeek --gallery posts/*.svg\n' | ansi_png "$WORK/h5.png" 58
  ffmpeg -y -i "$WORK/cards/p1.png" -i "$WORK/cards/p2.png" -i "$WORK/cards/p3.png" \
    -filter_complex "[0:v][1:v][2:v]hstack=inputs=3" -frames:v 1 "$WORK/row.png" >/dev/null 2>&1
  stack "$WORK/h5.png" "$WORK/row.png" "$WORK/s5.png" \
    && still_clip "$WORK/s5.png" 3.8 "$WORK/clips/5-posts.mp4"
fi

{
  printf '\n  \033[1mtermpeek\033[0m\n\n'
  printf '  images  video  PDFs  diffs  X posts\n'
  printf '  \033[2minside Claude Code, Codex, Hermes\033[0m\n\n'
  printf '  \033[36mgithub.com/0xNyk/termpeek\033[0m\n'
} | ansi_png "$WORK/s6.png" 50
still_clip "$WORK/s6.png" 3.4 "$WORK/clips/6-close.mp4"

# --- frame and assemble -----------------------------------------------------
shopt -s nullglob
framed=()
for c in "$WORK/clips"/*.mp4; do
  base="$(basename "$c" .mp4)"
  if "$ROOT/tools/frame-video.sh" "$c" "$WORK/${base}.f.mp4" >/dev/null 2>&1; then
    framed+=("$WORK/${base}.f.mp4")
    say "  $base"
  fi
done
(( ${#framed[@]} )) || { echo "no scenes composed" >&2; exit 1; }

: > "$WORK/list.txt"
for f in "${framed[@]}"; do printf "file '%s'\n" "$f" >> "$WORK/list.txt"; done
ffmpeg -y -f concat -safe 0 -i "$WORK/list.txt" -c copy "$OUT/demo.mp4" >/dev/null 2>&1 \
  || ffmpeg -y -f concat -safe 0 -i "$WORK/list.txt" -c:v libx264 -pix_fmt yuv420p -crf 19 "$OUT/demo.mp4" >/dev/null 2>&1 \
  || { echo "concat failed" >&2; exit 1; }

ffmpeg -y -i "$OUT/demo.mp4" -vf "fps=12,scale=760:-1:flags=lanczos,palettegen=stats_mode=diff" "$WORK/pal.png" >/dev/null 2>&1
ffmpeg -y -i "$OUT/demo.mp4" -i "$WORK/pal.png" \
  -lavfi "fps=12,scale=760:-1:flags=lanczos[x];[x][1:v]paletteuse=dither=bayer:bayer_scale=4" \
  "$OUT/demo.gif" >/dev/null 2>&1

ffprobe -v error -show_entries format=duration -of csv=p=0 "$OUT/demo.mp4" | xargs printf "demo.mp4  %ss\n"
du -h "$OUT/demo.mp4" "$OUT/demo.gif" 2>/dev/null | awk '{printf "  %s  %s\n", $1, $2}'
