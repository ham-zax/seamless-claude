#!/usr/bin/env bash
# Adds the T3 hooks to ~/.claude/settings.json, or removes them with --remove. Idempotent: it first
# removes every hook entry whose command is in t3/hooks/, then adds the current set. The tmux hooks of
# ../handoff/ stay: each T3 hook exits at once outside T3 Code. Makes a backup first.
# CLAUDE_SETTINGS overrides the settings file (test.sh).
set -eu
here=$(cd "${BASH_SOURCE[0]%/*}" && pwd)
f=${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}
remove=0
case ${1:-} in
  --remove) remove=1 ;;
  '') ;;
  *) echo "usage: $0 [--remove]" >&2; exit 2 ;;
esac
[ -f "$f" ] || echo '{}' > "$f"
backup=$f.bak-t3-$(date +%Y%m%d-%H%M%S)
cp "$f" "$backup"
jq --arg d "$here/hooks/" --argjson remove "$remove" '
  def strip: .hooks |= ((. // {})
    | with_entries(.value |= map(.hooks |= map(select(.command | startswith($d) | not)) | select(.hooks | length > 0)))
    | with_entries(select(.value | length > 0)));
  def add(ev; m; cmd; t): .hooks[ev] = ((.hooks[ev] // []) +
    [(if m == null then {} else {matcher: m} end) + {hooks: [{type: "command", command: ($d + cmd), timeout: t}]}]);
  strip
  | if $remove == 1 then . else
      add("UserPromptSubmit"; null; "nudge.sh"; 10)
      | add("PostToolUse"; null; "nudge.sh"; 10)
      | add("Stop"; null; "stop.sh"; 60)
      | add("SessionStart"; "compact"; "inject.sh"; 10)
    end' "$backup" > "$f.tmp"
jq -e . "$f.tmp" > /dev/null
mv "$f.tmp" "$f"
if [ "$remove" = 1 ]; then echo "Removed the T3 hooks from $f. Backup: $backup"; else echo "Installed the T3 hooks in $f. Backup: $backup"; fi
