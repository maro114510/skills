#!/usr/bin/env bats
# Tests for drive.sh. A stub wait.sh hands out queued event lines, a stub agent stands in for the configured
# agent command, and the pushes go to a local origin, so no test calls GitHub or a model.
# shellcheck disable=SC2292 # bats fails a test on a mid-test `[[ ]]` only under bash 4.1+; `[ ]` works on every bash.
# shellcheck disable=SC2016 # agent_does snippets expand later, inside the stub agent.

setup() {
  scripts="${BATS_TEST_DIRNAME}"
  unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_PREFIX
  tmp="${BATS_TEST_TMPDIR}"
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
  export BABYSIT_REMOTE_BASE="file://${tmp}/srv"
  export BABYSIT_PR_STATE="${tmp}/pr-state"
  export BABYSIT_WAIT="${tmp}/wait"
  export BABYSIT_NOW=1000000
  mkdir -p "${tmp}/srv/o" "${tmp}/bin"

  git init -q --bare -b main "${tmp}/srv/o/r.git"
  git clone -q "file://${tmp}/srv/o/r.git" "${tmp}/seed" 2>/dev/null
  git -C "${tmp}/seed" switch -q -c main
  printf 'base\n' >"${tmp}/seed/app.txt"
  git -C "${tmp}/seed" add -- app.txt
  git -C "${tmp}/seed" commit -q -m base
  git -C "${tmp}/seed" push -q origin main
  git -C "${tmp}/seed" switch -q -c feat/x
  printf 'feature\n' >"${tmp}/seed/feature.txt"
  git -C "${tmp}/seed" add -- feature.txt
  git -C "${tmp}/seed" commit -q -m feature
  git -C "${tmp}/seed" push -q origin feat/x
  head0="$(git -C "${tmp}/seed" rev-parse HEAD)"
  git clone -q "file://${tmp}/srv/o/r.git" "${tmp}/repo" 2>/dev/null
  cd "${tmp}/repo" || return 1
  git config skills.babysit.agent "${tmp}/agent --print"

  cat >"${tmp}/bin/gh" <<EOF
#!/usr/bin/env bash
printf '%s ' "\$@" | tr '\n' ' ' >>"${tmp}/gh-calls"
echo >>"${tmp}/gh-calls"
n=\$(wc -l <"${tmp}/gh-calls" | tr -d ' ')
expr=""
prev=""
for a in "\$@"; do
  [ "\$prev" = "--jq" ] && expr="\$a"
  prev="\$a"
done
case "\$*" in
"api repos/o/r") resp='{"default_branch":"main"}' ;;
*graphql*) resp="{\"data\":{\"addPullRequestReviewThreadReply\":{\"comment\":{\"id\":\"PRRC_\$n\"}}}}" ;;
*issues/7/comments*) resp="{\"id\":1,\"node_id\":\"IC_\$n\"}" ;;
*) exit 0 ;;
esac
if [ -n "\$expr" ]; then jq -r "\$expr" <<<"\$resp"; else echo "\$resp"; fi
EOF
  printf '#!/usr/bin/env bash\ncat "%s/snap.json"\n' "${tmp}" >"${tmp}/pr-state"
  # Each call logs its arguments and prints the next queued event line; an empty queue is an API failure.
  cat >"${tmp}/wait" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"${tmp}/wait-calls"
[ -s "${tmp}/events" ] || exit 1
head -n 1 "${tmp}/events"
tail -n +2 "${tmp}/events" >"${tmp}/events.rest"
mv "${tmp}/events.rest" "${tmp}/events"
EOF
  # The agent logs its call, environment, directory, and event file, then runs what the test put in agent-does.
  cat >"${tmp}/agent" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"${tmp}/agent-calls"
env >"${tmp}/agent-env"
pwd -P >"${tmp}/agent-pwd"
cp "\${BABYSIT_EVENT_FILE}" "${tmp}/agent-event.json"
. "${tmp}/agent-does"
EOF
  agent_does 'printf '\''{"outcome":"none"}'\'' >"${BABYSIT_RESULT_FILE}"'
  printf '#!/usr/bin/env bash\n' >"${tmp}/osascript"
  chmod +x "${tmp}/bin/gh" "${tmp}/pr-state" "${tmp}/wait" "${tmp}/agent" "${tmp}/osascript"
  export PATH="${tmp}/bin:${PATH}"
  export BABYSIT_GH="${tmp}/bin/gh" BABYSIT_OSASCRIPT="${tmp}/osascript"
  : >"${tmp}/events"

  clean='{"repo":"o/r","number":7,"url":"https://github.com/o/r/pull/7","state":"OPEN","isDraft":false,
    "author":"me","viewer":"me","isCrossRepository":false,"baseRef":"main","headRef":"feat/x","head":"HEAD0",
    "mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","reviewDecision":"REVIEW_REQUIRED","automationOwner":null,
    "checks":[{"key":"ci/test","name":"test","workflow":"CI","kind":"check_run","rerunnable":true,"status":"pass",
      "runId":100,"workflowRunId":10,"attempt":1,"url":"https://example.invalid/run/100","startedAt":"2026-01-01T00:00:00Z"}],
    "reviewRequests":[],"latestReviews":[],"threads":[],"reviews":[],"comments":[]}'
  set_snap '.'
}

# Writes the snapshot at head0 after the jq edit $1.
set_snap() {
  jq -c --arg head "${head0}" ".head = \$head | $1" <<<"${clean}" >"${tmp}/snap.json"
}

# Queues one event line at head0: the object $1 merged over the fields every event carries.
queue() {
  jq -nc --arg head "${head0}" "{repo: \"o/r\", pr: 7, head: \$head, gen: 0} + $1" >>"${tmp}/events"
}

# Queues the stop event $1 with an empty report.
queue_stop() {
  queue "{event: \"$1\", report: {parked: [], reported: [], handled: [], unresolved: [], muted: [], pending: [], reasons: {}}}"
}

# Queues a comment event for comment id $1 by author $2 with body hash $3, on thread $4 or none.
queue_comment() {
  queue "{event: \"comment\", key: \"c:$1\", hash: \"$3\",
    comment: {id: \"$1\", kind: \"issue_comment\", author: \"$2\", thread: ${4:-null}, excerpt: \"x\", bodyLength: 1}}"
}

# Sets the shell snippet the stub agent runs.
agent_does() {
  printf '%s\n' "$1" >"${tmp}/agent-does"
}

drive() {
  run bash "${scripts}/drive.sh" o/r 7
}

field() {
  tail -n 1 <<<"${output}" | jq -r "$1"
}

ledger() {
  bash "${scripts}/ledger.sh" show o/r 7 | jq -r "$1"
}

agent_calls() {
  if [ -e "${tmp}/agent-calls" ]; then wc -l <"${tmp}/agent-calls" | tr -d ' '; else echo 0; fi
}

remote_head() {
  git --git-dir="${tmp}/srv/o/r.git" rev-parse refs/heads/feat/x
}

expect() {
  if [ "$1" != "$2" ]; then
    echo "expected [$2], got [$1]; output: ${output}" >&2
    return 1
  fi
}

codex_receipt='{id: "IC1", author: "chatgpt-codex-connector", authorAssociation: "NONE",
  body: "<!-- codex-review-receipt:v1 -->\nCodex Review: Didn'\''t find any major issues.", bodyHash: "h1",
  createdAt: "2026-01-02T00:00:00Z", url: "u", isMinimized: false}'
human_comment='{id: "IC1", author: "carol", authorAssociation: "MEMBER", body: "please rename feature.txt", bodyHash: "h1",
  createdAt: "2026-01-02T00:00:00Z", url: "u", isMinimized: false}'

@test "exits 2 and takes no lock when skills.babysit.agent is unset" {
  git config --unset skills.babysit.agent
  queue_stop approved
  drive
  expect "${status}" 2
  [ ! -e "${tmp}/wait-calls" ]
  expect "$(ledger '.lock // "none"')" none
}

@test "exits 2 on a pull request the viewer did not author" {
  set_snap '.author = "someone"'
  queue_stop approved
  drive
  expect "${status}" 2
  [ ! -e "${tmp}/wait-calls" ]
}

@test "a Codex status comment is recorded as reported and the agent is not invoked" {
  set_snap ".comments = [${codex_receipt}]"
  queue_comment IC1 chatgpt-codex-connector h1
  queue_stop approved
  drive
  expect "${status}" 0
  expect "$(agent_calls)" 0
  expect "$(ledger '.items["c:IC1"].disposition')" reported
  expect "$(ledger '.items["c:IC1"].hash')" h1
}

@test "a CodeRabbit summary comment is recorded as reported and the agent is not invoked" {
  set_snap '.comments = [{id: "IC1", author: "coderabbitai", authorAssociation: "NONE",
    body: "<!-- This is an auto-generated comment: summarize by coderabbit.ai -->\nWalkthrough", bodyHash: "h1",
    createdAt: "2026-01-02T00:00:00Z", url: "u", isMinimized: false}]'
  queue_comment IC1 coderabbitai h1
  queue_stop approved
  drive
  expect "${status}" 0
  expect "$(agent_calls)" 0
  expect "$(ledger '.items["c:IC1"].disposition')" reported
}

@test "a CodeRabbit review comment without a status marker invokes the agent" {
  set_snap '.comments = [{id: "IC1", author: "coderabbitai", authorAssociation: "NONE",
    body: "_Potential issue_ | Major\n<!-- This is an auto-generated comment by CodeRabbit -->", bodyHash: "h1",
    createdAt: "2026-01-02T00:00:00Z", url: "u", isMinimized: false}]'
  queue_comment IC1 coderabbitai h1
  queue_stop approved
  drive
  expect "${status}" 0
  expect "$(agent_calls)" 1
}

@test "a status marker from an author who is not that bot invokes the agent" {
  set_snap ".comments = [${codex_receipt} | .author = \"carol\"]"
  queue_comment IC1 carol h1
  queue_stop approved
  drive
  expect "${status}" 0
  expect "$(agent_calls)" 1
}

@test "a human comment invokes the agent once with that event and its full body, in the drive worktree" {
  set_snap ".comments = [${human_comment}]"
  queue_comment IC1 carol h1
  queue_stop approved
  drive
  expect "${status}" 0
  expect "$(agent_calls)" 1
  expect "$(jq -r '.key' "${tmp}/agent-event.json")" c:IC1
  expect "$(jq -r '.comment.body' "${tmp}/agent-event.json")" "please rename feature.txt"
  expect "$(cat "${tmp}/agent-pwd")" "$(cd "$(git rev-parse --git-common-dir)/babysit/wt/o/r/7" && pwd -P)"
  grep -q -- '^--print ' "${tmp}/agent-calls"
  expect "$(ledger '.items["c:IC1"].disposition')" handled
}

@test "idle re-arms wait with no agent call" {
  queue '{event: "idle"}'
  queue_stop approved
  drive
  expect "${status}" 0
  expect "$(wc -l <"${tmp}/wait-calls" | tr -d ' ')" 2
  expect "$(agent_calls)" 0
}

@test "approved stops with exit 0, clears the lock, and reports the stop" {
  queue_stop approved
  drive
  expect "${status}" 0
  expect "$(field .stop)" approved
  expect "$(ledger '.lock // "none"')" none
}

@test "stalled stops with exit 1" {
  queue_stop stalled
  drive
  expect "${status}" 1
  expect "$(field .stop)" stalled
}

@test "a time limit with rounds below 5 restarts in a new session" {
  queue_stop limit
  queue_stop approved
  drive
  expect "${status}" 0
  expect "$(wc -l <"${tmp}/wait-calls" | tr -d ' ')" 2
  first="$(sed -n 1p "${tmp}/wait-calls" | sed 's/.*--session \([^ ]*\).*/\1/')"
  second="$(sed -n 2p "${tmp}/wait-calls" | sed 's/.*--session \([^ ]*\).*/\1/')"
  [ -n "${first}" ]
  [ "${first}" != "${second}" ]
}

@test "a limit with rounds at 5 stops with exit 1" {
  path="$(bash "${scripts}/ledger.sh" path o/r 7)"
  mkdir -p "$(dirname "${path}")"
  printf '{"rounds":5}\n' >"${path}"
  queue_stop limit
  queue_stop approved
  drive
  expect "${status}" 1
  expect "$(field .stop)" limit
  expect "$(wc -l <"${tmp}/wait-calls" | tr -d ' ')" 1
}

@test "a re-runnable check failure is re-run with no agent call" {
  queue '{event: "check_failed", key: "k:ci/test@x#0", check: {key: "ci/test", runId: 100, workflowRunId: 10}}'
  queue_stop approved
  drive
  expect "${status}" 0
  expect "$(agent_calls)" 0
  grep -q 'run rerun 10 --failed' "${tmp}/gh-calls"
  expect "$(ledger '.items["k:ci/test@x#0"].disposition')" rerun
}

@test "the agent's fix for a confirmed check failure is pushed and the item recorded handled" {
  queue '{event: "check_confirmed", key: "k:ci/test@x#0", check: {key: "ci/test", runId: 101, workflowRunId: 10}}'
  queue_stop approved
  agent_does 'printf "fixed\n" >fix.txt; git add -- fix.txt; git commit -q -m fix; printf '\''{"outcome":"fixed"}'\'' >"${BABYSIT_RESULT_FILE}"'
  drive
  expect "${status}" 0
  [ "$(remote_head)" != "${head0}" ]
  expect "$(ledger .rounds)" 1
  expect "$(ledger '.repairs["ci/test"]')" 1
  expect "$(ledger '.items["k:ci/test@x#0"].disposition')" handled
  run grep -E -i 'merge|ready|requested_reviewers' "${tmp}/gh-calls"
  expect "${status}" 1
}

@test "the agent's reply is posted on the comment's thread and the comment recorded handled" {
  set_snap ".threads = [{id: \"T1\", isResolved: false, path: \"a\", line: 1, comments: [${human_comment}]}]"
  queue_comment IC1 carol h1 '"T1"'
  queue_stop approved
  agent_does 'printf '\''{"outcome":"reply","reply":"feature.txt is already renamed."}'\'' >"${BABYSIT_RESULT_FILE}"'
  drive
  expect "${status}" 0
  grep -q 'graphql.*id=T1.*body=feature.txt is already renamed.' "${tmp}/gh-calls"
  expect "$(ledger '.items["c:IC1"].disposition')" handled
}

@test "the agent's park is recorded with its reason" {
  set_snap ".comments = [${human_comment}]"
  queue_comment IC1 carol h1
  queue_stop approved
  agent_does 'printf '\''{"outcome":"park","reason":"needs a product decision"}'\'' >"${BABYSIT_RESULT_FILE}"'
  drive
  expect "${status}" 0
  expect "$(ledger '.items["c:IC1"].disposition')" parked
  expect "$(ledger '.items["c:IC1"].reason')" "needs a product decision"
}

@test "an agent that writes no result parks the item" {
  set_snap ".comments = [${human_comment}]"
  queue_comment IC1 carol h1
  queue_stop approved
  agent_does ':'
  drive
  expect "${status}" 0
  expect "$(ledger '.items["c:IC1"].disposition')" parked
}

@test "an agent that exits nonzero stops the run with exit 1" {
  set_snap ".comments = [${human_comment}]"
  queue_comment IC1 carol h1
  queue_stop approved
  agent_does 'exit 4'
  drive
  expect "${status}" 1
  expect "$(wc -l <"${tmp}/wait-calls" | tr -d ' ')" 1
  expect "$(ledger '.lock // "none"')" none
}

@test "the agent gets neither GH_TOKEN, GITHUB_TOKEN, nor the session token" {
  export GH_TOKEN=gh-secret GITHUB_TOKEN=github-secret
  set_snap ".comments = [${human_comment}]"
  queue_comment IC1 carol h1
  queue_stop approved
  drive
  expect "${status}" 0
  session="$(sed -n 1p "${tmp}/wait-calls" | sed 's/.*--session \([^ ]*\).*/\1/')"
  [ -n "${session}" ]
  run grep -l -e gh-secret -e github-secret -e "${session}" "${tmp}/agent-env" "${tmp}/agent-calls" "${tmp}/agent-event.json"
  expect "${status}" 1
}

@test "a remote head that moves while the agent runs parks the item and stops" {
  set_snap ".comments = [${human_comment}]"
  queue_comment IC1 carol h1
  queue_stop approved
  agent_does "jq -c '.head = \"0000000000000000000000000000000000000000\"' '${tmp}/snap.json' >'${tmp}/snap.new'
mv '${tmp}/snap.new' '${tmp}/snap.json'
printf '{\"outcome\":\"none\"}' >\"\${BABYSIT_RESULT_FILE}\""
  drive
  expect "${status}" 1
  expect "$(ledger '.items["c:IC1"].disposition')" parked
  expect "$(wc -l <"${tmp}/wait-calls" | tr -d ' ')" 1
}
