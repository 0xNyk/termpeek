<div align="center">

![termpeek — your agent can see the image, now you can too. Images, video, PDFs, diffs and X posts inside Claude Code, Codex and Hermes.](assets/readme/banner.png)

[![ci](https://github.com/0xNyk/termpeek/actions/workflows/ci.yml/badge.svg)](https://github.com/0xNyk/termpeek/actions/workflows/ci.yml)
[![release](https://img.shields.io/github/v/release/0xNyk/termpeek?color=3b82f6)](https://github.com/0xNyk/termpeek/releases)
[![license: MIT](https://img.shields.io/badge/license-MIT-3b82f6.svg)](LICENSE)
[![platform](https://img.shields.io/badge/platform-macOS%20%7C%20Linux-7d8590)](#requirements)
[![shell: bash 3.2](https://img.shields.io/badge/shell-bash%203.2-7d8590)](#requirements)

**Preview images, video, PDFs, code and diffs from inside an AI coding CLI that can't show them to you.**

</div>

---

Claude Code, Codex, Gemini CLI and Hermes all run a full-screen TUI that owns the
terminal. When a tool writes an image, you get `Read image (42 KB)`. The agent
can see it. You can't.

termpeek doesn't fight the TUI. It renders where the TUI never repaints.

```bash
termpeek ~/Desktop/dashboard-v3.png              # image, full pixels
termpeek out/onboarding-demo.mp4                 # video, sampled into a filmstrip
termpeek docs/2026-q3-report.pdf                 # rendered page, not a filename
termpeek https://x.com/nykdotdev/status/20       # the post, as a card
termpeek --diff HEAD~1                           # what changed, side by side
```

![termpeek previewing an image, a PDF, a diff and X posts inside a terminal](assets/video/demo.gif)

## Contents

- [Why this is needed](#why-this-is-needed)
- [Install](#install)
- [Usage](#usage)
- [What it renders](#what-it-renders)
- [X posts](#x-posts)
- [Transports](#transports)
- [Previews that open by themselves](#previews-that-open-by-themselves)
- [Any agent that speaks MCP](#any-agent-that-speaks-mcp)
- [Configuration](#configuration)
- [Caching](#caching)
- [Supported agents](#supported-agents)
- [How this differs from what already exists](#how-this-differs-from-what-already-exists)
- [Three traps worth knowing](#three-traps-worth-knowing)
- [Questions](#questions)
- [Requirements](#requirements)
- [Development](#development)

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

![Without termpeek the agent TUI captures stdout, strips escapes and repaints over the PTY, so you see a filename. With termpeek the render happens outside the TUI, in a tmux sidebar or separate window.](assets/readme/how-it-works.png)

Only one agent CLI renders media natively today: **Grok Build**, which added
Kitty graphics in v0.1.212 (June 2026). Claude Code has six open or duplicated
issues requesting it. Codex has one. termpeek covers the rest, and adds video,
PDFs and diffs on top.

## Install

```bash
git clone https://github.com/0xNyk/termpeek
cd termpeek && ./install.sh
```

There is also a bootstrap script, `get.sh`, which clones or updates the repo and
runs the installer. Fetch it, read it, then run it — it is deliberately short:

```bash
curl -fsSL https://raw.githubusercontent.com/0xNyk/termpeek/main/get.sh -o get.sh
less get.sh && sh get.sh
```

It clones a public repository and symlinks three scripts into `~/.local/bin`.
Nothing else: no sudo, no shell profile edits, no daemons. Piping an installer
straight into a shell is a habit worth not having, so it is not the headline
instruction here.

Renderers (Homebrew shown; all are widely packaged):

```bash
brew install chafa ffmpeg    # required: images, video, PDFs, tiling
brew install bat git-delta   # code and diffs
brew install poppler         # PDFs (pdftoppm)
brew install tmux            # optional, gives the sidebar
brew install timg            # optional, only used outside tmux
```

`chafa` and `ffmpeg` are the two that matter. Everything else degrades: with no
graphics protocol at all you get Unicode block art, which works in any terminal.

### Quick start

```bash
tp-session          # launch claude inside tmux with the sidebar ready
```

Then ask the agent to preview anything, or run `termpeek <file>` yourself.

## Usage

```bash
termpeek out/latency-by-region.png       # detect type, pick transport, show it
termpeek --diff                          # working-tree diff
termpeek --diff HEAD~3 -- src/           # any git diff arguments
termpeek --pages docs/2026-q3-report.pdf # contact sheet of every page
termpeek --page 4 docs/spec.pdf          # a specific page
termpeek https://x.com/nykdotdev/status/20
termpeek --gallery shot.png report.pdf   # several items at once
termpeek --carousel --wait 4 img/*.png   # one at a time
termpeek --probe                         # what your terminal actually supports
```

| Flag | Meaning | Default |
|---|---|---|
| `-g, --geometry <WxH>` | size in character cells | measured from the pane |
| `-p, --protocol` | `kitty` \| `iterm` \| `sixel` \| `symbols` | detected |
| `-t, --transport` | `tmux` \| `window` \| `inline` | detected |
| `--page <n>` | PDF page | `1` |
| `--pages` | PDF contact sheet | off |
| `--gallery` | tile several items together | off |
| `--carousel` | cycle several items, one at a time | off |
| `--cols <n>` | gallery columns | auto — whatever fits the pane best |
| `--wait <s>` | carousel delay per item | `3` |
| `--dpi <n>` | PDF DPI (overrides exact-pixel sizing) | auto |
| `--loops <n>` | video loops, `-1` for forever | `1` |
| `--here` | write to stdout, skip the transport | off |

## What it renders

| Type | Renderer | Notes |
|---|---|---|
| Images | chafa | PNG, JPG, GIF, WebP, SVG, AVIF, JXL, TIFF, QOI |
| Video | ffmpeg → chafa | sampled into a filmstrip; `TERMPEEK_ANIMATE=1` to play it |
| PDF | pdftoppm → chafa | rasterized at 2x the display size, framed as a page |
| Tiled views | ffmpeg → chafa | composed into one image, laid out to fit the pane |
| Diffs | delta | syntax highlighted, side-by-side when wide enough |
| Code | bat | syntax highlighting and line numbers |
| X posts | SVG → chafa | avatar, badge, text, counts — no API key needed |

Inside tmux everything goes through **chafa**, including video and tiled views.
That is not an aesthetic preference; see
[Three traps worth knowing](#three-traps-worth-knowing).

Every image below is generated from real command output by `tools/ansi2svg.py`,
not drawn by hand — see [Demos are reproducible](#demos-are-reproducible).

### Images

![An SVG chart rendered inside the terminal at full pixel fidelity.](assets/readme/demo-image.png)

### Video

![A frame of an animated clip rendered in the terminal.](assets/readme/demo-video.png)

By default a clip is sampled into a filmstrip — a still, which persists in the
pane the way an image preview does. Animation is opt-in:

```bash
TERMPEEK_ANIMATE=1 termpeek out/render.mp4
```

Animation redraws each frame in place, and what remains after the player exits
does not survive a pane redraw. A strip also reads better in a sidebar than four
seconds of motion you have to be looking at to catch.

### PDFs

![A PDF page rendered as paper, with a white background, border and page counter.](assets/readme/demo-pdf.png)

Rasterized at twice the pixel size the terminal will draw, then downscaled, so
the downscale itself does the anti-aliasing and small type stays legible.

`--pages` gives the whole document at once:

![Four PDF pages tiled as a contact sheet.](assets/readme/demo-pages.png)

### Diffs

![A side-by-side TypeScript diff with syntax highlighting and line numbers.](assets/readme/demo-diff.png)

### Code

![A TypeScript file with syntax highlighting and line numbers.](assets/readme/demo-code.png)

### Several things at once

Pass more than one target and they are shown together — mix types freely:

```bash
termpeek --gallery a.png report.pdf https://x.com/nykdotdev/status/20
termpeek --carousel --wait 4 links/*.url     # one at a time
```

![Three X post cards tiled side by side in one terminal pane.](assets/readme/demo-gallery.png)

The layout adapts to the pane rather than assuming a row: a narrow sidebar
stacks the tiles, a wide window spreads them. Pin it with `--cols` if you
disagree.

### The sidebar

![A tmux window with an agent conversation on the left and a termpeek diff preview on the right.](assets/readme/demo-sidebar.png)

Captured from a real tmux session: the agent runs on the left, previews open on
the right and reuse that one pane.

### Capability probe

![termpeek --probe output showing detected protocol, transport and terminal.](assets/readme/demo-probe.png)

## X posts

Paste a link, see the post. No API key, no browser, no login.

```bash
termpeek https://x.com/nykdotdev/status/20
```

The card is generated as SVG and handed straight to chafa, which rasterizes SVG
natively — so this path adds no browser, no headless Chrome, and no JavaScript
toolchain.

Three ways to fetch, tried in order:

| Backend | Needs | Use when |
|---|---|---|
| `syndication` | nothing | default — the endpoint behind embedded posts |
| `xint` | an X API key | you already run [xint](https://github.com/0xNyk/xint) and want the official API |
| `cookies` | a logged-in session | posts the first two can't reach |

Pin one with `TERMPEEK_X_BACKEND=xint`.

For the cookie backend, put `auth_token` and `ct0` in a file and point at it:

```bash
chmod 600 ~/.config/termpeek/x-cookies
export TERMPEEK_X_COOKIE_FILE=~/.config/termpeek/x-cookies
```

Cookies are session credentials. termpeek reads the file straight into a request
header — never echoes it, never logs it, and never puts it on a command line
where it would appear in the process list. It warns if the file is readable by
anyone but you.

The syndication endpoint is undocumented and can change without notice. That is
the trade for needing no setup; the other two backends exist for when it does.

## Transports

![Three transports: a tmux sidebar pane beside the agent, a separate OS window, or inline to stdout.](assets/readme/transports.png)

Chosen automatically; override with `-t`.

**tmux** — a sidebar pane next to the agent. Previews reuse one pane, so the
layout stays put no matter how many you open. Images, video, PDFs and cards all
render here.

This requires `allow-passthrough`, which `tp-session` turns on for you. Without
it tmux swallows the escape sequences that carry Kitty graphics and you see
nothing at all.

**window** — a separate terminal window. Always works, costs a focus change.
This is the default when you're not in tmux.

**inline** — straight to stdout, for running termpeek by hand.

On Linux the window transport spawns your terminal emulator — `$TERMINAL` if you
set one, otherwise the first of kitty, wezterm, ghostty, foot, konsole,
alacritty, gnome-terminal, xterm that is installed. With no display server
attached there is nowhere to put a window, so the transport reports `none`
rather than spawning something you will never see; use tmux there.

To make the sidebar the default, launch your agent through the wrapper:

```bash
tp-session            # claude, inside tmux, sidebar ready
tp-session codex      # or any other agent CLI
```

It records your terminal's graphics protocol before tmux rewrites `TERM`, and
enables `allow-passthrough`.

## Previews that open by themselves

A `PostToolUse` hook previews media the moment the agent writes it, so you stop
having to ask.

```json
{ "hooks": { "PostToolUse": [ { "matcher": "Write|Edit|NotebookEdit",
  "hooks": [ { "type": "command",
    "command": "/path/to/termpeek/hooks/claude-code/auto-preview.sh" } ] } ] } }
```

Images, PDFs and video only — code and diffs are skipped, because the agent
already shows you those and a window per edit would be intolerable. Repeats of
the same file are suppressed for 20 seconds, so a render loop opens one preview
rather than forty. Set `TERMPEEK_AUTO_PREVIEW=0` to turn it off without editing
settings. Full notes in [hooks/claude-code/README.md](hooks/claude-code/README.md).

## Any agent that speaks MCP

Codex, Gemini CLI and the rest have no plugin surface worth targeting one at a
time, but they all speak MCP.

```bash
claude mcp add termpeek -- /path/to/termpeek/scripts/termpeek-mcp
```

```json
{ "mcpServers": { "termpeek": { "command": "/path/to/termpeek/scripts/termpeek-mcp" } } }
```

Four tools: `preview`, `preview_many`, `preview_diff`, `probe`.

Worth being clear about how this differs from other image-related MCP servers:
they return base64 so the **model** can see a picture. This renders to **your
terminal** and returns text to the model. The model already has a tool for
reading an image; what it cannot do is put one in front of you. Details in
[hooks/mcp/README.md](hooks/mcp/README.md).

## Configuration

Everything is an environment variable; none of them are required.

| Variable | Does | Default |
|---|---|---|
| `TERMPEEK_PROTOCOL` | force `kitty` / `iterm` / `sixel` / `symbols` | detected |
| `TERMPEEK_TRANSPORT` | force `tmux` / `window` / `inline` / `none` | detected |
| `TERMPEEK_GEOMETRY` | size in cells, e.g. `80x40` | measured from the pane |
| `TERMPEEK_ANIMATE` | `1` plays video instead of a filmstrip | `0` |
| `TERMPEEK_STRIP_FRAMES` | frames sampled for the filmstrip | `4` |
| `TERMPEEK_SUPERSAMPLE` | PDF raster multiple | `2` |
| `TERMPEEK_MAX_PAYLOAD` | bytes before a render is scaled down | `8000000` |
| `TERMPEEK_RENDERER` | `timg` to prefer timg outside tmux | chafa |
| `TERMPEEK_COLS` | pin gallery columns | auto |
| `TERMPEEK_SIDEBAR_WIDTH` | sidebar pane width | `45%` |
| `TERMPEEK_TMUX_MODE` | `sidebar` or `popup` | `sidebar` |
| `TERMPEEK_WINDOW_APP` | terminal to spawn for the window transport | platform default |
| `TERMPEEK_X_BACKEND` | `syndication` / `xint` / `cookies` | tried in order |
| `TERMPEEK_X_COOKIE_FILE` | cookie file for the cookie backend | unset |
| `TERMPEEK_AUTO_PREVIEW` | `0` disables the hook | `1` |
| `TERMPEEK_CACHE_DISABLE` | `1` bypasses the cache | `0` |

## Caching

Expensive work is cached; cheap work is not.

| Path | Cold | Warm |
|---|---|---|
| X post card | 1441 ms | 186 ms |
| PDF page | 476 ms | 119 ms |
| image | ~90 ms | not cached |
| diff | ~100 ms | not cached |

Those are measured, not estimated. A cache that saves 90 ms is not worth the
risk of showing you something stale, so images and diffs go straight through.

Invalidation differs by input, because the inputs do:

**Local files** are keyed on path, size and mtime. Editing a PDF changes the
key, so there is no TTL and no way to be served a stale page.

**Remote data** is keyed on the post id with a TTL, since there is nothing local
to compare against. Post records expire after 15 minutes — the text never
changes but the counts do. Avatars last a week. Caching the fetch also blunts
the project's flakiest dependency: an undocumented endpoint that can rate-limit
or disappear.

```bash
termpeek --cache          # what is cached
termpeek --clear-cache    # empty it
termpeek --no-cache FILE  # re-render this once
```

## Supported agents

| CLI | How | Status |
|---|---|---|
| Claude Code | skill, auto-preview hook, or MCP | verified end to end |
| Codex | MCP | verified end to end — `mcp: termpeek/preview (completed)` |
| Hermes Agent | MCP | connected, all 4 tools discovered by its own tester |
| Gemini CLI | MCP | protocol verified, not tried in the client |
| Grok Build | renders images natively; termpeek adds PDFs, diffs and posts | untested |

Claude Code and Codex have been driven end to end — Codex discovers the tools,
calls `preview`, and the window opens. Hermes connects and enumerates all four
tools via `hermes mcp test`. Gemini is protocol-verified only; I have not run it
from that client, so it is marked accordingly rather than assumed.

If your agent can run a shell command or speak MCP, it can use termpeek.

```bash
claude mcp add termpeek -- /path/to/termpeek/scripts/termpeek-mcp
codex mcp add termpeek  -- /path/to/termpeek/scripts/termpeek-mcp
hermes mcp add termpeek --command /path/to/termpeek/scripts/termpeek-mcp
```

## How this differs from what already exists

There are good pieces in this space. None of them cover the whole problem.

| | Covers | Gap termpeek fills |
|---|---|---|
| chafa / timg / viu | rendering | no way past the agent's TUI; auto-detection downgrades silently |
| Existing Claude Code image skills | images, Claude only | no video, PDFs or diffs; single-agent |
| MCP image servers | the *model* sees the image | you still don't; different problem, both useful |
| cterm, cmux, Warp | replacing your terminal | termpeek works with the terminal you already use |
| Grok Build's native support | images, one vendor | everything else, plus PDFs and diffs |

## Three traps worth knowing

All three cost real debugging time. They're encoded in the code; don't undo them.

**Renderers lie when stdout isn't a terminal.** chafa and timg both downgrade to
character art rather than failing. timg is worse: with no answer to its pixel
size query it renders a *single frame* of a video, exits `0`, and mentions it
only on stderr. Same clip, same flags: piped gave 1 frame, a real terminal gave
75 at 15.1fps. So termpeek probes once and always passes an explicit protocol.

![Same clip and flags: kitty piped renders 1 frame, kitty on a real tty renders 75, quarter blocks render 74.](assets/readme/protocol-frames.png)

**tmux stores no graphics, only placeholders.** `allow-passthrough` forwards the
bytes once; what tmux keeps in its buffer is the placeholder glyphs, not the
picture. So the renderer's transmission strategy decides whether anything
appears, and only chafa's holds up — measured in a live pane, chafa emitted
1.69 MB for a test image where timg emitted 3.6 KB. That is why every path
inside tmux goes through chafa, and why anything that would otherwise be tiled
or animated is composed into a single image first.

**Anything printed after an image erases it.** A redraw does not re-send
graphics, and a scroll is a redraw. Text printed *before* a render therefore has
to shrink that render, or its last row pushes the pane down by one and the
picture vanishes. A full-pane PDF that drew its header and nothing else was
exactly this.

## Questions

**Does it send anything anywhere?** No. Rendering is entirely local.

**What if my terminal has no graphics support?** You get Unicode block art. It
works in every terminal, including over SSH and inside CI logs.

**Do I have to use tmux?** No. Without it you get a separate window, which works
everywhere. tmux only buys you the sidebar.

**Why doesn't my video move?** By design — the default is a filmstrip, because a
still survives in the pane and an animation does not. `TERMPEEK_ANIMATE=1` plays
it.

**A large preview came up empty.** Lower `TERMPEEK_MAX_PAYLOAD`. chafa transmits
uncompressed RGBA, and tmux discards output once a pane's backlog gets large
enough.

**Will this break when Claude Code adds native image support?** Images become
redundant; video, PDFs, diffs and the other agents do not. The tool is built
around a constraint that only partly goes away.

**Why shell instead of a real language?** No runtime to install, and it targets
bash 3.2 so it runs on a stock Mac.

**Does it work over SSH?** Yes, with the caveats you'd expect: Kitty graphics
pass through, and the block-art fallback always works.

## Requirements

macOS or Linux. `bash` 3.2 is enough (macOS ships it). `chafa` and `ffmpeg` are
the two dependencies that matter — ffmpeg composes tiled views, samples video
filmstrips and frames PDF pages. `poppler` (`pdftoppm`) is needed for PDFs,
`bat` and `git-delta` for code and diffs.

On Linux you need either tmux or a terminal emulator and a display; headless
hosts get the inline path only. With no graphics protocol you get Unicode block
art, which works in any terminal.

## Development

```bash
./tests/run.sh
```

The suite checks renderer selection and escape-sequence structure, including
regression guards for every failure listed in
[Three traps worth knowing](#three-traps-worth-knowing). Whether pixels *look*
right needs a human at a real terminal; that part can't be asserted from inside
an agent, and pretending otherwise is how several of these bugs survived.

CI runs shellcheck plus the suite on both Ubuntu and macOS. macOS gets its own
job because it ships bash 3.2, where an empty array under `set -u` is fatal —
a difference that has already broken this project once.

Contributions welcome; see [CONTRIBUTING.md](CONTRIBUTING.md). Security issues:
[SECURITY.md](SECURITY.md).

### Demos are reproducible

Every image in this README is generated from real command output.
`tools/ansi2svg.py` reads the bytes a command actually writes — SGR colour,
bold, dim, inverse — and draws them as SVG. The tmux sidebar is a genuine
`tmux capture-pane`. The banner and the demo video rebuild from
`tools/make-banner.sh` and `tools/make-demo-video.sh`.

```bash
./scripts/termpeek --here --diff | tools/ansi2svg.py --title "termpeek --diff" -o out.svg
```

They are not screenshots, deliberately. Capturing a terminal captures whatever
else is on screen, and produces a bitmap nobody can diff or regenerate. That is
not hypothetical: it happened while building this README, and the capture held
unrelated work that had no business being published. Sampling a pane cannot do
that.

## License

[MIT](LICENSE)
