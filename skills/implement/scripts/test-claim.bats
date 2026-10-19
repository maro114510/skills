#!/usr/bin/env bats
# Tests for claim.sh, against a throwaway repo whose origin is a local bare repo.
# shellcheck disable=SC2292 # bats fails a test on a mid-test `[[ ]]` only under bash 4.1+; `[ ]` works on every bash.

setup() {
  target="${BATS_TEST_DIRNAME}/claim.sh"
  work="${BATS_TEST_TMPDIR}"
  ref=refs/claims/issue-7
  git init -q --bare "${work}/origin.git"
  repo="${work}/repo"
  git init -q -b main "${repo}"
  git -C "${repo}" -c core.hooksPath=/dev/null -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
  git -C "${repo}" remote add origin "${work}/origin.git"
  git -C "${repo}" push -q origin main
  cd "${repo}" || return 1
  # A fake herdr answers from files in ${herdr_dir}, so no test depends on a real herdr server.
  # Tests start outside herdr and outside any harness; the ones that need a pane or a harness session set them.
  unset HERDR_PANE_ID CLAUDE_CODE_SESSION_ID CODEX_THREAD_ID
  herdr_dir="${work}/herdr"
  mkdir -p "${work}/bin" "${herdr_dir}"
  cat >"${work}/bin/herdr" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
"pane get") f="${FAKE_HERDR_DIR}/get-$3" ;;
"pane list") f="${FAKE_HERDR_DIR}/list" ;;
"pane process-info") f="${FAKE_HERDR_DIR}/process-$4" ;;
*) exit 2 ;;
esac
# Like the real herdr, errors go to stderr and leave stdout empty.
if [[ ! -f "${f}.json" ]]; then
  echo '{"error":{"code":"pane_not_found","message":"pane not found"}}' >&2
  exit 1
fi
rc="$(cat "${f}.rc" 2>/dev/null || echo 0)"
if [[ "${rc}" == 0 ]]; then
  cat "${f}.json"
else
  cat "${f}.json" >&2
fi
exit "${rc}"
EOF
  chmod +x "${work}/bin/herdr"
  export FAKE_HERDR_DIR="${herdr_dir}" PATH="${work}/bin:${PATH}"
}

# Prints one herdr pane object: pane id $1, agent session $2 (empty for none), status $3, agent $4 (default claude,
# "-" for a pane with no agent).
pane_object() {
  jq -nc --arg p "$1" --arg s "$2" --arg st "$3" --arg a "${4:-claude}" \
    '{pane_id: $p, agent: (if $a == "-" then null else $a end), agent_status: $st,
      agent_session: (if $s == "" then null else {agent: $a, kind: "id", value: $s} end)}'
}

# Rewrites the fake herdr's pane list from the panes it currently shows.
list_panes() {
  local f
  for f in "${herdr_dir}"/get-*.json; do
    [ -f "${f}" ] && jq -c .result.pane "${f}"
  done | jq -sc '{result: {panes: ., type: "pane_list"}}' >"${herdr_dir}/list.json"
}

# Makes the fake herdr show pane $1 running session $2 with status $3, with this test's process as the pane's shell.
show_pane() {
  jq -nc --argjson pane "$(pane_object "$@")" '{result: {pane: $pane, type: "pane_info"}}' >"${herdr_dir}/get-$1.json"
  pane_shell "$1" $$
  list_panes
}

# Makes the fake herdr report process $2 as the shell of pane $1.
pane_shell() {
  jq -nc --arg p "$1" --argjson pid "$2" '{result: {process_info: {pane_id: $p, shell_pid: $pid}, type: "pane_process_info"}}' \
    >"${herdr_dir}/process-$1.json"
}

# Makes the fake herdr report pane $1 as closed.
close_pane() {
  rm "${herdr_dir}/get-$1.json"
  list_panes
}

# Makes the fake herdr fail every call with error code $1, as when its server is down.
herdr_fails() {
  local f
  for f in get-w1:p1 get-w1:p2 process-w1:p1 process-w1:p2 list; do
    printf '{"error":{"code":"%s","message":"failed"}}' "$1" >"${herdr_dir}/${f}.json"
    echo 1 >"${herdr_dir}/${f}.rc"
  done
}

# Acquires the claim as token $1 from herdr pane $2 running session $3.
acquire_in_pane() {
  show_pane "$2" "$3" working
  HERDR_PANE_ID="$2" bash "${target}" acquire 7 "$1" >/dev/null
}

claim() {
  run bash "${target}" "$@"
}

# Succeeds when the output has a line exactly equal to $1.
has_line() {
  printf '%s\n' "${lines[@]}" | grep -qxF -- "$1"
}

# Prints the value of key $1 from the output.
value() {
  printf '%s\n' "${lines[@]}" | sed -n "s/^$1=//p" | head -n1
}

# Prints the token recorded in the claim ref.
claim_token() {
  git cat-file -p "${ref}" | sed -n 's/^token=//p'
}

@test "rejects bad arguments with exit 2" {
  claim
  [ "${status}" -eq 2 ]
  claim nope 7
  [ "${status}" -eq 2 ]
  claim acquire 0
  [ "${status}" -eq 2 ]
  claim acquire 7a
  [ "${status}" -eq 2 ]
  claim acquire 7 'bad token'
  [ "${status}" -eq 2 ]
  claim release 7
  [ "${status}" -eq 2 ]
  claim takeover 7
  [ "${status}" -eq 2 ]
  run git rev-parse -q --verify "${ref}"
  [ "${status}" -ne 0 ]
}

@test "outside a Git repository exits 2" {
  mkdir "${work}/plain"
  cd "${work}/plain" || return 1
  GIT_CEILING_DIRECTORIES="${work}" run bash "${target}" acquire 7
  [ "${status}" -eq 2 ]
}

@test "fresh claim with no branch exits 0 and records the token in the ref" {
  claim acquire 7
  [ "${status}" -eq 0 ]
  has_line "claim=${ref}"
  token="$(value token)"
  [ -n "${token}" ]
  [ "$(claim_token)" = "${token}" ]
}

@test "claim is visible from another worktree and stays out of the history" {
  bash "${target}" acquire 7 tok-a
  git worktree add -q -b other "${work}/wt"
  run git -C "${work}/wt" cat-file -p "${ref}"
  has_line "token=tok-a"
  run git log --all --oneline
  [ "${#lines[@]}" -eq 1 ]
}

@test "rerun with the same token is this session's own claim" {
  bash "${target}" acquire 7 tok-a
  claim acquire 7 tok-a
  [ "${status}" -eq 0 ]
  has_line "token=tok-a"
}

@test "claim held by another token exits 20 with its owner" {
  CLAIM_PID=$$ bash "${target}" acquire 7 tok-a
  claim acquire 7 tok-b
  [ "${status}" -eq 20 ]
  has_line "owner_token=tok-a"
  has_line "alive=yes"
  [ "$(claim_token)" = tok-a ]
}

@test "held claim prints this session's new token, and taking over with it changes the owner" {
  bash "${target}" acquire 7 tok-a
  claim acquire 7
  [ "${status}" -eq 20 ]
  mine="$(value token)"
  [ -n "${mine}" ]
  [ "${mine}" != tok-a ]
  claim takeover 7 "${mine}"
  [ "${status}" -eq 0 ]
  [ "$(claim_token)" = "${mine}" ]
}

@test "dead owner process is reported as not alive" {
  CLAIM_PID=999999 bash "${target}" acquire 7 tok-a
  claim acquire 7 tok-b
  [ "${status}" -eq 20 ]
  has_line "alive=no"
}

@test "local matching branch exits 10 and lists it" {
  git branch feat/issue-7-thing
  claim acquire 7
  [ "${status}" -eq 10 ]
  has_line "branch=feat/issue-7-thing remote=no worktree=- dirty=-"
}

@test "remote-only branch exits 10 and lists it as remote" {
  git push -q origin main:refs/heads/feat/issue-7
  claim acquire 7
  [ "${status}" -eq 10 ]
  has_line "branch=feat/issue-7 remote=yes worktree=- dirty=-"
}

@test "branch with a worktree reports its path and dirtiness" {
  git worktree add -q -b fix/issue-7-x "${work}/wt"
  touch "${work}/wt/new.txt"
  claim acquire 7
  [ "${status}" -eq 10 ]
  wt="$(cd "${work}/wt" && pwd -P)"
  has_line "branch=fix/issue-7-x remote=no worktree=${wt} dirty=yes"
}

@test "other issue numbers do not match" {
  git branch feat/issue-70
  git branch feat/issue-17-x
  git branch issue-7x
  claim acquire 7
  [ "${status}" -eq 0 ]
}

@test "unreachable origin exits 2 and drops a new claim" {
  git remote set-url origin "${work}/missing.git"
  claim acquire 7
  [ "${status}" -eq 2 ]
  run git rev-parse -q --verify "${ref}"
  [ "${status}" -ne 0 ]
}

@test "unreachable origin keeps an existing own claim" {
  bash "${target}" acquire 7 tok-a
  git remote set-url origin "${work}/missing.git"
  claim acquire 7 tok-a
  [ "${status}" -eq 2 ]
  has_line "token=tok-a"
  [ "$(claim_token)" = tok-a ]
}

@test "unreachable origin after a takeover reports the claim as held" {
  bash "${target}" acquire 7 tok-a
  git remote set-url origin "${work}/missing.git"
  claim takeover 7 tok-b
  [ "${status}" -eq 2 ]
  has_line "token=tok-b"
  [ "$(claim_token)" = tok-b ]
}

@test "concurrent acquires give exactly one claim" {
  local i wins=0
  for i in $(seq 1 20); do
    (
      bash "${target}" acquire 7 "tok-${i}" >/dev/null 2>&1
      echo $? >"${work}/rc.${i}"
    ) &
  done
  wait
  for i in $(seq 1 20); do
    [[ "$(cat "${work}/rc.${i}")" == 0 ]] && wins=$((wins + 1))
  done
  [ "${wins}" -eq 1 ]
}

@test "takeover replaces the owner and still reports branches" {
  bash "${target}" acquire 7 tok-a
  git branch feat/issue-7
  claim takeover 7 tok-b
  [ "${status}" -eq 10 ]
  [ "$(claim_token)" = tok-b ]
}

@test "takeover of a free Issue claims it" {
  claim takeover 7 tok-b
  [ "${status}" -eq 0 ]
  [ "$(claim_token)" = tok-b ]
}

@test "release by a non-owner exits 20 and keeps the claim" {
  bash "${target}" acquire 7 tok-a
  claim release 7 tok-b
  [ "${status}" -eq 20 ]
  [ "$(claim_token)" = tok-a ]
}

@test "after a takeover, the old owner cannot release the new claim" {
  bash "${target}" acquire 7 tok-a
  bash "${target}" takeover 7 tok-b
  claim release 7 tok-a
  [ "${status}" -eq 20 ]
  [ "$(claim_token)" = tok-b ]
}

@test "release by the owner removes the claim, and is idempotent" {
  bash "${target}" acquire 7 tok-a
  claim release 7 tok-a
  [ "${status}" -eq 0 ]
  run git rev-parse -q --verify "${ref}"
  [ "${status}" -ne 0 ]
  claim release 7 tok-a
  [ "${status}" -eq 0 ]
}

@test "claim taken in a herdr pane records the pane and its agent session" {
  acquire_in_pane tok-a w1:p1 ses-a
  run git cat-file -p "${ref}"
  has_line "pane=w1:p1"
  has_line "session=ses-a"
}

@test "claim taken while herdr fails still succeeds and records no pane" {
  herdr_fails server_not_running
  HERDR_PANE_ID=w1:p1 claim acquire 7 tok-a
  [ "${status}" -eq 0 ]
  run git cat-file -p "${ref}"
  has_line "pane="
  has_line "session="
}

@test "pane whose shell is not an ancestor, as for a daemon that outlived its pane, is not recorded" {
  show_pane w1:p1 ses-a working
  pane_shell w1:p1 999999
  HERDR_PANE_ID=w1:p1 claim acquire 7 tok-a
  [ "${status}" -eq 0 ]
  run git cat-file -p "${ref}"
  has_line "pane="
  has_line "session="
}

@test "pane running the harness's own session is recorded" {
  show_pane w1:p1 ses-a working
  CODEX_THREAD_ID=ses-a HERDR_PANE_ID=w1:p1 bash "${target}" acquire 7 tok-a
  run git cat-file -p "${ref}"
  has_line "pane=w1:p1"
  has_line "session=ses-a"
}

@test "harness session is found by herdr's pane list, even from a daemon outside the pane" {
  show_pane w1:p2 ses-a working
  pane_shell w1:p2 999999
  CODEX_THREAD_ID=ses-a HERDR_PANE_ID=w1:p9 claim acquire 7 tok-a
  [ "${status}" -eq 0 ]
  run git cat-file -p "${ref}"
  has_line "pane=w1:p2"
  has_line "session=ses-a"
}

@test "pane running another session than the harness's own is not recorded" {
  show_pane w1:p1 ses-other working
  CLAUDE_CODE_SESSION_ID=ses-a HERDR_PANE_ID=w1:p1 claim acquire 7 tok-a
  [ "${status}" -eq 0 ]
  run git cat-file -p "${ref}"
  has_line "pane="
  has_line "session="
}

@test "pane id with a control character is not recorded, even if herdr accepted it" {
  show_pane $'w1:p1\ntoken=forged' ses-a working
  HERDR_PANE_ID=$'w1:p1\ntoken=forged' claim acquire 7 tok-a
  [ "${status}" -eq 0 ]
  run git cat-file -p "${ref}"
  has_line "pane="
  # The owner fields are exactly token, pid, lstart, started, pane, and session, with nothing injected.
  [ "${#lines[@]}" -eq 6 ]
  [ "$(value token)" = tok-a ]
}

@test "session with a control character is not recorded, but one with a path is" {
  show_pane w1:p1 $'ses-a\nalive=forged' working
  HERDR_PANE_ID=w1:p1 claim acquire 7 tok-a
  [ "${status}" -eq 0 ]
  run git cat-file -p "${ref}"
  has_line "pane="
  has_line "session="
  [ "${#lines[@]}" -eq 6 ]
  bash "${target}" release 7 tok-a
  show_pane w1:p1 "/sessions/a b.jsonl" working
  HERDR_PANE_ID=w1:p1 bash "${target}" acquire 7 tok-a
  run git cat-file -p "${ref}"
  has_line "session=/sessions/a b.jsonl"
}

@test "claim taken outside herdr reports an unknown state" {
  CLAIM_PID=$$ bash "${target}" acquire 7 tok-a
  claim acquire 7 tok-b
  [ "${status}" -eq 20 ]
  has_line "alive=yes"
  has_line "owner_pane=-"
  has_line "owner_session=-"
  has_line "state=unknown"
}

@test "owner session still in its pane reports the pane's agent status" {
  acquire_in_pane tok-a w1:p1 ses-a
  show_pane w1:p1 ses-a blocked
  claim acquire 7 tok-b
  [ "${status}" -eq 20 ]
  has_line "owner_pane=w1:p1"
  has_line "owner_session=ses-a"
  has_line "pane_session=ses-a"
  has_line "active_pane=w1:p1"
  has_line "state=blocked"
}

@test "closed pane with the session in no other pane is gone" {
  acquire_in_pane tok-a w1:p1 ses-a
  show_pane w1:p2 ses-other idle
  close_pane w1:p1
  claim acquire 7 tok-b
  [ "${status}" -eq 20 ]
  has_line "pane_session=-"
  has_line "active_pane=-"
  has_line "state=gone"
}

@test "pane switched to another session, as after /clear, is gone" {
  acquire_in_pane tok-a w1:p1 ses-a
  show_pane w1:p1 ses-new working
  claim acquire 7 tok-b
  [ "${status}" -eq 20 ]
  has_line "pane_session=ses-new"
  has_line "state=gone"
}

@test "pane left with no agent is gone" {
  acquire_in_pane tok-a w1:p1 ses-a
  show_pane w1:p1 "" unknown -
  claim acquire 7 tok-b
  [ "${status}" -eq 20 ]
  has_line "pane_session=-"
  has_line "state=gone"
}

@test "pane without an agent status reports unknown" {
  acquire_in_pane tok-a w1:p1 ses-a
  jq '.result.pane.agent_status = null' "${herdr_dir}/get-w1:p1.json" >"${work}/p.json"
  mv "${work}/p.json" "${herdr_dir}/get-w1:p1.json"
  claim acquire 7 tok-b
  [ "${status}" -eq 20 ]
  has_line "active_pane=w1:p1"
  has_line "state=unknown"
}

@test "pane whose agent has not reported a session is unknown, never gone" {
  acquire_in_pane tok-a w1:p1 ses-a
  show_pane w1:p1 "" working
  claim acquire 7 tok-b
  [ "${status}" -eq 20 ]
  has_line "pane_session=-"
  has_line "state=unknown"
}

@test "session open in several panes reports the busiest one" {
  acquire_in_pane tok-a w1:p1 ses-a
  show_pane w1:p1 ses-new idle
  show_pane w1:p2 ses-a idle
  show_pane w1:p3 ses-a working
  claim acquire 7 tok-b
  [ "${status}" -eq 20 ]
  has_line "active_pane=w1:p3"
  has_line "state=working"
}

@test "rerun with the same token refreshes the recorded pane, as after an upgrade or a resume" {
  bash "${target}" acquire 7 tok-a
  acquire_in_pane tok-a w1:p1 ses-a
  run git cat-file -p "${ref}"
  has_line "token=tok-a"
  has_line "pane=w1:p1"
  has_line "session=ses-a"
}

@test "session resumed in another pane reports that pane" {
  acquire_in_pane tok-a w1:p1 ses-a
  show_pane w1:p1 ses-new idle
  show_pane w1:p2 ses-a working
  claim acquire 7 tok-b
  [ "${status}" -eq 20 ]
  has_line "pane_session=ses-new"
  has_line "active_pane=w1:p2"
  has_line "state=working"
}

@test "herdr failing at status time is unknown, never gone" {
  acquire_in_pane tok-a w1:p1 ses-a
  herdr_fails server_not_running
  claim acquire 7 tok-b
  [ "${status}" -eq 20 ]
  has_line "state=unknown"
}

@test "pane list failing after the pane moved on is unknown, never gone" {
  acquire_in_pane tok-a w1:p1 ses-a
  show_pane w1:p1 ses-new idle
  echo '{"error":{"code":"server_not_running"}}' >"${herdr_dir}/list.json"
  echo 1 >"${herdr_dir}/list.rc"
  claim acquire 7 tok-b
  [ "${status}" -eq 20 ]
  has_line "state=unknown"
}

@test "pane whose agent has reported no session is not recorded" {
  show_pane w1:p1 "" working
  HERDR_PANE_ID=w1:p1 claim acquire 7 tok-a
  [ "${status}" -eq 0 ]
  run git cat-file -p "${ref}"
  has_line "pane="
  has_line "session="
}

@test "pane list values that are not single-line strings read as unknown" {
  acquire_in_pane tok-a w1:p1 ses-a
  show_pane w1:p1 ses-new idle
  show_pane w1:p2 ses-a $'working\nforged'
  claim acquire 7 tok-b
  [ "${status}" -eq 20 ]
  has_line "active_pane=w1:p2"
  has_line "state=unknown"
}

@test "owner recorded with a pane but no session is unknown, whatever the pane runs" {
  show_pane w1:p1 "" working
  printf 'token=tok-a\npid=1\nlstart=x\nstarted=x\npane=w1:p1\nsession=\n' | git hash-object -w --stdin |
    xargs git update-ref "${ref}"
  claim status 7
  [ "${status}" -eq 20 ]
  has_line "owner_pane=w1:p1"
  has_line "state=unknown"
}

@test "status of a free Issue exits 0 and claims nothing" {
  claim status 7
  [ "${status}" -eq 0 ]
  has_line "claim=${ref}"
  run git rev-parse -q --verify "${ref}"
  [ "${status}" -ne 0 ]
}

@test "status of a held Issue exits 20 with the state, needs no token, and changes nothing" {
  acquire_in_pane tok-a w1:p1 ses-a
  before="$(git rev-parse "${ref}")"
  claim status 7
  [ "${status}" -eq 20 ]
  has_line "owner_token=tok-a"
  has_line "state=working"
  [ "$(printf '%s\n' "${lines[@]}" | grep -c '^token=')" -eq 0 ]
  [ "$(git rev-parse "${ref}")" = "${before}" ]
}

@test "status rejects a missing or bad issue number with exit 2" {
  claim status
  [ "${status}" -eq 2 ]
  claim status 7a
  [ "${status}" -eq 2 ]
}
