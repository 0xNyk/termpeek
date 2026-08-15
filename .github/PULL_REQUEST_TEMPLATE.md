## What this changes

<!-- One or two sentences. -->

## Why

<!-- What failure or gap prompted it. If it fixes a rendering bug, say how the
     failure presented — "blank pane", "text but no image", "block art" and
     "wrong size" have had different causes in this project. -->

## Checklist

- [ ] `./tests/run.sh` passes
- [ ] `shellcheck -S warning lib/*.sh scripts/* tests/run.sh` is clean
- [ ] Rendering changes have a regression test — every bug here failed
      *silently*, by falling back rather than erroring
- [ ] README updated if behaviour or defaults changed
- [ ] Targets bash 3.2 (macOS system bash); empty arrays under `set -u` are
      expanded as `${a[@]+"${a[@]}"}`
