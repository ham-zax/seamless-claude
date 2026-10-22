#!/bin/sh
# Stop hook (async + asyncRewake): keeps the prompt cache warm while an interactive session
# sits idle. It runs the cachebeat watcher. Exit 2 wakes Claude for one short turn, and the
# Stop of that turn starts this hook again (beat.sh treats it as a re-arm, the deadline stays).
#
# Headless runs (claude -p, SDK, workers) wait for async hooks before they exit: skip them.
[ "$CLAUDE_CODE_SESSION_ATTENDED" = 1 ] || exit 0
[ -n "$CLAUDE_CODE_SESSION_ID" ] && [ -n "$CLAUDE_PID" ] || exit 0
cat > /dev/null   # hook input: unused, the environment has the session id

BEAT="$HOME/.claude/skills/cachebeat/beat.sh"
IDLE_MIN=${CACHEBEAT_IDLE_MIN:-50}   # 1 h cache TTL: beat before it expires
MAX_HOURS=4                          # the hook "timeout" in settings.json must exceed this

while :; do
  sh "$BEAT" "$IDLE_MIN" "$MAX_HOURS" > /dev/null &
  bp=$!
  # Claude Code leaves async hooks running when the session quits: stop with the session.
  while kill -0 "$bp" 2>/dev/null; do
    kill -0 "$CLAUDE_PID" 2>/dev/null || { kill "$bp"; exit 0; }
    sleep 30
  done
  wait "$bp"; rc=$?
  case $rc in
    0) # /clear keeps the Claude process but starts a new session: a watcher of the old
       # session sees a dead transcript and would wake the live session mid-work.
       live=$(jq -r '.sessionId // empty' "$HOME/.claude/sessions/$CLAUDE_PID.json" 2>/dev/null)
       [ -n "$live" ] && [ "$live" != "$CLAUDE_CODE_SESSION_ID" ] && exit 0
       echo "cachebeat: idle keep-warm turn. Reply with . only." >&2; exit 2 ;;
    6) ;;        # run cap: start again, the deadline stays
    *) exit 0 ;; # 3 deadline, 4 uncached beat, 5 no state, 7 superseded
  esac
done
