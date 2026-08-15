#!/usr/bin/env bash
# termpeek installer — links the CLI onto your PATH and checks the renderers.
#
#   ./install.sh                 install to ~/.local/bin
#   TERMPEEK_BIN_DIR=... ./install.sh
#   ./install.sh --uninstall

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="${TERMPEEK_BIN_DIR:-$HOME/.local/bin}"

red()  { printf '\033[31m%s\033[0m\n' "$1"; }
grn()  { printf '\033[32m%s\033[0m\n' "$1"; }
dim()  { printf '\033[2m%s\033[0m\n' "$1"; }

if [[ "${1:-}" == "--uninstall" ]]; then
  rm -f "$BIN_DIR/termpeek" "$BIN_DIR/tp-session" "$BIN_DIR/termpeek-mcp"
  grn "removed termpeek, tp-session and termpeek-mcp from $BIN_DIR"
  exit 0
fi

mkdir -p "$BIN_DIR" || { red "cannot create $BIN_DIR"; exit 1; }

# Check the link actually landed. Reporting success after a failed ln sends
# people off to run a command that is not there.
failed=0
for cmd in termpeek tp-session termpeek-mcp; do
  chmod +x "$ROOT/scripts/$cmd" 2>/dev/null
  if ! ln -sf "$ROOT/scripts/$cmd" "$BIN_DIR/$cmd" 2>/dev/null || [[ ! -x "$BIN_DIR/$cmd" ]]; then
    red "could not link $cmd into $BIN_DIR"
    failed=1
  fi
done

if (( failed )); then
  echo
  dim "Fix the permissions on $BIN_DIR, or choose another location:"
  dim "  TERMPEEK_BIN_DIR=~/bin ./install.sh"
  dim "You can also run it in place: $ROOT/scripts/termpeek"
  exit 1
fi
grn "linked termpeek, tp-session and termpeek-mcp into $BIN_DIR"

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) dim "note: $BIN_DIR is not on your PATH — add it to your shell profile" ;;
esac

echo
echo "renderers:"
missing=0
check() {
  if command -v "$1" >/dev/null 2>&1; then
    printf '  \033[32mok\033[0m    %-9s %s\n' "$1" "$2"
  else
    printf '  \033[31mmiss\033[0m  %-9s %s\n' "$1" "$2"
    missing=1
  fi
}
check chafa    "images"
check timg     "video"
check pdftoppm "PDFs (ships with poppler)"
check bat      "code files"
check delta    "diffs"
check ffmpeg   "PDF page framing"
check tmux     "sidebar transport (optional)"
check jq       "X posts and the MCP server"

if (( missing )); then
  echo
  dim "install what's missing:"
  dim "  brew install chafa timg bat git-delta ffmpeg tmux"
  dim "termpeek still runs without them — it degrades to what's available."
fi

echo
dim "try:  termpeek --probe"
