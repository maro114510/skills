#!/usr/bin/env bats
# Tests for oe question writing an Owner's question.
#
# - Each test writes the GitHub state it needs as JSON, then runs oe question against it.
# - testdata/fake-gh.sh stands in for gh, answers every read from that state, and applies every write to it.
# - git config skills.lang sets the reader's language, through the environment, so the user's config never leaks in.
# - Every comment oe writes is by the OWNER at 08:00.
# shellcheck disable=SC2292 # bats fails a test on a mid-test `[[ ]]` only under bash 4.1+; `[ ]` works on every bash.

setup() {
  bats_require_minimum_version 1.5.0
  oe="${BATS_TEST_DIRNAME}/oe"
  mkdir -p "${BATS_TEST_TMPDIR}/bin"
  printf '#!/usr/bin/env bash\nexec bash "%s/testdata/fake-gh.sh" "$@"\n' "${BATS_TEST_DIRNAME}" >"${BATS_TEST_TMPDIR}/bin/gh"
  chmod +x "${BATS_TEST_TMPDIR}/bin/gh"
  export PATH="${BATS_TEST_TMPDIR}/bin:${PATH}"
  export OE_GITHUB="${BATS_TEST_TMPDIR}/github.json"
  printf '%s\n' '{"issues": [{"number": 5, "branch": true}]}' >"${OE_GITHUB}"
  reader en
}

# Sets the reader's language to $1 through git config skills.lang.
reader() {
  export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=skills.lang GIT_CONFIG_VALUE_0="$1"
}

# Prints how many comments Issue 5 has in the saved GitHub state.
comment_count() {
  jq '.issues[0].comments // [] | length' "${OE_GITHUB}"
}

# Prints the body of the newest comment on Issue 5 in the saved GitHub state.
last_comment() {
  jq -r '.issues[0].comments | last | .body' "${OE_GITHUB}"
}

# Prints a question in the template's structure, in English, with a letter on each option.
english_question() {
  cat <<'EOF'
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

# Prints the same question in Japanese.
japanese_question() {
  cat <<'EOF'
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
}

@test "a question in the template's structure is written with a letter on each option" {
  run bash "${oe}" question o/r 5 < <(english_question)

  [ "${status}" -eq 0 ]
  [ "${output}" = $'question\thttps://github.com/o/r/issues/5#issuecomment-1' ]
  [ "$(comment_count)" -eq 1 ]
  body="$(last_comment)"
  [ "${body%%$'\n'*}" = "<!-- oe:question -->" ]
  [ "${body}" != "${body#*$'\n- A. Email the team on failure\n'}" ]
  [ "${body}" != "${body#*$'\n- B. Leave it as is\n'}" ]
}

@test "a question in Japanese is written for a Japanese reader" {
  reader ja

  run bash "${oe}" question o/r 5 < <(japanese_question)

  [ "${status}" -eq 0 ]
  [ "$(comment_count)" -eq 1 ]
  body="$(last_comment)"
  [ "${body}" != "${body#*$'\n- A. 失敗時にチームへメールする\n'}" ]
}

@test "a question missing a template part is refused and writes nothing" {
  run bash "${oe}" question o/r 5 < <(english_question | sed '/^Criteria:/,/^$/d')

  [ "${status}" -eq 2 ]
  [ "$(comment_count)" -eq 0 ]
}

@test "a question holding two decisions is refused and writes nothing" {
  run bash "${oe}" question o/r 5 < <(english_question && echo && english_question)

  [ "${status}" -eq 2 ]
  [ "${output}" != "${output#*one decision}" ]
  [ "$(comment_count)" -eq 0 ]
}

@test "an option without its letter is refused and writes nothing" {
  run bash "${oe}" question o/r 5 < <(english_question | sed 's/^- B\. /- /')

  [ "${status}" -eq 2 ]
  [ "$(comment_count)" -eq 0 ]
}

@test "options lettered out of order are refused and write nothing" {
  run bash "${oe}" question o/r 5 < <(english_question | sed 's/^- B\. /- C. /')

  [ "${status}" -eq 2 ]
  [ "$(comment_count)" -eq 0 ]
}

@test "an option without the line on how it fares is refused and writes nothing" {
  run bash "${oe}" question o/r 5 < <(english_question | sed '/Noticed within minutes/d')

  [ "${status}" -eq 2 ]
  [ "$(comment_count)" -eq 0 ]
}

@test "a question in another language than the reader's is refused and writes nothing" {
  run bash "${oe}" question o/r 5 < <(japanese_question)

  [ "${status}" -eq 2 ]
  [ "$(comment_count)" -eq 0 ]

  reader ja
  run bash "${oe}" question o/r 5 < <(english_question)

  [ "${status}" -eq 2 ]
  [ "$(comment_count)" -eq 0 ]
}

@test "an empty question is refused and writes nothing" {
  run bash "${oe}" question o/r 5 </dev/null

  [ "${status}" -eq 2 ]
  [ "$(comment_count)" -eq 0 ]
}

@test "a failed GitHub write exits 1" {
  export GH_FAIL=issues/5/comments

  run bash "${oe}" question o/r 5 < <(english_question)

  [ "${status}" -eq 1 ]
}
