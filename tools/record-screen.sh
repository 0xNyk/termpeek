#!/usr/bin/env bash
# Record a real screen capture of termpeek in a dedicated window.
#
#   tools/record-screen.sh [outdir]
#
# macOS records a whole display, so the danger with any screen recording is
# capturing whatever else happens to be on screen. Two things make this safe:
#
#   1. screencapture -R bounds the video to a rectangle. Nothing outside that
#      rect reaches the file, ever.
#   2. The rect is not guessed. The demo window paints itself a unique colour
#      first; this script finds that colour in a still and uses its bounding box
#      as the rect. If the colour is not on screen the window did not come up
#      where expected, and the script ABORTS WITHOUT RECORDING rather than
#      filming the desktop.
#
# That second point is the whole design. An earlier attempt at this recorded
# unrelated work because it assumed a window was where it had been asked to go.

set -uo pipefail

ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$ROOT/assets/video}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/tp-screen.XXXXXX")"

# A colour nothing else on a desktop is likely to be showing.
MARKER_R=17; MARKER_G=87; MARKER_B=205
MARKER_HEX="1157cd"

WIN_X="${TP_WIN_X:-80}"
WIN_Y="${TP_WIN_Y:-80}"
COLS="${TP_COLS:-104}"
ROWS="${TP_ROWS:-26}"
FONT="${TP_FONT:-14}"
DURATION="${TP_DURATION:-26}"

say()  { printf '\033[36m%s\033[0m\n' "$1" >&2; }
warn() { printf '\033[33m%s\033[0m\n' "$1" >&2; }
die()  { printf '\033[31m%s\033[0m\n' "$1" >&2; cleanup; exit 1; }

cleanup() {
  osascript -e 'tell application "Ghostty" to close (every window whose name contains "TPREC")' >/dev/null 2>&1
  rm -rf "$WORK"
}
trap cleanup EXIT

command -v screencapture >/dev/null 2>&1 || die "screencapture not found (macOS only)"
[[ -d /Applications/Ghostty.app ]] || die "Ghostty not found"
mkdir -p "$OUT"

# Find the marker colour's bounding box in a PNG. Returns "x y w h" in PIXELS of
# the capture, or nothing if the colour is absent.
find_marker() {
  local png="$1" w h
  # csv option separator is ':' not ',' — a comma is parsed as another option
  # and ffprobe then prints nothing useful.
  w="$(ffprobe -v error -select_streams v:0 -show_entries stream=width  -of csv=p=0 "$png")"
  h="$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 "$png")"
  [[ -n "$w" && -n "$h" ]] || return 1
  ffmpeg -y -i "$png" -f rawvideo -pix_fmt rgb24 "$WORK/raw" >/dev/null 2>&1 || return 1
  python3 - "$WORK/raw" "$w" "$h" <<'PY'
import sys
path, w, h = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
data = open(path, 'rb').read()

# Do NOT look for the exact marker colour. On a wide-gamut display the terminal
# renders sRGB #1157cd as something else, and a tight tolerance then matches
# nothing while a loose one matches half the screen. Measured on this machine:
# tolerance 20 found 1 pixel, tolerance 40 found 112,921 spread over 3125x1945.
#
# Instead find the most common strongly-blue colour actually on screen and lock
# onto that. The marker fills a window, so it dominates its own hue by a wide
# margin regardless of how the display transformed it.
hist = {}
for y in range(0, h, 6):
    base = y*w*3
    for x in range(0, w, 6):
        i = base + x*3
        r, g, b = data[i], data[i+1], data[i+2]
        if b > r + 55 and b > g + 30 and 60 < b < 245:
            key = (r >> 3, g >> 3, b >> 3)
            hist[key] = hist.get(key, 0) + 1
if not hist:
    sys.exit(1)
(kr, kg, kb), _ = max(hist.items(), key=lambda kv: kv[1])
R, G, B, TOL = (kr << 3) + 4, (kg << 3) + 4, (kb << 3) + 4, 14

# Count matches per row and per column rather than taking the bounding box of
# every match. A bounding box unions disjoint regions: one take found a blue
# element elsewhere on screen and produced a 901x881 rect spanning both, which
# then recorded something that was not the terminal at all. The window is a
# solid block, so the dominant contiguous band in each axis is the window.
rows = [0]*h
cols = [0]*w
for y in range(0, h, 2):
    base = y*w*3
    rc = 0
    for x in range(0, w, 2):
        i = base + x*3
        if abs(data[i]-R) <= TOL and abs(data[i+1]-G) <= TOL and abs(data[i+2]-B) <= TOL:
            rc += 1
            cols[x] += 1
    rows[y] = rc

def band(counts, step):
    peak = max(counts)
    if peak == 0:
        return None
    thresh = peak * 0.5
    best = cur = None
    for i in range(0, len(counts), step):
        if counts[i] >= thresh:
            if cur is None:
                cur = [i, i]
            else:
                cur[1] = i
        else:
            if cur and (best is None or cur[1]-cur[0] > best[1]-best[0]):
                best = cur
            cur = None
    if cur and (best is None or cur[1]-cur[0] > best[1]-best[0]):
        best = cur
    return best

rb = band(rows, 2)
cb = band(cols, 2)
if not rb or not cb:
    sys.exit(1)
print(cb[0], rb[0], cb[1]-cb[0]+1, rb[1]-rb[0]+1)
PY
}

# --- the window -------------------------------------------------------------
FIX="$ROOT/tests/fixtures"
[[ -s "$FIX/test.png" ]] || "$ROOT/tests/run.sh" >/dev/null 2>&1
git -C "$ROOT" diff HEAD~1 -- lib/ > "$WORK/change.diff" 2>/dev/null
[[ -s "$WORK/change.diff" ]] || cp "$FIX/test.diff" "$WORK/change.diff"

# Phase one only paints the marker and waits, so the geometry can be measured
# before anything worth filming happens.
cat > "$WORK/stage.sh" <<STAGE
#!/bin/zsh
printf '\033]0;TPREC\007'
printf '\033[48;2;${MARKER_R};${MARKER_G};${MARKER_B}m\033[2J\033[H'
while [ ! -f "$WORK/go" ]; do sleep 0.2; done
printf '\033[0m\033[2J\033[H'
exec "$WORK/demo.sh"
STAGE
chmod +x "$WORK/stage.sh"

cat > "$WORK/demo.sh" <<DEMO
#!/bin/zsh
TP="$ROOT/scripts/termpeek"
p() { printf "\033[2m\$ \033[0m%s\n" "\$1"; }
pause() { sleep "\$1"; }

printf '\033[2J\033[H'
pause 1
printf '\033[38;5;114m>\033[0m chart p95 latency by region\n\n'
pause 1.2
printf '  Wrote \033[1mout/latency.svg\033[0m\n\n'
pause 0.8
printf '\033[31m  Read image (42 KB)\033[0m\n'
printf '\033[2m  the agent can see it. you cannot.\033[0m\n\n'
pause 2.2

p "termpeek out/latency.svg"
pause 0.6
\$TP --here -g 92x22 "$ROOT/assets/readme/protocol-frames.svg" 2>/dev/null
pause 3.2

printf '\033[2J\033[H'
p "termpeek --diff"
pause 0.5
\$TP --here -g 100x24 "$WORK/change.diff" 2>/dev/null
pause 3.4

printf '\033[2J\033[H'
p "termpeek q3-report.pdf"
pause 0.5
\$TP --here -g 74x24 "$ROOT/assets/video/report.pdf" 2>/dev/null || \\
  \$TP --here -g 74x24 "$ROOT/assets/readme/demo-pdf.png" 2>/dev/null
pause 3.2

printf '\033[2J\033[H'
p "termpeek https://x.com/nykdotdev/status/20"
pause 0.5
\$TP --here -g 92x18 "$ROOT/assets/readme/demo-gallery.png" 2>/dev/null
pause 3.2

printf '\033[2J\033[H\n'
printf '  \033[1mtermpeek\033[0m\n\n'
printf '  images · video · PDFs · diffs · X posts\n'
printf '  \033[2minside Claude Code, Codex, Hermes\033[0m\n\n'
printf '  \033[36mgithub.com/0xNyk/termpeek\033[0m\n'
sleep 6
DEMO
chmod +x "$WORK/demo.sh"

say "opening a dedicated window"
open -na Ghostty.app --args \
  --window-position-x="$WIN_X" --window-position-y="$WIN_Y" \
  --window-width="$COLS" --window-height="$ROWS" \
  --font-size="$FONT" --window-padding-x=14 --window-padding-y=12 \
  -e "$WORK/stage.sh"

# --- locate it, or refuse ---------------------------------------------------
say "locating the window by its marker colour"
# Search the whole display rather than a guessed rect: Ghostty may ignore a
# requested position and centre the window, and a probe anchored to the request
# then misses it. The probe still is only ever fed to colour detection and is
# deleted immediately — it is never displayed, and the VIDEO is still bounded to
# the rect this finds.
# Poll rather than sleeping a fixed amount. How long a window takes to appear
# varies, and a fixed wait either fails on a slow launch or pads every run.
# A region only counts once it is plausibly window-sized, which also rejects a
# stray blue pixel somewhere else on screen.
mx=""; my=""; mw=0; mh=0
for attempt in $(seq 1 25); do
  sleep 1
  screencapture -x -o "$WORK/probe.png" 2>/dev/null || continue
  SEARCH_W="$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of csv=p=0 "$WORK/probe.png" 2>/dev/null)"
  [[ -n "$SEARCH_W" ]] || continue
  if read -r mx my mw mh < <(find_marker "$WORK/probe.png"); then
    (( mw > 400 && mh > 300 )) && break
  fi
  mw=0; mh=0
done

(( mw > 400 && mh > 300 )) || die "marker colour #$MARKER_HEX never appeared at a window-sized region.
Refusing to record: a rect chosen blind would capture whatever else is there."

# The probe is in device pixels; screencapture -R takes points. On a retina
# display those differ by 2, so the marker's pixel bounds must be divided back
# down before they can be used as a rect.
# The probe is the full display in device pixels. Points = pixels / backing
# scale, which we get from the display's logical width.
LOGICAL_W="$(osascript -e 'tell application "Finder" to get bounds of window of desktop' 2>/dev/null | awk -F', ' '{print $3}')"
SCALE=1
if [[ -n "$LOGICAL_W" && "$LOGICAL_W" -gt 0 ]]; then
  SCALE=$(( (SEARCH_W + LOGICAL_W / 2) / LOGICAL_W ))
fi
(( SCALE < 1 )) && SCALE=1

RX=$(( mx / SCALE ))
RY=$(( my / SCALE ))
RW=$(( mw / SCALE ))
RH=$(( mh / SCALE ))
# Inset before recording, and asymmetrically. The marker bounding box hugs the
# window, but the Dock auto-hides: it is absent when the marker is measured and
# slides up OVER the window during the take. A symmetric inset both clipped the
# first line of output and still let a strip of Dock icons in, so the bottom
# gets a much deeper margin than the other sides.
INSET="${TP_INSET:-4}"
INSET_BOTTOM="${TP_INSET_BOTTOM:-56}"
RX=$(( RX + INSET )); RY=$(( RY + INSET ))
RW=$(( RW - INSET * 2 )); RH=$(( RH - INSET - INSET_BOTTOM ))
(( RW < 200 || RH < 120 )) && die "marker region is implausibly small (${RW}x${RH}) — refusing to record"

rm -f "$WORK/probe.png" "$WORK/raw"
say "window found at ${RX},${RY} ${RW}x${RH} (scale ${SCALE}x)"

# --- record -----------------------------------------------------------------
say "recording ${DURATION}s, bounded to that rect only"
touch "$WORK/go"
screencapture -v -V "$DURATION" -R"$RX,$RY,$RW,$RH" "$WORK/raw.mov" 2>/dev/null
[[ -s "$WORK/raw.mov" ]] || die "screencapture produced nothing"

# --- verify what was actually filmed ----------------------------------------
# The rect was correct a moment ago, but confirm the footage really is the demo
# before it is kept. A dark terminal averages dark; a desktop generally does not.
ffmpeg -y -i "$WORK/raw.mov" -vf "select=eq(n\,30),scale=1:1" -fps_mode passthrough -frames:v 1 "$WORK/avg.png" >/dev/null 2>&1
AVG="$(ffmpeg -v error -i "$WORK/avg.png" -f rawvideo -pix_fmt rgb24 - 2>/dev/null | python3 -c "
import sys
d=sys.stdin.buffer.read()
print(sum(d[:3])//3 if len(d)>=3 else 255)")"
if [[ -z "$AVG" ]] || (( AVG > 90 )); then
  rm -f "$WORK/raw.mov"
  die "footage does not look like the demo terminal (mean brightness ${AVG:-?}). Deleted it rather than keep something unverified."
fi
say "footage verified (mean brightness $AVG)"

# --- encode -----------------------------------------------------------------
# Bound BOTH dimensions before padding. Scaling on width alone makes a source
# taller than 720 whenever it is narrower than 16:9, and pad cannot shrink —
# the encode fails outright after the recording has already been taken.
ffmpeg -y -i "$WORK/raw.mov" \
  -vf "scale=w=1280:h=720:force_original_aspect_ratio=decrease:flags=lanczos,pad=1280:720:(ow-iw)/2:(oh-ih)/2:0x0d1117,fps=30" \
  -c:v libx264 -pix_fmt yuv420p -profile:v high -level 4.0 \
  -movflags +faststart -crf 20 "$OUT/screen.mp4" >/dev/null 2>&1 || die "encode failed"

ffmpeg -y -i "$OUT/screen.mp4" -vf "fps=15,scale=900:-1:flags=lanczos,palettegen=stats_mode=diff" "$WORK/pal.png" >/dev/null 2>&1
ffmpeg -y -i "$OUT/screen.mp4" -i "$WORK/pal.png" \
  -lavfi "fps=15,scale=900:-1:flags=lanczos[x];[x][1:v]paletteuse=dither=bayer:bayer_scale=3" \
  "$OUT/screen.gif" >/dev/null 2>&1

ls -la "$OUT"/screen.* 2>/dev/null
