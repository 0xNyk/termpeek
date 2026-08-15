#!/usr/bin/env bash
# termpeek auto-preview — a Claude Code PostToolUse hook.
#
# Without this, seeing what the agent just made is a thing you have to remember
# to ask for. With it, writing an image, PDF or video opens a preview by itself.
#
# Install: see hooks/claude-code/README.md
#
# Design constraints, in order of importance:
#
#   1. Never block the agent. Previewing is a convenience; if anything here is
#      slow or broken the tool call must still complete. Every path exits 0, and
#      the preview runs detached.
#   2. Never surprise. Only files the agent just wrote, only media types, and
#      only when a transport can actually display something.
#   3. Never spam. A loop that writes forty frames should not open forty
#      windows, so repeats within a short window are suppressed.

set -uo pipefail

# Resolve through symlinks so the hook works wherever it is linked from.
tp__self="${BASH_SOURCE[0]}"
while [ -L "$tp__self" ]; do
  tp__dir="$(cd -P "$(dirname "$tp__self")" && pwd)"
  tp__self="$(readlink "$tp__self")"
  case "$tp__self" in /*) ;; *) tp__self="$tp__dir/$tp__self" ;; esac
done
ROOT="$(cd -P "$(dirname "$tp__self")/../.." && pwd)"
TERMPEEK="${TERMPEEK_BIN:-$ROOT/scripts/termpeek}"

STATE_DIR="${TERMPEEK_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/termpeek}"
COOLDOWN="${TERMPEEK_HOOK_COOLDOWN:-20}"   # seconds before the same file re-previews

# Opt-out without editing settings.json.
[[ "${TERMPEEK_AUTO_PREVIEW:-1}" == "0" ]] && exit 0

input="$(cat)"

# jq is already required for tweet previews; without it, do nothing rather than
# hand-parse JSON badly.
command -v jq >/dev/null 2>&1 || exit 0

tool="$(printf '%s' "$input" | jq -r '.tool_name // ""' 2>/dev/null)"
case "$tool" in
  Write|Edit|NotebookEdit) ;;
  *) exit 0 ;;
esac

path="$(printf '%s' "$input" | jq -r '.tool_input.file_path // ""' 2>/dev/null)"
[[ -n "$path" && -f "$path" ]] || exit 0

# Only things worth looking at. Deliberately excludes code and diffs: the agent
# already shows you those as text, and a window per edit would be intolerable.
case "$(printf '%s' "$path" | tr '[:upper:]' '[:lower:]')" in
  *.png|*.jpg|*.jpeg|*.gif|*.webp|*.svg|*.avif|*.pdf|*.mp4|*.mov|*.webm) ;;
  *) exit 0 ;;
esac

# A transport has to exist, or this spawns work that shows nobody anything.
# shellcheck source=../../lib/probe.sh
source "$ROOT/lib/probe.sh" 2>/dev/null || exit 0
[[ "$(tp_detect_transport)" == "none" ]] && exit 0

# Suppress repeats: a render loop writing the same file over and over should
# open one preview, not one per iteration.
mkdir -p "$STATE_DIR" 2>/dev/null || exit 0
stamp="$STATE_DIR/seen-$(printf '%s' "$path" | cksum | tr -d ' \t')"
now="$(date +%s)"
if [[ -f "$stamp" ]]; then
  last="$(cat "$stamp" 2>/dev/null || echo 0)"
  (( now - last < COOLDOWN )) && exit 0
fi
printf '%s' "$now" > "$stamp" 2>/dev/null

# Detached, output discarded, and never waited on: the tool call returns now.
( "$TERMPEEK" "$path" >/dev/null 2>&1 & ) >/dev/null 2>&1

exit 0
