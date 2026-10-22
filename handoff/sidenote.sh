# shellcheck shell=bash
# Optional side note, off by default. handoff-nudge.sh starts the runs, handoff-inject.sh names the
# note in the restore header. A side model keeps a note of the user's rules, approvals, open promises
# and decisions while the main model works, so the handoff does not depend on the main model's memory
# at the stop limit.
# Turn it on: set HANDOFF_NOTE in the "env" block of ~/.claude/settings.json:
#   haiku  claude -p --model claude-haiku-5-5 --effort xhigh on the Claude account (--bare is not
#          used: it needs an API key)
#   pi     pi -p --model opencode2api/minimax-m3.1-flash-free (free OpenAI-compatible endpoint)
# Other values or unset: off.
#
# Runs: the first at sidenote_start tokens, then after each sidenote_step new tokens, and one last run
# when the warn message arrives. Each run is a new process: it reads the note and the transcript text
# since the last good run (no tool output), writes the updated note, and stops. One run at a time
# (lock). A run moves the read position only after it succeeds, so a skipped or failed run loses no
# text. The note belongs to the window (PID and start time), so after /clear the new session keeps
# the same note and a late last run still updates it.
sidenote_start=70000 sidenote_step=20000

# sidenote_engine: prints the engine. Exit 1 when the side note is off.
sidenote_engine() { case ${HANDOFF_NOTE:-} in haiku | pi) echo "$HANDOFF_NOTE" ;; *) return 1 ;; esac; }

# handoff_dir <transcript>: prints the handoff folder of the session. The name is the project folder
# of the transcript: Claude Code names it after the start folder, so a cd in the session does not move it.
handoff_dir() { local p=${1%/*}; echo "$HOME/.claude/handoffs/${p##*/}"; }

# sidenote_file <handoff folder> <pid> <start time>: prints the note path of the window.
sidenote_file() { echo "$1/window-$2-$3.note.md"; }

# sidenote_copy <note path>: the line that the handoff messages add when the side note is on.
sidenote_copy() { echo "A side model keeps a note of the user's rules, approvals, open promises and decisions at $1. Before you write the handoff, read it if it exists, and copy each still-valid item that the handoff lacks. Check each item against what you know: the side model can be wrong."; }

sidenote_prompt="You keep a note for an AI coding agent. Below are the current note and the newest text of the session between the user and the agent (tool output is left out). Print the complete updated note with these sections:
## Constraints: user rules and limits for the task, approvals and their limits. Mark each as user-stated or inferred. Quote short binding user words.
## Owed to the user: questions without a visible answer, and promises that the agent made and did not keep.
## Decisions: choices and their reasons, and failed approaches with the reason.
## Facts: paths, commands and numbers that a new session needs.
Leave out rules from CLAUDE.md, AGENTS.md and system reminders: the agent always has them. Keep every item of the current note unless the new text shows that it is done or replaced. The note can come from earlier sessions: keep their items too. One line per item. Write none for an empty section. Do not invent: list only what the text shows. The user dictates by voice: after a likely misheard word, add [= meaning, assumed]. Keep the note under 60 lines. Print only the note."

# sidenote_tick <engine> <transcript> <tokens> <warn> <note> <state dir> <pid> <start time>
# Starts one detached run if a run is due and no run works. Returns at once.
sidenote_tick() {
  local engine=$1 tp=$2 tokens=$3 warn=$4 note=$5 st=$6 pid=$7 start=$8
  local at=$st/pid-$pid.note.at lock=$st/pid-$pid.note.lock s t l f last=0 final=0
  if read -r s t l f 2>/dev/null < "$at" && [ "$s" = "$start" ] && [ "$t" = "$tp" ] \
    && [[ $l =~ ^[0-9]+$ && $f =~ ^[01]$ ]]; then
    last=$l final=$f
  fi
  (( (last == 0 && tokens >= sidenote_start) || (last > 0 && tokens >= last + sidenote_step) \
    || (tokens >= warn && final == 0) )) || return 0
  # A run ends within 300 s. A lock older than 6 min belongs to a run that died.
  [ -z "$(find "$lock" -mmin +6 2>/dev/null)" ] || rm -f "$lock"
  # A run works: ask it for one more pass, so the text since its start is not lost.
  (set -o noclobber; : > "$lock") 2>/dev/null || { : > "$st/pid-$pid.note.want"; return 0; }
  (( tokens >= warn )) && final=1
  printf '%s %s %s %s\n' "$start" "$tp" "$tokens" "$final" > "$at"
  mkdir -p "${note%/*}"
  # shellcheck disable=SC2016  # the inner script expands its own variables
  setsid nohup env -u TMUX -u TMUX_PANE CLAUDE_CODE_SESSION_ATTENDED=0 \
    bash -c '
      engine=$1 tp=$2 note=$3 pos=$4 lock=$5 start=$6 prompt=$7
      chunk=$note.chunk in=$note.in want=${pos}.want
      trap "rm -f \"\$lock\" \"\$chunk\" \"\$in\" \"\$note.tmp\"" EXIT
      rm -f "$want"
      once() {
      off=0
      if read -r s t o 2>/dev/null < "$pos" && [ "$s" = "$start" ] && [ "$t" = "$tp" ] && [[ $o =~ ^[0-9]+$ ]]; then off=$o; fi
      size=$(stat -c %s "$tp") || return 0
      (( size > off )) || return 0
      tail -c +$((off + 1)) "$tp" | head -c $((size - off)) > "$chunk"
      # A partial last line stays for the next run.
      [ -z "$(tail -c 1 "$chunk")" ] || sed -i "\$d" "$chunk"
      new=$((off + $(stat -c %s "$chunk")))
      # The restore header filter, without system reminders (CLAUDE.md and hook text that Claude always
      # gets). The newest 400,000 characters (about 100k tokens) at most.
      text=$(jq -Rr '\''fromjson? // empty | select(.type == "user" or .type == "assistant") | (.message.content | if type == "string" then . else (map(select(.type == "text") | .text) | join(" ")) end | gsub("\n"; " ") | gsub("<system-reminder>.*?</system-reminder>"; "")) as $t | select($t | test("\\S")) | "[\(.type)] \($t)"'\'' "$chunk" | tail -c 400000)
      if [ -n "$text" ]; then
        { echo "=== Current note"; cat "$note" 2>/dev/null || echo none; echo "=== Newest session text"; echo "$text"; } > "$in"
        cd "${note%/*}" || return 0
        case $engine in
          haiku) timeout 300 claude -p --model claude-haiku-5-5 --effort xhigh --no-session-persistence \
                   --settings "{\"disableAllHooks\": true}" "$prompt" < "$in" > "$note.tmp" ;;
          pi)    timeout 300 pi -p --model opencode2api/minimax-m3.1-flash-free --no-session --no-context-files \
                   "@$in" "$prompt" < /dev/null > "$note.tmp" ;;
        esac && [ -s "$note.tmp" ] && mv "$note.tmp" "$note" || return 0
      fi
      printf "%s %s %s\n" "$start" "$tp" "$new" > "$pos"
      }
      # One more pass if a tick came while this run worked (at most 2 passes, within the 6 min lock).
      once; [ -e "$want" ] && rm -f "$want" && touch "$lock" && once
    ' sidenote "$engine" "$tp" "$note" "$st/pid-$pid.note" "$lock" "$start" "$sidenote_prompt" \
    > /dev/null 2>&1 < /dev/null &
}
