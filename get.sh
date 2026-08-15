#!/usr/bin/env sh
# termpeek bootstrap — clone (or update) and install.
#
#   sh -c "$(curl -fsSL https://raw.githubusercontent.com/0xNyk/termpeek/main/get.sh)"
#
# Piping a script from the internet into a shell means trusting it completely.
# This one is short on purpose so it can be read first:
#
#   curl -fsSL https://raw.githubusercontent.com/0xNyk/termpeek/main/get.sh | less
#
# It clones a public repository, symlinks three scripts into a bin directory,
# and touches nothing else. No sudo, no shell profile edits, no daemons.

set -eu

REPO="${TERMPEEK_REPO:-https://github.com/0xNyk/termpeek}"
DEST="${TERMPEEK_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/termpeek}"
REF="${TERMPEEK_REF:-main}"

say()  { printf '%s\n' "$1"; }
dim()  { printf '\033[2m%s\033[0m\n' "$1"; }
die()  { printf '\033[31m%s\033[0m\n' "$1" >&2; exit 1; }

command -v git >/dev/null 2>&1 || die "git is required"

if [ -d "$DEST/.git" ]; then
  say "updating $DEST"
  git -C "$DEST" fetch --quiet origin "$REF" || die "could not fetch $REF"
  git -C "$DEST" checkout --quiet "$REF"
  # Hard reset rather than pull: this is a managed copy, and a merge conflict
  # here would leave someone stuck in a repository they never meant to edit.
  git -C "$DEST" reset --quiet --hard "origin/$REF"
else
  say "cloning into $DEST"
  mkdir -p "$(dirname "$DEST")"
  git clone --quiet --depth 1 --branch "$REF" "$REPO" "$DEST" \
    || die "could not clone $REPO"
fi

say ""
sh "$DEST/install.sh"

say ""
dim "installed from $DEST — update later with the same command,"
dim "or remove with: $DEST/install.sh --uninstall"
