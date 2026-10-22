#!/usr/bin/env bash
# Stop hook for T3 Code: after Claude wrote this session's handoff, compacts the same thread and
# continues without the user. /clear is not used: after a server restart T3 resumes the session from
# before the first /clear (R1). Compaction keeps the session id (F4).
# ../handoff/handoff-stop.sh still does the checks and writes the record into the handoff. Outside
# tmux it ends with "Handoff written. Type /clear" (H3): that line is the signal that a handoff is ready.
# Then this hook queues two turns with `t3 thread send` (F2, F3): /compact, then the continue prompt.
# handoff-inject.sh, through inject.sh, loads the handoff between them. Outside T3 it does nothing.
# shellcheck source=lib.sh
. "${BASH_SOURCE[0]%/*}/lib.sh"
t3_session || exit 0
input=$(cat)
out=$(env -u TMUX -u TMUX_PANE CLAUDE_CODE_SESSION_ATTENDED=1 "$t3_handoff_dir/handoff-stop.sh" <<<"$input")
if ! jq -e '.systemMessage // "" | startswith("[handoff] Handoff written.")' <<<"$out" > /dev/null 2>&1; then
  [ -z "$out" ] || printf '%s\n' "$out"   # block decision or nothing
  exit 0
fi

say() { jq -nc --arg m "[handoff] $1" '{systemMessage: $m}'; }
sid=$(jq -r .session_id <<<"$input")
state=$HOME/.claude/handoffs/.state
read -r start file _ < "$state/pid-$CLAUDE_PID"
status=$(awk 'NR == 1 && $0 != "---" { exit } NR > 1 && $0 == "---" { exit } $1 == "status:" { print $2; exit }' "$file")
case $status in
  continue) prompt="Continue from the handoff." ;;
  *)        prompt="Show me only what the handoff lists under ## Owed to the user. Do not start the Next step." ;;
esac
manual="Press Compact in T3, then send: $prompt"

# Same limit as handoff-stop.sh (H9): 10 automatic cycles per window. A compaction that this hook did
# not start resets the count (handoff-inject.sh, no .auto marker).
max=10
cycles=$state/pid-$CLAUDE_PID.cycles
n=0
if [ -f "$cycles" ]; then
  read -r cstart cn < "$cycles"
  [ "$cstart" = "$start" ] && [[ $cn =~ ^[0-9]+$ ]] && n=$cn
fi
if (( n >= max )); then
  say "Handoff written. Automatic compaction limit reached ($n of $max in this thread). $manual"
  exit 0
fi
thread=$(t3_thread_id "$sid") || { say "Handoff written. This T3 thread was not found (t3/README.md). $manual"; exit 0; }
cli=$(t3_cli)
# One trigger per handoff: Stop can fire again before the compaction.
(set -o noclobber; : > "$state/pid-$CLAUDE_PID.auto") 2>/dev/null || exit 0
printf '%s %s\n' "$start" $((n + 1)) > "$cycles"

# Detached: the turn is still running while this hook runs (F3). The second send waits in the queue (F2).
# shellcheck disable=SC2016  # the helper expands its own arguments
setsid -f bash -c '
  log() { printf "%s pid %s thread %s: %s\n" "$(date "+%F %T")" "$5" "$2" "$1" >> "$4"; }
  timeout 60 "$1" thread send "$2" /compact > /dev/null 2>&1 || { log "send /compact failed"; rm -f "${4%/*}/pid-$5.auto"; exit 0; }
  timeout 60 "$1" thread send "$2" "$3" > /dev/null 2>&1 || log "send prompt failed"
' t3-handoff "$cli" "$thread" "$prompt" "$state/t3-send.log" "$CLAUDE_PID" < /dev/null > /dev/null 2>&1
if [ "$status" = continue ]; then next="then continues"; else next="then shows what is owed and waits for you"; fi
say "Handoff written. Compacting this thread, $next (cycle $((n + 1)))."
