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
# shellcheck source=../lib/x-fetch.sh
source "$ROOT/lib/x-fetch.sh"

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

echo "== transports =="
check "explicit transport wins" "$(TERMPEEK_TRANSPORT=tmux tp_detect_transport)" "tmux"
# Linux without a display has nowhere to put a window; claiming otherwise
# spawns a process that dies without ever showing anything.
if [[ -n "$(tp_linux_terminal)" ]]; then
  ok "finds a terminal emulator to spawn"
else
  echo "  no terminal emulator on PATH; skipping"
fi
# shellcheck disable=SC2209  # env-var prefix on a function call, not an assignment
check "\$TERMINAL wins when installed" "$(TERMINAL=cat tp_linux_terminal)" "cat"
check "\$TERMINAL args stripped"       "$(TERMINAL='cat -v' tp_linux_terminal)" "cat"
# An uninstalled $TERMINAL must be ignored, i.e. produce whatever plain
# detection produces. Asserting an exit code here would only test whether the
# machine happens to have a terminal emulator — CI runners have none.
check "uninstalled \$TERMINAL ignored" \
  "$(TERMINAL=definitely-not-a-terminal tp_linux_terminal 2>/dev/null)" \
  "$(tp_linux_terminal 2>/dev/null)"

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
  # The sixel branch has never run on this developer's terminal — Ghostty
  # declines sixel by design — so assert the stream shape instead of the pixels.
  # A sixel image is a DCS: ESC P <params> q, then raster attributes.
  out="$(TP_GEOMETRY=20x10 tp_render_image "$FIX/test.png" sixel 2>/dev/null | head -c 200)"
  case "$out" in
    *$'\033'P*q*) ok "image/sixel emits a DCS sixel stream" ;;
    *)            no "image/sixel produced no DCS introducer" ;;
  esac
else
  echo "  chafa or fixture missing; skipping image checks"
fi

echo "== timg pixelation mapping =="
check "kitty -> k"   "$(tp__timg_pixelation kitty)"   "k"
check "iterm -> i"   "$(tp__timg_pixelation iterm)"   "i"
check "sixel -> s"   "$(tp__timg_pixelation sixel)"   "s"
check "symbols -> q" "$(tp__timg_pixelation symbols)" "q"
check "unknown -> q" "$(tp__timg_pixelation nonsense)" "q"

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

echo "== cookie backend =="
# The cookie fetch needs a live session, but the parsing does not. These values
# are invented; the point is which shapes are accepted and which names must NOT
# match — ct0 should never be found inside ct0_backup.
cookiedir="$(mktemp -d "${TMPDIR:-/tmp}/tp-ck.XXXXXX")"
printf 'auth_token=AAAA1111\nct0=BBBB2222\n' > "$cookiedir/plain"
printf 'auth_token=AAAA1111; ct0=BBBB2222; guest_id=v1\n' > "$cookiedir/oneline"
printf '# Netscape HTTP Cookie File\n.x.com\tTRUE\t/\tTRUE\t0\tauth_token\tAAAA1111\n.x.com\tTRUE\t/\tTRUE\t0\tct0\tBBBB2222\n' > "$cookiedir/netscape"
printf 'x_auth_token=WRONG\nct0_backup=WRONG\nauth_token=AAAA1111\nct0=BBBB2222\n' > "$cookiedir/tricky"
for shape in plain oneline netscape tricky; do
  check "cookie/$shape auth_token" "$(tp_x_cookie_value "$cookiedir/$shape" auth_token)" "AAAA1111"
  check "cookie/$shape ct0"        "$(tp_x_cookie_value "$cookiedir/$shape" ct0)"        "BBBB2222"
done
check "cookie file absent" "$(tp_x_cookie_value /no/such/file auth_token 2>/dev/null || echo MISS)" "MISS"

echo "== x/tweet =="
check "url -> id"        "$(tp_x_id 'https://x.com/nykdotdev/status/1234567890')" "1234567890"
check "url+query -> id"  "$(tp_x_id 'https://twitter.com/a/status/42?s=20&t=x')"  "42"
check "bare id -> id"    "$(tp_x_id '99')" "99"
check "not a post -> ''" "$(tp_x_id 'https://example.com/hello')" ""
# The syndication token is derived, not guessed; this value is fixed for id 20.
check "token derivation" "$(tp_x_token 20)" "6dq1a2xwd93"

# Normalization must flatten every backend to one shape, so the card renderer
# never learns three schemas. Fixtures, so this stays offline.
if command -v jq >/dev/null 2>&1; then
  synd='{"user":{"name":"Nyk","screen_name":"nykdotdev","is_blue_verified":true,"profile_image_url_https":"https://x/a.jpg"},"text":"hello","created_at":"2026-08-15T09:41:00.000Z","favorite_count":128,"conversation_count":9}'
  check "syndication -> handle" "$(printf '%s' "$synd" | tp_x_normalize | jq -r .handle)" "nykdotdev"
  check "syndication -> likes"  "$(printf '%s' "$synd" | tp_x_normalize | jq -r .likes)"  "128"
  v2='{"data":{"text":"hi","created_at":"2026-08-15T09:41:00.000Z","public_metrics":{"like_count":7,"reply_count":2,"retweet_count":1}},"includes":{"users":[{"name":"Nyk","username":"nykdotdev","profile_image_url":"https://x/a.jpg"}]}}'
  check "api v2 -> handle" "$(printf '%s' "$v2" | tp_x_normalize | jq -r .handle)" "nykdotdev"
  check "api v2 -> likes"  "$(printf '%s' "$v2" | tp_x_normalize | jq -r .likes)"  "7"
  check "junk -> nothing"  "$(printf '%s' '{"nope":1}' | tp_x_normalize)" ""
fi

# Card rendering must not require network: --from-json is the offline path.
if command -v jq >/dev/null 2>&1; then
  cj="$FIX/card.json"
  printf '%s' '{"name":"Nyk","handle":"nykdotdev","verified":true,"avatar":"","text":"a & b <c> \"d\"","created":"2026-08-15T09:41:00.000Z","likes":1234,"replies":5,"reposts":6,"media":[]}' > "$cj"
  "$ROOT/scripts/tweet-card" --from-json "$cj" --out "$FIX/card.svg" >/dev/null 2>&1
  if [[ -s "$FIX/card.svg" ]]; then
    ok "card renders from json"
    # XML injection guard: raw &, < and > in post text must not reach the SVG.
    if grep -q '&amp;' "$FIX/card.svg" && ! grep -qE '<c>' "$FIX/card.svg"; then
      ok "card escapes xml in post text"
    else
      no "card leaked unescaped xml"
    fi
    grep -q '1.2K' "$FIX/card.svg" && ok "card abbreviates counts" || no "card did not abbreviate 1234"
  else
    no "card did not render"
  fi
fi

echo "== gallery / carousel =="
if command -v chafa >/dev/null 2>&1 && [[ -s "$FIX/test.png" ]]; then
  check "image resolves to itself" "$(tp_resolve_to_image "$FIX/test.png")" "$FIX/test.png"
  check "text has no still preview" "$(tp_resolve_to_image "$FIX/test.diff" 2>/dev/null)" ""
  check "--cols needs a value" "$("$TP" --here --gallery --cols >/dev/null 2>&1; echo $?)" "64"

  # A carousel is sequential and works with chafa alone.
  "$TP" --here --carousel --wait 0 -g 40x12 "$FIX/test.png" "$FIX/test.png" >/dev/null 2>&1 \
    && ok "--carousel cycles items" || no "--carousel failed"

  # Tiling genuinely needs timg, which most Linux distributions do not package.
  # Guard rather than pretend, so the suite reports honestly on those machines.
  if command -v timg >/dev/null 2>&1; then
    "$TP" --here -g 60x16 "$FIX/test.png" "$FIX/test.png" >/dev/null 2>&1 \
      && ok "two targets render together" || no "two targets failed"
    "$TP" --here --gallery -g 60x16 "$FIX/test.png" >/dev/null 2>&1 \
      && ok "--gallery works with one item" || no "--gallery with one item failed"
    # A path with a space must survive the trip through the transport's item list.
    cp "$FIX/test.png" "$FIX/with space.png"
    "$TP" --here --gallery -g 60x16 "$FIX/with space.png" "$FIX/test.png" >/dev/null 2>&1 \
      && ok "paths with spaces survive" || no "path with space broke the gallery"
  else
    echo "  timg missing; skipping gallery tiling checks"
  fi
fi

echo "== cache =="
# shellcheck source=../lib/cache.sh
source "$ROOT/lib/cache.sh"
cachedir="$(mktemp -d "${TMPDIR:-/tmp}/tp-cache.XXXXXX")"
# Deliberately NOT a subshell: ok/no increment pass/fail, and a subshell would
# keep those increments local, so a failing cache check would never fail CI.
tp_cache_saved="${TERMPEEK_CACHE:-}"
export TERMPEEK_CACHE="$cachedir"
# A file's key must change when the file does, or an edit serves a stale render.
# GNU stat's -f means --file-system, so a BSD-first probe silently returns a
# mount point on Linux instead of failing. That made every file share the same
# metadata there, and edits stopped invalidating the cache. Assert the shape.
case "$(tp__stat_mtime "$FIX/test.png")" in
  ''|*[!0-9]*) no "stat mtime is not a plain number on this platform" ;;
  *)           ok "stat mtime is numeric" ;;
esac
[[ "$(tp__stat_meta "$ROOT/lib/cache.sh")" != "$(tp__stat_meta "$ROOT/lib/render.sh")" ]] \
  && ok "stat metadata differs between files" \
  || no "two different files reported identical metadata"

k1="$(tp_cache_key_file "$FIX/test.png" pdf 1)"
k2="$(tp_cache_key_file "$FIX/test.png" pdf 2)"
[[ "$k1" != "$k2" ]] && ok "different args give different keys" || no "keys collided across args"

cp "$FIX/test.png" "$cachedir/mutable.png"
ka="$(tp_cache_key_file "$cachedir/mutable.png" x)"
sleep 1; printf 'extra' >> "$cachedir/mutable.png"
kb="$(tp_cache_key_file "$cachedir/mutable.png" x)"
[[ "$ka" != "$kb" ]] && ok "editing a file invalidates its key" || no "key survived an edit"

# put/get round trip
printf 'payload' > "$cachedir/src"
stored="$(tp_cache_put render testkey "$cachedir/src")"
[[ -s "$stored" ]] && ok "cache stores an entry" || no "cache did not store"
[[ "$(tp_cache_get render testkey)" == "$stored" ]] && ok "cache returns the stored path" || no "cache get missed"
check "absent key misses" "$(tp_cache_get render nosuchkey || echo MISS)" "MISS"

# TTL: an entry older than the window must not be served. Backdate it rather
# than sleeping, and use a positive window — ttl<=0 means "never expires" by
# design, so a negative value proves nothing.
touch -t 202001010000 "$stored" 2>/dev/null
check "entry older than the ttl misses" \
  "$(tp_cache_get render testkey 60 2>/dev/null || echo MISS)" "MISS"
check "entry inside the ttl still hits" \
  "$(tp_cache_get render testkey 0 2>/dev/null)" "$stored"

# The disable switch has to actually bypass, not just skip writes.
check "TERMPEEK_CACHE_DISABLE bypasses" \
  "$(TERMPEEK_CACHE_DISABLE=1 tp_cache_get render testkey || echo MISS)" "MISS"
if [[ -n "$tp_cache_saved" ]]; then export TERMPEEK_CACHE="$tp_cache_saved"; else unset TERMPEEK_CACHE; fi

echo "== mcp server =="
MCP="$ROOT/scripts/termpeek-mcp"
if [[ -x "$MCP" ]] && command -v jq >/dev/null 2>&1; then
  mcp() { printf '%s\n' "$@" | "$MCP" 2>/dev/null; }

  init='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{}}}'
  check "initialize returns a protocol" \
    "$(mcp "$init" | jq -r 'select(.id==1) | .result.protocolVersion')" "2024-11-05"
  check "server identifies itself" \
    "$(mcp "$init" | jq -r 'select(.id==1) | .result.serverInfo.name')" "termpeek"
  check "advertises four tools" \
    "$(mcp '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' | jq -r '.result.tools | length')" "4"
  check "ping answers" \
    "$(mcp '{"jsonrpc":"2.0","id":3,"method":"ping"}' | jq -r '.result | type')" "object"
  check "unknown method is -32601" \
    "$(mcp '{"jsonrpc":"2.0","id":4,"method":"nope"}' | jq -r '.error.code')" "-32601"
  check "missing argument is a tool error" \
    "$(mcp '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"preview","arguments":{}}}' | jq -r '.result.isError')" "true"

  # Notifications carry no id. Answering one corrupts the stream, and clients
  # send at least one (notifications/initialized) during every handshake.
  check "notifications get no reply" \
    "$(mcp '{"jsonrpc":"2.0","method":"notifications/initialized"}' '{"jsonrpc":"2.0","method":"x/y"}' | wc -c | tr -d ' ')" "0"

  # A malformed line must not take the server down mid-session.
  check "survives malformed input" \
    "$(mcp 'not json' '{"jsonrpc":"2.0","id":6,"method":"ping"}' | jq -r 'select(.id==6) | .id')" "6"

  # The tool must call termpeek, not return the picture to the model.
  mcpstub="$(mktemp -d "${TMPDIR:-/tmp}/tp-mcp.XXXXXX")/stub.sh"
  printf '#!/bin/sh\nexit 0\n' > "$mcpstub"; chmod +x "$mcpstub"
  if [[ -s "$FIX/test.png" ]]; then
    r="$(printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/call\",\"params\":{\"name\":\"preview\",\"arguments\":{\"path\":\"$FIX/test.png\"}}}" | TERMPEEK_BIN="$mcpstub" "$MCP" 2>/dev/null | jq -r '.result.content[0].text')"
    case "$r" in *"Shown to the user"*) ok "preview reports back as text" ;; *) no "preview returned: $r" ;; esac
  fi
fi

echo "== auto-preview hook =="
HOOK="$ROOT/hooks/claude-code/auto-preview.sh"
if [[ -x "$HOOK" ]] && command -v jq >/dev/null 2>&1; then
  hookrun() { printf '%s' "$1" | TERMPEEK_BIN="$hookstub" TERMPEEK_CACHE="$hookcache" "$HOOK" >/dev/null 2>&1; echo $?; }
  hookdir="$(mktemp -d "${TMPDIR:-/tmp}/tp-hook.XXXXXX")"
  hookstub="$hookdir/stub.sh"; hookcache="$hookdir/cache"; hooklog="$hookdir/log"
  printf '#!/bin/sh\necho x >> "%s"\n' "$hooklog" > "$hookstub"; chmod +x "$hookstub"
  : > "$hooklog"

  # Every guard must exit 0: a hook that fails is a hook that blocks the agent.
  check "hook ignores non-media"  "$(hookrun "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$ROOT/lib/probe.sh\"}}")" "0"
  check "hook ignores other tools" "$(hookrun '{"tool_name":"Bash","tool_input":{"command":"ls"}}')" "0"
  check "hook ignores absent file" "$(hookrun '{"tool_name":"Write","tool_input":{"file_path":"/no/such/x.png"}}')" "0"
  check "hook survives junk input" "$(hookrun 'not json')" "0"
  check "hook exits 0 on opt-out"  "$(printf '%s' '{"tool_name":"Write","tool_input":{"file_path":"'"$FIX"'/test.png"}}' | TERMPEEK_AUTO_PREVIEW=0 "$HOOK" >/dev/null 2>&1; echo $?)" "0"

  if [[ -s "$FIX/test.png" ]]; then
    n0=$(wc -l < "$hooklog" | tr -d ' ')
    hookrun "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$FIX/test.png\"}}" >/dev/null
    sleep 1
    n1=$(wc -l < "$hooklog" | tr -d ' ')
    # Only meaningful where something can actually display; skip otherwise.
    if [[ "$(tp_detect_transport)" != "none" ]]; then
      (( n1 > n0 )) && ok "hook previews a written image" || no "hook did not fire on an image"
      hookrun "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$FIX/test.png\"}}" >/dev/null
      sleep 1
      n2=$(wc -l < "$hooklog" | tr -d ' ')
      (( n2 == n1 )) && ok "hook cooldown suppresses repeats" || no "hook fired twice for one file"
    else
      echo "  no transport; skipping hook firing checks"
    fi
  fi
fi

echo "== version =="
# Three places state a version. They drifted apart the moment there was more
# than one, so VERSION is the only source and the rest read it.
tp_ver="$(cat "$ROOT/VERSION" 2>/dev/null)"
case "$tp_ver" in
  [0-9]*.[0-9]*.[0-9]*) ok "VERSION holds a semver string" ;;
  *)                    no "VERSION is not semver: '$tp_ver'" ;;
esac
check "--version matches VERSION" "$("$TP" --version)" "termpeek $tp_ver"
if command -v jq >/dev/null 2>&1; then
  check "mcp reports the same version" \
    "$(printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
       | "$ROOT/scripts/termpeek-mcp" 2>/dev/null | jq -r '.result.serverInfo.version')" "$tp_ver"
fi
check "changelog documents this version" \
  "$(grep -oE '^## \[[0-9]+\.[0-9]+\.[0-9]+\]' "$ROOT/CHANGELOG.md" | head -1 | tr -d '#[] ')" "$tp_ver"

echo "== cli =="
check "no args -> 64"        "$("$TP" >/dev/null 2>&1; echo $?)" "64"
check "missing value -> 64"  "$("$TP" --here -g >/dev/null 2>&1; echo $?)" "64"
check "unknown opt -> 64"    "$("$TP" --nonsense >/dev/null 2>&1; echo $?)" "64"
check "absent file -> 66"    "$("$TP" --here /no/such/file >/dev/null 2>&1; echo $?)" "66"
"$TP" --probe >/dev/null 2>&1 && ok "--probe runs" || no "--probe failed"
# install.sh puts a symlink on PATH. Taking dirname of the link instead of the
# real file pointed at the bin directory and no library was found — the install
# was broken while every in-tree invocation kept working.
link="$(mktemp -d "${TMPDIR:-/tmp}/tp-link.XXXXXX")/termpeek"
ln -sf "$TP" "$link"
( cd / && "$link" --probe ) >/dev/null 2>&1 \
  && ok "runs through a symlink from another directory" \
  || no "symlink invocation cannot find its libraries"
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
