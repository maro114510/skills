# shellcheck shell=bash
# The host-local state of orchestrate-epic: where it lives on this host, and the record store inside it.
# Each subcommand that touches the state sources this file, so none restates the layout.
#
# | Path under the state directory | Holds | Written by |
# |---|---|---|
# | locks.git | One ref per Epic that a session holds | oe lock; read by oe status through lock_held |
# | records/<repo-key>/<issue>.jsonl | One Issue's records, oldest first, one JSON object per line | oe claim, oe attempt, oe start, oe verdict; dropped by oe forget |
# | boards/<repo-key>/<epic> | The Herdr pane of the Epic's board and the server it is on, as JSON | oe board, which overwrites it |
# | waits/<repo-key>/<epic> | The process ID and start time of the Epic's running oe wait | oe wait, which writes it only while no other wait runs and drops it when it ends on its own; oe lock release, and an acquire by another session, stop that process |
# | notices/<repo-key>/<epic> | Each item that needed the person at the latest read, with when the person was last notified about it, as tab-separated lines | oe wait, only with git config skills.notify set, which overwrites it |
#
# - The state directory is OE_STATE_DIR when set, and orchestrate-epic under XDG_STATE_HOME or ~/.local/state otherwise.
#   Either default lies outside every checkout, so no agent's worktree ever holds the state.
# - An Issue has at most one parent Epic, so its records are keyed by repository and Issue, and oe forget drops an Epic's by its child Issues.
#
# | Record | Fields |
# |---|---|
# | claim | kind, at |
# | attempt | kind, at |
# | run | kind, at, role: owner or verifier |
# | verdict | kind, at, sha, state, findings |
#
# - A run record marks an agent oe start started. oe ready counts the agent as running while the record is no older than
#   the lock of the session holding the Epic, and the agent's worktree, which the session removes once the agent ends, exists.
#
# - at is this host's UTC time in ISO 8601 without fractions, the form GitHub uses, so a record and a GitHub event compare as strings.
#   The comparison assumes a synced clock; the Design Doc accepts the risk of skew.
# - A record file is replaced whole through a rename, so a reader never sees half of a write.
#   Only one writer touches an Issue's file at a time, because oe lock admits one session per Epic and one agent runs per Issue.

# Prints the state directory.
state_dir() {
  printf '%s' "${OE_STATE_DIR:-${XDG_STATE_HOME:-${HOME}/.local/state}/orchestrate-epic}"
}

# Prints the key of repository $1 in the state.
# A path or ref component cannot hold every repository name, such as one ending in .lock, so the lowercased name is hashed.
repo_key() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | git hash-object --stdin
}

# Prints the record file of Issue $2 in repository $1.
record_path() {
  local key
  key="$(repo_key "$1")" || return 1
  printf '%s/records/%s/%s.jsonl' "$(state_dir)" "${key}" "$2"
}

# Prints the current time as a record's at: OE_NOW in epoch seconds when set, so tests control it, or the clock.
record_now() {
  local now="${OE_NOW:-$(date -u +%s)}"
  [[ "${now}" =~ ^[0-9]+$ ]] || {
    echo "OE_NOW must be epoch seconds" >&2
    return 1
  }
  jq -nr --argjson t "${now}" '$t | todate'
}

# Prints the records of Issue $2 in repository $1 as one JSON array, oldest first, and [] when it has none.
# Returns 1 with the reason on stderr when the file cannot be read as JSON lines.
records_read() {
  local file
  file="$(record_path "$1" "$2")" || return 1
  if [[ ! -e "${file}" ]]; then
    printf '[]\n'
    return 0
  fi
  jq -cs . "${file}" 2>/dev/null || {
    echo "cannot read the records in ${file}" >&2
    return 1
  }
}

# Appends the record $3, a JSON object, to Issue $2 in repository $1.
# Returns 1 with the reason on stderr, and leaves the file as it was, when the store cannot be read or written.
records_add() {
  local file tmp
  file="$(record_path "$1" "$2")" || return 1
  # Reading first refuses to append to a file that is not JSON lines.
  records_read "$1" "$2" >/dev/null || return 1
  mkdir -p "${file%/*}" 2>/dev/null || {
    echo "cannot create ${file%/*}" >&2
    return 1
  }
  tmp="$(mktemp "${file%/*}/.${2}.XXXXXX" 2>/dev/null)" || {
    echo "cannot write in ${file%/*}" >&2
    return 1
  }
  if { [[ ! -e "${file}" ]] || cat "${file}"; } >"${tmp}" &&
    jq -c . <<<"$3" >>"${tmp}" 2>/dev/null &&
    mv -f "${tmp}" "${file}"; then
    return 0
  fi
  rm -f "${tmp}"
  echo "cannot write the record to ${file}" >&2
  return 1
}

# Drops every record of Issue $2 in repository $1, and the repository's directory once it holds no Issue.
# Returns 1 with the reason on stderr when the file stays.
records_drop() {
  local file
  file="$(record_path "$1" "$2")" || return 1
  rm -f "${file}" 2>/dev/null && [[ ! -e "${file}" ]] || {
    echo "cannot remove ${file}" >&2
    return 1
  }
  rmdir "${file%/*}" 2>/dev/null || true
}

# The lock store: one ref per Epic, whose blob names the holding session.
# oe lock writes it; every function below only reads it.

# Prints the lock store.
lock_store() {
  printf '%s/locks.git' "$(state_dir)"
}

# Prints the ref of the lock of Epic $2 in repository $1.
lock_ref() {
  printf 'refs/oe-lock/%s/%s' "$(repo_key "$1")" "$2"
}

# Prints field $1 of the holder blob $2.
lock_field() {
  git --git-dir="$(lock_store)" cat-file -p "$2" 2>/dev/null | sed -n "s/^$1=//p" | head -n1
}

# Prints when process $1 started, as ps prints it under the caller's TZ and locale, or nothing when it is not running.
process_start_local() {
  ps -o lstart= -p "$1" 2>/dev/null | sed -e 's/^ *//' -e 's/ *$//'
}

# Prints the second since the epoch when process $1 started, read from the kernel, or nothing when it is not running.
# - Linux: boot time plus the start in clock ticks, as procps computes it.
# - macOS: the sysctl KERN_PROC_PID, whose struct kinfo_proc opens with p_starttime; 202 is SYS___sysctl.
process_start_epoch() {
  if [[ -r /proc/stat ]]; then
    local stat fields btime
    stat="$(cat "/proc/$1/stat" 2>/dev/null)" || return 0
    read -ra fields <<<"${stat##*) }"
    btime="$(sed -n 's/^btime //p' /proc/stat)"
    printf '%s\n' "$((btime + fields[19] / $(getconf CLK_TCK)))"
  else
    perl -e '
      my $buf = "\0" x 4096;
      my $len = pack("Q", length $buf);
      syscall(202, pack("i4", 1, 14, 1, $ARGV[0]), 4, $buf, $len, 0, 0) == 0 && unpack("Q", $len) or exit;
      print unpack("q", $buf), "\n";
    ' "$1" 2>/dev/null
  fi
}

# Prints when process $1 started, or nothing when it is not running.
# - The text is fixed to UTC and the C locale, so every session reads the same text whatever TZ and locale it runs with.
# - When ps prints nothing, the kernel's start is printed in the text ps uses, because a sandbox such as srt refuses to start the setuid ps.
process_start() {
  local start
  start="$(LC_ALL=C TZ=UTC0 process_start_local "$1")"
  if [[ -z "${start}" ]]; then
    start="$(process_start_epoch "$1")"
    [[ "${start}" =~ ^[0-9]+$ ]] || return 0
    start="$(LC_ALL=C perl -MPOSIX -e 'print strftime("%a %b %e %H:%M:%S %Y", gmtime($ARGV[0]))' "${start}")"
  fi
  printf '%s\n' "${start}"
}

# Succeeds when the holder recorded in blob $1 is still running: its process exists and started when it did.
# A lock taken before process_start fixed TZ and the locale holds the text in its taker's, so it still matches a reader with the same ones.
lock_holder_running() {
  local pid lstart
  pid="$(lock_field pid "$1")"
  lstart="$(lock_field lstart "$1")"
  [[ "${pid}" =~ ^[1-9][0-9]*$ && -n "${lstart}" ]] || return 1
  [[ "$(process_start "${pid}")" == "${lstart}" || "$(process_start_local "${pid}")" == "${lstart}" ]]
}

# Succeeds when a running session holds the lock of Epic $2 in repository $1. Creates nothing.
lock_held() {
  local blob
  [[ -d "$(lock_store)" ]] || return 1
  blob="$(git --git-dir="$(lock_store)" rev-parse --quiet --verify "$(lock_ref "$1" "$2")")" || return 1
  lock_holder_running "${blob}"
}

# Prints when the running session that holds the lock of Epic $2 in repository $1 took it, in a record's at form.
# Fails when no running session holds it. Creates nothing.
lock_started() {
  local blob
  [[ -d "$(lock_store)" ]] || return 1
  blob="$(git --git-dir="$(lock_store)" rev-parse --quiet --verify "$(lock_ref "$1" "$2")")" || return 1
  lock_holder_running "${blob}" || return 1
  lock_field started "${blob}"
}

# Prints the record file of the oe wait for Epic $2 in repository $1.
wait_record() {
  local key
  key="$(repo_key "$1")" || return 1
  printf '%s/waits/%s/%s' "$(state_dir)" "${key}" "$2"
}

# Prints the record file of the notifications oe wait sent for Epic $2 in repository $1.
notice_record() {
  local key
  key="$(repo_key "$1")" || return 1
  printf '%s/notices/%s/%s' "$(state_dir)" "${key}" "$2"
}

# Prints process $1 and every process below it.
process_tree() {
  local child
  printf '%s\n' "$1"
  for child in $(pgrep -P "$1" 2>/dev/null); do
    process_tree "${child}"
  done
}

# Prints the process ID of the oe wait recorded for Epic $2 in repository $1 while it runs, unless it is process $3.
# The record holds the process ID and its start time, so a reused process ID never counts.
recorded_wait() {
  local file pid lstart
  file="$(wait_record "$1" "$2")" || return 0
  read -r pid lstart 2>/dev/null <"${file}" || return 0
  [[ "${pid}" =~ ^[1-9][0-9]*$ && "${pid}" != "${3:-}" && -n "${lstart:-}" ]] || return 0
  [[ "$(process_start "${pid}")" == "${lstart}" ]] || return 0
  printf '%s' "${pid}"
}

# Stops the oe wait recorded for Epic $2 in repository $1.
# - The wait is suspended while its tree is read, then killed before anything below it,
#   so it never sees a failed poll and exits 1, and runs no exit trap that could drop a record.
# - It gets KILL, not TERM: bash 5 prints "Terminated" when it reaps a child that TERM killed, before any trap runs.
stop_recorded_wait() {
  local pid tree
  pid="$(recorded_wait "$1" "$2")"
  [[ -n "${pid}" ]] || return 0
  kill -STOP "${pid}" 2>/dev/null || true
  tree="$(process_tree "${pid}")"
  kill -KILL "${pid}" 2>/dev/null || true
  # shellcheck disable=SC2086 # one process ID per word
  kill -TERM ${tree} 2>/dev/null || true
}
