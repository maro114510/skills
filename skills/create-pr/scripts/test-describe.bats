#!/usr/bin/env bats
# Tests for describe.sh, in a throwaway skills root whose pr-context.sh and harness CLI are stubs.
# The root holds the real SKILL.md and description.md, so the rules handed to the session come from them.
# shellcheck disable=SC2292 # bats fails a test on a mid-test `[[ ]]` only under bash 4.1+; `[ ]` works on every bash.

setup() {
  # The developer's own git config and hooks must not reach the repositories built here.
  export GIT_CONFIG_GLOBAL="${BATS_TEST_TMPDIR}/gitconfig" GIT_CONFIG_NOSYSTEM=1
  unset GIT_CONFIG GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS
  : >"${GIT_CONFIG_GLOBAL}"
  root="${BATS_TEST_TMPDIR}/skills"
  mkdir -p "${root}/create-pr/scripts" "${root}/create-pr/references"
  cp "${BATS_TEST_DIRNAME}/describe.sh" "${root}/create-pr/scripts/"
  cp "${BATS_TEST_DIRNAME}/../SKILL.md" "${root}/create-pr/"
  cp "${BATS_TEST_DIRNAME}/../references/description.md" "${root}/create-pr/references/"
  bin="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "${bin}"
  args_file="${BATS_TEST_TMPDIR}/harness-args"
  stdin_file="${BATS_TEST_TMPDIR}/harness-stdin"

  repo="${BATS_TEST_TMPDIR}/repo"
  git init -q -b main "${repo}"
  echo a >"${repo}/tracked.txt"
  git -C "${repo}" add .
  git -C "${repo}" -c user.name=t -c user.email=t@t commit -q -m init
  head_sha="$(git -C "${repo}" rev-parse HEAD)"

  note="${BATS_TEST_TMPDIR}/note.md"
  echo "- What changed: the weekly report skips generated functions" >"${note}"
  context 0 "== branch"$'\n'"feature"$'\n'"CONTEXT-SENTINEL"
}

# A pr-context.sh that records its arguments, prints $2, and exits $1.
context() {
  printf '#!/bin/sh\necho "$@" >"%s"\ncat <<'"'"'EOF'"'"'\n%s\nEOF\nexit %s\n' \
    "${BATS_TEST_TMPDIR}/context-args" "$2" "$1" >"${root}/create-pr/scripts/pr-context.sh"
}

# A harness CLI named $1 that records its arguments and stdin, then runs the shell body $2.
harness() {
  printf '#!/bin/sh\nprintf "%%s\\n" "$@" >"%s"\ncat >"%s"\n%s\n' "${args_file}" "${stdin_file}" "$2" >"${bin}/$1"
  chmod +x "${bin}/$1"
}

# A reply in the format describe.sh asks the session for.
reply='echo "Here is the description."; echo "PR_TITLE: fix(report): stop false positives"; echo PR_BODY_BEGIN; echo "## Summary"; echo; echo "The weekly report no longer flags generated code."; echo PR_BODY_END'

describe() {
  cd "${repo}" || return 1
  run env TMPDIR="${BATS_TEST_TMPDIR}" PATH="${bin}:${PATH}" bash "${root}/create-pr/scripts/describe.sh" "$@"
}

# Succeeds when the output has a line exactly equal to $1.
has_line() {
  printf '%s\n' "${lines[@]}" | grep -qxF -- "$1"
}

@test "a reply with a title and body prints only them, then the written result" {
  harness claude "${reply}"
  describe claude "${note}"
  [ "${status}" -eq 0 ]
  [ "${lines[0]}" = "PR_TITLE: fix(report): stop false positives" ]
  [ "${lines[1]}" = "PR_BODY_BEGIN" ]
  [ "${lines[2]}" = "## Summary" ]
  [ "${lines[3]}" = "The weekly report no longer flags generated code." ]
  [ "${lines[4]}" = "PR_BODY_END" ]
  [ "${lines[5]}" = "DESCRIBE status=written head=${head_sha}" ]
  [ "${#lines[@]}" -eq 6 ]
}

@test "the argument tokens reach pr-context.sh verbatim" {
  harness claude "${reply}"
  describe claude "${note}" ready base develop lang en
  [ "${status}" -eq 0 ]
  [ "$(cat "${BATS_TEST_TMPDIR}/context-args")" = "ready base develop lang en" ]
}

@test "the session gets the context, the note, and the writing rules on stdin" {
  harness claude "${reply}"
  describe claude "${note}"
  [ "${status}" -eq 0 ]
  grep -qxF "CONTEXT-SENTINEL" "${stdin_file}"
  grep -qxF -- "- What changed: the weekly report skips generated functions" "${stdin_file}"
  grep -qF "## Step 2. Analyze the Change" "${stdin_file}"
  grep -qF "### 3.1 Language" "${stdin_file}"
  grep -qF "### 3.2 Checkboxes" "${stdin_file}"
  grep -qF "## Step 4. Choose the PR Title" "${stdin_file}"
  grep -qF "# PR Description" "${stdin_file}"
  grep -qF "## Compact Pass" "${stdin_file}"
}

@test "the session gets none of the steps that run scripts, push, or create the PR" {
  harness claude "${reply}"
  describe claude "${note}"
  [ "${status}" -eq 0 ]
  if grep -qE "^## Step (1|3|5|6)\." "${stdin_file}"; then return 1; fi
  if grep -qF "describe.sh" "${stdin_file}"; then return 1; fi
  if grep -qF "git push" "${stdin_file}"; then return 1; fi
}

@test "a session that edits a tracked file exits 3" {
  harness claude "echo b >> tracked.txt; ${reply}"
  describe claude "${note}"
  [ "${status}" -eq 3 ]
  has_line "SESSION_CHANGED_WORKTREE"
  has_line "DESCRIBE status=changed head=${head_sha}"
  if has_line "PR_BODY_BEGIN"; then return 1; fi
}

@test "a session that adds an untracked file exits 3" {
  harness claude "touch pwned.txt; ${reply}"
  describe claude "${note}"
  [ "${status}" -eq 3 ]
}

@test "a session that commits exits 3" {
  harness claude "git -c user.name=t -c user.email=t@t commit -q --allow-empty -m moved; ${reply}"
  describe claude "${note}"
  [ "${status}" -eq 3 ]
}

@test "a worktree change wins over a session failure" {
  harness claude 'echo b >> tracked.txt; exit 1'
  describe claude "${note}"
  [ "${status}" -eq 3 ]
}

@test "a session that exits non-zero exits 1 and reports its code" {
  harness claude 'echo boom >&2; exit 7'
  describe claude "${note}"
  [ "${status}" -eq 1 ]
  has_line "boom"
  has_line "SESSION_EXIT=7"
  has_line "DESCRIBE status=failed head=${head_sha}"
}

@test "a session with no output exits 1" {
  harness claude 'printf "  \n"'
  describe claude "${note}"
  [ "${status}" -eq 1 ]
  has_line "DESCRIBE status=failed head=${head_sha}"
}

@test "a reply without a title line exits 1 and shows the reply" {
  harness claude 'echo PR_BODY_BEGIN; echo body; echo PR_BODY_END'
  describe claude "${note}"
  [ "${status}" -eq 1 ]
  has_line "body"
  has_line "DESCRIBE status=failed head=${head_sha}"
}

@test "a reply whose body never ends exits 1" {
  harness claude 'echo "PR_TITLE: fix: x"; echo PR_BODY_BEGIN; echo body'
  describe claude "${note}"
  [ "${status}" -eq 1 ]
}

@test "a reply with an empty body exits 1" {
  harness claude 'echo "PR_TITLE: fix: x"; echo PR_BODY_BEGIN; echo " "; echo PR_BODY_END'
  describe claude "${note}"
  [ "${status}" -eq 1 ]
}

@test "a reply with an empty title exits 1" {
  harness claude 'echo "PR_TITLE: "; echo PR_BODY_BEGIN; echo body; echo PR_BODY_END'
  describe claude "${note}"
  [ "${status}" -eq 1 ]
}

@test "a failing pr-context.sh exits 1 with its output, and the session never runs" {
  context 4 "ON_BASE_BRANCH main"
  harness claude "${reply}"
  describe claude "${note}"
  [ "${status}" -eq 1 ]
  has_line "ON_BASE_BRANCH main"
  has_line "CONTEXT_EXIT=4"
  [ ! -e "${args_file}" ]
}

@test "an unsupported harness exits 2" {
  describe pi "${note}"
  [ "${status}" -eq 2 ]
}

@test "a missing note exits 2" {
  harness claude "${reply}"
  describe claude "${BATS_TEST_TMPDIR}/absent.md"
  [ "${status}" -eq 2 ]
  [ ! -e "${args_file}" ]
}

@test "an empty note exits 2" {
  harness claude "${reply}"
  printf ' \n' >"${note}"
  describe claude "${note}"
  [ "${status}" -eq 2 ]
}

@test "codex runs ephemeral in a read-only sandbox and its last message is the reply" {
  # shellcheck disable=SC2016 # expanded by the stub, not here
  harness codex 'while [ $# -gt 0 ]; do [ "$1" = -o ] && o="$2"; shift; done; { '"${reply}"'; } >"$o"'
  describe codex "${note}"
  [ "${status}" -eq 0 ]
  [ "${lines[0]}" = "PR_TITLE: fix(report): stop false positives" ]
  [ "$(sed -n 1p "${args_file}")" = "exec" ]
  grep -qxF -- "--ephemeral" "${args_file}"
  grep -qxF -- 'sandbox_mode="read-only"' "${args_file}"
  grep -qxF "CONTEXT-SENTINEL" "${stdin_file}"
}

# Prints a stub OpenCode body that answers `run --help`, listing --standalone only when $1 is v2, then runs $2.
opencode_stub() {
  local help='      --agent        agent to use'
  [ "$1" = v2 ] && help='      --standalone   run in a private server\n      --agent        agent to use'
  # shellcheck disable=SC2016 # expanded by the stub, not here
  printf 'if [ "$1 $2" = "run --help" ]; then printf "%s\\n"; exit 0; fi\n%s' "${help}" "$2"
}

@test "opencode runs standalone with the input attached as a file" {
  # shellcheck disable=SC2016 # expanded by the stub, not here
  harness opencode "$(opencode_stub v2 'while [ $# -gt 0 ]; do [ "$1" = --file ] && cp "$2" "'"${BATS_TEST_TMPDIR}"'/attached"; shift; done; '"${reply}")"
  describe opencode "${note}"
  [ "${status}" -eq 0 ]
  [ "$(sed -n 1p "${args_file}")" = "run" ]
  [ "$(sed -n 2p "${args_file}")" = "--standalone" ]
  grep -qxF "CONTEXT-SENTINEL" "${BATS_TEST_TMPDIR}/attached"
}

@test "opencode denies edits and every command but read-only ones" {
  # shellcheck disable=SC2016 # expanded by the stub, not here
  harness opencode "$(opencode_stub v2 'printf "%s" "${OPENCODE_CONFIG_CONTENT}" >"'"${BATS_TEST_TMPDIR}"'/config"; '"${reply}")"
  describe opencode "${note}"
  [ "${status}" -eq 0 ]
  config="$(cat "${BATS_TEST_TMPDIR}/config")"
  [ "$(jq -r '.permission.edit' <<<"${config}")" = "deny" ]
  [ "$(jq -r '.permission.webfetch' <<<"${config}")" = "deny" ]
  [ "$(jq -r '.permission.bash["*"]' <<<"${config}")" = "deny" ]
  [ "$(jq -r '.permission.bash["git diff*"]' <<<"${config}")" = "allow" ]
  [ "$(jq -r '.permission.bash["*>*"]' <<<"${config}")" = "deny" ]
}

@test "opencode without --standalone fails before the session runs" {
  # shellcheck disable=SC2016 # expanded by the stub, not here
  harness opencode "$(opencode_stub v1 'touch "'"${BATS_TEST_TMPDIR}"'/ran"; '"${reply}")"
  describe opencode "${note}"
  [ "${status}" -eq 1 ]
  has_line "SESSION_EXIT=unsupported"
  [ ! -e "${BATS_TEST_TMPDIR}/ran" ]
}

@test "claude runs in plan mode without saving the session" {
  harness claude "${reply}"
  describe claude "${note}"
  [ "${status}" -eq 0 ]
  [ "$(sed -n 1p "${args_file}")" = "-p" ]
  grep -qxF -- "--no-session-persistence" "${args_file}"
  grep -qxF -- "--permission-mode" "${args_file}"
  [ "$(grep -A1 -xF -- "--permission-mode" "${args_file}" | tail -n 1)" = "plan" ]
}
