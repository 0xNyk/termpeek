# termpeek

Preview images, video, PDFs, code and diffs from inside an AI coding CLI that
can't show them to you.

Claude Code, Codex, Gemini CLI and Hermes all run a full-screen TUI that owns
the terminal. When a tool writes an image, you get `Read image (42 KB)`. The
agent can see it. You can't.

termpeek doesn't fight the TUI. It renders where the TUI never repaints.

```bash
termpeek screenshot.png      # image, full pixels
termpeek clip.mp4            # video, actual motion
termpeek report.pdf          # rendered page, not a filename
termpeek --diff              # what changed, side by side
```

## Why this is needed

Terminal graphics protocols have existed for years. The blocker isn't the
terminal, it's the agent's TUI sitting between your renderer and the screen.

Measured from inside a Claude Code tool call:

| Approach | Result |
|---|---|
| Model emits escape sequences | sanitized before display |
| Subprocess writes to stdout | captured as text |
| Write to `/dev/tty` | `device not configured` |
| Write to the PTY directly | overwritten on next repaint |

Only one agent CLI renders media natively today: **Grok Build**, which added
Kitty graphics in v0.1.212 (June 2026). Claude Code has six open or duplicated
issues requesting it. Codex has one. termpeek covers the rest, and adds video,
PDFs and diffs on top.

## Install

```bash
git clone https://github.com/0xNyk/termpeek
cd termpeek && ./install.sh
```

Renderers (Homebrew shown; all are widely packaged):

```bash
brew install chafa timg      # images and video (timg pulls in poppler for PDFs)
brew install bat git-delta   # code and diffs
brew install tmux            # optional, gives the best transport
```

## Usage

```bash
termpeek <file|url>            # detect type, pick transport, show it
termpeek --diff                # working-tree diff
termpeek --diff HEAD~3         # any git diff arguments
termpeek --pages doc.pdf       # contact sheet of every page
termpeek --probe               # what your terminal actually supports
```

| Flag | Meaning | Default |
|---|---|---|
| `-g, --geometry <WxH>` | size in character cells | `80x40` |
| `-p, --protocol` | `kitty` \| `iterm` \| `sixel` \| `symbols` | detected |
| `-t, --transport` | `tmux` \| `window` \| `inline` | detected |
| `--page <n>` | PDF page | `1` |
| `--pages` | PDF contact sheet | off |
| `--dpi <n>` | PDF DPI (overrides exact-pixel sizing) | auto |
| `--loops <n>` | video loops, `-1` for forever | `1` |
| `--here` | write to stdout, skip the transport | off |

## What it renders

| Type | Renderer | Notes |
|---|---|---|
| Images | chafa | PNG, JPG, GIF, WebP, SVG, AVIF, JXL, TIFF, QOI |
| Video | timg | full-pixel Kitty graphics, compressed |
| PDF | pdftoppm → chafa | rasterized at exact display size, framed as a page |
| Diffs | delta | syntax highlighted, side-by-side when wide enough |
| Code | bat | syntax highlighting and line numbers |

## Transports

Chosen automatically; override with `-t`.

**tmux** — a sidebar pane next to the agent. Previews reuse one pane, so the
layout stays put no matter how many you open. Best experience.

**window** — a separate terminal window. Always works, costs a focus change.
This is the default when you're not in tmux.

**inline** — straight to stdout, for running termpeek by hand.

To make the sidebar the default, launch your agent through the wrapper:

```bash
tp-session            # claude, inside tmux, sidebar ready
tp-session codex      # or any other agent CLI
```

It records your terminal's graphics protocol before tmux rewrites `TERM`, and
enables `allow-passthrough` — without which tmux eats the escape sequences that
carry Kitty graphics.

## Two traps worth knowing

Both cost real debugging time. They're encoded in the code; don't undo them.

**Renderers lie when stdout isn't a terminal.** chafa and timg both downgrade to
character art rather than failing. timg is worse: with no answer to its pixel
size query it renders a *single frame* of a video, exits `0`, and mentions it
only on stderr. Same clip, same flags: piped gave 1 frame, a real terminal gave
75 at 15.1fps. So termpeek probes once and always passes an explicit protocol.

**A frozen frame is worse than coarse pixels.** When stdout genuinely isn't a
terminal, video falls back to block rendering on purpose. Moving and coarse
beats sharp and stuck.

## Supported agents

| CLI | How | Status |
|---|---|---|
| Claude Code | skill (`SKILL.md`) | verified end to end |
| Codex | shell + a note in `AGENTS.md` | expected to work, untested |
| Hermes Agent | shell hook or Python plugin | expected to work, untested |
| Gemini CLI | shell | expected to work, untested |
| Grok Build | renders images natively; termpeek adds PDFs and diffs | untested |

Only Claude Code has been verified end to end so far. The rest share the same
constraint termpeek is built around — a TUI that captures stdout — so they
should work, but reports are welcome. If your agent can run a shell command, it
can use termpeek.

## Requirements

macOS or Linux. `bash` 3.2 is enough (macOS ships it). `ffmpeg` is used for PDF
page framing. Everything else degrades: with no graphics protocol you get
Unicode block art, which works in any terminal.

## Testing

```bash
./tests/run.sh
```

The suite checks renderer selection and escape-sequence structure, including a
regression guard against the frozen-video bug. Whether pixels *look* right needs
a human at a real terminal; that part can't be asserted from inside an agent.

## License

MIT
