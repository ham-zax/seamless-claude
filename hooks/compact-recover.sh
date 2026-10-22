#!/usr/bin/env bash
# SessionStart(compact): re-inject git state after compaction. Output is capped to keep it cheap.
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0
echo "## git: $(git branch --show-current 2>/dev/null)"
git status --short 2>/dev/null | head -30
git diff --stat 2>/dev/null | tail -1
echo "## recent commits"
git log --oneline -5 2>/dev/null
exit 0
