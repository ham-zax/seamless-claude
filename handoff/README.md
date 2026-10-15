# Handoff hooks

A lean alternative to the seamless-claude plugin. At a per-model token limit, Claude stops at the
nearest checkpoint and writes a short handoff file. You type `/clear`. A hook loads the handoff into
the new session. Native auto-compaction stays on as the last fallback. There is no background model
call.

## Flow

1. `handoff-nudge.sh` (UserPromptSubmit and PostToolUse) reads the context size from the transcript:
   `input_tokens + cache_read_input_tokens + cache_creation_input_tokens` of the last main-chain
   assistant entry.
2. At the warn limit it injects one message: reach a checkpoint soon, do not write the handoff yet.
3. At the hard limit it injects the full instruction once: finish the current step, write the handoff
   to `~/.claude/handoffs/<cwd-slug>/<session-id>.md`, tell the user to type `/clear`. Each later
   prompt gets a one-line reminder until the file exists. With the hard message, it binds the
   handoff to this Claude window: `CLAUDE_PID` and the process start time.
4. `handoff-inject.sh` (SessionStart, matcher `clear`) loads the handoff bound to this window, if the
   file exists and is less than 2 h old. It appends a mechanical tail of the old transcript after the
   handoff was written (user and assistant text, one-line tool briefs, at most 6000 chars). Then it
   renames the file to `<session-id>.used.md`. The first `/clear` in the window removes the binding,
   with or without a handoff.

`/clear` keeps the Claude process, so the PID stays the same and only the session ID changes. A
`/clear` in another window, in the same folder or not, loads nothing and behaves natively. The start
time protects against a reused PID. If you close the window instead of typing `/clear`, the handoff
stays on disk: tell the new session to read it.

`<cwd-slug>` is the working directory with every non-alphanumeric character replaced by `-`.
Both hooks do nothing unless `CLAUDE_CODE_SESSION_ATTENDED=1`, so `claude -p`, SDK runs and workers
are not affected.

## Limits

| Model | Warn | Hard | Native compaction starts |
|---|---|---|---|
| model id contains `haiku` | 85k | 100k | about 115k (`autoCompactWindow` 148000) |
| all other models | 135k | 150k | about 170k (`autoCompactWindow` 203000) |

Native compaction starts at `autoCompactWindow` − 33k (the autocompact buffer that `/context`
shows). Keep it above the hard limit, or compaction runs before the handoff.

## Wiring (`~/.claude/settings.json`)

```json
{
  "autoCompactWindow": 203000,
  "modelSettings": { "claude-haiku-5-5": { "autoCompactWindow": 148000 } },
  "hooks": {
    "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "$HOME/repo/seamless-claude/handoff/handoff-nudge.sh" }] }],
    "PostToolUse": [{ "hooks": [{ "type": "command", "command": "$HOME/repo/seamless-claude/handoff/handoff-nudge.sh" }] }],
    "SessionStart": [{ "matcher": "clear", "hooks": [{ "type": "command", "command": "$HOME/repo/seamless-claude/handoff/handoff-inject.sh" }] }]
  }
}
```

Add these entries next to existing hooks. Do not replace them.

## Files

- `~/.claude/handoffs/<cwd-slug>/<session-id>.md`: handoff, written by Claude.
- `~/.claude/handoffs/<cwd-slug>/<session-id>.used.md`: handoff after injection. Kept for review.
- `~/.claude/handoffs/.state/<session-id>.warn` and `.hard`: tiers already injected for a session.
  The hook creates them atomically, so parallel tool calls inject each message once.
- `~/.claude/handoffs/.state/pid-<pid>`: `<start time> <handoff path>`, the binding to a window.

## Test

```sh
handoff/test.sh      # fixture tests, no model calls
shellcheck handoff/*.sh
```

To test `/clear` end to end without a person, drive real interactive windows with tmux on a
private socket. The folder trust prompt selects "No" by default: send `Down`, then `Enter`.

```sh
tmux -L hot new-session -d -s A -c "$dir" "claude --model haiku"
tmux -L hot send-keys -t A '/clear'; tmux -L hot send-keys -t A Enter
tmux -L hot capture-pane -p -t A
tmux -L hot kill-server   # when done
```

Write a handoff and its binding (`.state/pid-<pid>`, see Files) for window A, then type `/clear`
in another window and in A. Only A loads the handoff.
