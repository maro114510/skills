#!/usr/bin/env bash
# Grades one create-pr evaluation run from what it left behind, never from the executor's report.
# Usage: grade.sh <A|B|C> <dir>
# Reads the stub's records in <dir>/state and the clone in <dir>/repo.
# Prints "<n> PASS|FAIL|MANUAL <evidence>" for each item of scenarios/<scenario>.md.
# MANUAL means the records cannot settle the item, so read the executor's report or the body lines the evidence names.
# Exit: 0 no FAIL, 1 at least one FAIL, 2 bad usage or <dir> is not a sandbox.
set -uo pipefail

usage() {
  sed -n '3p' "$0" | sed 's/^# //' >&2
  exit 2
}

[[ $# -eq 2 && "$1" =~ ^[ABC]$ ]] || usage
scenario="$1"
dir="$2"
[[ -f "${dir}/.create-pr-eval" ]] || {
  echo "Not a sandbox: ${dir}" >&2
  exit 2
}
pr="${dir}/state/pr"
failed=0

result() {
  echo "$1 $2 $3"
  [[ "$2" == FAIL ]] && failed=1
  return 0
}

# body <subcommand> [args] analyzes the PR body, because Markdown structure and Unicode need more than grep.
body() {
  python3 - "$@" "${pr}/body" <<'PY'
import re, sys
cmd, args, path = sys.argv[1], sys.argv[2:-1], sys.argv[-1]
lines = open(path, encoding="utf-8").read().split("\n")
fence, out = False, []
for i, l in enumerate(lines, 1):
    if re.match(r"\s*(```|~~~)", l):
        fence = not fence
        continue
    if not fence:
        out.append((i, l))

def sections():
    cur, res = None, {}
    for _, l in out:
        m = re.match(r"##\s+(.+?)\s*$", l)
        if m:
            cur = m.group(1)
            res[cur] = []
        elif cur is not None:
            res[cur].append(l)
    return res

def content(ls):
    text = re.sub(r"<!--.*?-->", "", "\n".join(ls), flags=re.S)
    stripped = (l.strip() for l in text.split("\n"))
    return [l for l in stripped if l and l not in ("-", "- [ ]")]

if cmd == "refs":
    # GitHub closes from a keyword anywhere in the text, but not inside code; Related counts only on its own line.
    closing = re.compile(r"(?<![\w-])(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?):?\s+#(\d+)\b", re.I)
    related = re.compile(r"^\s*related:?\s+#(\d+)\s*$", re.I)
    found = set()
    for _, l in out:
        l = re.sub(r"`[^`]*`", "", l)
        found.update(("Closes", int(n)) for n in closing.findall(l))
        m = related.match(l)
        if m:
            found.add(("Related", int(m.group(1))))
    for kind, n in sorted(found):
        print(kind + " #" + str(n))
elif cmd == "ownline":
    # The closing references on a line of their own, the only ones create-linked-pr.sh links.
    for _, l in out:
        m = re.match(r"^\s*(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?):?\s+#(\d+)\s*$", l, re.I)
        if m:
            print("Closes #" + m.group(1))
elif cmd == "headings":
    for _, l in out:
        m = re.match(r"##\s+(.+?)\s*$", l)
        if m:
            print(m.group(1))
elif cmd == "unfilled":
    # args are the template file, then its section headings. A section is filled only by a line the template lacks.
    template = open(args[0], encoding="utf-8").read().split("\n")
    s = sections()
    for h in args[1:]:
        if h not in s or not set(content(s[h])) - set(content(template)):
            print(h)
elif cmd == "checked":
    for l in sections().get(args[0], []):
        if re.match(r"\s*[-*]\s+\[[xX]\]", l):
            print(l.strip())
elif cmd == "wraps":
    block = re.compile(r"\s*([-*+>|#]|\d+[.)]\s|<!--|$)")
    for (i, a), (j, b) in zip(out, out[1:]):
        if j == i + 1 and a.strip() and b.strip() and not block.match(b):
            print(j)
PY
}

has_japanese() {
  python3 -c 'import re, sys; sys.exit(0 if re.search(r"[\u3040-\u30ff\u3400-\u9fff\uff66-\uff9f]", sys.stdin.read()) else 1)'
}

arg_values() { sed -n "/^$1\$/{n;p;}" "${pr}/args"; }

created=0
[[ -f "${pr}/title" ]] && created=1
creates="$(cat "${pr}/creates" 2>/dev/null || echo 0)"
title="$(cat "${pr}/title" 2>/dev/null)"
links="$(sort -un "${pr}/links" 2>/dev/null | tr '\n' ' ' | sed 's/ $//')"

# Item 1 needs one gh pr create whose caller is create-linked-pr.sh itself, not a shell whose -c text names it.
caller="$(cat "${pr}/caller" 2>/dev/null)"
script_caller='^(([^ ]*/)?(ba)?sh [^-].*/|([^ ]*/)?(ba)?sh |[^ ]*/)?create-linked-pr\.sh( |$)'
if [[ "${creates}" == 1 && "${caller}" =~ ${script_caller} ]]; then
  result 1 PASS "one gh pr create, from create-linked-pr.sh"
else
  result 1 FAIL "gh pr create ran ${creates} times; last caller: ${caller:-none}"
fi

# Item 2 needs origin's branch to equal HEAD at creation, and the branch not to have moved since.
if [[ "${created}" == 1 ]]; then
  branch="$(cat "${pr}/branch")"
  head="$(cat "${pr}/head")"
  remote="$(cat "${pr}/remote")"
  tip="$(git -C "${dir}/repo" rev-parse -q --verify "refs/heads/${branch}" 2>/dev/null)"
  if [[ -n "${remote}" && "${remote}" == "${head}" && "${head}" == "${tip}" ]]; then
    result 2 PASS "created at ${head:0:7}, the tip of ${branch}"
  else
    result 2 FAIL "origin ${remote:-missing}, HEAD at creation ${head}, ${branch} now ${tip:-missing}"
  fi
else
  result 2 FAIL "no PR was created"
fi

if [[ "${created}" == 0 ]]; then
  last=7
  [[ "${scenario}" != B ]] && last=8
  for ((n = 3; n <= last; n++)); do
    if [[ "${scenario}" == C && "${n}" == 7 ]]; then
      result 7 MANUAL "read the report for the NOTICE relay"
    else
      result "${n}" FAIL "no PR was created"
    fi
  done
  exit "${failed}"
fi

refs="$(body refs | tr '\n' ' ' | sed 's/ $//')"
ownline="$(body ownline)"
base="$(arg_values --base | tail -n 1)"
labels="$(arg_values --label)"

# Draft, @me, at most two labels, each existing and none a status label.
metadata() {
  local n="$1" problems="" l
  grep -qx -- --draft "${pr}/args" || problems+="not draft; "
  [[ "$(arg_values --assignee)" == "@me" ]] || problems+="assignee is not only @me; "
  [[ "$(grep -c . <<<"${labels}")" -le 2 ]] || problems+="more than two labels; "
  while IFS= read -r l; do
    [[ -n "${l}" ]] || continue
    jq -e --arg l "${l}" 'any(.[]; .name == $l)' "${dir}/state/labels.json" >/dev/null || problems+="label ${l} does not exist; "
    [[ "${l}" =~ ^([Ww][Ii][Pp]|[Dd][Rr][Aa][Ff][Tt])$ ]] && problems+="status label ${l}; "
  done <<<"${labels}"
  if [[ -z "${problems}" ]]; then
    result "${n}" PASS "draft, @me, labels: $(tr '\n' ' ' <<<"${labels}" | sed 's/ $//')"
  else
    result "${n}" FAIL "${problems%; }"
  fi
}

# Conventional Commits under 70 characters, and with $2=ja a Japanese subject.
title_check() {
  local n="$1" problems="" length
  [[ "${title}" =~ ^(feat|fix|refactor|docs|chore|deps|perf|test|ci|build|style|revert)(\([^\)]+\))?!?:\ [^\ ] ]] ||
    problems+="not Conventional Commits; "
  length="$(python3 -c 'import sys; print(len(sys.argv[1]))' "${title}")"
  [[ "${length}" -lt 70 ]] || problems+="${length} characters; "
  if [[ "${2:-}" == ja ]] && ! has_japanese <<<"${title#*: }"; then
    problems+="subject is not Japanese; "
  fi
  if [[ -z "${problems}" ]]; then
    result "${n}" PASS "${title} (${length} characters)"
  else
    result "${n}" FAIL "${problems%; }: ${title}"
  fi
}

english() {
  local n="$1" extra="${2:-}"
  if { echo "${title}" && cat "${pr}/body"; } | has_japanese; then
    result "${n}" FAIL "title or body holds Japanese text"
  elif [[ -n "${extra}" ]]; then
    result "${n}" FAIL "${extra}"
  else
    result "${n}" PASS "${3:-title and body are English}"
  fi
}

wraps() {
  local suspects
  suspects="$(body wraps | tr '\n' ' ' | sed 's/ $//')"
  if [[ -z "${suspects}" ]]; then
    result "$1" PASS "no prose line continues on the next line"
  else
    result "$1" MANUAL "check body lines ${suspects} for a manual wrap"
  fi
}

case "${scenario}" in
A)
  if [[ "${refs}" == "Closes #12" && "${links}" == 12 ]] && grep -qx 'Closes #12' <<<"${ownline}"; then
    result 3 PASS "references: ${refs}; linked: ${links}"
  else
    result 3 FAIL "references: ${refs:-none}; on their own line: $(tr '\n' ' ' <<<"${ownline:-none}"); linked: ${links:-none}"
  fi
  template="$(mktemp "${TMPDIR:-/tmp}/grade-template.XXXXXX")"
  trap 'rm -f "${template}"' EXIT
  git -C "${dir}/repo" show HEAD:.github/PULL_REQUEST_TEMPLATE.md >"${template}"
  sections=()
  while IFS= read -r h; do sections+=("${h}"); done < <(sed -n 's/^##[[:space:]]*//p' "${template}")
  unfilled="$(body unfilled "${template}" "${sections[@]}" | tr '\n' ',' | sed 's/,$//')"
  if [[ -z "${unfilled}" ]]; then
    result 4 PASS "every template section is present and filled: ${sections[*]}"
  else
    result 4 FAIL "missing or empty template sections: ${unfilled}"
  fi
  title_check 5 ja
  metadata 6
  checked="$(body checked 動作確認)"
  if [[ -z "${checked}" ]]; then
    result 7 PASS "nothing under 動作確認 is checked"
  else
    result 7 FAIL "checked: $(tr '\n' ' ' <<<"${checked}")"
  fi
  wraps 8
  ;;
B)
  if [[ "${refs}" == "Closes #40" && "${links}" == 40 ]] && ! grep -q '#99' "${pr}/body"; then
    result 3 PASS "references: ${refs}; linked: ${links}; no #99"
  else
    result 3 FAIL "references: ${refs:-none}; linked: ${links:-none}; #99 in body: $(grep -c '#99' "${pr}/body")"
  fi
  english 4
  title_check 5
  metadata 6
  wraps 7
  ;;
C)
  if [[ "${base}" == feat/export-api && "${refs}" == "Closes #8" && -z "${links}" ]] && grep -qx 'Closes #8' <<<"${ownline}"; then
    result 3 PASS "base ${base}; references: ${refs}; nothing linked"
  else
    result 3 FAIL "base ${base:-default}; references: ${refs:-none}; on their own line: $(tr '\n' ' ' <<<"${ownline:-none}"); linked: ${links:-none}"
  fi
  order="$(body headings | python3 -c '
import sys
allowed = ["Background", "Summary", "Implementation Details", "Changes", "Impact", "Concerns", "Future Considerations", "Test Plan"]
hs = [l.rstrip("\n") for l in sys.stdin if l.strip()]
bad = [h for h in hs if h not in allowed]
idx = [allowed.index(h) for h in hs if h in allowed]
if bad: print("not default sections: " + ", ".join(bad))
elif idx != sorted(idx): print("default sections out of order: " + ", ".join(hs))
elif not hs: print("no sections")
')"
  english 4 "${order}" "English, default sections: $(body headings | tr '\n' ',' | sed 's/,$//')"
  title_check 5
  metadata 6
  result 7 MANUAL "read the report: the NOTICE that #8 stays unlinked on base feat/export-api, with the --link step after a retarget"
  wraps 8
  ;;
esac

exit "${failed}"
