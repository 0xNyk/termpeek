#!/usr/bin/env bash
# Record the demo from the user's point of view: a real Claude Code session
# where the agent makes something and the preview simply appears.
#
#   tools/record-claude-demo.sh [outdir]
#
# Everything else in tools/ shows termpeek being driven by hand, which is not
# the product. The product is the PostToolUse hook: the agent writes a chart and
# you see it without asking. This records exactly that.
#
# Requires Ghostty to be running — `open` will not launch it from a script once
# it has fully quit.
#
# Safety is the same as record-screen.sh: the window paints a marker colour,
# the script finds that block and records only it, and refuses to record at all
# if the marker is absent.

set -uo pipefail

ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$ROOT/assets/video}"
DEMO="$ROOT/assets/demo-project"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/tp-claude.XXXXXX")"
SESSION="tpdemo$$"

COLS="${TP_COLS:-190}"
ROWS="${TP_ROWS:-34}"
FONT="${TP_FONT:-13}"
SECS="${TP_SECS:-110}"          # a real turn takes a while; trimmed later
PROMPT="${TP_PROMPT:-chart the p95 latency by region from data/latency.csv into out/latency.svg}"

say()  { printf '\033[36m%s\033[0m\n' "$1" >&2; }
warn() { printf '\033[33m%s\033[0m\n' "$1" >&2; }
die()  { printf '\033[31m%s\033[0m\n' "$1" >&2; exit 1; }

cleanup() {
  tmux kill-session -t "$SESSION" 2>/dev/null
  pkill -f 'tpclaude\.sh' 2>/dev/null
  osascript -e 'tell application "Ghostty" to close (every window whose name contains "TPREC")' >/dev/null 2>&1
  rm -rf "$WORK"
}
trap cleanup EXIT

command -v screencapture >/dev/null 2>&1 || die "screencapture not found (macOS only)"
command -v tmux >/dev/null 2>&1 || die "tmux is required for the sidebar"
command -v claude >/dev/null 2>&1 || die "claude not found on PATH"
pgrep -f "Ghostty.app/Contents/MacOS/ghostty" >/dev/null 2>&1 \
  || die "Ghostty is not running. Open it once, then re-run — 'open' cannot relaunch it from here."
mkdir -p "$OUT"

# Same detector as record-screen.sh: find the dominant strongly-blue block
# rather than an exact colour, because a wide-gamut display shifts it.
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
hist = {}
for y in range(0, h, 6):
    base = y*w*3
    for x in range(0, w, 6):
        i = base + x*3
        r, g, b = data[i], data[i+1], data[i+2]
        if b > r + 55 and b > g + 30 and 60 < b < 245:
            k = (r >> 3, g >> 3, b >> 3); hist[k] = hist.get(k, 0) + 1
if not hist: sys.exit(1)
(kr, kg, kb), _ = max(hist.items(), key=lambda kv: kv[1])
R, G, B, TOL = (kr << 3)+4, (kg << 3)+4, (kb << 3)+4, 14
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
        if c[i] >= t: cur = [i, i] if cur is None else [cur[0], i]
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

# --- a clean slate ----------------------------------------------------------
# The chart has to be MADE during the take. Leaving last run's file there means
# the agent finds nothing to do and the preview never fires.
rm -f "$DEMO/out"/*.svg 2>/dev/null
mkdir -p "$DEMO/out"
[[ -f "$DEMO/.claude/settings.json" ]] || die "demo project has no hook settings"

tmux kill-session -t "$SESSION" 2>/dev/null
tmux new-session -d -s "$SESSION" -x "$COLS" -y "$ROWS" -c "$DEMO"
tmux set -g allow-passthrough on 2>/dev/null
tmux send-keys -t "$SESSION" "clear && claude" Enter

cat > "$WORK/tpclaude.sh" <<STAGE
#!/bin/zsh
printf '\033]0;TPREC\007'
printf '\033[48;2;17;87;205m\033[2J\033[H'
while [ ! -f "$WORK/go" ]; do sleep 0.15; done
exec tmux attach -t "$SESSION"
STAGE
chmod +x "$WORK/tpclaude.sh"

say "opening the window"
open -na Ghostty.app --args \
  --window-width="$COLS" --window-height="$ROWS" --font-size="$FONT" \
  --window-padding-x=14 --window-padding-y=12 -e "$WORK/tpclaude.sh"

mx=""; my=""; mw=0; mh=0
for _ in $(seq 1 20); do
  sleep 1
  screencapture -x -o "$WORK/probe.png" 2>/dev/null || continue
  if read -r mx my mw mh < <(find_marker "$WORK/probe.png"); then
    (( mw > 500 && mh > 300 )) && break
  fi
  mw=0; mh=0
done
rm -f "$WORK/probe.png" "$WORK/raw"
(( mw > 500 && mh > 300 )) || die "marker never appeared — refusing to record blind"

RX=$(( mx / 2 + 4 )); RY=$(( my / 2 + 28 ))
RW=$(( mw / 2 - 8 )); RH=$(( mh / 2 - 56 ))
say "window at ${RX},${RY} ${RW}x${RH}"

# --- roll -------------------------------------------------------------------
touch "$WORK/go"
sleep 4                                   # let claude finish drawing its UI
say "recording ${SECS}s — sending the prompt"
screencapture -v -V "$SECS" -R"$RX,$RY,$RW,$RH" "$WORK/take.mov" 2>/dev/null &
CAP=$!
sleep 3
tmux send-keys -t "$SESSION" "$PROMPT" Enter
wait $CAP 2>/dev/null
[[ -s "$WORK/take.mov" ]] || die "nothing recorded"

# Verify it is the terminal, not something else that happened to be there.
ffmpeg -y -i "$WORK/take.mov" -vf "select=eq(n\,30),scale=1:1" -fps_mode passthrough \
  -frames:v 1 "$WORK/avg.png" >/dev/null 2>&1
AVG="$(ffmpeg -v error -i "$WORK/avg.png" -f rawvideo -pix_fmt rgb24 - 2>/dev/null | python3 -c "
import sys; d=sys.stdin.buffer.read(); print(sum(d[:3])//3 if len(d)>=3 else 255)")"
if [[ -z "$AVG" ]] || (( AVG > 95 )); then
  rm -f "$WORK/take.mov"
  die "footage does not look like the terminal (brightness ${AVG:-?}) — deleted"
fi
say "verified (brightness $AVG)"

if [[ -s "$DEMO/out/latency.svg" ]]; then
  say "the agent wrote out/latency.svg during the take"
else
  warn "no chart was written — the preview will not have fired"
fi

# A real turn spends most of its time waiting. Speed the whole thing up rather
# than cutting, so the session still reads as one continuous take.
SPEED="${TP_SPEED:-2.5}"
ffmpeg -y -i "$WORK/take.mov" -vf "setpts=PTS/${SPEED},fps=30" -an \
  -c:v libx264 -pix_fmt yuv420p -crf 19 "$WORK/fast.mp4" >/dev/null 2>&1 || die "speed-up failed"

"$ROOT/tools/frame-video.sh" "$WORK/fast.mp4" "$OUT/claude-demo.mp4" >/dev/null 2>&1 \
  || die "framing failed"

ffprobe -v error -show_entries format=duration -of csv=p=0 "$OUT/claude-demo.mp4" \
  | xargs printf "claude-demo.mp4  %ss\n"
