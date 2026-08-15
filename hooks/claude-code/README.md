# Auto-preview hook for Claude Code

Writing an image, PDF or video opens a preview by itself. Without it, seeing
what the agent just made is something you have to remember to ask for.

## Install

Add to `~/.claude/settings.json` (or a project's `.claude/settings.json`):

```json
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Write|Edit|NotebookEdit",
        "hooks": [
          {
            "type": "command",
            "command": "/absolute/path/to/termpeek/hooks/claude-code/auto-preview.sh"
          }
        ]
      }
    ]
  }
}
```

Use an absolute path — Claude Code does not resolve `~` here.

If you already have `PostToolUse` hooks, add this to the existing array rather
than replacing it.

## What triggers it

| | |
|---|---|
| Tools | `Write`, `Edit`, `NotebookEdit` |
| Types | png, jpg, jpeg, gif, webp, svg, avif, pdf, mp4, mov, webm |
| Skipped | code, diffs, text — the agent already shows you those |

## Tuning

| Variable | Meaning | Default |
|---|---|---|
| `TERMPEEK_AUTO_PREVIEW=0` | turn it off without editing settings | on |
| `TERMPEEK_HOOK_COOLDOWN` | seconds before the same file previews again | `20` |
| `TERMPEEK_BIN` | path to the termpeek executable | alongside the hook |

## Why it behaves the way it does

**It never blocks.** Previewing is a convenience, so every path exits `0` and
the preview runs detached. A slow or broken preview must not stall a tool call.

**It suppresses repeats.** A render loop that writes the same file forty times
should open one preview, not forty. The cooldown is per file path.

**It checks for a transport first.** With nowhere to display — no tmux, no
display server — it does nothing rather than spawning work nobody will see.

**It ignores code and diffs.** A window per edit would be intolerable, and the
agent already puts that text in front of you. Ask for `termpeek --diff` when you
want to see a change rendered.

## Checking it works

```bash
printf '{"tool_name":"Write","tool_input":{"file_path":"'"$PWD"'/tests/fixtures/test.png"}}' \
  | hooks/claude-code/auto-preview.sh
```

A preview should appear. If nothing happens, run `termpeek --probe` — a
transport of `none` means there is nowhere to show it.
