#!/usr/bin/env bash
# termpeek test suite.
#
# What can and cannot be asserted here: whether pixels LOOK right needs a human
# at a real terminal. What is checkable is that the right renderer is chosen and
# that it emits the expected escape structure — which is exactly where the bugs
# in this project actually were (silent protocol downgrades, frozen video,
# panes that closed instantly, bash 3.2 array expansion).

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export TERMPEEK_LIB="$ROOT/lib"
FIX="$ROOT/tests/fixtures"
TP="$ROOT/scripts/termpeek"

pass=0; fail=0
ok()   { printf '  \033[32mok\033[0m   %s\n' "$1"; pass=$((pass+1)); }
no()   { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
check(){ if [[ "$2" == "$3" ]]; then ok "$1"; else no "$1 (want '$3', got '$2')"; fi; }

# shellcheck source=../lib/probe.sh
source "$ROOT/lib/probe.sh"
# shellcheck source=../lib/render.sh
source "$ROOT/lib/render.sh"

echo "== fixtures =="
# Regenerate if EITHER fixture is missing or empty — checking only one let a
# 0-byte video survive and fail three unrelated tests.
if [[ ! -s "$FIX/test.png" || ! -s "$FIX/anim.mp4" ]]; then
  mkdir -p "$FIX"
  if command -v ffmpeg >/dev/null 2>&1; then
    ffmpeg -y -f lavfi -i "testsrc=size=160x120:rate=1" -frames:v 1 "$FIX/test.png" >/dev/null 2>&1
    # Dimensions must be EVEN: libx264 with yuv420p rejects odd width/height,
    # and ffmpeg fails silently enough to leave a 0-byte file behind.
    ffmpeg -y -f lavfi -i "mandelbrot=size=240x136:rate=10" -t 2 -pix_fmt yuv420p "$FIX/anim.mp4" >/dev/null 2>&1
    if [[ -s "$FIX/anim.mp4" ]]; then ok "generated fixtures"; else no "video fixture is empty"; fi
  else
    echo "  ffmpeg missing; skipping generated fixtures"
  fi
else
  ok "fixtures present"
fi
printf 'diff --git a/x.js b/x.js\n--- a/x.js\n+++ b/x.js\n@@ -1 +1 @@\n-const a = 1;\n+const a = 2;\n' > "$FIX/test.diff"

echo "== type detection =="
check "png  -> image"  "$(tp_detect_type "$FIX/test.png")"   "image"
check "mp4  -> video"  "$(tp_detect_type "$FIX/anim.mp4")"   "video"
check "diff -> diff"   "$(tp_detect_type "$FIX/test.diff")"  "diff"
check "sh   -> file"   "$(tp_detect_type "$ROOT/lib/probe.sh")" "file"
check "x.com -> tweet" "$(tp_detect_type 'https://x.com/a/status/1')" "tweet"
check "absent -> missing" "$(tp_detect_type '/no/such/file')" "missing"
# A unified diff without a .diff extension must still be detected by content.
cp "$FIX/test.diff" "$FIX/patchlike.txt"
check "extensionless diff -> diff" "$(tp_detect_type "$FIX/patchlike.txt")" "diff"

echo "== protocol detection =="
check "explicit override wins" "$(TERMPEEK_PROTOCOL=sixel tp_detect_protocol)" "sixel"
check "ghostty -> kitty" "$(TERM_PROGRAM=ghostty TERM=xterm-ghostty TMUX='' tp_detect_protocol)" "kitty"
check "iTerm -> iterm"   "$(TERM_PROGRAM=iTerm.app TERM=xterm-256color TMUX='' tp_detect_protocol)" "iterm"
check "dumb -> symbols"  "$(TERM_PROGRAM='' TERM=dumb TMUX='' tp_detect_protocol)" "symbols"
check "unknown -> symbols" "$(TERM_PROGRAM='' TERM=weird-term-9000 TMUX='' tp_detect_protocol)" "symbols"

echo "== renderer output shape =="
if command -v chafa >/dev/null 2>&1 && [[ -f "$FIX/test.png" ]]; then
  out="$(TP_GEOMETRY=20x10 tp_render_image "$FIX/test.png" kitty 2>/dev/null | head -c 4000)"
  case "$out" in
    *$'\033'_G*) ok "image/kitty emits APC graphics" ;;
    *)           no "image/kitty missing APC graphics" ;;
  esac
  # Symbols mode must produce character art and must NOT use a pixel protocol.
  # Do not assert colour escapes here: with no colour support (CI, TERM=dumb)
  # chafa legitimately emits plain ASCII, which is still a correct rendering.
  out="$(TP_GEOMETRY=20x10 tp_render_image "$FIX/test.png" symbols 2>/dev/null | head -c 2000)"
  case "$out" in
    *$'\033'_G*) no "image/symbols must not emit APC graphics" ;;
    "")          no "image/symbols produced nothing" ;;
    *)           ok "image/symbols emits character art" ;;
  esac
else
  echo "  chafa or fixture missing; skipping image checks"
fi

echo "== video: no frozen frame when stdout is not a tty =="
# Regression guard. timg silently renders ONE frame under kitty when the
# terminal cannot answer the pixel-size query, exiting 0. Piped output is
# exactly that case, so the renderer must fall back to blocks and animate.
if command -v timg >/dev/null 2>&1 && [[ -f "$FIX/anim.mp4" ]]; then
  frames="$(TP_GEOMETRY=20x10 tp_render_video "$FIX/anim.mp4" kitty 2>/dev/null \
            | perl -0777 -ne 'print scalar(()=/\e\[\d+A/g)')"
  if [[ "${frames:-0}" -gt 1 ]]; then
    ok "video animates when piped ($frames frame moves)"
  else
    no "video froze when piped (${frames:-0} frame moves)"
  fi
else
  echo "  timg or fixture missing; skipping video checks"
fi

echo "== cli =="
check "no args -> 64"        "$("$TP" >/dev/null 2>&1; echo $?)" "64"
check "missing value -> 64"  "$("$TP" --here -g >/dev/null 2>&1; echo $?)" "64"
check "unknown opt -> 64"    "$("$TP" --nonsense >/dev/null 2>&1; echo $?)" "64"
check "absent file -> 66"    "$("$TP" --here /no/such/file >/dev/null 2>&1; echo $?)" "66"
"$TP" --probe >/dev/null 2>&1 && ok "--probe runs" || no "--probe failed"
"$TP" --version >/dev/null 2>&1 && ok "--version runs" || no "--version failed"
# Both flag spellings must work; --loops=1 was a real bug.
#
# Deliberately run against an IMAGE, not a video: this asserts argument parsing,
# and pairing it with a video made the check fail on any machine without timg
# (Linux has no timg in apt) for a reason unrelated to what is being tested.
if command -v chafa >/dev/null 2>&1 && [[ -s "$FIX/test.png" ]]; then
  "$TP" --here -g 12x6 --loops=1 "$FIX/test.png" >/dev/null 2>&1 && ok "--loops=1 accepted" || no "--loops=1 rejected"
  "$TP" --here -g 12x6 --loops 1 "$FIX/test.png" >/dev/null 2>&1 && ok "--loops 1 accepted" || no "--loops 1 rejected"
fi

echo
printf 'passed %d, failed %d\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
