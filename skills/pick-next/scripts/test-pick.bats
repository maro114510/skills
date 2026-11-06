#!/usr/bin/env bats
# Tests for pick.sh against a local repository with real worktrees. GitHub is faked: gh is a stub on PATH that
# prints the Issue and pull request pages written by the helpers below.
# shellcheck disable=SC2292 # bats fails a test on a mid-test `[[ ]]` only under bash 4.1+; `[ ]` works on every bash.

setup() {
  target="${BATS_TEST_DIRNAME}/pick.sh"
  unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_PREFIX
  repo="${BATS_TEST_TMPDIR}/repo"
  git init -q -b main "${repo}"
  cd "${repo}" || return 1
  git config user.email t@example.invalid
  git config user.name t
  git config core.hooksPath /dev/null
  git commit -q --allow-empty -m base
  git remote add origin https://github.com/o/r.git
  issues="${BATS_TEST_TMPDIR}/issues.jsonl"
  prs="${BATS_TEST_TMPDIR}/prs.jsonl"
  : >"${issues}"
  : >"${prs}"
  mkdir -p "${BATS_TEST_TMPDIR}/bin"
  PATH="${BATS_TEST_TMPDIR}/bin:${PATH}"
  fake_gh
}

# Fakes gh api graphql: the Issue query gets one page holding every issue() node, viewer me, and the pull
# request query one page holding every pr() node. Any other call fails, so a write would fail the test.
fake_gh() {
  cat >"${BATS_TEST_TMPDIR}/bin/gh" <<EOF
#!/usr/bin/env bash
[ "\$1 \$2" = "api graphql" ] || { echo "unexpected gh call: \$*" >&2; exit 1; }
case "\$*" in
*"owner=o"*"repo=r"*) ;;
*) echo "unexpected repository: \$*" >&2; exit 1 ;;
esac
case "\$*" in
*"pullRequests("*) jq -sc '{data: {repository: {pullRequests: {pageInfo: {hasNextPage: false, endCursor: null}, nodes: .}}}}' "${prs}" ;;
*"issues("*) jq -sc '{data: {viewer: {login: "me"}, repository: {issues: {pageInfo: {hasNextPage: false, endCursor: null}, nodes: .}}}}' "${issues}" ;;
*) echo "unexpected query: \$*" >&2; exit 1 ;;
esac
EOF
  chmod +x "${BATS_TEST_TMPDIR}/bin/gh"
}

# Adds open Issue $1 titled $2. Options set its relations:
#   --blocked-by <n>:<OPEN|CLOSED>  an Issue that blocks it
#   --blocks <n>                    an open Issue it blocks
#   --parent <n>:<completed>/<total> its Epic and that Epic's progress
#   --subs <completed>/<total>      makes it an Epic with that progress
#   --assignee <login>              an assignee
#   --branch <name>                 a branch GitHub links to it
issue() {
  local num="$1" title="$2" blocked='[]' blocks='[]' parent=null subs='{"total":0,"completed":0}' assignees='[]' branches='[]'
  shift 2
  while [ $# -gt 0 ]; do
    case "$1" in
    --blocked-by) blocked="$(jq -c --arg n "${2%%:*}" --arg s "${2#*:}" '. + [{number: ($n | tonumber), title: ("Blocker " + $n), state: $s}]' <<<"${blocked}")" ;;
    --blocks) blocks="$(jq -c --argjson n "$2" '. + [{number: $n, state: "OPEN"}]' <<<"${blocks}")" ;;
    --parent)
      parent="$(jq -nc --argjson n "${2%%:*}" --argjson c "$(cut -d: -f2 <<<"$2" | cut -d/ -f1)" --argjson t "${2##*/}" \
        '{number: $n, title: ("Epic " + ($n | tostring)), subIssuesSummary: {completed: $c, total: $t}}')"
      ;;
    --subs) subs="$(jq -nc --argjson c "${2%/*}" --argjson t "${2#*/}" '{completed: $c, total: $t}')" ;;
    --assignee) assignees="$(jq -c --arg l "$2" '. + [{login: $l}]' <<<"${assignees}")" ;;
    --branch) branches="$(jq -c --arg b "$2" '. + [{ref: {name: $b}}]' <<<"${branches}")" ;;
    *)
      echo "unknown issue option $1" >&2
      return 1
      ;;
    esac
    shift 2
  done
  jq -nc --argjson n "${num}" --arg t "${title}" --argjson blocked "${blocked}" --argjson blocks "${blocks}" \
    --argjson parent "${parent}" --argjson subs "${subs}" --argjson assignees "${assignees}" --argjson branches "${branches}" \
    '{number: $n, title: $t, url: ("https://github.com/o/r/issues/" + ($n | tostring)), body: ("Body of " + $t),
      assignees: {nodes: $assignees}, parent: $parent, subIssuesSummary: $subs,
      blockedBy: {nodes: $blocked}, blocking: {nodes: $blocks}, linkedBranches: {nodes: $branches}}' >>"${issues}"
}

# Adds open pull request $1 titled $2 from branch $3 with checks $4 (SUCCESS, FAILURE, PENDING, or none).
# Options: --draft, --closes <n>, --review <APPROVED|CHANGES_REQUESTED|REVIEW_REQUIRED>.
pr() {
  local num="$1" title="$2" branch="$3" checks="$4" draft=false closes='[]' review=null rollup
  shift 4
  while [ $# -gt 0 ]; do
    case "$1" in
    --draft)
      draft=true
      shift
      ;;
    --closes)
      closes="$(jq -c --argjson n "$2" '. + [{number: $n}]' <<<"${closes}")"
      shift 2
      ;;
    --review)
      review="\"$2\""
      shift 2
      ;;
    *)
      echo "unknown pr option $1" >&2
      return 1
      ;;
    esac
  done
  if [ "${checks}" = none ]; then rollup=null; else rollup="{\"state\":\"${checks}\"}"; fi
  jq -nc --argjson n "${num}" --arg t "${title}" --arg b "${branch}" --argjson draft "${draft}" --argjson closes "${closes}" \
    --argjson review "${review}" --argjson rollup "${rollup}" \
    '{number: $n, title: $t, url: ("https://github.com/o/r/pull/" + ($n | tostring)), body: ("Body of " + $t),
      isDraft: $draft, headRefName: $b, reviewDecision: $review, closingIssuesReferences: {nodes: $closes},
      commits: {nodes: [{commit: {statusCheckRollup: $rollup}}]}}' >>"${prs}"
}

# Checks out branch $1 in a new worktree at $2.
worktree_on() {
  git -C "${repo}" worktree add -q -b "$1" "$2"
}

canonical() {
  (cd "$1" && pwd -P)
}

field() {
  jq -cr "$1" <<<"${output}"
}

expect() {
  if [ "$1" != "$2" ]; then
    echo "expected [$2], got [$1]; output: ${output}" >&2
    return 1
  fi
}

@test "an Issue blocked by an open Issue is listed as blocked with its blocker, and never under next" {
  issue 10 "Blocked work" --blocked-by 11:OPEN
  issue 11 "Blocker work" --blocks 10
  run bash "${target}"
  expect "${status}" 0
  expect "$(field '[.blocked[] | {number, blockedBy}]')" '[{"number":10,"blockedBy":[{"number":11,"title":"Blocker 11"}]}]'
  expect "$(field '[.next[].number]')" '[11]'
}

@test "an Issue blocked while already in progress in a worktree still never appears under next" {
  issue 10 "Blocked work" --blocked-by 11:OPEN --branch feat/issue-10-blocked
  issue 11 "Blocker work" --blocks 10
  worktree_on feat/issue-10-blocked "${BATS_TEST_TMPDIR}/wt10"
  run bash "${target}"
  expect "${status}" 0
  expect "$(field '[.next[].number]')" '[11]'
  expect "$(field '[.blocked[].number]')" '[10]'
}

@test "an Issue whose only blocker is closed is listed under next" {
  issue 10 "Unblocked work" --blocked-by 9:CLOSED
  run bash "${target}"
  expect "${status}" 0
  expect "$(field '[.next[].number]')" '[10]'
  expect "$(field '.blocked')" '[]'
}

@test "next ranks work in progress, then Issues that unblock more, then Epics with progress, then lower numbers" {
  issue 20 "Untouched Epic child" --parent 2:0/3
  issue 21 "Child of an Epic with progress" --parent 3:1/3
  issue 22 "Unblocks one" --blocks 40
  issue 23 "Unblocks two" --blocks 40 --blocks 41
  issue 24 "Has a worktree" --branch feat/issue-24-x
  issue 25 "Assigned to me" --assignee me
  issue 26 "Plain later"
  issue 19 "Plain earlier"
  issue 40 "Blocked A" --blocked-by 22:OPEN --blocked-by 23:OPEN
  issue 41 "Blocked B" --blocked-by 23:OPEN
  worktree_on feat/issue-24-x "${BATS_TEST_TMPDIR}/wt24"
  run bash "${target}" --limit 10
  expect "${status}" 0
  expect "$(field '[.next[].number]')" '[24,25,23,22,21,19,20,26]'
  expect "$(field '.next[0].inProgress')" true
  expect "$(field '.next[2].unblocks')" 2
  expect "$(field '.next[4].epic')" '{"number":3,"title":"Epic 3","completed":1,"total":3}'
}

@test "an Epic that has sub-issues is listed in no group" {
  issue 30 "Epic itself" --subs 1/2
  issue 31 "Its child" --parent 30:1/2
  run bash "${target}"
  expect "${status}" 0
  expect "$(field '[.owner[], .next[], .blocked[] | .number]')" '[31]'
}

@test "an Issue assigned only to someone else is left out of next" {
  issue 50 "Someone else's" --assignee other
  issue 51 "Shared" --assignee other --assignee me
  run bash "${target}"
  expect "${status}" 0
  expect "$(field '[.next[].number]')" '[51]'
}

@test "a pull request with green or no checks waits on the owner, ready ones first, and its Issue leaves next" {
  issue 60 "Work with a draft PR"
  issue 61 "Work with a ready PR"
  pr 70 "Draft PR" feat/issue-60 SUCCESS --draft --closes 60
  pr 71 "Ready PR" feat/issue-61 none --closes 61
  pr 72 "Dependency bump" deps/x SUCCESS --review APPROVED
  run bash "${target}"
  expect "${status}" 0
  expect "$(field '[.owner[] | {number, isDraft, checks, issues}]')" \
    '[{"number":71,"isDraft":false,"checks":null,"issues":[{"number":61,"title":"Work with a ready PR"}]},{"number":72,"isDraft":false,"checks":"SUCCESS","issues":[]},{"number":70,"isDraft":true,"checks":"SUCCESS","issues":[{"number":60,"title":"Work with a draft PR"}]}]'
  expect "$(field '.next')" '[]'
}

@test "a pull request with changes requested does not wait on the owner, and its Issue stays in progress under next" {
  issue 62 "Work with requested changes"
  pr 73 "Needs fixes" feat/issue-62 SUCCESS --review CHANGES_REQUESTED --closes 62
  run bash "${target}"
  expect "${status}" 0
  expect "$(field '.owner')" '[]'
  expect "$(field '[.next[] | {number, inProgress, pr: .pr.number}]')" '[{"number":62,"inProgress":true,"pr":73}]'
}

@test "a pull request with failing checks puts its Issue in progress under next with the checks state" {
  issue 63 "Plain"
  issue 64 "Work with a red PR"
  pr 74 "Red PR" feat/issue-64 FAILURE --closes 64
  run bash "${target}"
  expect "${status}" 0
  expect "$(field '.owner')" '[]'
  expect "$(field '[.next[] | {number, inProgress, checks: .pr.checks}]')" '[{"number":64,"inProgress":true,"checks":"FAILURE"},{"number":63,"inProgress":false,"checks":null}]'
}

@test "a pull request with pending checks that closes no Issue is listed under next as a pull request in progress" {
  pr 75 "Unlinked PR" fix/x PENDING
  run bash "${target}"
  expect "${status}" 0
  expect "$(field '[.next[] | {kind, number, inProgress, checks: .pr.checks}]')" '[{"kind":"pr","number":75,"inProgress":true,"checks":"PENDING"}]'
}

@test "a worktree with uncommitted changes on an Issue branch is attached to that Issue as dirty" {
  issue 80 "Local work"
  worktree_on fix/issue-80-local "${BATS_TEST_TMPDIR}/wt80"
  touch "${BATS_TEST_TMPDIR}/wt80/new-file"
  run bash "${target}"
  expect "${status}" 0
  expect "$(field '.next[0].worktrees')" "[{\"path\":\"$(canonical "${BATS_TEST_TMPDIR}/wt80")\",\"branch\":\"fix/issue-80-local\",\"dirty\":true}]"
  expect "$(field '.local')" '[]'
}

@test "a worktree on a pull request's head branch is attached to that pull request" {
  pr 76 "Ready PR" chore/tidy SUCCESS
  worktree_on chore/tidy "${BATS_TEST_TMPDIR}/wt76"
  run bash "${target}"
  expect "${status}" 0
  expect "$(field '.owner[0].worktrees')" "[{\"path\":\"$(canonical "${BATS_TEST_TMPDIR}/wt76")\",\"branch\":\"chore/tidy\",\"dirty\":false}]"
}

@test "a dirty worktree that matches no open Issue or pull request is listed as local state, and a clean one is not" {
  worktree_on feat/issue-90-gone "${BATS_TEST_TMPDIR}/dirty"
  worktree_on feat/clean "${BATS_TEST_TMPDIR}/clean"
  echo change >"${BATS_TEST_TMPDIR}/dirty/file"
  run bash "${target}"
  expect "${status}" 0
  expect "$(field '.local')" "[{\"path\":\"$(canonical "${BATS_TEST_TMPDIR}/dirty")\",\"branch\":\"feat/issue-90-gone\",\"dirty\":true}]"
}

@test "the limit cuts next and blocked and reports how many each group holds" {
  issue 1 "A"
  issue 2 "B"
  issue 3 "C"
  issue 4 "D"
  issue 5 "E" --blocked-by 1:OPEN
  issue 6 "F" --blocked-by 1:OPEN
  run bash "${target}" --limit 2
  expect "${status}" 0
  expect "$(field '[.next[].number]')" '[1,2]'
  expect "$(field '.nextTotal')" 4
  expect "$(field '[.blocked[].number]')" '[5,6]'
  expect "$(field '.blockedTotal')" 2
}

@test "without a limit, next holds the first three items" {
  issue 1 "A"
  issue 2 "B"
  issue 3 "C"
  issue 4 "D"
  run bash "${target}"
  expect "${status}" 0
  expect "$(field '[.next[].number]')" '[1,2,3]'
}

@test "an item carries its title, URL, and body so it can be explained without opening GitHub" {
  issue 7 "Explainable"
  run bash "${target}"
  expect "${status}" 0
  expect "$(field '.next[0] | {kind, title, url, body}')" '{"kind":"issue","title":"Explainable","url":"https://github.com/o/r/issues/7","body":"Body of Explainable"}'
  expect "$(field '.repo')" o/r
}

@test "a GitHub read that fails exits 1" {
  printf '#!/usr/bin/env bash\nexit 1\n' >"${BATS_TEST_TMPDIR}/bin/gh"
  run bash "${target}"
  expect "${status}" 1
}

@test "an origin that is not on GitHub exits 2" {
  git -C "${repo}" remote set-url origin https://example.invalid/o/r.git
  run bash "${target}"
  expect "${status}" 2
}

@test "an invalid limit exits 2" {
  run bash "${target}" --limit 0
  expect "${status}" 2
}
