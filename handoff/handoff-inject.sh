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
tp=$(jq -r '.transcript_path' <<<"$input")
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

ctx="# Handoff restored after /clear
Source session: $old (full history: claude --resume $old)
Old transcript: ${tp%/*}/$old.jsonl (read only the part you need, for a detail the handoff left out)
Written $(( ($(date +%s) - mtime) / 60 )) min ago. File: $used
Other handoffs for this folder: $dir

$(cat "$file")"

jq -n --arg c "${ctx:0:40000}" '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $c}}' \
  && mv "$file" "$used"
