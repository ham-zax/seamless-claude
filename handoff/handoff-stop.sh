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

input=$(cat)
IFS=$'\t' read -r sid active < <(jq -r '[.session_id, (.stop_hook_active // false)] | @tsv' <<<"$input" 2>/dev/null)
[[ $sid =~ ^[A-Za-z0-9-]+$ ]] || exit 0
state=$HOME/.claude/handoffs/.state
rec=$state/pid-${CLAUDE_PID:-x}
[ -f "$rec" ] || exit 0
read -r start file _ < "$rec"
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

# Hook-owned record at the end of the handoff, replaced on every Stop until the /clear: the final
# visible reply (written after the handoff, so the handoff cannot hold it) and the transcripts of the
# sessions before this one (handoff-inject.sh keeps the list in <session-id>.chain). Pointers only:
# the next session reads a transcript when it needs a detail.
marker='<!-- handoff-stop.sh: record below, replaced on every Stop -->'
reply=$(jq -r '.last_assistant_message // empty' <<<"$input")
max_reply=6000
(( ${#reply} <= max_reply )) || reply="${reply:0:max_reply}
[handoff] Cut at $max_reply characters. The full reply is the last assistant message in the old transcript."
{
  awk -v m="$marker" '$0 == m { exit } { print }' "$file"
  printf '%s\n' "$marker"
  if [ -n "$reply" ]; then
    printf '## Last reply to the user\nThe old session gave this reply after it wrote the handoff. The user saw it before the /clear.\n\n%s\n' "$reply"
  fi
  if [ -s "$state/$sid.chain" ]; then
    printf '## Earlier transcripts\nSessions before the old session, newest first:\n'
    sed 's/^/- /' "$state/$sid.chain"
  fi
} > "$file.tmp" && mv "$file.tmp" "$file"

say() { jq -n --arg m "[handoff] $1" '{systemMessage: $m}'; }
if [ -z "${TMUX:-}" ] || [ -z "${TMUX_PANE:-}" ]; then
  say "Handoff written. Type /clear to continue in a new session."
  exit 0
fi
# Every model: after max automatic clears the hook pauses once. The user's /clear resets the count
# (handoff-inject.sh), and the next max clears run automatically again.
max=7
cycles=$state/pid-$CLAUDE_PID.cycles
n=0
if [ -f "$cycles" ]; then
  read -r cstart cn < "$cycles"
  [ "$cstart" = "$start" ] && [[ $cn =~ ^[0-9]+$ ]] && n=$cn
fi
if (( n >= max )); then
  say "$max automatic clears in this window. Type /clear to continue in a new session."
  exit 0
fi
# One trigger per handoff: Stop can fire again before the /clear arrives. handoff-inject.sh removes
# the marker when it loads the handoff.
(set -o noclobber; : > "$state/pid-$CLAUDE_PID.auto") 2>/dev/null || exit 0
printf '%s %s\n' "$start" $((n + 1)) > "$cycles"

# The helper owns the rest of the cycle and ends within about 95 s. It types only after Claude is
# idle, and the prompt only after the /clear removed the binding. Keys typed while the user types
# would mix with the user's keys: it types only after 2 s without input from a tmux client that shows
# this pane (client_activity of clients whose current pane is this pane), and gives up after 30 s of
# activity. Input in other panes or windows does not count. Each give-up appends one line to
# clear.log in the state directory.
# shellcheck disable=SC2016  # the helper expands its own arguments
setsid -f bash -c '
  quiet() {
    local last
    for _ in $(seq 60); do
      last=$(tmux list-clients -t "$1" -F "#{client_activity} #{pane_id}" 2>/dev/null |
        awk -v p="$1" '"'"'$2 == p { print $1 }'"'"' | sort -n | tail -n 1)
      [ -z "$last" ] || (( $(date +%s) - last >= 2 )) && return 0
      sleep 0.5
    done
    return 1
  }
  # An unsent draft would turn "/clear" into "draft/clear". Esc Esc clears the input box (C-l does
  # not, Claude Code 2.1.307). The typed x keeps the box non-empty: Esc Esc on an empty box opens
  # Rewind. The second round covers an open @-mention menu, where the first Esc only closes the menu.
  clr() {
    for _ in 1 2; do
      tmux send-keys -t "$1" -l x && tmux send-keys -t "$1" Escape Escape || return 1
      sleep 0.3
    done
  }
  give_up() { printf "%s pane %s pid %s: %s\n" "$(date "+%F %T")" "$1" "$5" "$6" >> "$4"; exit 0; }
  sleep 2
  quiet "$1" || give_up "$@" "input for 30 s, /clear not typed"
  clr "$1" && tmux send-keys -t "$1" -l /clear && tmux send-keys -t "$1" Enter || give_up "$@" "send-keys /clear failed"
  for _ in $(seq 60); do [ -e "$2" ] || break; sleep 0.5; done
  [ -e "$2" ] && give_up "$@" "handoff not loaded 30 s after /clear"
  [ -n "$3" ] || exit 0
  sleep 1
  quiet "$1" || give_up "$@" "input for 30 s, prompt not typed"
  clr "$1" && tmux send-keys -t "$1" -l "$3" && tmux send-keys -t "$1" Enter || give_up "$@" "send-keys prompt failed"
' handoff-clear "$TMUX_PANE" "$rec" "$prompt" "$state/clear.log" "$CLAUDE_PID" < /dev/null > /dev/null 2>&1
if [ -n "$prompt" ]; then next="continuing in a new session"; else next="the new session waits for you"; fi
say "Handoff written. Clearing, $next (cycle $((n + 1))). If you type in this pane, the hook waits. After 30 s of typing it gives up: then type /clear. The hook deletes unsent text in the input box before it types."
