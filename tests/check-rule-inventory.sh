#!/usr/bin/env bash
# Structural checker for a rule inventory, such as docs/design/orchestrate-epic-v2/rule-inventory.tsv.
#
# Usage: check-rule-inventory.sh [inventory.tsv]
#
# It validates structure only, never whether a rule is correct. The format:
#   - The first line is `#status: incomplete` or `#status: complete`. Other `#` lines are comments.
#   - The first non-comment line is the header below, then one tab-separated row per rule:
#       id  source  quote  rule  disposition  issue  owner  reason
#   - `-` marks an empty field. Paths are relative to the repository root.
#
# Rejected in every mode:
#   - a row without exactly 8 columns, a malformed or duplicate id, an empty source, quote, or rule
#   - a disposition other than kept, changed, retired, or `-`; an issue other than `#<n>` or `-`
#   - a changed or retired row without a reason
#   - a dangling source anchor: the source file is missing or does not contain the quote verbatim
#   - a dangling owner anchor: `prose:<path>#<quote>` whose file lacks the quote, or
#     `test:<path>::<name>` whose file lacks the name; an empty quote or name; any other owner form
#     A test owner is matched as text in its file, so it proves the name exists, not that it runs.
# Rejected only in complete mode: a row whose disposition or owner is `-`.
#
# Exit codes: 0 valid, 1 invalid (one `ERROR` line per problem, naming the row), 2 usage.

set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
inventory="${1:-${root}/docs/design/orchestrate-epic-v2/rule-inventory.tsv}"

if [[ "$#" -gt 1 ]] || [[ ! -f "${inventory}" ]]; then
  printf 'usage: %s [inventory.tsv]; file not found: %s\n' "$0" "${inventory}" >&2
  exit 2
fi

errors=0
fail() {
  printf 'ERROR %s\n' "$1"
  errors=$((errors + 1))
}

status_line="$(head -n 1 "${inventory}")"
case "${status_line}" in
'#status: complete') mode=complete ;;
'#status: incomplete') mode=incomplete ;;
*)
  printf 'ERROR line 1: expected "#status: incomplete" or "#status: complete", got "%s"\n' "${status_line}"
  exit 1
  ;;
esac

# Row-local rules in awk. Prints ERROR lines, then one ANCHOR line per row for the file checks below.
structural="$(awk -F'\t' -v mode="${mode}" '
  function err(where, msg) { print "ERROR " where ": " msg }
  /^#/ { next }
  !seen_header {
    seen_header = 1
    if ($0 != "id\tsource\tquote\trule\tdisposition\tissue\towner\treason")
      err("line " NR, "header must be: id source quote rule disposition issue owner reason, tab-separated")
    next
  }
  /^[[:space:]]*$/ { next }
  {
    if (NF != 8) { err("line " NR, "expected 8 columns, got " NF); next }
    id = $1; where = id " (line " NR ")"
    if (id !~ /^[A-Z]+-[0-9][0-9][0-9]?$/) err(where, "malformed id, expected AREA-NN")
    if (id in ids) err(where, "duplicate id, first seen on line " ids[id])
    else ids[id] = NR
    if ($2 == "-" || $2 == "") err(where, "empty source")
    if ($3 == "-" || $3 == "") err(where, "empty quote")
    if ($4 == "-" || $4 == "") err(where, "empty rule")
    if ($5 !~ /^(kept|changed|retired|-)$/) err(where, "disposition must be kept, changed, retired, or -")
    if ($6 !~ /^(#[0-9]+|-)$/) err(where, "issue must be #<number> or -")
    if (($5 == "changed" || $5 == "retired") && ($8 == "-" || $8 == "")) err(where, $5 " row needs a reason")
    if (mode == "complete" && $5 == "-") err(where, "missing disposition in a complete inventory")
    if (mode == "complete" && $7 == "-") err(where, "missing owner in a complete inventory")
    rows++
    print "ANCHOR\t" id "\t" NR "\t" $2 "\t" $3 "\t" $7
  }
  END {
    if (!seen_header) err("file", "missing header row")
    print "ROWS\t" rows + 0
  }
' "${inventory}")"

rows=0
while IFS= read -r line; do
  case "${line}" in
  ERROR*)
    printf '%s\n' "${line}"
    errors=$((errors + 1))
    ;;
  ROWS*) rows="${line#ROWS?}" ;;
  ANCHOR*)
    IFS=$'\t' read -r _ id nr source quote owner <<<"${line}"
    where="${id} (line ${nr})"
    if [[ ! -f "${root}/${source}" ]] || ! grep -qF -- "${quote}" "${root}/${source}"; then
      fail "${where}: dangling source anchor, \"${quote}\" not found in ${source}"
    fi
    case "${owner}" in
    -) ;;
    prose:*'#'*)
      path="${owner#prose:}" && path="${path%%#*}"
      needle="${owner#prose:*#}"
      if [[ -z "${needle}" ]] || [[ ! -f "${root}/${path}" ]] || ! grep -qF -- "${needle}" "${root}/${path}"; then
        fail "${where}: dangling owner anchor, \"${needle}\" not found in ${path}"
      fi
      ;;
    test:*::*)
      path="${owner#test:}" && path="${path%%::*}"
      needle="${owner#test:*::}"
      if [[ -z "${needle}" ]] || [[ ! -f "${root}/${path}" ]] || ! grep -qF -- "${needle}" "${root}/${path}"; then
        fail "${where}: dangling owner anchor, test ${needle} not found in ${path}"
      fi
      ;;
    *) fail "${where}: owner must be -, prose:<path>#<quote>, or test:<path>::<name>" ;;
    esac
    ;;
  esac
done <<<"${structural}"

if [[ "${errors}" -gt 0 ]]; then
  printf '%s error(s) in %s\n' "${errors}" "${inventory}"
  exit 1
fi
printf 'OK %s rows (%s)\n' "${rows}" "${mode}"
