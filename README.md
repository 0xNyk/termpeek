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

![Without termpeek the agent TUI captures stdout, strips escapes and repaints over the PTY, so you see a filename. With termpeek the render happens outside the TUI, in a tmux sidebar or separate window.](assets/readme/how-it-works.png)

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

## What a session looks like

You keep talking to the agent. Previews appear beside it and stay there.

```console
$ tp-session                       # claude, in tmux, sidebar ready

  ┌ claude ─────────────────────┐ ┌ termpeek ──────────┐
  │ > plot the latency data     │ │                    │
  │                             │ │   [ the chart,     │
  │ Wrote chart.png             │ │     in pixels ]    │
  │ ⏵ termpeek chart.png        │ │                    │
  │                             │ │                    │
  │ > now show me the diff      │ │                    │
  │ ⏵ termpeek --diff           │ │   [ side-by-side   │
  │                             │ │     diff ]         │
  └─────────────────────────────┘ └────────────────────┘
```

The sidebar is one pane, reused. Ten previews later the layout is unchanged.

## Transports

![Three transports: a tmux sidebar pane beside the agent, a separate OS window, or inline to stdout.](assets/readme/transports.png)

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

![Same clip and flags: kitty piped renders 1 frame, kitty on a real tty renders 75, quarter blocks render 74.](assets/readme/protocol-frames.png)

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

## How this differs from what already exists

There are good pieces in this space. None of them cover the whole problem.

| | Covers | Gap termpeek fills |
|---|---|---|
| chafa / timg / viu | rendering | no way past the agent's TUI; auto-detection downgrades silently |
| Existing Claude Code image skills | images, Claude only | no video, PDFs or diffs; single-agent |
| MCP image servers | the *model* sees the image | you still don't; different problem, both useful |
| cterm, cmux, Warp | replacing your terminal | termpeek works with the terminal you already use |
| Grok Build's native support | images, one vendor | everything else, plus PDFs and diffs |

## Questions

**Does it send anything anywhere?** No. Rendering is entirely local.

**What if my terminal has no graphics support?** You get Unicode block art. It
works in every terminal, including over SSH and inside CI logs.

**Do I have to use tmux?** No. Without it you get a separate window, which works
everywhere. tmux only buys you the sidebar.

**Will this break when Claude Code adds native image support?** Images become
redundant; video, PDFs, diffs and the other agents do not. The tool is built
around a constraint that only partly goes away.

**Why shell instead of a real language?** No runtime to install, and it targets
bash 3.2 so it runs on a stock Mac. The whole thing is under 1,100 lines.

**Does it work over SSH?** Yes, with the caveats you'd expect: Kitty graphics
pass through, and the block-art fallback always works.

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
