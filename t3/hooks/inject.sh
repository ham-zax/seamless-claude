#!/usr/bin/env bash
# SessionStart(compact) hook for T3 Code: loads this window's handoff after the thread is compacted.
# Compaction keeps the session id (F4), unlike /clear. So the wrapper also does what a new session id
# did for free: it keeps the earlier used handoff (H7) and resets the warn/stop markers (H5), so the
# next cycle in this session warns again. Outside T3, or for other sources, it does nothing.
# shellcheck source=lib.sh
. "${BASH_SOURCE[0]%/*}/lib.sh"
t3_session || exit 0
input=$(cat)
IFS=$'\t' read -r src sid < <(jq -r '[.source // "", .session_id // ""] | @tsv' <<<"$input")
[ "$src" = compact ] && [[ $sid =~ ^[A-Za-z0-9-]+$ ]] || exit 0
state=$HOME/.claude/handoffs/.state

# handoff-inject.sh moves <sid>.md to <sid>.used.md: keep the used file of the earlier cycle.
if [ -f "$state/pid-$CLAUDE_PID" ]; then
  read -r _ file _ < "$state/pid-$CLAUDE_PID"
  used=${file%.md}.used.md
  if [ -f "$used" ] && [ -f "$file" ]; then
    n=1
    while [ -e "${file%.md}.used.$n.md" ]; do n=$((n + 1)); done
    mv "$used" "${file%.md}.used.$n.md"
  fi
fi

out=$(CLAUDE_CODE_SESSION_ATTENDED=1 "$t3_handoff_dir/handoff-inject.sh" <<<"$input")
# Every compaction starts a new cycle, also the T3 fallback and the compact button.
rm -f "$state/$sid.warn" "$state/$sid.hard"
[ -n "$out" ] || exit 0
jq -c '.hookSpecificOutput.additionalContext |= sub("^# Handoff restored after /clear"; "# Handoff restored after compaction of this T3 thread")' <<<"$out"
