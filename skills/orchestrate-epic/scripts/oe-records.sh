#!/usr/bin/env bash
# oe records
#
# Prints an Issue's records on this host, so an Owner reads them without knowing where they live. It writes nothing.
#
# Usage
#
#   oe records <owner/repo> <issue-number>
#
# Output
#
# - The records from the latest claim on, or every record without a claim, oldest first, as JSON lines.
# - oe-store.sh lists each record's fields.
#
# Exit codes
#
# | Code | Meaning | Output |
# |---|---|---|
# | 0 | The records were read | The records |
# | 1 | The record store could not be read | Nothing |
# | 2 | The arguments are invalid | Nothing |
set -uo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
source "${dir}/oe-store.sh"

usage() {
  echo "$1" >&2
  echo "Usage: oe records <owner/repo> <issue-number>" >&2
  exit 2
}

[[ $# -eq 2 ]] || usage "Expected <owner/repo> <issue-number>"
[[ "$1" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || usage "Invalid repository: $1"
[[ "$2" =~ ^[1-9][0-9]*$ ]] || usage "Invalid Issue number: $2"

records="$(records_read "$1" "$2")" || {
  echo "oe records: the records of Issue #$2 are unreadable" >&2
  exit 1
}
jq -c '(map(.kind == "claim") | rindex(true)) as $claim | .[($claim // 0):][]' <<<"${records}"
