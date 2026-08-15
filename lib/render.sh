#!/usr/bin/env bash
# termpeek — type detection and renderer routing
#
# Each renderer is handed an EXPLICIT protocol flag. See lib/probe.sh for why
# auto-detection is never trusted.

set -uo pipefail

TERMPEEK_LIB="${TERMPEEK_LIB:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
# shellcheck source=./probe.sh
source "$TERMPEEK_LIB/probe.sh"
# shellcheck source=./cache.sh
source "$TERMPEEK_LIB/cache.sh"

TP_GEOMETRY="${TERMPEEK_GEOMETRY:-80x40}"

# --- type detection ---------------------------------------------------------
# Emits: image | video | pdf | diff | file | tweet | missing
tp_detect_type() {
  local target="$1"

  case "$target" in
    https://x.com/*/status/*|https://twitter.com/*/status/*) printf 'tweet'; return 0 ;;
  esac

  [[ -e "$target" ]] || { printf 'missing'; return 0; }

  local lower; lower="$(printf '%s' "$target" | tr '[:upper:]' '[:lower:]')"
  case "$lower" in
    *.png|*.jpg|*.jpeg|*.gif|*.webp|*.svg|*.avif|*.jxl|*.tiff|*.bmp|*.qoi)
      printf 'image'; return 0 ;;
    *.mp4|*.mov|*.webm|*.mkv|*.avi|*.m4v)
      printf 'video'; return 0 ;;
    *.pdf)
      printf 'pdf'; return 0 ;;
    *.diff|*.patch)
      printf 'diff'; return 0 ;;
  esac

  # Unified diffs are frequently produced without a .diff extension.
  if head -n 40 "$target" 2>/dev/null | grep -qE '^(diff --git |--- |\+\+\+ |@@ )'; then
    printf 'diff'; return 0
  fi

  printf 'file'
}

# --- renderers --------------------------------------------------------------
# Every renderer writes escape sequences to stdout. The transport layer decides
# where that stdout actually lands.

# --- one renderer inside a multiplexer --------------------------------------
# tmux keeps no graphics in its screen buffer. Passthrough forwards the bytes
# once; the placeholder glyphs are the only part that survives a redraw. That
# makes the renderer's transmission strategy decisive, and only chafa's holds
# up here — measured in a live pane, chafa emitted 1.69 MB for a test image
# where timg emitted 3.6 KB for the same one.
#
# timg also refuses to upscale past a source's native size, so a 240x136 clip
# drew 15x5 cells in a 70x30 pane. That reads as "the video did not show".
#
# So inside tmux every path goes through chafa, and anything timg would have
# tiled or animated is composed into a single image first.

tp__passthrough() {
  [[ -n "${TMUX:-}" ]] && { printf 'tmux'; return 0; }
  [[ -n "${STY:-}" ]] && { printf 'screen'; return 0; }
  printf 'none'
}

# chafa cannot play audio, so an explicit timg request still wins outside tmux.
tp__use_chafa() {
  [[ "${TERMPEEK_RENDERER:-}" == "timg" ]] && return 1
  [[ -n "${TMUX:-}" ]]
}

# The pixel box the current geometry actually paints, optionally supersampled.
# Rasterising to this size means downscaling is what sharpens the result,
# instead of chafa enlarging a raster that was already too small — which is
# what made PDFs and cards look soft.
tp__display_px() {
  local mult="${1:-1}"
  local cw ch cell cpx cpy
  cw="$(printf '%s' "$TP_GEOMETRY" | cut -dx -f1)"
  ch="$(printf '%s' "$TP_GEOMETRY" | cut -dx -f2)"
  cell="$(tp__cell_pixels)"
  cpx="$(printf '%s' "$cell" | cut -dx -f1)"
  cpy="$(printf '%s' "$cell" | cut -dx -f2)"
  local w=$(( cw * cpx * mult )) h=$(( ch * cpy * mult ))
  (( w > 0 )) || w=$(( 800 * mult ))
  (( h > 0 )) || h=$(( 1000 * mult ))
  printf '%sx%s' "$w" "$h"
}

tp__chafa() {
  local target="$1" proto="$2"; shift 2
  local fmt="$proto"; [[ "$fmt" == "sixel" ]] && fmt="sixels"
  chafa -f "$fmt" --passthrough "$(tp__passthrough)" --size "$TP_GEOMETRY" \
    "$@" "$target"
}

tp_render_image() {
  local target="$1" proto="${2:-$(tp_detect_protocol)}"
  command -v chafa >/dev/null 2>&1 || { echo "termpeek: chafa not installed (brew install chafa)" >&2; return 127; }
  tp__chafa "$target" "$proto"
}

# Compose images into one grid PNG, so a tiled view is a single transmission
# rather than N of them. Every tile is letterboxed to the same box because
# xstack requires uniform inputs and silently produces nothing otherwise.
#   tp__montage <out.png> <cols> <file>...
tp__montage() {
  local out="$1" cols="$2"; shift 2
  (( $# > 0 )) || return 1
  command -v ffmpeg >/dev/null 2>&1 || return 1

  # ffmpeg cannot decode SVG, and chafa can — so the resolver hands SVGs
  # straight through. Composing them therefore needs a raster step first, or
  # xstack fails and the whole tiled path silently falls back to timg.
  local work; work="$(mktemp -d "${TMPDIR:-/tmp}/termpeek-mtg.XXXXXX")" || return 1
  local -a src=(); local f i=0
  for f in "$@"; do
    case "${f##*.}" in
      svg|SVG)
        if command -v rsvg-convert >/dev/null 2>&1 \
           && rsvg-convert -w "${TERMPEEK_MONTAGE_RASTER:-1200}" \
                -o "$work/i$i.png" "$f" 2>/dev/null; then
          src+=("$work/i$i.png")
        else
          rm -rf "$work"; return 1
        fi ;;
      *) src+=("$f") ;;
    esac
    i=$(( i + 1 ))
  done
  set -- "${src[@]}"

  local n=$#
  (( cols > n )) && cols=$n
  (( cols > 0 )) || cols=1
  local rows=$(( (n + cols - 1) / cols ))

  # Tile width comes from the box; tile HEIGHT comes from the content's own
  # aspect ratio. Splitting the box's height evenly instead padded three wide
  # cards into tall boxes and spent most of the pane on background.
  local box bw bh tw th
  box="$(tp__display_px 2)"
  bw="$(printf '%s' "$box" | cut -dx -f1)"
  bh="$(printf '%s' "$box" | cut -dx -f2)"
  tw=$(( bw / cols ))
  (( tw > 16 )) || tw=16

  local dims sw sh
  dims="$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height \
          -of csv=p=0 "$1" 2>/dev/null)"
  sw="${dims%%,*}"; sh="${dims##*,}"
  if [[ "$sw" =~ ^[0-9]+$ ]] && [[ "$sh" =~ ^[0-9]+$ ]] && (( sw > 0 )); then
    th=$(( tw * sh / sw ))
  else
    th=$(( bh / rows ))
  fi
  (( th > 16 )) || th=16

  # Never let the assembled grid exceed the box, or chafa shrinks the whole
  # thing and the extra resolution is wasted.
  if (( rows * th > bh )); then
    tw=$(( tw * bh / (rows * th) ))
    th=$(( bh / rows ))
    (( tw > 16 )) || tw=16
  fi
  tw=$(( tw / 2 * 2 )); th=$(( th / 2 * 2 ))

  local -a args=() ; local filter="" layout="" i=0 f
  for f in "$@"; do
    args+=(-i "$f")
    filter+="[$i:v]scale=${tw}:${th}:force_original_aspect_ratio=decrease,"
    filter+="pad=${tw}:${th}:(ow-iw)/2:(oh-ih)/2:0x0d1117,setsar=1[t$i];"
    [[ -n "$layout" ]] && layout+="|"
    layout+="$(( (i % cols) * tw ))_$(( (i / cols) * th ))"
    i=$(( i + 1 ))
  done
  for (( i = 0; i < n; i++ )); do filter+="[t$i]"; done

  local rc
  if (( n == 1 )); then
    ffmpeg -y "${args[@]}" -filter_complex "${filter%%;*}" -map "[t0]" \
      -frames:v 1 "$out" >/dev/null 2>&1
    rc=$?
  else
    filter+="xstack=inputs=${n}:layout=${layout}:fill=0x0d1117[o]"
    ffmpeg -y "${args[@]}" -filter_complex "$filter" -map "[o]" \
      -frames:v 1 "$out" >/dev/null 2>&1
    rc=$?
  fi
  rm -rf "$work"
  [[ -s "$out" ]] || return 1
  return $rc
}

# Video -> animated GIF at the pane's real pixel width, then chafa. Beats
# handing timg the file directly on both counts that matter here: the
# transmission survives tmux, and ffmpeg will scale a small source UP.
tp__video_gif() {
  local src="$1" dst="$2"
  local fps="${TERMPEEK_VIDEO_FPS:-12}"
  local w; w="$(tp__display_px | cut -dx -f1)"
  ffmpeg -y -i "$src" -vf \
"fps=${fps},scale=${w}:-2:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4" \
    -loop 0 "$dst" >/dev/null 2>&1
}

# An earlier version downgraded timg to blocks inside tmux, on the strength of a
# measurement taken in a DETACHED session — where timg cannot query cell size
# and renders one frame regardless. With a client attached, kitty works in a
# pane: a chart rendered there at full fidelity. The downgrade only made video
# and galleries needlessly blocky, so it is gone.
tp__timg_in_tmux() { return 1; }

tp__timg_pixelation() {
  if tp__timg_in_tmux; then printf 'q'; return 0; fi
  case "$1" in
    kitty) printf 'k' ;;
    iterm) printf 'i' ;;
    sixel) printf 's' ;;
    *)     printf 'q' ;;
  esac
}

# Video, and the pixel-size query trap.
#
# To animate under kitty graphics, timg needs the terminal's pixels-per-cell,
# which it gets from TIOCGWINSZ or the "[16t" query. When nothing answers, timg
# does not fail loudly: it renders ONE frame, exits 0, and mentions the downgrade
# on stderr. That looks exactly like "video is broken".
#
# Crucially, the query only fails when stdout is not a real terminal. Measured
# both ways on the same clip:
#   piped        -> 1 kitty frame   (frozen)
#   real Ghostty -> 75 frames @ 15.1fps, 16.5 MiB, "Using kitty graphics"
#
# Every termpeek transport renders inside a real terminal (a tmux pane or a
# spawned window), so kitty is the correct default and gives markedly better
# quality than quarter-blocks. We only downgrade when we can see that stdout is
# not a tty, or when the caller forces it.
#
# (chafa can also animate a GIF under kitty, but it retransmits whole frames:
# 143 MB for the same 6 seconds versus timg's 16.5 MiB. Not worth it.)
tp_render_video() {
  local target="$1" proto="${2:-$(tp_detect_protocol)}" loops="${TERMPEEK_LOOPS:-1}"

  # Preferred path inside a multiplexer: GIF via ffmpeg, played by chafa.
  if tp__use_chafa && tp_is_pixel_protocol "$proto" \
     && command -v ffmpeg >/dev/null 2>&1 && command -v chafa >/dev/null 2>&1; then
    local tmp; tmp="$(mktemp -d "${TMPDIR:-/tmp}/termpeek-vid.XXXXXX")" || return 1
    if tp__video_gif "$target" "$tmp/v.gif" && [[ -s "$tmp/v.gif" ]]; then
      # chafa has no loop count; it plays for --duration and stops. Ask ffprobe
      # how long the clip is so `--loops 2` means two passes rather than a
      # guess, and fall back to a sane hold if the duration is unreadable.
      local secs
      secs="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$target" 2>/dev/null)"
      secs="${secs%%.*}"; [[ "$secs" =~ ^[0-9]+$ ]] || secs=5
      (( secs > 0 )) || secs=1
      local dur
      if (( loops < 0 )); then dur=inf; else dur=$(( secs * loops )); fi
      tp__chafa "$tmp/v.gif" "$proto" --animate on --duration "$dur"
      local rc=$?
      rm -rf "$tmp"
      return $rc
    fi
    rm -rf "$tmp"
  fi

  command -v timg >/dev/null 2>&1 || { echo "termpeek: timg not installed (brew install timg)" >&2; return 127; }

  local p
  if [[ "${TERMPEEK_FORCE_BLOCKS:-0}" == "1" ]] || tp__timg_in_tmux \
     || { [[ "$proto" == "kitty" ]] && [[ ! -t 1 ]]; }; then
    p=q   # coarse but visible beats sharp and absent
  else
    p="$(tp__timg_pixelation "$proto")"
  fi

  local -a extra=()
  # --compress applies only to the pixel protocols and cuts bandwidth sharply.
  [[ "$p" == "k" || "$p" == "i" ]] && extra+=("--compress=${TERMPEEK_COMPRESS:-1}")

  # bash 3.2 (macOS): expanding an empty array under `set -u` aborts the script,
  # so every possibly-empty array expansion is guarded with ${a[@]+"${a[@]}"}.
  timg -p "$p" -g "$TP_GEOMETRY" --loops="$loops" ${extra[@]+"${extra[@]}"} "$target"
}

tp__pdf_pages() {
  local n=""
  if command -v pdfinfo >/dev/null 2>&1; then
    n="$(pdfinfo "$1" 2>/dev/null | awk '/^Pages:/{print $2}')"
  fi
  printf '%s' "${n:-?}"
}

# Pixels per character cell. Sharpness depends on this: if we rasterize at some
# arbitrary DPI and then let chafa resample down to the cell grid, text goes
# through two lossy resizes and turns mushy. Rendering at exactly the pixel size
# the terminal will draw removes the second resize entirely.
#
# Measured on Ghostty 1.3.1 (retina): 16x34. 8x16 is the classic non-retina cell
# and is a safe floor when nothing reports.
tp__cell_pixels() {
  if [[ -n "${TERMPEEK_CELL_PX:-}" ]]; then
    printf '%s' "$TERMPEEK_CELL_PX"; return 0
  fi
  local cached="$TERMPEEK_CACHE/cell-px"
  if [[ -r "$cached" ]]; then
    cat "$cached"; return 0
  fi
  # timg reports "cell-pixels: WxH" when a real terminal answers the query.
  if [[ -t 1 ]] && command -v timg >/dev/null 2>&1; then
    local px
    px="$(timg --verbose -g 1x1 /dev/null 2>&1 | awk '/cell-pixels:/{print $NF; exit}')"
    if [[ "$px" == *x* ]]; then
      mkdir -p "$TERMPEEK_CACHE" 2>/dev/null && printf '%s' "$px" > "$cached"
      printf '%s' "$px"; return 0
    fi
  fi
  printf '%s' "${TERMPEEK_CELL_PX_DEFAULT:-8x16}"
}

# Compose one rasterized page into something that reads as a *document*: flatten
# onto white (PDF pages are often transparent, which otherwise picks up the
# terminal background and stops looking like paper), add a page margin, then a
# thin grey edge so the sheet has a visible boundary.
#
# Done with ffmpeg because it is already a dependency; ImageMagick is not
# installed and this needs no more than pad + drawbox.
tp__pdf_frame() {
  local src="$1" dst="$2" m="${TERMPEEK_PDF_MARGIN:-24}"
  command -v ffmpeg >/dev/null 2>&1 || return 1
  ffmpeg -y -i "$src" -vf \
    "color=white:s=1x1[bg];[bg][0:v]scale2ref[b][v];[b][v]overlay=shortest=1,pad=iw+${m}*2:ih+${m}*2:${m}:${m}:white,drawbox=x=${m}-1:y=${m}-1:w=iw-${m}*2+2:h=ih-${m}*2+2:color=0x9a9a9a:t=2" \
    -frames:v 1 "$dst" >/dev/null 2>&1
}

# PDFs: timg links poppler and can render them directly, but it rasterizes to
# roughly the cell grid, which turns small text into mush. Rendering with
# pdftoppm at a real DPI first and handing chafa a high-resolution PNG keeps the
# glyphs legible. pdftoppm ships with poppler, which timg already depends on.
tp_render_pdf() {
  local target="$1" proto="${2:-$(tp_detect_protocol)}"
  local page="${TERMPEEK_PDF_PAGE:-1}"
  local pages; pages="$(tp__pdf_pages "$target")"

  if command -v pdftoppm >/dev/null 2>&1 && command -v chafa >/dev/null 2>&1; then
    # Rasterizing and framing a page costs ~250ms and produces the same bytes
    # every time. The key includes the file's mtime and size, so editing the
    # PDF invalidates it and a stale page can never be served.
    local ckey; ckey="$(tp_cache_key_file "$target" "pdf" "$page" \
      "${TERMPEEK_PDF_DPI:-auto}" "$TP_GEOMETRY" "$(tp__cell_pixels)")"
    local hit; hit="$(tp_cache_get render "$ckey")"
    if [[ -n "$hit" ]]; then
      printf '\033[1m%s\033[0m  \033[2m·  PDF  ·  page %s of %s\033[0m\n' \
        "$(basename "$target")" "$page" "$pages"
      if [[ "$pages" != "?" && "$pages" != "1" ]]; then
        printf '\033[2m[ page %s of %s — --page <n> to move, --pages for contact sheet ]\033[0m\n' \
          "$page" "$pages"
      fi
      tp_render_image "$hit" "$proto"
      return $?
    fi

    local tmp; tmp="$(mktemp -d "${TMPDIR:-/tmp}/termpeek-pdf.XXXXXX")" || return 1

    # Rasterize at exactly the pixel width the terminal will paint, so chafa
    # does no second downscale. Margin cells are reserved for the paper border.
    # Rasterise at 2x the box the pane paints. Rendering at exactly the display
    # size left nothing for chafa to average over, so glyph stems landed on
    # single cells and the page read as soft; supersampling makes the downscale
    # itself do the anti-aliasing. 2x is where the sharpness stops improving
    # and the ~250ms raster cost starts to show.
    local ss="${TERMPEEK_SUPERSAMPLE:-2}"
    local box; box="$(tp__display_px "$ss")"
    local target_w target_h
    target_w="$(printf '%s' "$box" | cut -dx -f1)"
    target_h="$(printf '%s' "$box" | cut -dx -f2)"
    (( target_w > 0 )) || target_w=$(( 800 * ss ))
    (( target_h > 0 )) || target_h=$(( 1000 * ss ))

    # -scale-to-x/-scale-to-y with -1 preserves aspect; bound by the smaller fit
    # so a portrait page is limited by height, not width.
    local -a pp=(-png -f "$page" -l "$page" -aa yes -aaVector yes
                 -scale-to-x "$target_w" -scale-to-y -1)
    if [[ -n "${TERMPEEK_PDF_DPI:-}" ]]; then
      pp=(-png -f "$page" -l "$page" -aa yes -aaVector yes -r "$TERMPEEK_PDF_DPI")
    fi

    if pdftoppm "${pp[@]}" "$target" "$tmp/page" 2>/dev/null; then
      local png; png="$(find "$tmp" -name 'page*.png' -print -quit)"

      # If the aspect-preserved page overflows the available height, redo it
      # bounded by height instead. Cheaper than guessing the page geometry.
      if [[ -n "$png" ]] && command -v ffprobe >/dev/null 2>&1 && [[ -z "${TERMPEEK_PDF_DPI:-}" ]]; then
        local h; h="$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 "$png" 2>/dev/null)"
        if [[ -n "$h" ]] && (( h > target_h )); then
          rm -f "$tmp"/page*.png
          pdftoppm -png -f "$page" -l "$page" -aa yes -aaVector yes \
            -scale-to-y "$target_h" -scale-to-x -1 "$target" "$tmp/page" 2>/dev/null
          png="$(find "$tmp" -name 'page*.png' -print -quit)"
        fi
      fi

      if [[ -n "$png" ]]; then
        local framed="$tmp/framed.png"
        tp__pdf_frame "$png" "$framed" || framed="$png"
        framed="$(tp_cache_put render "$ckey" "$framed")"

        printf '\033[1m%s\033[0m  \033[2m·  PDF  ·  page %s of %s\033[0m\n' \
          "$(basename "$target")" "$page" "$pages"
        # Counter BEFORE the image: printing after it forces a tmux redraw and
        # tmux does not re-send graphics, so the page would vanish.
        if [[ "$pages" != "?" && "$pages" != "1" ]]; then
          printf '\033[2m[ page %s of %s — --page <n> to move, --pages for contact sheet ]\033[0m\n' \
            "$page" "$pages"
        fi
        tp_render_image "$framed" "$proto"
        local rc=$?
        rm -rf "$tmp"
        return $rc
      fi
    fi
    rm -rf "$tmp"
  fi

  # Fallback: let timg do it directly.
  command -v timg >/dev/null 2>&1 || { echo "termpeek: need pdftoppm+chafa or timg for PDFs" >&2; return 127; }
  timg -p "$(tp__timg_pixelation "$proto")" -g "$TP_GEOMETRY" "$target"
}

# Contact sheet: every page as a thumbnail grid, the way a PDF viewer's page
# navigator looks. timg's --grid does the layout.
tp_render_pdf_sheet() {
  local target="$1" proto="${2:-$(tp_detect_protocol)}"
  local pages; pages="$(tp__pdf_pages "$target")"
  local cols="${TERMPEEK_PDF_COLS:-3}"
  local max="${TERMPEEK_PDF_MAX_PAGES:-12}"

  command -v pdftoppm >/dev/null 2>&1 || { echo "termpeek: pdftoppm required" >&2; return 127; }
  if ! tp__use_chafa; then
    command -v timg >/dev/null 2>&1 || { echo "termpeek: timg required for contact sheets" >&2; return 127; }
  fi

  local last="$pages"
  [[ "$last" == "?" ]] && last=1
  (( last > max )) && last=$max

  local tmp; tmp="$(mktemp -d "${TMPDIR:-/tmp}/termpeek-sheet.XXXXXX")" || return 1
  # timg labels each cell with the file's basename — it has no page-number
  # format specifier (%f %b %w %h %D are the whole set), so the page number has
  # to be in the filename itself.
  # Size each page to the tile it will occupy rather than a fixed 600px, which
  # was an upscale in a wide pane and wasted raster time in a narrow one.
  local sheet_w
  sheet_w=$(( $(tp__display_px 2 | cut -dx -f1) / cols ))
  (( sheet_w > 200 )) || sheet_w=200
  pdftoppm -png -f 1 -l "$last" -aa yes -aaVector yes -scale-to-x "$sheet_w" -scale-to-y -1 \
    "$target" "$tmp/page" 2>/dev/null

  printf '\033[1m%s\033[0m  \033[2m·  PDF  ·  %s pages' "$(basename "$target")" "$pages"
  [[ "$pages" != "?" ]] && (( pages > last )) && printf ' (showing first %s)' "$last"
  printf '\033[0m\n'

  # shellcheck disable=SC2012
  local -a files; while IFS= read -r f; do files+=("$f"); done < <(ls "$tmp"/page*.png 2>/dev/null | sort)
  if (( ${#files[@]} == 0 )); then rm -rf "$tmp"; echo "termpeek: no pages rendered" >&2; return 1; fi

  # Give timg explicit columns AND rows. `--grid=N` alone means an NxN grid,
  # which reserves far more vertical space than a handful of pages needs.
  local rows=$(( (${#files[@]} + cols - 1) / cols ))
  (( rows < 1 )) && rows=1

  if tp__use_chafa && tp_is_pixel_protocol "$proto"; then
    if tp__montage "$tmp/sheet.png" "$cols" "${files[@]}"; then
      tp_render_image "$tmp/sheet.png" "$proto"
      local rc=$?; rm -rf "$tmp"; return $rc
    fi
  fi

  timg -p "$(tp__timg_pixelation "$proto")" --grid="${cols}x${rows}" -g "$TP_GEOMETRY" \
    --title='%b' "${files[@]}"
  local rc=$?
  rm -rf "$tmp"
  return $rc
}

tp_render_file() {
  local target="$1"
  if command -v bat >/dev/null 2>&1; then
    bat --color=always --style=numbers,grid --paging=never "$target"
  else
    cat "$target"
  fi
}

# Diffs go through delta with side-by-side + line numbers + syntax highlighting.
# Plain `delta < file` produces a unified list that reads no better than the raw
# patch; the side-by-side view with language-aware highlighting is the thing
# that actually makes a code change scannable.
#
# Side-by-side needs horizontal room. Below ~140 columns the two panes get too
# narrow to read, so we fall back to unified rather than shipping shredded text.
tp__delta_args() {
  local cols="${TERMPEEK_COLUMNS:-0}"
  if [[ "$cols" == "0" ]]; then
    cols="$(printf '%s' "$TP_GEOMETRY" | cut -dx -f1)"
  fi
  printf -- '--paging=never --line-numbers --syntax-theme=%s' \
    "${TERMPEEK_SYNTAX_THEME:-Dracula}"
  if (( cols >= ${TERMPEEK_SIDE_BY_SIDE_MIN:-140} )); then
    printf -- ' --side-by-side'
  fi
}

tp_render_diff() {
  local target="$1"
  if command -v delta >/dev/null 2>&1; then
    # shellcheck disable=SC2046  # word splitting is intentional here
    delta $(tp__delta_args) < "$target"
  elif command -v bat >/dev/null 2>&1; then
    bat --color=always --language=diff --paging=never "$target"
  else
    cat "$target"
  fi
}

# Live diff of a working tree, which is the common case inside an agent session:
# "show me what you just changed". Accepts optional pathspec / revision args.
tp_render_git_diff() {
  command -v git >/dev/null 2>&1 || { echo "termpeek: git not found" >&2; return 127; }
  local tmp; tmp="$(mktemp "${TMPDIR:-/tmp}/termpeek-gitdiff.XXXXXX")" || return 1
  if ! git diff "$@" > "$tmp" 2>/dev/null; then
    rm -f "$tmp"; echo "termpeek: git diff failed" >&2; return 1
  fi
  if [[ ! -s "$tmp" ]]; then
    # Nothing unstaged — fall back to staged changes before declaring it clean.
    git diff --cached "$@" > "$tmp" 2>/dev/null
  fi
  if [[ ! -s "$tmp" ]]; then
    rm -f "$tmp"; echo "termpeek: no changes to show"; return 0
  fi
  tp_render_diff "$tmp"
  local rc=$?
  rm -f "$tmp"
  return $rc
}

# Tweet cards render to PNG first, then reuse the image path. The fetch+card
# renderer lives in scripts/tweet-card (bun/satori); see references/tweets.md.
tp_render_tweet() {
  local url="$1" proto="${2:-$(tp_detect_protocol)}"
  local card
  card="$("$TERMPEEK_LIB/../scripts/tweet-card" "$url")" || return $?
  tp_render_image "$card" "$proto"
}

# --- multiple items ---------------------------------------------------------
# Reduce any previewable target to a single image file, so several unrelated
# things — a screenshot, a PDF page, a post — can share one gallery or carousel.
# Prints the path, or nothing if the type has no still representation.
tp_resolve_to_image() {
  local target="$1" out
  local kind; kind="$(tp_detect_type "$target")"
  local dir="${TERMPEEK_ITEM_DIR:-${TMPDIR:-/tmp}}"

  case "$kind" in
    image) printf '%s' "$target"; return 0 ;;
    pdf)
      out="$(mktemp "$dir/tp-item.XXXXXX")" && rm -f "$out"
      if pdftoppm -png -f "${TERMPEEK_PDF_PAGE:-1}" -l "${TERMPEEK_PDF_PAGE:-1}" \
           -aa yes -aaVector yes -scale-to-x 900 -scale-to-y -1 "$target" "$out" 2>/dev/null; then
        printf '%s' "$(find "$(dirname "$out")" -name "$(basename "$out")-*.png" -print -quit)"
        return 0
      fi
      return 1 ;;
    video)
      # A still frame stands in for the clip; a grid cannot animate anyway.
      out="$(mktemp "$dir/tp-item.XXXXXX").png"
      command -v ffmpeg >/dev/null 2>&1 || return 1
      ffmpeg -y -i "$target" -frames:v 1 -vf "select=eq(n\,0)" "$out" >/dev/null 2>&1 \
        && { printf '%s' "$out"; return 0; }
      return 1 ;;
    tweet)
      # timg labels each cell with the filename, so name the card after the post
      # rather than leaving it as the mktemp gibberish the user never chose.
      local handle id label
      handle="$(printf '%s' "$target" | sed -E 's#https?://(x|twitter)\.com/([^/]+)/status.*#\2#')"
      id="$(printf '%s' "$target" | sed -E 's#.*status(es)?/([0-9]+).*#\2#')"
      label="$(printf '%s' "@${handle}-${id}" | tr -cd '[:alnum:]@._-')"

      local card; card="$("$TERMPEEK_LIB/../scripts/tweet-card" "$target")" || return 1
      # timg reads bitmaps, not SVG, so rasterize when we can.
      if command -v rsvg-convert >/dev/null 2>&1; then
        out="$(dirname "$card")/${label}.png"
        rsvg-convert -w "${TERMPEEK_CARD_WIDTH:-900}" -o "$out" "$card" 2>/dev/null \
          && { rm -f "$card"; printf '%s' "$out"; return 0; }
      fi
      out="$(dirname "$card")/${label}.svg"
      mv -f "$card" "$out" 2>/dev/null && { printf '%s' "$out"; return 0; }
      printf '%s' "$card"; return 0 ;;
    *) return 1 ;;
  esac
}

# Gallery: every item on screen at once, tiled.
tp_render_gallery() {
  local proto="${TERMPEEK_PROTOCOL:-$(tp_detect_protocol)}"
  if ! tp__use_chafa; then
    command -v timg >/dev/null 2>&1 || { echo "termpeek: timg required for a gallery" >&2; return 127; }
  fi
  local -a files=()
  local t img
  for t in "$@"; do
    if img="$(tp_resolve_to_image "$t")" && [[ -n "$img" ]]; then
      files+=("$img")
    else
      echo "termpeek: skipping (no still preview): $t" >&2
    fi
  done
  (( ${#files[@]} )) || { echo "termpeek: nothing to show" >&2; return 66; }

  local cols="${TERMPEEK_COLS:-${#files[@]}}"
  (( cols > 4 )) && cols=4
  local rows=$(( (${#files[@]} + cols - 1) / cols ))

  if tp__use_chafa && tp_is_pixel_protocol "$proto"; then
    local tmp; tmp="$(mktemp -d "${TMPDIR:-/tmp}/termpeek-gal.XXXXXX")" || return 1
    if tp__montage "$tmp/grid.png" "$cols" "${files[@]}"; then
      tp_render_image "$tmp/grid.png" "$proto"
      local rc=$?; rm -rf "$tmp"; return $rc
    fi
    rm -rf "$tmp"
  fi

  timg -p "$(tp__timg_pixelation "$proto")" --grid="${cols}x${rows}" -g "$TP_GEOMETRY" \
    --title='%b' "${files[@]}"
}

# Carousel: one at a time, advancing on a timer. timg's -w is the wait between
# images and --loops controls how many times it cycles.
tp_render_carousel() {
  local proto="${TERMPEEK_PROTOCOL:-$(tp_detect_protocol)}"
  local wait="${TERMPEEK_CAROUSEL_WAIT:-3}"
  local loops="${TERMPEEK_LOOPS:-1}"
  local -a files=()
  local t img
  for t in "$@"; do
    if img="$(tp_resolve_to_image "$t")" && [[ -n "$img" ]]; then
      files+=("$img")
    else
      echo "termpeek: skipping (no still preview): $t" >&2
    fi
  done
  (( ${#files[@]} )) || { echo "termpeek: nothing to show" >&2; return 66; }

  if command -v timg >/dev/null 2>&1; then
    timg -p "$(tp__timg_pixelation "$proto")" -g "$TP_GEOMETRY" \
      -w "$wait" --loops="$loops" --title='%b' --clear=every "${files[@]}"
    return $?
  fi

  # A carousel is sequential, so unlike a gallery it does not need timg's
  # tiling. chafa alone can do it, which keeps this working on systems where
  # timg is not packaged (Linux distributions generally do not carry it).
  local n=1 f
  while (( n <= loops )) || (( loops < 0 )); do
    for f in "${files[@]}"; do
      printf '\033[2J\033[H'
      printf '\033[2m%s\033[0m\n' "$(basename "$f")"
      tp_render_image "$f" "$proto" || return $?
      sleep "$wait"
    done
    (( loops < 0 )) || n=$(( n + 1 ))
  done
}

# --- dispatch ---------------------------------------------------------------
tp_render() {
  local target="$1" proto="${2:-$(tp_detect_protocol)}"
  local kind; kind="$(tp_detect_type "$target")"

  case "$kind" in
    image) tp_render_image "$target" "$proto" ;;
    video) tp_render_video "$target" "$proto" ;;
    pdf)   tp_render_pdf   "$target" "$proto" ;;
    diff)  tp_render_diff  "$target" ;;
    file)  tp_render_file  "$target" ;;
    tweet) tp_render_tweet "$target" "$proto" ;;
    missing)
      echo "termpeek: no such file: $target" >&2; return 66 ;;
    *)
      echo "termpeek: unhandled type: $kind" >&2; return 65 ;;
  esac
}
