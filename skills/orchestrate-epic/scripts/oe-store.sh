# shellcheck shell=bash
# The host-local state of orchestrate-epic: where it lives on this host, and the record store inside it.
# Each subcommand that touches the state sources this file, so none restates the layout.
#
# | Path under the state directory | Holds | Written by |
# |---|---|---|
# | locks.git | One ref per Epic that a session holds | oe lock; read by oe status through lock_held |
# | records/<repo-key>/<issue>.jsonl | One Issue's records, oldest first, one JSON object per line | oe claim, oe attempt, oe verdict, oe update; dropped by oe forget |
# | boards/<repo-key>/<epic> | The Herdr pane of the Epic's board and the server it is on, as JSON | oe board, which overwrites it |
# | waits/<repo-key>/<epic> | The process ID and start time of the Epic's latest oe wait | oe wait, which stops that process first and drops the file when it ends on its own; oe lock release stops that process |
#
# - The state directory is OE_STATE_DIR when set, and orchestrate-epic under XDG_STATE_HOME or ~/.local/state otherwise.
#   Either default lies outside every checkout, so no agent's worktree ever holds the state.
# - An Issue has at most one parent Epic, so its records are keyed by repository and Issue, and oe forget drops an Epic's by its child Issues.
#
# | Record | Fields |
# |---|---|
# | claim | kind, at |
# | attempt | kind, at |
# | verdict | kind, at, sha, state, findings |
# | update | kind, at, sha |
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

# Prints when process $1 started, or nothing when it is not running.
# The text is fixed to UTC and the C locale, so every session reads the same text whatever TZ and locale it runs with.
process_start() {
  LC_ALL=C TZ=UTC0 process_start_local "$1"
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

# Prints the record file of the oe wait for Epic $2 in repository $1.
wait_record() {
  local key
  key="$(repo_key "$1")" || return 1
  printf '%s/waits/%s/%s' "$(state_dir)" "${key}" "$2"
}

# Prints process $1 and every process below it.
process_tree() {
  local child
  printf '%s\n' "$1"
  for child in $(pgrep -P "$1" 2>/dev/null); do
    process_tree "${child}"
  done
}

# Stops the oe wait recorded for Epic $2 in repository $1, unless it is process $3.
# - The record holds the process ID and its start time, so a reused process ID is never stopped.
# - The wait is suspended while its tree is read, then killed before anything below it,
#   so it never sees a failed poll and exits 1, and runs no exit trap that could drop a record a newer wait just wrote.
# - It gets KILL, not TERM: bash 5 prints "Terminated" when it reaps a child that TERM killed, before any trap runs.
stop_recorded_wait() {
  local file pid lstart tree
  file="$(wait_record "$1" "$2")" || return 0
  read -r pid lstart 2>/dev/null <"${file}" || return 0
  [[ "${pid}" =~ ^[1-9][0-9]*$ && "${pid}" != "${3:-}" && -n "${lstart:-}" ]] || return 0
  [[ "$(process_start "${pid}")" == "${lstart}" ]] || return 0
  kill -STOP "${pid}" 2>/dev/null || true
  tree="$(process_tree "${pid}")"
  kill -KILL "${pid}" 2>/dev/null || true
  # shellcheck disable=SC2086 # one process ID per word
  kill -TERM ${tree} 2>/dev/null || true
}
