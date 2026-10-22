#!/usr/bin/env bash
# Fixture tests for handoff-nudge.sh, handoff-inject.sh and handoff-stop.sh. No model calls. HOME points at a temp dir.
set -u
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
# This test shell stands in for the Claude window: hooks bind handoffs to CLAUDE_PID.
export HOME=$tmp CLAUDE_CODE_SESSION_ATTENDED=1 CLAUDE_PID=$$
unset TMUX TMUX_PANE HANDOFF_NOTE
state=$HOME/.claude/handoffs/.state
proj=$tmp/projects/-work
mkdir -p "$proj"
cwd=/work
hdir=$HOME/.claude/handoffs/-work
fail=0

check() {   # name; reads the status of the previous condition
  # shellcheck disable=SC2319  # intended: the caller's condition status
  local status=$?
  if [ "$status" = 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi
}

# transcript <file> <tokens> [model] [extra jsonl line]
transcript() {
  jq -nc --argjson t "$2" --arg m "${3:-claude-opus-5-5}" \
    '{type: "assistant", timestamp: "2026-01-01T00:00:00Z", message: {model: $m,
      usage: {input_tokens: 10, cache_read_input_tokens: ($t - 10), cache_creation_input_tokens: 0}}}' > "$1"
  [ -z "${4:-}" ] || echo "$4" >> "$1"
}

nudge() {   # event sid transcript; runs in tmux unless TMUX is set empty
  jq -nc --arg e "$1" --arg s "$2" --arg t "$3" --arg c "$cwd" \
    '{hook_event_name: $e, session_id: $s, transcript_path: $t, cwd: $c}' | TMUX=${TMUX-/tmp/x,1,0} TMUX_PANE=%9 "$here/handoff-nudge.sh"
}

ctx() { jq -r '.hookSpecificOutput.additionalContext // empty'; }
start_of() { sed 's/.*) //' "/proc/$1/stat" | cut -d' ' -f20; }

# --- nudge ---
transcript "$proj/s1.jsonl" 120000
[ -z "$(nudge UserPromptSubmit s1 "$proj/s1.jsonl")" ]; check "below warn: no output"

transcript "$proj/s1.jsonl" 141000
out=$(nudge PostToolUse s1 "$proj/s1.jsonl" | ctx)
[[ $out == *141k*"We start a new session soon"*"Plan a checkpoint within about 10k tokens"*"At the checkpoint, write the handoff to: $hdir/s1.md"*"status: continue | done"*"## Next step"* ]]; check "warn: checkpoint message with template"
[[ $out == *"never replaces a reply"*"## Owed to the user"*"Always include this section"* ]]; check "warn: reply owed before handoff"
[[ $out == *"Carry forward"*"UNKNOWN"*"Write every section"*"## Constraints"*"## Uncertainty"*"## Live state"* ]]; check "warn: template has carry-forward, UNKNOWN, constraints and uncertainty"
[ "$(cat "$state/pid-$$")" = "$(start_of $$) $hdir/s1.md claude-opus-5-5" ]; check "warn: handoff bound to this window"
[ -z "$(nudge UserPromptSubmit s1 "$proj/s1.jsonl")" ]; check "warn: not repeated"
rm -f "$state/s1.warn"
out=$(cwd=/work/packages/core nudge PostToolUse s1 "$proj/s1.jsonl" | ctx)
[[ $out == *"write the handoff to: $hdir/s1.md"* ]] && [ "$(cat "$state/pid-$$")" = "$(start_of $$) $hdir/s1.md claude-opus-5-5" ]; check "warn: cwd in a subfolder: same handoff folder"

transcript "$proj/s1.jsonl" 151000
out=$(nudge PostToolUse s1 "$proj/s1.jsonl" | ctx)
[[ $out == *"Stop now"*"$hdir/s1.md"* && $out != *"## Next step"* ]]; check "hard: stop message, template not repeated"
[[ $out == *"under ## Owed to the user"* ]]; check "hard: unanswered questions listed as owed"
out=$(nudge PostToolUse s1 "$proj/s1.jsonl" | ctx)
[[ $out == *"above the 150k"* && $(wc -l <<<"$out") == 1 ]]; check "hard: one-line reminder on tool result"
out=$(nudge UserPromptSubmit s1 "$proj/s1.jsonl" | ctx)
[[ $out == *"above the 150k"* && $(wc -l <<<"$out") == 1 ]]; check "hard: one-line reminder on prompt"
ev=$(nudge UserPromptSubmit s1 "$proj/s1.jsonl" | jq -r .hookSpecificOutput.hookEventName)
[ "$ev" = UserPromptSubmit ]; check "hard: event name echoed"

mkdir -p "$hdir" && echo x > "$hdir/s1.md"
[ -z "$(nudge UserPromptSubmit s1 "$proj/s1.jsonl")" ]; check "handoff present: silent"
rm "$hdir/s1.md"

transcript "$proj/s2.jsonl" 160000 claude-opus-5-5 '{"type":"system","subtype":"compact_boundary"}'
[ -z "$(nudge UserPromptSubmit s2 "$proj/s2.jsonl")" ]; check "after compaction: silent"

transcript "$proj/s3.jsonl" 160000 claude-opus-5-5 \
  '{"type":"assistant","isSidechain":true,"message":{"model":"x","usage":{"input_tokens":5}}}'
out=$(nudge UserPromptSubmit s3 "$proj/s3.jsonl" | ctx)
[[ $out == *160k*"Stop now"*"## Next step"* ]]; check "sidechain ignored; jump past warn: stop message with template"

transcript "$proj/s4.jsonl" 95000 claude-haiku-5-5
out=$(nudge UserPromptSubmit s4 "$proj/s4.jsonl" | ctx)
[[ $out == *"At 100k"* ]]; check "haiku: warn at 95k"
transcript "$proj/s4.jsonl" 101000 claude-haiku-5-5
out=$(nudge PostToolUse s4 "$proj/s4.jsonl" | ctx)
[[ $out == *"100k stop limit"* ]]; check "haiku: stop at 101k"
transcript "$proj/s5.jsonl" 90000 claude-sonnet-5-5
[ -z "$(nudge UserPromptSubmit s5 "$proj/s5.jsonl")" ]; check "sonnet: silent at 90k"

transcript "$proj/s6.jsonl" 160000
out=$(CLAUDE_CODE_SESSION_ATTENDED=0 nudge UserPromptSubmit s6 "$proj/s6.jsonl")
[ -z "$out" ] && [ -z "$(find "$state" -name 's6*')" ]; check "headless: silent, no state"

transcript "$proj/s7.jsonl" 160000
for _ in 1 2 3 4 5 6 7 8; do nudge PostToolUse s7 "$proj/s7.jsonl" > "$tmp/par.$RANDOM$RANDOM" & done; wait
[ "$(cat "$tmp"/par.* | rg -c 'Stop now')" = 1 ]; check "parallel hooks: one hard message"

transcript "$proj/s8.jsonl" 160000
out=$(TMUX='' nudge UserPromptSubmit s8 "$proj/s8.jsonl")
[ -z "$out" ] && [ -z "$(find "$state" -name 's8*')" ]; check "outside tmux: silent, no state"

transcript "$proj/s9.jsonl" 141000
out=$(nudge UserPromptSubmit s9 "$proj/s9.jsonl" | ctx)
[[ $out == *"A hook then clears the session"* ]]; check "warn: in tmux, hook clears"
[[ $out != *"side model"* ]]; check "side note off by default: warn message names no note"

# --- side note (sidenote.sh), on only with HANDOFF_NOTE ---
# Stub engines: log each run, print the arguments, the hook environment and stdin (the note grows).
bin=$tmp/bin; mkdir -p "$bin"
for e in claude pi; do
  # shellcheck disable=SC2016  # the stub expands its own variables
  printf '#!/usr/bin/env bash\n[ ! -e "%s" ] || sleep 1\necho run >> "%s"\necho "%s args: $*"; echo "attended=${CLAUDE_CODE_SESSION_ATTENDED:-} tmux=${TMUX:-}"; cat\n' "$tmp/slow" "$tmp/runs" "$e" > "$bin/$e"
  chmod +x "$bin/$e"
done
note=$hdir/window-$$-$(start_of $$).note.md lock=$state/pid-$$.note.lock
runs() { cat "$tmp/runs" 2>/dev/null | wc -l; }
idle() { for _ in $(seq 50); do [ ! -e "$lock" ] && return 0; sleep 0.1; done; return 1; }   # run ended
sn() { PATH=$bin:$PATH HANDOFF_NOTE=${E:-haiku} nudge PostToolUse "$1" "$proj/$1.jsonl"; }
# A real transcript only grows: append a usage line instead of rewriting the file.
grow() { transcript "$tmp/line" "$2"; cat "$tmp/line" >> "$proj/$1.jsonl"; }   # sid tokens
say() { jq -nc --arg r "$1" --arg c "$2" '{type: $r, message: {content: $c}}' >> "$proj/$3.jsonl"; }   # role text sid

transcript "$proj/w1.jsonl" 69000; say user "never push to main" w1
[ -z "$(sn w1)" ] && [ "$(runs)" = 0 ]; check "side note: no run below 70k"
transcript "$proj/w1.jsonl" 71000; say user "never push to main" w1
say user "<system-reminder>a CLAUDE.md rule</system-reminder>" w1
out=$(sn w1); idle
[ -z "$out" ] && [ "$(runs)" = 1 ]; check "side note: first run at 71k, no message to Claude"
n=$(cat "$note")
[[ $n == *"claude args: -p --model claude-haiku-5-5 --effort xhigh --no-session-persistence --settings {\"disableAllHooks\": true} You keep a note"* ]]; check "side note haiku: xhigh effort, hooks off, no session"
[[ $n == *"attended=0 tmux="*"=== Current note"*none*"=== Newest session text"*"[user] never push to main"* && $n != *usage* && $n != *"CLAUDE.md rule"* ]]; check "side note: hooks see no session, input is note plus text only, no system reminders"
[ "$(cut -d' ' -f3 "$state/pid-$$.note")" = "$(stat -c %s "$proj/w1.jsonl")" ] && [ -z "$(find "$hdir" -name '*.note.md.*')" ]; check "side note: read position saved, no temp files left"
grow w1 85000; say user "never push to main" w1
sn w1 > /dev/null; idle
[ "$(runs)" = 1 ]; check "side note: no run before 20k more tokens"
grow w1 92000; say assistant "I will check the lock later" w1
: > "$lock"
sn w1 > /dev/null; sleep 0.3
[ "$(runs)" = 1 ] && [ -e "$state/pid-$$.note.want" ]; check "side note: a working run blocks a new run and asks it for one more pass"
touch -d '-7 minutes' "$lock"
sn w1 > /dev/null; idle
n=$(cat "$note")
[ "$(runs)" = 2 ] && [[ $n == *"=== Current note"*"[user] never push to main"*"=== Newest session text"*"[assistant] I will check the lock later" ]]; check "side note: stale lock removed, next run gets the old note and only the new text"
grow w1 141000; say user "use pnpm" w1
out=$(sn w1 | ctx); idle
[ "$(runs)" = 3 ] && [[ $out == *"Plan a checkpoint"*"A side model keeps a note"*"at $note"*"## Next step"* ]]; check "side note: last run at warn, warn message names the note"
grow w1 151000
out=$(sn w1 | ctx); idle
[ "$(runs)" = 3 ] && [[ $out == *"Stop now"*"at $note"* ]]; check "side note: no run at the stop limit after the last run, stop message names the note"
transcript "$proj/w2.jsonl" 71000; say user "new session text" w2
sn w2 > /dev/null; idle
n=$(cat "$note")
[ "$(runs)" = 4 ] && [[ $n == *"=== Current note"*"use pnpm"*"=== Newest session text"*"[user] new session text" && ${n##*=== Newest session text} != *"use pnpm"* ]]; check "side note: next session in the window keeps the note, reads its own transcript"
transcript "$proj/w3.jsonl" 71000; say user "x" w3
E=pi sn w3 > /dev/null; idle
[[ $(cat "$note") == "pi args: -p --model opencode2api/minimax-m3.1-flash-free --no-session --no-context-files @$note.in You keep a note"* ]]; check "side note pi: MiniMax M3.1, text as a file"
transcript "$proj/w4.jsonl" 141000
out=$(E=sonnet sn w4 | ctx); sleep 0.3
[[ $out != *"side model"* ]] && [ "$(runs)" = 5 ]; check "side note: unknown engine is off"
transcript "$proj/w5.jsonl" 71000; say user "first" w5; : > "$tmp/slow"
sn w5 > /dev/null; sleep 0.3; grow w5 92000; say user "second" w5; sn w5 > /dev/null; idle; idle; rm -f "$tmp/slow"
[ "$(runs)" = 7 ] && [[ $(cat "$note") == *"[user] second"* ]] && [ ! -e "$state/pid-$$.note.want" ]; check "side note: a tick during a run gives one more pass that reads the new text"
grow w5 141000; mkdir -p "$hdir" && echo x > "$hdir/w5.md"; say user "after handoff" w5
out=$(sn w5); idle
[[ $out == *"exists"* || -z $out ]] && [ "$(runs)" = 8 ] && [[ $(cat "$note") == *"[user] after handoff"* ]]; check "side note: last run still starts after the handoff exists"
rm -f "$hdir/w5.md"
echo "## Goal W" > "$hdir/w.md"; printf '%s %s\n' "$(start_of $$)" "$hdir/w.md" > "$state/pid-$$"
out=$(jq -nc --arg t "$proj/new.jsonl" --arg c "$cwd" '{transcript_path: $t, session_id: "neww", source: "clear", cwd: $c}' | "$here/handoff-inject.sh" | ctx)
[[ $out == *"Side note of this window"*"$note"*"## Goal W"* ]]; check "inject: header names the side note"
rm -f "$tmp/runs" "$state"/pid-$$.note*

# --- inject ---
inject() { jq -nc --arg t "$proj/new.jsonl" '{transcript_path: $t, session_id: "new", source: "clear"}' | "$here/handoff-inject.sh"; }
bind() { printf '%s %s\n' "${2:-$(start_of $$)}" "$hdir/$1.md" > "$state/pid-$$"; }   # name [start]

rm -rf "$hdir" "$state" && mkdir -p "$hdir" "$state"
echo "## Goal A" > "$hdir/a.md"
echo "## Goal B" > "$hdir/b.md"
bind b
out=$(CLAUDE_PID=$PPID inject)
[ -z "$out" ] && [ -e "$hdir/b.md" ] && [ -e "$state/pid-$$" ]; check "other window: /clear loads nothing"

since=$(date -u -d '-1 minute' +%Y-%m-%dT%H:%M:%S.000Z)
later=$(date -u -d '+1 minute' +%Y-%m-%dT%H:%M:%S.000Z)
{
  jq -nc --arg t "$since" '{type: "user", timestamp: $t, message: {content: "before handoff"}}'
  jq -nc --arg t "$later" '{type: "user", timestamp: $t, message: {content: "late user note"}}'
  jq -nc --arg t "$later" '{type: "user", timestamp: $t, message: {content: "<command-name>/clear</command-name>"}}'
  jq -nc --arg t "$later" '{type: "assistant", timestamp: $t, message: {content: [
    {type: "text", text: "late answer"}, {type: "tool_use", name: "Bash", input: {command: "ls"}}]}}'
} > "$proj/b.jsonl"
out=$(inject | ctx)
[[ $out == *"Source session: b"*"## Goal B"* && $out != *"Goal A"* && $out != *"Side note"* ]]; check "this window: its own handoff injected, no side note line"
[[ $out == *"Before the Next step:"*"1. Give the user every item under ## Owed to the user"*"2. Run git status"* ]]; check "inject: owed items first, then git status"
[[ $out == *"not a new approval"*"Search the old transcript before you act if:"*"Re-check a claim before an action that depends on it"* && $out != *"Cut at"* ]]; check "inject: no new approval, transcript triggers, claims re-checked, small handoff not cut"
[[ $out == *"Old transcript: $proj/b.jsonl"* && $out != *"late user note"* ]]; check "no transcript copy, old transcript path given"
[ -e "$hdir/b.used.md" ] && [ ! -e "$hdir/b.md" ] && [ ! -e "$state/pid-$$" ]; check "used: renamed, binding consumed"
[[ $out == *"without tool output"*"jq -r 'select(.type == \"user\" or .type == \"assistant\")"*"map(select(.type == \"text\")"* && $out == *"repeat any answer or question in it that is still open"* ]]; check "inject: array-safe user-message command and last-reply rule"
[ "$(cat "$state/new.chain")" = "$proj/b.jsonl" ]; check "inject: chain starts with the old transcript"

printf '%s\n' /t/z1 /t/z2 /t/z3 /t/z4 /t/z5 > "$state/d.chain"
echo "## Goal D" > "$hdir/d.md" && bind d
inject > /dev/null
[ "$(cat "$state/new.chain")" = "$proj/d.jsonl
/t/z1
/t/z2
/t/z3
/t/z4" ] && [ ! -e "$state/d.chain" ]; check "inject: chain keeps 5 transcripts, old chain removed"
rm -f "$state/new.chain"
[ -z "$(inject)" ]; check "used: next /clear loads nothing"

touch -d '-3 hours' "$hdir/a.md" && bind a
[ -z "$(inject)" ] && [ -e "$hdir/a.md" ] && [ ! -e "$state/pid-$$" ]; check "stale: ignored, binding consumed"

echo "## Goal C" > "$hdir/c.md" && bind c 1
[ -z "$(inject)" ] && [ -e "$hdir/c.md" ]; check "reused PID (other start time): ignored"

head -c 50000 /dev/zero | tr '\0' x > "$hdir/big.md" && bind big
out=$(inject | ctx)
[[ $out == *"[handoff] Cut at 40000 characters. Read the rest of $hdir/big.used.md"* ]] && (( ${#out} < 40200 )); check "inject: long handoff cut with a notice"

bind none
[ -z "$(inject)" ] && [ ! -e "$state/pid-$$" ]; check "no handoff written: binding consumed"

bind c
out=$(CLAUDE_CODE_SESSION_ATTENDED=0 inject)
[ -z "$out" ] && [ -e "$hdir/c.md" ] && [ -e "$state/pid-$$" ]; check "headless: no injection"

echo "$(start_of $$) 3" > "$state/pid-$$.cycles" && : > "$state/pid-$$.auto"
inject > /dev/null
[ ! -e "$state/pid-$$.auto" ] && [ -e "$state/pid-$$.cycles" ]; check "automatic /clear: marker consumed, count kept"
inject > /dev/null
[ ! -e "$state/pid-$$.cycles" ]; check "manual /clear: count reset"

# --- stop ---
# A fake tmux logs the keys. Its first Enter (after /clear) removes the binding, as handoff-inject.sh
# does. Its list-clients logs each poll and prints $tmp/activity ("<last client input, epoch s>
# <client's current pane>") if it exists. A fake sleep makes the detached helper fast. Both are on PATH for the hook only.
fake=$tmp/fake && mkdir -p "$fake"
# shellcheck disable=SC2016  # the fake script expands its own arguments
printf '#!/bin/sh\nif [ "$1" = list-clients ]; then echo >> "%s/polls"; cat "%s/activity" 2>/dev/null; exit 0; fi\necho "$*" >> "%s/keys"\n[ "$*" = "send-keys -t %%9 Enter" ] && rm -f "%s/pid-%s"\nexit 0\n' \
  "$tmp" "$tmp" "$tmp" "$state" "$$" > "$fake/tmux"
printf '#!/bin/sh\nexit 0\n' > "$fake/sleep"
chmod +x "$fake/tmux" "$fake/sleep"
stop() {   # sid [stop_hook_active] [last reply]
  jq -nc --arg s "$1" --argjson a "${2:-false}" --arg r "${3:-}" '{session_id: $s, stop_hook_active: $a} + (if $r == "" then {} else {last_assistant_message: $r} end)' |
    PATH=$fake:$PATH "$here/handoff-stop.sh"
}
in_tmux() { TMUX=/tmp/x,1,0 TMUX_PANE=%9 "$@"; }
# handoff <sid> <status> [model]: this window's handoff for session sid
handoff() {
  printf -- '---\nsession: %s\nstatus: %s\n---\n## Goal\n## Owed to the user\nnone\n' "$1" "$2" > "$hdir/$1.md"
  printf '%s %s %s\n' "$(start_of $$)" "$hdir/$1.md" "${3:-claude-opus-5-5}" > "$state/pid-$$"
}
keys() { for _ in $(seq 50); do rg -q 'Continue' "$tmp/keys" 2>/dev/null && break; command sleep 0.1; done; cat "$tmp/keys" 2>/dev/null; }
reset() { rm -f "$tmp/keys" "$tmp/polls" "$tmp/activity" "$state/clear.log" "$state"/pid-$$*; }

reset; handoff t1 continue
out=$(stop t1 | jq -r .systemMessage)
[[ $out == *"Type /clear"* ]] && [ ! -e "$tmp/keys" ]; check "stop outside tmux: user types /clear"

reset; handoff t1 continue && sed -i '/^## Owed/,$d' "$hdir/t1.md"
out=$(in_tmux stop t1)
[ "$(jq -r .decision <<<"$out")" = block ] && [[ $(jq -r .reason <<<"$out") == *"Owed to the user"* ]] && [ ! -e "$tmp/keys" ]; check "stop, no owed section: blocked once, no clear"
out=$(in_tmux stop t1 true | jq -r .systemMessage)
[[ $out == *"cycle 1"* && $(keys) == *Continue* ]]; check "stop, no owed section on retry: no loop, clears"

reset; handoff t1 "done"
out=$(in_tmux stop t1 | jq -r .systemMessage)
for _ in $(seq 50); do [ -e "$state/pid-$$" ] || break; command sleep 0.1; done
command sleep 0.3
[[ $out == *"the new session shows what is owed, then waits for you"* ]] && [ "$(cat "$tmp/keys")" = "send-keys -t %9 -l x
send-keys -t %9 Escape Escape
send-keys -t %9 -l x
send-keys -t %9 Escape Escape
send-keys -t %9 -l /clear
send-keys -t %9 Enter
send-keys -t %9 -l x
send-keys -t %9 Escape Escape
send-keys -t %9 -l x
send-keys -t %9 Escape Escape
send-keys -t %9 -l Show me only what the handoff lists under ## Owed to the user. Do not start the Next step.
send-keys -t %9 Enter" ]; check "stop, status done: clears, types the owed-items prompt"

reset; handoff t1 continue
[ -z "$(in_tmux stop t2)" ] && [ ! -e "$tmp/keys" ]; check "stop, other session's handoff: nothing"

reset; handoff t1 continue
out=$(in_tmux stop t1 | jq -r .systemMessage)
[ "$(keys)" = "send-keys -t %9 -l x
send-keys -t %9 Escape Escape
send-keys -t %9 -l x
send-keys -t %9 Escape Escape
send-keys -t %9 -l /clear
send-keys -t %9 Enter
send-keys -t %9 -l x
send-keys -t %9 Escape Escape
send-keys -t %9 -l x
send-keys -t %9 Escape Escape
send-keys -t %9 -l Continue from the handoff.
send-keys -t %9 Enter" ]; check "stop, continue: clears the input, types /clear, then the prompt"
[[ $out == *"cycle 1"* ]] && [ "$(cat "$state/pid-$$.cycles")" = "$(start_of $$) 1" ]; check "stop, continue: cycle counted"

reset; handoff t1 continue
echo "$(( $(date +%s) + 100 )) %9" > "$tmp/activity"   # the user keeps typing in this pane
in_tmux stop t1 > /dev/null
for _ in $(seq 100); do [ "$(wc -l < "$tmp/polls" 2>/dev/null || echo 0)" -ge 60 ] && break; command sleep 0.1; done
for _ in $(seq 50); do [ -s "$state/clear.log" ] && break; command sleep 0.1; done
[ "$(wc -l < "$tmp/polls" 2>/dev/null)" = 60 ] && [ ! -e "$tmp/keys" ]; check "stop, user typing: helper gives up, types nothing"
rg -q "pane %9 pid $$: input for 30 s, /clear not typed" "$state/clear.log"; check "stop, user typing: give-up logged"
[ ! -e "$state/pid-$$.auto" ]; check "stop, user typing: marker removed, so the user's /clear resets the count"

reset; handoff t1 continue
echo "$(( $(date +%s) + 100 )) %3" > "$tmp/activity"   # the user types in another pane
in_tmux stop t1 > /dev/null
[[ $(keys) == *"/clear"*"Continue"* ]]; check "stop, input in another pane: types /clear and the prompt"

reset; handoff t1 continue
echo "$(( $(date +%s) - 5 )) %9" > "$tmp/activity"   # input 5 s ago: quiet
in_tmux stop t1 > /dev/null
[[ $(keys) == *"/clear"*"Continue"* ]]; check "stop, user quiet 5 s: types /clear and the prompt"

rm -f "$tmp/keys"; handoff t1 continue
[ -z "$(in_tmux stop t1)" ] && [ ! -e "$tmp/keys" ]; check "stop again before /clear: no second trigger"

reset; handoff t1 continue
cat > "$state/pid-$$.cycles" <<<"$(start_of $$) 10"
out=$(in_tmux stop t1 | jq -r .systemMessage)
[[ $out == *"limit reached (10 of 10"*"handoff is saved"*"sets the count to 0"* ]] && [ ! -e "$tmp/keys" ]; check "stop, opus limit 10: user types /clear"

reset; handoff t1 continue claude-haiku-5-5
cat > "$state/pid-$$.cycles" <<<"$(start_of $$) 10"
out=$(in_tmux stop t1 | jq -r .systemMessage)
[[ $out == *"limit reached (10 of 10"*"handoff is saved"*"sets the count to 0"* ]] && [ ! -e "$tmp/keys" ]; check "stop, haiku limit 10: user types /clear"

reset; handoff t1 continue
cat > "$state/pid-$$.cycles" <<<"$(start_of $$) 9"
out=$(in_tmux stop t1 | jq -r .systemMessage)
[[ $out == *"cycle 10"* && $(keys) == *"/clear"* ]]; check "stop, cycle 10 of 10: still clears"

# --- record: last reply and earlier transcripts ---
reset; handoff t1 "done"
printf '%s\n' /t/a.jsonl /t/b.jsonl > "$state/t1.chain"
stop t1 false "Decide: A or B?" > /dev/null
rec=$(sed -n '/^<!-- handoff-stop.sh/,$p' "$hdir/t1.md")
[[ $rec == *"## Last reply to the user"*"Decide: A or B?"*"## Earlier transcripts"*"- /t/a.jsonl"*"- /t/b.jsonl"* ]]; check "record: last reply and earlier transcripts appended"
stop t1 false "Second reply" > /dev/null
[ "$(rg -c 'handoff-stop.sh: record' "$hdir/t1.md")" = 1 ] && rg -q 'Second reply' "$hdir/t1.md" && ! rg -q 'Decide' "$hdir/t1.md" && rg -q '^## Owed to the user' "$hdir/t1.md"; check "record: replaced on the next Stop, handoff kept"
head -c 7000 /dev/zero | tr '\0' y > "$tmp/long"
stop t1 false "$(cat "$tmp/long")" > /dev/null
rg -q 'Cut at 6000 characters' "$hdir/t1.md" && [ "$(rg -o 'y{100,}' "$hdir/t1.md" | awk '{ print length }')" = 6000 ]; check "record: long reply cut with a notice"
rm -f "$state/t1.chain"

reset; handoff t1 continue
[ -z "$(CLAUDE_CODE_SESSION_ATTENDED=0 in_tmux stop t1)" ] && [ ! -e "$tmp/keys" ]; check "stop headless: nothing"

# --- manual (/handoff) ---
manual() { "$here/handoff-nudge.sh" --manual; }
reset; rm -rf "$hdir"; mkdir -p "$tmp/.claude/projects/-work"
transcript "$tmp/.claude/projects/-work/m1.jsonl" 20000 claude-haiku-5-5
out=$(cd /tmp && CLAUDE_CODE_SESSION_ID=m1 manual)
[[ $out == *"(/handoff)"*"Write the handoff to $hdir/m1.md"*"Outside tmux"*"## Next step"* ]]; check "manual: low context, outside tmux: instructions with template"
[ "$(cat "$state/pid-$$")" = "$(start_of $$) $hdir/m1.md claude-haiku-5-5" ]; check "manual: cwd in another folder: handoff bound in the project folder"
out=$(cd /tmp && CLAUDE_CODE_SESSION_ID=m1 TMUX=/tmp/x,1,0 TMUX_PANE=%9 manual)
[[ $out == *"A hook then clears the session"* && $out != *"Outside tmux"* ]]; check "manual: in tmux, hook clears"
mkdir -p "$hdir" && echo x > "$hdir/m1.md"
out=$(cd /tmp && CLAUDE_CODE_SESSION_ID=m1 manual)
[[ $out == *"exists"* && $out != *"## Next step"* ]]; check "manual: handoff exists: no second template"
out=$(CLAUDE_CODE_SESSION_ID=nope manual)
[[ $out == "[handoff] No session ID or transcript found"* ]]; check "manual: unknown session: error"
out=$(CLAUDE_CODE_SESSION_ATTENDED=0 CLAUDE_CODE_SESSION_ID=m1 manual)
[[ $out == "[handoff] Not an interactive session"* ]]; check "manual: headless: error"

exit $fail
