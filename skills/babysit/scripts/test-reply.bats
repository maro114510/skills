#!/usr/bin/env bats
# Tests for reply.sh. A stub gh answers like GitHub and logs every call, so no test calls GitHub.
# shellcheck disable=SC2292 # bats fails a test on a mid-test `[[ ]]` only under bash 4.1+; `[ ]` works on every bash.

setup() {
  scripts="${BATS_TEST_DIRNAME}"
  tmp="${BATS_TEST_TMPDIR}"
  token="tok-1"
  export BABYSIT_NOW=1000000
  git init -q "${tmp}/repo"
  cd "${tmp}/repo" || return 1
  # A stub gh that logs its arguments on one line, fails on demand, and applies --jq to a canned response.
  cat >"${tmp}/gh" <<EOF
#!/usr/bin/env bash
printf '%s ' "\$@" | tr '\n' ' ' >>"${tmp}/calls"
echo >>"${tmp}/calls"
[ -e "${tmp}/gh-fails" ] && { echo "HTTP 502" >&2; exit 1; }
n=\$(wc -l <"${tmp}/calls" | tr -d ' ')
expr=""
prev=""
for a in "\$@"; do
  [ "\$prev" = "--jq" ] && expr="\$a"
  prev="\$a"
done
case "\$*" in
*graphql*) resp="{\"data\":{\"addPullRequestReviewThreadReply\":{\"comment\":{\"id\":\"PRRC_\$n\"}}}}" ;;
*) resp="{\"id\":1,\"node_id\":\"IC_\$n\"}" ;;
esac
if [ -n "\$expr" ]; then jq -r "\$expr" <<<"\$resp"; else echo "\$resp"; fi
EOF
  chmod +x "${tmp}/gh"
  export BABYSIT_GH="${tmp}/gh"
  printf 'Fixed in abc1234.\nありがとう\n' >"${tmp}/body.md"
  bash "${scripts}/ledger.sh" start o/r 7 "${token}" >/dev/null
}

reply() {
  run bash "${scripts}/reply.sh" o/r 7 --session "${token}" --body-file "${tmp}/body.md" "$@"
}

calls() {
  if [ -e "${tmp}/calls" ]; then wc -l <"${tmp}/calls" | tr -d ' '; else echo 0; fi
}

ledger() {
  bash "${scripts}/ledger.sh" show o/r 7 | jq -r "$1"
}

expect() {
  if [ "$1" != "$2" ]; then
    echo "expected [$2], got [$1]; output: ${output}" >&2
    return 1
  fi
}

@test "rejects bad arguments with exit 2" {
  run bash "${scripts}/reply.sh"
  [ "${status}" -eq 2 ]
  reply
  [ "${status}" -eq 2 ]
  reply --thread T1 --conversation
  [ "${status}" -eq 2 ]
  reply --thread 'bad id'
  [ "${status}" -eq 2 ]
  : >"${tmp}/empty.md"
  run bash "${scripts}/reply.sh" o/r 7 --session "${token}" --thread T1 --body-file "${tmp}/empty.md"
  [ "${status}" -eq 2 ]
  run bash "${scripts}/reply.sh" o/r 7 --session "${token}" --thread T1 --body-file "${tmp}/missing.md"
  [ "${status}" -eq 2 ]
  expect "$(calls)" 0
  reply --thread T1
  [ "${status}" -eq 0 ]
}

@test "a session that does not hold the lock exits 3 and posts nothing" {
  run bash "${scripts}/reply.sh" o/r 7 --session other --thread T1 --body-file "${tmp}/body.md"
  [ "${status}" -eq 3 ]
  expect "$(calls)" 0
}

@test "a thread reply goes to that thread, takes its comment id, and counts on the thread" {
  reply --thread T1
  [ "${status}" -eq 0 ]
  expect "$(jq -r .posted <<<"${output}")" true
  expect "$(jq -r .id <<<"${output}")" PRRC_1
  expect "$(calls)" 1
  [[ "$(cat "${tmp}/calls")" == *"addPullRequestReviewThreadReply"*"id=T1"* ]]
  [[ "$(cat "${tmp}/calls")" == *"Fixed in abc1234."* ]]
  expect "$(ledger '.own.replies[0].id')" PRRC_1
  expect "$(ledger '.replies.T1')" 1
}

@test "a conversation reply is a comment on the pull request and counts on the conversation" {
  reply --conversation
  [ "${status}" -eq 0 ]
  expect "$(jq -r .id <<<"${output}")" IC_1
  [[ "$(cat "${tmp}/calls")" == *"repos/o/r/issues/7/comments"* ]]
  expect "$(ledger '.own.replies[0].id')" IC_1
  expect "$(ledger '.replies.conversation')" 1
  expect "$(ledger '.replies.T1 // 0')" 0
}

@test "a third reply to one thread is not posted and exits 10" {
  reply --thread T1
  reply --thread T1
  [ "${status}" -eq 0 ]
  reply --thread T1
  [ "${status}" -eq 10 ]
  expect "$(jq -r .posted <<<"${output}")" false
  expect "$(calls)" 2
  expect "$(ledger '.replies.T1')" 2
  expect "$(ledger '.own.replies | length')" 2
  reply --thread T2
  [ "${status}" -eq 0 ]
}

@test "issue comments and review bodies share one capped conversation" {
  reply --conversation
  reply --conversation
  reply --conversation
  [ "${status}" -eq 10 ]
  expect "$(calls)" 2
}

@test "no call ever resolves a thread" {
  reply --thread T1
  reply --thread T1
  reply --conversation
  expect "$(calls)" 3
  run grep -qiE 'resolve' "${tmp}/calls"
  [ "${status}" -eq 1 ]
}

@test "a failed post exits 1 and counts nothing against the cap" {
  : >"${tmp}/gh-fails"
  reply --thread T1
  [ "${status}" -eq 1 ]
  expect "$(jq -r .posted <<<"${output}")" false
  expect "$(ledger '.replies.T1 // 0')" 0
  expect "$(ledger '[.own.replies[]? | select(.id != null)] | length')" 0
  rm "${tmp}/gh-fails"
  reply --thread T1
  [ "${status}" -eq 0 ]
  expect "$(ledger '.replies.T1')" 1
}

@test "the pending hash equals the bodyHash pr-state gives the posted comment" {
  reply --thread T1
  [ "${status}" -eq 0 ]
  # GitHub stores the body without its trailing newline, and pr-state hashes what it reads back.
  raw="$(jq -nc --arg body "$(cat "${tmp}/body.md")" '
    def page($nodes): {totalCount: ($nodes | length), pageInfo: {hasNextPage: false, endCursor: null}, nodes: $nodes};
    {data: {viewer: {login: "me"}, repository: {pullRequest: {
      number: 7, url: "https://github.com/o/r/pull/7", state: "OPEN", isDraft: false, isCrossRepository: false,
      mergeable: "MERGEABLE", mergeStateStatus: "CLEAN", reviewDecision: "APPROVED",
      baseRefName: "main", headRefName: "feat/x", headRefOid: "aaa", author: {login: "me"},
      reviewThreads: page([]), reviews: page([]), reviewRequests: page([]), latestOpinionatedReviews: page([]),
      comments: page([{id: "IC1", body: $body, createdAt: "2026-01-01T00:00:00Z", url: "u", isMinimized: false,
        authorAssociation: "MEMBER", author: {login: "me"}}]),
      commits: {nodes: [{commit: {oid: "aaa", statusCheckRollup: {contexts: page([])}}}]}}}}}')"
  run bash "${scripts}/pr-state.sh" --normalize - <<<"${raw}"
  [ "${status}" -eq 0 ]
  expect "$(ledger '.own.replies[0].hash')" "$(jq -r '.comments[0].bodyHash' <<<"${output}")"
}

@test "a lock lost while posting exits 3 and still says the reply was posted" {
  printf '#!/usr/bin/env bash\nbash "%s/ledger.sh" stop o/r 7 %s\nexec "%s" "$@"\n' "${scripts}" "${token}" "${tmp}/gh" >"${tmp}/gh-losing"
  chmod +x "${tmp}/gh-losing"
  export BABYSIT_GH="${tmp}/gh-losing"
  reply --thread T1
  [ "${status}" -eq 3 ]
  expect "$(tail -n 1 <<<"${output}" | jq -r .posted)" true
  expect "$(tail -n 1 <<<"${output}" | jq -r .id)" PRRC_1
}
