# How it works

Why the problem exists, how termpeek gets around it, and the four constraints
that shaped the implementation. If you are changing rendering code, read the
traps at the bottom first — every one of them cost real debugging time and is
encoded in the source.

## The problem

Terminal graphics protocols have existed for years. The blocker isn't the
terminal, it's the agent's TUI sitting between your renderer and the screen.

Claude Code, Codex, Gemini CLI and Hermes all run a full-screen TUI that owns
the terminal. Measured from inside a Claude Code tool call:

| Approach | Result |
|---|---|
| Model emits escape sequences | sanitized before display |
| Subprocess writes to stdout | captured as text |
| Write to `/dev/tty` | `device not configured` |
| Write to the PTY directly | overwritten on next repaint |

![Without termpeek the agent TUI captures stdout, strips escapes and repaints over the PTY, so you see a filename. With termpeek the render happens outside the TUI, in a tmux sidebar or separate window.](../assets/readme/how-it-works.png)

So termpeek does not render *into* the agent's TUI. It renders somewhere the
TUI never repaints.

Only one agent CLI renders media natively today: **Grok Build**, which added
Kitty graphics in v0.1.212 (June 2026). Claude Code has six open or duplicated
issues requesting it. Codex has one.

## Transports

![Three transports: a tmux sidebar pane beside the agent, a separate OS window, or inline to stdout.](../assets/readme/transports.png)

Chosen automatically; override with `-t` or `TERMPEEK_TRANSPORT`.

### tmux — the sidebar

A pane next to the agent. Previews reuse one pane, so the layout stays put no
matter how many you open. Images, video, PDFs and cards all render here.

This requires `allow-passthrough`, which `tp-session` turns on for you. Without
it tmux swallows the escape sequences that carry Kitty graphics and you see
nothing at all.

### window — a separate OS window

Always works, costs a focus change. This is the default when you're not in tmux.

On Linux this spawns your terminal emulator — `$TERMINAL` if you set one,
otherwise the first of kitty, wezterm, ghostty, foot, konsole, alacritty,
gnome-terminal, xterm that is installed, each invoked the way that emulator
documents. With no display server attached there is nowhere to put a window, so
the transport reports `none` rather than spawning something you will never see.
Use tmux there.

### inline — straight to stdout

For running termpeek by hand outside an agent, or piping its output somewhere.

## Four traps worth knowing

These are the constraints the implementation is built around. They are encoded
in the code with comments; please don't undo them.

### 1. Renderers lie when stdout isn't a terminal

chafa and timg both downgrade to character art rather than failing. timg is
worse: with no answer to its pixel-size query it renders a *single frame* of a
video, exits `0`, and mentions it only on stderr.

Same clip, same flags: piped gave 1 frame, a real terminal gave 75 at 15.1fps.

![Same clip and flags: kitty piped renders 1 frame, kitty on a real tty renders 75, quarter blocks render 74.](../assets/readme/protocol-frames.png)

So termpeek probes once, caches the result, and always passes an explicit
protocol flag. It never lets a renderer decide. See `lib/probe.sh`.

### 2. tmux stores no graphics, only placeholders

`allow-passthrough` forwards the bytes once. What tmux keeps in its screen
buffer is the placeholder glyphs, not the picture. So the renderer's
transmission strategy decides whether anything appears — and only chafa's holds
up. Measured in a live pane, chafa emitted 1.69 MB for a test image where timg
emitted 3.6 KB.

That is why every path inside tmux goes through chafa, and why anything that
would otherwise be tiled or animated is composed into a single image first. See
`tp__use_chafa` and `tp__montage` in `lib/render.sh`.

timg also refuses to enlarge a source past its native size, so a 240x136 clip
drew 15x5 cells in a 70x30 pane — which reads as "the video did not show".

### 3. Anything printed after an image erases it

A redraw does not re-send graphics, and a scroll is a redraw. Text printed
*before* a render therefore has to shrink that render, or its last row pushes
the pane down by one and the picture vanishes. A full-pane PDF that drew its
header and nothing else was exactly this.

See `tp__say` and `tp__fit_geometry` in `lib/render.sh`.

### 4. A file being written renders as a truncated image, silently

Measured: a PNG cut to 40 KB produced 648 KB of escape output, exit 0, empty
stderr. Nothing distinguishes it from a good render except the picture.

Reported by [@buskerrrrrr](https://x.com/buskerrrrrr): firing on create rather
than on close catches half-written PNGs, and a browser capture gives no
`.crdownload` marker to wait for, so a settled size is the only general signal.

`tp__wait_stable` in `lib/render.sh` polls size and mtime until they hold still,
but only for files touched in the last couple of seconds, so settled files cost
nothing. It degrades to rendering rather than blocking.

## Why video is a filmstrip by default

Animation redraws each frame in place, and what remains after the player exits
does not survive a pane redraw — it leaves a correctly-sized but empty box. A
still persists exactly like an image preview does.

A strip also reads better in a sidebar than four seconds of motion you have to
be looking at to catch. `TERMPEEK_ANIMATE=1` plays the clip instead.

## What can and cannot be tested

The suite asserts renderer selection and escape-sequence structure — which is
where the bugs in this project actually were. Whether pixels *look* right needs
a human at a real terminal, and pretending otherwise is how several of these
bugs survived a green test run.
