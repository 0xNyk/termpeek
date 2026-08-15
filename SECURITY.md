# Security policy

## Supported versions

Security fixes target the current release and `main`. Older releases are not
maintained as separate support lines unless a GitHub advisory says otherwise.

## Report a vulnerability

Use [GitHub private vulnerability reporting](https://github.com/0xNyk/termpeek/security/advisories/new).
If GitHub is unavailable, email `nyk@builderz.dev` with the subject
`termpeek security report`.

Include the affected command or component, reproduction conditions, likely
impact, and any suggested mitigation. Remove personal data and unrelated local
paths from logs or screenshots.

## Threat model

termpeek takes a path or URL and hands it to a renderer, then displays the
result in a terminal you control. Things worth knowing:

- **File paths reach external binaries.** `chafa`, `timg`, `pdftoppm`, `bat` and
  `delta` parse untrusted input. A malicious image or PDF is a risk to those
  decoders, not to termpeek specifically. Keep them updated.
- **Escape sequences are written to your terminal.** Renderer output is passed
  through rather than sanitized, which is the entire point. Previewing a file
  from an untrusted source means trusting the renderer that parses it.
- **Transports spawn processes.** The tmux transport creates panes; the window
  transport launches a terminal application. Both run a generated script under
  `$TMPDIR` that is removed after use.
- **No network access.** The core renderers are local-only. Tweet preview, when
  enabled, performs an outbound fetch — that is the one exception.

termpeek does not read credentials, write outside `$TMPDIR`, or persist anything
beyond a small capability cache.
