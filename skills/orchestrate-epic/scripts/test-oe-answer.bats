#!/usr/bin/env bats
# Tests for oe question recording the person's answer, given in the session's conversation, on the Issue and its decision in the Issue body.
#
# - Each test writes the GitHub state it needs as JSON and the host-local records it needs, then runs oe against them.
# - testdata/fake-gh.sh stands in for gh, answers every read from that state, and applies every write to it.
# - git config skills.lang sets the reader's language, through the environment, so the user's config never leaks in.
# - Every comment oe writes is by the OWNER at 08:00, and every test runs at 08:00.
# shellcheck disable=SC2292 # bats fails a test on a mid-test `[[ ]]` only under bash 4.1+; `[ ]` works on every bash.

setup() {
  bats_require_minimum_version 1.5.0
  load testdata/records
  export OE_STATE_DIR="${BATS_TEST_TMPDIR}/state"
  oe="${BATS_TEST_DIRNAME}/oe"
  mkdir -p "${BATS_TEST_TMPDIR}/bin"
  printf '#!/usr/bin/env bash\nexec bash "%s/testdata/fake-gh.sh" "$@"\n' "${BATS_TEST_DIRNAME}" >"${BATS_TEST_TMPDIR}/bin/gh"
  chmod +x "${BATS_TEST_TMPDIR}/bin/gh"
  export PATH="${BATS_TEST_TMPDIR}/bin:${PATH}"
  export OE_GITHUB="${BATS_TEST_TMPDIR}/github.json"
  # 2027-01-15 08:00 UTC
  export OE_NOW=1800000000
  export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=skills.lang GIT_CONFIG_VALUE_0=en
  printf '%s\n' '{"default_branch": {"checks": {"test": "success"}}, "issues": [{"number": 5, "branch": true}]}' >"${OE_GITHUB}"
  records 5 claim@07:00 attempt@07:01
}

# Writes an Owner's question with options A and B on Issue 5 through oe question.
ask() {
  bash "${oe}" question o/r 5 >/dev/null <<'EOF'
Decision: The nightly export fails on a full folder: how should it respond?

Context:
- Goal: the sales team reads yesterday's orders each morning.
- Stage: the export runs nightly but has no error handling.
- Why now: last night the folder filled up, and nobody was told.

Criteria:
- Failures are noticed quickly.

Options:
- A. Email the team on failure
  - Noticed within minutes; deletes nothing.
- B. Leave it as is
  - No work; failures found the next morning.

Recommendation: A, email the team; it meets the criterion.

Agreement: Shall I email the team on failure? If not, which option?
EOF
}

# Prints how many comments Issue 5 has in the saved GitHub state.
comment_count() {
  jq '.issues[0].comments // [] | length' "${OE_GITHUB}"
}

# Prints the body of the newest comment on Issue 5 in the saved GitHub state.
last_comment() {
  jq -r '.issues[0].comments | last | .body' "${OE_GITHUB}"
}

# Prints the action that oe ready gives Issue 5.
action_of_5() {
  bash "${oe}" ready o/r 1 | while IFS=$'\t' read -r n action _; do
    if [ "${n}" = 5 ]; then
      echo "${action}"
    fi
  done
}

@test "an answer by an option's letter is written on the Issue, and oe ready reads it as the engineer's answer" {
  ask
  [ "$(action_of_5)" = wait-answer ]

  run bash "${oe}" question o/r 5 --answer b

  [ "${status}" -eq 0 ]
  [ "${output%%$'\t'*}" = answer ]
  [ "$(comment_count)" -eq 2 ]
  body="$(last_comment)"
  [ "${body%%$'\n'*}" = "<!-- oe:answer -->" ]
  [ "${body}" != "${body#*$'\n'B. Leave it as is$'\n'}" ]
  [ "${body}" != "${body#*https://github.com/o/r/issues/5#issuecomment-1}" ]
  [ "$(action_of_5)" = start-owner ]
}

@test "a free-text answer is written as given, and oe ready reads it as the engineer's answer" {
  ask

  run bash "${oe}" question o/r 5 --answer "Email the team, and keep files for 30 days"

  [ "${status}" -eq 0 ]
  body="$(last_comment)"
  [ "${body%%$'\n'*}" = "<!-- oe:answer -->" ]
  [ "${body}" != "${body#*$'\n'Email the team, and keep files for 30 days$'\n'}" ]
  [ "$(action_of_5)" = start-owner ]
}

@test "a letter that no option has is refused and writes nothing" {
  ask

  run bash "${oe}" question o/r 5 --answer C

  [ "${status}" -eq 2 ]
  [ "$(comment_count)" -eq 1 ]
}

@test "an empty answer is refused and writes nothing" {
  ask

  run bash "${oe}" question o/r 5 --answer "  "

  [ "${status}" -eq 2 ]
  [ "$(comment_count)" -eq 1 ]
}

@test "a question from before the latest claim gets no answer" {
  ask
  records 5 claim@08:30

  run bash "${oe}" question o/r 5 --answer A

  [ "${status}" -eq 3 ]
  [ "$(comment_count)" -eq 1 ]
}

@test "an Issue without a question gets no answer" {
  run bash "${oe}" question o/r 5 --answer A

  [ "${status}" -eq 3 ]
  [ "$(comment_count)" -eq 0 ]
}

# Sets the body of Issue 5 in the saved GitHub state to $1.
issue_body() {
  jq --arg body "$1" '.issues[0].body = $body' "${OE_GITHUB}" >"${OE_GITHUB}.new" && mv "${OE_GITHUB}.new" "${OE_GITHUB}"
}

# Prints the body of Issue 5 in the saved GitHub state.
body_of_5() {
  jq -r '.issues[0].body // ""' "${OE_GITHUB}"
}

criteria_body='## Background

Exports fail silently.

## Acceptance Criteria

- The export retries once.'

decisions_note="Decisions the engineer made on this Issue's questions. Each takes precedence over the criteria it contradicts, and a later one over an earlier one."

@test "an answer by an option's letter appends the decision line and the chosen option to a decisions section, leaving the rest of the body as it was" {
  issue_body "${criteria_body}"
  ask

  run bash "${oe}" question o/r 5 --answer b

  [ "${status}" -eq 0 ]
  [ "$(body_of_5)" = "${criteria_body}

## Decisions

${decisions_note}

- Decision: The nightly export fails on a full folder: how should it respond?
  - B. Leave it as is
  - https://github.com/o/r/issues/5#issuecomment-1" ]
}

@test "a second answer appends its decision after the first and keeps the first" {
  issue_body "${criteria_body}"
  ask
  bash "${oe}" question o/r 5 --answer A >/dev/null
  ask

  run bash "${oe}" question o/r 5 --answer "Email the team, and keep files for 30 days"

  [ "${status}" -eq 0 ]
  [ "$(body_of_5)" = "${criteria_body}

## Decisions

${decisions_note}

- Decision: The nightly export fails on a full folder: how should it respond?
  - A. Email the team on failure
  - https://github.com/o/r/issues/5#issuecomment-1
- Decision: The nightly export fails on a full folder: how should it respond?
  - Email the team, and keep files for 30 days
  - https://github.com/o/r/issues/5#issuecomment-3" ]
}

@test "a decisions section followed by another section gets the new decision at its own end" {
  issue_body "## Decisions

${decisions_note}

- Decision: Which folder?
  - A. The shared one
  - https://github.com/o/r/issues/5#issuecomment-9

## Notes

Keep this."
  ask

  run bash "${oe}" question o/r 5 --answer B

  [ "${status}" -eq 0 ]
  [ "$(body_of_5)" = "## Decisions

${decisions_note}

- Decision: Which folder?
  - A. The shared one
  - https://github.com/o/r/issues/5#issuecomment-9
- Decision: The nightly export fails on a full folder: how should it respond?
  - B. Leave it as is
  - https://github.com/o/r/issues/5#issuecomment-1

## Notes

Keep this." ]
}

@test "a multi-line free-text answer stays inside its decision" {
  issue_body "${criteria_body}"
  ask

  run bash "${oe}" question o/r 5 --answer "Email the team.
Keep files for 30 days."

  [ "${status}" -eq 0 ]
  [ "$(body_of_5)" = "${criteria_body}

## Decisions

${decisions_note}

- Decision: The nightly export fails on a full folder: how should it respond?
  - Email the team.
    Keep files for 30 days.
  - https://github.com/o/r/issues/5#issuecomment-1" ]
}

@test "in Japanese the decisions section has a Japanese heading and note" {
  export GIT_CONFIG_VALUE_0=ja
  issue_body "## 背景

書き出しが黙って失敗する。"
  bash "${oe}" question o/r 5 >/dev/null <<'EOF'
判断: 夜間の書き出しが満杯のフォルダで失敗したとき、どう対応するか

背景:
- 目的: 営業チームが毎朝前日の注文を読む
- 段階: 書き出しは毎晩動くが、失敗時の処理がない
- 今聞く理由: 昨夜フォルダが満杯になり、誰も気づかなかった

基準:
- 失敗にすぐ気づける

選択肢:
- A. 失敗時にチームへメールする
  - 数分で気づき、何も消さない
- B. 今のままにする
  - 作業なし、翌朝まで気づかない

推奨: A。基準を満たすため

合意: 失敗時にメールしてよいですか。違う場合はどの選択肢にしますか
EOF

  run bash "${oe}" question o/r 5 --answer A

  [ "${status}" -eq 0 ]
  [ "$(body_of_5)" = "## 背景

書き出しが黙って失敗する。

## 決定事項

このIssueの質問にエンジニアが出した決定です。各決定は矛盾する基準より優先し、後の決定は先の決定より優先します。

- 判断: 夜間の書き出しが満杯のフォルダで失敗したとき、どう対応するか
  - A. 失敗時にチームへメールする
  - https://github.com/o/r/issues/5#issuecomment-1" ]
}

@test "when writing the answer fails after the decision, a rerun records the answer without a second decision" {
  issue_body "${criteria_body}"
  ask
  expected="${criteria_body}

## Decisions

${decisions_note}

- Decision: The nightly export fails on a full folder: how should it respond?
  - B. Leave it as is
  - https://github.com/o/r/issues/5#issuecomment-1"

  GH_FAIL="-X POST" run bash "${oe}" question o/r 5 --answer B

  [ "${status}" -eq 1 ]
  [ "$(comment_count)" -eq 1 ]
  [ "$(body_of_5)" = "${expected}" ]

  run bash "${oe}" question o/r 5 --answer B

  [ "${status}" -eq 0 ]
  [ "$(comment_count)" -eq 2 ]
  [ "$(body_of_5)" = "${expected}" ]
}

@test "when writing the decision fails, no answer is written" {
  issue_body "${criteria_body}"
  ask

  GH_FAIL="-X PATCH" run bash "${oe}" question o/r 5 --answer B

  [ "${status}" -eq 1 ]
  [ "$(comment_count)" -eq 1 ]
  [ "$(body_of_5)" = "${criteria_body}" ]
}
