#!/usr/bin/env bash
# Stub gh that setup.sh installs as <dir>/bin/gh. Answers the calls create-pr makes from files in <dir>/state and
# records every call, so grading reads what a run did instead of what the executor reports. Never talks to GitHub.
# Every URL it prints is on github.invalid, so replaying one with the real gh cannot reach GitHub either.
# Reads: state/issues ("<n>:<title>:<open sub-issues>" lines), state/labels.json.
# Writes: state/gh.log (one line per call); per gh pr create, state/pr/{args,title,body,head,remote,branch,caller};
# state/pr/creates (count); state/pr/links (issue numbers linked through the API); state/pr/edited_body.
set -uo pipefail

state="$(cd "$(dirname "$0")/.." && pwd)/state"
repo_url="https://github.invalid/acme/demo"
pr_url="${repo_url}/pull/101"
printf '%s\n' "$*" >>"${state}/gh.log"

jq_expr=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  [[ "${args[i]}" == "--jq" || "${args[i]}" == "-q" ]] && jq_expr="${args[i + 1]:-}"
done

out() {
  if [[ -n "${jq_expr}" ]]; then jq -r "${jq_expr}"; else cat; fi
}

issue_json() {
  local line title open
  line="$(grep -m 1 "^$1:" "${state}/issues")" || return 1
  title="${line#*:}"
  title="${title%:*}"
  open="${line##*:}"
  jq -n --arg n "$1" --arg t "${title}" --argjson o "${open}" \
    '{id: ("I_" + $n), number: ($n | tonumber), title: $t, state: "OPEN", body: "", subIssuesSummary: {total: $o, completed: 0}}'
}

# value_of <flag> prints the argument after the last <flag>.
value_of() {
  local v="" j
  for ((j = 0; j < ${#args[@]}; j++)); do [[ "${args[j]}" == "$1" ]] && v="${args[j + 1]:-}"; done
  printf '%s' "${v}"
}

pr_create() {
  local pr="${state}/pr" branch head remote creates
  mkdir -p "${pr}"
  creates="$(cat "${pr}/creates" 2>/dev/null || echo 0)"
  echo $((creates + 1)) >"${pr}/creates"
  branch="$(value_of --head)"
  branch="${branch##*:}"
  [[ -n "${branch}" ]] || branch="$(git branch --show-current 2>/dev/null)"
  head="$(git rev-parse HEAD 2>/dev/null)"
  remote="$(git ls-remote origin "refs/heads/${branch}" 2>/dev/null | cut -f1)"
  printf '%s\n' "${args[@]}" >"${pr}/args"
  value_of --title >"${pr}/title"
  if [[ "$(value_of --body-file)" == "-" ]]; then
    cat >"${pr}/body"
  else
    cp "$(value_of --body-file)" "${pr}/body" 2>/dev/null || : >"${pr}/body"
  fi
  printf '%s\n' "${branch}" >"${pr}/branch"
  printf '%s\n' "${head}" >"${pr}/head"
  printf '%s\n' "${remote}" >"${pr}/remote"
  # The parent's command line tells a create-linked-pr.sh call from a gh pr create the executor typed.
  ps -o args= -p "${PPID}" >"${pr}/caller" 2>/dev/null || : >"${pr}/caller"
  if [[ -z "${remote}" ]]; then
    echo "aborted: you must first push the current branch to a remote, or use the --head flag" >&2
    exit 1
  fi
  echo "${pr_url}"
}

pr_view() {
  local pr="${state}/pr"
  if [[ " ${args[*]} " == *" --web "* ]]; then
    echo "Opening ${pr_url} in your browser."
    return 0
  fi
  if [[ ! -f "${pr}/title" ]]; then
    echo "no pull requests found for branch \"$(git branch --show-current 2>/dev/null)\"" >&2
    exit 1
  fi
  local base body
  base="$(sed -n '/^--base$/{n;p;}' "${pr}/args" | tail -n 1)"
  body="${pr}/body"
  [[ -f "${pr}/edited_body" ]] && body="${pr}/edited_body"
  jq -n --rawfile b "${body}" --rawfile t "${pr}/title" --rawfile r <(cat "${pr}/links" 2>/dev/null) \
    --arg base "${base:-main}" --arg url "${pr_url}" --argjson draft "$(grep -qx -- --draft "${pr}/args" && echo true || echo false)" \
    '{id: "PR_101", number: 101, url: $url, isDraft: $draft, state: "OPEN", title: $t, body: $b, baseRefName: $base,
      closingIssuesReferences: [$r | split("\n")[] | select(length > 0) | {number: tonumber}]}' | out
}

case "${1:-} ${2:-}" in
"repo view")
  jq -n --arg url "${repo_url}" '{defaultBranchRef: {name: "main"}, nameWithOwner: "acme/demo", url: $url}' | out
  ;;
"label list") out <"${state}/labels.json" ;;
"issue view")
  if ! issue_json "${3:-}" >/dev/null; then
    echo "GraphQL: Could not resolve to an issue with the number of ${3:-}." >&2
    exit 1
  fi
  issue_json "$3" | out
  ;;
"issue list" | "pr list") echo '[]' | out ;;
"pr create") pr_create ;;
"pr view") pr_view ;;
"pr edit")
  mkdir -p "${state}/pr"
  cp "$(value_of --body-file)" "${state}/pr/edited_body" 2>/dev/null || true
  echo "${pr_url}"
  ;;
"api graphql")
  for a in "$@"; do
    [[ "${a}" == i=I_* ]] && echo "${a#i=I_}" >>"${state}/pr/links"
  done
  echo '{"data":{"addCloseIssueReferences":{"issue":{"number":1}}}}'
  ;;
*)
  echo "stub gh: unsupported: $*" >&2
  exit 1
  ;;
esac
