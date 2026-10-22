# shellcheck shell=bash
# Shared functions of the T3 hooks (PLAN.md, "Design"). Facts: FINDINGS.md F1, L1-L3.
# Overrides, for test.sh only: T3_HANDOFF_RUNTIME (folder of the T3 binaries), T3_HANDOFF_USERDATA
# (T3 userdata folder), T3_HANDOFF_CLI (t3 CLI path).

# shellcheck disable=SC2034  # used by the hooks that source this file
t3_handoff_dir=$(cd "${BASH_SOURCE[0]%/*}/../../handoff" && pwd)
# Folders of the T3 server binaries: the desktop app in WSL (wsl-runtime/sha256-…/t3) and the Linux
# service (runtime/versions/<version>/t3, `t3code.service`).
t3_runtimes=${T3_HANDOFF_RUNTIME:-$HOME/.t3/wsl-runtime:$HOME/.t3/runtime}
t3_userdata=${T3_HANDOFF_USERDATA:-$HOME/.t3/userdata}

# t3_server_exe: prints the exe of the T3 server that runs this Claude process. The server is the
# direct parent of $CLAUDE_PID (F1). Walks up a few levels in case a wrapper sits between them.
t3_server_exe() {
  local p=${CLAUDE_PID:-} exe r _
  for _ in 1 2 3 4; do
    p=$(awk '{print $4}' "/proc/$p/stat" 2>/dev/null) || return 1
    [[ $p =~ ^[0-9]+$ ]] && (( p > 1 )) || return 1
    exe=$(readlink "/proc/$p/exe" 2>/dev/null)
    local IFS=:
    for r in $t3_runtimes; do
      case $exe in "$r"/*) echo "$exe"; return 0 ;; esac
    done
  done
  return 1
}

# t3_session: true if this Claude process runs under T3 Code. CLAUDE_CODE_ENTRYPOINT=sdk-ts alone
# is not proof: other SDK programs set it too (P3).
t3_session() { [ -n "${CLAUDE_PID:-}" ] && t3_server_exe > /dev/null; }

# t3_cli: prints the t3 CLI path. The server binary is the CLI (L1, L2).
t3_cli() { if [ -n "${T3_HANDOFF_CLI:-}" ]; then echo "$T3_HANDOFF_CLI"; else t3_server_exe; fi; }

# t3_thread_id <session id>: prints the T3 thread id of a Claude session id. The provider log of a
# thread holds every session id of the thread (L3). Its name is the thread id with ':' as '-', so
# each candidate is checked with `t3 thread show`. Prints nothing if no thread matches.
t3_thread_id() {
  local sid=$1 cli log name cand
  [[ $sid =~ ^[A-Za-z0-9-]+$ ]] || return 1
  cli=$(t3_cli) || return 1
  # Newest log first: a forked thread can contain the session id of its parent.
  log=$(grep -lF "\"$sid\"" "$t3_userdata"/logs/provider/events.*.log* 2>/dev/null | xargs -r ls -t | head -n 1)
  [ -n "$log" ] || return 1
  name=${log##*/events.}
  name=${name%%.log*}
  for cand in "$name" "${name/-/:}"; do
    if timeout 20 "$cli" thread show "$cand" --json > /dev/null 2>&1; then
      echo "$cand"
      return 0
    fi
  done
  return 1
}
