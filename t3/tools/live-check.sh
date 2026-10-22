#!/usr/bin/env bash
# Live check of the T3 handoff cycle with Haiku (Phase 3, ../results/2026-10-22-e2e.md). Needs the
# running T3 server and the hooks from ../install.sh. Starts one new thread "t3 live-check", runs two
# handoff cycles (done, then continue) and checks the thread messages and the provider log.
# --restart also restarts the T3 server and checks the context after it. Other open threads stop for
# about 20 s. Exit 0 = all checks pass, 1 = a check failed, 2 = usage or setup error.
set -u
restart=0
case ${1:-} in
  --restart) restart=1 ;;
  '') ;;
  *) echo "usage: $0 [--restart]" >&2; exit 2 ;;
esac
rt=$HOME/.t3/userdata/server-runtime.json
model=claude-haiku-5-5
t3dir=$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)
now=$t3dir/hooks/handoff-now.sh
fails=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fails=$((fails + 1)); }
cli() { readlink "/proc/$(jq -r .pid "$rt")/exe"; }

[ -f "$rt" ] || { echo "T3 server not running ($rt missing)" >&2; exit 2; }
jq -e --arg d "${now%/*}/" '[.hooks[][] | .hooks[].command | select(startswith($d))] | length == 4' \
  ~/.claude/settings.json > /dev/null || { echo "T3 hooks not installed: run t3/install.sh" >&2; exit 2; }
T3=$(cli)
echo "T3 $(jq -r .serverVersion "$rt"), model $model"

# show_until <k>: waits until the thread is idle after cycle k: k `/compact` messages, a user prompt
# after the last one, and an assistant reply last. Prints the thread JSON. A message count is not
# enough: a reply can be split into more messages while it streams.
show_until() {
  local j _
  for _ in $(seq 60); do
    j=$(timeout 30 "$T3" thread show "$id" --json 2>/dev/null)
    jq -e --argjson k "$1" '.thread.status == "completed" and (.messages as $m
      | [$m | to_entries[] | select(.value.role == "user" and .value.text == "/compact") | .key] as $c
      | ($c | length) >= $k
      and ([$m | to_entries[] | select(.value.role == "user") | .key] | last) > ($c | last)
      and ($m | last | .role) == "assistant")' <<<"$j" > /dev/null 2>&1 && break
    sleep 5
  done
  printf '%s' "$j"
}
# texts <json> <from>: user and assistant texts from message <from>, one per line.
texts() { jq -r --argjson f "$2" '.messages[$f:][] | "[\(.role)] \(.text // "" | gsub("\n"; " "))"' <<<"$1"; }

# Cycle 1: status done → /compact, then the owed prompt.
start=$(cd "$t3dir/.." && timeout 300 "$T3" thread start . "t3 live-check. Remember the code word KIWI-42. \
Say 1 with the code word. Then run $now in Bash, follow its instructions, write the handoff with \
status: done, and end the turn." --provider claudeAgent --model "$model" --wait --json) ||
  { echo "thread start failed. If no T3 project contains $t3dir/.., run: \"$T3\" project add $(cd "$t3dir/.." && pwd)" >&2; exit 2; }
id=$(jq -r .threadId <<<"$start")
echo "thread $id"
j=$(show_until 1)
t=$(texts "$j" 1)
if grep -qx '\[user\] /compact' <<<"$t"; then ok "cycle 1: /compact queued"; else bad "cycle 1: /compact queued"; fi
if grep -q '^\[user\] .*Owed to the user' <<<"$t"; then ok "cycle 1: owed prompt for status done"; else bad "cycle 1: owed prompt for status done"; fi

# Cycle 2: status continue → /compact, then "Continue from the handoff."; the agent says 3 alone.
n=$(jq '.messages | length' <<<"$j")
timeout 300 "$T3" thread send "$id" "Say 2 with the code word. Then run $now again, write the handoff \
with status: continue (the next step is: say 3 with the code word, then stop), and end the turn." --wait --json > /dev/null
j=$(show_until 2)
t=$(texts "$j" "$((n + 1))")
if grep -qx '\[user\] /compact' <<<"$t"; then ok "cycle 2: /compact queued"; else bad "cycle 2: /compact queued"; fi
if grep -qx '\[user\] Continue from the handoff\.' <<<"$t"; then ok "cycle 2: continue prompt"; else bad "cycle 2: continue prompt"; fi
if tail -n 1 <<<"$t" | grep -q '3.*KIWI-42'; then ok "cycle 2: agent continued alone"; else bad "cycle 2: agent continued alone"; fi

# shellcheck disable=SC2012  # T3 log names have no spaces
log=$(ls -t "$HOME/.t3/userdata/logs/provider/events.${id//:/-}".log* 2>/dev/null | head -n 1)
c=$(grep -o 'Handoff restored after compaction of this T3 thread' "$log" 2>/dev/null | wc -l)
if (( c >= 2 )); then ok "handoff injected $c times"; else bad "handoff injected $c times (want 2)"; fi
s=$(grep -o '"session_id":"[0-9a-f-]*"' "$log" 2>/dev/null | sort -u | wc -l)
if (( s == 1 )); then ok "one session id in the thread"; else bad "$s session ids in the thread (want 1)"; fi

if (( restart )); then
  old=$(jq -r .pid "$rt")
  # Linux service (F1b): systemd restarts it. WSL desktop app: the app restarts it after a TERM.
  if [ "$(jq -r '.serviceManaged // false' "$rt")" = true ]; then
    systemctl --user restart t3code.service
  else
    kill -TERM "$old"
  fi
  for _ in $(seq 60); do
    p=$(jq -r .pid "$rt" 2>/dev/null) && [ "$p" != "$old" ] && kill -0 "$p" 2>/dev/null && break
    sleep 5
  done
  sleep 10
  T3=$(cli)
  r=$(timeout 240 "$T3" thread send "$id" "Which number did you say last, and what is the code word? \
Answer from memory, do not read files." --wait --json | jq -r .reply)
  if grep -q '3' <<<"$r" && grep -q 'KIWI-42' <<<"$r"; then ok "context kept after server restart"; else bad "context after restart: $r"; fi
fi

[ -s "$HOME/.claude/handoffs/.state/t3-send.log" ] && echo "note: t3-send.log: $(tail -n 1 "$HOME/.claude/handoffs/.state/t3-send.log")"
echo "Thread $id stays in T3. Delete it there if you want."
if (( fails )); then echo "$fails check(s) failed"; exit 1; fi
echo "all checks pass"
