#!/usr/bin/env bash
# The pre-push gate. It decides, with no LLM judgment, whether a push or a reply may go out, and prints
# one verdict with its reason as a single JSON line. A verdict it cannot determine is `refuse`.
# Usage: gate.sh push  <owner/repo> <pr> --session <token> --worktree <path> --start <sha> -- <push command>
#        gate.sh reply <owner/repo> <pr> --session <token> --body-file <file|->
# The push command must be exactly `git push origin <sha>:refs/heads/<branch>`, where <sha> is the HEAD
# the gate verified and <branch> is the pull request's head branch. The gate prints both, and pushing
# that sha instead of HEAD keeps a commit made after the check from going out unchecked.
# Output: {"verdict":"allow|park|refuse","reason":"...", ...}. An allow for a push also carries head,
# branch, and start; a park also carries matches, the category and path of each hard stop it hit.
# Exit: 0 allow, 10 park, 11 refuse, 2 usage error, 3 the lock belongs to another session.
# Anything but 0 means "do not push" or "do not post". Exit 2 and 3 print no verdict.
# BABYSIT_PR_STATE replaces pr-state.sh, and BABYSIT_REMOTE_BASE adds one accepted origin prefix; tests use both.
set -uo pipefail
export LC_ALL=C GIT_TERMINAL_PROMPT=0 GIT_OPTIONAL_LOCKS=0

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR disable=SC1091 # CI runs shellcheck without -x, so it cannot follow this.
source "${script_dir}/common.sh"

PR_STATE="${BABYSIT_PR_STATE:-${script_dir}/pr-state.sh}"

printed=0
work=""

# Any exit without a verdict, such as a failed command nobody checked, is a refusal.
# shellcheck disable=SC2329 # Invoked by the EXIT trap below.
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
  echo "       gate.sh reply <owner/repo> <pr> --session <token> --body-file <file|->" >&2
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
[[ "${mode}" == push || "${mode}" == reply ]] || usage "Unknown mode: ${mode:-<none>}"
repo="${2:-}"
pr="${3:-}"
babysit_valid_repo "${repo}" || usage "Invalid repository: ${repo:-<none>}"
babysit_valid_pr "${pr}" || usage "Invalid pull request number: ${pr:-<none>}"
shift 3

session=""
worktree=""
start=""
body_file=""
cmd=()
while (($# > 0)); do
  case "$1" in
  --)
    shift
    cmd=("$@")
    break
    ;;
  --session | --worktree | --start | --body-file)
    (($# >= 2)) || usage "$1 needs a value"
    case "$1" in
    --session) session="$2" ;;
    --worktree) worktree="$2" ;;
    --start) start="$2" ;;
    --body-file) body_file="$2" ;;
    esac
    shift 2
    ;;
  *) usage "Unknown option: $1" ;;
  esac
done
ncmd=${#cmd[@]}

[[ "${session}" =~ ^[A-Za-z0-9-]+$ ]] || usage "--session needs a token"
if [[ "${mode}" == push ]]; then
  [[ -z "${body_file}" ]] || usage "--body-file belongs to reply"
  [[ -n "${worktree}" && -d "${worktree}" ]] || usage "--worktree needs an existing directory"
  [[ "${start}" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]] || usage "--start needs a full commit sha"
  ((ncmd > 0)) || usage "The push command must follow --"
  cd "${worktree}" || usage "Cannot enter the worktree"
  [[ "$(git rev-parse --is-inside-work-tree 2>/dev/null)" == true ]] || usage "Not a Git worktree: ${worktree}"
else
  [[ -z "${worktree}" && -z "${start}" && ${ncmd} -eq 0 ]] || usage "--worktree, --start, and a push command belong to push"
  [[ "${body_file}" == - || -r "${body_file}" ]] || usage "--body-file needs a readable file or -"
fi

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

# What follows is shared by push and reply: the hard stops. Every git read must succeed, since a diff that
# failed to print would otherwise look like a diff with nothing in it.
work="$(mktemp -d)" || refuse "could not create a work directory"
findings="${work}/findings"
: >"${findings}"

note() {
  printf '%s\t%s\n' "$1" "$2" >>"${findings}"
}

# Paths, in lower case. A CI or execution config, a dependency manifest or lockfile, a test file, and a
# file that is named like a secret.
RE_CI='^\.github/|^\.gitlab-ci\.ya?ml$|^\.gitlab/|^\.circleci/|^\.buildkite/|^\.travis\.ya?ml$|^\.drone\.ya?ml$|^\.woodpecker|^\.?appveyor\.ya?ml$|^azure-pipelines|^\.azure-pipelines/|^bitbucket-pipelines\.ya?ml$|^cloudbuild\.ya?ml$|^\.?codecov\.ya?ml$|(^|/)jenkinsfile|(^|/)(gnu)?makefile$|\.mk$|(^|/)dockerfile|\.dockerfile$|(^|/)(docker-)?compose[^/]*\.ya?ml$|(^|/)justfile$|(^|/)taskfile\.ya?ml$|(^|/)prek\.toml$|(^|/)\.pre-commit-config\.ya?ml$|(^|/)lefthook[^/]*\.ya?ml$|^\.husky/|^\.githooks/|(^|/)\.envrc$|^\.devcontainer/|^\.claude/|^\.codex/|^\.opencode/|^\.cursor/|^\.agents/|^\.mcp\.json$|(^|/)(agents|claude)\.md$|(^|/)tox\.ini$|(^|/)noxfile\.py$|(^|/)\.?mise\.toml$|(^|/)\.tool-versions$'
RE_DEPS='(^|/)(package(-lock)?\.json|npm-shrinkwrap\.json|yarn\.lock|pnpm-lock\.ya?ml|pnpm-workspace\.ya?ml|bun\.lockb?|\.yarnrc(\.ya?ml)?|\.npmrc|\.pypirc|pip\.conf|go\.(mod|sum|work|work\.sum)|cargo\.(toml|lock)|pyproject\.toml|poetry\.lock|uv\.lock|pipfile(\.lock)?|setup\.(py|cfg)|gemfile(\.lock)?|composer\.(json|lock)|pom\.xml|build\.gradle(\.kts)?|settings\.gradle(\.kts)?|gradle\.properties|gradle-wrapper\.(properties|jar)|mix\.(exs|lock)|package\.swift|package\.resolved|podfile(\.lock)?|cartfile(\.resolved)?|pubspec\.(ya?ml|lock)|flake\.(nix|lock)|deno\.(jsonc?|lock)|brewfile(\.lock\.json)?|renovate\.json5?|nuget\.config|directory\.(packages|build)\.(props|targets)|packages\.lock\.json|\.gitmodules)$|(^|/)requirements[^/]*\.(txt|in)$|(^|/)constraints[^/]*\.txt$|\.(gemspec|csproj|fsproj|vbproj)$|^vendor/|/vendor/|(^|/)node_modules/|^third_party/'
RE_TESTFILE='(^|/)(tests?|__tests__|specs?|e2e|spec_helper)/|(^|/)[^/]*[._-](test|spec)\.[a-z0-9]+$|(^|/)test_[^/]*\.[a-z0-9]+$|_test\.[a-z0-9]+$|\.bats$|(^|/)[^/]*tests?\.(java|kt|cs|scala|swift)$|(^|/)conftest\.py$'
RE_SECRETFILE='(^|/)\.env(\..+)?$|(^|/)\.netrc$|(^|/)\.git-credentials$|(^|/)id_(rsa|dsa|ecdsa|ed25519)$|(^|/)credentials(\.json)?$|\.(pem|key|p12|pfx|jks|keystore|kdbx)$|(^|/)secrets?\.(ya?ml|json|toml|env)$'
RE_SECRETFILE_OK='\.env\.(example|sample|template|dist)$'

# Added lines, matched with grep -E. A quote class is built from variables to keep the patterns readable.
dq='"'
sq="'"
bt='`'
quote="[${dq}${sq}${bt}]"
RE_KEYHDR='-----BEGIN [A-Z ]*PRIVATE KEY'
RE_TOKEN='(^|[^[:alnum:]])(gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{22,}|AKIA[0-9A-Z]{16}|ASIA[0-9A-Z]{16}|xox[abprs]-[A-Za-z0-9-]{10,}|sk-[A-Za-z0-9_-]{20,}|[sr]k_live_[A-Za-z0-9]{16,}|AIza[0-9A-Za-z_-]{35}|glpat-[A-Za-z0-9_-]{20,}|npm_[A-Za-z0-9]{36}|SG\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}|eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,})'
RE_ASSIGN="(key|token|secret|passw(or)?d|credentials?)[A-Za-z0-9_]*${quote}?[[:space:]]*(:=|=|:)[[:space:]]*${quote}[^${dq}${sq}${bt}\$[:space:]{<(][^${dq}${sq}${bt}]{5,}${quote}"
RE_URL='(https?|ftp|ssh|sftp|git|wss?)://|(^|[^[:alnum:]_.-])git@[A-Za-z0-9.-]+:'
RE_NETCMD='(^|[^[:alnum:]_.-])(curl|wget|nc|ncat|netcat|telnet|ssh|scp|sftp|rsync)([^[:alnum:]_-]|$)'
RE_NETAPI='(^|[^[:alnum:]_.])fetch[[:space:]]*\(|axios|XMLHttpRequest|requests\.(get|post|put|patch|delete|head|request|session)|urllib|httpx|aiohttp|http\.(Get|Post|Head|PostForm|NewRequest|DefaultClient)|net/http|HttpClient|Net::HTTP|URLSession|okhttp|reqwest|WebSocket|socket\.(connect|create_connection)|net\.Dial|Invoke-(WebRequest|RestMethod)'
RE_IMAGE='!\[[^]]*\]\(|<img[[:space:]>/]'
RE_SKIP='(^|[^[:alnum:]_])(it|test|describe|context|suite|specify|scenario)\.(skip|only|todo|failing)([^[:alnum:]_]|$)|(^|[^[:alnum:]_.])(xit|xdescribe|xtest|xcontext|fit|fdescribe|fcontext|ftest)[[:space:]]*\(|@pytest\.mark\.(skip|skipif|xfail)|pytest\.(skip|xfail)[[:space:]]*\(|@unittest\.(skip|expectedFailure)|self\.skipTest[[:space:]]*\(|@(Disabled|Ignore)([^[:alnum:]_]|$)|(^|[^[:alnum:]_.])[tb]\.Skip(f|Now)?[[:space:]]*\(|#\[ignore|passWithNoTests'
RE_SKIP_RUBY="^[[:space:]]*(xit|xdescribe|xcontext|skip|pending)[[:space:]]+[${dq}${sq}:]"
RE_SKIP_BATS='^[[:space:]]*skip([[:space:]]|$)'
RE_COVERAGE='fail[_-]?under|coverage[_-]?threshold|(minimum|min|required)[_-]?coverage'
RE_DECL="^[[:space:]]*(it|test|specify|scenario)(\\.each[^(]*)?[[:space:]]*[(${bt}${sq}${dq}]|^[[:space:]]*(async[[:space:]]+)?def[[:space:]]+test|^[[:space:]]*func[[:space:]]+(\\([^)]*\\)[[:space:]]*)?Test|^[[:space:]]*@test([[:space:]]|\$)|^[[:space:]]*#\\[(tokio::)?test"

# Succeeds when grep with the options $1 finds the pattern $2 in file $3; any grep error is a refusal.
has() {
  local rc
  grep "$1" -e "$2" "$3" >/dev/null 2>&1
  rc=$?
  ((rc <= 1)) || refuse "a pattern scan failed"
  return "${rc}"
}

# Sets decl_count to the number of test declarations in file $1.
count_decl() {
  local rc
  decl_count="$(grep -Eic -e "${RE_DECL}" "$1" 2>/dev/null)"
  rc=$?
  ((rc <= 1)) && [[ "${decl_count}" =~ ^[0-9]+$ ]] || refuse "a pattern scan failed"
}

# Records the secrets in the text file $2 as found in $1, which is what the finding names.
scan_secrets() {
  has -Eq "${RE_KEYHDR}" "$2" && note secrets "$1"
  has -Eq "${RE_TOKEN}" "$2" && note secrets "$1"
  has -Eiq "${RE_ASSIGN}" "$2" && note secrets "$1"
}

# Records the hard stops that the path $1 hits by name alone, and sets path_lower to the path in lower case.
# Fails for a path with a control character, which cannot be matched reliably and so is a finding itself.
path_rules() {
  if [[ "$1" == *[[:cntrl:]]* ]]; then
    note path "$(printf '%q' "$1")"
    return 1
  fi
  path_lower="$(lower "$1")"
  [[ "${path_lower}" =~ ${RE_CI} ]] && note ci "$1"
  [[ "${path_lower}" =~ ${RE_DEPS} ]] && note deps "$1"
  return 0
}

# Records every hard stop that the change from $1 to $2 hits. The paths after them, when given, restrict it.
scan_diff() {
  local old="$1" new="$2" raw="${work}/raw" patch="${work}/patch" added="${work}/added" removed="${work}/removed"
  local meta path oldmode newmode status is_test rc na nr
  shift 2
  # The paths are names, not patterns: a name like a[1].txt must match itself and not a1.txt.
  GIT_LITERAL_PATHSPECS=1 git diff --raw -z --no-renames --no-ext-diff --no-textconv --no-color "${old}" "${new}" -- "$@" \
    >"${raw}" </dev/null || refuse "could not read the diff"
  while IFS= read -r -d '' meta && IFS= read -r -d '' path; do
    read -r oldmode newmode _ _ status <<<"${meta#:}"
    case "${status}" in
    A | M | D | T) ;;
    *) refuse "the diff holds a change of an unreadable kind" ;;
    esac
    path_rules "${path}" || continue
    if [[ "${oldmode}" == 160000 || "${newmode}" == 160000 ]]; then
      note deps "${path}"
      continue
    fi
    is_test=0
    [[ "${path_lower}" =~ ${RE_TESTFILE} ]] && is_test=1
    if [[ "${status}" == D ]]; then
      ((is_test == 1)) && note tests "${path}"
      continue
    fi
    [[ "${path_lower}" =~ ${RE_SECRETFILE} && ! "${path_lower}" =~ ${RE_SECRETFILE_OK} ]] && note secrets "${path}"

    git diff -U0 --no-color --no-ext-diff --no-textconv --no-renames "${old}" "${new}" -- ":(literal)${path}" \
      >"${patch}" </dev/null || refuse "could not read the diff"
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
      note binary "${path}"
      continue
    fi
    ((rc == 0)) || refuse "could not read the added lines"

    scan_secrets "${path}" "${added}"
    has -Eq "${RE_URL}" "${added}" && note network "${path}"
    has -Eiq "${RE_NETCMD}" "${added}" && note network "${path}"
    has -Eiq "${RE_NETAPI}" "${added}" && note network "${path}"
    has -Eq "${RE_SKIP}" "${added}" && note tests "${path}"
    has -Eiq "${RE_COVERAGE}" "${added}" && note tests "${path}"
    if [[ "${path_lower}" == *.bats ]]; then
      has -Eq "${RE_SKIP_BATS}" "${added}" && note tests "${path}"
    fi
    if ((is_test == 1)); then
      has -Eq "${RE_SKIP_RUBY}" "${added}" && note tests "${path}"
      count_decl "${added}"
      na=${decl_count}
      count_decl "${removed}"
      nr=${decl_count}
      ((nr > na)) && note tests "${path}"
    fi
  done <"${raw}"
}

# Ends with park when anything was found, and with allow otherwise. $1 is the JSON merged into the verdict.
finish() {
  local categories matches
  if [[ -s "${findings}" ]]; then
    categories="$(cut -f1 "${findings}" | sort -u | paste -sd, - | sed 's/,/, /g')"
    matches="$(jq -R -s -c '
      split("\n") | map(select(length > 0) | split("\t") | {category: .[0], path: .[1]})
      | unique | group_by(.category) | map(.[:10]) | add' "${findings}")" || refuse "could not list the matches"
    emit park "a hard stop matched: ${categories}" "$(jq -nc --argjson x "$1" --argjson matches "${matches}" \
      '$x + {matches: $matches}')"
  fi
  emit allow "every allow condition holds and no hard stop matched" "$1"
}

if [[ "${mode}" == reply ]]; then
  # A reply is checked against conditions 0 to 3 above and for secrets and images that load from outside.
  # An image address can carry data out when GitHub fetches it, so the gate treats it as outbound network.
  if [[ "${body_file}" == - ]]; then
    cat >"${work}/body" || refuse "could not read the reply"
  else
    cat "${body_file}" >"${work}/body" || refuse "could not read the reply"
  fi
  scan_secrets "reply body" "${work}/body"
  has -Eiq "${RE_IMAGE}" "${work}/body" && note network "reply body"
  finish '{}'
fi

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

# 9. No hard stop matches. Paths and added lines are inspected commit by commit, because a secret that one
# commit adds and the next removes still lands in the remote history.
# A merge of the base is the one case that skips the commit-by-commit scan: the only commit the base's
# history does not already hold has the start as its first parent and a commit of the base's history as
# its second. The base's own changes are already in the base, so only what the merge did beyond them is
# inspected, as the paths that differ from the automatic merge or conflicted, and each of those as a whole
# path. Any other shape falls back to the full scan, which inspects at least as much.
base_merge=0
range=("${start}..${head}")
base_ref="$(pf '.baseRef // ""')"
if [[ -n "${base_ref}" && "${base_ref}" != -* ]] && git check-ref-format "refs/heads/${base_ref}" &&
  git fetch -q --no-tags origin "refs/heads/${base_ref}" 2>/dev/null &&
  base_tip="$(git rev-parse --verify -q 'FETCH_HEAD^{commit}')" &&
  git rev-list --parents --reverse "${start}..${head}" "^${base_tip}" >"${work}/novel" 2>/dev/null &&
  [[ "$(wc -l <"${work}/novel" | tr -d ' ')" == 1 ]]; then
  read -r _ parent1 parent2 extra_parent <"${work}/novel"
  if [[ "${parent1}" == "${start}" && -n "${parent2}" && -z "${extra_parent}" ]] &&
    git merge-base --is-ancestor "${parent2}" "${base_tip}" 2>/dev/null; then
    git merge-tree --write-tree --name-only -z "${start}" "${parent2}" >"${work}/merge-tree" 2>/dev/null
    case $? in
    0 | 1)
      base_merge=1
      range=("${start}..${head}" "^${base_tip}")
      ;;
    esac
  fi
fi

if ((base_merge == 0)); then
  git rev-list --parents --reverse "${start}..${head}" >"${work}/commits" 2>/dev/null || refuse "could not list the new commits"
fi

if ((base_merge == 1)); then
  touched=()
  {
    IFS= read -r -d '' merged_tree
    while IFS= read -r -d '' conflicted && [[ -n "${conflicted}" ]]; do
      touched+=("${conflicted}")
    done
  } <"${work}/merge-tree"
  [[ -n "${merged_tree:-}" ]] || refuse "could not recompute the merge of the base"
  git diff --raw -z --no-renames --no-ext-diff --no-textconv --no-color "${merged_tree}" "${head}" >"${work}/resolution" </dev/null ||
    refuse "could not compare the merge with the automatic merge"
  while IFS= read -r -d '' _ && IFS= read -r -d '' resolved; do
    touched+=("${resolved}")
  done <"${work}/resolution"
  if ((${#touched[@]} > 0)); then
    for path in "${touched[@]}"; do
      path_rules "${path}"
    done
    scan_diff "${start}" "${head}" "${touched[@]}"
  fi
else
  while read -r commit parents; do
    [[ -n "${commit}" ]] || continue
    for parent in ${parents}; do
      scan_diff "${parent}" "${commit}"
    done
  done <"${work}/commits"
fi

git log --format=%B "${range[@]}" >"${work}/messages" 2>/dev/null || refuse "could not read the commit messages"
scan_secrets "commit message" "${work}/messages"

finish "$(jq -nc --arg head "${head}" --arg branch "${branch}" --arg start "${start}" \
  '{head: $head, branch: $branch, start: $start}')"
