#!/usr/bin/env bash
# UserPromptSubmit + PostToolUse hook: when the context nears the per-model limit, tells Claude to
# write a handoff file at the next checkpoint, and at the stop limit to write it at once. After the
# handoff, handoff-stop.sh clears the session in tmux (or the user types /clear) and handoff-inject.sh
# loads the file into the new session. Native auto-compaction stays the fallback: autoCompactWindow
# in settings.json must put it above the stop limit (window - 33k buffer).
#
#
# With --manual (the /handoff command runs it in the Bash environment of the session) it skips the
# limits and prints the handoff instructions as plain text. It works outside tmux too: the user then
# types /clear.
manual=; [ "${1:-}" = --manual ] && manual=1
fail() { [ -z "$manual" ] || echo "[handoff] $1"; exit 0; }
# Headless runs (claude -p, SDK, workers) have nobody to type /clear: skip them.
[ "${CLAUDE_CODE_SESSION_ATTENDED:-}" = 1 ] || fail "Not an interactive session: no handoff."
# Outside tmux nothing can clear the session automatically: native auto-compaction handles it.
[ -n "$manual" ] || { [ -n "${TMUX:-}" ] && [ -n "${TMUX_PANE:-}" ]; } || exit 0
set -u

if [ -n "$manual" ]; then
  event='' sid=${CLAUDE_CODE_SESSION_ID:-} cwd=$PWD
  tp=$(find "$HOME/.claude/projects" -mindepth 2 -maxdepth 2 -name "$sid.jsonl" -print -quit 2>/dev/null)
else
  input=$(cat)
  IFS=$'\t' read -r event sid tp cwd < <(jq -r '[.hook_event_name, .session_id, .transcript_path, .cwd] | @tsv' <<<"$input")
fi
[[ $sid =~ ^[A-Za-z0-9-]+$ ]] && [ -r "${tp:-}" ] || fail "No session ID or transcript found: no handoff."

# Context size = input + cache tokens of the last main-chain assistant entry. A compact_boundary after
# it makes that number stale, so it reads as 0 until the next reply.
read -r tokens model < <(tail -c 4000000 "$tp" | jq -Rr '
  fromjson? // empty
  | if .type == "assistant" and .message.usage and (.isSidechain | not) and .message.model != "<synthetic>" then
      "\(.message.usage | (.input_tokens // 0) + (.cache_read_input_tokens // 0) + (.cache_creation_input_tokens // 0)) \(.message.model)"
    elif .subtype == "compact_boundary" then "0 compact"
    else empty end' | tail -n 1)
[[ ${tokens:-} =~ ^[0-9]+$ ]] || { [ -n "$manual" ] && tokens=0 model=unknown; } || exit 0

# shellcheck source=limits.sh
. "${BASH_SOURCE[0]%/*}/limits.sh"
read -r warn hard < <(handoff_limits "$model")
[ -n "$manual" ] || (( tokens >= warn )) || exit 0

file=$HOME/.claude/handoffs/${cwd//[^A-Za-z0-9]/-}/$sid.md
[ -e "$file" ] && fail "The handoff $file exists. End your turn: the Stop hook continues from it."   # handoff written: no more messages
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

template="The handoff replaces this whole conversation for the next session. Keep what governs the next actions: intent, constraints, promises, decisions, uncertainty, and pointers to evidence. Leave out what git and the repository show. Target 1000-1500 words, 2000 at most, one line per bullet. Cut history and repeats first, never a constraint or an open promise.
Rules:
- Carry forward: if this session started from a handoff, copy its still-valid Constraints, Decisions and Next step items. Drop only items that are done or that the user replaced. Mark a replaced decision as REPLACED.
- Quote only short binding user clauses. Use quotes only for exact words, and mark a paraphrase with ~. The user dictates by voice: after a likely misheard word, add [= meaning, confirmed | assumed].
- Never invent a quote, path, result or locator. If a detail is lost, write UNKNOWN and a phrase to search for in the old transcript.
- Do not list finished, intended edits: git shows them. List uncommitted edits that are partial, broken, temporary (debug code to revert), or the user's work to keep.
- Write every section. Write none for an empty section, so the next session knows you checked it.
- status: continue only if approved work remains that needs no user input. Write done if the request is complete and verified, or if a question under ## Next step blocks progress. The hook clears the screen right after your turn, so the user may not read your last reply: put every open answer and question from it under ## Owed to the user.
- Before you write the file, recall from the whole conversation: binding constraints, open questions and promises, partial edits, unverified claims, failed approaches and blockers. The file must hold each one. Do not add a summary.

---
session: $sid
cwd: $cwd
created: <ISO time>
status: continue | done
---
## Goal
The current request and its observable done condition. If there are several tasks, name the active one.
## Constraints
Standing user rules: scope limits and non-goals, forbidden actions, workflow and test rules, answer format. Approvals with their limits (approval to investigate is not approval to edit). Mark each as user-stated or inferred.
## Owed to the user
Always include this section. Every user question or request without a visible answer, and every promise you made (\"I will check X later\"), with partial findings and what remains. An answer that exists only in your reasoning or in this file is owed. Write \"none\" only if nothing remains.
## State
Done, in progress, blocked. For each check: command, result, and the state it covered. A check from before a later edit does not prove that edit. Partial and temporary edits (see Rules). If status is done: complete, or waiting for the user and on what.
## Decisions
DECISION: choice, reason, source (user or agent). FAILED: approach, exact reason, the condition for a retry. Mark replaced decisions.
## Uncertainty
Assumptions you built on but did not verify, open hypotheses, known risks. For each, the check that decides it.
## Facts to keep
Facts that cost tokens to find again: file:line locations, commands, measured numbers, environment quirks. In 1-4 lines, how the relevant code path works or the current root-cause hypothesis.
## Live state
Running processes, background jobs, workers and their IDs, worktrees, temp files, pending approvals, and how to check that each still exists.
## Next step
A prerequisite check, then the exact next action and its stop condition. Then the remaining plan in order, including cleanup of temporary edits. Then any question that blocks progress."

if [ -n "$manual" ]; then
  bind || fail "Cannot bind the handoff to this window (CLAUDE_PID unset): no handoff."
  [ -n "${TMUX:-}" ] && [ -n "${TMUX_PANE:-}" ] || after="Outside tmux: after your turn, the user types /clear and the new session loads the handoff."
  printf '%s\n' "[handoff] The user asked for a handoff now (/handoff). Do not start a new step. Let background jobs run.
$owed
Write the handoff to $file as your last action, then end your turn. $after

$template"
  exit 0
elif (( tokens < hard )); then
  mark warn || exit 0
  bind
  msg="[handoff] Context is at ${k}k tokens. We start a new session soon. At ${h}k a [handoff] message tells you to stop at once.
Continue your work. Plan a checkpoint within about 10k tokens: a finished, verified step. Do not start a sub-task that you cannot finish before it.
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
else
  # Every prompt and tool result until the file exists. Native compaction is the fallback.
  msg="[handoff] Context is at ${k}k tokens, above the ${h}k stop limit. Write the handoff to $file now as the earlier [handoff] message describes, then end your turn."
fi

jq -n --arg e "$event" --arg m "$msg" '{hookSpecificOutput: {hookEventName: $e, additionalContext: $m}}'
