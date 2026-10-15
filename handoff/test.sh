#!/usr/bin/env bash
# Fixture tests for handoff-nudge.sh, handoff-inject.sh and handoff-stop.sh. No model calls. HOME points at a temp dir.
set -u
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
# This test shell stands in for the Claude window: hooks bind handoffs to CLAUDE_PID.
export HOME=$tmp CLAUDE_CODE_SESSION_ATTENDED=1 CLAUDE_PID=$$
unset TMUX TMUX_PANE
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

transcript "$proj/s1.jsonl" 136000
out=$(nudge PostToolUse s1 "$proj/s1.jsonl" | ctx)
[[ $out == *136k*"At the checkpoint, write the handoff to: $hdir/s1.md"*"status: continue | done"*"## Next step"* ]]; check "warn: checkpoint message with template"
[ "$(cat "$state/pid-$$")" = "$(start_of $$) $hdir/s1.md claude-opus-5-5" ]; check "warn: handoff bound to this window"
[ -z "$(nudge UserPromptSubmit s1 "$proj/s1.jsonl")" ]; check "warn: not repeated"

transcript "$proj/s1.jsonl" 146000
out=$(nudge PostToolUse s1 "$proj/s1.jsonl" | ctx)
[[ $out == *"Stop now"*"$hdir/s1.md"* && $out != *"## Next step"* ]]; check "hard: stop message, template not repeated"
[ -z "$(nudge PostToolUse s1 "$proj/s1.jsonl")" ]; check "hard: PostToolUse silent after"
out=$(nudge UserPromptSubmit s1 "$proj/s1.jsonl" | ctx)
[[ $out == *"above the 145k"* && $(wc -l <<<"$out") == 1 ]]; check "hard: one-line reminder on prompt"
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

transcript "$proj/s4.jsonl" 90000 claude-haiku-5-5
out=$(nudge UserPromptSubmit s4 "$proj/s4.jsonl" | ctx)
[[ $out == *"At 95k"* ]]; check "haiku: warn at 90k"
transcript "$proj/s4.jsonl" 96000 claude-haiku-5-5
out=$(nudge PostToolUse s4 "$proj/s4.jsonl" | ctx)
[[ $out == *"95k stop limit"* ]]; check "haiku: stop at 96k"
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

transcript "$proj/s9.jsonl" 136000
out=$(nudge UserPromptSubmit s9 "$proj/s9.jsonl" | ctx)
[[ $out == *"A hook then clears the session"* ]]; check "warn: in tmux, hook clears"

# --- inject ---
inject() { jq -nc --arg t "$proj/new.jsonl" '{transcript_path: $t, source: "clear"}' | "$here/handoff-inject.sh"; }
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
[[ $out == *"Source session: b"*"## Goal B"* && $out != *"Goal A"* ]]; check "this window: its own handoff injected"
[[ $out == *"Old transcript: $proj/b.jsonl"* && $out != *"late user note"* ]]; check "no transcript copy, old transcript path given"
[ -e "$hdir/b.used.md" ] && [ ! -e "$hdir/b.md" ] && [ ! -e "$state/pid-$$" ]; check "used: renamed, binding consumed"
[ -z "$(inject)" ]; check "used: next /clear loads nothing"

touch -d '-3 hours' "$hdir/a.md" && bind a
[ -z "$(inject)" ] && [ -e "$hdir/a.md" ] && [ ! -e "$state/pid-$$" ]; check "stale: ignored, binding consumed"

echo "## Goal C" > "$hdir/c.md" && bind c 1
[ -z "$(inject)" ] && [ -e "$hdir/c.md" ]; check "reused PID (other start time): ignored"

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
# does. A fake sleep makes the detached helper fast. Both are on PATH for the hook only.
fake=$tmp/fake && mkdir -p "$fake"
printf '#!/bin/sh\necho "$*" >> "%s/keys"\n[ "$*" = "send-keys -t %%9 Enter" ] && rm -f "%s/pid-%s"\nexit 0\n' \
  "$tmp" "$state" "$$" > "$fake/tmux"
printf '#!/bin/sh\nexit 0\n' > "$fake/sleep"
chmod +x "$fake/tmux" "$fake/sleep"
stop() { jq -nc --arg s "$1" '{session_id: $s}' | PATH=$fake:$PATH "$here/handoff-stop.sh"; }
in_tmux() { TMUX=/tmp/x,1,0 TMUX_PANE=%9 "$@"; }
# handoff <sid> <status> [model]: this window's handoff for session sid
handoff() {
  printf -- '---\nsession: %s\nstatus: %s\n---\n## Goal\n' "$1" "$2" > "$hdir/$1.md"
  printf '%s %s %s\n' "$(start_of $$)" "$hdir/$1.md" "${3:-claude-opus-5-5}" > "$state/pid-$$"
}
keys() { for _ in $(seq 50); do rg -q 'Continue' "$tmp/keys" 2>/dev/null && break; command sleep 0.1; done; cat "$tmp/keys" 2>/dev/null; }
reset() { rm -f "$tmp/keys" "$state"/pid-$$*; }

reset; handoff t1 continue
out=$(stop t1 | jq -r .systemMessage)
[[ $out == *"Type /clear"* ]] && [ ! -e "$tmp/keys" ]; check "stop outside tmux: user types /clear"

reset; handoff t1 "done"
[ -z "$(in_tmux stop t1)" ] && [ ! -e "$tmp/keys" ]; check "stop, status done: nothing"

reset; handoff t1 continue
[ -z "$(in_tmux stop t2)" ] && [ ! -e "$tmp/keys" ]; check "stop, other session's handoff: nothing"

reset; handoff t1 continue
out=$(in_tmux stop t1 | jq -r .systemMessage)
[ "$(keys)" = "send-keys -t %9 -l /clear
send-keys -t %9 Enter
send-keys -t %9 -l Continue from the handoff.
send-keys -t %9 Enter" ]; check "stop, continue: types /clear, then the prompt"
[[ $out == *"cycle 1"* ]] && [ "$(cat "$state/pid-$$.cycles")" = "$(start_of $$) 1" ]; check "stop, continue: cycle counted"

rm -f "$tmp/keys"; handoff t1 continue
[ -z "$(in_tmux stop t1)" ] && [ ! -e "$tmp/keys" ]; check "stop again before /clear: no second trigger"

reset; handoff t1 continue
cat > "$state/pid-$$.cycles" <<<"$(start_of $$) 5"
out=$(in_tmux stop t1 | jq -r .systemMessage)
[[ $out == *"5 automatic clears"* ]] && [ ! -e "$tmp/keys" ]; check "stop, opus limit 5: user types /clear"

reset; handoff t1 continue claude-haiku-5-5
cat > "$state/pid-$$.cycles" <<<"$(start_of $$) 40"
in_tmux stop t1 > /dev/null
[[ $(keys) == *"/clear"* ]]; check "stop, haiku: no limit"

reset; handoff t1 continue
[ -z "$(CLAUDE_CODE_SESSION_ATTENDED=0 in_tmux stop t1)" ] && [ ! -e "$tmp/keys" ]; check "stop headless: nothing"

exit $fail
