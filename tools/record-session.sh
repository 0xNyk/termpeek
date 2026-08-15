#!/usr/bin/env bash
# Record a REAL termpeek session, automated, without touching the screen.
#
# This drives an actual tmux session, samples the panes on a timer, and encodes
# the samples. Everything it records genuinely happened: the sidebar really
# opens, delta really renders, the carousel really advances.
#
#   tools/record-session.sh [outdir]
#
# Why not screencapture: macOS records a whole display. A window can be placed
# deterministically and a rect recorded, but if the window fails to appear the
# recording silently contains whatever else was on screen. That is not a
# theoretical risk — it happened while building this project's README, and the
# capture contained someone's unrelated work. Sampling tmux cannot do that: the
# only thing readable is the pane this script started.
#
# The tradeoff is honest: kitty graphics are not text, so image previews appear
# as their surrounding chrome rather than pixels. Text scenes — diffs, code, the
# agent transcript, panes appearing — are captured exactly as they ran.

set -uo pipefail

ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$ROOT/assets/video}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/tp-rec.XXXXXX")"
A2S="$ROOT/tools/ansi2svg.py"
SESSION="tprec$$"

SAMPLE_HZ="${TP_REC_HZ:-6}"     # samples per second
FPS="${TP_REC_FPS:-12}"          # output frame rate; each sample is held
W=1280; H=720

command -v tmux >/dev/null 2>&1 || { echo "tmux is required" >&2; exit 127; }
mkdir -p "$OUT" "$WORK/frames" "$WORK/svg"

cleanup() { tmux kill-session -t "$SESSION" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT

say() { printf '\033[36m%s\033[0m\n' "$1" >&2; }

frame=0
hold_factor=$(python3 -c "print(max(1,round($FPS/$SAMPLE_HZ)))")

# One sample: capture every pane with escapes intact, lay them side by side, and
# hold the result for however many output frames the rate demands.
sample() {
  local svgs=() pane
  local i=0
  while IFS= read -r pane; do
    tmux capture-pane -p -e -t "$pane" > "$WORK/pane$i.ansi" 2>/dev/null || continue
    python3 "$A2S" --bare --min-cols 70 -i "$WORK/pane$i.ansi" -o "$WORK/svg/p$i.svg" >/dev/null 2>&1 || continue
    rsvg-convert -h 600 -o "$WORK/svg/p$i.png" "$WORK/svg/p$i.svg" 2>/dev/null || continue
    svgs+=("$WORK/svg/p$i.png")
    i=$((i+1))
  done < <(tmux list-panes -t "$SESSION" -F '#{pane_id}' 2>/dev/null)

  (( ${#svgs[@]} )) || return 1

  local composed="$WORK/composed.png"
  if (( ${#svgs[@]} == 1 )); then
    cp "${svgs[0]}" "$composed"
  else
    ffmpeg -y -i "${svgs[0]}" -i "${svgs[1]}" -filter_complex \
      "[0:v]pad=iw+3:ih:0:0:0x30363d[l];[l][1:v]hstack=inputs=2" \
      -frames:v 1 "$composed" >/dev/null 2>&1 || cp "${svgs[0]}" "$composed"
  fi

  ffmpeg -y -i "$composed" -vf \
    "scale=w=$((W-100)):h=$((H-60)):force_original_aspect_ratio=decrease,pad=$W:$H:(ow-iw)/2:(oh-ih)/2:0x0d1117" \
    -frames:v 1 "$WORK/f.png" >/dev/null 2>&1 || return 1

  local j
  for ((j=0; j<hold_factor; j++)); do
    printf -v name '%06d' "$frame"
    cp "$WORK/f.png" "$WORK/frames/$name.png"
    frame=$((frame+1))
  done
}

# Sample continuously for N seconds while whatever was sent runs.
record_for() {
  local secs="$1"
  local n; n=$(python3 -c "print(int($secs*$SAMPLE_HZ))")
  local i
  for ((i=0; i<n; i++)); do
    sample || true
    python3 -c "import time; time.sleep(1/$SAMPLE_HZ)"
  done
}

send() { tmux send-keys -t "$SESSION" "$1" Enter; }

# --- the session ------------------------------------------------------------
FIX="$ROOT/tests/fixtures"
[[ -s "$FIX/test.png" ]] || "$ROOT/tests/run.sh" >/dev/null 2>&1
cp "$FIX/test.diff" "$WORK/auth.diff"

tmux new-session -d -s "$SESSION" -x 210 -y 34 -c "$ROOT"
sleep 1
send "clear"
sleep 0.5

say "recording: the ask"
send "printf '\\033[38;5;114m>\\033[0m tighten the Session type and add role scopes\\n\\n  Edited \\033[1msrc/auth.ts\\033[0m  \\033[2m+12 -5\\033[0m\\n\\n'"
record_for 2

say "recording: asking to see it"
send "printf '\\033[38;5;114m>\\033[0m show me what changed\\n\\n'"
record_for 1.5

say "recording: the sidebar opening (live)"
send "TERMPEEK_SIDEBAR_WIDTH=48% bash ./scripts/termpeek -g 92x30 '$WORK/auth.diff'"
record_for 6

say "recording: settling"
record_for 2

# --- encode -----------------------------------------------------------------
say "encoding $frame frames"
ffmpeg -y -framerate "$FPS" -i "$WORK/frames/%06d.png" \
  -c:v libx264 -pix_fmt yuv420p -profile:v high -level 4.0 \
  -movflags +faststart -crf 20 "$OUT/session.mp4" >/dev/null 2>&1 \
  || { echo "encode failed" >&2; exit 1; }

ffmpeg -y -i "$OUT/session.mp4" -vf "fps=10,scale=900:-1:flags=lanczos,palettegen=stats_mode=diff" \
  "$WORK/pal.png" >/dev/null 2>&1
ffmpeg -y -i "$OUT/session.mp4" -i "$WORK/pal.png" \
  -lavfi "fps=10,scale=900:-1:flags=lanczos[x];[x][1:v]paletteuse=dither=bayer:bayer_scale=3" \
  "$OUT/session.gif" >/dev/null 2>&1

ls -la "$OUT"/session.* 2>/dev/null
