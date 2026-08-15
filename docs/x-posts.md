# X post previews

Paste a link, see the post. No API key, no browser, no login.

```bash
termpeek https://x.com/nykdotdev/status/20
```

![Three X post cards stacked in a termpeek sidebar pane, each showing avatar, handle, verified badge, text and counts.](../assets/readme/demo-gallery.png)

The card is generated as SVG and handed straight to chafa, which rasterizes SVG
natively — so this path adds no browser, no headless Chrome, and no JavaScript
toolchain.

## Backends

Three ways to fetch, tried in order:

| Backend | Needs | Use when |
|---|---|---|
| `syndication` | nothing | default — the endpoint behind embedded posts |
| `xint` | an X API key | you already run [xint](https://github.com/0xNyk/xint) and want the official API |
| `cookies` | a logged-in session | posts the first two can't reach |

Pin one with `TERMPEEK_X_BACKEND=xint`.

All three normalize to a single record shape, so the renderer only ever knows
one schema.

The syndication endpoint is undocumented and can change without notice. That is
the trade for needing no setup; the other two backends exist for when it does.

## Cookie authentication

For the cookie backend, put `auth_token` and `ct0` in a file and point at it:

```bash
chmod 600 ~/.config/termpeek/x-cookies
export TERMPEEK_X_COOKIE_FILE=~/.config/termpeek/x-cookies
```

Both Netscape cookie-jar and plain `name=value` formats are accepted.

Cookies are session credentials. termpeek reads the file straight into a request
header — it never echoes it, never logs it, and never puts it on a command line
where it would appear in the process list. It warns if the file is readable by
anyone but you.

## Caching

Post records expire after 15 minutes; the text never changes but the counts do.
Avatars last a week. Caching also blunts the project's flakiest dependency: an
undocumented endpoint that can rate-limit or disappear. See
[caching](caching.md).
