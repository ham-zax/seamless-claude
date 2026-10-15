#!/usr/bin/env bash
# UserPromptSubmit + PostToolUse hook: when the context nears the per-model limit, tells Claude to
# write a handoff file at the next checkpoint, and at the stop limit to write it at once. After the
# handoff, handoff-stop.sh clears the session in tmux (or the user types /clear) and handoff-inject.sh
# loads the file into the new session. Native auto-compaction stays the fallback: autoCompactWindow
# in settings.json must put it above the stop limit (window - 33k buffer).
#
# Headless runs (claude -p, SDK, workers) have nobody to type /clear: skip them.
[ "${CLAUDE_CODE_SESSION_ATTENDED:-}" = 1 ] || exit 0
# Outside tmux nothing can clear the session automatically: native auto-compaction handles it.
[ -n "${TMUX:-}" ] && [ -n "${TMUX_PANE:-}" ] || exit 0
set -u

input=$(cat)
IFS=$'\t' read -r event sid tp cwd < <(jq -r '[.hook_event_name, .session_id, .transcript_path, .cwd] | @tsv' <<<"$input")
[[ $sid =~ ^[A-Za-z0-9-]+$ ]] && [ -r "$tp" ] || exit 0

# Context size = input + cache tokens of the last main-chain assistant entry. A compact_boundary after
# it makes that number stale, so it reads as 0 until the next reply.
read -r tokens model < <(tail -c 4000000 "$tp" | jq -Rr '
  fromjson? // empty
  | if .type == "assistant" and .message.usage and (.isSidechain | not) and .message.model != "<synthetic>" then
      "\(.message.usage | (.input_tokens // 0) + (.cache_read_input_tokens // 0) + (.cache_creation_input_tokens // 0)) \(.message.model)"
    elif .subtype == "compact_boundary" then "0 compact"
    else empty end' | tail -n 1)
[[ ${tokens:-} =~ ^[0-9]+$ ]] || exit 0

case $model in
  *haiku*) warn=85000 hard=95000 ;;    # Haiku usage costs about 3x above 100k
  *)       warn=135000 hard=145000 ;;
esac
(( tokens >= warn )) || exit 0

file=$HOME/.claude/handoffs/${cwd//[^A-Za-z0-9]/-}/$sid.md
[ -e "$file" ] && exit 0   # handoff written: no more messages
state=$HOME/.claude/handoffs/.state
mkdir -p "$state"
k=$((tokens / 1000)) h=$((hard / 1000))
# One message per tier: parallel tool calls run this hook at the same time, and only the hook that
# creates the marker file first injects.
mark() { (set -o noclobber; : > "$state/$sid.$1") 2>/dev/null; }
# Bind the handoff to this Claude window: PID, process start time, model. /clear keeps the process,
# so only a /clear in this window loads the handoff. Other windows in the same folder load nothing.
bind() {
  local start
  start=$(sed 's/.*) //' "/proc/${CLAUDE_PID:-x}/stat" 2>/dev/null | cut -d' ' -f20)
  [ -n "$start" ] && printf '%s %s %s\n' "$start" "$file" "$model" > "$state/pid-$CLAUDE_PID"
}
after="A hook then clears the session and continues from the handoff in a new session."
# The warning often arrives on a user prompt. A handoff never replaces the reply to that prompt: an
# answer that only exists in reasoning or in the handoff file is lost at /clear.
owed="A handoff never replaces a reply. If the user asked something, answer it in visible text first when the answer is short. Otherwise list it under ## Owed to the user."

template="The handoff replaces this whole conversation for the next session. Keep only what is expensive or impossible to rebuild from git and the repository. Rules: about 2000 words at most. Omit empty sections. Keep paths, commands, IDs and error messages verbatim. Give pointers (file:line, command) instead of file contents. Do not list modified files: git shows them.
status: write continue if work remains that you can do without the user. Write done if the request is complete and verified, or the next step needs the user.

---
session: $sid
cwd: $cwd
created: <ISO time>
status: continue | done
---
## Goal
The request and its done condition. Quote the user's direction-setting messages verbatim: requests, corrections, constraints, approvals.
## Owed to the user
Always include this section. List every user question or request that the user has not yet seen answered in a visible reply, quoted verbatim, with any partial findings. An answer that exists only in your reasoning or in this file is owed. Write \"none\" only if the user saw every answer.
## State
What is done and how it was verified (command and result). What is in progress.
## Decisions
DECISION: choice, reason. Include what the user approved or rejected.
## Dead ends
FAILED: what was tried, why it failed.
## Facts to keep
Facts that cost tokens to find again: file:line locations, commands, measured numbers, environment quirks.
## Live state
Running processes, background jobs, workers and their IDs, temp files, pending approvals.
## Next step
The exact next action and its stop condition. Open questions for the user."

if (( tokens < hard )); then
  mark warn || exit 0
  bind
  msg="[handoff] Context is at ${k}k tokens. At ${h}k a [handoff] message tells you to stop at once.
Reach a checkpoint before then: finish and verify the current step. Do not start large new work.
$owed
At the checkpoint, write the handoff to: $file
Make it your last action and end your turn. $after

$template"
elif mark hard; then
  bind
  msg="[handoff] Context is at ${k}k tokens, at the ${h}k stop limit for this model. Stop now. Do not finish the current step.
Let background jobs run. Move a long foreground command to the background. List every unanswered user question under ## Owed to the user. Write the handoff to $file now as your last action, then end your turn. $after"
  # Context can jump past the warn limit in one tool result: then the template comes here.
  mark warn && msg+="

$template"
elif [ "$event" = UserPromptSubmit ]; then
  msg="[handoff] Context is at ${k}k tokens, above the ${h}k stop limit. Write the handoff to $file now as the earlier [handoff] message describes, then end your turn."
else
  exit 0   # PostToolUse: the reminder waits for the next user prompt
fi

jq -n --arg e "$event" --arg m "$msg" '{hookSpecificOutput: {hookEventName: $e, additionalContext: $m}}'
