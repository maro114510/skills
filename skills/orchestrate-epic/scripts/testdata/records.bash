# shellcheck shell=bash
# Test helpers for oe's host-local records, loaded by a bats suite with `load testdata/records`.
#
# - A suite sets OE_STATE_DIR to a directory of its own test, so no test reads another's records or the user's.
# - Every record of repository o/r lives in the file that oe-store.sh names for it.
# - A time is a clock time on the day of the test, written as HH:MM, as in fake-github.jq.

# shellcheck source=SCRIPTDIR/../oe-store.sh
source "${BATS_TEST_DIRNAME}/oe-store.sh"

# Prints the record file of Issue $1 in o/r.
record_file() {
  printf '%s/records/%s/%s.jsonl' "$(state_dir)" "$(repo_key o/r)" "$1"
}

# Saves the records of Issue $1 in o/r, oldest first, one argument per record written as kind@HH:MM.
records() {
  local file r
  file="$(record_file "$1")"
  shift
  mkdir -p "${file%/*}"
  for r in "$@"; do
    printf '{"kind":"%s","at":"2027-01-15T%s:00Z"}\n' "${r%@*}" "${r#*@}"
  done >>"${file}"
}

# Prints the records of Issue $1 in o/r, one JSON object per line, or nothing when it has none.
records_of() {
  local file
  file="$(record_file "$1")"
  [[ ! -e "${file}" ]] || jq -c . "${file}"
}
