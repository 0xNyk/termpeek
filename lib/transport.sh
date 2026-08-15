#!/usr/bin/env bash
# termpeek — transports
#
# The core problem: agent CLIs (Claude Code, Codex, Hermes, Gemini) run a
# full-screen TUI that owns the terminal. They capture subprocess stdout as
# text, sanitize escape sequences the model emits, and repaint over anything
# written directly to the PTY. /dev/tty is not even openable from a tool call.
# Verified on Claude Code + Ghostty: `tty` => "not a tty",
# /dev/tty => "device not configured".
#
# So we never try to draw *into* the agent's TUI. We draw somewhere it does not
# repaint:
#
#   tmux    — a split pane or popup in the same window. Preferred: it sits
#             beside the conversation, persists, and needs no window switch.
#   window  — a separate OS window. Always available on macOS; costs a focus
#             change, so it is the fallback rather than the default.
#   inline  — we own the tty (running termpeek by hand, not under an agent).

set -uo pipefail

TERMPEEK_LIB="${TERMPEEK_LIB:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
# shellcheck source=./probe.sh
source "$TERMPEEK_LIB/probe.sh"

TERMPEEK_RUNTIME="${TERMPEEK_RUNTIME:-${TMPDIR:-/tmp}/termpeek-$(id -u)}"

tp__runtime_dir() { mkdir -p "$TERMPEEK_RUNTIME"; printf '%s' "$TERMPEEK_RUNTIME"; }

# Write a self-deleting script that renders one target, then holds the pane open.
# Rendering happens in the *destination* pane so the escape sequences are
# interpreted by a terminal we control, never by the agent's TUI.
tp__make_runner() {
  local target="$1" hold="${2:-1}"
  local dir; dir="$(tp__runtime_dir)"
  local runner; runner="$dir/run-$$-$RANDOM.sh"
  cat > "$runner" <<EOF
#!/usr/bin/env bash
export TERMPEEK_LIB="$TERMPEEK_LIB"
export TERMPEEK_GEOMETRY="${TERMPEEK_GEOMETRY:-80x40}"
export TERMPEEK_PROTOCOL="${TERMPEEK_PROTOCOL:-$(tp_detect_protocol)}"
export TERMPEEK_LOOPS="${TERMPEEK_LOOPS:-1}"
export TERMPEEK_PDF_PAGE="${TERMPEEK_PDF_PAGE:-1}"
${TERMPEEK_PDF_DPI:+export TERMPEEK_PDF_DPI="$TERMPEEK_PDF_DPI"}
export TERMPEEK_RENDER_MODE="${TERMPEEK_RENDER_MODE:-auto}"
source "$TERMPEEK_LIB/render.sh"
printf '\033]0;termpeek: %s\007' "$(basename "$target")"
if [[ "\$TERMPEEK_RENDER_MODE" == "sheet" ]]; then
  tp_render_pdf_sheet "$target"
else
  tp_render "$target"
fi
status=\$?
rm -f "$runner"
if [[ "$hold" == "1" ]]; then
  printf '\n\033[2m[termpeek] %s — press enter to close\033[0m\n' "$(basename "$target")"
  read -r
fi
exit \$status
EOF
  chmod +x "$runner"
  printf '%s' "$runner"
}

# --- tmux -------------------------------------------------------------------
# A dedicated, reused sidebar pane. Reusing one pane (rather than spawning a new
# split per preview) keeps the layout stable across many previews, which is the
# difference between a usable sidebar and a screen full of shrinking panes.
# tmux swallows the APC sequences that carry kitty graphics unless passthrough
# is enabled, so images silently render as nothing. Turning it on is required
# for any pixel protocol to survive the multiplexer.
tp__tmux_prepare() {
  local cur
  cur="$(tmux show -gv allow-passthrough 2>/dev/null)"
  if [[ "$cur" != "on" && "$cur" != "all" ]]; then
    tmux set -g allow-passthrough on 2>/dev/null
  fi
}

tp_transport_tmux() {
  local target="$1" mode="${TERMPEEK_TMUX_MODE:-sidebar}"
  tp__tmux_prepare
  # Cache the host terminal's protocol while a client is attached, so later
  # previews do not fall back to `symbols` when the query is unavailable.
  tp_record_host_protocol 2>/dev/null || true

  case "$mode" in
    popup)
      # Floating, dismissible, does not disturb the layout at all.
      local runner; runner="$(tp__make_runner "$target" 0)"
      tmux display-popup -E -w "${TERMPEEK_POPUP_W:-80%}" -h "${TERMPEEK_POPUP_H:-80%}" \
        "$runner; printf '\n[termpeek] press enter to close\n'; read -r"
      ;;
    sidebar|*)
      # The sidebar must OUTLIVE the render. A pane whose command exits is
      # closed by tmux immediately, so the preview would flash and vanish —
      # observed as "the split never appeared". hold=1 parks the runner on a
      # read; respawn-pane -k replaces it for the next preview.
      local runner; runner="$(tp__make_runner "$target" 1)"
      local pane
      pane="$(tmux list-panes -F '#{pane_id} #{@termpeek}' 2>/dev/null \
              | awk '$2=="1"{print $1; exit}')"
      if [[ -n "$pane" ]]; then
        tmux respawn-pane -k -t "$pane" "$runner" 2>/dev/null && return 0
      fi
      pane="$(tmux split-window -h -P -F '#{pane_id}' \
                -l "${TERMPEEK_SIDEBAR_WIDTH:-45%}" "$runner")" || return 1
      tmux set-option -p -t "$pane" @termpeek 1 2>/dev/null
      # Keep the pane open if the runner ever dies, rather than collapsing the
      # layout mid-session.
      tmux set-option -p -t "$pane" remain-on-exit on 2>/dev/null
      tmux select-pane -t '{last}' 2>/dev/null   # give focus back to the agent
      ;;
  esac
}

# --- separate OS window -----------------------------------------------------
# `ghostty +new-window` exists as an action but is NOT supported on macOS
# (verified: "+new-window is not supported on this platform"), so we go through
# `open -na`, which is the documented macOS path.
tp_transport_window() {
  local target="$1"
  local runner; runner="$(tp__make_runner "$target" 1)"
  local app="${TERMPEEK_WINDOW_APP:-}"

  if [[ -z "$app" ]]; then
    case "${TERM_PROGRAM:-}" in
      ghostty)   app="Ghostty" ;;
      iTerm.app) app="iTerm" ;;
      *)         app="Ghostty" ;;
    esac
  fi

  if [[ -d "/Applications/$app.app" ]]; then
    open -na "$app.app" --args -e "$runner"
  else
    open -na Terminal.app "$runner"
  fi
}

tp_transport_inline() {
  local target="$1"
  # shellcheck source=./render.sh
  source "$TERMPEEK_LIB/render.sh"
  tp_render "$target"
}

# --- dispatch ---------------------------------------------------------------
tp_show() {
  local target="$1"
  local transport="${2:-$(tp_detect_transport)}"

  case "$transport" in
    tmux)   tp_transport_tmux   "$target" ;;
    window) tp_transport_window "$target" ;;
    inline) tp_transport_inline "$target" ;;
    none)
      echo "termpeek: no usable transport (no tmux, no tty, not macOS)" >&2
      return 69 ;;
    *)
      echo "termpeek: unknown transport: $transport" >&2
      return 64 ;;
  esac
}
