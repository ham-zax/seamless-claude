#!/usr/bin/env bash
# Stop hook: when Claude ends a turn after it wrote this session's handoff with "status: continue",
# starts the next session without the user. A hook cannot run /clear, so a detached helper types
# /clear into this tmux pane, waits for handoff-inject.sh to load the handoff, then types a prompt
# to continue. Outside tmux, or after the automatic clear limit, the user types /clear.
#
# Headless runs (claude -p, SDK, workers): skip them.
[ "${CLAUDE_CODE_SESSION_ATTENDED:-}" = 1 ] || exit 0
set -u

sid=$(jq -r '.session_id' 2>/dev/null)
[[ $sid =~ ^[A-Za-z0-9-]+$ ]] || exit 0
state=$HOME/.claude/handoffs/.state
rec=$state/pid-${CLAUDE_PID:-x}
[ -f "$rec" ] || exit 0
read -r start file model < "$rec"
[ "$start" = "$(sed 's/.*) //' "/proc/$CLAUDE_PID/stat" 2>/dev/null | cut -d' ' -f20)" ] || exit 0  # PID reused
[ "${file##*/}" = "$sid.md" ] && [ -f "$file" ] || exit 0   # this session's handoff, not yet loaded
status=$(awk 'NR == 1 && $0 != "---" { exit } NR > 1 && $0 == "---" { exit } $1 == "status:" { print $2; exit }' "$file")
[ "$status" = continue ] || exit 0

say() { jq -n --arg m "[handoff] $1" '{systemMessage: $m}'; }
if [ -z "${TMUX:-}" ] || [ -z "${TMUX_PANE:-}" ]; then
  say "Handoff written. Type /clear to continue in a new session."
  exit 0
fi
case $model in
  *haiku*) max=0 ;;   # no limit
  *)       max=5 ;;
esac
cycles=$state/pid-$CLAUDE_PID.cycles
n=0
if [ -f "$cycles" ]; then
  read -r cstart cn < "$cycles"
  [ "$cstart" = "$start" ] && [[ $cn =~ ^[0-9]+$ ]] && n=$cn
fi
if (( max && n >= max )); then
  say "$max automatic clears in this window. Type /clear to continue in a new session."
  exit 0
fi
# One trigger per handoff: Stop can fire again before the /clear arrives. handoff-inject.sh removes
# the marker when it loads the handoff.
(set -o noclobber; : > "$state/pid-$CLAUDE_PID.auto") 2>/dev/null || exit 0
printf '%s %s\n' "$start" $((n + 1)) > "$cycles"

# The helper owns the rest of the cycle and ends within about 35 s. It types only after Claude is
# idle, and the prompt only after the /clear removed the binding.
# shellcheck disable=SC2016  # the helper expands its own arguments
setsid -f bash -c '
  sleep 2
  tmux send-keys -t "$1" -l /clear && tmux send-keys -t "$1" Enter || exit 0
  for _ in $(seq 60); do [ -e "$2" ] || break; sleep 0.5; done
  [ -e "$2" ] && exit 0
  sleep 1
  tmux send-keys -t "$1" -l "Continue from the handoff." && tmux send-keys -t "$1" Enter
' handoff-clear "$TMUX_PANE" "$rec" < /dev/null > /dev/null 2>&1
say "Handoff written. Clearing and continuing in a new session (cycle $((n + 1)))."
