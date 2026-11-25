#!/usr/bin/env bats
# Tests that describe.sh (create-pr) and self-review.sh (implement) pin the same read-only sandbox per CLI.
# Each script launches a fresh session with its own copy of the pin, because each skill runs standalone.
# A fix to one copy that misses the other would leave one skill with a weaker sandbox than the other.
# Each script is run against a stub CLI that records the pin it was given; the pins are compared here and
# each script's own suite pins its own behavior.
# shellcheck disable=SC2292 # bats fails a test on a mid-test `[[ ]]` only under bash 4.1+; `[ ]` works on every bash.

setup() {
  # The developer's own git config and hooks must not reach the repositories built here.
  export GIT_CONFIG_GLOBAL="${BATS_TEST_TMPDIR}/gitconfig" GIT_CONFIG_NOSYSTEM=1
  unset GIT_CONFIG GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS
  : >"${GIT_CONFIG_GLOBAL}"
  skills="${BATS_TEST_DIRNAME}/../skills"

  # describe.sh reads SKILL.md and description.md beside it, and reruns pr-context.sh, which is a stub here.
  root="${BATS_TEST_TMPDIR}/skills"
  mkdir -p "${root}/create-pr/scripts" "${root}/create-pr/references"
  cp "${skills}/create-pr/scripts/describe.sh" "${root}/create-pr/scripts/"
  cp "${skills}/create-pr/SKILL.md" "${root}/create-pr/"
  cp "${skills}/create-pr/references/description.md" "${root}/create-pr/references/"
  printf '#!/bin/sh\necho CONTEXT\n' >"${root}/create-pr/scripts/pr-context.sh"

  repo="${BATS_TEST_TMPDIR}/repo"
  git init -q -b main "${repo}"
  echo a >"${repo}/tracked.txt"
  git -C "${repo}" add .
  git -C "${repo}" -c user.name=t -c user.email=t@t commit -q -m init
  echo "- What changed: the pin" >"${BATS_TEST_TMPDIR}/note.md"

  # One stub for every CLI. It answers the help probes both scripts run before the session, and records
  # the argv, the OpenCode config, and the DSH overlay that the session was launched with.
  bin="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "${bin}"
  cat >"${bin}/stub" <<'EOF'
#!/bin/sh
case "$*" in
"run --help") echo '      --standalone   run in a private server'; exit 0 ;;
"--help") echo '      --patch <path>  extra patch-list overlay'; exit 0 ;;
esac
printf '%s\n' "$@" >"${CAPTURE}.args"
printf '%s' "${OPENCODE_CONFIG_CONTENT:-}" >"${CAPTURE}.config"
p=
for a; do
  [ "${p}" = --patch ] && cp "${a}" "${CAPTURE}.pin"
  p="${a}"
done
cat >/dev/null
echo "REVIEW_VERDICT: none"
EOF
  chmod +x "${bin}/stub"
  for cli in claude codex opencode dsh; do ln -s stub "${bin}/${cli}"; done
}

# launch <describe|self-review> <harness>: runs the script against the stub, leaving what the session
# received in ${BATS_TEST_TMPDIR}/<script>.{args,config,pin}. The script's own exit code does not matter here.
launch() {
  local script="$1" harness="$2"
  cd "${repo}" || return 1
  export CAPTURE="${BATS_TEST_TMPDIR}/${script}"
  rm -f "${CAPTURE}".args "${CAPTURE}".config "${CAPTURE}".pin
  case "${script}" in
  describe) env TMPDIR="${BATS_TEST_TMPDIR}" PATH="${bin}:${PATH}" bash "${root}/create-pr/scripts/describe.sh" "${harness}" "${BATS_TEST_TMPDIR}/note.md" || true ;;
  self-review) env TMPDIR="${BATS_TEST_TMPDIR}" PATH="${bin}:${PATH}" bash "${skills}/implement/scripts/self-review.sh" "${harness}" "${repo}" || true ;;
  esac
  [ -s "${CAPTURE}.args" ]
}

# The OpenCode permission rules as `<rule>\t<action>` lines in the order the config states them,
# because the last matching rule wins.
opencode_rules() {
  jq -r '"edit\t\(.permission.edit)", "webfetch\t\(.permission.webfetch)", (.permission.bash | to_entries[] | "\(.key)\t\(.value)")' "${CAPTURE}.config"
}

@test "opencode pins the same permission rules in both scripts, apart from the go commands self-review.sh adds" {
  launch describe opencode
  opencode_rules >"${BATS_TEST_TMPDIR}/describe.rulelist"
  launch self-review opencode
  opencode_rules >"${BATS_TEST_TMPDIR}/self-review.rulelist"
  # self-review.sh lets its reviewer run the tests of the code it reviews; the writer of a PR description has no use for them.
  go_rules=$'^(go vet\\*|go test\\*|go \\*-exec\\*|go \\*-toolexec\\*|go vet\\*-vettool\\*)\t'
  grep -vE "${go_rules}" "${BATS_TEST_TMPDIR}/self-review.rulelist" >"${BATS_TEST_TMPDIR}/self-review.shared-rules"
  [ -s "${BATS_TEST_TMPDIR}/describe.rulelist" ]
  diff "${BATS_TEST_TMPDIR}/describe.rulelist" "${BATS_TEST_TMPDIR}/self-review.shared-rules"
}

@test "opencode launches both scripts standalone, so the pinned config is not ignored" {
  launch describe opencode
  grep -qxF -- "--standalone" "${CAPTURE}.args"
  launch self-review opencode
  grep -qxF -- "--standalone" "${CAPTURE}.args"
}

@test "dsh pins the same overlay in both scripts, apart from the preset name and description" {
  launch describe dsh
  # The preset name, its description, and the session root are specific to each script and run.
  normalize() { grep -vE '^(      [a-z-]+-read-only:| {8}name: | {8}description: |    defaultPreset: )' "$1" | sed 's|^    root: .*|    root: SESSIONS|'; }
  normalize "${CAPTURE}.pin" >"${BATS_TEST_TMPDIR}/describe.cmp"
  launch self-review dsh
  normalize "${CAPTURE}.pin" >"${BATS_TEST_TMPDIR}/self-review.cmp"
  grep -qxF "        sandbox: read-only" "${BATS_TEST_TMPDIR}/describe.cmp"
  diff "${BATS_TEST_TMPDIR}/describe.cmp" "${BATS_TEST_TMPDIR}/self-review.cmp"
}

@test "dsh runs both scripts with the overlay applied and no approval prompts" {
  for script in describe self-review; do
    launch "${script}" dsh
    grep -qxF -- "--patch" "${CAPTURE}.args"
    [ "$(grep -A1 -xF -- "--approval-policy" "${CAPTURE}.args" | tail -n 1)" = "never" ]
  done
}

@test "claude runs both scripts in plan mode without saving the session" {
  launch describe claude
  grep -xF -e "--permission-mode" -e "plan" -e "--no-session-persistence" "${CAPTURE}.args" >"${BATS_TEST_TMPDIR}/describe.cmp"
  launch self-review claude
  grep -xF -e "--permission-mode" -e "plan" -e "--no-session-persistence" "${CAPTURE}.args" >"${BATS_TEST_TMPDIR}/self-review.cmp"
  [ "$(wc -l <"${BATS_TEST_TMPDIR}/describe.cmp" | tr -d ' ')" -eq 3 ]
  diff "${BATS_TEST_TMPDIR}/describe.cmp" "${BATS_TEST_TMPDIR}/self-review.cmp"
}

@test "codex runs both scripts ephemeral in a read-only sandbox" {
  launch describe codex
  grep -xF -e "--ephemeral" -e 'sandbox_mode="read-only"' "${CAPTURE}.args" >"${BATS_TEST_TMPDIR}/describe.cmp"
  launch self-review codex
  grep -xF -e "--ephemeral" -e 'sandbox_mode="read-only"' "${CAPTURE}.args" >"${BATS_TEST_TMPDIR}/self-review.cmp"
  [ "$(wc -l <"${BATS_TEST_TMPDIR}/describe.cmp" | tr -d ' ')" -eq 2 ]
  diff "${BATS_TEST_TMPDIR}/describe.cmp" "${BATS_TEST_TMPDIR}/self-review.cmp"
}
