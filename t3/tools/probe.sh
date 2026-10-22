#!/usr/bin/env bash
# Phase 0 probe (see ../FINDINGS.md): logs each hook event with the environment that the handoff
# hooks depend on. Remove the hook entries from ~/.claude/settings.json after the test.
log=$HOME/.claude/handoffs/.state/t3-probe.log
mkdir -p "${log%/*}"
input=$(cat)
pcmd=$(tr '\0' ' ' < "/proc/$PPID/cmdline" 2>/dev/null | cut -c1-120)
jq -nc --argjson in "$input" --arg pcmd "$pcmd" --arg ppid "$PPID" '{
  t: (now | todate),
  event: $in.hook_event_name,
  source: ($in.source // $in.trigger // null),
  sid: $in.session_id,
  cwd: $in.cwd,
  CLAUDE_PID: env.CLAUDE_PID,
  ATTENDED: env.CLAUDE_CODE_SESSION_ATTENDED,
  ENTRYPOINT: env.CLAUDE_CODE_ENTRYPOINT,
  TMUX: env.TMUX,
  t3env: (env | with_entries(select(.key | test("T3|CLAUDE_CODE_TASK"))) | keys),
  ppid: $ppid,
  pcmd: $pcmd
}' >> "$log" 2>/dev/null
exit 0
