# Contributing to termpeek

Contributions are welcome. Keep changes reviewable and attach evidence that
matches their risk.

## Getting started

1. Fork and clone the repo
2. Install the renderers: `brew install chafa timg bat git-delta tmux`
3. Run `./tests/run.sh` to confirm a clean baseline
4. Run `./scripts/termpeek --probe` to see what your terminal supports

## Ground rules for this codebase

**Target bash 3.2.** macOS still ships it. Notably, expanding an empty array
under `set -u` is fatal there, so guard with `${arr[@]+"${arr[@]}"}`.

**Never trust renderer auto-detection.** chafa and timg silently downgrade when
they cannot query the terminal. Probe once, then pass an explicit protocol flag.
Several comments in `lib/` explain specific instances; please don't remove them.

**Prefer degrading over failing.** If a protocol isn't available, render
something. Unicode block art works in every terminal.

## Testing

```bash
./tests/run.sh
```

The suite asserts renderer selection and escape-sequence structure. It cannot
assert that output *looks* right — that needs a human at a real terminal. If
your change affects appearance, say what you looked at and in which terminal.

Adding a regression test for a bug you fixed is the most useful thing you can
do here. Every check in the suite exists because something broke.

## Assets and demos are generated, never screenshotted

Every image in the README is built from real command output by a committed
script — `tools/ansi2svg.py` for terminal output, `tools/make-banner.sh` for the
banner, `tools/make-demo-video.sh` for the clip, `tools/make-demo-assets.sh` for
the demo project's media, `tools/make-readme-assets.sh` for images that show
composed output. The tmux sidebar shot is a genuine `tmux capture-pane`.

```bash
./scripts/termpeek --here --diff | tools/ansi2svg.py --title "termpeek --diff" -o out.svg
```

Two reasons, and the second is the serious one:

1. A screenshot is a bitmap nobody can diff or regenerate. When behaviour
   changes, generated assets rebuild; screenshots quietly go stale and start
   advertising something the tool no longer does.
2. Capturing a terminal captures whatever else is on screen. That is not
   hypothetical — it happened while building this README, and the capture held
   unrelated work that had no business being published.

If you add an image, add the script that produces it.

## Documentation

Behaviour changes need the docs changed in the same PR. This project has
already shipped a README that stated the inverse of what the code did — it said
images could not render in a tmux pane, months after they could. Documentation
that is confidently wrong is worse than none.

Deep material lives in `docs/`; keep the README scannable and link out.

## Pull requests

- One concern per PR
- Say which terminal and multiplexer you tested in
- Note new external dependencies and why they're needed
- Shell changes should pass `shellcheck` where practical
