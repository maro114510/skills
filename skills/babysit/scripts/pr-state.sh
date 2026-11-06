#!/usr/bin/env bash
# Prints one pull request as normalized JSON from GitHub GraphQL, paginated so nothing is truncated.
# It keeps no state and judges nothing; evaluate.jq does that.
# Usage: pr-state.sh <owner/repo> <pr>
#        pr-state.sh --normalize <file|->   normalize one saved, complete response of the same query
# Output fields: repo, number, url, state, isDraft, author, viewer, isCrossRepository, baseRef,
# headRef, head, mergeable, mergeStateStatus, reviewDecision, checks, reviewRequests, latestReviews,
# threads, reviews, comments. Each comment carries id, author, authorAssociation, body, bodyHash,
# createdAt, url, and isMinimized. Each check is the latest run of its key.
# Exit: 0 printed, 1 GitHub could not be read completely, 2 usage error.
set -uo pipefail

# Pages a connection holds; GitHub's maximum.
PAGE=100
# A guard against a cursor that never ends.
MAX_PAGES=50

usage() {
  echo "$1" >&2
  echo "Usage: pr-state.sh <owner/repo> <pr> | --normalize <file|->" >&2
  exit 2
}

fail() {
  echo "pr-state: $1" >&2
  exit 1
}

COMMENT_FIELDS='id body createdAt url isMinimized authorAssociation author { login }'

# One query shape for every page. Each connection is fetched only while its @include flag is true,
# so later pages carry just the connections that still have a next page.
# shellcheck disable=SC2016 # GraphQL variables, not shell expansion.
QUERY='query($owner: String!, $repo: String!, $num: Int!,
  $wThreads: Boolean!, $cThreads: String, $wReviews: Boolean!, $cReviews: String,
  $wComments: Boolean!, $cComments: String, $wRequests: Boolean!, $cRequests: String,
  $wLatest: Boolean!, $cLatest: String, $wChecks: Boolean!, $cChecks: String) {
  viewer { login }
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $num) {
      number url state isDraft isCrossRepository mergeable mergeStateStatus reviewDecision
      baseRefName headRefName headRefOid author { login }
      reviewThreads(first: '"${PAGE}"', after: $cThreads) @include(if: $wThreads) {
        totalCount pageInfo { hasNextPage endCursor }
        nodes { id isResolved isOutdated path line
          comments(first: '"${PAGE}"') { totalCount pageInfo { hasNextPage endCursor } nodes { '"${COMMENT_FIELDS}"' } } } }
      reviews(first: '"${PAGE}"', after: $cReviews) @include(if: $wReviews) {
        totalCount pageInfo { hasNextPage endCursor } nodes { state '"${COMMENT_FIELDS}"' } }
      comments(first: '"${PAGE}"', after: $cComments) @include(if: $wComments) {
        totalCount pageInfo { hasNextPage endCursor } nodes { '"${COMMENT_FIELDS}"' } }
      reviewRequests(first: '"${PAGE}"', after: $cRequests) @include(if: $wRequests) {
        totalCount pageInfo { hasNextPage endCursor }
        nodes { requestedReviewer { __typename
          ... on User { login } ... on Team { slug } ... on Bot { login } ... on Mannequin { login } } } }
      latestOpinionatedReviews(first: '"${PAGE}"', after: $cLatest) @include(if: $wLatest) {
        totalCount pageInfo { hasNextPage endCursor } nodes { state author { login } } }
      commits(last: 1) @include(if: $wChecks) { nodes { commit { oid statusCheckRollup {
        contexts(first: '"${PAGE}"', after: $cChecks) { totalCount pageInfo { hasNextPage endCursor } nodes { __typename
          ... on CheckRun { databaseId name status conclusion startedAt detailsUrl
            checkSuite { app { slug } workflowRun { databaseId runAttempt event file { path } workflow { name } } } }
          ... on StatusContext { context state createdAt targetUrl } } } } } } }
    }
  }
}'

# shellcheck disable=SC2016 # GraphQL variables, not shell expansion.
THREAD_QUERY='query($id: ID!, $cursor: String) {
  node(id: $id) { ... on PullRequestReviewThread {
    comments(first: '"${PAGE}"', after: $cursor) { totalCount pageInfo { hasNextPage endCursor } nodes { '"${COMMENT_FIELDS}"' } } } }
}'

# Connection name to the suffix of its @include flag and cursor variables.
CONNECTIONS='reviewThreads:Threads reviews:Reviews comments:Comments reviewRequests:Requests latestOpinionatedReviews:Latest checks:Checks'

# Flattens one response page to {viewer, pr, conns, checksCommit}. A head without a check rollup
# has an empty checks connection.
# shellcheck disable=SC2016 # jq program, not shell expansion.
FLATTEN='
  if (.errors // null) != null then error("GraphQL errors: \([.errors[]?.message] | join(", "))") else . end
  | .data.repository.pullRequest as $p
  | if ($p | type) != "object" then error("pull request not found") else . end
  | { viewer: .data.viewer.login,
      pr: ($p | del(.reviewThreads, .reviews, .comments, .reviewRequests, .latestOpinionatedReviews, .commits)),
      checksCommit: (if $p | has("commits") then $p.commits.nodes[0].commit.oid else null end),
      conns: ({ reviewThreads: $p.reviewThreads, reviews: $p.reviews, comments: $p.comments,
                reviewRequests: $p.reviewRequests, latestOpinionatedReviews: $p.latestOpinionatedReviews,
                checks: (if $p | has("commits")
                  then ($p.commits.nodes[0].commit.statusCheckRollup.contexts
                    // {totalCount: 0, pageInfo: {hasNextPage: false, endCursor: null}, nodes: []})
                  else null end) }
              | with_entries(select(.value != null))) }'

# Fails unless every connection, and every thread comment list, has no next page. hasNextPage, not
# totalCount, decides, because totalCount can count nodes the viewer cannot see, which would fail every poll.
# shellcheck disable=SC2016 # jq program, not shell expansion.
COMPLETE='
  def whole($name): if (. | type) != "object" or (.nodes | type) != "array" or (.pageInfo.hasNextPage | type) != "boolean"
    then "\($name) missing"
    elif .pageInfo.hasNextPage then "\($name) truncated"
    else empty end;
  . as $in
  | [ (("reviewThreads", "reviews", "comments", "reviewRequests", "latestOpinionatedReviews", "checks") as $c
      | .conns[$c] | whole($c)),
    (.conns.reviewThreads.nodes[]? | .comments | whole("thread comments")),
    (if .checksCommit != null and .checksCommit != .pr.headRefOid then "head moved while reading" else empty end),
    (if (.pr.headRefOid | type) != "string" then "head missing" else empty end)
  ] | if length > 0 then error(join(", ")) else $in end'

# Turns a complete flattened response into the output shape. The check key is stable across heads,
# so repair counts can follow one check from head to head; a re-run keeps its key, and only the
# latest run of a key counts. A run not started yet has no timestamp and counts as the latest.
# shellcheck disable=SC2016 # jq program, not shell expansion.
NORMALIZE='
  def comment: {id, author: (.author.login // null), authorAssociation, body: (.body // ""), createdAt, url,
    isMinimized: (.isMinimized == true)};
  def check_class:
    if .__typename == "CheckRun" then
      if (.status | type) != "string" then "unreadable"
      elif .status != "COMPLETED" then "pending"
      elif .conclusion == "SUCCESS" or .conclusion == "NEUTRAL" or .conclusion == "SKIPPED" then "pass"
      elif .conclusion == "ACTION_REQUIRED" then "action"
      elif (.conclusion | type) == "string" then "failed"
      else "unreadable" end
    elif .__typename == "StatusContext" then
      if .state == "SUCCESS" then "pass"
      elif .state == "PENDING" or .state == "EXPECTED" then "pending"
      elif (.state | type) == "string" then "failed"
      else "unreadable" end
    else "unreadable" end;
  def check:
    if .__typename == "StatusContext" then
      {key: "status/\(.context)", name: .context, workflow: null, kind: "status", rerunnable: false,
       status: check_class, runId: null, workflowRunId: null, attempt: null, url: .targetUrl, startedAt: .createdAt}
    else
      (.checkSuite.workflowRun // null) as $run
      | {key: "\(.checkSuite.app.slug // "app")/\($run.file.path // $run.workflow.name // "-")/\($run.event // "-")/\(.name)",
         name, workflow: ($run.workflow.name // null), kind: "check_run",
         rerunnable: (.checkSuite.app.slug == "github-actions" and $run != null),
         status: check_class, runId: .databaseId, workflowRunId: ($run.databaseId // null),
         attempt: ($run.runAttempt // null), url: .detailsUrl, startedAt}
    end;
  .pr as $p
  | { repo: ($p.url | capture("github\\.com/(?<r>[^/]+/[^/]+)/pull/").r? // null),
      number: $p.number, url: $p.url, state: $p.state, isDraft: $p.isDraft,
      author: ($p.author.login // null), viewer: .viewer, isCrossRepository: $p.isCrossRepository,
      baseRef: $p.baseRefName, headRef: $p.headRefName, head: $p.headRefOid,
      mergeable: $p.mergeable, mergeStateStatus: $p.mergeStateStatus, reviewDecision: $p.reviewDecision,
      checks: ([.conns.checks.nodes[] | check] | group_by(.key)
        | map(sort_by([.startedAt == null, .startedAt // "", .runId // 0]) | last)),
      reviewRequests: [.conns.reviewRequests.nodes[] | .requestedReviewer
        | {reviewer: (.login // .slug // null), type: .__typename}],
      latestReviews: [.conns.latestOpinionatedReviews.nodes[] | {author: (.author.login // null), state}],
      threads: [.conns.reviewThreads.nodes[] | {id, isResolved, isOutdated, path, line,
        comments: [.comments.nodes[] | comment]}],
      reviews: [.conns.reviews.nodes[] | comment + {state}],
      comments: [.conns.comments.nodes[] | comment] }'

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | cut -d' ' -f1
  else
    shasum -a 256 | cut -d' ' -f1
  fi
}

# Adds bodyHash to every comment of the normalized JSON on stdin. The hash covers the base64 of the
# body, which changes exactly when the body does.
add_hashes() {
  local normalized pairs id b64 hashes
  normalized="$(cat)"
  pairs="$(jq -r '[.comments[], .reviews[], .threads[].comments[]] | .[] | "\(.id)\t\(.body | @base64)"' \
    <<<"${normalized}")" || return 1
  hashes="$(while IFS=$'\t' read -r id b64; do
    [[ -n "${id}" ]] || continue
    printf '%s\t%s\n' "${id}" "$(printf '%s' "${b64}" | sha256)"
  done <<<"${pairs}" | jq -Rn '[inputs | split("\t") | {(.[0]): .[1]}] | add // {}')" || return 1
  jq -c --argjson h "${hashes}" '
    def hashed: . + {bodyHash: $h[.id]};
    .comments |= map(hashed) | .reviews |= map(hashed) | .threads |= map(.comments |= map(hashed))' \
    <<<"${normalized}"
}

finish() {
  local out
  out="$(jq -c "${COMPLETE} | ${NORMALIZE}" <<<"$1" 2>&1)" || fail "${out}"
  add_hashes <<<"${out}" || fail "cannot hash comment bodies"
}

command -v jq >/dev/null 2>&1 || usage "jq is required"

if [[ "${1:-}" == --normalize ]]; then
  [[ $# -eq 2 ]] || usage "--normalize needs exactly one file or -"
  if [[ "$2" == - ]]; then
    raw="$(cat)"
  else
    [[ -r "$2" ]] || usage "Cannot read response: $2"
    raw="$(cat "$2")"
  fi
  flat="$(jq -c "${FLATTEN}" <<<"${raw}" 2>&1)" || fail "${flat}"
  finish "${flat}"
  exit 0
fi

[[ $# -eq 2 ]] || usage "Expected <owner/repo> <pr-number>"
[[ "$1" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || usage "Invalid repository: $1"
[[ "$2" =~ ^[1-9][0-9]*$ ]] || usage "Invalid pull request number: $2"
command -v gh >/dev/null 2>&1 || fail "gh is required"
owner="${1%/*}"
name="${1#*/}"
num="$2"
err="$(mktemp)" || fail "mktemp failed"
trap 'rm -f "${err}"' EXIT

# Prints one flattened page. $1 is a JSON object of connection name to cursor; a connection absent
# from it is skipped, and a null cursor starts from its first page.
page() {
  local want="$1" args=() pair conn suffix cursor raw flat
  args=(-f query="${QUERY}" -f owner="${owner}" -f repo="${name}" -F num="${num}")
  for pair in ${CONNECTIONS}; do
    conn="${pair%%:*}"
    suffix="${pair#*:}"
    if jq -e --arg c "${conn}" 'has($c)' <<<"${want}" >/dev/null; then
      args+=(-F "w${suffix}=true")
      cursor="$(jq -r --arg c "${conn}" '.[$c] // ""' <<<"${want}")"
      [[ -z "${cursor}" ]] || args+=(-f "c${suffix}=${cursor}")
    else
      args+=(-F "w${suffix}=false")
    fi
  done
  raw="$(gh api graphql "${args[@]}" 2>"${err}" </dev/null)" || fail "gh api graphql failed: $(head -n1 "${err}")"
  flat="$(jq -c "${FLATTEN}" <<<"${raw}" 2>&1)" || fail "unexpected response: ${flat}"
  printf '%s\n' "${flat}"
}

acc="$(page '{"reviewThreads":null,"reviews":null,"comments":null,"reviewRequests":null,"latestOpinionatedReviews":null,"checks":null}')" ||
  exit 1
for ((i = 1; i < MAX_PAGES; i++)); do
  want="$(jq -c '[.conns | to_entries[] | select(.value.pageInfo.hasNextPage == true)
    | {(.key): .value.pageInfo.endCursor}] | add // {}' <<<"${acc}")"
  [[ "${want}" != '{}' ]] || break
  next="$(page "${want}")" || exit 1
  # Pages go through stdin, because a page of comment bodies can outgrow the argument size limit.
  acc="$(printf '%s\n%s\n' "${acc}" "${next}" | jq -sc '
    .[1] as $n | .[0]
    | if $n.pr.headRefOid != .pr.headRefOid then error("head moved while reading") else . end
    | reduce ($n.conns | to_entries[]) as $e (.;
        .conns[$e.key].nodes += $e.value.nodes
        | .conns[$e.key].pageInfo = $e.value.pageInfo
        | .conns[$e.key].totalCount = $e.value.totalCount)' 2>&1)" || fail "${acc}"
done

# Thread comments past the first page come from the thread node itself.
threads="$(jq -r '.conns.reviewThreads.nodes[]? | select(.comments.pageInfo.hasNextPage == true)
  | "\(.id)\t\(.comments.pageInfo.endCursor)"' <<<"${acc}")"
while IFS=$'\t' read -r thread cursor; do
  [[ -n "${thread}" ]] || continue
  for ((i = 0; i < MAX_PAGES; i++)); do
    raw="$(gh api graphql -f query="${THREAD_QUERY}" -f id="${thread}" -f cursor="${cursor}" 2>"${err}" </dev/null)" ||
      fail "gh api graphql failed: $(head -n1 "${err}")"
    acc="$(printf '%s\n%s\n' "${acc}" "${raw}" | jq -sc --arg id "${thread}" '
      (.[1].data.node.comments // error("thread comments missing")) as $c
      | .[0] | .conns.reviewThreads.nodes |= map(if .id == $id
          then .comments.nodes += $c.nodes | .comments.pageInfo = $c.pageInfo | .comments.totalCount = $c.totalCount
          else . end)' 2>&1)" || fail "${acc}"
    cursor="$(jq -r 'if .data.node.comments.pageInfo.hasNextPage then .data.node.comments.pageInfo.endCursor else "" end' \
      <<<"${raw}")"
    [[ -n "${cursor}" ]] || break
  done
done <<<"${threads}"

finish "${acc}"
