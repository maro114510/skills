#!/usr/bin/env bats
# Tests for pr-state.sh. Normalization reads one edited raw GraphQL response through --normalize;
# pagination runs against a stub gh on PATH, so no test calls GitHub.
# shellcheck disable=SC2292 # bats fails a test on a mid-test `[[ ]]` only under bash 4.1+; `[ ]` works on every bash.

setup() {
  target="${BATS_TEST_DIRNAME}/pr-state.sh"
  conn='{"totalCount":0,"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}'
  raw="$(jq -nc --argjson empty "${conn}" '
    def page($nodes): {totalCount: ($nodes | length), pageInfo: {hasNextPage: false, endCursor: "end"}, nodes: $nodes};
    def c($id; $body; $who): {id: $id, body: $body, createdAt: "2026-01-01T00:00:00Z", url: "u/\($id)",
      isMinimized: false, authorAssociation: "MEMBER", author: {login: $who}};
    def run($id; $conclusion; $started; $attempt): {__typename: "CheckRun", databaseId: $id, name: "test",
      status: "COMPLETED", conclusion: $conclusion, startedAt: $started, detailsUrl: "d/\($id)",
      checkSuite: {app: {slug: "github-actions"}, workflowRun: {databaseId: 10, runAttempt: $attempt,
        event: "pull_request", file: {path: ".github/workflows/ci.yml"}, workflow: {name: "CI"}}}};
    {data: {viewer: {login: "me"}, repository: {pullRequest: {
      number: 7, url: "https://github.com/o/r/pull/7", state: "OPEN", isDraft: false, isCrossRepository: false,
      mergeable: "MERGEABLE", mergeStateStatus: "CLEAN", reviewDecision: "APPROVED",
      baseRefName: "main", headRefName: "feat/x", headRefOid: "aaa", author: {login: "me"},
      reviewThreads: page([{id: "T1", isResolved: false, isOutdated: false, path: "a.sh", line: 3,
        comments: page([c("TC1"; "fix this"; "bob")])}]),
      reviews: page([c("R1"; ""; "bob") + {state: "APPROVED"}]),
      comments: page([c("IC1"; "please rename"; "carol")]),
      reviewRequests: page([{requestedReviewer: {__typename: "User", login: "dave"}},
        {requestedReviewer: {__typename: "Team", slug: "core"}}]),
      latestOpinionatedReviews: page([{state: "APPROVED", author: {login: "bob"}}]),
      commits: {nodes: [{commit: {oid: "aaa", statusCheckRollup: {contexts: page([
        run(100; "FAILURE"; "2026-01-01T00:00:00Z"; 1),
        run(101; "SUCCESS"; "2026-01-01T01:00:00Z"; 2),
        {__typename: "StatusContext", context: "ci/ext", state: "FAILURE", createdAt: "2026-01-01T00:00:00Z", targetUrl: "t"}
      ])}}}]}}}}}')"
}

# Normalizes the raw response after the jq edit $1 to .data.repository.pullRequest.
normalize() {
  local edited
  edited="$(jq -c ".data.repository.pullRequest |= (${1:-.})" <<<"${raw}")"
  run bash "${target}" --normalize - <<<"${edited}"
}

field() {
  jq -r "$1" <<<"${output}"
}

expect() {
  if [ "$1" != "$2" ]; then
    echo "expected [$2], got [$1]; output: ${output}" >&2
    return 1
  fi
}

# Puts a gh on PATH that serves page1.json, page2.json for a comments cursor, and thread.json for a
# thread node, and logs each call's arguments.
stub_gh() {
  mkdir -p "${BATS_TEST_TMPDIR}/bin"
  cat >"${BATS_TEST_TMPDIR}/bin/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" | tr '\n' ' ' >>"${BATS_TEST_TMPDIR}/calls"
echo >>"${BATS_TEST_TMPDIR}/calls"
[ -e "${BATS_TEST_TMPDIR}/fail" ] && { echo "HTTP 502" >&2; exit 1; }
for a in "\$@"; do
  case "\$a" in
  cComments=*) cat "${BATS_TEST_TMPDIR}/page2.json"; exit 0 ;;
  id=*) cat "${BATS_TEST_TMPDIR}/thread.json"; exit 0 ;;
  esac
done
cat "${BATS_TEST_TMPDIR}/page1.json"
EOF
  chmod +x "${BATS_TEST_TMPDIR}/bin/gh"
  export PATH="${BATS_TEST_TMPDIR}/bin:${PATH}"
}

# Page 1 holds one of two issue comments and one of two comments in thread T1.
paged_fixtures() {
  jq -c '.data.repository.pullRequest
    |= (.comments |= (.totalCount = 2 | .pageInfo = {hasNextPage: true, endCursor: "c1"})
      | .reviewThreads.nodes[0].comments |= (.totalCount = 2 | .pageInfo = {hasNextPage: true, endCursor: "t1"}))' \
    <<<"${raw}" >"${BATS_TEST_TMPDIR}/page1.json"
  jq -c --arg head "${1:-aaa}" '.data.repository.pullRequest
    |= {number, url, state, isDraft, isCrossRepository, mergeable, mergeStateStatus, reviewDecision,
        baseRefName, headRefName, author, headRefOid: $head,
        comments: {totalCount: 2, pageInfo: {hasNextPage: false, endCursor: "c2"},
          nodes: [.comments.nodes[0] | .id = "IC2" | .body = "second"]}}' \
    <<<"${raw}" >"${BATS_TEST_TMPDIR}/page2.json"
  jq -c '{data: {node: {comments: {totalCount: 2, pageInfo: {hasNextPage: false, endCursor: "t2"},
    nodes: [.data.repository.pullRequest.reviewThreads.nodes[0].comments.nodes[0] | .id = "TC2"]}}}}' \
    <<<"${raw}" >"${BATS_TEST_TMPDIR}/thread.json"
}

@test "rejects bad arguments with exit 2" {
  run bash "${target}"
  [ "${status}" -eq 2 ]
  run bash "${target}" noslash 7
  [ "${status}" -eq 2 ]
  run bash "${target}" o/r 0
  [ "${status}" -eq 2 ]
  run bash "${target}" --normalize
  [ "${status}" -eq 2 ]
  run bash "${target}" --normalize "${BATS_TEST_TMPDIR}/missing.json"
  [ "${status}" -eq 2 ]
}

@test "normalizes the pull request, viewer, and review state" {
  normalize
  [ "${status}" -eq 0 ]
  expect "$(field .repo)" o/r
  expect "$(field .number)" 7
  expect "$(field .head)" aaa
  expect "$(field .viewer)" me
  expect "$(field .author)" me
  expect "$(field .isCrossRepository)" false
  expect "$(field .mergeable)" MERGEABLE
  expect "$(field '[.reviewRequests[].reviewer] | join(",")')" dave,core
  expect "$(field '.latestReviews[0].state')" APPROVED
  expect "$(field '.threads[0].comments[0].id')" TC1
  expect "$(field '.comments[0].authorAssociation')" MEMBER
  expect "$(field '.reviews[0].state')" APPROVED
}

@test "keeps only the latest run of each check, keyed stably across heads" {
  normalize
  expect "$(field '.checks | length')" 2
  expect "$(field '.checks[] | select(.kind == "check_run") | .key')" "github-actions/.github/workflows/ci.yml/pull_request/test"
  expect "$(field '.checks[] | select(.kind == "check_run") | "\(.status) \(.runId) \(.attempt) \(.rerunnable)"')" "pass 101 2 true"
  expect "$(field '.checks[] | select(.kind == "status") | "\(.key) \(.status) \(.rerunnable)"')" "status/ci/ext failed false"
}

@test "a queued re-run counts as the latest run" {
  normalize '.commits.nodes[0].commit.statusCheckRollup.contexts.nodes[1] |= (.status = "QUEUED" | .conclusion = null | .startedAt = null)'
  expect "$(field '.checks[] | select(.kind == "check_run") | .status')" pending
}

@test "a check outside GitHub Actions cannot be re-run" {
  normalize '.commits.nodes[0].commit.statusCheckRollup.contexts.nodes |= map(if .checkSuite then .checkSuite = {app: {slug: "circleci"}, workflowRun: null} else . end)'
  expect "$(field '[.checks[] | select(.kind == "check_run") | .rerunnable] | unique | join(",")')" false
}

@test "a head without a check rollup has no checks" {
  normalize '.commits.nodes[0].commit.statusCheckRollup = null'
  [ "${status}" -eq 0 ]
  expect "$(field '.checks | length')" 0
}

@test "every comment carries a body hash that follows its body" {
  normalize
  first="$(field '.comments[0].bodyHash')"
  [ "${#first}" -eq 64 ]
  expect "$(field '[.threads[].comments[], .reviews[]] | map(.bodyHash | length) | unique | join(",")')" 64
  normalize
  expect "$(field '.comments[0].bodyHash')" "${first}"
  normalize '.comments.nodes[0].body = "please rename it"'
  [ "$(field '.comments[0].bodyHash')" != "${first}" ]
}

@test "a truncated connection fails with exit 1" {
  normalize '.comments.pageInfo.hasNextPage = true'
  [ "${status}" -eq 1 ]
  normalize '.reviewThreads.nodes[0].comments.pageInfo.hasNextPage = true'
  [ "${status}" -eq 1 ]
  normalize 'del(.reviews)'
  [ "${status}" -eq 1 ]
}

@test "GraphQL errors and a missing pull request fail with exit 1" {
  run bash "${target}" --normalize - <<<'{"errors":[{"message":"boom"}]}'
  [ "${status}" -eq 1 ]
  run bash "${target}" --normalize - <<<'{"data":{"viewer":{"login":"me"},"repository":{"pullRequest":null}}}'
  [ "${status}" -eq 1 ]
}

@test "pages every truncated connection and thread until nothing is left" {
  stub_gh
  paged_fixtures
  run bash "${target}" o/r 7
  [ "${status}" -eq 0 ]
  expect "$(field '[.comments[].id] | join(",")')" IC1,IC2
  expect "$(field '[.threads[0].comments[].id] | join(",")')" TC1,TC2
  expect "$(wc -l <"${BATS_TEST_TMPDIR}/calls" | tr -d ' ')" 3
  # The second page asks only for the connection that had more.
  second="$(sed -n 2p "${BATS_TEST_TMPDIR}/calls")"
  case "${second}" in *"wComments=true"*"wThreads=false"* | *"wThreads=false"*"wComments=true"*) ;; *) false ;; esac
  case "${second}" in *"wChecks=false"*"cComments=c1"* | *"cComments=c1"*"wChecks=false"*) ;; *) false ;; esac
}

@test "a head that moves between pages fails with exit 1" {
  stub_gh
  paged_fixtures bbb
  run bash "${target}" o/r 7
  [ "${status}" -eq 1 ]
}

@test "a failing gh fails with exit 1" {
  stub_gh
  paged_fixtures
  touch "${BATS_TEST_TMPDIR}/fail"
  run bash "${target}" o/r 7
  [ "${status}" -eq 1 ]
}
