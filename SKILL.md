---
name: termpeek
description: Preview images, video, PDFs, code files, diffs, and tweets from inside an agent CLI that cannot render them. Use when the user asks to see, view, preview, show, or look at a file — screenshots, generated images, charts, mockups, video clips, PDFs, or a code diff — or says "show me", "let me see it", "preview that", "what does it look like". Also use after generating or downloading an image/video/PDF so the user can actually see the result. Works in Claude Code, Codex, Hermes, Gemini CLI, and any terminal agent.
---

# termpeek

Agent CLIs run a full-screen TUI that owns the terminal. They capture subprocess
stdout as text, strip escape sequences, and repaint over anything written to the
PTY — so an image "displayed" from a tool call is invisible to the user. On
Claude Code, `/dev/tty` cannot even be opened from a tool call.

termpeek does not fight the TUI. It renders in a place the TUI never repaints:
a tmux pane, or a separate terminal window.

## When to use this

Reach for termpeek whenever the user should *see* something rather than read a
description of it:

- after writing or generating an image, chart, diagram, or screenshot
- when the user asks "show me", "what does it look like", "preview that"
- after downloading or being handed a PDF
- to show a code change visually — `termpeek --diff`
- for a tweet/X URL the user wants to look at

Do not use it for content the agent needs to *reason about*. Reading an image
into your own context is the `Read` tool's job; termpeek is for the human's eyes.
They solve different problems and are often used together.

## Usage

```bash
scripts/termpeek <file|url>          # auto-detect type, pick transport, show it
scripts/termpeek --diff              # working-tree diff, side-by-side
scripts/termpeek --diff HEAD~3       # any git diff arguments
scripts/termpeek --probe             # what this terminal supports
```

Options:

| Flag | Meaning | Default |
|---|---|---|
| `-g, --geometry <WxH>` | size in character cells | `80x40` |
| `-p, --protocol` | `kitty` \| `iterm` \| `sixel` \| `symbols` | detected |
| `-t, --transport` | `tmux` \| `window` \| `inline` | detected |
| `--page <n>` | PDF page | `1` |
| `--dpi <n>` | PDF render DPI | `150` |
| `--loops <n>` | video loops, `-1` = forever | `1` |
| `--gallery` / `--carousel` | several items tiled, or one at a time | off |
| `--no-cache` | re-render even if cached | off |
| `--here` | render to stdout, no transport | off |

## What it handles

| Type | Renderer | Notes |
|---|---|---|
| Images | `chafa` | PNG, JPG, GIF, WebP, SVG, AVIF, JXL, TIFF, QOI |
| Video | `timg` | full-pixel kitty graphics + `--compress` |
| PDF | `pdftoppm` → `chafa` | high-DPI raster, white page, border, page counter |
| Diff | `delta` | syntax highlighted, side-by-side when wide enough |
| Code/text | `bat` | syntax highlighting, line numbers |
| X posts | `scripts/tweet-card` → `chafa` | fetch, render an SVG card, display |

Several items at once: pass more than one target, or use `--gallery` to tile
them and `--carousel` to cycle. Mixed types are fine — an image, a PDF page and
a post can share one view.

For an X post, pass the URL: `scripts/termpeek https://x.com/user/status/123`.
Fetching tries the no-auth syndication endpoint first, then `xint` if it is
installed, then cookie auth if `TERMPEEK_X_COOKIE_FILE` is set. Pin one with
`TERMPEEK_X_BACKEND`.

## Transports

Picked automatically, override with `-t`:

1. **tmux** — a reused sidebar pane beside the conversation. Best experience:
   no window switch, and it persists. Requires the agent to run inside tmux.
2. **window** — a separate OS window. Always available on macOS. This is the
   default when not in tmux.
3. **inline** — straight to stdout, for when you run termpeek by hand.

## Two traps this encodes

Both cost real debugging time; do not undo them.

**Renderer auto-detection lies when stdout is not a tty.** `chafa` and `timg`
both silently downgrade to block art rather than failing. timg is worse: without
a terminal pixel-size answer it renders a *single frame* of a video, exits `0`,
and only mentions it on stderr — indistinguishable from "video is broken".
Measured on one clip: piped → 1 frame; real terminal → 75 frames at 15.1fps.
So termpeek probes once and always passes an explicit protocol flag.

**A frozen frame is worse than coarse pixels.** If stdout is genuinely not a
tty, video falls back to quarter-blocks deliberately — moving and coarse beats
sharp and stuck.

## Requirements

```bash
brew install chafa timg     # renderers (timg pulls in poppler for PDFs)
brew install bat git-delta  # code and diff rendering
```

`ffmpeg` is used for PDF page framing. `tmux` is optional but gives the best
transport.

## Verifying

```bash
tests/run.sh          # protocol/type detection, renderer output shape
scripts/termpeek --probe
```

Pixel output cannot be asserted from inside an agent CLI — the tests check that
the right renderer is selected and that it emits the expected escape structure
(e.g. kitty APC transmissions, multi-frame cursor moves). Confirming it *looks*
right needs a human looking at a real terminal.
