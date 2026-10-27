#!/usr/bin/env bash
# Guards the orchestrate-epic v2 candidate, which must stay outside skill discovery and drive oe only.
#
# Usage: check-candidate.sh [candidate-dir]
#   candidate-dir defaults to docs/design/orchestrate-epic-v2/candidate.
#
# It lists every violation, one per line as <file>:<line>: <what>, and then exits 1:
#   - a file named SKILL.md anywhere under the directory, since discovery would load it (Epic #277, D7)
#   - a candidate agent with a frontmatter key other than name and description, which includes a model pin
#   - in a fenced bash, sh, shell, or zsh block, a command that is not on the allow-list below
#   - an emoji anywhere in a markdown file
#
# The allow-list is the whole of what the prose may run. Every line is an oe call, or one of:
#   git fetch origin <branch>      updates a remote-tracking ref only
#   sleep <seconds>                waits between polls
#   mktemp                         makes a file for a report
#   name="/literal/path"           names that file in a later call, since every call is its own shell
#   cat >"$file" <<'TAG'           writes the report, and only that form of cat is allowed
#   gh issue view ...              reads an Issue
#   gh api repos/... ...           reads, and fails when a flag makes it write
# A line may redirect, and may open a heredoc whose body is data and is never judged. It may not chain a
# second command with && || ; | or &, or substitute one with $( ) or backticks, except mktemp assigned to a variable.
# Fenced blocks of any other language, and unlabeled ones, are text and are not judged.
#
# Exit codes: 0 clean, 1 violations, 2 usage error.

set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
dir="${1:-${repo_root}/docs/design/orchestrate-epic-v2/candidate}"

if [[ "$#" -gt 1 ]] || [[ ! -d "${dir}" ]]; then
  printf 'usage: %s [candidate-dir]; not a directory: %s\n' "$0" "${dir}" >&2
  exit 2
fi
dir="$(cd "${dir}" && pwd)"

status=0
fail() {
  printf '%s\n' "$1"
  status=1
}

while IFS= read -r path; do
  fail "${path#"${dir}"/}:1: a candidate file is never named SKILL.md, or skill discovery would load it"
done < <(find "${dir}" -name SKILL.md -type f | sort)

if [[ -d "${dir}/agents" ]]; then
  if ! frontmatter="$(bash "${script_dir}/validate-agent-portability.sh" "${dir}/agents" 2>&1)"; then
    fail "${frontmatter}"
  fi
fi

# shellcheck disable=SC2016 # The awk program is single-quoted on purpose.
judge='
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
function violation(msg) { printf "%s:%d: %s\n", rel, FNR, msg; bad = 1 }
function judge(t,   s) {
  if (t ~ /^[A-Za-z_][A-Za-z0-9_]*="[^"$`\\]*"$/) return
  if (t ~ /^[A-Za-z_][A-Za-z0-9_]*="\$\(mktemp( [^)"]*)?\)"$/) return
  if (t ~ /\$\(|`/) { violation("substitutes a command: " substr(t, 1, 60)); return }
  s = t
  gsub(/\047[^\047]*\047/, "\047\047", s)
  gsub(/"[^"]*"/, "\"\"", s)
  if (s ~ /[;|&]/) { violation("chains a second command: " substr(t, 1, 60)); return }
  if (t ~ /^oe( |$)/) return
  if (t ~ /^git fetch origin( |$)/) return
  if (t ~ /^sleep [0-9]+$/) return
  if (t ~ /^mktemp( |$)/) return
  if (t ~ /^cat >"\$[A-Za-z_][A-Za-z0-9_]*" <<[\047"]?[A-Za-z_][A-Za-z0-9_]*[\047"]?$/) return
  if (t ~ /^gh issue view( |$)/) return
  if (t ~ /^gh api repos\// && t !~ / (-X|--method|-f|-F|--field|--raw-field|--input)( |=|$)/) return
  violation("is not an oe call or an allowed read: " substr(t, 1, 60))
}
FNR == 1 { infence = 0; judged = 0; hd = ""; cont = 0 }
{
  line = $0
  if (!infence && match(line, /^[ \t]*```/)) {
    lang = trim(substr(line, RLENGTH + 1))
    infence = 1; judged = (lang ~ /^(bash|sh|shell|zsh)$/); hd = ""; cont = 0
    next
  }
  if (infence && line ~ /^[ \t]*```[ \t]*$/) { infence = 0; judged = 0; next }
  if (!infence || !judged) next
  if (hd != "") { if (trim(line) == hd) hd = ""; next }
  t = trim(line)
  if (t == "" || t ~ /^#/) next
  if (cont) { cont = (t ~ /\\$/); next }
  cont = (t ~ /\\$/)
  if (match(t, /<<-?[ \t]*[\047"]?[A-Za-z_][A-Za-z0-9_]*[\047"]?/)) {
    hd = substr(t, RSTART, RLENGTH)
    sub(/^<<-?[ \t]*[\047"]?/, "", hd); sub(/[\047"]$/, "", hd)
  }
  judge(t)
}
END { exit bad }
'

while IFS= read -r path; do
  rel="${path#"${dir}"/}"
  if ! out="$(awk -v rel="${rel}" "${judge}" "${path}")"; then
    fail "${out}"
  fi
  if ! emoji="$(perl -CSD -ne 'print "$ARGV:$.: contains an emoji\n" if /[\x{1F000}-\x{1FAFF}\x{2600}-\x{27BF}\x{2B50}\x{2B55}\x{FE0F}]/' "${path}")" || [[ -n "${emoji}" ]]; then
    fail "${emoji//${dir}\//}"
  fi
done < <(find "${dir}" -name '*.md' -type f | sort)

if [[ "${status}" -ne 0 ]]; then
  exit 1
fi
printf 'candidate OK (%s)\n' "${dir#"${repo_root}"/}"
