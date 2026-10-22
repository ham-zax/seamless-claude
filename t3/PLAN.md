# Handoff in T3 Code — plan

Status: Phases 0 to 4 done (Phase 3: `results/2026-10-22-e2e.md`). Open: T3 native auto compaction untested. Last update 2026-10-22.
Facts and test results: FINDINGS.md (referenced as S1, L3, P6, H5 and so on).

## Goal

Give Claude threads in T3 Code the handoff cycle of tmux, without the user:
warn → the agent writes the handoff → the context resets → the agent continues from the handoff.

## Rules

1. Everything for T3 lives in `t3/`. Do not edit `../handoff/`. The T3 hooks wrap the handoff scripts.
   If a change in `../handoff/` is ever unavoidable, write it as a proposal in PLAN.md first, with the reason.
2. The T3 hooks do nothing outside T3 Code. tmux sessions and other SDK programs keep the current behavior.
3. Two concurrent sessions stay correct: all state stays keyed by `CLAUDE_PID` and session id, as in `../handoff/`.
4. Live tests use only Haiku (`--model claude-haiku-5-5`).
5. Each live test writes its result to `results/<date>-<test>.md` with the T3 version.

## Decision

**Path A': compaction in the same thread.** After the handoff, the T3 stop hook queues two turns in the same thread:
`/compact`, then "Continue from the handoff." (only for `status: continue`). `SessionStart(compact)` injects the handoff.

Reasons:
- `/clear` in the thread (path C) fails after a server restart (R1).
- Compaction keeps the session id, so a restart resumes the correct context (L4).
- One thread, nothing to settle, no user action.

Cost: the compaction summary stays in the context next to the handoff.

Rejected: path C, `/clear` in the same thread (R1). Kept in reserve: path B, a new thread per reset with `t3 thread start`.
Path B is safe on restart, but old threads stay open, and no settle command was found.
After Phase 3 (path A' works live) the settle check through the T3 MCP tools is not needed. Do it only if path A' breaks.

## Folder layout

| Path | Purpose |
|---|---|
| `README.md` | Entry point for an agent or the user: what, install, check after a T3 update, troubleshooting. |
| `PLAN.md` | This file: design, phases, decisions. |
| `FINDINGS.md` | Facts and live test results, with the T3 version. |
| `hooks/lib.sh` | Shared functions: `t3_session`, `t3_bin`, `t3_thread_id`. |
| `hooks/nudge.sh` | `UserPromptSubmit` + `PostToolUse`. In T3, runs `../handoff/handoff-nudge.sh`. |
| `hooks/stop.sh` | `Stop`. In T3, runs `../handoff/handoff-stop.sh`, then queues `/compact` and the continue prompt. |
| `hooks/inject.sh` | `SessionStart` matcher `compact`. In T3, runs `../handoff/handoff-inject.sh`, then resets the per-session state. |
| `hooks/handoff-now.sh` | Manual handoff in T3 (the `/handoff` command equivalent). |
| `install.sh` | Adds or removes (`--remove`) the T3 hook entries in `~/.claude/settings.json`. Backup first, idempotent. |
| `test.sh` | Offline tests with a fake `t3` binary and fake transcripts. No T3 server, no model. |
| `tools/probe.sh` | Phase 0 probe: logs hook events and environment. |
| `tools/live-check.sh` | Live check against the running T3 server with Haiku. Re-runs the probe facts and one handoff cycle. |
| `results/` | Dated live check outputs. |

## Design

### `hooks/lib.sh`

- `t3_session`: true only if an ancestor of `$CLAUDE_PID` runs a binary under `~/.t3/wsl-runtime/`. `CLAUDE_CODE_ENTRYPOINT=sdk-ts` alone is not enough (P3).
- `t3_bin`: prints the `/proc/<ancestor>/exe` path of that ancestor (L1, L2). No hash in a config file.
- `t3_thread_id <sid>`: finds the provider log that contains the session id (L3), turns the file name into a thread id, and confirms it with `t3 thread list --json`. Prints nothing if not found.

### `hooks/nudge.sh`

If `t3_session`: run `handoff-nudge.sh` with `CLAUDE_CODE_SESSION_ATTENDED=1` and `TMUX`/`TMUX_PANE` set to a placeholder. Pass stdin and stdout through.
Otherwise exit 0. Open point: the message text says "a hook clears the session". Accept it, or replace the line in the wrapper output.

### `hooks/stop.sh`

If `t3_session`:
1. Run `handoff-stop.sh` with `CLAUDE_CODE_SESSION_ATTENDED=1` and `TMUX` unset. It writes the record into the handoff and prints "Type /clear". If it prints a `block` decision, pass it through and stop.
2. Check the same conditions as `handoff-stop.sh`: `.state/pid-$CLAUDE_PID` exists, start time matches, file is `<sid>.md`, `status` is `continue` or `done`.
3. Apply the limit of 10 automatic resets per window (H9).
4. Find the thread id. If not found, print a `systemMessage` ("Press compact in T3") and stop.
5. Detached, without `--wait`: `t3 thread send <id> /compact`, then for `continue` `t3 thread send <id> "Continue from the handoff."`, for `done` the "Show me only what the handoff lists under ## Owed to the user" prompt of H3.
Otherwise exit 0.

### `hooks/inject.sh`

If `t3_session` and source is `compact`:
1. Archive an existing `<sid>.used.md` to `<sid>.used.<n>.md` (H7).
2. Run `handoff-inject.sh` with `CLAUDE_CODE_SESSION_ATTENDED=1`. Pass its output through.
3. Remove `.state/<sid>.warn` and `.state/<sid>.hard` so the next cycle warns again (H5).
Otherwise exit 0.

### `install.sh`

Adds the T3 hook entries next to the current ones. The tmux entries stay. Each T3 hook exits at once outside T3.
`--remove` deletes only the entries that point into `t3/hooks/`.

## Phases

### Phase 0 — probe and resume test — done

Results: FINDINGS.md, live tests 1 and 2.

### Phase 1 — open facts (live, Haiku) — done, all yes (FINDINGS.md F1-F6)

`t3_session` checks the parent chain of `CLAUDE_PID` (F1). The stop hook sends detached (F3).

1. Does `t3_session` detection work (ancestor of `CLAUDE_PID` is the T3 binary)?
2. Do two queued `t3 thread send` calls run in order, after the current turn ends?
3. Does a `t3 thread send` started from inside a `Stop` hook work (the turn is still running)?
4. Does a resume after a server restart keep the context after `/compact`?
5. Do two T3 threads in one project have different `CLAUDE_PID` values?

### Phase 2 — build — done (`t3/test.sh`: 28 checks pass, `../handoff/test.sh` unchanged: 82 pass)

1. `hooks/lib.sh` and `test.sh` cases for it.
2. `hooks/inject.sh`, `hooks/nudge.sh`, `hooks/stop.sh`, `hooks/handoff-now.sh`, each with `test.sh` cases.
   Cases: outside T3 nothing happens, compact source injects once, a second cycle in one session warns again, another window's handoff is not loaded, limit of 10 resets, no thread id found.
3. `install.sh` with `--remove`.
4. `shellcheck` on every script.

### Phase 3 — live end-to-end (Haiku)

1. Install. Start a Haiku thread with `t3 thread start`.
2. The agent runs `hooks/handoff-now.sh`, writes the handoff, ends the turn.
3. Check: `/compact` runs, the handoff is injected, the agent continues without user input.
4. Repeat once in the same thread (second cycle, H5 and H7).
5. Restart the server. Check that the context after the restart is the compacted one.
6. Write `results/<date>-e2e.md`.

### Phase 4 — docs

Update `README.md`, the main `README.md` (one line that points to `t3/`) and `~/.claude/CLAUDE.md` "Context handoff" section.

## Decisions made in Phase 2

- `autoCompactWindow` in T3 stays the fallback above the stop limit (stop + 15k, as in tmux).
- The wrappers rewrite the text "a hook clears the session" to "a hook compacts this T3 thread".
- A compaction that the stop hook did not start (T3 fallback, compact button) resets the cycle count, like a user `/clear` in tmux (H9).
- The stop hook has a 60 s timeout: the thread lookup calls `t3 thread show` up to two times.
