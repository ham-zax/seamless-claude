#!/usr/bin/env bash
# Fixture tests for handoff-nudge.sh and handoff-inject.sh. No model calls. HOME points at a temp dir.
set -u
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
# This test shell stands in for the Claude window: hooks bind handoffs to CLAUDE_PID.
export HOME=$tmp CLAUDE_CODE_SESSION_ATTENDED=1 CLAUDE_PID=$$
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

nudge() {   # event sid transcript
  jq -nc --arg e "$1" --arg s "$2" --arg t "$3" --arg c "$cwd" \
    '{hook_event_name: $e, session_id: $s, transcript_path: $t, cwd: $c}' | "$here/handoff-nudge.sh"
}

ctx() { jq -r '.hookSpecificOutput.additionalContext // empty'; }
start_of() { sed 's/.*) //' "/proc/$1/stat" | cut -d' ' -f20; }

# --- nudge ---
transcript "$proj/s1.jsonl" 120000
[ -z "$(nudge UserPromptSubmit s1 "$proj/s1.jsonl")" ]; check "below warn: no output"

transcript "$proj/s1.jsonl" 136000
out=$(nudge PostToolUse s1 "$proj/s1.jsonl" | ctx)
[[ $out == *136k*"Do not write the handoff yet"* ]]; check "warn: message once"
[ -z "$(nudge UserPromptSubmit s1 "$proj/s1.jsonl")" ]; check "warn: not repeated"

transcript "$proj/s1.jsonl" 151000
out=$(nudge PostToolUse s1 "$proj/s1.jsonl" | ctx)
[[ $out == *"$hdir/s1.md"*"## Next step"* ]]; check "hard: full message with path"
[ "$(cat "$state/pid-$$")" = "$(start_of $$) $hdir/s1.md" ]; check "hard: handoff bound to this window"
[ -z "$(nudge PostToolUse s1 "$proj/s1.jsonl")" ]; check "hard: PostToolUse silent after"
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
[[ $out == *160k* ]]; check "sidechain entry ignored"

transcript "$proj/s4.jsonl" 90000 claude-haiku-5-5
out=$(nudge UserPromptSubmit s4 "$proj/s4.jsonl" | ctx)
[[ $out == *"hard limit for this model is 100k"* ]]; check "haiku: warn at 90k"
transcript "$proj/s5.jsonl" 90000 claude-sonnet-5-5
[ -z "$(nudge UserPromptSubmit s5 "$proj/s5.jsonl")" ]; check "sonnet: silent at 90k"

transcript "$proj/s6.jsonl" 160000
out=$(CLAUDE_CODE_SESSION_ATTENDED=0 nudge UserPromptSubmit s6 "$proj/s6.jsonl")
[ -z "$out" ] && [ -z "$(find "$state" -name 's6*')" ]; check "headless: silent, no state"

transcript "$proj/s7.jsonl" 160000
for _ in 1 2 3 4 5 6 7 8; do nudge PostToolUse s7 "$proj/s7.jsonl" > "$tmp/par.$RANDOM$RANDOM" & done; wait
[ "$(cat "$tmp"/par.* | rg -c 'hard limit for this model')" = 1 ]; check "parallel hooks: one hard message"

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
[[ $out == *"USER: late user note"*"ASSISTANT: late answer"*"TOOL Bash: "* ]]; check "tail: late turns appended"
[[ $out != *"before handoff"* && $out != *"command-name"* ]]; check "tail: older turns and commands skipped"
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

exit $fail
