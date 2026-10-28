#!/usr/bin/env bats
# Tests for `oe ready`. A stub gh answers every read from fixture files, applying --jq with jq as
# the real gh applies its built-in jq. Each test writes every fixture its outcome depends on.
# shellcheck disable=SC2292 # bats fails a test on a mid-test `[[ ]]` only under bash 4.1+; `[ ]` works on every bash.

# 2027-01-15T08:00:00Z, the fixed current time every test runs at.
NOW=1800000000
HOUR_AGO="2027-01-15T07:00:00Z"
FIVE_MINUTES_AGO="2027-01-15T07:55:00Z"
DEFAULT_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
PR_SHA=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

# jq helpers for the fixture edits below.
# shellcheck disable=SC2016 # jq program, not shell expansion.
DEFS='
def rollup($checks): if $checks == null then null else {contexts: {totalCount: ($checks | length), nodes: $checks}} end;
def passed($name): {__typename: "CheckRun", name: $name, status: "COMPLETED", conclusion: "SUCCESS",
  startedAt: "2027-01-15T07:20:00Z", checkSuite: {databaseId: 1}};
def failed($name): passed($name) | .conclusion = "FAILURE";
def running($name): passed($name) | .status = "IN_PROGRESS" | .conclusion = null;
def status($context; $state): {__typename: "StatusContext", context: $context, state: $state, createdAt: "2027-01-15T07:20:00Z"};
def comment($assoc; $body; $at): {authorAssociation: $assoc, body: $body, createdAt: $at};
def comments($c): .issue.comments = {totalCount: ($c | length), nodes: $c};
def blockers($b): .issue.blockedBy = {totalCount: ($b | length), nodes: $b};
def blocker($n; $state; $reason): {number: $n, state: $state, stateReason: $reason};
def branch: .ref = {name: "feat/issue-\(.issue.number)"};
def closed: .issue.state = "CLOSED" | .issue.stateReason = "COMPLETED";
def pr($number; $state; $created; $sha; $checks): {number: $number, state: $state, createdAt: $created,
  mergedAt: (if $state == "MERGED" then "2027-01-15T07:40:00Z" else null end), isCrossRepository: false,
  headRefOid: $sha, mergeable: "MERGEABLE", reviews: {totalCount: 0, nodes: []}, reviewThreads: {nodes: []},
  commits: {nodes: [{commit: {oid: $sha, committedDate: $created, statusCheckRollup: rollup($checks)}}]}};
def prs($p): .pullRequests.nodes = $p;
'

setup() {
  bats_require_minimum_version 1.5.0
  oe="${BATS_TEST_DIRNAME}/oe"
  export OE_FIXTURES="${BATS_TEST_TMPDIR}/fixtures"
  mkdir -p "${OE_FIXTURES}" "${BATS_TEST_TMPDIR}/bin"
  cat >"${BATS_TEST_TMPDIR}/bin/gh" <<'STUB'
#!/usr/bin/env bash
# Answers oe's reads from $OE_FIXTURES. A call whose arguments contain $GH_FAIL fails.
args="$*"
if [[ -n "${GH_FAIL:-}" && "${args}" == *"${GH_FAIL}"* ]]; then
  echo "gh: HTTP 502" >&2
  exit 1
fi
prog="" path="" query="" num=""
while [[ $# -gt 0 ]]; do
  case "$1" in
  api) path="$2" && shift ;;
  --jq) prog="$2" && shift ;;
  -f | -F)
    case "$2" in
    query=*) query="${2#query=}" ;;
    num=*) num="${2#num=}" ;;
    esac
    shift
    ;;
  esac
  shift
done
case "${path}" in
graphql)
  if [[ "${query}" == *subIssues* ]]; then file=gate.json; else file="issue-${num}.json"; fi
  ;;
*/pulls\?*) file=pulls.json ;;
*/statuses*)
  sha="${path#*/commits/}"
  file="statuses-${sha%%/*}.json"
  ;;
*/activity\?*)
  ref="${path#*ref=refs/heads/}"
  ref="${ref%%&*}"
  file="activity-${ref//\//_}.json"
  ;;
*)
  echo "stub: unexpected gh call: ${args}" >&2
  exit 99
  ;;
esac
if [[ ! -f "${OE_FIXTURES}/${file}" ]]; then
  [[ "${path}" != graphql ]] || { echo "stub: no fixture ${file}" >&2 && exit 98; }
  printf '[]' | jq -r "${prog:-.}"
  exit
fi
jq -r "${prog:-.}" "${OE_FIXTURES}/${file}"
STUB
  chmod +x "${BATS_TEST_TMPDIR}/bin/gh"
  export PATH="${BATS_TEST_TMPDIR}/bin:${PATH}"
  export OE_NOW="${NOW}"
}

# Writes the Epic read: $1 is a jq expression for the default-branch head's checks, or null for
# none; the rest are the child Issue numbers.
gate() {
  local checks="$1"
  shift
  jq -n --arg sha "${DEFAULT_SHA}" --arg at "${HOUR_AGO}" "${DEFS}"' ($ARGS.positional | map(tonumber)) as $n
    | {data: {repository: {nameWithOwner: "o/r",
        defaultBranchRef: {name: "main", target: {oid: $sha, committedDate: $at, statusCheckRollup: rollup('"${checks}"')}},
        issue: {subIssues: {totalCount: ($n | length), nodes: ($n | map({number: ., repository: {nameWithOwner: "o/r"}}))}}}}}' \
    --args "$@" >"${OE_FIXTURES}/gate.json"
}

# Writes Issue $1's read: an open Issue with no dependencies, comments, branch, or PR, edited by
# the jq expression $2 applied to .data.repository.
issue() {
  jq -n --argjson n "$1" "${DEFS}"'{data: {repository: {
      issue: {number: $n, state: "OPEN", stateReason: null, blockedBy: {totalCount: 0, nodes: []},
        comments: {totalCount: 0, nodes: []}},
      ref: null, pullRequests: {nodes: []}}}}
    | .data.repository |= ('"${2:-.}"')' >"${OE_FIXTURES}/issue-$1.json"
}

# Lists an open PR from feat/issue-$1 at head $2 in the REST pull list.
listed_pr() {
  jq -n --arg ref "feat/issue-$1" --arg sha "$2" \
    '[{head: {ref: $ref, sha: $sha, repo: {full_name: "o/r"}}}]' >"${OE_FIXTURES}/pulls.json"
}

# Records a push of $2 to branch $1 at time $3.
pushed() {
  jq -n --arg sha "$2" --arg at "$3" '[{after: $sha, timestamp: $at}]' >"${OE_FIXTURES}/activity-${1//\//_}.json"
}

# Writes the commit statuses on $1, newest first, as REST returns them: each later argument is
# context:state.
statuses() {
  local sha="$1"
  shift
  jq -n '$ARGS.positional | map(split(":") | {context: .[0], state: .[1]})' \
    --args "$@" >"${OE_FIXTURES}/statuses-${sha}.json"
}

# Prints the action oe ready gave Issue $1.
action_of() {
  printf '%s\n' "${lines[@]}" | while IFS=$'\t' read -r n action _; do
    if [ "${n}" = "$1" ]; then
      echo "${action}"
    fi
  done
}

# An Issue whose PR passed CI and has no verdict yet; a starting point for reads that must fail.
green_pr_without_verdict() {
  gate '[passed("test")]' 5
  issue 5 'branch | comments([comment("OWNER"; "<!-- oe:claim -->"; "2027-01-15T07:00:00Z"),
    comment("OWNER"; "<!-- oe:attempt -->"; "2027-01-15T07:01:00Z")])
    | prs([pr(50; "OPEN"; "2027-01-15T07:10:00Z"; "'"${PR_SHA}"'"; [passed("test")])])'
  listed_pr 5 "${PR_SHA}"
  pushed feat/issue-5 "${PR_SHA}" "2027-01-15T07:10:00Z"
}

@test "default head with no checks ten minutes after its push ends the session with a reason" {
  gate null 5
  issue 5
  pushed main "${DEFAULT_SHA}" "${HOUR_AGO}"

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 3 ]
  [ "${#lines[@]}" -eq 1 ]
  case "${lines[0]}" in
  end$'\t'*"no checks"*) ;;
  *) return 1 ;;
  esac
}

@test "default head with no checks for under ten minutes since its push makes every Issue wait" {
  gate null 5 6
  issue 5
  issue 6
  pushed main "${DEFAULT_SHA}" "${FIVE_MINUTES_AGO}"

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = wait-base ]
  [ "$(action_of 6)" = wait-base ]
}

@test "a failing check on the default head makes no Issue ready" {
  gate '[passed("lint"), failed("test")]' 5
  issue 5

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = wait-base ]
}

@test "a pending check on the default head makes no Issue ready" {
  gate '[running("test")]' 5
  issue 5

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = wait-base ]
}

@test "the oe/verify status on the default head is not counted as a check" {
  gate '[status("oe/verify"; "SUCCESS")]' 5
  issue 5
  pushed main "${DEFAULT_SHA}" "${HOUR_AGO}"

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 3 ]
}

@test "an Issue with no branch and every dependency completed is claimed" {
  gate '[passed("test")]' 5
  issue 5 'blockers([blocker(3; "CLOSED"; "COMPLETED")])'

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [ "$(action_of 5)" = claim ]
}

@test "a failed gh read exits non-zero and prints nothing" {
  green_pr_without_verdict
  run bash "${oe}" ready o/r 1
  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = start-verifier ]

  for call in subIssues "num=5" /pulls /statuses /activity; do
    GH_FAIL="${call}" run --separate-stderr bash "${oe}" ready o/r 1

    [ "${status}" -ne 0 ]
    [ "${status}" -ne 3 ]
    [ -z "${output}" ]
  done
}

@test "a closed Issue is done" {
  gate '[passed("test")]' 5
  issue 5 'closed'

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = "done" ]
}

@test "an Issue with an open dependency is not ready" {
  gate '[passed("test")]' 5
  issue 5 'blockers([blocker(3; "CLOSED"; "COMPLETED"), blocker(4; "OPEN"; null)])'

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = wait-dependencies ]
}

@test "an Issue whose dependency closed as not planned waits instead of being claimed" {
  gate '[passed("test")]' 5
  issue 5 'blockers([blocker(4; "CLOSED"; "NOT_PLANNED")])'

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = wait-dependencies ]
}

@test "an Issue whose branch exists without a PR is not ready and gets an Owner" {
  gate '[passed("test")]' 5
  issue 5 'branch | comments([comment("OWNER"; "<!-- oe:claim -->"; "2027-01-15T07:00:00Z")])'

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = start-owner ]
}

@test "an open Issue whose PR merged after the latest claim waits for an engineer" {
  gate '[passed("test")]' 5
  issue 5 'comments([comment("OWNER"; "<!-- oe:claim -->"; "2027-01-15T07:00:00Z")])
    | prs([pr(50; "MERGED"; "2027-01-15T07:10:00Z"; "'"${PR_SHA}"'"; [passed("test")])])'

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = wait-engineer ]
}

@test "a PR merged before the latest claim does not hold a restarted Issue" {
  gate '[passed("test")]' 5
  issue 5 'comments([comment("OWNER"; "<!-- oe:claim -->"; "2027-01-15T07:50:00Z")])
    | prs([pr(50; "MERGED"; "2027-01-15T07:10:00Z"; "'"${PR_SHA}"'"; [passed("test")])])'

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = claim ]
}

@test "an Issue whose branch exists and whose PR closed without merging waits for an engineer" {
  gate '[passed("test")]' 5
  issue 5 'branch | comments([comment("OWNER"; "<!-- oe:claim -->"; "2027-01-15T07:00:00Z")])
    | prs([pr(50; "CLOSED"; "2027-01-15T07:10:00Z"; "'"${PR_SHA}"'"; [passed("test")])])'

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = wait-engineer ]
}

@test "a PR from a fork with the Issue's branch name is ignored" {
  gate '[passed("test")]' 5
  issue 5 'prs([pr(50; "MERGED"; "2027-01-15T07:10:00Z"; "'"${PR_SHA}"'"; [passed("test")]) | .isCrossRepository = true])'

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = claim ]
}

@test "an Issue with an agent running in this session is left out and the rest come in number order" {
  gate '[passed("test")]' 7 5 6
  issue 5
  issue 6
  issue 7

  run bash "${oe}" ready o/r 1 --running 6

  [ "${status}" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[0]%%$'\t'*}" = 5 ]
  [ "${lines[1]%%$'\t'*}" = 7 ]
}
