#!/usr/bin/env bats
# Tests for oe ready.
#
# - Each test writes the GitHub state it needs as JSON, then runs oe ready against it.
# - testdata/fake-gh.sh stands in for gh and answers every read from that state.
# - testdata/fake-github.jq lists every field of the state and its default.
# - The tests are grouped by the row of the next-action table in docs/design/orchestrate-epic.md that they cover.
# - Every test runs at 08:00 on the same day, so a working marker started at 06:00 or earlier has expired.
# shellcheck disable=SC2292 # bats fails a test on a mid-test `[[ ]]` only under bash 4.1+; `[ ]` works on every bash.

setup() {
  bats_require_minimum_version 1.5.0
  export OE_STATE_DIR="${BATS_TEST_TMPDIR}/state"
  oe="${BATS_TEST_DIRNAME}/oe"
  mkdir -p "${BATS_TEST_TMPDIR}/bin"
  printf '#!/usr/bin/env bash\nexec bash "%s/testdata/fake-gh.sh" "$@"\n' "${BATS_TEST_DIRNAME}" >"${BATS_TEST_TMPDIR}/bin/gh"
  chmod +x "${BATS_TEST_TMPDIR}/bin/gh"
  export PATH="${BATS_TEST_TMPDIR}/bin:${PATH}"
  export OE_GITHUB="${BATS_TEST_TMPDIR}/github.json"
  unset OE_WORKTREE_ROOT
  # 2027-01-15 08:00 UTC
  export OE_NOW=1800000000
  # The head SHA fake-github.jq gives PR 50.
  pr50="$(printf 'b%.0s' {1..38})50"
}

# Saves the GitHub state from stdin.
github() {
  cat >"${OE_GITHUB}"
}

# Configures $1 as the agents' bot, through the git config skills.bot that oe reads.
agent_bot() {
  export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=skills.bot GIT_CONFIG_VALUE_0="$1"
}

# Prints, as a JSON string, an Issue body that ends in the working marker of role $1 started at $2, HH:MM, with the SHA $3 for a Verifier.
marker_body() {
  local sha=""
  [ -z "${3:-}" ] || sha=" sha=$3"
  printf 'Some work.\n\n<!-- oe:working role=%s at=2027-01-15T%s:00Z%s session=s1 -->' "$1" "$2" "${sha}" | jq -Rs .
}

# Prints the action that oe ready gave the Issue numbered $1.
action_of() {
  printf '%s\n' "${lines[@]}" | while IFS=$'\t' read -r n action _; do
    if [ "${n}" = "$1" ]; then
      echo "${action}"
    fi
  done
}

# Prints the field $2 of the line for the Issue numbered $1, counting the Issue number as field 1.
field_of() {
  printf '%s\n' "${lines[@]}" | awk -F '\t' -v n="$1" -v f="$2" '$1 == n { print $f }'
}

# Source of truth

@test "oe ready reads no file under the state directory" {
  mkdir -p "${OE_STATE_DIR}/records"
  echo 'not json' >"${OE_STATE_DIR}/records/garbage.jsonl"
  chmod 000 "${OE_STATE_DIR}"
  github <<'JSON'
{"issues": [{"number": 5, "branch": true, "pull_requests": [{"number": 50, "opened": "07:10", "checks": {"test": "success"}}]}]}
JSON

  run --separate-stderr bash "${oe}" ready o/r 1
  chmod 755 "${OE_STATE_DIR}"

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = start-verifier ]
}

@test "Issues come in number order" {
  github <<'JSON'
{"issues": [{"number": 7}, {"number": 5}, {"number": 6}]}
JSON

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "${#lines[@]}" -eq 3 ]
  [ "${lines[0]%%$'\t'*}" = 5 ]
  [ "${lines[1]%%$'\t'*}" = 6 ]
  [ "${lines[2]%%$'\t'*}" = 7 ]
}

@test "a failed check on the default branch head gives each Issue the action it gets without it" {
  github <<'JSON'
{"issues": [{"number": 5, "closed": true}, {"number": 6}, {"number": 7, "blocked_by": [{"number": 6, "state": "open"}]}]}
JSON
  run bash "${oe}" ready o/r 1
  [ "${status}" -eq 0 ]
  without="${output}"

  github <<'JSON'
{
  "default_branch": {"checks": {"lint": "success", "test": "failure"}},
  "issues": [{"number": 5, "closed": true}, {"number": 6}, {"number": 7, "blocked_by": [{"number": 6, "state": "open"}]}]
}
JSON
  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "${output}" = "${without}" ]
}

@test "every failed GitHub read exits non-zero and prints nothing" {
  github <<'JSON'
{"issues": [{"number": 5, "branch": true, "pull_requests": [{"number": 50, "opened": "07:10", "checks": {"test": "success"}}]}]}
JSON
  run bash "${oe}" ready o/r 1
  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = start-verifier ]

  # The Epic read, the Issue read, the pull request list, the commit statuses, and the push activity.
  for read in subIssues "num=5" /pulls /statuses /activity; do
    GH_FAIL="${read}" run --separate-stderr bash "${oe}" ready o/r 1

    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
  done
}

# Row 1: the Issue is closed

@test "a closed Issue is done" {
  github <<'JSON'
{"issues": [{"number": 5, "closed": true}]}
JSON

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = "done" ]
}

@test "a closed Issue with more comments than one read holds is done" {
  github <<'JSON'
{"issues": [{"number": 5, "closed": true, "branch": true, "older_comments": 150}]}
JSON

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = "done" ]
}

# Row 2: a hold or a question is newer than the latest answer

@test "the line of an Issue with an open question holds the question and the command that records its answer" {
  github <<'JSON'
{
  "issues": [{
    "number": 5,
    "branch": true,
    "comments": [
      {"by": "OWNER", "at": "07:10", "body": "<!-- oe:question -->\n### Question from the orchestrate-epic agent working on this Issue\n\nDecision: Which option?\n\nOptions:\n- A. Keep it\n  - No work.\n\n---\nAnswer in the session's conversation."}
    ]
  }]
}
JSON

  run --separate-stderr bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  IFS=$'\t' read -r n action reason command <<<"${lines[0]}"
  [ "${n}" = 5 ]
  [ "${action}" = wait-answer ]
  [ "${reason}" = 'question https://github.com/o/r/issues/5#issuecomment-1 has no answer yet:\nDecision: Which option?\n\nOptions:\n- A. Keep it\n  - No work.' ]
  [ "${command}" = "bash '${oe}' question o/r 5 --answer <reply>" ]
}

@test "a hold with no later answer waits on the person and names the hold's reason" {
  github <<'JSON'
{
  "issues": [{
    "number": 5,
    "branch": true,
    "comments": [
      {"by": "OWNER", "at": "07:10", "body": "<!-- oe:hold -->\n### The orchestrate-epic session holds this Issue for the person\n\nPR #50 was closed without merging\n\n---\nAnswer in the session's conversation."}
    ],
    "pull_requests": [{"number": 50, "state": "closed", "opened": "07:00"}]
  }]
}
JSON

  run --separate-stderr bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = wait-answer ]
  [ "$(field_of 5 3)" = 'hold https://github.com/o/r/issues/5#issuecomment-1 has no answer yet:\nPR #50 was closed without merging' ]
  [ "$(field_of 5 4)" = "bash '${oe}' question o/r 5 --answer <reply>" ]
}

@test "a hold answered through oe no longer waits, and the answer starts an Owner" {
  github <<'JSON'
{
  "issues": [{
    "number": 5,
    "branch": true,
    "comments": [
      {"by": "OWNER", "at": "07:30", "body": "<!-- oe:hold -->\nfailure verdict on bbbbbbb"},
      {"by": "OWNER", "at": "07:40", "body": "<!-- oe:answer -->\nRetry with a smaller batch"}
    ],
    "pull_requests": [{"number": 50, "opened": "07:10", "checks": {"test": "success"}, "verdicts": ["failure"]}]
  }]
}
JSON

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = start-owner ]
}

@test "a marked or untrusted comment after a question does not answer it" {
  github <<'JSON'
{
  "issues": [{
    "number": 5,
    "branch": true,
    "comments": [
      {"by": "OWNER", "at": "07:10", "body": "<!-- oe:question -->\nWhich option?"},
      {"by": "MEMBER", "at": "07:20", "body": "<!-- oe:note -->\nUse option A"},
      {"by": "NONE", "at": "07:21", "body": "Use option A"},
      {"by": "CONTRIBUTOR", "at": "07:22", "body": "Use option A"}
    ]
  }]
}
JSON

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = wait-answer ]
}

@test "a question from the configured bot waits for the answer, and an answer it records through oe ends the wait" {
  agent_bot agent-app
  github <<'JSON'
{
  "issues": [{
    "number": 5,
    "branch": true,
    "comments": [
      {"by": "NONE", "login": "agent-app", "type": "Bot", "at": "07:10", "body": "<!-- oe:question -->\nWhich option?"}
    ],
    "pull_requests": [{"number": 50, "opened": "07:00", "checks": {"test": "success"}, "verdicts": ["success"]}]
  }]
}
JSON
  run bash "${oe}" ready o/r 1
  [ "$(action_of 5)" = wait-answer ]

  jq '.issues[0].comments += [{"by": "NONE", "login": "agent-app", "type": "Bot", "at": "07:20", "body": "<!-- oe:answer -->\nA. Use option A"}]' \
    "${OE_GITHUB}" >"${OE_GITHUB}.new" && mv "${OE_GITHUB}.new" "${OE_GITHUB}"
  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = start-owner ]
}

@test "a comment from the configured bot that is no record does not answer its question" {
  agent_bot agent-app
  github <<'JSON'
{
  "issues": [{
    "number": 5,
    "branch": true,
    "comments": [
      {"by": "NONE", "login": "agent-app", "type": "Bot", "at": "07:10", "body": "<!-- oe:question -->\nWhich option?"},
      {"by": "NONE", "login": "agent-app", "type": "Bot", "at": "07:20", "body": "Use option A"}
    ]
  }]
}
JSON

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = wait-answer ]
}

@test "an answer-shaped comment from another bot or an untrusted user does not answer the question" {
  agent_bot agent-app
  github <<'JSON'
{
  "issues": [{
    "number": 5,
    "branch": true,
    "comments": [
      {"by": "NONE", "login": "agent-app", "type": "Bot", "at": "07:10", "body": "<!-- oe:question -->\nWhich option?"},
      {"by": "NONE", "login": "renovate", "type": "Bot", "at": "07:20", "body": "<!-- oe:answer -->\nA. Use option A"},
      {"by": "NONE", "login": "agent-app", "type": "User", "at": "07:21", "body": "<!-- oe:answer -->\nA. Use option A"},
      {"by": "CONTRIBUTOR", "at": "07:22", "body": "<!-- oe:answer -->\nA. Use option A"}
    ]
  }]
}
JSON

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = wait-answer ]
}

@test "a hold or question from another bot, or from a user with the configured bot's login, is ignored" {
  agent_bot agent-app
  github <<'JSON'
{
  "issues": [{
    "number": 5,
    "branch": true,
    "comments": [
      {"by": "NONE", "login": "renovate", "type": "Bot", "at": "07:10", "body": "<!-- oe:question -->\nWhich option?"},
      {"by": "NONE", "login": "agent-app", "type": "User", "at": "07:11", "body": "<!-- oe:hold -->\nHold it"}
    ],
    "pull_requests": [{"number": 50, "opened": "07:00", "checks": {"test": "success"}, "verdicts": ["success"]}]
  }]
}
JSON

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = wait-merge ]
}

@test "with no bot configured, a question-shaped comment from a bot is ignored" {
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  github <<'JSON'
{
  "issues": [{
    "number": 5,
    "branch": true,
    "comments": [
      {"by": "NONE", "login": "agent-app", "type": "Bot", "at": "07:10", "body": "<!-- oe:question -->\nWhich option?"}
    ],
    "pull_requests": [{"number": 50, "opened": "07:00", "checks": {"test": "success"}, "verdicts": ["success"]}]
  }]
}
JSON

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = wait-merge ]
}

@test "an invalid configured bot login fails the read" {
  agent_bot 'bad"login'
  github <<'JSON'
{"issues": [{"number": 5}]}
JSON

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 2 ]
  [ "${output}" != "${output#*skills.bot}" ]
}

@test "a push during the read does not hide a pending question" {
  github <<'JSON'
{
  "issues": [{
    "number": 5,
    "branch": true,
    "comments": [{"by": "OWNER", "at": "07:30", "body": "<!-- oe:question -->\nWhich option?"}],
    "pull_requests": [{"number": 50, "opened": "07:10", "checks": {"test": "success"}, "pushed_during_read": true}]
  }]
}
JSON

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = wait-answer ]
}

@test "more comments than one read holds fail the read when the read comments hold no hold, question, or answer" {
  github <<'JSON'
{"issues": [{"number": 5, "branch": true, "comments": [{"by": "NONE", "at": "07:10", "body": "Any news?"}], "older_comments": 150}]}
JSON

  run --separate-stderr bash "${oe}" ready o/r 1

  [ "${status}" -eq 1 ]
  [ -z "${output}" ]
}

@test "more comments than one read holds do not fail the read when the read comments hold a question" {
  github <<'JSON'
{
  "issues": [{
    "number": 5,
    "branch": true,
    "comments": [
      {"by": "MEMBER", "at": "07:00", "body": "Looks fine"},
      {"by": "OWNER", "at": "07:20", "body": "<!-- oe:question -->\nWhich option?"}
    ],
    "older_comments": 150
  }]
}
JSON

  run --separate-stderr bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = wait-answer ]
}

# Row 3: the PR was closed without merging, or merged with the Issue open

@test "an Issue whose PR was closed without merging is held, with the command that records the hold" {
  github <<'JSON'
{"issues": [{"number": 5, "branch": true, "pull_requests": [{"number": 50, "state": "closed", "opened": "07:10"}]}]}
JSON

  run --separate-stderr bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = hold ]
  [ "$(field_of 5 3)" = "PR #50 was closed without merging" ]
  [ "$(field_of 5 4)" = "bash '${oe}' hold o/r 5 'PR #50 was closed without merging'" ]
}

@test "an open Issue whose PR merged at the branch's current head is held" {
  github <<'JSON'
{"issues": [{"number": 5, "branch": true, "pull_requests": [{"number": 50, "state": "merged", "opened": "07:10", "merged": "07:40"}]}]}
JSON

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = hold ]
  [ "$(field_of 5 3)" = "PR #50 merged; the Issue is still open" ]
}

@test "a merged PR whose branch the engineer deleted is not the PR, so an Owner starts over" {
  github <<'JSON'
{"issues": [{"number": 5, "pull_requests": [{"number": 50, "state": "merged", "opened": "07:10", "merged": "07:40"}]}]}
JSON

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = start-owner ]
  [ "$(field_of 5 3)" = "no PR yet" ]
}

@test "a closed PR whose head is not the branch's current head is not the PR" {
  github <<'JSON'
{
  "issues": [{
    "number": 5,
    "branch": true,
    "branch_sha": "cccccccccccccccccccccccccccccccccccccccc",
    "pull_requests": [{"number": 50, "state": "closed", "opened": "07:10"}]
  }]
}
JSON

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = start-owner ]
}

@test "an open PR is the PR even when a newer PR from the branch was closed at another head" {
  github <<JSON
{
  "issues": [{
    "number": 5,
    "branch": true,
    "branch_sha": "${pr50}",
    "pull_requests": [
      {"number": 50, "opened": "07:10", "checks": {"test": "success"}, "verdicts": ["success"]},
      {"number": 51, "state": "closed", "opened": "07:20"}
    ]
  }]
}
JSON

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = wait-merge ]
}

@test "a merged PR from a fork with the Issue's branch name is ignored" {
  github <<'JSON'
{"issues": [{"number": 5, "pull_requests": [{"number": 50, "state": "merged", "opened": "07:10", "merged": "07:40", "from_fork": true}]}]}
JSON

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = start-owner ]
}

# Rows 4 and 5: dependencies

@test "an Issue whose dependency closed as not planned or duplicate is held" {
  github <<'JSON'
{
  "issues": [
    {"number": 5, "blocked_by": [{"number": 3, "state": "completed"}, {"number": 4, "state": "not_planned"}]},
    {"number": 6, "blocked_by": [{"number": 4, "state": "duplicate"}]}
  ]
}
JSON

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = hold ]
  [ "$(field_of 5 3)" = "dependency #4 closed as not_planned" ]
  [ "$(action_of 6)" = hold ]
}

@test "an Issue with one open dependency waits for its dependencies" {
  github <<'JSON'
{"issues": [{"number": 5, "blocked_by": [{"number": 3, "state": "completed"}, {"number": 4, "state": "open"}]}]}
JSON

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = wait-dependencies ]
  [ "$(field_of 5 3)" = "#4 open" ]
  [ -z "$(field_of 5 4)" ]
}

@test "an Issue with no branch and every dependency completed gets an Owner with the command that starts it" {
  github <<'JSON'
{"issues": [{"number": 5, "blocked_by": [{"number": 3, "state": "completed"}]}]}
JSON

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [ "$(action_of 5)" = start-owner ]
  [ "$(field_of 5 4)" = "bash '${oe}' start owner o/r 5 'no PR yet'" ]
}

# Rows 6 and 7: the working marker

@test "an Owner's marker started an hour ago, with no push or question since, waits for the agent" {
  github <<JSON
{"issues": [{"number": 5, "body": $(marker_body owner 07:00)}]}
JSON

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = wait-agent ]
  [ -z "$(field_of 5 4)" ]
}

@test "a Verifier's marker on the head with no verdict yet waits for the agent" {
  github <<JSON
{
  "issues": [{
    "number": 5,
    "branch": true,
    "body": $(marker_body verifier 07:30 "${pr50}"),
    "pull_requests": [{"number": 50, "opened": "07:10", "checks": {"test": "success"}}]
  }]
}
JSON

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = wait-agent ]
}

@test "an Owner's marker whose PR head was pushed after it has its result, so CI decides" {
  github <<JSON
{
  "issues": [{
    "number": 5,
    "branch": true,
    "body": $(marker_body owner 07:00),
    "pull_requests": [{"number": 50, "opened": "07:30", "checks": {"test": "in_progress"}}]
  }]
}
JSON

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = wait-ci ]
}

@test "an Owner's marker whose PR head was pushed before it has no result yet" {
  github <<JSON
{
  "issues": [{
    "number": 5,
    "branch": true,
    "body": $(marker_body owner 07:30),
    "comments": [
      {"by": "OWNER", "at": "07:15", "body": "<!-- oe:hold -->\nchecks failed"},
      {"by": "OWNER", "at": "07:20", "body": "<!-- oe:answer -->\nFix the test"}
    ],
    "pull_requests": [{"number": 50, "opened": "07:10", "checks": {"test": "failure"}}]
  }]
}
JSON

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = wait-agent ]
}

@test "a Verifier's marker whose SHA got a verdict has its result" {
  github <<JSON
{
  "issues": [{
    "number": 5,
    "branch": true,
    "body": $(marker_body verifier 07:30 "${pr50}"),
    "pull_requests": [{"number": 50, "opened": "07:10", "checks": {"test": "success"}, "verdicts": ["success"]}]
  }]
}
JSON

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = wait-merge ]
}

@test "an answer newer than a live marker ends it, so the answer starts the next agent" {
  github <<JSON
{
  "issues": [{
    "number": 5,
    "body": $(marker_body owner 07:30),
    "comments": [
      {"by": "OWNER", "at": "07:10", "body": "<!-- oe:hold -->\nno result"},
      {"by": "OWNER", "at": "07:40", "body": "<!-- oe:answer -->\nTry again"}
    ]
  }]
}
JSON

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = start-owner ]
}

@test "an Owner's marker two hours old with no push or question is held as expired" {
  github <<JSON
{"issues": [{"number": 5, "body": $(marker_body owner 06:00)}]}
JSON

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = hold ]
  [ "$(field_of 5 3)" = "pr-owner started at 2027-01-15T06:00:00Z and gave no result within 2 hours" ]
}

@test "a Verifier's marker two hours old with no verdict is held as expired" {
  github <<JSON
{
  "issues": [{
    "number": 5,
    "branch": true,
    "body": $(marker_body verifier 05:50 "${pr50}"),
    "pull_requests": [{"number": 50, "opened": "05:40", "checks": {"test": "success"}}]
  }]
}
JSON

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = hold ]
}

@test "a malformed marker line is no marker" {
  github <<'JSON'
{"issues": [{"number": 5, "body": "Work.\n\n<!-- oe:working role=owner at=yesterday -->"}]}
JSON

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = start-owner ]
}

# Row 8: repair signals and the repair cap

@test "a failed check on the PR head gets an Owner" {
  github <<'JSON'
{"issues": [{"number": 5, "branch": true, "pull_requests": [{"number": 50, "opened": "07:10", "checks": {"lint": "success", "test": "failure"}}]}]}
JSON

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = start-owner ]
  [ "$(field_of 5 3)" = "checks failed on bbbbbbb: test" ]
}

@test "a PR that conflicts with its base gets an Owner" {
  github <<'JSON'
{"issues": [{"number": 5, "branch": true, "pull_requests": [{"number": 50, "opened": "07:10", "checks": {"test": "success"}, "conflicting": true}]}]}
JSON

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = start-owner ]
  [ "$(field_of 5 3)" = "PR #50 conflicts with its base" ]
}

@test "a trusted Changes requested review of the head after its push gets an Owner" {
  github <<'JSON'
{
  "issues": [{
    "number": 5,
    "branch": true,
    "pull_requests": [{
      "number": 50, "opened": "07:10", "checks": {"test": "success"}, "verdicts": ["success"],
      "reviews": [{"by": "MEMBER", "at": "07:40", "body": "Rename this"}]
    }]
  }]
}
JSON

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = start-owner ]
}

@test "a Changes requested review of an older head starts no Owner" {
  github <<'JSON'
{
  "issues": [{
    "number": 5,
    "branch": true,
    "pull_requests": [{
      "number": 50, "opened": "07:00", "pushed": "07:40",
      "head_sha": "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
      "checks": {"test": "success"}, "verdicts": ["success"],
      "reviews": [{"by": "MEMBER", "at": "07:20", "sha": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "body": "Rename this"}]
    }]
  }]
}
JSON

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = wait-merge ]
}

@test "a trusted review-thread comment after the head's push gets an Owner" {
  github <<'JSON'
{
  "issues": [{
    "number": 5,
    "branch": true,
    "pull_requests": [{
      "number": 50, "opened": "07:10", "checks": {"test": "success"}, "verdicts": ["success"],
      "thread_comments": [{"by": "COLLABORATOR", "at": "07:40", "body": "This leaks the token"}]
    }]
  }]
}
JSON

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = start-owner ]
}

@test "a review-thread comment from before the head's push starts no Owner" {
  github <<'JSON'
{
  "issues": [{
    "number": 5,
    "branch": true,
    "pull_requests": [{
      "number": 50, "opened": "07:10", "pushed": "07:50", "checks": {"test": "success"}, "verdicts": ["success"],
      "thread_comments": [{"by": "COLLABORATOR", "at": "07:40", "body": "This leaks the token"}]
    }]
  }]
}
JSON

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = wait-merge ]
}

@test "untrusted, resolved, outdated, or bot-answered review threads start no Owner" {
  github <<'JSON'
{
  "issues": [{
    "number": 5,
    "branch": true,
    "pull_requests": [{
      "number": 50, "opened": "07:10", "checks": {"test": "success"}, "verdicts": ["success"],
      "threads": [
        {"comments": [{"by": "NONE", "at": "07:40", "body": "This leaks the token"}]},
        {"resolved": true, "comments": [{"by": "COLLABORATOR", "at": "07:40", "body": "This leaks the token"}]},
        {"outdated": true, "comments": [{"by": "COLLABORATOR", "at": "07:40", "body": "This leaks the token"}]},
        {"comments": [
          {"by": "COLLABORATOR", "at": "07:40", "body": "This leaks the token"},
          {"login": "coderabbitai", "type": "Bot", "at": "07:50", "body": "Addressed in the latest push."}]}
      ]
    }]
  }]
}
JSON

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = wait-merge ]
}

@test "a review bot's finding starts no Owner" {
  github <<'JSON'
{
  "issues": [{
    "number": 5,
    "branch": true,
    "pull_requests": [{
      "number": 50, "opened": "07:10", "checks": {"test": "success"}, "verdicts": ["success"],
      "threads": [{"comments": [{"login": "coderabbitai", "type": "Bot", "at": "07:40", "body": "_Potential issue_ | Major\nThis leaks."}]}]
    }]
  }]
}
JSON

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = wait-merge ]
}

@test "a trusted comment on the Issue with no hold or question before it starts no Owner" {
  github <<'JSON'
{
  "issues": [{
    "number": 5,
    "branch": true,
    "comments": [{"by": "OWNER", "at": "07:40", "body": "Looks good so far"}],
    "pull_requests": [{"number": 50, "opened": "07:10", "checks": {"test": "success"}, "verdicts": ["success"]}]
  }]
}
JSON

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = wait-merge ]
}

@test "an answer from before the head's push starts no Owner" {
  github <<'JSON'
{
  "issues": [{
    "number": 5,
    "branch": true,
    "comments": [
      {"by": "OWNER", "at": "07:02", "body": "<!-- oe:question -->\nWhich option?"},
      {"by": "MEMBER", "at": "07:03", "body": "Use option A"}
    ],
    "pull_requests": [{"number": 50, "opened": "07:10", "checks": {"test": "success"}, "verdicts": ["success"]}]
  }]
}
JSON

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = wait-merge ]
}

@test "a trusted comment answering a question after the head's push gets an Owner" {
  github <<'JSON'
{
  "issues": [{
    "number": 5,
    "branch": true,
    "comments": [
      {"by": "OWNER", "at": "07:30", "body": "<!-- oe:question -->\nWhich option?"},
      {"by": "MEMBER", "at": "07:40", "body": "Use option A"}
    ],
    "pull_requests": [{"number": 50, "opened": "07:10", "checks": {"test": "success"}, "verdicts": ["success"]}]
  }]
}
JSON

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = start-owner ]
}

@test "the third commit of the PR with a failed check holds the Issue" {
  github <<'JSON'
{
  "issues": [{
    "number": 5,
    "branch": true,
    "pull_requests": [{
      "number": 50, "opened": "07:00", "committed": "07:40", "checks": {"test": "failure"},
      "commits": [
        {"sha": "1111111111111111111111111111111111111111", "committed": "07:10", "checks": {"test": "failure"}},
        {"sha": "2222222222222222222222222222222222222222", "committed": "07:20", "checks": {"test": "success"}},
        {"sha": "3333333333333333333333333333333333333333", "committed": "07:30", "checks": {"lint": "failure"}}
      ]
    }]
  }]
}
JSON

  run --separate-stderr bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = hold ]
  [ "$(field_of 5 3)" = "3 commits of PR #50 had a failed check since the latest answer; still: checks failed on bbbbbbb: test" ]
}

@test "two commits of the PR with a failed check still get an Owner" {
  github <<'JSON'
{
  "issues": [{
    "number": 5,
    "branch": true,
    "pull_requests": [{
      "number": 50, "opened": "07:00", "committed": "07:40", "checks": {"test": "failure"},
      "commits": [{"sha": "1111111111111111111111111111111111111111", "committed": "07:10", "checks": {"test": "failure"}}]
    }]
  }]
}
JSON

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = start-owner ]
}

@test "commits with a failed check before the latest answer do not count toward the cap" {
  github <<'JSON'
{
  "issues": [{
    "number": 5,
    "branch": true,
    "comments": [
      {"by": "OWNER", "at": "07:30", "body": "<!-- oe:hold -->\n3 commits failed"},
      {"by": "OWNER", "at": "07:35", "body": "<!-- oe:answer -->\nKeep going"}
    ],
    "pull_requests": [{
      "number": 50, "opened": "07:00", "committed": "07:50", "pushed": "07:50", "checks": {"test": "failure"},
      "commits": [
        {"sha": "1111111111111111111111111111111111111111", "committed": "07:10", "checks": {"test": "failure"}},
        {"sha": "2222222222222222222222222222222222222222", "committed": "07:20", "checks": {"test": "failure"}}
      ]
    }]
  }]
}
JSON

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = start-owner ]
}

# Prints, as a JSON array, $1 earlier commits of a PR, oldest first, from 01:00 on.
# The oldest $2 of them have a failed check, and the others passed.
earlier_commits() {
  jq -nc --argjson count "$1" --argjson failed "$2" '
    def pad: if . < 10 then "0\(.)" else "\(.)" end;
    [range(0; $count) | {sha: (("e" * (39 - ("\(.)" | length))) + "a\(.)"),
      committed: "\(1 + (. / 60 | floor) | pad):\(. % 60 | pad)",
      checks: {test: (if . < $failed then "failure" else "success" end)}}]'
}

@test "the oldest 3 of 21 commits since the latest answer with a failed check hold the Issue" {
  github <<JSON
{"issues": [{"number": 5, "branch": true, "pull_requests": [{
  "number": 50, "opened": "00:30", "committed": "07:50", "conflicting": true, "checks": {"test": "success"},
  "commits": $(earlier_commits 20 3)
}]}]}
JSON

  run --separate-stderr bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = hold ]
  [ "$(field_of 5 3)" = "3 commits of PR #50 had a failed check since the latest answer; still: PR #50 conflicts with its base" ]
}

@test "the oldest 3 of 71 commits since the latest answer with a failed check hold the Issue" {
  github <<JSON
{"issues": [{"number": 5, "branch": true, "pull_requests": [{
  "number": 50, "opened": "00:30", "committed": "07:50", "conflicting": true, "checks": {"test": "success"},
  "commits": $(earlier_commits 70 3)
}]}]}
JSON

  run --separate-stderr bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = hold ]
  [ "$(field_of 5 3)" = "3 commits of PR #50 had a failed check since the latest answer; still: PR #50 conflicts with its base" ]
}

@test "a failed read of an earlier page of commits exits non-zero and prints nothing" {
  github <<JSON
{"issues": [{"number": 5, "branch": true, "pull_requests": [{
  "number": 50, "opened": "00:30", "committed": "07:50", "conflicting": true, "checks": {"test": "success"},
  "commits": $(earlier_commits 20 3)
}]}]}
JSON

  GH_FAIL="before=" run --separate-stderr bash "${oe}" ready o/r 1

  [ "${status}" -eq 1 ]
  [ -z "${output}" ]
}

@test "an earlier commit whose only failed check is the 101st counts as a commit with a failed check" {
  github <<JSON
{"issues": [{"number": 5, "branch": true, "pull_requests": [{
  "number": 50, "opened": "00:30", "committed": "07:50", "conflicting": true, "checks": {"test": "success"},
  "commits": $(earlier_commits 2 2 | jq -c '. + [{sha: "1111111111111111111111111111111111111111", committed: "07:00", checks: ([range(1; 101) | {key: "check-\(.)", value: "success"}] + [{key: "check-101", value: "failure"}] | from_entries)}]')
}]}]}
JSON

  run --separate-stderr bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = hold ]
  [ "$(field_of 5 3)" = "3 commits of PR #50 had a failed check since the latest answer; still: PR #50 conflicts with its base" ]
}

@test "a failed read of a later page of an earlier commit's checks exits non-zero and prints nothing" {
  github <<JSON
{"issues": [{"number": 5, "branch": true, "pull_requests": [{
  "number": 50, "opened": "00:30", "committed": "07:50", "conflicting": true, "checks": {"test": "success"},
  "commits": [{"sha": "1111111111111111111111111111111111111111", "committed": "07:00", "checks": $(checks_150 success)}]
}]}]}
JSON

  GH_FAIL="after=" run --separate-stderr bash "${oe}" ready o/r 1

  [ "${status}" -eq 1 ]
  [ -z "${output}" ]
}

@test "a failed check whose name holds a newline and tabs yields one line of four fields and no injected command" {
  github <<'JSON'
{"issues": [{"number": 5, "branch": true, "pull_requests": [{"number": 50, "opened": "07:10", "checks": {"x\n9; touch pwned\tstart-owner\ty": "failure"}}]}]}
JSON

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  tabs="${lines[0]//[^$'\t']/}"
  [ "${#tabs}" -eq 3 ]
  [ "$(action_of 5)" = start-owner ]
}

@test "a reason holding a single quote reads back unchanged from the start command" {
  github <<'JSON'
{"issues": [{"number": 5, "branch": true, "pull_requests": [{"number": 15, "opened": "07:10", "checks": {"it's": "failure"}}]}]}
JSON

  run --separate-stderr bash "${oe}" ready o/r 1

  IFS=$'\t' read -r _ action reason start <<<"${lines[0]}"
  [ "${action}" = start-owner ]
  [ "${reason}" != "${reason#*it\'s}" ]
  eval "set -- ${start#bash }"
  [ "$1" = "${oe}" ]
  [ "${*: -1}" = "${reason}" ]
}

# Rows 9 and 10: CI on the head

@test "a running check on the PR head waits for CI" {
  github <<'JSON'
{"issues": [{"number": 5, "branch": true, "pull_requests": [{"number": 50, "opened": "07:10", "checks": {"lint": "success", "test": "in_progress"}}]}]}
JSON

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = wait-ci ]
}

@test "a PR head pushed five minutes ago with no checks waits for CI, even when committed long before" {
  github <<'JSON'
{"issues": [{"number": 5, "branch": true, "pull_requests": [{"number": 50, "opened": "07:10", "committed": "06:00", "pushed": "07:55"}]}]}
JSON

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = wait-ci ]
}

@test "a PR head with no checks ten minutes after its push is held" {
  github <<'JSON'
{"issues": [{"number": 5, "branch": true, "pull_requests": [{"number": 50, "opened": "07:10", "pushed": "07:40"}]}]}
JSON

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = hold ]
  [ "$(field_of 5 3)" = "no checks on bbbbbbb 1200s after its push" ]
}

@test "a check cancelled in one suite and passed by a later run of the same name in another suite counts as passed" {
  github <<'JSON'
{
  "issues": [{
    "number": 5,
    "branch": true,
    "pull_requests": [{"number": 50, "opened": "07:10", "check_runs": [
      {"name": "gate", "result": "cancelled", "suite": 1, "workflow": 7, "started": "07:15"},
      {"name": "gate", "result": "success", "suite": 2, "workflow": 7, "started": "07:16"}
    ]}]
  }]
}
JSON

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = start-verifier ]
}

@test "a check cancelled in one suite while a later run of the same name in another suite is running waits for CI" {
  github <<'JSON'
{
  "issues": [{
    "number": 5,
    "branch": true,
    "pull_requests": [{"number": 50, "opened": "07:10", "check_runs": [
      {"name": "gate", "result": "cancelled", "suite": 1, "workflow": 7, "started": "07:15"},
      {"name": "gate", "result": "in_progress", "suite": 2, "workflow": 7, "started": "07:16"}
    ]}]
  }]
}
JSON

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = wait-ci ]
}

@test "a cancelled check with no later run of the same name gets an Owner" {
  github <<'JSON'
{
  "issues": [{
    "number": 5,
    "branch": true,
    "pull_requests": [{"number": 50, "opened": "07:10", "check_runs": [
      {"name": "gate", "result": "cancelled", "suite": 2, "workflow": 7, "started": "07:16"},
      {"name": "lint", "result": "success", "suite": 1, "started": "07:17"}
    ]}]
  }]
}
JSON

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = start-owner ]
}

@test "a check cancelled in one workflow and passed by a later run of the same name from another workflow gets an Owner" {
  github <<'JSON'
{
  "issues": [{
    "number": 5,
    "branch": true,
    "pull_requests": [{"number": 50, "opened": "07:10", "check_runs": [
      {"name": "gate", "result": "cancelled", "suite": 1, "workflow": 7, "started": "07:15"},
      {"name": "gate", "result": "success", "suite": 2, "workflow": 8, "started": "07:16"}
    ]}]
  }]
}
JSON

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = start-owner ]
}

# Prints 150 checks named check-1 to check-150, which GitHub returns over two pages.
# check-150, on the second page, has the result $1, and every other check passed.
checks_150() {
  jq -nc --arg last "$1" '[range(1; 150) | {key: "check-\(.)", value: "success"}] + [{key: "check-150", value: $last}] | from_entries'
}

@test "a pending check on the second page of a PR head with 150 checks waits for CI" {
  github <<JSON
{"issues": [{"number": 5, "branch": true, "pull_requests": [{"number": 50, "opened": "07:10", "checks": $(checks_150 in_progress)}]}]}
JSON

  run --separate-stderr bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = wait-ci ]
}

@test "a failed check on the second page of a PR head with 150 checks gets an Owner that names it" {
  github <<JSON
{"issues": [{"number": 5, "branch": true, "pull_requests": [{"number": 50, "opened": "07:10", "checks": $(checks_150 failure)}]}]}
JSON

  run --separate-stderr bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = start-owner ]
  [ "$(field_of 5 3)" = "checks failed on bbbbbbb: check-150" ]
}

@test "a failed read of the second page of checks exits non-zero and prints nothing" {
  github <<JSON
{"issues": [{"number": 5, "branch": true, "pull_requests": [{"number": 50, "opened": "07:10", "checks": $(checks_150 success)}]}]}
JSON

  GH_FAIL="after=" run --separate-stderr bash "${oe}" ready o/r 1

  [ "${status}" -eq 1 ]
  [ -z "${output}" ]
}

# Rows 11 to 13: the verdict on the head

@test "a head that passed its checks with no verdict gets a Verifier with the command that starts it" {
  github <<'JSON'
{"issues": [{"number": 5, "branch": true, "pull_requests": [{"number": 50, "opened": "07:10", "checks": {"test": "success"}}]}]}
JSON

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = start-verifier ]
  [ "$(field_of 5 4)" = "bash '${oe}' start verifier o/r 5" ]
}

@test "pending verify statuses on the head are no verdict, so the head still gets a Verifier" {
  github <<'JSON'
{"issues": [{"number": 5, "branch": true, "pull_requests": [{"number": 50, "opened": "07:10", "checks": {"test": "success"}, "verdicts": ["pending", "pending", "pending"]}]}]}
JSON

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = start-verifier ]
}

@test "a failure verdict on the head holds the Issue" {
  github <<'JSON'
{"issues": [{"number": 5, "branch": true, "pull_requests": [{"number": 50, "opened": "07:10", "checks": {"test": "success"}, "verdicts": ["failure", "pending"]}]}]}
JSON

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = hold ]
  [ "$(field_of 5 3)" = "failure verdict on bbbbbbb" ]
}

@test "a success verdict on the head waits for the merge" {
  github <<'JSON'
{"issues": [{"number": 5, "branch": true, "pull_requests": [{"number": 50, "opened": "07:10", "checks": {"test": "success"}, "verdicts": ["success", "pending"]}]}]}
JSON

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = wait-merge ]
}

@test "a head that lacks a merged sibling PR is verified, since the engineer updates the branch" {
  github <<'JSON'
{
  "issues": [
    {"number": 4, "closed": true, "pull_requests": [{"number": 40, "state": "merged", "opened": "07:05", "merged": "07:30"}]},
    {"number": 5, "branch": true, "pull_requests": [{"number": 50, "opened": "07:10", "checks": {"test": "success"}, "missing_merges": [40]}]}
  ]
}
JSON

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = start-verifier ]
}

# A PR that moved during the read, and reads GitHub cuts short

@test "a push during the read leaves only its Issue to be read again" {
  github <<'JSON'
{
  "issues": [
    {"number": 5, "branch": true, "pull_requests": [{"number": 50, "opened": "07:10", "checks": {"test": "success"}, "pushed_during_read": true}]},
    {"number": 6}
  ]
}
JSON

  run --separate-stderr bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = read-again ]
  [ -z "$(field_of 5 4)" ]
  [ "$(action_of 6)" = start-owner ]
}

@test "more review threads than one read holds fail the read instead of missing engineer input" {
  github <<'JSON'
{"issues": [{"number": 5, "branch": true, "pull_requests": [{"number": 50, "opened": "07:10", "checks": {"test": "success"}, "verdicts": ["success"], "older_threads": 100}]}]}
JSON

  run --separate-stderr bash "${oe}" ready o/r 1

  [ "${status}" -eq 1 ]
  [ -z "${output}" ]
}

@test "older PRs left out of the read do not fail it, and the newest one decides the action" {
  github <<'JSON'
{"issues": [{"number": 5, "branch": true, "pull_requests": [{"number": 15, "opened": "07:10", "checks": {"test": "success"}}], "older_pull_requests": 100}]}
JSON

  run --separate-stderr bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = start-verifier ]
}

@test "--running is accepted and changes nothing, so a caller written for it still runs" {
  github <<'JSON'
{"issues": [{"number": 5}, {"number": 6}]}
JSON

  run bash "${oe}" ready o/r 1 --running 6

  [ "${status}" -eq 0 ]
  [ "$(action_of 6)" = start-owner ]
}

@test "--facts, whose only reader is gone, is refused as an unknown argument" {
  github <<'JSON'
{"issues": [{"number": 5}]}
JSON

  run --separate-stderr bash "${oe}" ready o/r 1 --facts

  [ "${status}" -eq 2 ]
  [ -z "${output}" ]
}
# Reads of one Issue each

@test "a closed Issue is done without a read of its own, while an open Issue beside it is read" {
  github <<'JSON'
{"issues": [{"number": 5, "closed": true}, {"number": 6}]}
JSON

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [ "$(action_of 5)" = "done" ]
  [ "$(field_of 5 3)" = closed ]
  [ "$(cat "${OE_GITHUB}.issue-reads")" = 6 ]
}
