# Handoff hooks

A lean alternative to the seamless-claude plugin. In tmux, near a per-model token limit, Claude
writes a short handoff file at a checkpoint and ends its turn. A hook then clears the session and
continues from the handoff without you. Outside tmux, the hooks send no messages and native
auto-compaction handles a full context. Native auto-compaction also stays on in tmux as the last
fallback. There is no background model call.

## Flow

1. `handoff-nudge.sh` (UserPromptSubmit and PostToolUse) reads the context size from the transcript:
   `input_tokens + cache_read_input_tokens + cache_creation_input_tokens` of the last main-chain
   assistant entry.
2. At the warn limit it injects one message with the template: at the next checkpoint (a finished,
   verified step), write the handoff to `~/.claude/handoffs/<cwd-slug>/<session-id>.md` as the last
   action and end the turn. It also binds the handoff to this Claude window: `CLAUDE_PID`, the process
   start time and the model.
3. At the stop limit it injects one message: stop now, let background jobs run, write the handoff at
   once. Each later prompt gets a one-line reminder until the file exists.
4. The handoff front matter has `status: continue` (work remains that needs no user decision) or
   `status: done`.
5. `handoff-stop.sh` (Stop) acts when this session's handoff exists with `status: continue`:
   - in tmux, a detached helper types `/clear` into this pane, waits until the handoff is loaded,
     then types `Continue from the handoff.`;
   - outside tmux, or after the automatic clear limit, it tells you to type `/clear`.
6. `handoff-inject.sh` (SessionStart, matcher `clear`) loads the handoff bound to this window, if the
   file exists and is less than 2 h old, and renames it to `<session-id>.used.md`. The header gives
   the old transcript path, so the new session can read a detail that the handoff left out. The first
   `/clear` in the window removes the binding, with or without a handoff.

`/clear` keeps the Claude process, so the PID stays the same and only the session ID changes. A
`/clear` in another window, in the same folder or not, loads nothing and behaves natively. The start
time protects against a reused PID. If you close the window instead of typing `/clear`, the handoff
stays on disk: tell the new session to read it.

`<cwd-slug>` is the working directory with every non-alphanumeric character replaced by `-`.
All hooks do nothing unless `CLAUDE_CODE_SESSION_ATTENDED=1`, so `claude -p`, SDK runs and workers
are not affected. `handoff-nudge.sh` also does nothing unless `$TMUX` and `$TMUX_PANE` are set, so
outside tmux no handoff starts and native auto-compaction runs.

## Limits

| Model | Warn (checkpoint) | Stop now | Automatic clears per window | Native compaction starts |
|---|---|---|---|---|
| model id contains `haiku` | 85k | 95k | no limit | about 115k (`autoCompactWindow` 148000) |
| all other models | 135k | 145k | 5 | about 170k (`autoCompactWindow` 203000) |

Native compaction starts at `autoCompactWindow` − 33k (the autocompact buffer that `/context`
shows). Keep it above the stop limit, or compaction runs before the handoff. A `/clear` that you type
resets the automatic clear count.

## Wiring (`~/.claude/settings.json`)

```json
{
  "autoCompactWindow": 203000,
  "modelSettings": { "claude-haiku-5-5": { "autoCompactWindow": 148000 } },
  "hooks": {
    "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "$HOME/repo/seamless-claude/handoff/handoff-nudge.sh" }] }],
    "PostToolUse": [{ "hooks": [{ "type": "command", "command": "$HOME/repo/seamless-claude/handoff/handoff-nudge.sh" }] }],
    "Stop": [{ "hooks": [{ "type": "command", "command": "$HOME/repo/seamless-claude/handoff/handoff-stop.sh" }] }],
    "SessionStart": [{ "matcher": "clear", "hooks": [{ "type": "command", "command": "$HOME/repo/seamless-claude/handoff/handoff-inject.sh" }] }]
  }
}
```

Add these entries next to existing hooks. Do not replace them. For automatic clears, start Claude
inside tmux (for example `tmux new -A -s main`, then `claude`).

## Files

- `~/.claude/handoffs/<cwd-slug>/<session-id>.md`: handoff, written by Claude.
- `~/.claude/handoffs/<cwd-slug>/<session-id>.used.md`: handoff after injection. Kept for review.
- `~/.claude/handoffs/.state/<session-id>.warn` and `.hard`: tiers already injected for a session.
  The hook creates them atomically, so parallel tool calls inject each message once.
- `~/.claude/handoffs/.state/pid-<pid>`: `<start time> <handoff path> <model>`, the binding to a window.
- `~/.claude/handoffs/.state/pid-<pid>.auto`: an automatic `/clear` is in progress. One trigger per
  handoff.
- `~/.claude/handoffs/.state/pid-<pid>.cycles`: `<start time> <count>`, automatic clears in a window.

## Test

```sh
handoff/test.sh      # fixture tests, no model calls
shellcheck handoff/*.sh
```

To test `/clear` end to end without a person, drive real interactive windows with tmux on a
private socket. The folder trust prompt selects "No" by default: send `Down`, then `Enter`.

```sh
tmux -L hot new-session -d -s A -c "$dir" "claude --model haiku"
tmux -L hot send-keys -t A -l 'Reply with OK.'; tmux -L hot send-keys -t A Enter
tmux -L hot capture-pane -p -t A
tmux -L hot kill-server   # when done
```

Get the window's PID, session ID and `procStart` from `~/.claude/sessions/*.json`. Write a handoff
with `status: continue` and its binding (see Files), then send one prompt. The hook types `/clear`
and the continue prompt, and the new session follows the handoff's Next step.
