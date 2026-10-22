# T3 Code findings

Facts that the T3 integration depends on. Each fact names its source and the T3 Code version.
If a T3 Code update breaks the integration, re-check these facts first (README.md, "After a T3 Code update").

Version checked: T3 Code nightly `0.1.2-nightly.20261021.3499`, commit `b5a226e49c52` (2026-10-21).
The Claude adapter at that commit is identical to `main` 3b95e78.

## Source facts (from the T3 Code repository)

| # | Fact | Source |
|---|---|---|
| S1 | T3 Code runs Claude through the Claude Agent SDK. The SDK starts the WSL `claude` binary. Setting sources: `user`, `project`, `local`. | `apps/server/src/orchestration-v2/Adapters/ClaudeAdapterV2.ts`, `makeClaudeQueryOptions` |
| S2 | T3 sets no hooks and no plugins in the SDK query. User hooks come from `~/.claude/settings.json`. | same |
| S3 | The T3 setting `autoCompactWindow` goes to the SDK as `autoCompactThreshold`, only if below the model max tokens. | same, `claudeAutoCompactThreshold` |
| S4 | The compact button sends the text `/compact` as a user turn. | same, `compactThread` |
| S5 | Idle compaction runs about 2 min before the prompt cache expires, above 200K tokens. | `IdleCompaction.ts`, `packages/shared/src/claudeCompaction.ts` |
| S6 | `t3 thread start/send/list/show` talk to the running server. `send` queues a turn on a busy thread and does not interrupt. `send -` reads the message from stdin. | `apps/server/src/cli/thread.ts` |
| S7 | The CLI finds the server through `~/.t3/userdata/server-runtime.json`. | `thread.ts`, `readPersistedServerRuntimeState` |
| S8 | The Claude process gets no T3 thread id and no `T3*` variable. | `ClaudeAdapterV2.ts` |
| S9 | `ContextHandoffService` moves history between providers. It is not related to our handoff. | `ContextHandoffService.ts` |

## Local facts (WSL install)

| # | Fact | How to check |
|---|---|---|
| L1 | `t3` is not on `PATH`. The binary is `~/.t3/wsl-runtime/sha256-<hash>/t3`. The hash changes with each nightly. | `ls ~/.t3/wsl-runtime/` |
| L2 | The running server binary: `/proc/<pid>/exe`, `pid` from `~/.t3/userdata/server-runtime.json`. | `jq .pid ~/.t3/userdata/server-runtime.json` |
| L3 | Each thread logs to `~/.t3/userdata/logs/provider/events.<thread id with ':' as '-'>.log`. The log holds every Claude session id of the thread. | `rg -l <session id> ~/.t3/userdata/logs/provider/` |
| L4 | SQLite `~/.t3/userdata/statev2.sqlite`, table `orchestration_v2_projection_provider_threads`, field `payload_json.nativeThreadRef.nativeId` keeps only the first Claude session id of a thread. | `sqlite3 -readonly ...` |
| L5 | After the server is stopped, the desktop app starts a new server after about 1 min. | Resume test below |

## Live test 1 — Phase 0 probe (2026-10-22, Haiku `claude-haiku-5-5`, thread `mcp:ff47d710-bef9-4e74-95bf-13b03cf509e4`)

Method: `tools/probe.sh` registered for `SessionStart`, `UserPromptSubmit`, `PreCompact`, `Stop`. The thread was driven only with the `t3` CLI: `start`, `send "/compact"`, `send "/clear"`, one question. The probe hooks were removed after the test.

| # | Question | Result |
|---|---|---|
| P1 | Do user hooks fire in T3 Code? | Yes: `SessionStart`, `UserPromptSubmit`, `PreCompact`, `Stop`. |
| P2 | `SessionStart` source `compact`? | Yes, after a manual `/compact` (`PreCompact` trigger `manual`). Auto compaction not tested. |
| P3 | T3 marker in the hook environment? | `CLAUDE_CODE_ENTRYPOINT=sdk-ts`, `CLAUDE_CODE_SESSION_ATTENDED=0`, no `TMUX`, no `T3*` variable. `sdk-ts` alone does not prove T3: other SDK programs set it too. |
| P4 | `CLAUDE_PID`? | Set. Same value before and after `/compact` and `/clear`. |
| P5 | Claude session id in `t3 thread show`? | No. See L3 for the lookup. |
| P6 | `/clear` through `t3 thread send`? | Yes. `SessionStart` source `clear`, new session id, old messages gone. |
| P7 | Hook `cwd`? | `/home/hamza/repo`, the T3 project root, not the folder where the CLI ran. |

## Live test 2 — resume after `/clear` (2026-10-22, same thread)

1. Sent "Remember the code word PINEAPPLE-42" (session `a8750bc3`). Then `/clear` (new session `6b945c8f`). The agent answered NONE for the code word.
2. Stopped the server (SIGTERM). The desktop app started a new server after about 1 min.
3. Asked the agent to quote every earlier message.

Result: T3 resumed session `64d960a9`, its stored `nativeId` (L4), from before the first `/clear`. The agent saw the first probe message and the old compaction summary. The code word was not visible.

Conclusion R1: a `/clear` inside a T3 thread is not safe. After a server restart, the context jumps back to the first session of the thread. A hook cannot change `nativeId`.

## Live test 3 — Phase 1 open facts (2026-10-22, Haiku)

Details: `results/2026-10-22-phase1.md`. Test hook: `tools/phase1-hook.sh`.

| # | Fact |
|---|---|
| F1 | The direct parent of `CLAUDE_PID` is the T3 server binary under `~/.t3/wsl-runtime/`. `/proc/<parent>/exe` gives the `t3` CLI path. |
| F2 | Two `t3 thread send` calls run in order. The second waits in the queue. |
| F3 | A detached `t3 thread send` from a `Stop` hook works. `/compact` starts about 2 s later. |
| F4 | After `/compact` and a server restart, the thread resumes the compacted context. The session id stays the same. |
| F5 | Each T3 thread has its own `CLAUDE_PID`. |
| F6 | Haiku's compaction summary lost a code word from the first message. The summary is lossy. |

## Facts from our own hooks (`../handoff/`)

| # | Fact | Location |
|---|---|---|
| H1 | `handoff-nudge.sh`, `handoff-stop.sh` and `handoff-inject.sh` exit unless `CLAUDE_CODE_SESSION_ATTENDED=1`. | first lines of each script |
| H2 | `handoff-nudge.sh` exits outside tmux (empty `TMUX` or `TMUX_PANE`). `--manual` skips this check. | `handoff-nudge.sh` line 17 |
| H3 | `handoff-stop.sh` types `/clear` into the tmux pane. Outside tmux it prints "Type /clear" and exits. | `handoff-stop.sh` lines 58-61 |
| H4 | The handoff binds to the window with `.state/pid-$CLAUDE_PID` (process start time, file, model). | `bind()` in `handoff-nudge.sh` |
| H5 | Warn and stop are sent once per session: markers `.state/<sid>.warn` and `.state/<sid>.hard`. Compaction keeps the session id, so a second cycle in the same session finds the old markers. Between warn and stop it says nothing. At stop it never calls `bind`. | `mark()` in `handoff-nudge.sh` |
| H6 | After `compact_boundary` the token count reads 0 until the next reply. | `handoff-nudge.sh` lines 30-36 |
| H7 | `handoff-inject.sh` moves `<sid>.md` to `<sid>.used.md`. With one session id, the next cycle overwrites the old used file. | end of `handoff-inject.sh` |
| H8 | The inject header says "Handoff restored after /clear". | `handoff-inject.sh` |
| H9 | `handoff-stop.sh` limits automatic clears to 10 per window. Files `.state/pid-$CLAUDE_PID.cycles` and `.auto`. | `handoff-stop.sh` |
| H10 | `handoff-inject.sh` writes `.state/<sid>.chain`, then deletes `.state/<old>.chain`. After compaction `<old>` = `<sid>`, so the chain file is gone. Effect: the next handoff has no "Earlier transcripts" list. The transcript is the same file, so nothing is lost. | end of `handoff-inject.sh` |
