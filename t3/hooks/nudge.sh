#!/usr/bin/env bash
# UserPromptSubmit + PostToolUse hook for T3 Code: runs ../handoff/handoff-nudge.sh in a T3 session.
# handoff-nudge.sh skips non-attended sessions and sessions outside tmux (H1, H2): the wrapper sets
# both, then rewrites the lines that say the hook clears the session. Outside T3 it does nothing.
# shellcheck source=lib.sh
. "${BASH_SOURCE[0]%/*}/lib.sh"
t3_session || exit 0
out=$(CLAUDE_CODE_SESSION_ATTENDED=1 TMUX=t3 TMUX_PANE=t3 "$t3_handoff_dir/handoff-nudge.sh")
[ -n "$out" ] || exit 0
jq -c '.hookSpecificOutput.additionalContext |= (
  gsub("A hook then clears the session and continues from the handoff in a new session\\.";
       "A hook then compacts this T3 thread, loads the handoff and continues from it.")
  | gsub("The hook clears the screen right after your turn"; "The hook compacts the thread right after your turn"))' <<<"$out"
