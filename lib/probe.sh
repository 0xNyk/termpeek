#!/usr/bin/env bash
# termpeek — terminal capability probe
#
# Why this exists: chafa and timg both auto-detect graphics support, and both
# silently fall back to block art when the detection query fails (e.g. stdout is
# a pipe, or the process was spawned without an interactive tty). During the P0
# spike, timg fell back to quarter-blocks with exit code 0 and no warning, which
# looked like "video is broken" rather than "protocol was downgraded".
#
# So: probe ONCE, cache it, and always pass renderers an explicit protocol flag.
# Never let the renderer decide.

set -uo pipefail

TERMPEEK_CACHE="${TERMPEEK_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/termpeek}"

# Emit one of: kitty | iterm | sixel | symbols
tp_detect_protocol() {
  # Explicit override always wins.
  if [[ -n "${TERMPEEK_PROTOCOL:-}" ]]; then
    printf '%s' "$TERMPEEK_PROTOCOL"
    return 0
  fi

  local prog="${TERM_PROGRAM:-}" term="${TERM:-}"

  # Multiplexers hide the host terminal's identity. Inside tmux, TERM becomes
  # tmux-256color and TERM_PROGRAM becomes "tmux", so naive detection reports
  # `symbols` and silently throws away graphics support the host actually has.
  # Ask tmux what the attached client is running under instead.
  if [[ -n "${TMUX:-}" ]]; then
    if [[ -n "${TERMPEEK_HOST_PROTOCOL:-}" ]]; then
      printf '%s' "$TERMPEEK_HOST_PROTOCOL"; return 0
    fi
    local cached; cached="$(tp_load_host_protocol)"
    # Ignore a cached fallback for the same reason it should never be written.
    case "$cached" in
      kitty|iterm|sixel) printf '%s' "$cached"; return 0 ;;
    esac
    if command -v tmux >/dev/null 2>&1; then
      local ct
      ct="$(tmux display-message -p '#{client_termname}' 2>/dev/null)"
      case "$ct" in
        xterm-ghostty|xterm-kitty|*kitty*) printf 'kitty'; return 0 ;;
        iterm|*iterm*)                     printf 'iterm'; return 0 ;;
      esac
    fi
  fi

  case "$prog" in
    ghostty)  printf 'kitty'  ; return 0 ;;  # Kitty graphics yes, sixel never
    iTerm.app) printf 'iterm' ; return 0 ;;
    WezTerm)  printf 'kitty'  ; return 0 ;;
    vscode)   printf 'symbols'; return 0 ;;  # integrated terminal: no graphics
  esac

  case "$term" in
    xterm-kitty|*kitty*) printf 'kitty'  ; return 0 ;;
    xterm-ghostty)       printf 'kitty'  ; return 0 ;;
    foot|*foot*)         printf 'sixel'  ; return 0 ;;
    dumb|"")             printf 'symbols'; return 0 ;;
  esac

  # Unknown terminal: symbols renders everywhere, so it is the safe floor.
  printf 'symbols'
}

# Does this protocol carry real pixels, or is it character art?
tp_is_pixel_protocol() {
  case "$1" in
    kitty|iterm|sixel) return 0 ;;
    *)                 return 1 ;;
  esac
}

# Cache the host terminal's protocol before entering tmux, so the probe above
# has something trustworthy to read once TERM has been rewritten.
# Only ever cache a POSITIVE result. "symbols" is what detection returns when it
# could not tell — caching that poisons every later preview in the session, and
# the cache outlives the session, so one bad detection degrades the tool
# permanently until someone clears it by hand. Observed exactly that: a stale
# "symbols" entry silently forced block art in a terminal that does kitty.
tp_record_host_protocol() {
  local proto; proto="$(tp_detect_protocol)"
  case "$proto" in
    kitty|iterm|sixel) ;;
    *) return 0 ;;
  esac
  mkdir -p "$TERMPEEK_CACHE" 2>/dev/null || return 0
  printf '%s' "$proto" > "$TERMPEEK_CACHE/host-protocol"
}

tp_load_host_protocol() {
  [[ -r "$TERMPEEK_CACHE/host-protocol" ]] && cat "$TERMPEEK_CACHE/host-protocol"
}

# Which transport can actually put pixels in front of the user?
#   inline  — we own the tty, write escapes directly
#   tmux    — inside tmux, use a split/popup the agent TUI never repaints
#   window  — spawn a separate OS window
#   none    — nothing available
#
# Agent CLIs (Claude Code, Codex, Hermes) capture subprocess stdout as text and
# leave /dev/tty unopenable, so "inline" is never available from inside one.
# Verified on Claude Code: `tty` => "not a tty", /dev/tty => "device not configured".
tp_detect_transport() {
  if [[ -n "${TERMPEEK_TRANSPORT:-}" ]]; then
    printf '%s' "$TERMPEEK_TRANSPORT"
    return 0
  fi

  if [[ -n "${TMUX:-}" ]] && command -v tmux >/dev/null 2>&1; then
    printf 'tmux'; return 0
  fi

  # Do we own a real terminal? If so we can just print.
  if [[ -t 1 ]] && { : > /dev/tty; } 2>/dev/null; then
    printf 'inline'; return 0
  fi

  case "$(uname -s)" in
    Darwin) printf 'window'; return 0 ;;
    Linux)
      # Only if there is a display to put a window on. Over plain SSH or in a
      # container there is not, and claiming otherwise means spawning a process
      # that dies without ever showing anything.
      if [[ -n "${WAYLAND_DISPLAY:-}${DISPLAY:-}" ]] && [[ -n "$(tp_linux_terminal)" ]]; then
        printf 'window'; return 0
      fi
      ;;
  esac

  printf 'none'
}

# First usable terminal emulator on Linux, respecting $TERMINAL if the user set
# it. Ordered so terminals that can actually draw pixels come first — falling
# back to xterm means block art, which works but is a downgrade.
tp_linux_terminal() {
  if [[ -n "${TERMINAL:-}" ]] && command -v "${TERMINAL%% *}" >/dev/null 2>&1; then
    printf '%s' "${TERMINAL%% *}"
    return 0
  fi
  local t
  for t in kitty wezterm ghostty foot konsole alacritty gnome-terminal \
           xfce4-terminal x-terminal-emulator xterm; do
    if command -v "$t" >/dev/null 2>&1; then
      printf '%s' "$t"
      return 0
    fi
  done
  printf ''
  return 1
}

tp_probe_report() {
  printf 'protocol   %s\n' "$(tp_detect_protocol)"
  printf 'transport  %s\n' "$(tp_detect_transport)"
  printf 'TERM       %s\n' "${TERM:-<unset>}"
  printf 'TERM_PROGRAM %s\n' "${TERM_PROGRAM:-<unset>}"
  printf 'TMUX       %s\n' "${TMUX:-<none>}"
  printf 'stdout_tty %s\n' "$([[ -t 1 ]] && echo yes || echo no)"
  printf 'dev_tty    %s\n' "$({ : > /dev/tty; } 2>/dev/null && echo writable || echo unavailable)"
}

# Allow running this file directly as a probe.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  tp_probe_report
fi
