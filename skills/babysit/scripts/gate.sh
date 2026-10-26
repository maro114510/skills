#!/usr/bin/env bash
# Pre-push gate. Prints one verdict as a JSON line.
# gate.sh push <owner/repo> <pr> --session <token> --worktree <path> --start <sha> -- git push origin <sha>:refs/heads/<branch>
# The command after -- must match exactly, and the sha is the HEAD this gate checked.
# Exit 0 allow, 10 park, 11 refuse, 2 usage error, 3 lock lost. Anything but 0 means do not push.
# Test hooks BABYSIT_PR_STATE and BABYSIT_REMOTE_BASE.
set -uo pipefail
# GIT_NO_REPLACE_OBJECTS makes git read the objects that get pushed.
export LC_ALL=C GIT_TERMINAL_PROMPT=0 GIT_OPTIONAL_LOCKS=0 GIT_NO_REPLACE_OBJECTS=1
# Caller pathspec settings would change how a literal path matches.
unset GIT_LITERAL_PATHSPECS GIT_GLOB_PATHSPECS GIT_NOGLOB_PATHSPECS GIT_ICASE_PATHSPECS

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR disable=SC1091 # CI does not follow sources.
source "${script_dir}/common.sh"

PR_STATE="${BABYSIT_PR_STATE:-${script_dir}/pr-state.sh}"

printed=0
work=""

# No verdict means refuse.
# shellcheck disable=SC2329 # Called by the EXIT trap.
on_exit() {
  [[ -z "${work}" ]] || rm -rf "${work}"
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

# Prints verdict $1 with reason $2 and extra JSON $3, then exits with its code.
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

[[ "${1:-}" == push ]] || usage "Unknown mode: ${1:-<none>}"
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
# Git prints paths from the checkout root, so run from there.
cd "$(git rev-parse --show-toplevel)" || usage "Cannot enter the worktree"

# The lock shows this session owns the pull request.
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

# Snapshot is for the requested pull request
[[ "$(lower "$(pf '.repo // ""')")" == "$(lower "${repo}")" && "$(pf '.number // 0')" == "${pr}" ]] ||
  refuse "the snapshot describes another pull request"

# Viewer is the author
viewer="$(lower "$(pf '.viewer // ""')")"
author="$(lower "$(pf '.author // ""')")"
[[ -n "${viewer}" && "${viewer}" == "${author}" ]] || refuse "the viewer is not the pull request author"

# Head branch is in this repository
[[ "$(pf '.isCrossRepository')" == false ]] || refuse "the pull request comes from a fork or its origin is unknown"

# Pull request is open
[[ "$(pf '.state // ""')" == OPEN ]] || refuse "the pull request is not open"

# Head branch is not the default branch
branch="$(pf '.headRef // ""')"
if [[ -z "${branch}" || "${branch}" == -* ]] || ! git check-ref-format "refs/heads/${branch}"; then
  refuse "the head branch name is unusable"
fi
repo_json="$(gh api "repos/${repo}" 2>/dev/null)" || refuse "could not read the default branch from GitHub"
default_branch="$(jq -r '.default_branch // ""' <<<"${repo_json}" 2>/dev/null)"
[[ -n "${default_branch}" ]] || refuse "could not read the default branch from GitHub"
[[ "${branch}" != "${default_branch}" ]] || refuse "the head branch is the default branch"

# origin is the pull request repository
norm_url() {
  lower "$1" | sed -E -e 's#^[^/@:]+@([^:/]+):#ssh://\1/#' -e 's#^([a-z+]+://)[^/@\#?]*@#\1#' -e 's#/+$##' -e 's#\.git$##'
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

# Remote branch is still at the start commit
remote_out="$(git ls-remote --heads origin "refs/heads/${branch}" 2>/dev/null)" || refuse "could not read the remote branch"
remote_head="$(awk -v ref="refs/heads/${branch}" '$2 == ref {print $1}' <<<"${remote_out}")"
[[ "${remote_head}" == "${start}" ]] || refuse "the remote branch moved or was deleted since the start commit"

# HEAD descends from the start commit and adds one
head="$(git rev-parse --verify -q 'HEAD^{commit}')" || refuse "HEAD cannot be read"
git cat-file -e "${start}^{commit}" 2>/dev/null || refuse "the start commit is not in the worktree"
[[ "${head}" != "${start}" ]] || refuse "nothing to push: HEAD is the start commit"
git merge-base --is-ancestor "${start}" "${head}" || refuse "HEAD does not descend from the start commit"

# Push command matches exactly
want=(git push origin "${head}:refs/heads/${branch}")
same=1
((ncmd == ${#want[@]})) || same=0
for ((i = 0; same == 1 && i < ncmd; i++)); do
  [[ "${cmd[i]}" == "${want[i]}" ]] || same=0
done
((same == 1)) || refuse "the push command differs from the verified one: ${want[*]}"

# Hard stops are read one commit at a time, because a removed secret stays in history, and every git read must succeed.
work="$(mktemp -d)" || refuse "could not create a work directory"
findings="${work}/findings"
: >"${findings}"

note() {
  printf '%s\t%s\n' "$1" "$2" >>"${findings}"
}

# Path patterns, matched in lower case
RE_CI='^\.github/|^\.gitlab-ci\.ya?ml$|^\.gitlab/|^\.circleci/|^\.buildkite/|^\.travis\.ya?ml$|^\.drone\.ya?ml$|^\.woodpecker|^\.?appveyor\.ya?ml$|^azure-pipelines|^\.azure-pipelines/|^bitbucket-pipelines\.ya?ml$|^cloudbuild\.ya?ml$|^\.?codecov\.ya?ml$|(^|/)jenkinsfile|(^|/)(gnu)?makefile$|\.mk$|(^|/)dockerfile|\.dockerfile$|(^|/)(docker-)?compose[^/]*\.ya?ml$|(^|/)justfile$|(^|/)taskfile\.ya?ml$|(^|/)prek\.toml$|(^|/)\.pre-commit-config\.ya?ml$|(^|/)lefthook[^/]*\.ya?ml$|^\.husky/|^\.githooks/|(^|/)\.envrc$|^\.devcontainer/|^\.claude/|^\.codex/|^\.opencode/|^\.cursor/|^\.agents/|^\.mcp\.json$|(^|/)(agents|claude)\.md$|(^|/)tox\.ini$|(^|/)noxfile\.py$|(^|/)\.?mise\.toml$|(^|/)\.tool-versions$'
RE_DEPS='(^|/)(package(-lock)?\.json|npm-shrinkwrap\.json|yarn\.lock|pnpm-lock\.ya?ml|pnpm-workspace\.ya?ml|bun\.lockb?|\.yarnrc(\.ya?ml)?|\.npmrc|\.pypirc|pip\.conf|go\.(mod|sum|work|work\.sum)|cargo\.(toml|lock)|pyproject\.toml|poetry\.lock|uv\.lock|pipfile(\.lock)?|setup\.(py|cfg)|gemfile(\.lock)?|composer\.(json|lock)|pom\.xml|build\.gradle(\.kts)?|settings\.gradle(\.kts)?|gradle\.properties|gradle-wrapper\.(properties|jar)|mix\.(exs|lock)|package\.swift|package\.resolved|podfile(\.lock)?|cartfile(\.resolved)?|pubspec\.(ya?ml|lock)|flake\.(nix|lock)|deno\.(jsonc?|lock)|brewfile(\.lock\.json)?|renovate\.json5?|nuget\.config|directory\.(packages|build)\.(props|targets)|packages\.lock\.json|\.gitmodules)$|(^|/)requirements[^/]*\.(txt|in)$|(^|/)constraints[^/]*\.txt$|\.(gemspec|csproj|fsproj|vbproj)$|^vendor/|/vendor/|(^|/)node_modules/|^third_party/'
RE_TESTFILE='(^|/)(tests?|__tests__|specs?|e2e|spec_helper)/|(^|/)[^/]*[._-](test|spec)\.[a-z0-9]+$|(^|/)test_[^/]*\.[a-z0-9]+$|_test\.[a-z0-9]+$|\.bats$|(^|/)[^/]*tests?\.(java|kt|cs|scala|swift)$|(^|/)conftest\.py$'
RE_SECRETFILE='(^|/)\.env(\..+)?$|(^|/)\.netrc$|(^|/)\.git-credentials$|(^|/)id_(rsa|dsa|ecdsa|ed25519)$|(^|/)credentials(\.json)?$|\.(pem|key|p12|pfx|jks|keystore|kdbx)$|(^|/)secrets?\.(ya?ml|json|toml|env)$'
RE_SECRETFILE_OK='\.env\.(example|sample|template|dist)$'

# Line patterns for grep -E
dq='"'
sq="'"
bt='`'
quote="[${dq}${sq}${bt}]"
RE_KEYHDR='-----BEGIN [A-Z ]*PRIVATE KEY'
RE_TOKEN='(^|[^[:alnum:]])(gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{22,}|AKIA[0-9A-Z]{16}|ASIA[0-9A-Z]{16}|xox[abprs]-[A-Za-z0-9-]{10,}|sk-[A-Za-z0-9_-]{20,}|[sr]k_live_[A-Za-z0-9]{16,}|AIza[0-9A-Za-z_-]{35}|glpat-[A-Za-z0-9_-]{20,}|npm_[A-Za-z0-9]{36}|SG\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}|eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,})'
RE_ASSIGN="(key|token|secret|passw(or)?d|credentials?)[A-Za-z0-9_]*${quote}?[[:space:]]*(:=|=|:)[[:space:]]*${quote}[^${dq}${sq}${bt}\$[:space:]{<(][^${dq}${sq}${bt}]{5,}${quote}"
# An unquoted literal that ends the line or a # comment, with punctuation allowed. A reference, a call, a bracketed value, and prose after the value do not match.
RE_ASSIGN_BARE='(key|token|secret|passw(or)?d|credentials?)[A-Za-z0-9_]*[[:space:]]*(:=|=|:)[[:space:]]*[A-Za-z0-9+/_.~@!#%^&*?|:,-][A-Za-z0-9+/_.=~@!#%^&*?|:,-]{7,};?[[:space:]]*(#.*)?$'
RE_URL='(https?|ftp|ssh|sftp|git|wss?)://|(^|[^[:alnum:]_.-])git@[A-Za-z0-9.-]+:'
RE_NETCMD='(^|[^[:alnum:]_.-])(curl|wget|nc|ncat|netcat|telnet|ssh|scp|sftp|rsync)([^[:alnum:]_-]|$)'
RE_NETAPI='(^|[^[:alnum:]_.])fetch[[:space:]]*\(|axios|XMLHttpRequest|requests\.(get|post|put|patch|delete|head|request|session)|urllib|httpx|aiohttp|http\.(Get|Post|Head|PostForm|NewRequest|DefaultClient)|net/http|(^|[^[:alnum:]_.])https?2?\.(get|post|put|patch|delete|head|request|connect)[[:space:]]*\(|(^|[^[:alnum:]_.])(net|tls)\.(connect|createConnection)[[:space:]]*\(|http\.client|(require[[:space:]]*\(|from|import)[[:space:]]*.?(node:)?https?2?([^[:alnum:]_]|$)|HttpClient|Net::HTTP|URLSession|okhttp|reqwest|WebSocket|socket\.(connect|create_connection)|net\.Dial|Invoke-(WebRequest|RestMethod)'
RE_SKIP='(^|[^[:alnum:]_])(it|test|describe|context|suite|specify|scenario)\.(skip|only|todo|failing)([^[:alnum:]_]|$)|(^|[^[:alnum:]_.])(xit|xdescribe|xtest|xcontext|fit|fdescribe|fcontext|ftest)[[:space:]]*\(|@pytest\.mark\.(skip|skipif|xfail)|pytest\.(skip|xfail)[[:space:]]*\(|@unittest\.(skip|expectedFailure)|self\.skipTest[[:space:]]*\(|@(Disabled|Ignore)([^[:alnum:]_]|$)|(^|[^[:alnum:]_.])[tb]\.Skip(f|Now)?[[:space:]]*\(|#\[ignore|passWithNoTests'
RE_SKIP_BATS='^[[:space:]]*skip([[:space:]]|$)'
RE_COVERAGE='fail[_-]?under|coverage[_-]?threshold|(minimum|min|required)[_-]?coverage'

# Returns the grep status, and refuses on a grep error.
has() {
  local rc
  grep "$1" -e "$2" "$3" >/dev/null 2>&1
  rc=$?
  ((rc <= 1)) || refuse "a pattern scan failed"
  return "${rc}"
}

# Notes secrets found in file $2 under the name $1.
scan_secrets() {
  has -Eq "${RE_KEYHDR}" "$2" && note secrets "$1"
  has -Eq "${RE_TOKEN}" "$2" && note secrets "$1"
  has -Eiq "${RE_ASSIGN}" "$2" && note secrets "$1"
  has -Eiq "${RE_ASSIGN_BARE}" "$2" && note secrets "$1"
}

# Diff flags. No renames, no external or text drivers, no ignored submodules.
DIFF_FLAGS=(--no-color --no-renames --no-ext-diff --no-textconv --ignore-submodules=none)

# Empty tree id of this repository.
EMPTY_TREE="$(git hash-object -t tree /dev/null 2>/dev/null)" || refuse "could not name the empty tree"

# Notes every hard stop in the change from $1 to $2.
scan_diff() {
  local old="$1" new="$2" raw="${work}/raw" patch="${work}/patch" added="${work}/added" removed="${work}/removed"
  local meta path lower_path oldmode newmode status rc
  git diff --raw -z "${DIFF_FLAGS[@]}" "${old}" "${new}" >"${raw}" </dev/null || refuse "could not read the diff"
  while IFS= read -r -d '' meta && IFS= read -r -d '' path; do
    read -r oldmode newmode _ _ status <<<"${meta#:}"
    case "${status}" in
    A | M | D | T) ;;
    *) refuse "the diff holds a change of an unreadable kind" ;;
    esac
    lower_path="$(lower "${path}")"
    [[ "${lower_path}" =~ ${RE_CI} ]] && note ci "${path}"
    [[ "${lower_path}" =~ ${RE_DEPS} ]] && note deps "${path}"
    if [[ "${oldmode}" == 160000 || "${newmode}" == 160000 ]]; then
      note deps "${path}"
      continue
    fi
    # A secret file is named for every status, a deleted one included.
    [[ "${lower_path}" =~ ${RE_SECRETFILE} && ! "${lower_path}" =~ ${RE_SECRETFILE_OK} ]] && note secrets "${path}"
    if [[ "${status}" == D ]]; then
      [[ "${lower_path}" =~ ${RE_TESTFILE} ]] && note tests "${path}"
    fi

    git diff -U0 "${DIFF_FLAGS[@]}" "${old}" "${new}" -- ":(literal)${path}" >"${patch}" </dev/null ||
      refuse "could not read the diff"
    : >"${added}"
    : >"${removed}"
    awk -v a="${added}" -v r="${removed}" '
      /^@@/ { hunk = 1; next }
      !hunk && /^Binary files / { bin = 1 }
      hunk && /^\+/ { print substr($0, 2) >> a }
      hunk && /^-/ { print substr($0, 2) >> r }
      END { exit bin ? 7 : 0 }' "${patch}"
    rc=$?
    if ((rc == 7)); then
      # A deleted binary file holds no text to weigh, as before.
      [[ "${status}" == D ]] || note binary "${path}"
      continue
    fi
    ((rc == 0)) || refuse "could not read the added lines"

    # A removed coverage setting weakens the tests as much as an added one.
    has -Eiq "${RE_COVERAGE}" "${removed}" && note tests "${path}"
    [[ "${status}" != D ]] || continue

    scan_secrets "${path}" "${added}"
    has -Eq "${RE_URL}" "${added}" && note network "${path}"
    has -Eiq "${RE_NETCMD}" "${added}" && note network "${path}"
    has -Eiq "${RE_NETAPI}" "${added}" && note network "${path}"
    has -Eq "${RE_SKIP}" "${added}" && note tests "${path}"
    has -Eiq "${RE_COVERAGE}" "${added}" && note tests "${path}"
    if [[ "${lower_path}" == *.bats ]]; then
      has -Eq "${RE_SKIP_BATS}" "${added}" && note tests "${path}"
    fi
  done <"${raw}"
}

git rev-list --parents --reverse "${start}..${head}" >"${work}/commits" 2>/dev/null || refuse "could not list the new commits"
while read -r commit parents; do
  [[ -n "${commit}" ]] || continue
  # A root commit is compared with the empty tree.
  [[ -n "${parents}" ]] || parents="${EMPTY_TREE}"
  for parent in ${parents}; do
    scan_diff "${parent}" "${commit}"
  done
done <"${work}/commits"

git log --format=%B "${start}..${head}" >"${work}/messages" 2>/dev/null || refuse "could not read the commit messages"
scan_secrets "commit message" "${work}/messages"

verdict="$(jq -nc --arg head "${head}" --arg branch "${branch}" --arg start "${start}" \
  '{head: $head, branch: $branch, start: $start}')"
if [[ -s "${findings}" ]]; then
  categories="$(cut -f1 "${findings}" | sort -u | paste -sd, - | sed 's/,/, /g')"
  matches="$(jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t") | {category: .[0], path: .[1]}) | unique | .[:20]' \
    "${findings}")" || refuse "could not list the matches"
  emit park "a hard stop matched: ${categories}" "$(jq -nc --argjson x "${verdict}" --argjson m "${matches}" '$x + {matches: $m}')"
fi
emit allow "every allow condition holds and no hard stop matched" "${verdict}"
