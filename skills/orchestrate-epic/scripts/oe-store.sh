# shellcheck shell=bash
# The host-local state of orchestrate-epic: where it lives on this host, and the record store inside it.
# Each subcommand that touches the state sources this file, so none restates the layout.
#
# | Path under the state directory | Holds | Written by |
# |---|---|---|
# | locks.git | One ref per Epic that a session holds | oe lock |
# | records/<repo-key>/<issue>.jsonl | One Issue's records, oldest first, one JSON object per line | oe claim, oe attempt, oe verdict; dropped by oe forget |
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
# Returns 1 with the reason on stderr when the file cannot be read or holds anything but records.
records_read() {
  local file
  file="$(record_path "$1" "$2")" || return 1
  if [[ ! -e "${file}" ]]; then
    printf '[]\n'
    return 0
  fi
  jq -cs 'if all(.[]; type == "object" and (.kind | type) == "string" and (.at | type) == "string")
    then . else error("not a record") end' "${file}" 2>/dev/null || {
    echo "cannot read the records in ${file}" >&2
    return 1
  }
}

# Appends the record $3, a JSON object, to Issue $2 in repository $1.
# Returns 1 with the reason on stderr, and leaves the file as it was, when the store cannot be read or written.
records_add() {
  local file tmp
  file="$(record_path "$1" "$2")" || return 1
  # Reading first refuses to append to a file that holds anything but records.
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
    jq -ce 'if type == "object" and (.kind | type) == "string" and (.at | type) == "string" then . else error("not a record") end' \
      <<<"$3" >>"${tmp}" 2>/dev/null &&
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
