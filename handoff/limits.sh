# shellcheck shell=bash
# Per-model handoff limits in tokens. One owner: handoff-nudge.sh and ~/.claude/statusline.sh source
# this file. Native compaction (autoCompactWindow - 33k) must start above the hard limit.
# handoff_limits <model id>: prints "<warn> <hard>".
handoff_limits() {
  case $1 in
    *haiku*) echo 90000 100000 ;;
    *)       echo 140000 150000 ;;
  esac
}
