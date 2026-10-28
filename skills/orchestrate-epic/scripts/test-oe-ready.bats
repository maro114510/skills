#!/usr/bin/env bats
# Tests for oe ready.
#
# - Each test writes the GitHub state it needs as JSON, then runs oe ready against it.
# - testdata/fake-gh.sh stands in for gh and answers every read from that state.
# - testdata/fake-github.jq lists every field of the state and its default.
# - Every test runs at 08:00 on the same day.
# shellcheck disable=SC2292 # bats fails a test on a mid-test `[[ ]]` only under bash 4.1+; `[ ]` works on every bash.

setup() {
  bats_require_minimum_version 1.5.0
  oe="${BATS_TEST_DIRNAME}/oe"
  mkdir -p "${BATS_TEST_TMPDIR}/bin"
  printf '#!/usr/bin/env bash\nexec bash "%s/testdata/fake-gh.sh" "$@"\n' "${BATS_TEST_DIRNAME}" >"${BATS_TEST_TMPDIR}/bin/gh"
  chmod +x "${BATS_TEST_TMPDIR}/bin/gh"
  export PATH="${BATS_TEST_TMPDIR}/bin:${PATH}"
  export OE_GITHUB="${BATS_TEST_TMPDIR}/github.json"
  # 2027-01-15 08:00 UTC
  export OE_NOW=1800000000
}

# Saves the GitHub state from stdin.
github() {
  cat >"${OE_GITHUB}"
}

# Prints the action that oe ready gave the Issue numbered $1.
action_of() {
  printf '%s\n' "${lines[@]}" | while IFS=$'\t' read -r n action _; do
    if [ "${n}" = "$1" ]; then
      echo "${action}"
    fi
  done
}

# Default branch gate

@test "a default branch head with no checks ten minutes after its push ends the session with a reason" {
  github <<'JSON'
{
  "default_branch": {"pushed": "07:00"},
  "issues": [{"number": 5}]
}
JSON

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 3 ]
  [ "${#lines[@]}" -eq 1 ]
  case "${lines[0]}" in
  end$'\t'*"no checks"*) ;;
  *) return 1 ;;
  esac
}

@test "a default branch head pushed five minutes ago with no checks makes every Issue wait, even when committed long before" {
  github <<'JSON'
{
  "default_branch": {"committed": "06:00", "pushed": "07:55"},
  "issues": [{"number": 5}, {"number": 6}]
}
JSON

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = wait-base ]
  [ "$(action_of 6)" = wait-base ]
}

@test "a failed check on the default branch head makes no Issue ready" {
  github <<'JSON'
{
  "default_branch": {"checks": {"lint": "success", "test": "failure"}},
  "issues": [{"number": 5}]
}
JSON

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = wait-base ]
}

@test "a running check on the default branch head makes no Issue ready" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "in_progress"}},
  "issues": [{"number": 5}]
}
JSON

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = wait-base ]
}

@test "the oe/verify status on the default branch head does not count as a check" {
  github <<'JSON'
{
  "default_branch": {"pushed": "07:00", "statuses": {"oe/verify": "success"}},
  "issues": [{"number": 5}]
}
JSON

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 3 ]
}

# Failed reads

@test "every failed GitHub read exits non-zero and prints nothing" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{
    "number": 5,
    "branch": true,
    "comments": [
      {"by": "OWNER", "at": "07:00", "body": "<!-- oe:claim -->"},
      {"by": "OWNER", "at": "07:01", "body": "<!-- oe:attempt -->"}
    ],
    "pull_requests": [{"number": 50, "opened": "07:10", "checks": {"test": "success"}}]
  }]
}
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

# Before the claim

@test "an Issue with no branch and every dependency completed is claimed" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{"number": 5, "blocked_by": [{"number": 3, "state": "completed"}]}]
}
JSON

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [ "$(action_of 5)" = claim ]
}

@test "a closed Issue is done" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{"number": 5, "closed": true}]
}
JSON

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = "done" ]
}

@test "an Issue with one open dependency is not ready" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{
    "number": 5,
    "blocked_by": [{"number": 3, "state": "completed"}, {"number": 4, "state": "open"}]
  }]
}
JSON

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = wait-dependencies ]
}

@test "an Issue whose dependency closed as not planned waits instead of being claimed" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{"number": 5, "blocked_by": [{"number": 4, "state": "not_planned"}]}]
}
JSON

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = wait-dependencies ]
}

@test "an Issue whose branch exists without a pull request is not ready to claim and gets an Owner" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{
    "number": 5,
    "branch": true,
    "comments": [{"by": "OWNER", "at": "07:00", "body": "<!-- oe:claim -->"}]
  }]
}
JSON

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = start-owner ]
}

@test "an open Issue whose pull request merged after the latest claim waits for an engineer" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{
    "number": 5,
    "comments": [{"by": "OWNER", "at": "07:00", "body": "<!-- oe:claim -->"}],
    "pull_requests": [{"number": 50, "state": "merged", "opened": "07:10", "merged": "07:40"}]
  }]
}
JSON

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = wait-engineer ]
}

@test "a pull request merged before the latest claim does not hold a restarted Issue" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{
    "number": 5,
    "comments": [{"by": "OWNER", "at": "07:50", "body": "<!-- oe:claim -->"}],
    "pull_requests": [{"number": 50, "state": "merged", "opened": "07:10", "merged": "07:40"}]
  }]
}
JSON

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = claim ]
}

@test "an Issue whose branch exists and whose pull request closed without merging waits for an engineer" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{
    "number": 5,
    "branch": true,
    "comments": [{"by": "OWNER", "at": "07:00", "body": "<!-- oe:claim -->"}],
    "pull_requests": [{"number": 50, "state": "closed", "opened": "07:10"}]
  }]
}
JSON

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = wait-engineer ]
}

@test "a merged pull request from a fork with the Issue's branch name is ignored" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{
    "number": 5,
    "pull_requests": [{"number": 50, "state": "merged", "opened": "07:10", "merged": "07:40", "from_fork": true}]
  }]
}
JSON

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = claim ]
}

@test "an Issue whose agent runs in this session is left out, and the rest come in number order" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{"number": 7}, {"number": 5}, {"number": 6}]
}
JSON

  run bash "${oe}" ready o/r 1 --running 6

  [ "${status}" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[0]%%$'\t'*}" = 5 ]
  [ "${lines[1]%%$'\t'*}" = 7 ]
}

# Verification

@test "a failed check on the pull request head gets an Owner" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{
    "number": 5,
    "branch": true,
    "comments": [
      {"by": "OWNER", "at": "07:00", "body": "<!-- oe:claim -->"},
      {"by": "OWNER", "at": "07:01", "body": "<!-- oe:attempt -->"}
    ],
    "pull_requests": [{"number": 50, "opened": "07:10", "checks": {"lint": "success", "test": "failure"}}]
  }]
}
JSON

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = start-owner ]
}

@test "a failure verdict on the pull request head gets an Owner" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{
    "number": 5,
    "branch": true,
    "comments": [
      {"by": "OWNER", "at": "07:00", "body": "<!-- oe:claim -->"},
      {"by": "OWNER", "at": "07:01", "body": "<!-- oe:attempt -->"}
    ],
    "pull_requests": [{"number": 50, "opened": "07:10", "checks": {"test": "success"}, "verdicts": ["failure", "pending"]}]
  }]
}
JSON

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = start-owner ]
}

@test "a pull request that conflicts with its base gets an Owner" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{
    "number": 5,
    "branch": true,
    "comments": [
      {"by": "OWNER", "at": "07:00", "body": "<!-- oe:claim -->"},
      {"by": "OWNER", "at": "07:01", "body": "<!-- oe:attempt -->"}
    ],
    "pull_requests": [{"number": 50, "opened": "07:10", "checks": {"test": "success"}, "conflicting": true}]
  }]
}
JSON

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = start-owner ]
}

@test "a success verdict on the pull request head waits for the merge" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{
    "number": 5,
    "branch": true,
    "comments": [
      {"by": "OWNER", "at": "07:00", "body": "<!-- oe:claim -->"},
      {"by": "OWNER", "at": "07:01", "body": "<!-- oe:attempt -->"}
    ],
    "pull_requests": [{"number": 50, "opened": "07:10", "checks": {"test": "success"}, "verdicts": ["success", "pending"]}]
  }]
}
JSON

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = wait-merge ]
}

@test "a running check on the pull request head waits for CI" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{
    "number": 5,
    "branch": true,
    "comments": [
      {"by": "OWNER", "at": "07:00", "body": "<!-- oe:claim -->"},
      {"by": "OWNER", "at": "07:01", "body": "<!-- oe:attempt -->"}
    ],
    "pull_requests": [{"number": 50, "opened": "07:10", "checks": {"lint": "success", "test": "in_progress"}}]
  }]
}
JSON

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = wait-ci ]
}

@test "a pull request head pushed five minutes ago with no checks waits for CI, even when committed long before" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{
    "number": 5,
    "branch": true,
    "comments": [
      {"by": "OWNER", "at": "07:00", "body": "<!-- oe:claim -->"},
      {"by": "OWNER", "at": "07:01", "body": "<!-- oe:attempt -->"}
    ],
    "pull_requests": [{"number": 50, "opened": "07:10", "committed": "06:00", "pushed": "07:55"}]
  }]
}
JSON

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = wait-ci ]
}

@test "a pull request head with no checks ten minutes after its push is parked" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{
    "number": 5,
    "branch": true,
    "comments": [
      {"by": "OWNER", "at": "07:00", "body": "<!-- oe:claim -->"},
      {"by": "OWNER", "at": "07:01", "body": "<!-- oe:attempt -->"}
    ],
    "pull_requests": [{"number": 50, "opened": "07:10", "pushed": "07:40"}]
  }]
}
JSON

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = parked ]
}

@test "a Verifier that ended once without a verdict is started again" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{
    "number": 5,
    "branch": true,
    "comments": [
      {"by": "OWNER", "at": "07:00", "body": "<!-- oe:claim -->"},
      {"by": "OWNER", "at": "07:01", "body": "<!-- oe:attempt -->"}
    ],
    "pull_requests": [{"number": 50, "opened": "07:10", "checks": {"test": "success"}, "verdicts": ["pending"]}]
  }]
}
JSON

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = start-verifier ]
}

@test "a Verifier that ended twice without a verdict parks the Issue" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{
    "number": 5,
    "branch": true,
    "comments": [
      {"by": "OWNER", "at": "07:00", "body": "<!-- oe:claim -->"},
      {"by": "OWNER", "at": "07:01", "body": "<!-- oe:attempt -->"}
    ],
    "pull_requests": [{"number": 50, "opened": "07:10", "checks": {"test": "success"}, "verdicts": ["pending", "pending"]}]
  }]
}
JSON

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = parked ]
}

# Attempts

@test "three attempts after the latest claim park an Issue that still needs repair" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{
    "number": 5,
    "branch": true,
    "comments": [
      {"by": "OWNER", "at": "07:00", "body": "<!-- oe:claim -->"},
      {"by": "OWNER", "at": "07:01", "body": "<!-- oe:attempt -->"},
      {"by": "OWNER", "at": "07:20", "body": "<!-- oe:attempt -->"},
      {"by": "OWNER", "at": "07:40", "body": "<!-- oe:attempt -->"}
    ],
    "pull_requests": [{"number": 50, "opened": "07:10", "checks": {"test": "success"}, "verdicts": ["failure"]}]
  }]
}
JSON

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = parked ]
}

@test "attempts before the latest claim do not count toward the cap" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{
    "number": 5,
    "branch": true,
    "comments": [
      {"by": "OWNER", "at": "06:00", "body": "<!-- oe:claim -->"},
      {"by": "OWNER", "at": "06:01", "body": "<!-- oe:attempt -->"},
      {"by": "OWNER", "at": "06:20", "body": "<!-- oe:attempt -->"},
      {"by": "OWNER", "at": "06:40", "body": "<!-- oe:attempt -->"},
      {"by": "OWNER", "at": "07:00", "body": "<!-- oe:claim -->"},
      {"by": "OWNER", "at": "07:00", "body": "<!-- oe:attempt -->"}
    ],
    "pull_requests": [{"number": 50, "opened": "07:10", "checks": {"test": "success"}, "verdicts": ["failure"]}]
  }]
}
JSON

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = start-owner ]
}

@test "an attempt record by an untrusted author does not count toward the cap" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{
    "number": 5,
    "branch": true,
    "comments": [
      {"by": "OWNER", "at": "07:00", "body": "<!-- oe:claim -->"},
      {"by": "OWNER", "at": "07:01", "body": "<!-- oe:attempt -->"},
      {"by": "OWNER", "at": "07:20", "body": "<!-- oe:attempt -->"},
      {"by": "NONE", "at": "07:40", "body": "<!-- oe:attempt -->"}
    ],
    "pull_requests": [{"number": 50, "opened": "07:10", "checks": {"test": "success"}, "verdicts": ["failure"]}]
  }]
}
JSON

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = start-owner ]
}

# Engineer input

@test "a question with no later comment waits for the answer" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{
    "number": 5,
    "branch": true,
    "comments": [
      {"by": "OWNER", "at": "07:00", "body": "<!-- oe:claim -->"},
      {"by": "OWNER", "at": "07:01", "body": "<!-- oe:attempt -->"},
      {"by": "OWNER", "at": "07:10", "body": "<!-- oe:question -->\nWhich option?"}
    ]
  }]
}
JSON

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = wait-answer ]
}

@test "a marked or untrusted comment after a question does not answer it" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{
    "number": 5,
    "branch": true,
    "comments": [
      {"by": "OWNER", "at": "07:00", "body": "<!-- oe:claim -->"},
      {"by": "OWNER", "at": "07:01", "body": "<!-- oe:attempt -->"},
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

@test "an unmarked trusted answer after the latest attempt gets an Owner, even on a verified pull request" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{
    "number": 5,
    "branch": true,
    "comments": [
      {"by": "OWNER", "at": "07:00", "body": "<!-- oe:claim -->"},
      {"by": "OWNER", "at": "07:01", "body": "<!-- oe:attempt -->"},
      {"by": "OWNER", "at": "07:10", "body": "<!-- oe:question -->\nWhich option?"},
      {"by": "MEMBER", "at": "07:20", "body": "Use option A"}
    ],
    "pull_requests": [{"number": 50, "opened": "07:10", "checks": {"test": "success"}, "verdicts": ["success"]}]
  }]
}
JSON

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = start-owner ]
}

@test "an answer that an earlier attempt already took does not start another Owner" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{
    "number": 5,
    "branch": true,
    "comments": [
      {"by": "OWNER", "at": "07:00", "body": "<!-- oe:claim -->"},
      {"by": "OWNER", "at": "07:01", "body": "<!-- oe:attempt -->"},
      {"by": "OWNER", "at": "07:02", "body": "<!-- oe:question -->\nWhich option?"},
      {"by": "MEMBER", "at": "07:03", "body": "Use option A"},
      {"by": "OWNER", "at": "07:04", "body": "<!-- oe:attempt -->"}
    ],
    "pull_requests": [{"number": 50, "opened": "07:10", "checks": {"test": "success"}, "verdicts": ["success"]}]
  }]
}
JSON

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = wait-merge ]
}

@test "a trusted Changes requested review after the latest attempt gets an Owner" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{
    "number": 5,
    "branch": true,
    "comments": [
      {"by": "OWNER", "at": "07:00", "body": "<!-- oe:claim -->"},
      {"by": "OWNER", "at": "07:30", "body": "<!-- oe:attempt -->"}
    ],
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

@test "a Changes requested review before the latest attempt does not start another Owner" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{
    "number": 5,
    "branch": true,
    "comments": [
      {"by": "OWNER", "at": "07:00", "body": "<!-- oe:claim -->"},
      {"by": "OWNER", "at": "07:30", "body": "<!-- oe:attempt -->"}
    ],
    "pull_requests": [{
      "number": 50, "opened": "07:10", "checks": {"test": "success"}, "verdicts": ["success"],
      "reviews": [{"by": "MEMBER", "at": "07:20", "body": "Rename this"}]
    }]
  }]
}
JSON

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = wait-merge ]
}

@test "a trusted review-thread comment after the latest attempt gets an Owner" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{
    "number": 5,
    "branch": true,
    "comments": [
      {"by": "OWNER", "at": "07:00", "body": "<!-- oe:claim -->"},
      {"by": "OWNER", "at": "07:30", "body": "<!-- oe:attempt -->"}
    ],
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

@test "an untrusted review-thread comment does not start an Owner" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{
    "number": 5,
    "branch": true,
    "comments": [
      {"by": "OWNER", "at": "07:00", "body": "<!-- oe:claim -->"},
      {"by": "OWNER", "at": "07:30", "body": "<!-- oe:attempt -->"}
    ],
    "pull_requests": [{
      "number": 50, "opened": "07:10", "checks": {"test": "success"}, "verdicts": ["success"],
      "thread_comments": [{"by": "NONE", "at": "07:40", "body": "This leaks the token"}]
    }]
  }]
}
JSON

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = wait-merge ]
}

# A push during the read

@test "a push during the read does not hide a pending question" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{
    "number": 5,
    "branch": true,
    "comments": [
      {"by": "OWNER", "at": "07:00", "body": "<!-- oe:claim -->"},
      {"by": "OWNER", "at": "07:01", "body": "<!-- oe:attempt -->"},
      {"by": "OWNER", "at": "07:30", "body": "<!-- oe:question -->\nWhich option?"}
    ],
    "pull_requests": [{"number": 50, "opened": "07:10", "checks": {"test": "success"}, "pushed_during_read": true}]
  }]
}
JSON

  run bash "${oe}" ready o/r 1

  [ "${status}" -eq 0 ]
  [ "$(action_of 5)" = wait-answer ]
}

@test "a push during the read fails the read when the action depends on the head" {
  github <<'JSON'
{
  "default_branch": {"checks": {"test": "success"}},
  "issues": [{
    "number": 5,
    "branch": true,
    "comments": [
      {"by": "OWNER", "at": "07:00", "body": "<!-- oe:claim -->"},
      {"by": "OWNER", "at": "07:01", "body": "<!-- oe:attempt -->"}
    ],
    "pull_requests": [{"number": 50, "opened": "07:10", "checks": {"test": "success"}, "pushed_during_read": true}]
  }]
}
JSON

  run --separate-stderr bash "${oe}" ready o/r 1

  [ "${status}" -eq 1 ]
  [ -z "${output}" ]
}
