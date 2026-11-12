#!/usr/bin/env bash
# Screens pending changes for secrets before a commit, reading the same pattern list as babysit's gate.
# Usage: scan-secrets.sh
# Run from inside the repository. Covers staged, unstaged, and untracked changes, so a secret never ends up in
# a commit however it got into the working tree. Every reported path is relative to the repository root.
#
# Prints one `excluded: <path>: <why>` line per match, with a line number when the match is in content and
# never the matched value. The matches are a best-effort heuristic; the caller decides what to do.
#
# The pattern definitions necessarily look like what they detect, so that one file is never screened itself.
#
# | Exit | Meaning                   |
# |------|---------------------------|
# | 0    | No match                  |
# | 10   | At least one match        |
# | 2    | Usage or repository error |
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The list lives in skills/shared so every scanner reads one copy; this skill links it beside itself,
# because APM deploys only skill directories.
# shellcheck source-path=SCRIPTDIR disable=SC1091 # CI cannot follow the link's target.
source "${script_dir}/secret-patterns.sh"

die() {
  printf 'scan-secrets: %s\n' "$1" >&2
  exit 2
}

# Report from the repository root, so a run from a subdirectory screens the whole tree.
top="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a repository"
cd "${top}" || die "could not enter ${top}"

patterns_file="${script_dir}/secret-patterns.sh"

# Succeeds when path $1 is the pattern list the scan reads, reached directly or through this skill's link.
is_patterns_file() {
  [[ -e "$1" && "$1" -ef "${patterns_file}" ]]
}

work="$(mktemp -d)" || die "could not create a work directory"
trap 'rm -rf "${work}"' EXIT

lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

: >"${work}/hits"
excluded() {
  printf 'excluded: %s\n' "$1" >>"${work}/hits"
}

# Path patterns, matched in lower case. A placeholder such as .env.example is not excluded by its name.
exclude_by_name() {
  local path="$1" lower_path
  lower_path="$(lower "${path}")"
  if [[ "${lower_path}" =~ ${RE_SECRETFILE} && ! "${lower_path}" =~ ${RE_SECRETFILE_OK} ]]; then
    excluded "${path}: secret file"
  fi
}

# Classifies one line of content, and notes it under $1:$2 when a pattern matches. The value itself never
# leaves this function.
check_line() {
  local path="$1" lineno="$2" text="$3" kind=""
  if [[ "${text}" =~ ${RE_KEYHDR} ]]; then
    kind="private key"
  elif [[ "${text}" =~ ${RE_TOKEN} ]]; then
    kind="token"
  else
    # RE_ASSIGN and RE_ASSIGN_BARE are matched without case so that `Password:` counts.
    shopt -s nocasematch
    if [[ "${text}" =~ ${RE_ASSIGN} ]]; then
      kind="assignment"
    elif [[ "${text}" =~ ${RE_ASSIGN_BARE} ]]; then
      kind="assignment"
    fi
    shopt -u nocasematch
  fi
  [[ -z "${kind}" ]] || excluded "${path}:${lineno}: ${kind}"
}

# Every path the working tree changed, and the untracked ones, whose whole content is new.
: >"${work}/paths"
: >"${work}/untracked"
git status --porcelain=v1 -z --untracked-files=all >"${work}/status" </dev/null ||
  die "could not read the working tree"
skip_next=0
while IFS= read -r -d '' entry; do
  if ((skip_next)); then
    # A rename or copy carries its source path as the next entry, with no status prefix.
    skip_next=0
    continue
  fi
  [[ "${entry}" =~ ^([ MADRCU?!])([ MADRCU?!])\ (.*)$ ]] || continue
  status="${BASH_REMATCH[1]}${BASH_REMATCH[2]}"
  path="${BASH_REMATCH[3]}"
  printf '%s\0' "${path}" >>"${work}/paths"
  [[ "${status}" == '??' ]] && printf '%s\0' "${path}" >>"${work}/untracked"
  [[ "${status}" == R* || "${status}" == C* ]] && skip_next=1
done <"${work}/status"

while IFS= read -r -d '' path; do
  [[ -n "${path}" ]] || continue
  exclude_by_name "${path}"
done <"${work}/paths"

# The added lines of the staged change and of the unstaged change; each is a line that a commit can carry.
if git rev-parse --verify -q HEAD >/dev/null; then
  base_ref="HEAD"
else
  base_ref="$(git hash-object -t tree /dev/null)" || die "could not name the empty tree"
fi
diff_flags=(--no-color --no-ext-diff --no-textconv --no-renames -U0)
git -c core.quotePath=false diff --cached "${diff_flags[@]}" "${base_ref}" -- >"${work}/staged" </dev/null ||
  die "could not read the staged change"
git -c core.quotePath=false diff "${diff_flags[@]}" -- >"${work}/unstaged" </dev/null ||
  die "could not read the unstaged change"

# Prints one path, one line number, and one line of content, each on its own line, for every added line of
# the diff in $1. A quoted path is unquoted, because one holding a quote or a backslash is C-quoted; an
# unquoted one drops the TAB git appends when the path holds a space.
extract_added() {
  awk '
    function unquote(s,    out, i, c, esc) {
      sub(/^"/, "", s)
      sub(/"$/, "", s)
      out = ""
      i = 1
      while (i <= length(s)) {
        c = substr(s, i, 1)
        if (c != "\\") {
          out = out c
          i++
          continue
        }
        esc = substr(s, i + 1, 1)
        if (esc == "\"") out = out "\""
        else if (esc == "\\") out = out "\\"
        else if (esc == "t") out = out "\t"
        else out = out "\\" esc
        i += 2
      }
      return out
    }
    /^diff --git / { path = ""; next }
    /^\+\+\+ / {
      new = substr($0, 5)
      sub(/\t$/, "", new)
      if (substr(new, 1, 1) == "\"") new = unquote(new)
      if (new == "/dev/null") path = ""
      else {
        sub(/^b\//, "", new)
        path = new
      }
      next
    }
    /^@@ / {
      split($0, parts, " ")
      start = parts[3]
      sub(/^\+/, "", start)
      split(start, span, ",")
      line = span[1]
      next
    }
    /^\+/ {
      if (path != "") {
        print path
        print line
        print substr($0, 2)
      }
      line++
      next
    }
  ' "$1" >>"$2" || die "could not read the added lines"
}

: >"${work}/added"
extract_added "${work}/staged" "${work}/added"
extract_added "${work}/unstaged" "${work}/added"
while IFS= read -r path; do
  IFS= read -r lineno || break
  IFS= read -r text || break
  is_patterns_file "${path}" && continue
  check_line "${path}" "${lineno}" "${text}"
done <"${work}/added"

# An untracked file holds only new lines, so its whole content is scanned. One grep pass first skips a clean
# file quickly and a binary one entirely.
# shellcheck disable=SC2094 # The pattern list and the hits file are never read here.
while IFS= read -r -d '' path; do
  [[ -f "${path}" ]] || continue
  is_patterns_file "${path}" && continue
  if ! grep -qIiE -e "${RE_KEYHDR}" -e "${RE_TOKEN}" -- "${path}" &&
    ! grep -qiiE -e "${RE_ASSIGN}" -e "${RE_ASSIGN_BARE}" -- "${path}"; then
    continue
  fi
  lineno=0
  while IFS= read -r text || [[ -n "${text}" ]]; do
    lineno=$((lineno + 1))
    check_line "${path}" "${lineno}" "${text}"
  done <"${path}"
done <"${work}/untracked"

if [[ -s "${work}/hits" ]]; then
  sort -u "${work}/hits"
  exit 10
fi
exit 0
