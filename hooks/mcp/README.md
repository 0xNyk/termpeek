# MCP server

Any agent that speaks MCP can show you media through termpeek. Codex, Gemini
CLI and others have no plugin surface worth targeting one at a time, but they
all speak this.

## What it exposes

| Tool | Does |
|---|---|
| `preview` | show one file, PDF page, video or X post |
| `preview_many` | show several, tiled (`gallery`) or one at a time (`carousel`) |
| `preview_diff` | show a git diff, side by side |
| `probe` | report what the terminal can display |

## The distinction that matters

Other image-related MCP servers return base64 so the **model** can see a
picture. This one renders to **your terminal** and returns a short text
confirmation to the model.

They solve different problems and compose fine. The model already has a tool for
reading an image into its own context; what it cannot do is put one in front of
you.

## Install

**Claude Code**

```bash
claude mcp add termpeek -- /absolute/path/to/termpeek/scripts/termpeek-mcp
```

**Codex, Gemini CLI, and anything else with an `mcpServers` config**

```json
{
  "mcpServers": {
    "termpeek": {
      "command": "/absolute/path/to/termpeek/scripts/termpeek-mcp"
    }
  }
}
```

Absolute paths — MCP clients do not expand `~`.

## Checking it works

```bash
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{}}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  | scripts/termpeek-mcp | jq -c '.result.serverInfo // (.result.tools | map(.name))'
```

Expect the server info, then the four tool names.

If the agent calls `preview` and nothing appears, have it call `probe`. A
transport of `none` means there is nowhere to display — start tmux, or on Linux
check that a terminal emulator and a display are available.

## Notes

Speaks JSON-RPC 2.0 over stdio, newline-delimited, in bash with jq — jq is
already a dependency, so the project still needs no language runtime.

Diagnostics go to stderr on purpose. A stray byte on stdout corrupts the
protocol stream, which presents as the client hanging rather than as an error.
