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
  rm -f "$BIN_DIR/termpeek" "$BIN_DIR/tp-session"
  grn "removed termpeek and tp-session from $BIN_DIR"
  exit 0
fi

mkdir -p "$BIN_DIR" || { red "cannot create $BIN_DIR"; exit 1; }

for cmd in termpeek tp-session; do
  ln -sf "$ROOT/scripts/$cmd" "$BIN_DIR/$cmd"
  chmod +x "$ROOT/scripts/$cmd"
done
grn "linked termpeek and tp-session into $BIN_DIR"

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

if (( missing )); then
  echo
  dim "install what's missing:"
  dim "  brew install chafa timg bat git-delta ffmpeg tmux"
  dim "termpeek still runs without them — it degrades to what's available."
fi

echo
dim "try:  termpeek --probe"
