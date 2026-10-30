#!/usr/bin/env bats
# Tests for the create-pr evaluation harness: setup.sh builds the sandboxes, gh-stub.sh records what a run creates,
# and grade.sh judges the records. A "reference run" drives create-pr's own scripts the way SKILL.md says, without an
# LLM, so the grader is checked against runs whose outcome the test fixes.
# shellcheck disable=SC2292 # bats fails a test on a mid-test `[[ ]]` only under bash 4.1+; `[ ]` works on every bash.

setup() {
  eval_dir="${BATS_TEST_DIRNAME}"
  scripts="${BATS_TEST_DIRNAME}/../scripts"
  work="${BATS_TEST_TMPDIR}"
  # The user's git config and gh target must not reach the sandbox; a run sets them only through the harness.
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  unset GIT_CONFIG GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS GH_REPO GH_HOST
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
  export LINK_POLL_INTERVAL=0
}

# snapshot <dir> prints what a sandbox is made of, with <dir> itself replaced, so two builds compare as text.
snapshot() {
  local d="$1" g
  for g in repo origin.git; do
    echo "## ${g} refs"
    git -C "${d}/${g}" for-each-ref --format='%(refname) %(objectname)'
    echo "## ${g} HEAD $(git -C "${d}/${g}" symbolic-ref -q HEAD)"
  done
  echo "## repo config"
  git -C "${d}/repo" config --local --list | sort
  echo "## repo status"
  git -C "${d}/repo" status --porcelain
  echo "## files"
  (cd "${d}" && find bin state prompt.md -type f | sort | while read -r f; do
    echo "# ${f}"
    cat "${f}"
  done)
}

normalized_snapshot() {
  snapshot "$1" | sed "s|$1|<dir>|g"
}

# reference_run <dir> <title> <labels> <body> [<argument tokens>...] runs SKILL.md's Step 1 and Step 6 commands in the
# sandbox, with the stub on PATH, as one correct executor would.
reference_run() {
  local d="$1" title="$2" labels="$3" body="$4" context flags_line
  shift 4
  local -a flags label_args=()
  cd "${d}/repo" || return 1
  context="$(PATH="${d}/bin:${PATH}" bash "${scripts}/pr-context.sh" "$@")" || return 1
  flags_line="$(sed -n '/^== create flags$/{n;p;}' <<<"${context}")"
  read -r -a flags <<<"${flags_line}"
  for l in ${labels}; do label_args+=(--label "${l}"); done
  git push -q -u origin "$(git branch --show-current)" &&
    PATH="${d}/bin:${PATH}" bash "${scripts}/create-linked-pr.sh" --title "${title}" --body-file - "${flags[@]}" \
      ${label_args[@]+"${label_args[@]}"} --web <<<"${body}"
}

body_a() {
  cat <<'EOF'
## 概要

リフレッシュ時に期限切れの JWT を `SessionExpiredError` として通知し、失効したトークンでの無限リトライを止めます。

## 変更点

- `refresh()` は 401 を受けると `SessionExpiredError` を投げます。

## 動作確認

- [ ] ユニットテスト (未実行: テストランナーがない)
- [ ] 手動確認 (未実行)

## 関連 Issue

Closes #12
EOF
}

body_b() {
  cat <<'EOF'
## Summary

Login attempts are capped at 10 so a client cannot retry credentials without limit.

Closes #40
EOF
}

body_c() {
  cat <<'EOF'
## Summary

CSV cells are quoted, so a cell holding a comma or a quote no longer corrupts the export.

Closes #8
EOF
}

@test "each scenario built into two directories yields the same refs, config, files, and prompt" {
  for s in A B C; do
    run bash "${eval_dir}/setup.sh" "${s}" "${work}/${s}1"
    [ "${status}" -eq 0 ]
    run bash "${eval_dir}/setup.sh" "${s}" "${work}/${s}2"
    [ "${status}" -eq 0 ]
    first="$(normalized_snapshot "${work}/${s}1")"
    second="$(normalized_snapshot "${work}/${s}2")"
    [ -n "${first}" ]
    [ "${first}" = "${second}" ]
  done
}

@test "rebuilding over an earlier sandbox discards the earlier run's records" {
  bash "${eval_dir}/setup.sh" A "${work}/a"
  touch "${work}/a/state/leftover"
  run bash "${eval_dir}/setup.sh" A "${work}/a"
  [ "${status}" -eq 0 ]
  [ ! -e "${work}/a/state/leftover" ]
}

@test "a non-empty directory that is not a sandbox is refused and left as it was" {
  mkdir -p "${work}/precious"
  echo keep >"${work}/precious/file"
  run bash "${eval_dir}/setup.sh" A "${work}/precious"
  [ "${status}" -eq 2 ]
  [ "$(cat "${work}/precious/file")" = keep ]
  [ "$(ls -A "${work}/precious")" = file ]
}

@test "scenario B leaves local main behind origin/main, which carries Closes #99, and the upstream behind HEAD" {
  bash "${eval_dir}/setup.sh" B "${work}/b"
  repo="${work}/b/repo"
  [ "$(git -C "${repo}" rev-list --count main..origin/main)" -eq 1 ]
  [[ "$(git -C "${repo}" log -1 --format=%B origin/main)" == *"Closes #99"* ]]
  [ "$(git -C "${repo}" rev-list --count '@{upstream}..HEAD')" -eq 1 ]
}

@test "scenario C's branch names feat/export-api as its gh-merge-base and has no PR template" {
  bash "${eval_dir}/setup.sh" C "${work}/c"
  repo="${work}/c/repo"
  [ "$(git -C "${repo}" config --get branch.feat/export-csv-quoting.gh-merge-base)" = feat/export-api ]
  [ -z "$(git -C "${repo}" ls-files '*PULL_REQUEST_TEMPLATE*' '*pull_request_template*')" ]
}

@test "the prompt names the SKILL.md under test, the sandbox repo, and the stub directory" {
  mkdir -p "${work}/other-skill"
  touch "${work}/other-skill/SKILL.md"
  bash "${eval_dir}/setup.sh" B "${work}/b" "${work}/other-skill"
  prompt="$(cat "${work}/b/prompt.md")"
  [[ "${prompt}" == *"Read ${work}/other-skill/SKILL.md"* ]]
  [[ "${prompt}" == *"shell command in ${work}/b/repo"* ]]
  [[ "${prompt}" == *"export PATH=${work}/b/bin:\$PATH"* ]]
  [[ "${prompt}" == *"lang en"* ]]
  [[ "${prompt}" == *"[critical]"* ]]
  [[ "${prompt}" != *"{{"* ]]
}

@test "with the stub off PATH, the scenario's commands make no HTTP request" {
  command -v gh >/dev/null || skip "gh is not installed"
  # Signed in, so gh would send a request it can send instead of stopping at sign-in; any value serves.
  token="${BATS_TEST_NAME}"
  for s in A C; do
    bash "${eval_dir}/setup.sh" "${s}" "${work}/${s}"
    cd "${work}/${s}/repo"
    run env GH_TOKEN="${token}" GH_DEBUG=api bash "${scripts}/pr-context.sh" lang en
    [ "${status}" -ne 0 ]
    [[ "${output}" != *"* Request"* ]]
    git push -q -u origin "$(git branch --show-current)"
    run env GH_TOKEN="${token}" GH_DEBUG=api bash "${scripts}/create-linked-pr.sh" --title "t" --body-file - --draft <<<"Closes #12"
    [ "${status}" -ne 0 ]
    [[ "${output}" != *"* Request"* ]]
  done
}

@test "replaying a URL the stub printed with the real gh does not reach github.com" {
  command -v gh >/dev/null || skip "gh is not installed"
  # Signed in, so gh would send a request it can send instead of stopping at sign-in; any value serves.
  token="${BATS_TEST_NAME}"
  bash "${eval_dir}/setup.sh" A "${work}/a"
  cd "${work}/a/repo"
  url="$("${work}/a/bin/gh" repo view --json url --jq .url)"
  run env GH_TOKEN="${token}" GH_DEBUG=api gh pr view "${url}/pull/101" --json id
  [ "${status}" -ne 0 ]
  if grep -Eq 'Request to https://([^/]*\.)?github\.com|Host: ([^ ]*\.)?github\.com' <<<"${output}"; then
    return 1
  fi
}

@test "a correct run of scenario A passes every graded item" {
  bash "${eval_dir}/setup.sh" A "${work}/a"
  run reference_run "${work}/a" "fix(auth): 期限切れの JWT を SessionExpiredError で通知する" "bug auth" "$(body_a)"
  [ "${status}" -eq 0 ]
  run bash "${eval_dir}/grade.sh" A "${work}/a"
  [ "${status}" -eq 0 ]
  [[ "${output}" != *FAIL* ]]
  [[ "${output}" == *"1 PASS"* ]]
}

@test "a correct run of scenario B passes every graded item" {
  bash "${eval_dir}/setup.sh" B "${work}/b"
  run reference_run "${work}/b" "feat(auth): add a login rate limit" "enhancement auth" "$(body_b)" lang en
  [ "${status}" -eq 0 ]
  run bash "${eval_dir}/grade.sh" B "${work}/b"
  [ "${status}" -eq 0 ]
  [[ "${output}" != *FAIL* ]]
}

@test "a correct run of scenario C targets feat/export-api and passes every graded item" {
  bash "${eval_dir}/setup.sh" C "${work}/c"
  run reference_run "${work}/c" "feat(export): quote CSV cells" "enhancement" "$(body_c)" lang en
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"NOTICE: base feat/export-api is not the default branch main"* ]]
  run bash "${eval_dir}/grade.sh" C "${work}/c"
  [ "${status}" -eq 0 ]
  [[ "${output}" != *FAIL* ]]
}

@test "a PR opened by a direct gh pr create fails item 1" {
  bash "${eval_dir}/setup.sh" A "${work}/a"
  cd "${work}/a/repo"
  git push -q -u origin fix/expired-jwt-refresh
  body_a >"${work}/body"
  PATH="${work}/a/bin:${PATH}" gh pr create --title "fix(auth): 期限切れの JWT を通知する" --body-file "${work}/body" \
    --base main --draft --assignee @me
  run bash "${eval_dir}/grade.sh" A "${work}/a"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"1 FAIL"* ]]
  [[ "${output}" == *"2 PASS"* ]]
}

@test "a PR opened while origin's branch is behind HEAD fails item 2" {
  bash "${eval_dir}/setup.sh" B "${work}/b"
  cd "${work}/b/repo"
  body_b >"${work}/body"
  PATH="${work}/b/bin:${PATH}" gh pr create --title "feat(auth): add a login rate limit" --body-file "${work}/body" \
    --base main --draft --assignee @me
  run bash "${eval_dir}/grade.sh" B "${work}/b"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"2 FAIL"* ]]
}

@test "scenario C opened against main, closing #7 as well, fails item 3" {
  bash "${eval_dir}/setup.sh" C "${work}/c"
  run reference_run "${work}/c" "feat(export): add the CSV export API" "enhancement" "$(printf '%s\n\nCloses #7\nCloses #8' "$(body_c | head -3)")" base main lang en
  [ "${status}" -eq 0 ]
  run bash "${eval_dir}/grade.sh" C "${work}/c"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"3 FAIL"* ]]
}

@test "scenario C opened against main fails item 3 even when its only reference is Closes #8 and nothing is linked" {
  bash "${eval_dir}/setup.sh" C "${work}/c"
  cd "${work}/c/repo"
  git push -q -u origin feat/export-csv-quoting
  body_c >"${work}/body"
  PATH="${work}/c/bin:${PATH}" gh pr create --title "feat(export): quote CSV cells" --body-file "${work}/body" \
    --base main --draft --assignee @me
  run bash "${eval_dir}/grade.sh" C "${work}/c"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"3 FAIL base main"* ]]
}

@test "grading a sandbox where no PR was created fails items 1 and 2" {
  bash "${eval_dir}/setup.sh" A "${work}/a"
  run bash "${eval_dir}/grade.sh" A "${work}/a"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"1 FAIL"* ]]
  [[ "${output}" == *"2 FAIL"* ]]
}
