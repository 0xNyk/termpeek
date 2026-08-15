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

## Pull requests

- One concern per PR
- Say which terminal and multiplexer you tested in
- Note new external dependencies and why they're needed
- Shell changes should pass `shellcheck` where practical
