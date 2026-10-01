#!/usr/bin/env bash
# Creates a PR and links each closing line to its issue through the API.
# Usage: create-linked-pr.sh --title T --body-file F|- [--base B] [--head H] [--repo R] [--draft] [--assignee A] [--label L]...
# Usage: create-linked-pr.sh --link PR [--repo R]
# Exit: 0 ok, 1 gh failed, 2 bad usage or unknown issue, 3 link missing.
set -uo pipefail

attempts="${LINK_POLL_ATTEMPTS:-10}"
interval="${LINK_POLL_INTERVAL:-3}"

usage() {
  sed -n '3,4p' "$0" | sed 's/^# //' >&2
  exit 2
}

title="" body_file="" base="" head="" repo="" draft=0 link_pr=""
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
  --link) link_pr="${2:-}" && shift ;;
  *) usage ;;
  esac
  shift
done

repo_args=()
[[ -n "${repo}" ]] && repo_args=(--repo "${repo}")

tmp="$(mktemp "${TMPDIR:-/tmp}/create-linked-pr.XXXXXX")"
err="${tmp}.err"
trap 'rm -f "${tmp}" "${err}"' EXIT

# Lists issue numbers of closing lines outside code fences, or with $2=rewrite turns them into Related.
closing() {
  awk -v mode="${2:-list}" '
    /^[[:space:]]*(```|~~~)/ { fence = !fence; if (mode == "rewrite") print; next }
    {
      l = tolower($0)
      if (!fence && l ~ /^[[:space:]]*(close[sd]?|fix(e[sd])?|resolve[sd]?):?[[:space:]]+#[0-9]+[[:space:]]*$/) {
        sub(/^[^#]*#/, "", l); sub(/[[:space:]]*$/, "", l)
        if (mode == "rewrite") print "Related #" l; else print l
        next
      }
      if (mode == "rewrite") print
    }
  ' "$1" | if [[ "${2:-list}" == "rewrite" ]]; then cat; else sort -un; fi
}

refs() {
  gh pr view "$1" ${repo_args[@]+"${repo_args[@]}"} --json closingIssuesReferences \
    --jq '.closingIssuesReferences[].number'
}

resolve_issues() {
  issue_ids=()
  local n id missing=0
  for n in ${issues}; do
    if id="$(gh issue view "${n}" ${repo_args[@]+"${repo_args[@]}"} --json id --jq .id 2>"${err}")" && [[ -n "${id}" ]]; then
      issue_ids+=("${id}")
    else
      echo "ISSUE_NOT_FOUND #${n}: $(tr '\n' ' ' <"${err}" | sed 's/[[:space:]]*$//')"
      missing=1
    fi
  done
  [[ "${missing}" == 0 ]] || exit 2
}

# Links each issue missing from PR $1, then polls until all appear.
link_and_verify() {
  local pr="$1" pr_id current n i=0 attempt status=0
  pr_id="$(gh pr view "${pr}" ${repo_args[@]+"${repo_args[@]}"} --json id,url --jq '[.id, .url] | @tsv' | cut -f1)"
  if [[ -z "${pr_id}" ]]; then
    # The PR may exist, so this is exit 3 and not 1.
    for n in ${issues}; do echo "LINK_MISSING #${n}"; done
    return 3
  fi
  current="$(refs "${pr}")" || current=""
  for n in ${issues}; do
    if ! grep -qx -- "${n}" <<<"${current}"; then
      # Not fatal, the poll decides.
      # shellcheck disable=SC2016 # GraphQL variables.
      gh api graphql \
        -f query='mutation($i: ID!, $p: ID!) { addCloseIssueReferences(input: {issueId: $i, pullRequestIds: [$p]}) { issue { number } } }' \
        -f i="${issue_ids[${i}]}" -f p="${pr_id}" >/dev/null ||
        echo "WARN: addCloseIssueReferences failed for #${n}" >&2
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
fi
default="$(gh repo view ${repo:+"${repo}"} --json defaultBranchRef --jq .defaultBranchRef.name)" || exit 1

if [[ -n "${link_pr}" ]]; then
  gh pr view "${link_pr}" ${repo_args[@]+"${repo_args[@]}"} --json body --jq .body >"${tmp}" || exit 1
  issues="$(closing "${tmp}")"
  [[ -z "${issues}" ]] && exit 0
  base="$(gh pr view "${link_pr}" ${repo_args[@]+"${repo_args[@]}"} --json baseRefName --jq .baseRefName)" || exit 1
  if [[ "${base}" != "${default}" ]]; then
    echo "NOTICE: base ${base} is not the default branch ${default}; nothing linked"
    exit 0
  fi
  resolve_issues
  link_and_verify "${link_pr}"
  exit $?
fi

# Same precedence as gh pr create, then passed explicitly so gh cannot pick another base.
if [[ -z "${base}" ]]; then
  branch="${head##*:}"
  [[ -n "${branch}" ]] || branch="$(git branch --show-current 2>/dev/null)"
  [[ -n "${branch}" ]] && base="$(git config --get "branch.${branch}.gh-merge-base" 2>/dev/null)"
  [[ -n "${base}" ]] || base="${default}"
fi

issues="$(closing "${tmp}")"
if [[ -n "${issues}" && "${base}" != "${default}" ]]; then
  rewritten="$(closing "${tmp}" rewrite)"
  printf '%s\n' "${rewritten}" >"${tmp}"
  for n in ${issues}; do
    echo "NOTICE: base ${base} is not the default branch ${default}; rewrote #${n} to Related #${n}"
  done
  issues=""
fi
resolve_issues

create_args=(--title "${title}" --body-file "${tmp}" --base "${base}")
[[ -n "${head}" ]] && create_args+=(--head "${head}")
[[ "${draft}" == 1 ]] && create_args+=(--draft)
for a in ${assignees[@]+"${assignees[@]}"}; do create_args+=(--assignee "${a}"); done
for l in ${labels[@]+"${labels[@]}"}; do create_args+=(--label "${l}"); done

# stdout only, so a warning is never read as the URL.
if ! out="$(gh pr create ${repo_args[@]+"${repo_args[@]}"} "${create_args[@]}" 2>"${err}")"; then
  cat "${err}"
  [[ -n "${out}" ]] && echo "${out}"
  exit 1
fi
cat "${err}" >&2
url="$(tail -n 1 <<<"${out}")"
echo "${url}"
[[ -z "${issues}" ]] && exit 0
link_and_verify "${url}"
