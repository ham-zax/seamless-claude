#!/usr/bin/env bash
# Offline tests for t3/hooks and t3/install.sh. No T3 server, no model calls. HOME points at a temp
# dir. A copy of bash named t3 under the fake runtime folder stands in for the T3 server: its child
# process is the Claude window (CLAUDE_PID). A fake CLI records the `t3 thread` calls.
set -u
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
# shellcheck disable=SC2329  # runs from the EXIT trap
cleanup() { xargs -r kill < "$tmp/pids" 2>/dev/null; rm -rf "$tmp"; }
trap cleanup EXIT
export HOME=$tmp CLAUDE_CODE_SESSION_ATTENDED=0 CLAUDE_CODE_ENTRYPOINT=sdk-ts
unset TMUX TMUX_PANE HANDOFF_NOTE
export T3_HANDOFF_RUNTIME=$tmp/.t3/wsl-runtime T3_HANDOFF_USERDATA=$tmp/.t3/userdata T3_HANDOFF_CLI=$tmp/fake-t3
state=$HOME/.claude/handoffs/.state
proj=$tmp/projects/-work
hdir=$HOME/.claude/handoffs/-work
mkdir -p "$proj" "$T3_HANDOFF_RUNTIME/sha256-x" "$T3_HANDOFF_USERDATA/logs/provider"
fail=0

check() {   # name; reads the status of the previous condition
  # shellcheck disable=SC2319  # intended: the caller's condition status
  local status=$?
  if [ "$status" = 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi
}

# Fake T3 server: a bash copy under the runtime folder. "sleep; :" keeps bash from exec-ing sleep.
cp "$(command -v bash)" "$T3_HANDOFF_RUNTIME/sha256-x/t3"
window() {   # prints the pid of a new Claude window under the fake server
  local server child
  "$T3_HANDOFF_RUNTIME/sha256-x/t3" -c 'sleep 600; :' < /dev/null > /dev/null 2>&1 & server=$!
  echo "$server" >> "$tmp/pids"
  for _ in $(seq 50); do child=$(pgrep -P "$server" | head -n 1); [ -n "$child" ] && break; sleep 0.1; done
  echo "$child" >> "$tmp/pids"
  echo "$child"
}

# Fake CLI: `thread show` knows only thread mcp:abc-1. Every call goes to cli.log.
cat > "$T3_HANDOFF_CLI" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$tmp/cli.log"
[ "\$1 \$2" != "thread show" ] || [ "\$3" = mcp:abc-1 ]
EOF
chmod +x "$T3_HANDOFF_CLI"
sends() { grep -c '^thread send' "$tmp/cli.log" 2>/dev/null || echo 0; }
wait_sends() { for _ in $(seq 50); do [ "$(sends)" -ge "$1" ] && return 0; sleep 0.1; done; return 1; }

transcript() {   # <file> <tokens>
  jq -nc --argjson t "$2" '{type: "assistant", timestamp: "2026-01-01T00:00:00Z", message: {model: "claude-haiku-5-5",
    usage: {input_tokens: 10, cache_read_input_tokens: ($t - 10), cache_creation_input_tokens: 0}}}' > "$1"
}
nudge() {   # sid tokens
  transcript "$proj/$1.jsonl" "$2"
  jq -nc --arg s "$1" --arg t "$proj/$1.jsonl" '{hook_event_name: "PostToolUse", session_id: $s, transcript_path: $t, cwd: "/work"}' |
    "$here/hooks/nudge.sh" | jq -r '.hookSpecificOutput.additionalContext // empty'
}
stop() { jq -nc --arg s "$1" '{hook_event_name: "Stop", session_id: $s, stop_hook_active: false, last_assistant_message: "bye"}' | "$here/hooks/stop.sh"; }
inject() {   # sid [source]
  jq -nc --arg s "$1" --arg src "${2:-compact}" --arg t "$proj/$1.jsonl" '{hook_event_name: "SessionStart", source: $src, session_id: $s, transcript_path: $t, cwd: "/work"}' |
    "$here/hooks/inject.sh" | jq -r '.hookSpecificOutput.additionalContext // empty'
}
handoff() {   # sid status [no-owed]
  local owed=$'## Owed to the user\nnone'
  [ -z "${3:-}" ] || owed=
  printf -- '---\nsession: %s\nstatus: %s\n---\n## Goal\ntest\n%s\n## Next step\nstep\n' "$1" "$2" "$owed" > "$hdir/$1.md"
}

# --- outside T3: every hook stays silent ---
export CLAUDE_PID=$$
[ -z "$(nudge o1 99000)" ]; check "outside T3: nudge silent at the stop limit"
mkdir -p "$hdir"; handoff o1 continue
[ -z "$(stop o1)" ] && [ -z "$(inject o1)" ]; check "outside T3: stop and inject silent"
[ "$(sends)" = 0 ]; check "outside T3: no t3 calls"

# --- T3 window, first cycle ---
CLAUDE_PID=$(window)
echo "\"s1\"" > "$T3_HANDOFF_USERDATA/logs/provider/events.mcp-abc-1.log"
[ -z "$(nudge s1 50000)" ]; check "T3: below warn, no message"
out=$(nudge s1 91000)
[[ $out == *"91k"*"write the handoff to: $hdir/s1.md"*"compacts this T3 thread"* && $out != *"clears the session"* ]]; check "T3: warn message names the handoff and compaction"
[ -f "$state/pid-$CLAUDE_PID" ]; check "T3: warn binds the handoff to the window"
[ -z "$(stop s1)" ]; check "T3: stop before the handoff exists does nothing"
handoff s1 continue no-owed
out=$(stop s1)
[[ $(jq -r .decision <<<"$out") == block ]]; check "T3: handoff without Owed section is blocked once"
handoff s1 continue
out=$(stop s1)
[[ $out == *"Compacting this thread, then continues (cycle 1)"* ]]; check "T3: stop announces compaction"
wait_sends 2; check "T3: two sends queued"
[ "$(grep '^thread send' "$tmp/cli.log" | head -n 2 | tr '\n' '|')" = "thread send mcp:abc-1 /compact|thread send mcp:abc-1 Continue from the handoff.|" ]; check "T3: /compact first, then the continue prompt, to the right thread"
[ -z "$(stop s1)" ] && sleep 0.3 && [ "$(sends)" = 2 ]; check "T3: second Stop before compaction sends nothing"
grep -q 'Last reply to the user' "$hdir/s1.md"; check "T3: handoff-stop.sh record written"
[ -z "$(inject s1 clear)" ]; check "T3: inject ignores source clear"
out=$(inject s1)
[[ $out == "# Handoff restored after compaction of this T3 thread"*"## Next step"* ]]; check "T3: compact injects the handoff"
[ -f "$hdir/s1.used.md" ] && [ ! -e "$hdir/s1.md" ] && [ ! -e "$state/s1.warn" ] && [ ! -e "$state/s1.hard" ]; check "T3: handoff used, markers reset"
[ -z "$(inject s1)" ] && [ ! -e "$state/pid-$CLAUDE_PID.cycles" ]; check "T3: compaction not started by the hook injects nothing, resets the count"

# --- same session, second cycle (compaction keeps the session id) ---
out=$(nudge s1 92000)
[[ $out == *"92k"*"$hdir/s1.md"* ]]; check "cycle 2: warns again in the same session"
handoff s1 "done"
out=$(stop s1)
[[ $out == *"then shows what is owed and waits for you (cycle 1)"* ]]; check "cycle 2: stop triggers again, count restarted"
wait_sends 4 && grep '^thread send' "$tmp/cli.log" | tail -n 1 | grep -q 'Show me only what the handoff lists'; check "cycle 2: done status sends the owed prompt"
out=$(inject s1)
[ -n "$out" ] && [ -f "$hdir/s1.used.1.md" ] && [ -f "$hdir/s1.used.md" ]; check "cycle 2: earlier used handoff kept as s1.used.1.md"

# --- other window in the same project ---
w1=$CLAUDE_PID
nudge s1 99500 > /dev/null; handoff s1 continue
CLAUDE_PID=$(window)
[ -z "$(inject s1)" ]; check "other window: loads nothing"
CLAUDE_PID=$w1; inject s1 > /dev/null

# --- thread not found, limit reached ---
CLAUDE_PID=$(window)
nudge s9 99500 > /dev/null; handoff s9 continue; n=$(sends)
out=$(stop s9)
[[ $out == *"thread was not found"*"Press Compact in T3"* ]] && [ "$(sends)" = "$n" ]; check "no thread id: asks the user, sends nothing"
echo "\"s1\" \"s8\"" > "$T3_HANDOFF_USERDATA/logs/provider/events.mcp-abc-1.log"
CLAUDE_PID=$(window)
nudge s8 99500 > /dev/null; handoff s8 continue
read -r start _ < "$state/pid-$CLAUDE_PID"; echo "$start 10" > "$state/pid-$CLAUDE_PID.cycles"
out=$(stop s8)
[[ $out == *"limit reached (10 of 10"* ]] && [ "$(sends)" = "$n" ]; check "limit of 10 cycles"

# --- handoff-now.sh ---
out=$(CLAUDE_CODE_SESSION_ID=s7 "$here/hooks/handoff-now.sh" 2>&1)
[[ $out == *"compacts this T3 thread"* || $out == *"No session ID or transcript"* ]]; check "handoff-now: runs in T3 mode"

# --- install.sh ---
export CLAUDE_SETTINGS=$tmp/settings.json
echo '{"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "other.sh"}]}]}}' > "$CLAUDE_SETTINGS"
"$here/install.sh" > /dev/null && "$here/install.sh" > /dev/null
[ "$(jq '[.hooks[][] .hooks[] | select(.command | contains("/t3/hooks/"))] | length' "$CLAUDE_SETTINGS")" = 4 ]; check "install: 4 entries, idempotent"
[ "$(jq -r '.hooks.SessionStart[0].matcher' "$CLAUDE_SETTINGS")" = compact ]; check "install: inject only on compact"
"$here/install.sh" --remove > /dev/null
[ "$(jq -c .hooks "$CLAUDE_SETTINGS")" = '{"Stop":[{"hooks":[{"type":"command","command":"other.sh"}]}]}' ]; check "remove: only the T3 entries go"

exit "$fail"
