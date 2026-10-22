# seamless-claude

Lean Claude Code hooks for long sessions. This fork no longer contains the upstream Node plugin
(RemoteCTO/seamless-claude). Git history keeps that code.

| Path | What it does | Live copy |
| --- | --- | --- |
| `handoff/` | Handoff before `/clear`: nudge, stop, inject hooks, `/handoff` command, side note. See `handoff/README.md`. | Runs from this repo |
| `hooks/cachebeat-hook.sh` | Stop hook: keeps the prompt cache warm while a session is idle. | `~/.claude/hooks/` |
| `skills/cachebeat/` | `beat.sh` watcher that `cachebeat-hook.sh` runs, and its skill. | `~/.claude/skills/cachebeat/` |
| `hooks/compact-recover.sh` | SessionStart (compact): shows git state after compaction. | `~/.claude/hooks/` |

`~/.claude/settings.json` runs the `handoff/` hooks from this repo. The other files are copies of
the live files. If you change a live file, copy it here again.

## Test

```bash
cd handoff && bash test.sh && shellcheck -x handoff-*.sh limits.sh sidenote.sh test.sh
shellcheck ../hooks/*.sh ../skills/cachebeat/beat.sh
```
