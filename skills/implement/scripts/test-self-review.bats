#!/usr/bin/env bats
# Tests for self-review.sh, using a stub reviewer CLI on PATH.
# shellcheck disable=SC2292 # bats fails a test on a mid-test `[[ ]]` only under bash 4.1+; `[ ]` works on every bash.
# shellcheck disable=SC2030,SC2031 # result_line reads ${lines} inside the same @test subshell that `run` set it in.

setup() {
  target="${BATS_TEST_DIRNAME}/self-review.sh"
  work="${BATS_TEST_TMPDIR}"
}

new_repo() {
  local d
  d="$(mktemp -d "${work}/repo.XXXXXX")"
  git -C "${d}" init -q -b main
  echo a >"${d}/tracked.txt"
  git -C "${d}" add .
  git -C "${d}" -c core.hooksPath=/dev/null -c user.name=t -c user.email=t@t commit -q -m init
  echo b >>"${d}/tracked.txt"
  echo u >"${d}/untracked.txt"
  echo "${d}"
}

# Runs self-review.sh against a fresh repo with a stub harness CLI (default `claude`) whose body is $1,
# after running setup $2 in the repo.
run_stub() {
  local repo bin harness="${3:-claude}"
  repo="$(new_repo)"
  (cd "${repo}" && eval "${2:-true}")
  bin="$(mktemp -d "${work}/bin.XXXXXX")"
  printf '#!/bin/sh\n%s\n' "$1" >"${bin}/${harness}"
  chmod +x "${bin}/${harness}"
  cd "${repo}" || return 1
  run env TMPDIR="${work}" PATH="${bin}:${PATH}" bash "${target}" "${harness}" "${repo}"
}

# Prints a stub OpenCode body that answers `run --help` as OpenCode $1 would, then runs $2.
# v2 offers `--standalone`; v1 is a 1.x release offering only `--command`; none offers neither.
# Help text must not contain `%`.
opencode_stub() {
  local help
  case "$1" in
  v2) help='      --standalone   run in a private server\n      --agent        agent to use' ;;
  v1) help='      --command      the command to run, use message for args\n      --agent        agent to use' ;;
  none) help='      --agent        agent to use' ;;
  esac
  # shellcheck disable=SC2016 # expanded by the stub, not here
  printf 'if [ "$1 $2" = "run --help" ]; then printf "%s\\n"; exit 0; fi\n%s' "${help}" "$2"
}

# Prints the flags in the opencode argv echoed as `ARGS: ...` by the stub, one per line.
argv_flags() {
  local argv arg
  argv="$(sed -n 's/^ARGS: //p' <<<"${output}")"
  [ "${argv#run }" != "${argv}" ] || return 1
  for arg in ${argv#run }; do
    case "${arg}" in -*) printf '%s\n' "${arg}" ;; esac
  done
}

# Succeeds when the output has a line exactly equal to $1.
has_line() {
  printf '%s\n' "${lines[@]}" | grep -qxF -- "$1"
}

# Mirrors OpenCode's Wildcard.match: `*` and `?` are wildcards, a trailing ` *` also matches nothing, anchored.
wildcard_re() {
  local re
  re="$(printf '%s' "$1" | sed -e 's/[]\\.+^${}()|[]/\\&/g' -e 's/\*/.*/g' -e 's/?/./g')"
  [[ "${re}" == *" .*" ]] && re="${re% .\*}( .*)?"
  printf '^%s$' "${re}"
}

# Prints the bash permission OpenCode resolves for command $1 under ${config}; the last matching rule wins.
bash_permission() {
  local verdict=none action pattern re
  while IFS=$'\t' read -r action pattern; do
    re="$(wildcard_re "${pattern}")"
    [[ "$1" =~ ${re} ]] && verdict="${action}"
  done < <(jq -r '.permission.bash | to_entries[] | "\(.value)\t\(.key)"' <<<"${config}")
  printf '%s' "${verdict}"
}

# Sets ${config} to the OpenCode config self-review.sh passes to the reviewer.
load_opencode_config() {
  # shellcheck disable=SC2016 # expanded by the stub, not here
  run_stub "$(opencode_stub v2 'printf "%s" "${OPENCODE_CONFIG_CONTENT}" | jq -c .; echo; echo "REVIEW_VERDICT: none"')" '' opencode
  [ "${status}" -eq 0 ]
  config="$(grep -m1 '^{' <<<"${output}")"
  [ -n "${config}" ]
}

# Fails listing every command in $2.. whose resolved permission is not $1.
expect_permission() {
  local want="$1" c bad=()
  shift
  for c in "$@"; do
    [[ "$(bash_permission "${c}")" == "${want}" ]] || bad+=("${c}")
  done
  if [ "${#bad[@]}" -ne 0 ]; then
    printf 'not %s: %s\n' "${want}" "${bad[@]}"
    return 1
  fi
}

@test "clean run exits 0 and prints the output" {
  run_stub 'echo "no findings"'
  [ "${status}" -eq 0 ]
  has_line "no findings"
}

@test "reviewer failure exits 1 and reports its code" {
  run_stub 'echo boom; exit 3'
  [ "${status}" -eq 1 ]
  has_line "REVIEWER_EXIT=3"
}

@test "edit to a tracked file exits 3" {
  run_stub 'echo c >> tracked.txt'
  [ "${status}" -eq 3 ]
}

@test "new untracked file exits 3" {
  run_stub 'touch pwned.txt'
  [ "${status}" -eq 3 ]
}

@test "edit to an existing untracked file exits 3" {
  run_stub 'echo x >> untracked.txt'
  [ "${status}" -eq 3 ]
}

@test "staging change exits 3" {
  run_stub 'git add tracked.txt'
  [ "${status}" -eq 3 ]
}

@test "new file with a quoted name exits 3" {
  run_stub 'printf 1 > "日本語.txt"'
  [ "${status}" -eq 3 ]
}

@test "edit to an existing untracked file with a quoted name exits 3" {
  run_stub 'echo 2 >> "日本語.txt"' 'echo 1 > "日本語.txt"'
  [ "${status}" -eq 3 ]
}

@test "worktree change wins over reviewer failure" {
  run_stub 'echo x >> tracked.txt; exit 1'
  [ "${status}" -eq 3 ]
}

@test "gitignored output is not a change" {
  run_stub 'echo out/ >> .git/info/exclude; mkdir out; touch out/x; echo ok'
  [ "${status}" -eq 0 ]
}

@test "output without trailing newline stays on its own line" {
  run_stub 'printf "finding without newline"'
  [ "${status}" -eq 0 ]
  has_line "finding without newline"
}

@test "opencode passes the review prompt as the message and asks for one command per call" {
  # shellcheck disable=SC2016 # expanded by the stub, not here
  run_stub "$(opencode_stub v2 'echo "ARGS: $*"; echo "REVIEW_VERDICT: none"')" '' opencode
  [ "${status}" -eq 0 ]
  grep -qF -- "ARGS: run --standalone Review the uncommitted changes." <<<"${output}"
  grep -qF -- "one command per bash call" <<<"${output}"
  if grep -qF -- "--agent" <<<"${output}"; then return 1; fi
}

# OpenCode v2 needs `--standalone` because its shared background service ignores OPENCODE_CONFIG_CONTENT,
# which would leave the deny block below inert.
@test "opencode runs the review standalone, and --standalone is its only flag" {
  # shellcheck disable=SC2016 # expanded by the stub, not here
  run_stub "$(opencode_stub v2 'echo "ARGS: $*"; echo "REVIEW_VERDICT: none"')" '' opencode
  [ "${status}" -eq 0 ]
  [ "$(argv_flags)" = "--standalone" ]
}

@test "opencode without --standalone fails before the review runs" {
  # shellcheck disable=SC2016 # expanded by the stub, not here
  run_stub "$(opencode_stub none 'echo "ARGS: $*"')" '' opencode
  [ "${status}" -eq 1 ]
  if grep -qF -- "ARGS:" <<<"${output}"; then return 1; fi
  grep -qF -- "Unsupported OpenCode CLI" <<<"${output}"
  has_line "REVIEWER_EXIT=unsupported"
}

# A 1.x release that offers `--command` is still refused: only v2 is supported.
@test "opencode 1.x offering only --command fails closed" {
  # shellcheck disable=SC2016 # expanded by the stub, not here
  run_stub "$(opencode_stub v1 'echo "ARGS: $*"')" '' opencode
  [ "${status}" -eq 1 ]
  if grep -qF -- "ARGS:" <<<"${output}"; then return 1; fi
  has_line "REVIEWER_EXIT=unsupported"
}

@test "missing opencode reports the probe's exit code" {
  if PATH=/usr/bin:/bin command -v opencode >/dev/null; then skip "opencode is on the system PATH"; fi
  run env TMPDIR="${work}" PATH=/usr/bin:/bin bash "${target}" opencode "$(new_repo)"
  [ "${status}" -eq 1 ]
  has_line "REVIEWER_EXIT=127"
}

@test "opencode uses only flags the installed CLI accepts" {
  local real
  real="$(command -v opencode)" || skip "opencode is not installed"
  # shellcheck disable=SC2016 # expanded by the stub, not here
  run_stub "if [ \"\$1 \$2\" = \"run --help\" ] || [ \"\$1\" = --version ]; then exec '${real}' \"\$@\"; fi"'
echo "ARGS: $*"; echo "REVIEW_VERDICT: none"' '' opencode
  [ "${status}" -eq 0 ]
  flags="$(argv_flags)"
  [ -n "${flags}" ]
  help="$("${real}" run --help 2>&1)"
  while IFS= read -r arg; do
    grep -qE -- "(^|[[:space:]])${arg}([[:space:],=]|$)" <<<"${help}" || {
      printf 'the installed opencode rejects %s\n' "${arg}"
      return 1
    }
  done <<<"${flags}"
}

@test "opencode allows read-only review commands" {
  load_opencode_config
  expect_permission allow "git diff" "git diff --cached" "git status --short" "git log -5" "git show HEAD" \
    "git ls-files" "git branch --show-current" "git rev-parse HEAD" "git merge-base HEAD origin/main" \
    "git blame main.go" "echo ---" "head -n 20 main.go" "cat AGENTS.md" "ls" "ls -la pkg" "rg -n foo" "go vet ./..." "go test ./..." \
    "go test -run TestX ./pkg/..."
}

@test "opencode denies writes and commands that run another program" {
  load_opencode_config
  expect_permission deny "git branch new" "git commit -m x" "git checkout ." "git diff --output=x" \
    "rm -rf x" "make" "echo x > f" "echo x >> f" "cat a > b" "go test -exec sh ./..." "go test -toolexec x ./..." \
    "go vet -vettool=x ./..." "go build ./..." "rg --pre sh foo" "rg --pre=sh foo" "rg --hostname-bin=sh foo"
}

@test "opencode reviewer writing a file exits 3" {
  run_stub "$(opencode_stub v2 'touch pwned.txt')" '' opencode
  [ "${status}" -eq 3 ]
  has_line "REVIEWER_CHANGED_WORKTREE"
}

@test "temp files are removed" {
  run_stub 'true'
  [ "$(find "${work}" -maxdepth 1 -type f | wc -l | tr -d ' ')" -eq 0 ]
}

# Prints a repo whose `main` gained a commit after `feature` branched from it, with two commits on
# `feature` checked out and a clean worktree, so only committed changes are left to review.
new_range_repo() {
  local d
  d="$(mktemp -d "${work}/range.XXXXXX")"
  g() { git -C "${d}" -c core.hooksPath=/dev/null -c user.name=t -c user.email=t@t "$@"; }
  g init -q -b main
  echo a >"${d}/tracked.txt"
  g add .
  g commit -q -m init
  g switch -q -c feature
  for n in 1 2; do
    echo "${n}" >>"${d}/tracked.txt"
    g commit -q -am "cycle ${n}"
  done
  g switch -q main
  echo m >"${d}/main.txt"
  g add .
  g commit -q -m later
  g switch -q feature
  echo "${d}"
}

# Runs self-review.sh in range mode against main on a fresh range repo, with a stub harness CLI whose body
# is $1; sets ${mb} to the merge base the review must start at.
run_range_stub() {
  local repo bin harness="${2:-claude}"
  repo="$(new_range_repo)"
  mb="$(git -C "${repo}" merge-base main feature)"
  bin="$(mktemp -d "${work}/bin.XXXXXX")"
  printf '#!/bin/sh\n%s\n' "$1" >"${bin}/${harness}"
  chmod +x "${bin}/${harness}"
  cd "${repo}" || return 1
  run env TMPDIR="${work}" PATH="${bin}:${PATH}" bash "${target}" "${harness}" "${repo}" main
}

@test "claude reviews the uncommitted changes without pinning a level" {
  # shellcheck disable=SC2016 # expanded by the stub, not here
  run_stub 'echo "ARGS: $*"'
  [ "${status}" -eq 0 ]
  has_line "ARGS: -p /code-review --permission-mode plan --no-session-persistence"
}

@test "claude reviews the committed range from the merge base with a clean worktree" {
  # shellcheck disable=SC2016 # expanded by the stub, not here
  run_range_stub 'echo "ARGS: $*"'
  [ "${status}" -eq 0 ]
  has_line "ARGS: -p /code-review ${mb}..HEAD --permission-mode plan --no-session-persistence"
}

@test "a base at the first pass's HEAD narrows the review to the fix delta" {
  local repo bin first
  repo="$(new_range_repo)"
  first="$(git -C "${repo}" rev-parse HEAD)"
  echo fix >>"${repo}/tracked.txt"
  git -C "${repo}" -c core.hooksPath=/dev/null -c user.name=t -c user.email=t@t commit -q -am fix
  bin="$(mktemp -d "${work}/bin.XXXXXX")"
  # shellcheck disable=SC2016 # expanded by the stub, not here
  printf '#!/bin/sh\necho "ARGS: $*"\n' >"${bin}/claude"
  chmod +x "${bin}/claude"
  run env TMPDIR="${work}" PATH="${bin}:${PATH}" bash "${target}" claude "${repo}" "${first}"
  [ "${status}" -eq 0 ]
  has_line "ARGS: -p /code-review ${first}..HEAD --permission-mode plan --no-session-persistence"
  # The first pass over the same repo still starts at the merge base with main.
  run env TMPDIR="${work}" PATH="${bin}:${PATH}" bash "${target}" claude "${repo}" main
  [ "${status}" -eq 0 ]
  has_line "ARGS: -p /code-review $(git -C "${repo}" merge-base main HEAD)..HEAD --permission-mode plan --no-session-persistence"
}

@test "codex reviews against the merge base instead of the uncommitted changes" {
  # Codex writes its review to the -o file, so the stub echoes its argv there.
  # shellcheck disable=SC2016 # expanded by the stub, not here
  run_range_stub 'for a; do [ "${p:-}" = -o ] && f="$a"; p="$a"; done; echo "ARGS: $*" >"$f"' codex
  [ "${status}" -eq 0 ]
  grep -qF -- "ARGS: exec review --base ${mb} --ephemeral" <<<"${output}"
  if grep -qF -- "--uncommitted" <<<"${output}"; then return 1; fi
}

@test "opencode names the committed range in the review message" {
  # shellcheck disable=SC2016 # expanded by the stub, not here
  run_range_stub "$(opencode_stub v2 'echo "ARGS: $*"; echo "REVIEW_VERDICT: none"')" opencode
  [ "${status}" -eq 0 ]
  grep -qF -- "Review the committed changes in ${mb}..HEAD." <<<"${output}"
  if grep -qF -- "uncommitted" <<<"${output}"; then return 1; fi
}

@test "reviewer moving HEAD in range mode exits 3" {
  run_range_stub 'git -c core.hooksPath=/dev/null -c user.name=t -c user.email=t@t commit -q --allow-empty -m pwned'
  [ "${status}" -eq 3 ]
  has_line "REVIEWER_CHANGED_WORKTREE"
}

# Runs self-review.sh in range mode with base $1 and a claude stub that announces any call.
run_range_base() {
  local bin
  bin="$(mktemp -d "${work}/bin.XXXXXX")"
  printf '#!/bin/sh\necho REVIEWER_CALLED\n' >"${bin}/claude"
  chmod +x "${bin}/claude"
  run env TMPDIR="${work}" PATH="${bin}:${PATH}" bash "${target}" claude "$(new_range_repo)" "$1"
}

@test "unknown base exits 2 before the review runs" {
  run_range_base no-such-base
  [ "${status}" -eq 2 ]
  if has_line REVIEWER_CALLED; then return 1; fi
}

@test "base with no commits after it exits 2 before the review runs" {
  run_range_base feature
  [ "${status}" -eq 2 ]
  if has_line REVIEWER_CALLED; then return 1; fi
}

@test "unsupported harness exits 2" {
  run bash "${target}" gemini "$(new_repo)"
  [ "${status}" -eq 2 ]
}

@test "missing worktree exits 2" {
  run bash "${target}" claude "${work}/missing"
  [ "${status}" -eq 2 ]
}

@test "directory outside a Git worktree exits 2" {
  run bash "${target}" claude "$(mktemp -d "${work}/nogit.XXXXXX")"
  [ "${status}" -eq 2 ]
}

# The last line is the machine-readable outcome, so the caller never has to read the reviewer's prose.
result_line() {
  printf '%s\n' "${lines[@]}" | grep '^SELF_REVIEW ' | tail -n 1
}

@test "empty output exits 4, reports status=empty, and shows the log tail" {
  run_stub 'echo "reviewer log line" >&2'
  [ "${status}" -eq 4 ]
  has_line "reviewer log line"
  [[ "$(result_line)" == "SELF_REVIEW status=empty "* ]]
  # A negative array subscript needs bash 4.3; macOS ships bash 3.2, so index from the length instead.
  [ "${lines[${#lines[@]} - 1]}" = "$(result_line)" ]
}

@test "whitespace-only output counts as empty" {
  run_stub 'printf " \n\t\n"'
  [ "${status}" -eq 4 ]
  [[ "$(result_line)" == *"status=empty "*"bytes=0" ]]
}

@test "reviewed output exits 0 with range, head, and bytes" {
  local head
  run_stub 'printf hello'
  [ "${status}" -eq 0 ]
  head="$(git rev-parse HEAD)"
  [ "$(result_line)" = "SELF_REVIEW status=reviewed range=uncommitted head=${head} bytes=5" ]
}

@test "range mode names the merge base and the reviewed HEAD" {
  run_range_stub 'printf hello'
  [ "${status}" -eq 0 ]
  [ "$(result_line)" = "SELF_REVIEW status=reviewed range=${mb}..$(git rev-parse HEAD) head=$(git rev-parse HEAD) bytes=5" ]
}

@test "reviewer failure reports status=failed" {
  run_stub 'echo boom; exit 3'
  [ "${status}" -eq 1 ]
  [[ "$(result_line)" == "SELF_REVIEW status=failed "* ]]
}

@test "unsupported opencode CLI reports status=failed" {
  # shellcheck disable=SC2016 # expanded by the stub, not here
  run_stub "$(opencode_stub none 'true')" '' opencode
  [ "${status}" -eq 1 ]
  [[ "$(result_line)" == "SELF_REVIEW status=failed "* ]]
}

@test "worktree change reports status=changed" {
  run_stub 'echo c >> tracked.txt; echo finding'
  [ "${status}" -eq 3 ]
  [[ "$(result_line)" == "SELF_REVIEW status=changed "* ]]
}

@test "a reviewer that changes the worktree and prints nothing exits 3, not 4" {
  run_stub 'touch pwned.txt'
  [ "${status}" -eq 3 ]
  [[ "$(result_line)" == "SELF_REVIEW status=changed "* ]]
}

@test "a reviewer that fails with no output still exits 1" {
  run_stub 'exit 2'
  [ "${status}" -eq 1 ]
}

@test "opencode asks the reviewer to end with a verdict line" {
  # shellcheck disable=SC2016 # expanded by the stub, not here
  run_stub "$(opencode_stub v2 'echo "ARGS: $*"; echo "REVIEW_VERDICT: none"')" '' opencode
  [ "${status}" -eq 0 ]
  grep -qF -- "REVIEW_VERDICT: findings" <<<"${output}"
  grep -qF -- "never end a turn with a progress message" <<<"${output}"
}

@test "opencode narration without a verdict exits 5, reports status=incomplete, and shows the tails" {
  run_stub "$(opencode_stub v2 'echo "Diff review done, now checking the tests."; echo "reviewer log line" >&2')" '' opencode
  [ "${status}" -eq 5 ]
  has_line "Diff review done, now checking the tests."
  has_line "reviewer log line"
  has_line "REVIEWER_NO_VERDICT"
  [[ "$(result_line)" == "SELF_REVIEW status=incomplete "* ]]
  [ "$(tail -n 1 <<<"${output}")" = "$(result_line)" ]
}

@test "opencode verdict followed by more text exits 5" {
  run_stub "$(opencode_stub v2 'echo "REVIEW_VERDICT: none"; echo "Now checking gofmt."')" '' opencode
  [ "${status}" -eq 5 ]
  [[ "$(result_line)" == "SELF_REVIEW status=incomplete "* ]]
}

@test "opencode findings with REVIEW_VERDICT: findings exit 0 and report verdict=findings" {
  run_stub "$(opencode_stub v2 'echo "main.go:3 nil dereference"; echo "REVIEW_VERDICT: findings"')" '' opencode
  [ "${status}" -eq 0 ]
  [[ "$(result_line)" == "SELF_REVIEW status=reviewed "*" verdict=findings" ]]
}

@test "opencode REVIEW_VERDICT: none exits 0 and reports verdict=none" {
  run_stub "$(opencode_stub v2 'echo "REVIEW_VERDICT: none"')" '' opencode
  [ "${status}" -eq 0 ]
  [[ "$(result_line)" == "SELF_REVIEW status=reviewed "*" verdict=none" ]]
}

# Writes a request file holding $1 and prints its path.
request_file() {
  local f
  f="$(mktemp "${work}/request.XXXXXX")"
  printf '%s\n' "$1" >"${f}"
  echo "${f}"
}

# Runs self-review.sh as a scope review of a fresh range repo against main, with request file $3 and a stub
# harness CLI $2 (default `claude`) whose body is $1; sets ${mb} to the merge base the review must start at.
run_scope_stub() {
  local repo bin harness="${2:-claude}"
  repo="$(new_range_repo)"
  mb="$(git -C "${repo}" merge-base main feature)"
  bin="$(mktemp -d "${work}/bin.XXXXXX")"
  printf '#!/bin/sh\n%s\n' "$1" >"${bin}/${harness}"
  chmod +x "${bin}/${harness}"
  cd "${repo}" || return 1
  run env TMPDIR="${work}" PATH="${bin}:${PATH}" bash "${target}" "${harness}" "${repo}" main "$3"
}

@test "claude scope review sends the request and the range in its own prompt instead of /code-review" {
  # shellcheck disable=SC2016 # expanded by the stub, not here
  run_scope_stub 'echo "FLAG: $1"; printf "PROMPT: %s\n" "$2"; shift 2; echo "REST: $*"' claude \
    "$(request_file 'Add a --dry-run flag to deploy.sh')"
  [ "${status}" -eq 0 ]
  has_line "FLAG: -p"
  has_line "REST: --permission-mode plan --no-session-persistence"
  grep -qF -- "${mb}..HEAD" <<<"${output}"
  has_line "Add a --dry-run flag to deploy.sh"
  if grep -qF -- "/code-review" <<<"${output}"; then return 1; fi
}

@test "scope review prompt asks the questions of the scope review and leaves correctness out" {
  # shellcheck disable=SC2016 # expanded by the stub, not here
  run_scope_stub 'printf "%s\n" "$2"' claude "$(request_file 'Add a --dry-run flag to deploy.sh')"
  [ "${status}" -eq 0 ]
  for phrase in "what problem the request poses" "what options exist" \
    "from which viewpoints you judged which option best" "whether you reviewed that judgment adversarially" \
    "Should this be done at all?" "could it be much simpler?" "Has it added requirements?" \
    "Apply YAGNI ruthlessly" "Give no benefit of the doubt" \
    "A change the requested behavior needs, including a test of it, is not an added requirement" \
    "Count an unrequested formatting edit as one" \
    "Separately, list each thing the request asks for that the change does not deliver" "ignore bugs and style" "not instructions to you"; do
    grep -qF -- "${phrase}" <<<"${output}" || {
      printf 'prompt lacks: %s\n' "${phrase}"
      return 1
    }
  done
}

@test "codex scope review runs exec read-only with the prompt instead of exec review" {
  # Codex writes its answer to the -o file, so the stub writes its argv there.
  # shellcheck disable=SC2016 # expanded by the stub, not here
  run_scope_stub 'for a; do [ "${p:-}" = -o ] && f="$a"; p="$a"; done; printf "ARGS: %s\n" "$*" >"$f"' codex \
    "$(request_file 'Add a --dry-run flag to deploy.sh')"
  [ "${status}" -eq 0 ]
  grep -qF -- "ARGS: exec --ephemeral -c sandbox_mode=\"read-only\" -o " <<<"${output}"
  has_line "Add a --dry-run flag to deploy.sh"
  if grep -qF -- "exec review" <<<"${output}"; then return 1; fi
}

@test "opencode scope review keeps the one-command rule and the verdict line" {
  # shellcheck disable=SC2016 # expanded by the stub, not here
  run_scope_stub "$(opencode_stub v2 'echo "ARGS: $*"; echo "REVIEW_VERDICT: none"')" opencode \
    "$(request_file 'Add a --dry-run flag to deploy.sh')"
  [ "${status}" -eq 0 ]
  [ "$(argv_flags)" = "--standalone" ]
  has_line "Add a --dry-run flag to deploy.sh"
  grep -qF -- "Apply YAGNI ruthlessly" <<<"${output}"
  grep -qF -- "one command per bash call" <<<"${output}"
  grep -qF -- "REVIEW_VERDICT: findings" <<<"${output}"
  [[ "$(result_line)" == "SELF_REVIEW status=reviewed range=${mb}..$(git rev-parse HEAD) "*" verdict=none" ]]
}

@test "request file without a base exits 2 before the review runs" {
  local bin
  bin="$(mktemp -d "${work}/bin.XXXXXX")"
  printf '#!/bin/sh\necho REVIEWER_CALLED\n' >"${bin}/claude"
  chmod +x "${bin}/claude"
  run env TMPDIR="${work}" PATH="${bin}:${PATH}" bash "${target}" claude "$(new_range_repo)" "" \
    "$(request_file 'Add a --dry-run flag to deploy.sh')"
  [ "${status}" -eq 2 ]
  if has_line REVIEWER_CALLED; then return 1; fi
}

@test "missing request file exits 2 before the review runs" {
  run_scope_stub 'echo REVIEWER_CALLED' claude "${work}/no-such-request"
  [ "${status}" -eq 2 ]
  if has_line REVIEWER_CALLED; then return 1; fi
}

@test "empty request file exits 2 before the review runs" {
  local empty
  empty="$(mktemp "${work}/request.XXXXXX")"
  run_scope_stub 'echo REVIEWER_CALLED' claude "${empty}"
  [ "${status}" -eq 2 ]
  if has_line REVIEWER_CALLED; then return 1; fi
}

@test "usage errors print no result line" {
  run bash "${target}" gemini "$(new_repo)"
  [ "${status}" -eq 2 ]
  [ -z "$(result_line)" ]
}
