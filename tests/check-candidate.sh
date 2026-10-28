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
#   - an emoji, a carriage return, or a leading byte order mark in a markdown file
#
# The allow-list is the whole of what the prose may run. Every line is an oe call, or one of:
#   git fetch origin <branch>      a plain branch name or an upper-case <PLACEHOLDER>, never a refspec, so it updates a remote-tracking ref only
#   sleep <seconds>                waits between polls
#   mktemp                         makes a file for a report
#   name="/literal/path"           names that file in a later call, since every call is its own shell
#   cat >"$file" <<'TAG'           writes the report, and only that form of cat is allowed
#   gh issue view ...              reads an Issue
#   gh api repos/... ...           reads, and fails when a flag makes it write
# An oe line holds plain words, <placeholders>, a quoted "$variable", a quoted literal, a quoted output redirect, and may end
# in a heredoc with a quoted delimiter, whose body is data. The arguments of gh and mktemp hold plain words and
# <placeholders> only, since a variable can hold a write flag; a quoted literal is opaque to gh only after --jq. Quotes, $,
# backticks, parentheses, braces, ; | & # * ~ and a backslash fail elsewhere. Rather than parse shell, the guard allows few
# forms, and each fix of a bypass stays one more line of this grammar.
# Fences follow markdown at column 0: a run of three or more backticks or tildes, closed by a run of at least as many.
# Blocks of another language, and unlabeled ones, are text and are not judged. Rather than model more of markdown and
# shell, the guard fails on what it would have to model: an indented fence, a fence inside a quote or a list item, a
# carriage return anywhere in the file, an HTML block, and a backslash at the end of a line.
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
BEGIN {
  # A word is plain characters and <placeholders> only. Quotes, $, `, ( ) { } < > ; | & # * ~ and a backslash never appear in one.
  WORD = "^([A-Za-z0-9_./:=@+,-]|<[A-Za-z][A-Za-z_]*>)+"
  VAR = "^\"\\$[A-Za-z_][A-Za-z0-9_]*\""
  RED = "^>\"[^\"$`\\\\]*\""
  SQ = "^\047[^\047]*\047"
  HD = "^<<([\047][A-Za-z_][A-Za-z0-9_]*[\047]|\"[A-Za-z_][A-Za-z0-9_]*\")$"
}
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
function violation(msg) { printf "%s:%d: %s\n", rel, FNR, msg; bad = 1 }
function tagof(h) { sub(/^<</, "", h); gsub(/[\047"]/, "", h); return h }
# args_ok judges the arguments of a command token by token. kind is oe, gh, or plain.
function args_ok(rest, kind,   prev, tok, n) {
  prev = ""
  HDTAG = ""
  while (1) {
    sub(/^[ \t]+/, "", rest)
    if (rest == "") return 1
    if (kind == "oe" && rest ~ HD) { HDTAG = tagof(rest); return 1 }
    n = 0
    if (match(rest, WORD) && (RLENGTH == length(rest) || substr(rest, RLENGTH + 1, 1) ~ /[ \t]/)) {
      n = RLENGTH; tok = substr(rest, 1, n)
      if (kind == "gh" && (tok ~ /^-[A-Za-z]*[fFX]/ || tok ~ /^--(method|field|raw-field|input)/)) return 0
    } else if (kind != "gh" && match(rest, VAR) && (RLENGTH == length(rest) || substr(rest, RLENGTH + 1, 1) ~ /[ \t]/)) {
      n = RLENGTH; tok = substr(rest, 1, n)
    } else if (kind == "oe" && match(rest, RED) && (RLENGTH == length(rest) || substr(rest, RLENGTH + 1, 1) ~ /[ \t]/)) {
      n = RLENGTH; tok = substr(rest, 1, n)
    } else if ((kind == "oe" || prev == "--jq") && match(rest, SQ) && (RLENGTH == length(rest) || substr(rest, RLENGTH + 1, 1) ~ /[ \t]/)) {
      n = RLENGTH; tok = substr(rest, 1, n)
    }
    if (n == 0) return 0
    prev = tok; rest = substr(rest, n + 1)
  }
}
function refuse(t) { violation("is not an oe call or an allowed read: " substr(t, 1, 60)); return 0 }
# judge returns 1 when the line is allowed. Anything it does not name fails.
function judge(t,   rest) {
  HDTAG = ""
  if (t ~ /^[A-Za-z_][A-Za-z0-9_]*="[^"$`\\]*"$/) return 1
  if (match(t, /^[A-Za-z_][A-Za-z0-9_]*="\$\(mktemp/) && substr(t, length(t) - 1) == ")\"") {
    rest = substr(t, RLENGTH + 1, length(t) - RLENGTH - 2)
    if (rest ~ /^([ \t]|$)/ && args_ok(rest, "plain")) return 1
    return refuse(t)
  }
  if (t ~ /^git fetch origin ([A-Za-z0-9][A-Za-z0-9._\/-]*|<[A-Z][A-Z_]*>)$/) return 1
  if (t ~ /^sleep [0-9]+$/) return 1
  if (t ~ /^cat >"\$[A-Za-z_][A-Za-z0-9_]*" <<([\047][A-Za-z_][A-Za-z0-9_]*[\047]|"[A-Za-z_][A-Za-z0-9_]*")$/) { match(t, /<<.*$/); HDTAG = tagof(substr(t, RSTART)); return 1 }
  if (t ~ /^oe([ \t]|$)/) { rest = substr(t, 3); return args_ok(rest, "oe") ? 1 : refuse(t) }
  if (t ~ /^mktemp([ \t]|$)/) { rest = substr(t, 7); return args_ok(rest, "plain") ? 1 : refuse(t) }
  if (t ~ /^gh issue view([ \t]|$)/) { rest = substr(t, 15); return args_ok(rest, "gh") ? 1 : refuse(t) }
  if (t ~ /^gh api repos\//) { rest = substr(t, 8); return args_ok(rest, "gh") ? 1 : refuse(t) }
  return refuse(t)
}
# fence parses a line as a markdown code fence at column 0: a run of three or more backticks or tildes, and for backticks an
# info string without a backtick. It sets FCH, FLEN, and FINFO.
function fence(line,   s, c, n) {
  s = line
  c = substr(s, 1, 1)
  if (c != "`" && c != "~") return 0
  n = 0
  while (substr(s, n + 1, 1) == c) n++
  if (n < 3) return 0
  FCH = c; FLEN = n; FINFO = substr(s, n + 1)
  if (c == "`" && index(FINFO, "`") > 0) return 0
  return 1
}
FNR == 1 { infence = 0; judged = 0; hd = "" }
{
  line = $0
  # The guard follows fences at column 0 only. An indented one could open or close a block it would not see.
  if (line ~ /^[ \t]+(```|~~~)/) { violation("an indented fence; the guard follows only fences at column 0"); next }
  if (!infence) {
    # An HTML block keeps a fence marker inside it as text. Running text such as <TOKEN> or a<b does not start one.
    if (line ~ /^[ \t]*<(\/?[A-Za-z][A-Za-z0-9-]*([ \t>\/]|$)|!|\?)/ && line !~ /^[ \t]*<[A-Z][A-Z_]*>/) {
      violation("an HTML block; markdown keeps what follows as text, so the guard cannot follow the fences after it")
      next
    }
    if (line ~ /^[ \t]*((>|[-*+]|[0-9]+[.)])[ \t]*)+(```|~~~)/) {
      violation("a fence inside a quote or a list item; the guard does not follow containers, so write the block at the top level")
      next
    }
    if (fence(line)) {
      lang = trim(FINFO); sub(/[ \t].*$/, "", lang)
      infence = 1; fch = FCH; flen = FLEN; judged = (lang ~ /^(bash|sh|shell|zsh)$/); hd = ""
    }
    next
  }
  if (fence(line) && FCH == fch && FLEN >= flen && trim(FINFO) == "") { infence = 0; judged = 0; next }
  if (!judged) next
  if (hd != "") { if (trim(line) == hd) hd = ""; next }
  t = trim(line)
  if (t == "" || t ~ /^#/) next
  if (t ~ /\\$/) { violation("a line continuation; write one command per line"); next }
  if (judge(t) && HDTAG != "") hd = HDTAG
}
END { exit bad }
'

while IFS= read -r path; do
  rel="${path#"${dir}"/}"
  if [[ "$(head -c 3 "${path}" | od -An -tx1 | tr -d ' \n')" == efbbbf ]]; then
    fail "${rel}:1: starts with a byte order mark, which markdown ignores; remove it"
    continue
  fi
  if grep -q "$(printf '\r')" "${path}"; then
    fail "${rel}:1: contains a carriage return; use LF line endings, since markdown also reads a bare CR as a line end"
    continue
  fi
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
