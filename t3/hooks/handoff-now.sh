#!/usr/bin/env bash
# Manual handoff (the /handoff command) that also works in T3 Code. The agent runs it in its Bash
# tool. Outside T3 it runs ../handoff/handoff-nudge.sh --manual unchanged.
# shellcheck source=lib.sh
. "${BASH_SOURCE[0]%/*}/lib.sh"
t3_session || exec "$t3_handoff_dir/handoff-nudge.sh" --manual
CLAUDE_CODE_SESSION_ATTENDED=1 TMUX=t3 TMUX_PANE=t3 "$t3_handoff_dir/handoff-nudge.sh" --manual |
  sed -e 's/A hook then clears the session and continues from the handoff in a new session\./A hook then compacts this T3 thread, loads the handoff and continues from it./' \
      -e 's/The hook clears the screen right after your turn/The hook compacts the thread right after your turn/'
