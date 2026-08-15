#!/usr/bin/env bash
# Record termpeek scene by scene, then assemble.
#
#   tools/record-screen.sh [outdir]
#
# One window sized to fit every scene does not work: a PDF page, a wide diff and
# a row of post cards want completely different shapes, so a shared window
# leaves most scenes adrift in dead space. Each scene therefore gets its own
# window, its own take, and a crop to whatever it actually drew.
#
# Safety, which matters because macOS records a whole display:
#
#   1. screencapture -R bounds the video to a rect; nothing outside it is
#      captured, ever.
#   2. The rect is measured, not assumed. Each scene paints a solid colour
#      first; the script finds that block and records exactly it. If it is not
#      found, that scene is SKIPPED rather than filmed blind.
#   3. Every take is checked afterwards. A dark terminal averages dark; a take
#      that comes out bright is deleted unseen.
#
# An early version assumed a window was where it had been asked to go and
# recorded unrelated work, which is why none of the above is optional.

set -uo pipefail

ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$ROOT/assets/video}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/tp-screen.XXXXXX")"
TP="$ROOT/scripts/termpeek"

say()  { printf '\033[36m%s\033[0m\n' "$1" >&2; }
warn() { printf '\033[33m%s\033[0m\n' "$1" >&2; }
die()  { printf '\033[31m%s\033[0m\n' "$1" >&2; exit 1; }

kill_stragglers() {
  # Ghostty opens a TAB inside an existing window rather than a new window, so a
  # surviving run turns the next one into "TPREC 1 / TPREC 2" with a tab bar
  # across the top — which lands inside the recording and makes the detector
  # span both tabs.
  pkill -f 'tpscene\.sh' 2>/dev/null
  osascript -e 'tell application "Ghostty" to close (every window whose name contains "TPREC")' >/dev/null 2>&1
  sleep 1
}
trap 'kill_stragglers; rm -rf "$WORK"' EXIT

command -v screencapture >/dev/null 2>&1 || die "screencapture not found (macOS only)"
[[ -d /Applications/Ghostty.app ]] || die "Ghostty not found"
command -v rsvg-convert >/dev/null 2>&1 || die "rsvg-convert required"
mkdir -p "$OUT" "$WORK/clips"
kill_stragglers

# --- marker detection -------------------------------------------------------
find_marker() {
  local png="$1" w h
  w="$(ffprobe -v error -select_streams v:0 -show_entries stream=width  -of csv=p=0 "$png")"
  h="$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 "$png")"
  [[ -n "$w" && -n "$h" ]] || return 1
  ffmpeg -y -i "$png" -f rawvideo -pix_fmt rgb24 "$WORK/raw" >/dev/null 2>&1 || return 1
  python3 - "$WORK/raw" "$w" "$h" <<'PY'
import sys
path, w, h = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
data = open(path, 'rb').read()

# Do NOT match an exact colour. On a wide-gamut display the terminal renders
# sRGB #1157cd as something else: tolerance 20 matched one pixel here, while
# tolerance 40 matched 112,921 spread across 3125x1945. Find the most common
# strongly-blue colour actually present and lock onto that instead.
hist = {}
for y in range(0, h, 6):
    base = y*w*3
    for x in range(0, w, 6):
        i = base + x*3
        r, g, b = data[i], data[i+1], data[i+2]
        if b > r + 55 and b > g + 30 and 60 < b < 245:
            k = (r >> 3, g >> 3, b >> 3)
            hist[k] = hist.get(k, 0) + 1
if not hist:
    sys.exit(1)
(kr, kg, kb), _ = max(hist.items(), key=lambda kv: kv[1])
R, G, B, TOL = (kr << 3)+4, (kg << 3)+4, (kb << 3)+4, 14

# Bands, not a bounding box. A bounding box unions disjoint regions, and a
# second blue thing on screen once produced a rect spanning both.
rows = [0]*h; cols = [0]*w
for y in range(0, h, 2):
    base = y*w*3; rc = 0
    for x in range(0, w, 2):
        i = base + x*3
        if abs(data[i]-R) <= TOL and abs(data[i+1]-G) <= TOL and abs(data[i+2]-B) <= TOL:
            rc += 1; cols[x] += 1
    rows[y] = rc

def band(c):
    peak = max(c)
    if peak == 0: return None
    t = peak*0.5; best = cur = None
    for i in range(0, len(c), 2):
        if c[i] >= t:
            cur = [i, i] if cur is None else [cur[0], i]
        else:
            if cur and (best is None or cur[1]-cur[0] > best[1]-best[0]): best = cur
            cur = None
    if cur and (best is None or cur[1]-cur[0] > best[1]-best[0]): best = cur
    return best

rb, cb = band(rows), band(cols)
if not rb or not cb: sys.exit(1)
print(cb[0], rb[0], cb[1]-cb[0]+1, rb[1]-rb[0]+1)
PY
}

# --- one scene --------------------------------------------------------------
# record_scene <name> <cols> <rows> <font> <seconds>   with the body on stdin
record_scene() {
  local name="$1" cols="$2" rows="$3" font="$4" secs="$5"
  local body; body="$(cat)"

  kill_stragglers
  local sdir="$WORK/$name"; mkdir -p "$sdir"

  cat > "$sdir/tpscene.sh" <<STAGE
#!/bin/zsh
printf '\033]0;TPREC\007'
printf '\033[48;2;17;87;205m\033[2J\033[H'
while [ ! -f "$sdir/go" ]; do sleep 0.15; done
printf '\033[0m\033[2J\033[H'
TP="$TP"
WORK="$WORK"
ROOT="$ROOT"
$body
sleep 3
STAGE
  chmod +x "$sdir/tpscene.sh"

  open -na Ghostty.app --args \
    --window-width="$cols" --window-height="$rows" --font-size="$font" \
    --window-padding-x=16 --window-padding-y=14 \
    -e "$sdir/tpscene.sh"

  local mx my mw mh i
  mw=0; mh=0
  for ((i=0; i<20; i++)); do
    sleep 1
    screencapture -x -o "$sdir/probe.png" 2>/dev/null || continue
    if read -r mx my mw mh < <(find_marker "$sdir/probe.png"); then
      (( mw > 300 && mh > 180 )) && break
    fi
    mw=0; mh=0
  done
  rm -f "$sdir/probe.png" "$WORK/raw"

  if (( mw <= 300 || mh <= 180 )); then
    warn "  $name: window never appeared — skipped rather than filmed blind"
    kill_stragglers
    return 1
  fi

  # Points, not device pixels. Margins are per side: the Dock creeps in at the
  # bottom, tab and title bars at the top, and one symmetric inset either
  # clipped output or let one of those through.
  local rx=$(( mx / 2 + 4 ))
  local ry=$(( my / 2 + 28 ))
  local rw=$(( mw / 2 - 8 ))
  local rh=$(( mh / 2 - 56 ))
  (( rw < 200 || rh < 90 )) && { warn "  $name: region too small"; kill_stragglers; return 1; }

  touch "$sdir/go"
  screencapture -v -V "$secs" -R"$rx,$ry,$rw,$rh" "$sdir/take.mov" 2>/dev/null
  kill_stragglers
  [[ -s "$sdir/take.mov" ]] || { warn "  $name: nothing recorded"; return 1; }

  # Verify before keeping. One take came out at mean brightness 122 and was not
  # the terminal at all.
  ffmpeg -y -i "$sdir/take.mov" -vf "select=eq(n\,20),scale=1:1" -fps_mode passthrough \
    -frames:v 1 "$sdir/avg.png" >/dev/null 2>&1
  local avg
  avg="$(ffmpeg -v error -i "$sdir/avg.png" -f rawvideo -pix_fmt rgb24 - 2>/dev/null | python3 -c "
import sys; d=sys.stdin.buffer.read(); print(sum(d[:3])//3 if len(d)>=3 else 255)")"
  if [[ -z "$avg" ]] || (( avg > 95 )); then
    rm -f "$sdir/take.mov"
    warn "  $name: does not look like the terminal (brightness ${avg:-?}) — deleted"
    return 1
  fi

  # Crop to what the scene actually drew. This is the point of per-scene takes:
  # a PDF page and a wide diff want different shapes, and whichever is smaller
  # would otherwise float in dead space.
  # The threshold has to sit ABOVE the terminal background, not the pure black
  # it is nominally set to. #0d1117 measures 17, but a recorded pane reads
  # closer to 35 after the display transform, so limit=26 cropped nothing and
  # every scene kept its empty right-hand half.
  local crop
  # Sample LATE: at two seconds a scene has often only printed its prompt, so
  # any detector locks onto an empty pane and the clip comes out blank.
  local probe_at=$(( secs > 5 ? secs - 3 : 2 ))
  local cw ch
  cw="$(ffprobe -v error -select_streams v:0 -show_entries stream=width  -of csv=p=0 "$sdir/take.mov")"
  ch="$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 "$sdir/take.mov")"
  ffmpeg -y -ss "$probe_at" -i "$sdir/take.mov" -frames:v 1 -f rawvideo -pix_fmt rgb24 \
    "$sdir/probe.rgb" >/dev/null 2>&1
  # Not cropdetect: it thresholds on absolute luma, and a diff's red and green
  # line backgrounds sit at roughly the same luma as an empty pane. A limit
  # high enough to remove the background ate the content, and the remainder was
  # then scaled up to fill the card — which is what "zoomed in" looked like.
  crop="$(python3 "$ROOT/tools/content-crop.py" "$sdir/probe.rgb" "$cw" "$ch" 2>/dev/null)"
  rm -f "$sdir/probe.rgb"
  if [[ -n "$crop" ]]; then
    ffmpeg -y -i "$sdir/take.mov" -vf "${crop},pad=iw+44:ih+36:22:18:0x0d1117" \
      -c:v libx264 -pix_fmt yuv420p -crf 18 "$WORK/clips/$name.mp4" >/dev/null 2>&1
  fi
  [[ -s "$WORK/clips/$name.mp4" ]] || \
    ffmpeg -y -i "$sdir/take.mov" -c:v libx264 -pix_fmt yuv420p -crf 18 "$WORK/clips/$name.mp4" >/dev/null 2>&1
  say "  $name: $(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 "$WORK/clips/$name.mp4" 2>/dev/null)"
}

# --- content ----------------------------------------------------------------
FIX="$ROOT/tests/fixtures"
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
  "$ROOT/scripts/tweet-card" --from-json "$WORK/cards/c$i.json" --width 720 \
    --out "$WORK/cards/post-$i.svg" >/dev/null 2>&1
  i=$((i+1))
done <<'ROWS'
termpeek v0.2 - preview images, video, PDFs and diffs from inside Claude Code.|128|9|21
The terminal always supported graphics. The agent TUI was the thing in the way.|246|17|38
Added X post previews - paste a link, see the card. No API key required.|181|12|29
ROWS

# --- scenes -----------------------------------------------------------------
say "recording scenes"

record_scene problem 72 11 20 7 <<'S'
printf '\033[38;5;114m>\033[0m chart p95 latency by region\n\n'
sleep 1.4
printf '  Wrote \033[1mout/latency.svg\033[0m\n\n'
sleep 1.0
printf '\033[31m  Read image (42 KB)\033[0m\n'
printf '\033[2m  the agent can see it. you cannot.\033[0m\n'
sleep 2.4
S

record_scene image 84 19 16 8 <<'S'
printf '\033[2m$\033[0m termpeek out/latency.svg\n\n'
sleep 0.7
$TP --here -g 78x14 "$ROOT/assets/readme/protocol-frames.svg" 2>/dev/null
sleep 3.6
S

record_scene diff 96 17 15 8 <<'S'
printf '\033[2m$\033[0m termpeek --diff\n\n'
sleep 0.7
$TP --here -g 90x13 "$WORK/change.diff" 2>/dev/null
sleep 3.6
S

record_scene pdf 50 25 15 8 <<'S'
printf '\033[2m$\033[0m termpeek q3-report.pdf\n\n'
sleep 0.7
$TP --here -g 44x20 "$ROOT/assets/video/report.pdf" 2>/dev/null
sleep 3.6
S

record_scene posts 96 13 15 8 <<'S'
printf '\033[2m$\033[0m termpeek --gallery posts/*.svg\n\n'
sleep 0.7
$TP --here --gallery -g 90x9 "$WORK/cards/post-1.svg" "$WORK/cards/post-2.svg" "$WORK/cards/post-3.svg" 2>/dev/null
sleep 3.6
S

record_scene close 60 11 20 6 <<'S'
printf '\n  \033[1mtermpeek\033[0m\n\n'
printf '  images - video - PDFs - diffs - X posts\n'
printf '  \033[2minside Claude Code, Codex, Hermes\033[0m\n\n'
printf '  \033[36mgithub.com/0xNyk/termpeek\033[0m\n'
sleep 4
S

# --- assemble ---------------------------------------------------------------
# Frame each clip on its own, then concatenate: every scene is fitted to the
# card individually, which is exactly what a shared window could not do.
framed=()
for c in problem image diff pdf posts close; do
  [[ -s "$WORK/clips/$c.mp4" ]] || continue
  if "$ROOT/tools/frame-video.sh" "$WORK/clips/$c.mp4" "$WORK/clips/$c.framed.mp4" >/dev/null 2>&1; then
    framed+=("$WORK/clips/$c.framed.mp4")
  else
    warn "  $c: framing failed"
  fi
done
(( ${#framed[@]} )) || die "no scenes survived"
say "assembling ${#framed[@]} scene(s)"

: > "$WORK/list.txt"
for f in "${framed[@]}"; do printf "file '%s'\n" "$f" >> "$WORK/list.txt"; done
ffmpeg -y -f concat -safe 0 -i "$WORK/list.txt" -c copy "$OUT/screen.mp4" >/dev/null 2>&1 \
  || ffmpeg -y -f concat -safe 0 -i "$WORK/list.txt" -c:v libx264 -pix_fmt yuv420p -crf 19 "$OUT/screen.mp4" >/dev/null 2>&1 \
  || die "concat failed"

ffmpeg -y -i "$OUT/screen.mp4" -vf "fps=15,scale=900:-1:flags=lanczos,palettegen=stats_mode=diff" "$WORK/pal.png" >/dev/null 2>&1
ffmpeg -y -i "$OUT/screen.mp4" -i "$WORK/pal.png" \
  -lavfi "fps=15,scale=900:-1:flags=lanczos[x];[x][1:v]paletteuse=dither=bayer:bayer_scale=3" \
  "$OUT/screen.gif" >/dev/null 2>&1

ffprobe -v error -show_entries format=duration -of csv=p=0 "$OUT/screen.mp4" | xargs printf "duration: %ss\n"
