#!/usr/bin/env bash
# Creates a PR and links each closing line to its issue through the API.
# Usage: create-linked-pr.sh --title T --body-file F|- [--base B] [--head H] [--repo R] [--draft] [--web] [--assignee A] [--label L]...
# Usage: create-linked-pr.sh --link PR [--repo R]
# Before creating, origin's tip of the head branch must equal local HEAD.
# Exit: 0 ok, 1 gh or git failed, 2 bad usage or unknown issue, 3 link missing, 4 NOT_PUSHED: head not pushed or stale.
# Why not gh pr create alone: GitHub can lag hours before it links a closing keyword, so each closing line is linked through the API and polled until it appears.
# An issue with open sub-issues gets Related instead of Closes, naming how many remain, so a partial PR never closes its parent; --link applies that rewrite to an existing PR body.
# On a non-default base, Closes stays but nothing is linked, because GitHub honors the keyword only once the PR targets the default branch.
# Everything but linking goes through REST, because another job can drain the GraphQL limit while REST still has room; with GraphQL exhausted, linking is skipped with a NOTICE and the body keyword remains.
set -uo pipefail

attempts="${LINK_POLL_ATTEMPTS:-10}"
interval="${LINK_POLL_INTERVAL:-3}"

usage() {
  sed -n '3,4p' "$0" | sed 's/^# //' >&2
  exit 2
}

title="" body_file="" base="" head="" repo="" draft=0 web=0 link_pr=""
assignees=()
labels=()
while [[ $# -gt 0 ]]; do
  case "$1" in
  --title) title="${2:-}" && shift ;;
  --body-file) body_file="${2:-}" && shift ;;
  --base) base="${2:-}" && shift ;;
  --head) head="${2:-}" && shift ;;
  --repo) repo="${2:-}" && shift ;;
  --assignee) assignees+=("${2:-}") && shift ;;
  --label) labels+=("${2:-}") && shift ;;
  --draft) draft=1 ;;
  --web) web=1 ;;
  --link) link_pr="${2:-}" && shift ;;
  *) usage ;;
  esac
  shift
done

# --link takes the PR's URL as well as its number; the URL names the repository.
if [[ -z "${repo}" && "${link_pr}" =~ ^https?://[^/]+/([^/]+/[^/]+)/pull/[0-9]+ ]]; then
  repo="${BASH_REMATCH[1]}"
fi
repo_args=()
[[ -n "${repo}" ]] && repo_args=(--repo "${repo}")
api_repo="repos/{owner}/{repo}"
[[ -n "${repo}" ]] && api_repo="repos/${repo}"

tmp="$(mktemp "${TMPDIR:-/tmp}/create-linked-pr.XXXXXX")"
err="${tmp}.err"
trap 'rm -f "${tmp}" "${err}"' EXIT

# Lists issue numbers of closing lines outside code fences, or with $2=rewrite turns those for the "<n>:<open count>" pairs in $3 into Related.
closing() {
  awk -v mode="${2:-list}" -v pairs="${3:-}" '
    BEGIN { n = split(pairs, p, " "); for (i = 1; i <= n; i++) { split(p[i], kv, ":"); open[kv[1] + 0] = kv[2] } }
    /^[[:space:]]*(```|~~~)/ { fence = !fence; if (mode == "rewrite") print; next }
    {
      l = tolower($0)
      if (!fence && l ~ /^[[:space:]]*(close[sd]?|fix(e[sd])?|resolve[sd]?):?[[:space:]]+#[0-9]+[[:space:]]*$/) {
        sub(/^[^#]*#/, "", l); l += 0
        if (mode != "rewrite") print l
        else if (l in open) print "Related #" l " (" open[l] " open sub-issues remain)"
        else print
        next
      }
      if (mode == "rewrite") print
    }
  ' "$1" | if [[ "${2:-list}" == "rewrite" ]]; then cat; else sort -un; fi
}

# Closing references exist only in GraphQL.
refs() {
  gh pr view "$1" ${repo_args[@]+"${repo_args[@]}"} --json closingIssuesReferences \
    --jq '.closingIssuesReferences[].number' 2>"${err}"
}

# Whether the last GraphQL call, its stderr in ${err}, failed on the rate limit.
graphql_exhausted() { grep -qi 'rate limit' "${err}"; }

# Reports each issue of $issues not in $1 as skipped.
skip_links() {
  local n
  for n in ${issues}; do
    grep -qx -- "${n}" <<<"$1" || echo "NOTICE: GraphQL rate limit exhausted; skipped linking #${n}"
  done
}

# Keeps in $issues only those without open sub-issues; the rest go to $parents as "<n>:<open count>".
resolve_issues() {
  issue_ids=()
  parents=""
  local n id open row kept="" missing=0
  for n in ${issues}; do
    # A server without sub-issues omits the summary, which counts as none open; any failure stops the guard.
    if row="$(gh api "${api_repo}/issues/${n}" \
      --jq '[.node_id, ((.sub_issues_summary.total // 0) - (.sub_issues_summary.completed // 0))] | @tsv' 2>"${err}")" &&
      [[ -n "${row}" ]]; then
      id="${row%%$'\t'*}"
      open=0
      [[ "${row}" == *$'\t'* ]] && open="${row#*$'\t'}"
      if [[ "${open}" =~ ^[1-9][0-9]*$ ]]; then
        parents+="${n}:${open} "
      else
        issue_ids+=("${id}")
        kept+="${n} "
      fi
    else
      echo "ISSUE_NOT_FOUND #${n}: $(tr '\n' ' ' <"${err}" | sed 's/[[:space:]]*$//')"
      missing=1
    fi
  done
  [[ "${missing}" == 0 ]] || exit 2
  issues="${kept}"
}

# Rewrites the closing lines of $parents in the body file to Related, so a partial PR never closes its parent.
rewrite_parents() {
  [[ -n "${parents}" ]] || return 1
  local rewritten p
  rewritten="$(closing "${tmp}" rewrite "${parents}")"
  printf '%s\n' "${rewritten}" >"${tmp}"
  for p in ${parents}; do echo "NOTICE: #${p%%:*} has ${p#*:} open sub-issues; rewrote to Related #${p%%:*}"; done
}

# Links each issue missing from PR $1, then polls until all appear.
link_and_verify() {
  local pr="$1" pr_id current n i=0 attempt status=0
  pr_id="$(gh api "${api_repo}/pulls/${pr##*/}" --jq .node_id)"
  if [[ -z "${pr_id}" ]]; then
    # The PR may exist, so this is exit 3 and not 1.
    for n in ${issues}; do echo "LINK_MISSING #${n}"; done
    return 3
  fi
  if ! current="$(refs "${pr}")"; then
    graphql_exhausted && skip_links "" && return 0
    current=""
  fi
  for n in ${issues}; do
    if ! grep -qx -- "${n}" <<<"${current}"; then
      # Not fatal, the poll decides.
      # shellcheck disable=SC2016 # GraphQL variables.
      gh api graphql \
        -f query='mutation($i: ID!, $p: ID!) { addCloseIssueReferences(input: {issueId: $i, pullRequestIds: [$p]}) { issue { number } } }' \
        -f i="${issue_ids[${i}]}" -f p="${pr_id}" >/dev/null 2>"${err}" || {
        graphql_exhausted && skip_links "${current}" && return 0
        cat "${err}" >&2
        echo "WARN: addCloseIssueReferences failed for #${n}" >&2
      }
    fi
    i=$((i + 1))
  done
  for ((attempt = 1; attempt <= attempts; attempt++)); do
    current="$(refs "${pr}")" || current=""
    status=0
    for n in ${issues}; do grep -qx -- "${n}" <<<"${current}" || status=3; done
    [[ "${status}" == 0 ]] && break
    [[ "${attempt}" -lt "${attempts}" ]] && sleep "${interval}"
  done
  for n in ${issues}; do
    if grep -qx -- "${n}" <<<"${current}"; then echo "LINKED #${n}"; else echo "LINK_MISSING #${n}"; fi
  done
  return "${status}"
}

if [[ -z "${link_pr}" ]]; then
  [[ -n "${title}" ]] || usage
  if [[ "${body_file}" == "-" ]]; then
    cat >"${tmp}"
  elif [[ -r "${body_file}" ]]; then
    cp "${body_file}" "${tmp}"
  else
    usage
  fi
  branch="${head##*:}"
  [[ -n "${branch}" ]] || branch="$(git branch --show-current 2>/dev/null)"
  # gh pr create would open the PR at whatever origin holds, even an older commit.
  if [[ -n "${branch}" ]]; then
    remote="$(git ls-remote origin "refs/heads/${branch}" 2>"${err}")" || {
      cat "${err}"
      exit 1
    }
    remote="${remote%%$'\t'*}"
  fi
  local_sha="$(git rev-parse HEAD 2>/dev/null)"
  if [[ -z "${branch}" || -z "${remote:-}" || "${remote}" != "${local_sha}" ]]; then
    echo "NOT_PUSHED ${branch:-<no branch>}: origin ${remote:-missing}, HEAD ${local_sha:-unknown}"
    exit 4
  fi
fi
repo_row="$(gh api "${api_repo}" --jq '[.default_branch, .owner.login] | @tsv')" || exit 1
default="${repo_row%%$'\t'*}"
owner="${repo_row#*$'\t'}"

if [[ -n "${link_pr}" ]]; then
  gh api "${api_repo}/pulls/${link_pr##*/}" --jq '.body // ""' >"${tmp}" || exit 1
  issues="$(closing "${tmp}")"
  [[ -z "${issues}" ]] && exit 0
  base="$(gh api "${api_repo}/pulls/${link_pr##*/}" --jq .base.ref)" || exit 1
  resolve_issues
  # The body keyword alone would still link the parent, so the PR body itself must change.
  if rewrite_parents; then
    gh api -X PATCH "${api_repo}/pulls/${link_pr##*/}" -F body=@"${tmp}" --silent || exit 1
  fi
  if [[ "${base}" != "${default}" ]]; then
    echo "NOTICE: base ${base} is not the default branch ${default}; nothing linked"
    exit 0
  fi
  [[ -z "${issues}" ]] && exit 0
  link_and_verify "${link_pr}"
  exit $?
fi

# Same precedence as gh pr create, then passed explicitly so gh cannot pick another base.
if [[ -z "${base}" ]]; then
  [[ -n "${branch}" ]] && base="$(git config --get "branch.${branch}.gh-merge-base" 2>/dev/null)"
  [[ -n "${base}" ]] || base="${default}"
fi

issues="$(closing "${tmp}")"
resolve_issues
rewrite_parents
# GitHub honors body keywords once the PR targets the default branch, for example after a retarget.
if [[ -n "${issues}" && "${base}" != "${default}" ]]; then
  for n in ${issues}; do
    echo "NOTICE: base ${base} is not the default branch ${default}; kept Closes #${n} unlinked"
  done
  issues=""
fi

# As gh pr create does, a branch pushed to a fork is named <fork owner>:<branch>.
head_ref="${head:-${branch}}"
if [[ "${head_ref}" != *:* ]]; then
  origin_url="$(git remote get-url origin 2>/dev/null)"
  origin_owner="${origin_url%.git}"
  origin_owner="${origin_owner%/*}"
  origin_owner="${origin_owner##*[/:]}"
  if [[ -n "${origin_owner}" && "$(tr '[:upper:]' '[:lower:]' <<<"${origin_owner}")" != "$(tr '[:upper:]' '[:lower:]' <<<"${owner}")" ]]; then
    head_ref="${origin_owner}:${head_ref}"
  fi
fi
create_args=(-f title="${title}" -F body=@"${tmp}" -f head="${head_ref}" -f base="${base}")
[[ "${draft}" == 1 ]] && create_args+=(-F draft=true)

if ! out="$(gh api -X POST "${api_repo}/pulls" "${create_args[@]}" --jq '[.number, .html_url] | @tsv' 2>"${err}")"; then
  cat "${err}"
  [[ -n "${out}" ]] && echo "${out}"
  exit 1
fi
number="${out%%$'\t'*}"
url="${out#*$'\t'}"
echo "${url}"

# The pulls endpoint takes neither, so they go on the PR's issue; the PR exists by now, so a failure is only a warning.
meta_args=()
for a in ${assignees[@]+"${assignees[@]}"}; do
  if [[ "${a}" == "@me" ]]; then
    a="$(gh api user --jq .login 2>"${err}")" || a=""
  fi
  [[ -n "${a}" ]] && meta_args+=(-f "assignees[]=${a}")
done
for l in ${labels[@]+"${labels[@]}"}; do meta_args+=(-f "labels[]=${l}"); done
if [[ ${#meta_args[@]} -gt 0 ]] && ! gh api -X PATCH "${api_repo}/issues/${number}" "${meta_args[@]}" --silent 2>"${err}"; then
  echo "WARN: could not set assignees or labels on ${url}: $(tr '\n' ' ' <"${err}" | sed 's/[[:space:]]*$//')" >&2
fi
status=0
[[ -n "${issues}" ]] && {
  link_and_verify "${url}"
  status=$?
}
# After linking, so the page shows the links; the PR already exists, so a browser failure is only a warning.
if [[ "${web}" == 1 ]] && ! gh pr view "${url}" --web >/dev/null 2>"${err}"; then
  echo "WARN: could not open ${url} in the browser: $(tr '\n' ' ' <"${err}" | sed 's/[[:space:]]*$//')" >&2
fi
exit "${status}"
