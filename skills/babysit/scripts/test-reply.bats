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
  # A stub pr-state that prints the pull request as snap.json holds it, or fails on demand.
  printf '#!/usr/bin/env bash\n[ -e "%s/pr-state-fails" ] && exit 1\ncat "%s/snap.json"\n' "${tmp}" "${tmp}" >"${tmp}/pr-state"
  chmod +x "${tmp}/pr-state"
  export BABYSIT_PR_STATE="${tmp}/pr-state"
  owned_by null
  printf 'Fixed in abc1234.\nありがとう\n' >"${tmp}/body.md"
  bash "${scripts}/ledger.sh" start o/r 7 "${token}" >/dev/null
}

# Writes a pull request whose automationOwner is the JSON value $1.
owned_by() {
  jq -nc --argjson owner "$1" '{repo: "o/r", number: 7, state: "OPEN", author: "me", viewer: "me",
    isCrossRepository: false, automationOwner: $owner}' >"${tmp}/snap.json"
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

@test "a reply on a pull request another automation owns exits 11, names it, posts nothing, and counts nothing" {
  owned_by '"orchestrate-epic"'
  reply --thread T1
  [ "${status}" -eq 11 ]
  expect "$(jq -r .posted <<<"${output}")" false
  expect "$(jq -r .owner <<<"${output}")" orchestrate-epic
  expect "$(calls)" 0
  expect "$(ledger '.replies.T1 // 0')" 0
  expect "$(ledger '.own.replies // [] | length')" 0
}

@test "a reply when the pull request cannot be read exits 1 and posts nothing" {
  : >"${tmp}/pr-state-fails"
  reply --conversation
  [ "${status}" -eq 1 ]
  expect "$(jq -r .posted <<<"${output}")" false
  expect "$(calls)" 0
  rm "${tmp}/pr-state-fails"
  jq -nc '{repo: "o/r", number: 7}' >"${tmp}/snap.json"
  reply --conversation
  [ "${status}" -eq 1 ]
  expect "$(calls)" 0
}

@test "an owned pull request takes no reply until a human deletes the marker, then the reply goes out" {
  owned_by '"orchestrate-epic"'
  reply --thread T1
  [ "${status}" -eq 11 ]
  owned_by null
  reply --thread T1
  [ "${status}" -eq 0 ]
  expect "$(calls)" 1
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

@test "a body asking CodeRabbit to approve exits 11, posts nothing, and leaves the ledger as it was" {
  before="$(bash "${scripts}/ledger.sh" show o/r 7)"
  printf 'Fixed in abc1234.\n@coderabbitai approve\n' >"${tmp}/body.md"
  # A later clock makes any ledger write, even a heartbeat refresh, show up in the comparison.
  export BABYSIT_NOW=1000100
  reply --thread T1
  [ "${status}" -eq 11 ]
  expect "$(jq -r .posted <<<"${output}")" false
  expect "$(calls)" 0
  expect "$(bash "${scripts}/ledger.sh" show o/r 7)" "${before}"
}

@test "a body asking CodeRabbit to resolve exits 11 and posts nothing" {
  printf '@coderabbitai resolve\n' >"${tmp}/body.md"
  reply --conversation
  [ "${status}" -eq 11 ]
  expect "$(jq -r .posted <<<"${output}")" false
  expect "$(calls)" 0
}

@test "the approval command is refused whatever its letter case" {
  printf '@CodeRabbitAI  Approve\n' >"${tmp}/body.md"
  reply --thread T1
  [ "${status}" -eq 11 ]
  expect "$(calls)" 0
}

@test "a body mentioning CodeRabbit without approve or resolve is posted" {
  printf '@coderabbitai fixed in abc1234; the approval flow is unchanged.\n' >"${tmp}/body.md"
  reply --thread T1
  [ "${status}" -eq 0 ]
  expect "$(jq -r .posted <<<"${output}")" true
  expect "$(calls)" 1
}

@test "a line that is only a re-review request to a listed bot is posted" {
  printf 'Fixed in abc1234.\n@codex review\n' >"${tmp}/body.md"
  reply --thread T1
  [ "${status}" -eq 0 ]
  printf '  @CodeRabbitAI Review  \n' >"${tmp}/body.md"
  reply --thread T2
  [ "${status}" -eq 0 ]
  expect "$(calls)" 2
}

@test "an address, a longer name, or a bot named without @ is not a mention and is posted" {
  printf 'Mail a@codex.com or ping @codexfoo; coderabbitai and codex reviewed this.\n' >"${tmp}/body.md"
  reply --thread T1
  [ "${status}" -eq 0 ]
  expect "$(calls)" 1
}

@test "a path or a slash word that does not start its line is posted" {
  printf '/tmp/x holds the log.\nRun it, then /approve is not needed.\n' >"${tmp}/body.md"
  reply --thread T1
  [ "${status}" -eq 0 ]
  expect "$(calls)" 1
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
