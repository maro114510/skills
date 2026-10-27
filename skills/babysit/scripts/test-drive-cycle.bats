#!/usr/bin/env bats
# Whole drive cycles, driven by the commands the skill runs, against a local origin, saved snapshots, and a stub gh.
# Each test plays the part of the model: it reads an event line, runs the next script, and edits a file where a
# repair needs one. No test calls GitHub.
# shellcheck disable=SC2292 # bats fails a test on a mid-test `[[ ]]` only under bash 4.1+; `[ ]` works on every bash.

setup() {
  scripts="${BATS_TEST_DIRNAME}"
  tmp="${BATS_TEST_TMPDIR}"
  token="tok-1"
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
  export BABYSIT_REMOTE_BASE="file://${tmp}/srv"
  export BABYSIT_PR_STATE="${tmp}/pr-state"
  export BABYSIT_NOW=1000000
  mkdir -p "${tmp}/srv/o" "${tmp}/bin"

  # origin holds main and the PR branch; repo is the user's own checkout, left dirty on purpose.
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
  printf 'my unsaved work\n' >>app.txt
  printf 'notes\n' >notes.txt

  # One stub serves gh for the scripts and for the gate: the default branch, replies, and re-runs.
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
  cat >"${tmp}/osascript" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" >>"${tmp}/osascript-calls"
EOF
  printf '#!/usr/bin/env bash\ncat "%s/snap.json"\n' "${tmp}" >"${tmp}/pr-state"
  chmod +x "${tmp}/bin/gh" "${tmp}/osascript" "${tmp}/pr-state"
  export PATH="${tmp}/bin:${PATH}"
  export BABYSIT_GH="${tmp}/bin/gh" BABYSIT_OSASCRIPT="${tmp}/osascript"

  # The PR as pr-state prints it: not READY because a reviewer was requested, one passing Actions check.
  clean='{"repo":"o/r","number":7,"url":"https://github.com/o/r/pull/7","state":"OPEN","isDraft":false,
    "author":"me","viewer":"me","isCrossRepository":false,"baseRef":"main","headRef":"feat/x","head":"HEAD0",
    "mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","reviewDecision":"APPROVED",
    "checks":[{"key":"github-actions/.github/workflows/ci.yml/pull_request/test","name":"test","workflow":"CI",
      "kind":"check_run","rerunnable":true,"status":"pass","runId":100,"workflowRunId":10,"attempt":1,
      "url":"https://example.invalid/run/100","startedAt":"2026-01-01T00:00:00Z"}],
    "reviewRequests":[{"reviewer":"dave","type":"User"}],"latestReviews":[],"threads":[],"reviews":[],"comments":[]}'
  check_key="github-actions/.github/workflows/ci.yml/pull_request/test"
  set_snap "${head0}" '.'
  bash "${scripts}/ledger.sh" start o/r 7 "${token}" >/dev/null
}

# Writes the snapshot for head $1 after the jq edit $2.
set_snap() {
  jq -c --arg head "$1" ".head = \$head | $2" <<<"${clean}" >"${tmp}/snap.json"
}

# One drive-mode wait that returns at once with the next event, or idle.
poll() {
  run bash "${scripts}/wait.sh" o/r 7 --max 0 --session "${token}" --mode drive --snapshot "${tmp}/snap.json"
}

field() {
  tail -n 1 <<<"${output}" | jq -r "$1"
}

# Reads jq expression $1 from the whole output, for scripts that print more than one line.
whole() {
  jq -r "$1" <<<"${output}"
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

# Everything that identifies the user's checkout.
fingerprint() {
  git -C "${tmp}/repo" symbolic-ref HEAD
  git -C "${tmp}/repo" rev-parse HEAD
  git -C "${tmp}/repo" status --porcelain --untracked-files=all
  git -C "${tmp}/repo" diff HEAD
  cat "${tmp}/repo/app.txt" "${tmp}/repo/notes.txt"
  git -C "${tmp}/repo" branch --list
}

remote_head() {
  git --git-dir="${tmp}/srv/o/r.git" rev-parse refs/heads/feat/x
}

# Resets the drive worktree to the PR head $1 and sets wt and wt_sha.
prepare() {
  run bash "${scripts}/worktree.sh" prepare o/r 7 --session "${token}" --branch feat/x --head "$1"
  [ "${status}" -eq 0 ]
  wt="$(jq -r .path <<<"${output}")"
  wt_sha="$(jq -r .sha <<<"${output}")"
}

# Commits file $1 with content $2 in the drive worktree, as a repair would.
fix() {
  mkdir -p "$(dirname "${wt}/$1")"
  printf '%s\n' "$2" >"${wt}/$1"
  git -C "${wt}" add -- "$1"
  git -C "${wt}" commit -q -m "fix"
}

push() {
  run bash "${scripts}/push.sh" o/r 7 --session "${token}" --worktree "${wt}" --start "${wt_sha}" --branch feat/x "$@"
}

@test "a CI failure goes through one re-run, one repair, one push, and a green re-run" {
  before="$(fingerprint)"
  set_snap "${head0}" '.checks[0].status = "failed"'
  poll
  expect "$(field .event)" check_failed
  key="$(field .key)"
  run bash "${scripts}/rerun.sh" o/r 7 --session "${token}" --key "${key}" \
    --workflow-run "$(field .check.workflowRunId)" --run-id "$(field .check.runId)"
  [ "${status}" -eq 0 ]
  poll
  expect "$(field .event)" idle

  # The re-run failed again, as a newer run of the same check.
  set_snap "${head0}" '.checks[0] += {status: "failed", runId: 101, attempt: 2}'
  poll
  expect "$(field .event)" check_confirmed
  failing="$(field .check.key)"
  prepare "${head0}"
  fix src/fix.txt "the repair"
  push --check "${failing}"
  [ "${status}" -eq 0 ]
  head1="$(field .sha)"
  expect "$(remote_head)" "${head1}"

  # CI passes on the new head, so nothing fires and the old failure is gone.
  set_snap "${head1}" '.'
  poll
  expect "$(field .event)" idle
  expect "$(ledger .rounds)" 1
  expect "$(ledger ".repairs[\"${check_key}\"]")" 1
  expect "$(ledger '.own.pushes | join(",")')" "${head1}"
  expect "$(fingerprint)" "${before}"
}

@test "a review comment goes through a fix, a push, and a reply, and the thread stays unresolved" {
  thread='{id: "T1", isResolved: false, path: "feature.txt", line: 1, comments: [
    {id: "TC1", author: "carol", authorAssociation: "NONE", body: "please rename", bodyHash: "h1",
     createdAt: "2026-01-02T00:00:00Z", url: "u", isMinimized: false}]}'
  set_snap "${head0}" ".threads = [${thread}]"
  poll
  expect "$(field .event)" comment
  expect "$(field .comment.thread)" T1
  prepare "${head0}"
  fix feature.txt renamed
  push
  [ "${status}" -eq 0 ]
  head1="$(field .sha)"
  printf 'Renamed in %s.\n' "${head1:0:7}" >"${tmp}/reply.md"
  run bash "${scripts}/reply.sh" o/r 7 --session "${token}" --thread T1 --body-file "${tmp}/reply.md"
  [ "${status}" -eq 0 ]
  reply_id="$(field .id)"
  run bash "${scripts}/ledger.sh" record o/r 7 "${token}" c:TC1 handled --hash h1
  [ "${status}" -eq 0 ]

  # GitHub now shows the agent's own reply in the thread, which is still unresolved.
  set_snap "${head1}" ".threads = [${thread} | .comments += [{id: \"${reply_id}\", author: \"me\", authorAssociation: \"OWNER\",
    body: \"Renamed.\", bodyHash: \"unrelated\", createdAt: \"2026-01-03T00:00:00Z\", url: \"u2\", isMinimized: false}]]"
  poll
  expect "$(field .event)" idle
  run bash "${scripts}/check.sh" o/r 7 --mode drive --snapshot "${tmp}/snap.json"
  expect "$(whole .status)" NOT_READY
  expect "$(whole '.blockers | any(test("unresolved review thread"))')" true
  run grep -qi 'resolve' "${tmp}/gh-calls"
  [ "${status}" -eq 1 ]
}

@test "a fix the gate parks is not pushed, is listed as parked with its reason, and shows a notification" {
  thread='{id: "T1", isResolved: false, path: "feature.txt", line: 1, comments: [
    {id: "TC1", author: "carol", authorAssociation: "NONE", body: "add a CI step", bodyHash: "h1",
     createdAt: "2026-01-02T00:00:00Z", url: "u", isMinimized: false}]}'
  set_snap "${head0}" ".threads = [${thread}]"
  poll
  expect "$(field .event)" comment
  prepare "${head0}"
  fix .github/workflows/ci.yml "name: ci"
  push
  [ "${status}" -eq 10 ]
  expect "$(field .verdict)" park
  expect "$(remote_head)" "${head0}"
  expect "$(ledger .rounds)" 0
  run bash "${scripts}/park.sh" o/r 7 --session "${token}" --key c:TC1 --hash h1 --reason "the gate parked a CI workflow change"
  [ "${status}" -eq 0 ]
  expect "$(field .notified)" true
  grep -q 'o/r#7' "${tmp}/osascript-calls"

  # Only the parked blocker is left, so the session ends and says why.
  poll
  expect "$(field .event)" stalled
  expect "$(field '.report.parked | join(",")')" c:TC1
  expect "$(field '.report.reasons["c:TC1"]')" "the gate parked a CI workflow change"
}

@test "a check that still fails after two repair pushes is parked as stuck" {
  head_n="${head0}"
  for round in 1 2; do
    set_snap "${head_n}" '.checks[0] += {status: "failed", rerunnable: false}'
    poll
    expect "$(field .event)" check_confirmed
    failing="$(field .check.key)"
    prepare "${head_n}"
    fix "src/try${round}.txt" "try ${round}"
    push --check "${failing}"
    [ "${status}" -eq 0 ]
    head_n="$(field .sha)"
  done
  expect "$(ledger .rounds)" 2
  expect "$(ledger ".repairs[\"${check_key}\"]")" 2
  set_snap "${head_n}" '.checks[0] += {status: "failed", rerunnable: false}'
  poll
  expect "$(field .event)" check_stuck
}

@test "five repair rounds stop the run with every unresolved item listed" {
  for _ in 1 2 3 4 5; do
    bash "${scripts}/ledger.sh" count-push o/r 7 "${token}"
  done
  set_snap "${head0}" '.checks[0].status = "failed" | .comments = [{id: "IC1", author: "carol", authorAssociation: "NONE",
    body: "also this", bodyHash: "h1", createdAt: "2026-01-02T00:00:00Z", url: "u", isMinimized: false}]'
  poll
  expect "$(field .event)" limit
  expect "$(field '.report.pending | length')" 2
  expect "$(field '.report.pending | map(.key) | any(startswith("c:IC1"))')" true
  expect "$(field '.report.pending | map(.event) | any(. == "check_failed")')" true
}
