# Handoff hooks: a lean handoff before /clear

Aegis Visibility: this plan adds new hook scripts, a settings contract (`autoCompactWindow`) and a
handoff file format. These surfaces need a durable record.

## Goal

At a per-model token limit, Claude stops at the nearest checkpoint and writes a short handoff file.
The user types `/clear`. A `SessionStart(clear)` hook injects that handoff into the new session.
The aim is more work per usage budget: a handoff costs about 4–10k tokens, and the user accepts
a small accuracy loss. Native auto-compaction stays on as the last fallback.

## Approved scope (user, 2026-10-15)

| Item | Decision |
|---|---|
| Limits, all models except Haiku | warn 135k, hard 150k |
| Limits, model id contains `haiku` | warn 85k, hard 100k (above 100k the user's Haiku usage costs about 3x) |
| Native fallback | `autoCompactWindow` 203000 (start about 170k), Haiku 148000 (start about 115k) |
| Triggers | UserPromptSubmit and PostToolUse (tool loops grow context with no user prompt) |
| Messages | warn once; hard limit: full message once, then a one-line reminder on each later prompt until this session's handoff exists |
| Handoff file | `~/.claude/handoffs/<cwd-slug>/<session-id>.md` |
| Injection | only the handoff bound to this window (PID + process start time), at most 2 h old; renamed to `<session-id>.used.md` after use |
| Gap after the handoff | the inject hook appends a mechanical tail of the old transcript (no model call) |
| Headless sessions | all hooks do nothing unless `CLAUDE_CODE_SESSION_ATTENDED=1` |
| Code home | this fork; `~/.claude/settings.json` points at the scripts here; no copy in `~/.claude/hooks` |
| Review | reminder to review real sessions on or after 2026-10-29 |

Out of scope: seamless-claude's Node plugin (left unchanged and unused), claive workers (headless,
so the hooks skip them). Later the user asked for a backup: `agent-config-backup` mirrors
`handoff/` into `config/claude/handoff/`.

## Measured facts (Claude Code 2.1.300)

- `claude -p "/context"` shows the compaction window and a fixed 33k autocompact buffer. Native
  compaction starts at window − 33k. The current setting `autoCompactWindow: 160000` gives about
  127k. Recent real Opus compactions started at 127k–131k, which matches.
- `CLAUDE_CODE_AUTO_COMPACT_WINDOW` accepts plain numbers only (`200k` parses as 100k).
- Per-model values work under `modelSettings.<model>.autoCompactWindow`. Both `haiku` and
  `claude-haiku-5-5` as keys apply to `--model haiku` and `--model claude-haiku-5-5`.
- Context size = `input_tokens + cache_read_input_tokens + cache_creation_input_tokens` of the
  last main-chain assistant entry in the transcript. After a `compact_boundary` entry that number
  is stale until the next assistant entry, so the hook skips the check.
- The hook environment has `CLAUDE_CODE_SESSION_ATTENDED`, `CLAUDE_CODE_SESSION_ID` and `CLAUDE_PID`
  (same pattern as `~/.claude/hooks/cachebeat-hook.sh`).

## Handoff format

Designed for continuation at minimum cost. The native compaction prompt asks for nine sections,
including all files and all user messages. seamless-claude asks for six, at 2000+ characters. Here
the new session can rebuild most facts from git and the repository, so the handoff keeps only what
is expensive or impossible to rebuild:

```
---
session: <id>
cwd: <cwd>
created: <ISO time>
---
## Goal            request, done condition, direction-setting user messages verbatim
## State           done + how verified, in progress; no file lists (git has them)
## Decisions       DECISION: choice, reason; user approvals and rejections
## Dead ends       FAILED: what was tried, why it failed
## Facts to keep   file:line pointers, commands, IDs, measured numbers, environment quirks
## Live state      running processes, workers, temp files, pending approvals
## Next step       exact next action, stop condition, open questions
```

Limit: about 800 words. Omit empty sections. Keep paths, commands and errors verbatim.

## Files

| File | Purpose |
|---|---|
| `handoff/handoff-nudge.sh` | UserPromptSubmit and PostToolUse hook: measure tokens, inject warn, hard and reminder messages |
| `handoff/handoff-inject.sh` | SessionStart(clear) hook: inject this window's handoff plus the transcript tail |
| `handoff/test.sh` | fixture tests for both scripts (no model calls) |
| `handoff/README.md` | what the hooks do, wiring, limits |
| `docs/handoff-review-2026-10-29.md` | review checklist for the reminder |
| `~/.claude/settings.json` | hook wiring, `autoCompactWindow` values |
| `~/.claude/CLAUDE.md` | short section: handoff behavior and review reminder |

State: `~/.claude/handoffs/.state/<session-id>.{warn,hard}` mark the tiers already injected
(created atomically). `~/.claude/handoffs/.state/pid-<pid>` binds a handoff to a window.

## TDD Route

mode `off`, decision `skipped`, authority `~/.config/aegis/config.toml`. Verification uses fixture
tests after the change.

## Tasks

1. Write `handoff-nudge.sh`. Check: `shellcheck`, `handoff/test.sh` cases below warn, warn, hard,
   reminder, handoff present, after compaction, Haiku limits, headless.
2. Write `handoff-inject.sh`. Check: `handoff/test.sh` cases fresh, stale, used, tail, headless.
3. Wire `~/.claude/settings.json`. Keep every existing hook. Add the inject hook as a second hook in
   the existing `clear` entry. Check: `jq` diff shows only the additions, and `claude -p --model
   opus "/context"` shows 203k, `--model haiku` shows 148k.
4. Headless check: one `claude -p` prompt in a scratch project creates no state or handoff files.
5. Interactive check (user): plant a handoff for a scratch folder, type `/clear`, ask what it says.
6. Update `~/.claude/CLAUDE.md` and write the review checklist.

## Risks

- PostToolUse runs after every tool call: the script reads at most the last 4 MB of the transcript
  with one `jq` pass.
- A deliberate run past the hard limit gets one-line reminders until about 170k, then native
  compaction runs.
- Revised 2026-10-15 after user review: the first version loaded the newest handoff in the folder.
  The user sometimes runs two windows in one folder, so a `/clear` in one window could load
  another window's handoff. Now a handoff is bound to the window that wrote it (`CLAUDE_PID` and
  process start time). A real two-window tmux test showed that the PID stays the same after
  `/clear` and that only the bound window loads the handoff.

## Retirement

None. seamless-claude's own plugin stays as upstream code and is not wired.
