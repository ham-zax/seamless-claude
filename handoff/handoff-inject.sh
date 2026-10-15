#!/usr/bin/env bash
# SessionStart(clear) hook: loads the handoff that this Claude window wrote after a handoff-nudge.sh
# message into the new session, once. handoff-nudge.sh binds the handoff to the window (PID and
# process start time), so a /clear in another window loads nothing. Handoffs older than 2 h are
# ignored. The old transcript after the handoff was written is appended mechanically, so a late turn
# is not lost.
#
# Headless runs (claude -p, SDK, workers) never /clear interactively: skip them.
[ "${CLAUDE_CODE_SESSION_ATTENDED:-}" = 1 ] || exit 0
set -u

input=$(cat)
tp=$(jq -r '.transcript_path' <<<"$input")
rec=$HOME/.claude/handoffs/.state/pid-${CLAUDE_PID:-x}
[ -f "$rec" ] || exit 0
read -r start file < "$rec"
rm -f "$rec"   # one /clear consumes the binding, with or without a handoff
[ "$start" = "$(sed 's/.*) //' "/proc/$CLAUDE_PID/stat" 2>/dev/null | cut -d' ' -f20)" ] || exit 0  # PID reused
[ -n "$(find "$file" -maxdepth 0 -mmin -120 2>/dev/null)" ] || exit 0

dir=${file%/*}
old=$(basename "$file" .md)
mtime=$(stat -c %Y "$file")
since=$(date -u -d "@$mtime" +%Y-%m-%dT%H:%M:%S)
used=$dir/$old.used.md

# Turns after the handoff: user text and assistant text verbatim, tool calls as one-line briefs.
tail_text=""
old_tp=${tp%/*}/$old.jsonl
if [ -r "$old_tp" ]; then
  tail_text=$(jq -Rr --arg since "$since" '
    fromjson? // empty
    | select((.timestamp // "") > $since and (.isSidechain | not) and (.isMeta | not))
    | if .type == "user" then
        .message.content | if type == "string" then . else (.[]? | select(.type == "text") | .text) end
        | select(test("^<(command-|local-command|system-reminder)") | not) | "USER: " + .[0:1500]
      elif .type == "assistant" then
        .message.content[]?
        | if .type == "text" then "ASSISTANT: " + .text[0:1500]
          elif .type == "tool_use" then "TOOL \(.name): " + (.input | tostring | .[0:150])
          else empty end
      else empty end' "$old_tp" | tail -c 6000)
fi

ctx="# Handoff restored after /clear
Source session: $old (full history: claude --resume $old)
Written $(( ($(date +%s) - mtime) / 60 )) min ago. File: $used
Other handoffs for this folder: $dir

$(cat "$file")"
[ -n "$tail_text" ] && ctx+="

## After the handoff (old transcript tail, mechanical copy)
$tail_text"

jq -n --arg c "${ctx:0:40000}" '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $c}}' \
  && mv "$file" "$used"
