#!/usr/bin/env bash
# termpeek — a small content-addressed cache.
#
# Measured before writing any of this:
#
#   tweet card   595ms   almost entirely network (fetch + avatar download)
#   PDF page     326ms   pdftoppm 153 + ffmpeg framing 96 + chafa 77
#   image         ~90ms  chafa alone
#   diff         ~100ms  delta alone
#
# So this caches the two expensive paths and leaves the cheap ones alone. A
# cache that saves 90ms is not worth the chance of serving something stale.
#
# Two different invalidation strategies, because the inputs differ:
#
#   Local files  keyed on path + mtime + size. Editing the file changes the key,
#                so there is no TTL and no way to see a stale render.
#   Remote data  keyed on the post id, with a TTL — the post itself does not
#                change but its counts do, and there is nothing local to compare
#                against.

set -uo pipefail

TERMPEEK_CACHE="${TERMPEEK_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/termpeek}"
TERMPEEK_CACHE_TTL="${TERMPEEK_CACHE_TTL:-900}"          # posts: 15 minutes
TERMPEEK_CACHE_AVATAR_TTL="${TERMPEEK_CACHE_AVATAR_TTL:-604800}"  # avatars: a week
TERMPEEK_CACHE_MAX="${TERMPEEK_CACHE_MAX:-200}"          # entries per bucket

tp_cache_enabled() { [[ "${TERMPEEK_CACHE_DISABLE:-0}" != "1" ]]; }

tp__hash() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | cut -c1-32
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum | cut -c1-32
  else
    cksum | tr -d ' \t'
  fi
}

# Identity of a local file: path, size and mtime. Any edit changes the key, so
# a cached render can never outlive the file it came from.
tp_cache_key_file() {
  local f="$1"; shift
  local meta
  meta="$(stat -f '%z-%m' "$f" 2>/dev/null || stat -c '%s-%Y' "$f" 2>/dev/null)"
  printf '%s|%s|%s' "$f" "$meta" "$*" | tp__hash
}

tp_cache_key() { printf '%s' "$*" | tp__hash; }

tp__bucket() {
  local b="$TERMPEEK_CACHE/$1"
  mkdir -p "$b" 2>/dev/null || return 1
  printf '%s' "$b"
}

# Print the cached path if it exists and is young enough. ttl<=0 means "no
# expiry", which is what the file-keyed entries use.
tp_cache_get() {
  local bucket="$1" key="$2" ttl="${3:-0}"
  tp_cache_enabled || return 1
  local dir; dir="$(tp__bucket "$bucket")" || return 1
  local path="$dir/$key"
  [[ -s "$path" ]] || return 1

  if (( ttl > 0 )); then
    local mtime now
    mtime="$(stat -f '%m' "$path" 2>/dev/null || stat -c '%Y' "$path" 2>/dev/null)"
    now="$(date +%s)"
    if [[ -n "$mtime" ]] && (( now - mtime > ttl )); then
      return 1
    fi
  fi
  printf '%s' "$path"
}

# Move a produced file into the cache and print its new location. Uses rename
# where possible so a reader never sees a half-written entry.
tp_cache_put() {
  local bucket="$1" key="$2" src="$3"
  tp_cache_enabled || { printf '%s' "$src"; return 0; }
  [[ -s "$src" ]] || return 1
  local dir; dir="$(tp__bucket "$bucket")" || { printf '%s' "$src"; return 0; }
  local dst="$dir/$key" tmp="$dir/.$key.$$"

  if cp "$src" "$tmp" 2>/dev/null && mv -f "$tmp" "$dst" 2>/dev/null; then
    tp_cache_prune "$bucket"
    printf '%s' "$dst"
  else
    rm -f "$tmp" 2>/dev/null
    printf '%s' "$src"
  fi
}

# Keep buckets bounded. Oldest first, because the newest entry is the one most
# likely to be asked for again.
tp_cache_prune() {
  local bucket="$1"
  local dir="$TERMPEEK_CACHE/$bucket"
  [[ -d "$dir" ]] || return 0
  local n
  n="$(find "$dir" -type f ! -name '.*' 2>/dev/null | wc -l | tr -d ' ')"
  (( n > TERMPEEK_CACHE_MAX )) || return 0
  local excess=$(( n - TERMPEEK_CACHE_MAX ))
  # Sort by mtime; BSD and GNU stat disagree on flags, so ask find for the time.
  find "$dir" -type f ! -name '.*' -exec stat -f '%m %N' {} + 2>/dev/null \
    || find "$dir" -type f ! -name '.*' -exec stat -c '%Y %n' {} + 2>/dev/null \
    | sort -n | head -n "$excess" | cut -d' ' -f2- | while IFS= read -r victim; do
        [[ -n "$victim" ]] && rm -f "$victim" 2>/dev/null
      done
}

tp_cache_clear() {
  [[ -d "$TERMPEEK_CACHE" ]] || { echo "termpeek: no cache at $TERMPEEK_CACHE"; return 0; }
  local n
  n="$(find "$TERMPEEK_CACHE" -type f 2>/dev/null | wc -l | tr -d ' ')"
  rm -rf "${TERMPEEK_CACHE:?}/render" "${TERMPEEK_CACHE:?}/x" "${TERMPEEK_CACHE:?}/avatar" 2>/dev/null
  echo "termpeek: cleared $n cached file(s) from $TERMPEEK_CACHE"
}

tp_cache_stats() {
  printf 'cache  %s\n' "$TERMPEEK_CACHE"
  local b n sz
  for b in render x avatar; do
    if [[ -d "$TERMPEEK_CACHE/$b" ]]; then
      n="$(find "$TERMPEEK_CACHE/$b" -type f ! -name '.*' 2>/dev/null | wc -l | tr -d ' ')"
      sz="$(du -sh "$TERMPEEK_CACHE/$b" 2>/dev/null | cut -f1 | tr -d ' ')"
      printf '  %-7s %4s entries  %s\n' "$b" "$n" "${sz:-0B}"
    else
      printf '  %-7s    0 entries\n' "$b"
    fi
  done
}
