#!/usr/bin/env bash
# termpeek — fetching a single X/Twitter post.
#
# Three backends, tried in order unless TERMPEEK_X_BACKEND pins one:
#
#   syndication  no auth, no setup. The endpoint behind embedded tweets.
#                Works for public posts. Undocumented, so it can change.
#   xint         the X API v2 via the xint CLI, if installed and configured.
#                Official and stable; needs an API key.
#   cookies      your logged-in session, for posts the other two cannot see.
#                Credentials are read from a file and never printed or logged.
#
# Every backend is normalized to one shape so the card renderer only ever sees:
#   {name, handle, verified, avatar, text, created_at, likes, replies, reposts, media[]}

set -uo pipefail

TERMPEEK_X_TIMEOUT="${TERMPEEK_X_TIMEOUT:-10}"

# shellcheck source=./cache.sh
source "${TERMPEEK_LIB:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/cache.sh"

tp_x_need() {
  command -v "$1" >/dev/null 2>&1 || { echo "termpeek: $1 is required for tweet preview" >&2; return 127; }
}

# Accepts a full URL or a bare numeric id.
tp_x_id() {
  local in="$1"
  case "$in" in
    *status/*) printf '%s' "$in" | sed -E 's#.*status(es)?/([0-9]+).*#\2#' ;;
    *[!0-9]*)  printf '' ;;
    *)         printf '%s' "$in" ;;
  esac
}

# The syndication endpoint requires a token derived from the post id:
#   ((id / 1e15) * PI) in base 36, with zeros and the decimal point removed.
# Implemented in awk so the tool keeps no scripting-language dependency.
tp_x_token() {
  awk -v id="$1" 'BEGIN{
    v = (id/1e15)*3.141592653589793
    d = "0123456789abcdefghijklmnopqrstuvwxyz"
    ip = int(v); fr = v - ip
    s = ""
    if (ip == 0) s = "0"
    while (ip > 0) { s = substr(d,(ip%36)+1,1) s; ip = int(ip/36) }
    out = s "."
    for (i = 0; i < 20; i++) { fr *= 36; c = int(fr); out = out substr(d,c+1,1); fr -= c }
    gsub(/0+|\./, "", out)
    print out
  }'
}

tp_x_fetch_syndication() {
  local id="$1" tok
  tp_x_need curl || return 127
  tok="$(tp_x_token "$id")"
  curl -fsS --max-time "$TERMPEEK_X_TIMEOUT" \
    -H 'User-Agent: Mozilla/5.0' \
    "https://cdn.syndication.twimg.com/tweet-result?id=${id}&token=${tok}&lang=en" 2>/dev/null
}

tp_x_fetch_xint() {
  local id="$1"
  command -v xint >/dev/null 2>&1 || return 1
  xint tweet "$id" --json 2>/dev/null
}

# Cookie auth. TERMPEEK_X_COOKIE_FILE points at a file containing at least
# auth_token and ct0 — either "name=value" per line, or Netscape cookies.txt.
#
# The file is read straight into a request header. It is never echoed, never
# written to logs, and never passed on a command line where it would show up in
# the process list.
tp_x_fetch_cookies() {
  local id="$1"
  local file="${TERMPEEK_X_COOKIE_FILE:-$HOME/.config/termpeek/x-cookies}"
  [[ -r "$file" ]] || return 1
  tp_x_need curl || return 127

  local perms
  perms="$(stat -f '%Lp' "$file" 2>/dev/null || stat -c '%a' "$file" 2>/dev/null)"
  case "$perms" in
    *[0-7][1-7][0-7]|*[0-7][0-7][1-7])
      echo "termpeek: $file is group/world readable — chmod 600 it" >&2 ;;
  esac

  local auth ct0
  auth="$(awk -F'auth_token[=\t]+' '/auth_token/{print $2}' "$file" | awk '{print $1}' | tr -d '";' | head -1)"
  ct0="$(awk -F'ct0[=\t]+' '/ct0/{print $2}' "$file" | awk '{print $1}' | tr -d '";' | head -1)"
  [[ -n "$auth" && -n "$ct0" ]] || {
    echo "termpeek: could not find auth_token and ct0 in the cookie file" >&2
    return 1
  }

  # The public web client bearer, not a user secret. Override if it rotates.
  local bearer="${TERMPEEK_X_BEARER:-AAAAAAAAAAAAAAAAAAAAANRILgAAAAAAnNwIzUejRCOuH5E6I8xnZz4puTs%3D1Zv7ttfk8LF81IUq16cHjhLTvJu4FA33AGWWjCpTnA}"

  curl -fsS --max-time "$TERMPEEK_X_TIMEOUT" \
    -H "authorization: Bearer ${bearer}" \
    -H "x-csrf-token: ${ct0}" \
    -H "cookie: auth_token=${auth}; ct0=${ct0}" \
    -H 'User-Agent: Mozilla/5.0' \
    "https://api.x.com/1.1/statuses/show.json?id=${id}&tweet_mode=extended&include_entities=true" 2>/dev/null
}

# --- normalization ----------------------------------------------------------
# Each source has its own field names. Rather than teach the renderer three
# schemas, map them all here.

tp_x_normalize() {
  tp_x_need jq || return 127
  jq -c '
    def num(x): (x // 0) | tonumber? // 0;
    if .user and .text then                       # syndication / statuses.show
      {
        name:     (.user.name // "unknown"),
        handle:   (.user.screen_name // ""),
        verified: ((.user.is_blue_verified // .user.verified // false) == true),
        avatar:   (.user.profile_image_url_https // .user.profile_image_url // ""),
        text:     (.full_text // .text // ""),
        created:  (.created_at // ""),
        likes:    num(.favorite_count),
        replies:  num(.conversation_count // .reply_count),
        reposts:  num(.retweet_count),
        media:    [ (.mediaDetails // .photos // .extended_entities.media // [])[]
                    | (.media_url_https // .url // empty) ]
      }
    elif .data then                               # X API v2 (xint)
      (.includes.users[0] // {}) as $u
      | {
          name:     ($u.name // "unknown"),
          handle:   ($u.username // ""),
          verified: (($u.verified // false) == true),
          avatar:   ($u.profile_image_url // ""),
          text:     (.data.text // ""),
          created:  (.data.created_at // ""),
          likes:    num(.data.public_metrics.like_count),
          replies:  num(.data.public_metrics.reply_count),
          reposts:  num(.data.public_metrics.retweet_count),
          media:    [ (.includes.media // [])[] | (.url // .preview_image_url // empty) ]
        }
    else
      empty
    end
  '
}

# Try each backend until one yields a usable record.
tp_x_fetch() {
  local id="$1" want="${TERMPEEK_X_BACKEND:-auto}"
  local raw out

  # Fetching dominates this path — measured at ~595ms for a card, nearly all of
  # it network. A post's text never changes, but its counts do, so this expires
  # rather than living forever. Caching also blunts the flakiest dependency in
  # the project: an undocumented endpoint that can rate-limit or vanish.
  local ckey; ckey="$(tp_cache_key "x" "$id" "$want")"
  local hit; hit="$(tp_cache_get x "$ckey" "$TERMPEEK_CACHE_TTL")"
  if [[ -n "$hit" ]]; then
    cat "$hit"
    return 0
  fi

  for backend in syndication xint cookies; do
    if [[ "$want" != "auto" && "$want" != "$backend" ]]; then continue; fi
    case "$backend" in
      syndication) raw="$(tp_x_fetch_syndication "$id")" ;;
      xint)        raw="$(tp_x_fetch_xint "$id")" ;;
      cookies)     raw="$(tp_x_fetch_cookies "$id")" ;;
    esac
    [[ -z "$raw" ]] && continue
    out="$(printf '%s' "$raw" | tp_x_normalize 2>/dev/null)"
    if [[ -n "$out" && "$out" != "null" ]]; then
      local tmp; tmp="$(mktemp "${TMPDIR:-/tmp}/tp-x.XXXXXX")"
      printf '%s' "$out" > "$tmp"
      tp_cache_put x "$ckey" "$tmp" >/dev/null
      rm -f "$tmp"
      printf '%s' "$out"
      return 0
    fi
  done

  echo "termpeek: could not fetch post $id (tried: ${want})" >&2
  return 1
}
