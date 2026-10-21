#!/usr/bin/env bash
# SessionStart(clear) hook: loads the handoff that this Claude window wrote after a handoff-nudge.sh
# message into the new session, once. handoff-nudge.sh binds the handoff to the window (PID and
# process start time), so a /clear in another window loads nothing. Handoffs older than 2 h are
# ignored. Claude writes the handoff as its last action, so nothing is copied from the old
# transcript: the header gives its path for details the handoff left out.
#
# Headless runs (claude -p, SDK, workers) never /clear interactively: skip them.
[ "${CLAUDE_CODE_SESSION_ATTENDED:-}" = 1 ] || exit 0
set -u

input=$(cat)
IFS=$'\t' read -r tp sid < <(jq -r '[.transcript_path, .session_id] | @tsv' <<<"$input")
state=$HOME/.claude/handoffs/.state
# handoff-stop.sh marks the /clear it types. A /clear that the user types resets its count.
if [ -e "$state/pid-${CLAUDE_PID:-x}.auto" ]; then
  rm -f "$state/pid-$CLAUDE_PID.auto"
else
  rm -f "$state/pid-${CLAUDE_PID:-x}.cycles"
fi
rec=$state/pid-${CLAUDE_PID:-x}
[ -f "$rec" ] || exit 0
read -r start file _ < "$rec"
rm -f "$rec"   # one /clear consumes the binding, with or without a handoff
[ "$start" = "$(sed 's/.*) //' "/proc/$CLAUDE_PID/stat" 2>/dev/null | cut -d' ' -f20)" ] || exit 0  # PID reused
[ -n "$(find "$file" -maxdepth 0 -mmin -120 2>/dev/null)" ] || exit 0

dir=${file%/*}
old=$(basename "$file" .md)
mtime=$(stat -c %Y "$file")
used=$dir/$old.used.md
otp=${tp%/*}/$old.jsonl

ctx="# Handoff restored after /clear
Source session: $old (full history: claude --resume $old)
Old transcript: $otp (read only the part you need, for a detail the handoff left out)
User messages only: jq -r 'select(.type == \"user\" and (.message.content | type) == \"string\") | .message.content' <transcript>
Written $(( ($(date +%s) - mtime) / 60 )) min ago. File: $used
Other handoffs for this folder: $dir
Before the Next step, give the user every item under ## Owed to the user in visible text. If ## Last reply to the user asks the user a question or for a decision, ask it again.
The handoff holds the old session's claims. Re-check a claim before you build on it when the check is cheap.

$(cat "$file")"
# Cut at the limit, but say so: the last sections (Next step) go first, and the full file stays on disk.
max=40000
(( ${#ctx} <= max )) || ctx="${ctx:0:max}
[handoff] Cut at $max characters. Read the rest of $used before you continue."

jq -n --arg c "$ctx" '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $c}}' \
  && mv "$file" "$used" || exit 0
# Transcript chain for the new session's handoff (handoff-stop.sh lists it): the old session, then
# the 4 newest sessions before it.
if [[ $sid =~ ^[A-Za-z0-9-]+$ ]]; then
  { echo "$otp"; head -n 4 "$state/$old.chain" 2>/dev/null; } > "$state/$sid.chain"
fi
rm -f "$state/$old.chain"
