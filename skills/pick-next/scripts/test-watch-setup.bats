#!/usr/bin/env bats
# Tests for watch-setup.sh. herdr-automate is a stub on PATH: check prints a plan, or fails while check.err exists,
# and status --json prints status.json. Any other call fails, so an approval would fail the test.
# shellcheck disable=SC2292 # bats fails a test on a mid-test `[[ ]]` only under bash 4.1+; `[ ]` works on every bash.

setup() {
  target="${BATS_TEST_DIRNAME}/watch-setup.sh"
  unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_PREFIX
  repo="${BATS_TEST_TMPDIR}/repo"
  git init -q -b main "${repo}"
  repo="$(cd "${repo}" && pwd -P)"
  cd "${repo}" || return 1
  git config user.email t@example.invalid
  git config user.name t
  git config core.hooksPath /dev/null
  git commit -q --allow-empty -m base
  git remote add origin git@github.com:o/r.git
  export HOME="${BATS_TEST_TMPDIR}/home"
  export HERDR_ENV=1
  file="${HOME}/.config/herdr-automate/automations/pick-next-o-r.luau"
  mkdir -p "${BATS_TEST_TMPDIR}/bin"
  PATH="${BATS_TEST_TMPDIR}/bin:${PATH}"
  echo '{"daemon":{"running":true,"paused_all":false}}' >"${BATS_TEST_TMPDIR}/status.json"
  cat >"${BATS_TEST_TMPDIR}/bin/herdr-automate" <<EOF
#!/usr/bin/env bash
case "\$*" in
"check \$2")
  if [ -e "${BATS_TEST_TMPDIR}/check.err" ]; then cat "${BATS_TEST_TMPDIR}/check.err"; exit 1; fi
  echo "plan of \$2" ;;
"status --json") cat "${BATS_TEST_TMPDIR}/status.json" ;;
*) echo "unexpected herdr-automate call: \$*" >&2; exit 1 ;;
esac
EOF
  chmod +x "${BATS_TEST_TMPDIR}/bin/herdr-automate"
}

expected_file() {
  local scripts
  scripts="$(cd "${BATS_TEST_DIRNAME}" && pwd -P)"
  cat <<EOF
-- Written by pick-next watch-setup.sh for o/r. Run /pick-next watch again to rewrite it.
herdr.caps { agents_per_run = 0, tokens_per_day = 0, wall_time = "2m" }

herdr.every("5m", { name = "pick-next-o-r" }, function()
  local v = sh("cd '${repo}' && PATH='${PATH}' bash '${scripts}/watch.sh'", { check = false, timeout = "1m" })
  if not v.ok then
    notify(v.log_tail)
  end
end)
EOF
}

@test "it writes the automation for this clone, checks it, and prints its path and plan" {
  run bash "${target}"
  [ "${status}" -eq 0 ]
  [ "$(cat "${file}")" = "$(expected_file)" ]
  [ "${lines[0]}" = "${file}" ]
  [ "${lines[1]}" = "plan of ${file}" ]
  [ "${#lines[@]}" -eq 2 ]
}

@test "from a linked worktree, the automation runs in the main worktree" {
  git worktree add -q "${BATS_TEST_TMPDIR}/linked"
  cd "${BATS_TEST_TMPDIR}/linked"
  run bash "${target}"
  [ "${status}" -eq 0 ]
  [ "$(cat "${file}")" = "$(expected_file)" ]
}

@test "running it again rewrites the same file" {
  run bash "${target}"
  run bash "${target}"
  [ "${status}" -eq 0 ]
  [ "$(cat "${file}")" = "$(expected_file)" ]
}

@test "a stopped daemon and paused scheduling are each named with the command that fixes them" {
  echo '{"daemon":{"running":false,"paused_all":true}}' >"${BATS_TEST_TMPDIR}/status.json"
  run bash "${target}"
  [ "${status}" -eq 0 ]
  [ "${lines[2]}" = "The herdr-automate daemon is not running: run herdr-automate start" ]
  [ "${lines[3]}" = "Scheduling is paused: run herdr-automate resume --all" ]
}

@test "a script herdr-automate check rejects exits 1 with its message" {
  echo "bad script" >"${BATS_TEST_TMPDIR}/check.err"
  run bash "${target}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"bad script"* ]]
}

@test "outside Herdr it exits 2 and writes nothing" {
  unset HERDR_ENV
  run bash "${target}"
  [ "${status}" -eq 2 ]
  [ ! -e "${file}" ]
}

@test "an origin not on GitHub exits 2 and writes nothing" {
  git remote set-url origin https://example.com/o/r.git
  run bash "${target}"
  [ "${status}" -eq 2 ]
  [ ! -e "${file}" ]
}

@test "a PATH holding a single quote exits 2 and writes nothing" {
  PATH="${PATH}:/tmp/it's" run bash "${target}"
  [ "${status}" -eq 2 ]
  [ ! -e "${file}" ]
}
