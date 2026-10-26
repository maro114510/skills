#!/usr/bin/env bash
# The pre-push gate. It decides, with no LLM judgment, whether a push may go out, and prints one
# verdict with its reason as a single JSON line. A verdict it cannot determine is `refuse`.
# Usage: gate.sh push <owner/repo> <pr> --session <token> --worktree <path> --start <sha> -- <push command>
# The push command must be exactly `git push origin <sha>:refs/heads/<branch>`, where <sha> is the HEAD
# the gate verified and <branch> is the pull request's head branch. The gate prints both, and pushing
# that sha instead of HEAD keeps a commit made after the check from going out unchecked.
# Output: {"verdict":"allow|park|refuse","reason":"...", ...}; an allow also carries head, branch, and start.
# Exit: 0 allow, 10 park, 11 refuse, 2 usage error, 3 the lock belongs to another session.
# Anything but 0 means "do not push". Exit 2 and 3 print no verdict.
set -uo pipefail
export LC_ALL=C GIT_TERMINAL_PROMPT=0 GIT_OPTIONAL_LOCKS=0

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR disable=SC1091 # CI runs shellcheck without -x, so it cannot follow this.
source "${script_dir}/common.sh"

PR_STATE="${BABYSIT_PR_STATE:-${script_dir}/pr-state.sh}"

printed=0

# Any exit without a verdict, such as a failed command nobody checked, is a refusal.
# shellcheck disable=SC2329 # Invoked by the EXIT trap below.
on_exit() {
  if ((printed == 0)); then
    printf '{"verdict":"refuse","reason":"the gate stopped before it reached a verdict"}\n'
    exit 11
  fi
}
trap on_exit EXIT

usage() {
  printed=1
  echo "$1" >&2
  echo "Usage: gate.sh push <owner/repo> <pr> --session <token> --worktree <path> --start <sha> -- git push origin <sha>:refs/heads/<branch>" >&2
  exit 2
}

lost() {
  printed=1
  echo "$1" >&2
  exit 3
}

# Prints the verdict $1 with reason $2 and the JSON object $3 merged in, then exits with its code.
emit() {
  local code extra="${3:-}"
  case "$1" in
  allow) code=0 ;;
  park) code=10 ;;
  *) code=11 ;;
  esac
  [[ -n "${extra}" ]] || extra='{}'
  jq -nc --arg v "$1" --arg r "$2" --argjson x "${extra}" '{verdict: $v, reason: $r} + $x'
  printed=1
  exit "${code}"
}

refuse() {
  emit refuse "$1"
}

command -v jq >/dev/null 2>&1 || usage "jq is required"
command -v git >/dev/null 2>&1 || usage "git is required"

mode="${1:-}"
[[ "${mode}" == push ]] || usage "Unknown mode: ${mode:-<none>}"
repo="${2:-}"
pr="${3:-}"
babysit_valid_repo "${repo}" || usage "Invalid repository: ${repo:-<none>}"
babysit_valid_pr "${pr}" || usage "Invalid pull request number: ${pr:-<none>}"
shift 3

session=""
worktree=""
start=""
cmd=()
while (($# > 0)); do
  case "$1" in
  --)
    shift
    cmd=("$@")
    break
    ;;
  --session | --worktree | --start)
    (($# >= 2)) || usage "$1 needs a value"
    case "$1" in
    --session) session="$2" ;;
    --worktree) worktree="$2" ;;
    --start) start="$2" ;;
    esac
    shift 2
    ;;
  *) usage "Unknown option: $1" ;;
  esac
done
ncmd=${#cmd[@]}

[[ "${session}" =~ ^[A-Za-z0-9-]+$ ]] || usage "--session needs a token"
[[ -n "${worktree}" && -d "${worktree}" ]] || usage "--worktree needs an existing directory"
[[ "${start}" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]] || usage "--start needs a full commit sha"
((ncmd > 0)) || usage "The push command must follow --"
cd "${worktree}" || usage "Cannot enter the worktree"
[[ "$(git rev-parse --is-inside-work-tree 2>/dev/null)" == true ]] || usage "Not a Git worktree: ${worktree}"

# The lock is how the gate knows this session still owns the pull request.
ledger_path="$(babysit_ledger_path "${repo}" "${pr}")" || usage "Not inside a Git repository"
ledger="$(babysit_ledger_read "${ledger_path}")" || refuse "the ledger cannot be read"
[[ "$(jq -r '.lock.token // ""' <<<"${ledger}")" == "${session}" ]] || lost "Lock is not held by this session"

snap="$("${PR_STATE}" "${repo}" "${pr}" 2>/dev/null)" || refuse "could not read the pull request from GitHub"
jq -e 'type == "object"' <<<"${snap}" >/dev/null 2>&1 || refuse "could not read the pull request from GitHub"
pf() {
  jq -r "$1" <<<"${snap}"
}
lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

# 0. The snapshot must describe the pull request that was asked about.
[[ "$(lower "$(pf '.repo // ""')")" == "$(lower "${repo}")" && "$(pf '.number // 0')" == "${pr}" ]] ||
  refuse "the snapshot describes another pull request"

# 1. The viewer is the author.
viewer="$(lower "$(pf '.viewer // ""')")"
author="$(lower "$(pf '.author // ""')")"
[[ -n "${viewer}" && "${viewer}" == "${author}" ]] || refuse "the viewer is not the pull request author"

# 2. The branch lives in this repository.
[[ "$(pf '.isCrossRepository')" == false ]] || refuse "the pull request comes from a fork or its origin is unknown"

# 3. The pull request is open.
[[ "$(pf '.state // ""')" == OPEN ]] || refuse "the pull request is not open"

# 4. Pushing to the head branch must never be a push to the default or a protected branch.
branch="$(pf '.headRef // ""')"
if [[ -z "${branch}" || "${branch}" == -* ]] || ! git check-ref-format "refs/heads/${branch}"; then
  refuse "the head branch name is unusable"
fi
repo_json="$(gh api "repos/${repo}" 2>/dev/null)" || refuse "could not read the repository from GitHub"
default_branch="$(jq -r '.default_branch // ""' <<<"${repo_json}" 2>/dev/null)"
[[ -n "${default_branch}" ]] || refuse "could not read the default branch from GitHub"
[[ "${branch}" != "${default_branch}" ]] || refuse "the head branch is the default branch"
encoded_branch="$(jq -rn --arg b "${branch}" '$b | @uri' | sed 's#%2[Ff]#/#g')"
branch_json="$(gh api "repos/${repo}/branches/${encoded_branch}" 2>/dev/null)" ||
  refuse "could not read the head branch from GitHub"
case "$(jq -r '.protected | tostring' <<<"${branch_json}" 2>/dev/null)" in
false) ;;
true) refuse "the head branch is protected" ;;
*) refuse "could not read whether the head branch is protected" ;;
esac

# 5. origin, for fetching and pushing, is the pull request's repository.
norm_url() {
  lower "$1" | sed -E -e 's#^[^/@:]+@([^:/]+):#ssh://\1/#' -e 's#^([a-z+]+://)[^/@]*@#\1#' -e 's#/+$##' -e 's#\.git$##'
}
want_https="https://github.com/$(lower "${repo}")"
want_ssh="ssh://github.com/$(lower "${repo}")"
want_test=""
[[ -z "${BABYSIT_REMOTE_BASE:-}" ]] || want_test="$(norm_url "${BABYSIT_REMOTE_BASE}/${repo}")"
check_origin() {
  local urls url
  urls="$(git remote get-url --all "$@" origin 2>/dev/null)" || refuse "origin cannot be resolved"
  [[ -n "${urls}" ]] || refuse "origin cannot be resolved"
  while IFS= read -r url; do
    url="$(norm_url "${url}")"
    [[ "${url}" == "${want_https}" || "${url}" == "${want_ssh}" || (-n "${want_test}" && "${url}" == "${want_test}") ]] ||
      refuse "origin does not resolve to ${repo}"
  done <<<"${urls}"
}
check_origin
check_origin --push

# 6. The remote branch still sits on the start commit, so the push is a fast-forward of it.
remote_out="$(git ls-remote --heads origin "refs/heads/${branch}" 2>/dev/null)" || refuse "could not read the remote branch"
remote_head="$(awk -v ref="refs/heads/${branch}" '$2 == ref {print $1}' <<<"${remote_out}")"
[[ "${remote_head}" == "${start}" ]] || refuse "the remote branch moved or was deleted since the start commit"

# 7. HEAD descends from the start commit and adds something.
head="$(git rev-parse --verify -q 'HEAD^{commit}')" || refuse "HEAD cannot be read"
git cat-file -e "${start}^{commit}" 2>/dev/null || refuse "the start commit is not in the worktree"
[[ "${head}" != "${start}" ]] || refuse "nothing to push: HEAD is the start commit"
git merge-base --is-ancestor "${start}" "${head}" || refuse "HEAD does not descend from the start commit"

# 8. The push command is exactly the verified one: no force flag, no + refspec, no other target.
want=(git push origin "${head}:refs/heads/${branch}")
same=1
((ncmd == ${#want[@]})) || same=0
for ((i = 0; same == 1 && i < ncmd; i++)); do
  [[ "${cmd[i]}" == "${want[i]}" ]] || same=0
done
((same == 1)) || refuse "the push command differs from the verified one: ${want[*]}"

emit allow "every allow condition holds" "$(jq -nc --arg head "${head}" --arg branch "${branch}" --arg start "${start}" \
  '{head: $head, branch: $branch, start: $start}')"
