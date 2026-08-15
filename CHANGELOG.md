# Changelog

All notable changes to termpeek are recorded here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning follows
[SemVer](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Video previews render as a sampled filmstrip by default; `TERMPEEK_ANIMATE=1`
  plays the clip instead. A still persists in the pane, an animation does not.
- Tiled views (galleries, PDF contact sheets) choose their own layout: a narrow
  sidebar stacks tiles, a wide pane spreads them. Pin with `--cols`.
- `tools/make-banner.sh` and `tools/make-demo-assets.sh` — the README banner and
  the demo clip are generated from source like every other image here.
- `CODE_OF_CONDUCT.md`, issue forms and a pull request template.
- `TERMPEEK_MAX_PAYLOAD` safety valve for tmux discarding a large transmission.

### Changed

- Inside tmux every path now renders through chafa, including video and tiled
  views. chafa is the only renderer whose transmission survives the multiplexer.
- PDFs rasterise at 2x the painted box and downscale, so the downscale does the
  anti-aliasing. Small type is legible where it used to be soft.
- The demo clip is 1280x720 instead of a 240x136 test fixture. timg will not
  enlarge a source past its native size, so the old asset drew 15x5 cells.
- README documents the tmux behaviour that actually ships; it previously said
  images could not render in a pane, which stopped being true.

### Fixed

- Images no longer disappear inside tmux — and they now stay in the sidebar.
  tmux keeps no graphics in its screen buffer, only the placeholder glyphs, so
  whether a picture survives depends on how the renderer transmits it. An
  earlier fix read that as "pixels can never go in a pane" and routed them to a
  separate window; the narrower and correct fix is to render with chafa, whose
  transmission reaches the terminal intact where timg's does not (1.69 MB vs
  3.6 KB for the same image, measured in a live pane).
- Previews no longer scroll themselves off the pane. A render sized to the full
  pane with header text above it pushed the pane down by one line, and that
  scroll is a redraw, which erases every kitty image in it. Text printed ahead
  of a render now shrinks it. A full-pane PDF that drew its header and no page
  was exactly this.
- Galleries no longer fail silently on SVG input. ffmpeg cannot decode SVG, so
  composing X post cards failed outright and fell back to a renderer that shows
  nothing inside tmux.

### Added

- A demo video, built by `tools/make-demo-video.sh` from real command output,
  and `tools/record-session.sh`, which records an actual tmux session by
  sampling its panes rather than recording the screen.

### Changed

- Codex and Hermes are now verified rather than assumed: Codex calls `preview`
  through MCP and the window opens, and `hermes mcp test` connects and lists all
  four tools. The README status table reflects what was actually run.

## [0.2.0] — 2026-08-15

### Added

- X/Twitter post preview. `termpeek <post-url>` renders the post as a card:
  avatar, verified badge, wrapped text, timestamp and counts.
- Three fetch backends, tried in order — the no-auth syndication endpoint, the
  X API v2 via `xint`, and cookie auth for posts the others cannot reach. Pin
  one with `TERMPEEK_X_BACKEND`; all three normalize to a single record shape so
  the renderer only knows one schema.
- A cache for the two paths that measurably cost something: X post cards
  (1441 ms -> 186 ms) and PDF pages (476 ms -> 119 ms). Images and diffs are
  left alone at ~90 ms; caching those would risk staleness to save nothing.
  Local files are keyed on path, size and mtime, so an edit invalidates the
  entry and no TTL is needed. Remote records expire after 15 minutes and
  avatars after a week. `--cache`, `--clear-cache` and `--no-cache` expose it.
- An MCP server (`scripts/termpeek-mcp`) exposing `preview`, `preview_many`,
  `preview_diff` and `probe`. One adapter covers every MCP-speaking agent
  instead of a bespoke integration each. Unlike image-oriented MCP servers it
  returns text to the model and renders to the user's terminal — the model
  already has a way to read an image; it has no way to show you one.
- A Linux window transport. Previously `tp_detect_transport` returned `window`
  only on macOS, so a Linux user without tmux got `none` and termpeek could not
  work at all — while the README claimed Linux support. It now spawns
  `$TERMINAL` or the first installed emulator, each invoked the way that
  emulator documents, and reports `none` when there is no display rather than
  spawning something nobody will see.
- A Claude Code `PostToolUse` hook that previews images, PDFs and video as the
  agent writes them. Never blocks (every path exits 0, preview runs detached),
  skips code and diffs, and suppresses repeats of the same file.
- `--gallery` and `--carousel` for previewing several items together. Passing
  more than one target implies a gallery. Mixed types work: images, PDF pages,
  video stills and X posts reduce to a common still form first.
- `tools/ansi2svg.py`, which renders real terminal output to SVG. The README
  demos are generated from actual command output rather than screenshotted.
- Diagrams in the README, generated from committed SVG via `rsvg-convert`.

### Notes

- The card is authored as SVG and handed to chafa, which rasterizes SVG through
  librsvg. No headless browser and no JavaScript toolchain in this path.
- The syndication token is derived from the post id in `awk`, so tweet preview
  adds no scripting-language dependency.
- Cookie credentials are read from a file into a request header. They are never
  echoed, logged, or placed on a command line where the process list would
  expose them; termpeek warns if the file is group- or world-readable.
- Avatars are a circle filled from an SVG `<pattern>`, not an `<image>` with a
  `clip-path` — librsvg ignores the clip and renders a square.
- Contact sheets label cells with `%b`. timg has no page-number format
  specifier — `%f %b %w %h %D` is the whole set — so an invented `%02n` printed
  literally. Page numbers now live in the filename.
- A carousel works without timg, falling back to chafa, since stepping through
  items sequentially needs no tiling. Galleries still require timg, which most
  Linux distributions do not package.
- `--grid` is given explicit columns AND rows; `--grid=N` alone means an NxN
  grid and reserves far more vertical space than a few pages need.

## [0.1.0] — 2026-08-15

First release.

### Added

- `termpeek` CLI: images, video, PDFs, code files and diffs, with type detection
  by extension and by content for extensionless diffs
- Capability probe with an explicit fallback chain: Kitty → iTerm2 → sixel →
  Unicode blocks
- Three transports — tmux sidebar, separate OS window, and inline — selected
  automatically
- `tp-session`, which launches any agent CLI inside tmux so the sidebar is the
  default, recording the host graphics protocol before tmux rewrites `TERM`
- PDF rendering at exact display pixel size with antialiasing, page framing and
  a page counter, plus `--pages` for a contact sheet
- Side-by-side diffs via delta, falling back to unified below 140 columns
- Claude Code skill definition (`SKILL.md`)
- Test suite covering type detection, protocol selection, renderer output shape
  and CLI argument handling

### Notes

Behaviour worth knowing, each the result of a real bug:

- Renderers are always given an explicit protocol. chafa and timg both downgrade
  silently when they cannot query the terminal.
- Video falls back to block rendering when stdout is not a terminal. Under Kitty
  graphics without a pixel-size answer, timg renders one frame and exits `0` —
  measured at 1 frame piped versus 75 in a real terminal.
- The tmux sidebar pane is held open deliberately. A pane whose command exits is
  closed immediately, which made previews flash and vanish.
- tmux `allow-passthrough` is enabled by the tmux transport; without it the
  multiplexer discards the escape sequences carrying Kitty graphics.
- Empty arrays are expanded as `${arr[@]+"${arr[@]}"}` throughout, because bash
  3.2 on macOS treats the bare form as an unbound variable under `set -u`.

[Unreleased]: https://github.com/0xNyk/termpeek/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/0xNyk/termpeek/releases/tag/v0.2.0
[0.1.0]: https://github.com/0xNyk/termpeek/releases/tag/v0.1.0
