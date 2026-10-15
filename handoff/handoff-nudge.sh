#!/usr/bin/env bash
# UserPromptSubmit + PostToolUse hook: when the context nears the per-model limit, tells Claude to
# stop at the nearest checkpoint and write a handoff file. The user then types /clear and
# handoff-inject.sh loads the file into the new session. Native auto-compaction stays the fallback:
# autoCompactWindow in settings.json must put it above the hard limit (window - 33k buffer).
#
# Headless runs (claude -p, SDK, workers) have nobody to type /clear: skip them.
[ "${CLAUDE_CODE_SESSION_ATTENDED:-}" = 1 ] || exit 0
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
  *haiku*) warn=85000 hard=100000 ;;   # Haiku usage costs about 3x above 100k
  *)       warn=135000 hard=150000 ;;
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

if (( tokens < hard )); then
  mark warn || exit 0
  msg="[handoff] Context is at ${k}k tokens. The hard limit for this model is ${h}k.
Plan to reach a checkpoint before the limit. Do not start large new work.
Do not write the handoff yet. A later [handoff] message asks for it at the limit."
elif mark hard; then
  # Bind the handoff to this Claude window: PID and process start time. /clear keeps the process, so
  # only a /clear in this window loads the handoff. Other windows in the same folder load nothing.
  start=$(sed 's/.*) //' "/proc/${CLAUDE_PID:-x}/stat" 2>/dev/null | cut -d' ' -f20)
  [ -n "$start" ] && printf '%s %s\n' "$start" "$file" > "$state/pid-$CLAUDE_PID"
  msg="[handoff] Context is at ${k}k tokens. The hard limit for this model is ${h}k.
Complete the current step right now to the nearest checkpoint. Do not start new work. Do not skip the verification of the step you finish.
Then write the handoff to: $file
Make it your last action. Then tell the user to type /clear. A hook loads the handoff into the new session.

The handoff replaces this whole conversation for the next session. Keep only what is expensive or impossible to rebuild from git and the repository. Rules: about 800 words at most. Omit empty sections. Keep paths, commands, IDs and error messages verbatim. Give pointers (file:line, command) instead of file contents. Do not list modified files: git shows them.

---
session: $sid
cwd: $cwd
created: <ISO time>
---
## Goal
The request and its done condition. Quote the user's direction-setting messages verbatim: requests, corrections, constraints, approvals.
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
elif [ "$event" = UserPromptSubmit ]; then
  msg="[handoff] Context is at ${k}k tokens, above the ${h}k hard limit. Finish the current step. Then write the handoff to $file as the earlier [handoff] message describes, and tell the user to type /clear."
else
  exit 0   # PostToolUse: the reminder waits for the next user prompt
fi

jq -n --arg e "$event" --arg m "$msg" '{hookSpecificOutput: {hookEventName: $e, additionalContext: $m}}'
