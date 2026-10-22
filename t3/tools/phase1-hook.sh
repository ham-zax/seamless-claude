#!/usr/bin/env bash
# Phase 1 test hook (PLAN.md, Phase 1). Register for SessionStart and Stop during the test only.
# Logs the process ancestry of $CLAUDE_PID. On Stop, if the trigger file
# ~/.claude/handoffs/.state/t3-phase1.trigger names this session's T3 thread, it consumes the file
# and queues "/compact" and a second prompt with `t3 thread send`, detached, from inside the hook.
log=$HOME/.claude/handoffs/.state/t3-phase1.log
trigger=$HOME/.claude/handoffs/.state/t3-phase1.trigger
input=$(cat)
event=$(jq -r .hook_event_name <<<"$input")
sid=$(jq -r .session_id <<<"$input")

# Ancestry: walk up from CLAUDE_PID, keep the first exe under ~/.t3/wsl-runtime/.
chain=() t3exe=
p=${CLAUDE_PID:-}
for _ in 1 2 3 4 5 6 7 8; do
  [ -n "$p" ] && [ "$p" -gt 1 ] 2>/dev/null || break
  exe=$(readlink "/proc/$p/exe" 2>/dev/null)
  chain+=("$p:${exe##*/}")
  case $exe in "$HOME"/.t3/wsl-runtime/*) t3exe=$exe; break ;; esac
  p=$(awk '{print $4}' "/proc/$p/stat" 2>/dev/null)
done
jq -nc --arg e "$event" --arg s "$sid" --arg src "$(jq -r '.source // empty' <<<"$input")" \
  --arg pid "${CLAUDE_PID:-}" --arg t3 "$t3exe" --arg chain "${chain[*]}" \
  '{t: (now | todate), event: $e, source: $src, sid: $s, CLAUDE_PID: $pid, t3exe: $t3, chain: $chain}' >> "$log"

if [ "$event" = Stop ] && [ -n "$t3exe" ] && [ -f "$trigger" ]; then
  read -r thread < "$trigger"
  rm -f "$trigger"
  # Detached so the Stop hook returns at once; the turn is still running when send is called.
  # shellcheck disable=SC2016  # $1..$3 expand in the inner shell
  setsid bash -c '
    "$1" thread send "$2" "/compact" --json >> "$3" 2>&1
    "$1" thread send "$2" "Reply with the word SECOND only. Do not use tools." --json >> "$3" 2>&1
  ' _ "$t3exe" "$thread" "$log.send" < /dev/null > /dev/null 2>&1 &
  echo "{\"t\":\"$(date -u +%FT%TZ)\",\"event\":\"queued\",\"thread\":\"$thread\"}" >> "$log"
fi
exit 0
