# Caching

Expensive work is cached; cheap work is not.

| Path | Cold | Warm |
|---|---|---|
| X post card | 1441 ms | 186 ms |
| PDF page | 476 ms | 119 ms |
| image | ~90 ms | not cached |
| diff | ~100 ms | not cached |

Those are measured, not estimated. A cache that saves 90 ms is not worth the
risk of showing you something stale, so images and diffs go straight through.

## Invalidation

Invalidation differs by input, because the inputs do.

**Local files** are keyed on path, size and mtime. Editing a PDF changes the
key, so there is no TTL and no way to be served a stale page.

**Remote data** is keyed on the post id with a TTL, since there is nothing local
to compare against. Post records expire after 15 minutes — the text never
changes but the counts do. Avatars last a week.

## Commands

```bash
termpeek --cache          # what is cached
termpeek --clear-cache    # empty it
termpeek --no-cache FILE  # re-render this once
```

`TERMPEEK_CACHE_DISABLE=1` turns it off entirely. `TERMPEEK_CACHE` sets the
location (default `${XDG_CACHE_HOME:-~/.cache}/termpeek`).
