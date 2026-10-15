# Handoff hooks review (due 2026-10-29)

The handoff hooks went live on 2026-10-15. Review two weeks of real sessions. Decide: keep, tune the
limits or the handoff format, or remove the hooks.

## Questions

1. Did Claude obey the messages? Hard message → handoff file written → user told to type `/clear`.
2. Did the new session continue well from the handoff? Count re-explanations and repeated dead ends.
3. Did native compaction still run? Each compaction above the hard limit is a missed handoff.
4. Size: tokens at the hard message, at the handoff write, and at the first reply after `/clear`.
5. Did the warn tier start too late or too early? Did work run past the hard limit for long?
6. Was the transcript tail useful, or only noise?

## Data

```sh
cd ~/.claude/projects
since=2026-10-15

# Sessions that got a [handoff] message, and which tier
rg -l --glob '*.jsonl' '\[handoff\] Context is at' . | while read -r f; do
  [[ $(stat -c %y "$f") > $since ]] || continue
  printf '%s warn=%s hard=%s\n' "$f" \
    "$(rg -c 'Do not write the handoff yet' "$f")" "$(rg -c 'Write the handoff to|write the handoff to' "$f")"
done

# Handoffs written and used
ls -la ~/.claude/handoffs/*/
cat ~/.claude/handoffs/*/*.used.md | wc -w     # total words; divide by file count

# Native compactions since the start (trigger and tokens before)
rg -l --glob '*.jsonl' '"compact_boundary"' . | xargs -r jq -c \
  'select(.subtype == "compact_boundary") | [.timestamp, .compactMetadata.trigger, .compactMetadata.preTokens]' \
  | awk -v s="$since" '$0 > "[\"" s'

# Restored sessions (inject hook output) and their first-reply token count
rg -l --glob '*.jsonl' 'Handoff restored after /clear' .
```

For each restored session, read the handoff and the first 5 turns after `/clear`. Note what the
new session had to ask for or rediscover.

## Decision record

| Question | Finding | Change |
|---|---|---|
| Obeyed | | |
| Continuation quality | | |
| Missed handoffs | | |
| Limits | | |
| Tail | | |

After the review, remove the reminder line from `~/.claude/CLAUDE.md` ("Context handoff" section).
