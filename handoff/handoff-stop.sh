#!/usr/bin/env bash
# Stop hook: when Claude ends a turn after it wrote this session's handoff, starts the next session
# without the user. With "status: continue" it also types a prompt to continue. With "status: done"
# the new session waits for the user. Clearing after every handoff keeps it current: no turn runs
# after it. A hook cannot run /clear, so a detached helper types
# /clear into this tmux pane, waits for handoff-inject.sh to load the handoff, then types a prompt
# to continue. Outside tmux, or after the automatic clear limit, the user types /clear.
#
# Headless runs (claude -p, SDK, workers): skip them.
[ "${CLAUDE_CODE_SESSION_ATTENDED:-}" = 1 ] || exit 0
set -u

IFS=$'\t' read -r sid active < <(jq -r '[.session_id, (.stop_hook_active // false)] | @tsv' 2>/dev/null)
[[ $sid =~ ^[A-Za-z0-9-]+$ ]] || exit 0
state=$HOME/.claude/handoffs/.state
rec=$state/pid-${CLAUDE_PID:-x}
[ -f "$rec" ] || exit 0
read -r start file model < "$rec"
[ "$start" = "$(sed 's/.*) //' "/proc/$CLAUDE_PID/stat" 2>/dev/null | cut -d' ' -f20)" ] || exit 0  # PID reused
[ "${file##*/}" = "$sid.md" ] && [ -f "$file" ] || exit 0   # this session's handoff, not yet loaded
# The section makes Claude check what the user has not seen yet. Block once: stop_hook_active is set
# on the retry, so a handoff without the section cannot loop.
if [ "$active" != true ] && ! grep -q '^## Owed to the user' "$file"; then
  jq -n --arg f "$file" '{decision: "block", reason: "[handoff] The handoff \($f) has no \"## Owed to the user\" section. Add it: every user question not yet answered in a visible reply, or \"none\". If a short answer is owed, give it in visible text now. Then end your turn."}'
  exit 0
fi
status=$(awk 'NR == 1 && $0 != "---" { exit } NR > 1 && $0 == "---" { exit } $1 == "status:" { print $2; exit }' "$file")
case $status in
  continue) prompt="Continue from the handoff." ;;
  done)     prompt="" ;;
  *)        exit 0 ;;
esac

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

# The helper owns the rest of the cycle and ends within about 95 s. It types only after Claude is
# idle, and the prompt only after the /clear removed the binding. Keys typed while the user types
# would mix with the user's keys: it types only after 2 s without client input (tmux
# client_activity), and gives up after 30 s of activity.
# shellcheck disable=SC2016  # the helper expands its own arguments
setsid -f bash -c '
  quiet() {
    local last
    for _ in $(seq 60); do
      last=$(tmux list-clients -t "$1" -F "#{client_activity}" 2>/dev/null | sort -n | tail -n 1)
      [ -z "$last" ] || (( $(date +%s) - last >= 2 )) && return 0
      sleep 0.5
    done
    return 1
  }
  sleep 2
  quiet "$1" || exit 0
  tmux send-keys -t "$1" -l /clear && tmux send-keys -t "$1" Enter || exit 0
  for _ in $(seq 60); do [ -e "$2" ] || break; sleep 0.5; done
  [ -e "$2" ] && exit 0
  [ -n "$3" ] || exit 0
  sleep 1
  quiet "$1" || exit 0
  tmux send-keys -t "$1" -l "$3" && tmux send-keys -t "$1" Enter
' handoff-clear "$TMUX_PANE" "$rec" "$prompt" < /dev/null > /dev/null 2>&1
if [ -n "$prompt" ]; then next="continuing in a new session"; else next="the new session waits for you"; fi
say "Handoff written. Clearing, $next (cycle $((n + 1))). If you type in this pane, the hook waits. After 30 s of typing it gives up: then type /clear."
