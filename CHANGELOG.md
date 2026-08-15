# Changelog

All notable changes to termpeek are recorded here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning follows
[SemVer](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/0xNyk/termpeek/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/0xNyk/termpeek/releases/tag/v0.1.0
