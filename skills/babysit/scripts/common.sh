# shellcheck shell=bash
# Helpers shared by the babysit scripts. Sourcing it only defines functions.

# Prints the current epoch seconds; BABYSIT_NOW pins it for tests.
babysit_now() {
  printf '%s\n' "${BABYSIT_NOW:-$(date +%s)}"
}

# Succeeds when $1 is <owner>/<repo>. Rejects `.` and `..` because the parts become ledger path segments.
babysit_valid_repo() {
  [[ "$1" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || return 1
  case "/$1/" in
  */./* | */../*) return 1 ;;
  *) return 0 ;;
  esac
}

babysit_valid_pr() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

# Prints the ledger path for <owner/repo> $1 and PR $2. Fails outside a Git repository.
babysit_ledger_path() {
  local dir
  dir="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
  [[ -n "${dir}" ]] || return 1
  # GitHub names are case-insensitive, so Owner/Repo and owner/repo share one ledger and one lock.
  printf '%s/babysit/%s/%s.json\n' "${dir}" "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" "$2"
}

# Prints the ledger at $1 as one JSON line, or {} when it does not exist. Fails when it is not a JSON object.
babysit_ledger_read() {
  if [[ ! -e "$1" ]]; then
    printf '{}\n'
    return 0
  fi
  jq -ce 'if type == "object" then . else error("ledger is not an object") end' "$1" 2>/dev/null
}

# Writes the JSON on stdin to $1 through a temp file renamed into place, so a reader never sees half a ledger.
babysit_ledger_write() {
  local tmp
  mkdir -p "$(dirname "$1")" || return 1
  tmp="$(mktemp "$1.XXXXXX")" || return 1
  if ! jq -c . >"${tmp}"; then
    rm -f "${tmp}"
    return 1
  fi
  mv -f "${tmp}" "$1"
}
