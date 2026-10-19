#!/usr/bin/env bats
# Tests for epic-freeze.sh. Each case builds an Epic comment list with jq and classifies it.
# shellcheck disable=SC2292 # bats fails a test on a mid-test `[[ ]]` only under bash 4.1+; `[ ]` works on every bash.

setup() {
  target="${BATS_TEST_DIRNAME}/epic-freeze.sh"
  comments='[]'
}

# Appends one comment. $1 id, $2 created_at, $3 author login, $4 author_association, $5 body.
add() {
  comments="$(jq -c --argjson id "$1" --arg at "$2" --arg login "$3" --arg assoc "$4" --arg body "$5" \
    '. + [{id: $id, created_at: $at, updated_at: $at, author_association: $assoc, user: {login: $login}, body: $body}]' \
    <<<"${comments}")"
}

# A ledger comment by the loop identity. $1 id, $2 release, $3-$5 worker, reviewer, fix as used/bound.
ledger() {
  add "$1" 2026-10-01T00:00:00Z loop OWNER "$(printf '%s\n' '<!-- orchestrate-epic:ledger -->' \
    'orchestrate-epic ledger:' "- release: $2" "- worker_dispatches: ${3/\// / }" \
    "- reviewer_passes: ${4/\// / }" "- fix_cycles: ${5/\// / }")"
}

# A freeze comment by $3 (default the loop identity). $1 id, $2 created_at.
freeze() {
  add "$1" "$2" "${3:-loop}" OWNER "$(printf '%s\n' '<!-- orchestrate-epic:freeze -->' \
    'orchestrate-epic: この Epic を凍結しました。' '- reason: fix_cycles 4 + 1 > 4' \
    '- worker_dispatches: 6 / 10' '- reviewer_passes: 5 / 8' '- fix_cycles: 4 / 4')"
}

classify() {
  run bash "${target}" --snapshot - --me loop "$@" <<<"${comments}"
}

has_line() {
  printf '%s\n' "${lines[@]}" | grep -qxF -- "$1"
}

lacks_prefix() {
  ! printf '%s\n' "${lines[@]}" | grep -q "^$1"
}

reason_has() {
  case "$(printf '%s\n' "${lines[@]}" | sed -n 's/^reason=//p' | head -n1)" in
  *"$1"*) return 0 ;;
  *) return 1 ;;
  esac
}

@test "rejects bad arguments with exit 2" {
  run bash "${target}"
  [ "${status}" -eq 2 ]
  run bash "${target}" owner/repo
  [ "${status}" -eq 2 ]
  run bash "${target}" noslash 7
  [ "${status}" -eq 2 ]
  run bash "${target}" owner/repo 0
  [ "${status}" -eq 2 ]
  run bash "${target}" --snapshot - <<<'[]'
  [ "${status}" -eq 2 ]
  run bash "${target}" --snapshot "${BATS_TEST_TMPDIR}/missing.json" --me loop
  [ "${status}" -eq 2 ]
  classify tokens=1
  [ "${status}" -eq 2 ]
  classify fix_cycles=0
  [ "${status}" -eq 2 ]
  classify fix_cycles=x
  [ "${status}" -eq 2 ]
}

@test "an Epic with no freeze and no ledger is CLEAR" {
  classify
  [ "${status}" -eq 0 ]
  has_line status=CLEAR
  has_line freeze_id=none
  has_line release_id=none
  has_line ledger_id=none
}

@test "reads cumulative counts back from the ledger" {
  ledger 11 none 3/10 2/8 1/4
  classify
  [ "${status}" -eq 0 ]
  has_line status=CLEAR
  has_line ledger_id=11
  has_line ledger_release=none
  has_line worker_dispatches=3/10
  has_line reviewer_passes=2/8
  has_line fix_cycles=1/4
}

@test "a reservation within every bound is ok" {
  ledger 11 none 3/10 2/8 1/4
  classify worker_dispatches=7 fix_cycles=3
  [ "${status}" -eq 0 ]
  has_line status=CLEAR
  has_line reserve=ok
}

@test "a resumed run that already used the fix-cycle bound cannot exceed it" {
  ledger 11 none 6/10 5/8 4/4
  classify worker_dispatches=1 fix_cycles=1
  [ "${status}" -eq 0 ]
  has_line status=CLEAR
  has_line reserve=exceed
  reason_has "fix_cycles 4 + 1 > 4"
}

@test "one exceeding counter rejects the whole reservation" {
  ledger 11 none 9/10 2/8 0/4
  classify worker_dispatches=2 reviewer_passes=1
  has_line reserve=exceed
  reason_has "worker_dispatches 9 + 2 > 10"
}

@test "a reservation without a ledger is unreadable" {
  classify worker_dispatches=1
  [ "${status}" -eq 1 ]
  has_line status=UNREADABLE
  lacks_prefix reserve=
}

@test "a frozen Epic stays FROZEN on re-invocation and evaluates no reservation" {
  ledger 11 none 6/10 5/8 4/4
  freeze 20 2026-10-02T00:00:00Z
  classify worker_dispatches=1
  [ "${status}" -eq 0 ]
  has_line status=FROZEN
  has_line freeze_id=20
  has_line release_id=none
  reason_has "fix_cycles 4 + 1 > 4"
  lacks_prefix reserve=
}

@test "a freeze without a recorded reason is still FROZEN" {
  add 20 2026-10-02T00:00:00Z loop OWNER '<!-- orchestrate-epic:freeze -->'
  classify
  has_line status=FROZEN
  reason_has unrecorded
}

@test "a freeze marker posted by someone else is ignored" {
  freeze 20 2026-10-02T00:00:00Z mallory
  classify
  has_line status=CLEAR
  has_line freeze_id=none
}

@test "a ledger posted by someone else is ignored" {
  add 12 2026-10-01T00:00:00Z mallory OWNER "$(printf '%s\n' '<!-- orchestrate-epic:ledger -->' \
    '- release: none' '- worker_dispatches: 0 / 99' '- reviewer_passes: 0 / 99' '- fix_cycles: 0 / 99')"
  classify
  has_line ledger_id=none
}

@test "the latest ledger by the loop identity wins" {
  ledger 11 none 3/10 2/8 1/4
  ledger 13 none 4/10 3/8 1/4
  classify
  has_line ledger_id=13
  has_line worker_dispatches=4/10
}

@test "a ledger saved with CRLF line endings still parses" {
  add 11 2026-10-01T00:00:00Z loop OWNER "$(printf '%s\r\n' '<!-- orchestrate-epic:ledger -->' \
    '- release: none' '- worker_dispatches: 1 / 10' '- reviewer_passes: 0 / 8' '- fix_cycles: 0 / 4')"
  classify fix_cycles=1
  [ "${status}" -eq 0 ]
  has_line worker_dispatches=1/10
  has_line reserve=ok
}

@test "a ledger missing a counter is unreadable" {
  add 11 2026-10-01T00:00:00Z loop OWNER "$(printf '%s\n' '<!-- orchestrate-epic:ledger -->' \
    '- release: none' '- worker_dispatches: 1 / 10' '- fix_cycles: 0 / 4')"
  classify
  [ "${status}" -eq 1 ]
  has_line status=UNREADABLE
  reason_has reviewer_passes
}

@test "input that is not a comment array is unreadable" {
  run bash "${target}" --snapshot - --me loop <<<'not json'
  [ "${status}" -eq 1 ]
  has_line status=UNREADABLE
  run bash "${target}" --snapshot - --me loop <<<'{"message":"Not Found"}'
  [ "${status}" -eq 1 ]
  has_line status=UNREADABLE
}

@test "a trusted epic-release after the freeze asks for a ledger reset" {
  ledger 11 none 6/10 5/8 4/4
  freeze 20 2026-10-02T00:00:00Z
  add 30 2026-10-03T00:00:00Z alice MEMBER 'epic-release'
  classify worker_dispatches=1
  [ "${status}" -eq 0 ]
  has_line status=RELEASE
  has_line freeze_id=20
  has_line release_id=30
  lacks_prefix reserve=
}

@test "a release the ledger already recorded is CLEAR, and its reset budget applies" {
  freeze 20 2026-10-02T00:00:00Z
  add 30 2026-10-03T00:00:00Z alice MEMBER 'epic-release'
  ledger 31 30 0/10 0/8 0/4
  classify fix_cycles=1
  has_line status=CLEAR
  has_line release_id=30
  has_line reserve=ok
}

@test "the earliest release after the freeze is the one that lifts it" {
  freeze 20 2026-10-02T00:00:00Z
  add 30 2026-10-03T00:00:00Z alice MEMBER 'epic-release'
  add 32 2026-10-04T00:00:00Z bob OWNER 'epic-release'
  ledger 31 30 0/10 0/8 0/4
  classify
  has_line status=CLEAR
  has_line release_id=30
}

@test "a new freeze after a processed release is FROZEN again" {
  freeze 20 2026-10-02T00:00:00Z
  add 30 2026-10-03T00:00:00Z alice MEMBER 'epic-release'
  ledger 31 30 10/10 0/8 0/4
  freeze 40 2026-10-05T00:00:00Z
  classify
  has_line status=FROZEN
  has_line freeze_id=40
  has_line release_id=none
}

@test "a release posted before the freeze does not lift it" {
  add 19 2026-10-01T12:00:00Z alice MEMBER 'epic-release'
  freeze 20 2026-10-02T00:00:00Z
  classify
  has_line status=FROZEN
}

@test "a release in the same second as the freeze counts only when posted after it" {
  add 19 2026-10-02T00:00:00Z alice MEMBER 'epic-release'
  freeze 20 2026-10-02T00:00:00Z
  classify
  has_line status=FROZEN
  add 21 2026-10-02T00:00:00Z alice MEMBER 'epic-release'
  classify
  has_line status=RELEASE
  has_line release_id=21
}

@test "an untrusted author cannot release" {
  freeze 20 2026-10-02T00:00:00Z
  add 30 2026-10-03T00:00:00Z eve CONTRIBUTOR 'epic-release'
  add 31 2026-10-03T00:00:01Z eve NONE 'epic-release'
  classify
  has_line status=FROZEN
}

@test "only a comment that is exactly epic-release releases" {
  freeze 20 2026-10-02T00:00:00Z
  add 30 2026-10-03T00:00:00Z alice MEMBER "let's not epic-release yet"
  add 31 2026-10-03T00:00:01Z alice MEMBER 'EPIC-RELEASE'
  add 32 2026-10-03T00:00:02Z alice MEMBER "$(printf '%s\n' epic-release epic-approve)"
  add 33 2026-10-03T00:00:03Z alice MEMBER 'orchestrate-epic: epic-release'
  classify
  has_line status=FROZEN
  add 34 2026-10-03T00:00:04Z alice MEMBER "$(printf '  epic-release  \n\nepic-release\n')"
  classify
  has_line status=RELEASE
  has_line release_id=34
}

@test "the loop identity's own epic-release comment counts when its author is trusted" {
  freeze 20 2026-10-02T00:00:00Z
  add 30 2026-10-03T00:00:00Z loop OWNER 'epic-release'
  classify
  has_line status=RELEASE
}
