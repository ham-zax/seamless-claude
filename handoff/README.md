# Handoff hooks

In tmux, near a per-model token limit, Claude
writes a short handoff file at a checkpoint and ends its turn. A hook then clears the session and
continues from the handoff without you. Outside tmux, the hooks send no messages and native
auto-compaction handles a full context. Native auto-compaction also stays on in tmux as the last
fallback. Only the optional side note calls a background model.

## Flow

1. `handoff-nudge.sh` (UserPromptSubmit and PostToolUse) reads the context size from the transcript:
   `input_tokens + cache_read_input_tokens + cache_creation_input_tokens` of the last main-chain
   assistant entry.
2. At the warn limit it injects one heads-up message with the template: continue the work, plan a
   checkpoint (a finished, verified step) within about 10k tokens, and do not start a sub-task that
   cannot finish before it. At the checkpoint, write the handoff to `~/.claude/handoffs/<project-slug>/<session-id>.md` as the last
   action and end the turn. A handoff never replaces a reply: Claude answers a short user question in
   visible text first, else lists it under `## Owed to the user`. The hook also binds the handoff to
   this Claude window: `CLAUDE_PID`, the process start time and the model.
3. At the stop limit it injects one message: stop now, let background jobs run, write the handoff at
   once. Each later prompt and tool result gets a one-line reminder until the file exists. Native
   auto-compaction is the last fallback.
4. The template (`handoff-nudge.sh`, `template=`) has these sections: Goal, Constraints, Owed to the
   user, State, Decisions, Uncertainty, Facts to keep, Live state, Next step. Every section is written,
   with `none` when empty. Items from an earlier handoff carry forward, and a lost detail is marked
   `UNKNOWN`. Every handoff has a `## Owed to the user` section: each question the user has not seen
   answered, and each promise, or `none`. The front matter has `status: continue` (work remains that needs no user decision) or
   `status: done`.
5. `handoff-stop.sh` (Stop) blocks the stop once if this session's handoff has no
   `## Owed to the user` section. Then it clears after every handoff, so no turn runs after it. With
   `status: continue` it also types a continue prompt. With `status: done` it types a prompt that
   asks the new session to show only the `## Owed to the user` items, and then the session waits
   for you:
   - first it appends a record to the handoff: `## Last reply to the user` (the final visible reply
     from the Stop input `last_assistant_message`, cut at 6000 characters) and `## Earlier
     transcripts` (up to 4 sessions before this one). It replaces the record on every Stop until the
     `/clear`;
   - in tmux, a detached helper clears the input box, types `/clear` into this pane, waits until the
     handoff is loaded, then clears the box again and types `Continue from the handoff.` (only for
     `continue`). To clear the box it sends `x`, `Escape Escape` twice: `C-l` does not clear it, and
     `Escape Escape` on an empty box opens Rewind. Unsent text in the box is lost. It types only after 2 s without your input
     in this pane (tmux `client_activity` of clients that show this pane), and gives up after 30 s
     of typing. Input in other panes does not count. Each give-up appends a line to
     `~/.claude/handoffs/.state/clear.log`;
   - outside tmux, or after 10 automatic clears in the window (every model), it tells you to type
     `/clear`. Your `/clear` sets the count to 0, and the next 10 clears run automatically. A
     give-up also removes the `.auto` marker, so your next `/clear` sets the count to 0.
6. `handoff-inject.sh` (SessionStart, matcher `clear`) loads the handoff bound to this window, if the
   file exists and is less than 2 h old, and renames it to `<session-id>.used.md`. The header gives
   the old transcript path and a `jq` command that prints only the user's messages, so the new
   session can read a detail that the handoff left out. It saves the transcript chain for the next
   handoff (`<session-id>.chain`). The new session gives the owed items and repeats any question in
   the last reply before the Next step and re-checks a cheap claim before it builds on
   it. A handoff over 40,000 characters is cut with a notice that names the full file. The first
   `/clear` in the window removes the binding, with or without a handoff.

`/handoff` starts a handoff at once, at any context size, in tmux or not: it runs
`handoff-nudge.sh --manual`, which binds the handoff and prints the instructions and the template.
Install it with `ln -s ~/repo/seamless-claude/handoff/handoff.md ~/.claude/commands/handoff.md`.

`/clear` keeps the Claude process, so the PID stays the same and only the session ID changes. A
`/clear` in another window, in the same folder or not, loads nothing and behaves natively. The start
time protects against a reused PID. If you close the window instead of typing `/clear`, the handoff
stays on disk: tell the new session to read it.

`<project-slug>` is the name of the transcript folder in `~/.claude/projects/`: the start folder of the
session with every non-alphanumeric character replaced by `-`. A `cd` in the session does not change it.
All hooks do nothing unless `CLAUDE_CODE_SESSION_ATTENDED=1`, so `claude -p`, SDK runs and workers
are not affected. `handoff-nudge.sh` also does nothing unless `$TMUX` and `$TMUX_PANE` are set, so
outside tmux no handoff starts and native auto-compaction runs.

## Side note (optional, off)

`handoff/sidenote.sh` lets a side model keep a note of your rules, approvals, open promises and
decisions while the main model works. The side note is off by default. To turn it on, set
`"env": { "HANDOFF_NOTE": "haiku" }` or `"pi"` in `~/.claude/settings.json`:

- `haiku`: `claude -p --model claude-haiku-5-5 --effort xhigh` on your Claude account. `--bare` is
  not used, because it needs an API key.
- `pi`: `pi -p --model opencode2api/minimax-m3.1-flash-free` (free OpenAI-compatible endpoint).

`handoff-nudge.sh` starts the runs: the first at 70k tokens, then after each 20k new tokens, and one
last run when the warn message arrives. Below the warn limit Claude gets no message. Each run is a new
detached process with the handoff hooks off. It reads the note and the user and assistant text since
the last good run (no tool output, the newest 400,000 characters at most), writes the updated note
through a temp file and a rename, and stops within 300 s.

- One run at a time: a lock file blocks a second run. The blocked tick writes `.note.want`, and
  the working run then does one more pass that reads the new text (2 passes at most per run).
  A lock older than 6 min belongs to a dead run and is removed.
- The last run starts even when the handoff file already exists.
- A run saves the read position only after it succeeds, so a blocked or failed run loses no text.
- The note belongs to the window (PID and start time), not to the session. After `/clear` the new
  session keeps the note, and a last run that ends after the `/clear` still updates it.
- The warn, stop and `/handoff` messages tell Claude to read the note, check it, and copy each
  still-valid item into the handoff. The restore header names the note and tells the new session to
  read it only if the handoff seems to lack a rule, an approval or a promise, or says `UNKNOWN`.

## Limits

The limits live in `handoff/limits.sh`. `~/.claude/statusline.sh` sources the same file and shows
`hoff <percent of the stop limit>`.

| Model | Warn (checkpoint) | Stop now | Automatic clears per window | Native compaction starts |
|---|---|---|---|---|
| model id contains `haiku` | 90k | 100k | 7 | about 115k (`autoCompactWindow` 148000) |
| all other models | 140k | 150k | 7 | about 165k (`autoCompactWindow` 198000) |

Native compaction starts at `autoCompactWindow` − 33k (the autocompact buffer that `/context`
shows). Keep it above the stop limit, or compaction runs before the handoff. A `/clear` that you type
resets the automatic clear count.

## Wiring (`~/.claude/settings.json`)

```json
{
  "autoCompactWindow": 198000,
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

- `~/.claude/handoffs/<project-slug>/<session-id>.md`: handoff, written by Claude.
- `~/.claude/handoffs/<project-slug>/<session-id>.used.md`: handoff after injection. Kept for review.
- `~/.claude/handoffs/<project-slug>/window-<pid>-<start time>.note.md`: side note of a window, only
  when the side note is on. Kept for review.
- `~/.claude/handoffs/.state/pid-<pid>.note` (`<start time> <transcript> <read position>`),
  `.note.at` (`<start time> <transcript> <tokens at the last start> <last run started 0|1>`) and
  `.note.lock` (a run works) and `.note.want` (a blocked tick asks for one more pass): side note
  state.
- `~/.claude/handoffs/.state/<session-id>.warn` and `.hard`: tiers already injected for a session.
  The hook creates them atomically, so parallel tool calls inject each message once.
- `~/.claude/handoffs/.state/pid-<pid>`: `<start time> <handoff path> <model>`, the binding to a window.
- `~/.claude/handoffs/.state/pid-<pid>.auto`: an automatic `/clear` is in progress. One trigger per
  handoff.
- `~/.claude/handoffs/.state/pid-<pid>.cycles`: `<start time> <count>`, automatic clears in a window.
- `~/.claude/handoffs/.state/<session-id>.chain`: transcripts of the sessions before this one, newest
  first. `handoff-inject.sh` writes it and removes the old session's chain.

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
