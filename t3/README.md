# seamless-claude for T3 Code

The handoff cycle of `../handoff/` for Claude threads in T3 Code. Two setups work with the same files:
the desktop app with the server in WSL (`~/.t3/wsl-runtime/`), and a Linux server with T3 as
`t3code.service` (`~/.t3/runtime/`), for example with the mobile client through the relay.
In tmux, the handoff hooks type `/clear`. T3 Code has no terminal. Here the T3 hooks compact the same
thread through the `t3` CLI, inject the handoff, and continue without the user.

Status: works live. Two cycles and a server restart pass with Haiku (`results/2026-10-22-e2e.md`).
Installed in `~/.claude/settings.json`. Not tested: T3 native auto compaction (`autoCompactWindow`). See PLAN.md.

## For an agent: read in this order

1. This file.
2. `PLAN.md`: rules, decision, design, phases. Continue from the first phase that is not done.
3. `FINDINGS.md`: the facts the design depends on, with the T3 version and the test that proves each.

Rules in short: change only files in `t3/`. Use only Haiku (`claude-haiku-5-5`) for live tests. Write each live result to `results/`.

## Find the `t3` CLI

The server binary is the CLI. Its folder changes with each nightly. On a Linux server
`~/.local/bin/t3` is only the launcher: use the server binary.

```bash
T3=$(readlink /proc/"$(jq .pid ~/.t3/userdata/server-runtime.json)"/exe)
"$T3" thread list --json
```

## Install and remove

```bash
t3/install.sh            # adds the T3 hooks to ~/.claude/settings.json (backup first, idempotent)
t3/install.sh --remove   # removes only the entries that point into t3/hooks/
```

The tmux hooks of `../handoff/` stay installed. Each T3 hook exits at once outside T3 Code.
For a handoff on request inside T3, the agent runs `t3/hooks/handoff-now.sh` in its Bash tool.

## Files

| Path | Role |
|---|---|
| `hooks/lib.sh` | `t3_session` (parent process is the T3 server), `t3_cli`, `t3_thread_id`. |
| `hooks/nudge.sh` | Warn/stop messages. Wraps `../handoff/handoff-nudge.sh`. |
| `hooks/stop.sh` | After the handoff: queues `/compact` and the continue prompt with `t3 thread send`. Wraps `handoff-stop.sh`. |
| `hooks/inject.sh` | `SessionStart(compact)`: loads the handoff, keeps the earlier used handoff, resets the warn/stop markers. Wraps `handoff-inject.sh`. |
| `hooks/handoff-now.sh` | Manual handoff. Wraps `handoff-nudge.sh --manual`. |
| `test.sh` | Offline tests: fake T3 server and fake CLI. |
| `tools/probe.sh`, `tools/phase1-hook.sh` | Live test hooks. Register only during a test. |

Logs: failed `t3 thread send` calls go to `~/.claude/handoffs/.state/t3-send.log`.

## After a T3 Code update, or if the handoff stops working

1. Note the new version: `jq -r .serverVersion ~/.t3/userdata/server-runtime.json`.
2. Run `t3/test.sh` (offline). If it fails, our scripts changed: fix them first.
3. Run `t3/tools/live-check.sh` (live, Haiku). It re-checks the facts in FINDINGS.md that the hooks depend on.
4. If a fact changed, update FINDINGS.md with the new version, then fix the hook that depends on it.
   The fact numbers (S, L, P, H) say which hook depends on what in PLAN.md "Design".

Most likely breaks after an update:
- The provider log name or content changes (L3): `t3_thread_id` finds nothing. The stop hook then asks the user to press compact.
- The T3 binary path layout changes (L1): `t3_session` returns false. The T3 hooks then do nothing.
- T3 starts to pass a thread id or a `T3*` variable to Claude (S8): simpler detection is possible.
- T3 starts to update `nativeId` after `/clear` (L4, R1): path C (`/clear`) becomes possible.

## Manual tools

- `tools/live-check.sh [--restart]`: starts the thread "t3 live-check" (Haiku), runs two handoff cycles and checks them. `--restart` also restarts the T3 server (other threads stop for about 20 s) and checks the context. Exit 0 = pass, 1 = a check failed, 2 = setup error.
- `tools/probe.sh`: hook that logs the event and environment to `~/.claude/handoffs/.state/t3-probe.log`. Register it only for a test, then remove it.
