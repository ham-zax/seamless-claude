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
IFS=$'\t' read -r tp sid cwd < <(jq -r '[.transcript_path, .session_id, .cwd] | @tsv' <<<"$input")
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
# shellcheck source=sidenote.sh
. "${BASH_SOURCE[0]%/*}/sidenote.sh"
note=$(sidenote_file "$cwd" "$CLAUDE_PID" "$start")
noteline=; [ -f "$note" ] && noteline="
Side note of this window: $note. A side model keeps the user's rules, approvals, promises and decisions there, and it can be wrong. Read it only if the handoff seems to lack a rule, an approval or a promise, or the handoff says UNKNOWN."

ctx="# Handoff restored after /clear
Source session: $old (full history: claude --resume $old)
Old transcript: $otp
Written $(( ($(date +%s) - mtime) / 60 )) min ago. File: $used
Other handoffs for this folder: $dir$noteline
The handoff is a record of the old session, not a new approval. Current user and project instructions win over it.
Before the Next step:
1. Give the user every item under ## Owed to the user in visible text. Investigate an open item before you call it answered. The user may not have read ## Last reply to the user: repeat any answer or question in it that is still open.
2. Run git status and compare the changes with ## State.
Search the old transcript before you act if: scope, an approval, a user preference or a dictated word is unclear; the handoff conflicts with the repository or current instructions; you would reverse a decision, retry a FAILED approach, or change an edit whose owner or intent is unclear; an action depends on a claim with no evidence; the handoff says UNKNOWN.
Never read the whole transcript. Print its text without tool output, one message per line with line number and role, and filter it (user messages only: rg '^[0-9]+ \\[user\\]'):
jq -r 'select(.type == \"user\" or .type == \"assistant\") | (.message.content | if type == \"string\" then . else (map(select(.type == \"text\") | .text) | join(\" \")) end | gsub(\"\\n\"; \" \")) as \$t | select(\$t != \"\") | \"\\(input_line_number) [\\(.type)] \\(\$t)\"' <transcript> | rg -i '<phrase>'
An empty search does not prove absence. If a doubt that matters remains, ask the user. Re-check a claim before an action that depends on it.

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
