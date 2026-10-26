#!/usr/bin/env bats
# Tests for gate.sh. No test calls GitHub. Secret-like fixtures are built at run time.
# shellcheck disable=SC2292 # Use [ ] so bats fails on every bash.

setup() {
  scripts="${BATS_TEST_DIRNAME}"
  gate="${scripts}/gate.sh"
  tmp="${BATS_TEST_TMPDIR}"
  token="tok-1"

  # Ignore the user Git configuration
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
  export BABYSIT_REMOTE_BASE="file://${tmp}/srv"
  export BABYSIT_PR_STATE="${tmp}/pr-state"

  mkdir -p "${tmp}/srv/o" "${tmp}/bin"
  git init -q --bare -b main "${tmp}/srv/o/r.git"
  git init -q --bare -b main "${tmp}/srv/o/other.git"
  git clone -q "file://${tmp}/srv/o/r.git" "${tmp}/wt" 2>/dev/null
  cd "${tmp}/wt" || return 1
  git switch -q -c main
  printf 'base\n' >app.txt
  git add -- app.txt
  git commit -q -m base
  git push -q origin main
  git switch -q -c feat/x
  printf 'feature\n' >feature.txt
  git add -- feature.txt
  git commit -q -m feature
  git push -q origin feat/x
  start="$(git rev-parse HEAD)"

  # The pull request as pr-state prints it
  clean='{"repo":"o/r","number":7,"url":"https://github.com/o/r/pull/7","state":"OPEN","isDraft":false,
    "author":"me","viewer":"me","isCrossRepository":false,"baseRef":"main","headRef":"feat/x","head":"aaa"}'
  set_snap '.'
  printf '#!/usr/bin/env bash\n[ -e "%s/pr-state-fails" ] && exit 1\ncat "%s/snap.json"\n' "${tmp}" "${tmp}" >"${tmp}/pr-state"
  chmod +x "${tmp}/pr-state"

  # gh serves the default branch
  printf '{"default_branch":"main"}\n' >"${tmp}/repo.json"
  printf '#!/usr/bin/env bash\n[ -e "%s/gh-fails" ] && exit 1\ncat "%s/repo.json"\n' "${tmp}" "${tmp}" >"${tmp}/bin/gh"
  chmod +x "${tmp}/bin/gh"
  export PATH="${tmp}/bin:${PATH}"

  bash "${scripts}/ledger.sh" start o/r 7 "${token}" >/dev/null
}

# Writes the pull request after the jq edit $1.
set_snap() {
  jq -c "$1" <<<"${clean}" >"${tmp}/snap.json"
}

# Commits file $1 with content $2 and message $3.
commit_file() {
  mkdir -p "$(dirname "$1")"
  printf '%s\n' "$2" >"$1"
  git add -- "$1"
  git commit -q -m "${3:-change}"
}

# Runs the gate with the exact command for HEAD.
gate_push() {
  run_gate git push origin "$(git rev-parse HEAD):refs/heads/feat/x"
}

# Runs the gate with the command given.
run_gate() {
  run bash "${gate}" push o/r 7 --session "${token}" --worktree "${tmp}/wt" --start "${start}" -- "$@"
}

field() {
  jq -r "$1" <<<"${output}"
}

expect() {
  if [ "$1" != "$2" ]; then
    echo "expected [$2], got [$1]; output: ${output}" >&2
    return 1
  fi
}

# Expects refuse with $1 in the reason.
expect_refuse() {
  expect "${status}" 11
  expect "$(field .verdict)" refuse
  [[ "$(field .reason)" == *"$1"* ]] || {
    echo "reason [$(field .reason)] lacks [$1]" >&2
    return 1
  }
}

# Pushes HEAD and makes it the new start.
publish() {
  git push -q origin HEAD:refs/heads/feat/x
  start="$(git rev-parse HEAD)"
}

# Expects park with a match for category $1 and path $2.
expect_park() {
  expect "${status}" 10
  expect "$(field .verdict)" park
  jq -e --arg c "$1" --arg p "${2:-}" \
    '.matches | any(.category == $c and ($p == "" or .path == $p))' <<<"${output}" >/dev/null || {
    echo "no [$1] match for [${2:-any path}]; output: ${output}" >&2
    return 1
  }
}

# Secret-like strings built at run time.
github_token() {
  printf 'gh%s%s' 'p_' "$(printf 'A%.0s' $(seq 1 36))"
}
aws_key() {
  printf 'AK%s%s' 'IA' "$(printf 'B%.0s' $(seq 1 16))"
}

# Commits file $1 to the base branch and returns.
base_commit() {
  git switch -q main
  commit_file "$1" "$2" "base change"
  git push -q origin main
  git switch -q feat/x
}

# Expects exit 2 and a usage message.
expect_usage() {
  run bash "${gate}" "$@"
  expect "${status}" 2
  [[ "${output}" == *"Usage:"* ]] || {
    echo "no usage message for [$*]; output: ${output}" >&2
    return 1
  }
}

@test "rejects bad arguments with exit 2 and a usage message" {
  expect_usage
  expect_usage bogus o/r 7
  expect_usage push noslash 7 --session "${token}" --worktree "${tmp}/wt" --start "${start}" -- git push
  expect_usage push o/r 0 --session "${token}" --worktree "${tmp}/wt" --start "${start}" -- git push
  expect_usage push o/r 7 --worktree "${tmp}/wt" --start "${start}" -- git push
  expect_usage push o/r 7 --session "bad token" --worktree "${tmp}/wt" --start "${start}" -- git push
  expect_usage push o/r 7 --session "${token}" --worktree "${tmp}/wt" -- git push
  expect_usage push o/r 7 --session "${token}" --worktree "${tmp}/wt" --start nothex -- git push
  expect_usage push o/r 7 --session "${token}" --worktree "${tmp}/wt" --start "${start}"
  expect_usage push o/r 7 --session "${token}" --worktree "${tmp}/missing" --start "${start}" -- git push
  expect_usage push o/r 7 --session "${token}" --start "${start}" -- git push
  expect_usage push o/r 7 --session "${token}" --worktree "${tmp}/wt" --start "${start}" --unknown -- git push
}

@test "exits 3 when another session holds the lock" {
  commit_file src.txt fix
  run bash "${gate}" push o/r 7 --session other-session --worktree "${tmp}/wt" --start "${start}" -- \
    git push origin "$(git rev-parse HEAD):refs/heads/feat/x"
  [ "${status}" -eq 3 ]
}

@test "exits 3 when the lock was cleared" {
  commit_file src.txt fix
  bash "${scripts}/ledger.sh" stop o/r 7 "${token}"
  gate_push
  [ "${status}" -eq 3 ]
}

@test "allows an ordinary fix pushed as a fast-forward of the verified commit" {
  commit_file src.txt "return 1"
  gate_push
  expect "${status}" 0
  expect "$(field .verdict)" allow
  expect "$(field .head)" "$(git rev-parse HEAD)"
  expect "$(field .branch)" feat/x
  expect "$(field .start)" "${start}"
}

@test "refuses a pull request from a fork" {
  commit_file src.txt fix
  set_snap '.isCrossRepository = true'
  gate_push
  expect_refuse fork
}

@test "refuses a pull request when the cross-repository flag is unreadable" {
  commit_file src.txt fix
  set_snap 'del(.isCrossRepository)'
  gate_push
  expect_refuse fork
}

@test "refuses a pull request authored by someone else" {
  commit_file src.txt fix
  set_snap '.author = "mallory"'
  gate_push
  expect_refuse author
}

@test "refuses a pull request without a known author" {
  commit_file src.txt fix
  set_snap '.author = null'
  gate_push
  expect_refuse author
}

@test "refuses a closed pull request" {
  commit_file src.txt fix
  set_snap '.state = "CLOSED"'
  gate_push
  expect_refuse open
}

@test "refuses a merged pull request" {
  commit_file src.txt fix
  set_snap '.state = "MERGED"'
  gate_push
  expect_refuse open
}

@test "refuses a pull request whose snapshot is for another repository" {
  commit_file src.txt fix
  set_snap '.repo = "o/elsewhere"'
  gate_push
  expect_refuse "another pull request"
}

@test "refuses when the head branch is the default branch" {
  git switch -q main
  local main_tip
  main_tip="$(git rev-parse HEAD)"
  commit_file src.txt fix
  set_snap '.headRef = "main"'
  run bash "${gate}" push o/r 7 --session "${token}" --worktree "${tmp}/wt" --start "${main_tip}" -- \
    git push origin "$(git rev-parse HEAD):refs/heads/main"
  expect_refuse "default branch"
}

@test "refuses when the branch cannot be read from GitHub" {
  commit_file src.txt fix
  : >"${tmp}/gh-fails"
  gate_push
  expect_refuse "could not"
}

@test "refuses when the pull request cannot be read" {
  commit_file src.txt fix
  : >"${tmp}/pr-state-fails"
  gate_push
  expect_refuse "could not"
}

@test "refuses when the remote head has moved ahead of the start" {
  commit_file src.txt fix
  git clone -q "file://${tmp}/srv/o/r.git" "${tmp}/other" 2>/dev/null
  (
    cd "${tmp}/other" || exit 1
    git switch -q feat/x
    printf 'theirs\n' >theirs.txt
    git add -- theirs.txt
    git commit -q -m theirs
    git push -q origin feat/x
  )
  gate_push
  expect_refuse "moved"
}

@test "refuses when the remote branch does not exist" {
  commit_file src.txt fix
  git push -q origin --delete feat/x
  gate_push
  expect_refuse "moved"
}

@test "refuses when there is nothing new to push" {
  gate_push
  expect_refuse "nothing"
}

@test "refuses when the start commit is not an ancestor of HEAD" {
  commit_file src.txt fix
  git reset -q --hard "${start}^"
  gate_push
  expect_refuse "descend"
}

@test "refuses when origin fetches from another repository" {
  commit_file src.txt fix
  git remote set-url origin "file://${tmp}/srv/o/other.git"
  gate_push
  expect_refuse origin
}

@test "refuses when origin pushes to another repository" {
  commit_file src.txt fix
  git remote set-url --push origin "file://${tmp}/srv/o/other.git"
  gate_push
  expect_refuse origin
}

@test "refuses when a rewrite rule sends the push elsewhere" {
  commit_file src.txt fix
  git config "url.file://${tmp}/srv/o/other.git.pushInsteadOf" "file://${tmp}/srv/o/r.git"
  gate_push
  expect_refuse origin
}

@test "refuses an origin whose host hides behind a fragment or query that looks like userinfo" {
  local url
  commit_file src.txt fix
  for url in 'https://evil.example#@github.com/o/r' 'https://evil.example?x=@github.com/o/r'; do
    git remote set-url origin "${url}"
    gate_push
    expect_refuse origin
  done
}

@test "refuses a push command that differs from the verified one" {
  commit_file src.txt fix
  head="$(git rev-parse HEAD)"
  other="$(git rev-parse HEAD^)"
  local -a variants=(
    "git push --force origin ${head}:refs/heads/feat/x"
    "git push --force-with-lease=refs/heads/feat/x:${start} origin ${head}:refs/heads/feat/x"
    "git push origin +${head}:refs/heads/feat/x"
    "git push origin HEAD:refs/heads/feat/x"
    "git push origin ${head}:refs/heads/main"
    "git push origin ${other}:refs/heads/feat/x"
    "git push origin ${head}:refs/heads/feat/x --no-verify"
    "git push upstream ${head}:refs/heads/feat/x"
    "git push origin"
  )
  for variant in "${variants[@]}"; do
    # shellcheck disable=SC2086 # Split into words on purpose.
    run_gate ${variant}
    echo "variant: ${variant}" >&2
    expect_refuse "command"
  done
}

@test "prints exactly one JSON line for a refusal" {
  commit_file src.txt fix
  set_snap '.state = "CLOSED"'
  gate_push
  expect "$(wc -l <<<"${output}" | tr -d ' ')" 1
  jq -e 'has("verdict") and has("reason")' <<<"${output}" >/dev/null
}

@test "parks a change to CI and execution configuration" {
  local entry
  for entry in .github/workflows/ci.yml .gitlab-ci.yml .circleci/config.yml Makefile rules.mk sub/Dockerfile \
    compose.yaml prek.toml .husky/pre-commit .claude/settings.json AGENTS.md; do
    git reset -q --hard "${start}"
    commit_file "${entry}" "content"
    gate_push
    expect_park ci "${entry}"
  done
}

@test "parks the deletion of a CI file" {
  commit_file .github/workflows/ci.yml "name: ci"
  publish
  git rm -q .github/workflows/ci.yml
  git commit -q -m "drop ci"
  gate_push
  expect_park ci .github/workflows/ci.yml
}

@test "parks a change to dependencies" {
  local entry
  for entry in package.json package-lock.json yarn.lock pnpm-lock.yaml go.mod go.sum Cargo.lock pyproject.toml \
    requirements-dev.txt Gemfile.lock .gitmodules vendor/lib.go web/vendor/x.js; do
    git reset -q --hard "${start}"
    commit_file "${entry}" "content"
    gate_push
    expect_park deps "${entry}"
  done
}

@test "parks a moved submodule pointer" {
  git update-index --add --cacheinfo "160000,${start},sub"
  git commit -q -m "bump sub"
  gate_push
  expect_park deps sub
}

@test "parks a moved submodule pointer even when the submodule file tells Git to ignore it" {
  git update-index --add --cacheinfo "160000,${start},sub"
  printf '[submodule "sub"]\n\tpath = sub\n\turl = https://example.invalid/x.git\n\tignore = all\n' >.gitmodules
  git add -- .gitmodules
  git commit -q -m "add sub"
  publish
  git update-index --cacheinfo "160000,$(git rev-parse main),sub"
  git commit -q -m "move only the pointer"
  gate_push
  expect_park deps sub
}

@test "parks the deletion of a test file" {
  commit_file tests/login_test.go "func TestLogin() {}"
  publish
  git rm -q tests/login_test.go
  git commit -q -m "drop test"
  gate_push
  expect_park tests tests/login_test.go
}

@test "parks an added skip or focus in a test" {
  local entry path line
  for entry in "a.test.js|it.skip('x', () => {})" "a.test.js|describe.only('x', () => {})" \
    "a.spec.ts|xit('x', () => {})" "a_test.py|@pytest.mark.skip" "a_test.py|pytest.skip('later')" \
    "a_test.go|t.Skip(\"later\")" "a.bats|  skip" "A.java|@Disabled"; do
    path="${entry%%|*}"
    line="${entry#*|}"
    git reset -q --hard "${start}"
    commit_file "${path}" "${line}"
    gate_push
    expect_park tests "${path}"
  done
}

@test "parks an added coverage threshold" {
  commit_file .coveragerc "fail_under = 10"
  gate_push
  expect_park tests .coveragerc
}

@test "parks a removed coverage threshold" {
  commit_file .coveragerc "fail_under = 90"
  publish
  commit_file .coveragerc "[run]"
  gate_push
  expect_park tests .coveragerc
}

@test "parks the deletion of a coverage configuration file" {
  commit_file .coveragerc "fail_under = 90"
  publish
  git rm -q .coveragerc
  git commit -q -m "drop coverage config"
  gate_push
  expect_park tests .coveragerc
}

@test "parks a secret in added text" {
  local entry path content
  for entry in "key.txt|-----BEGIN RSA ""PRIVATE KEY-----" "gh.txt|$(github_token)" "aws.txt|$(aws_key)" \
    "cfg.js|const API_TOKEN = 'abcdefgh12345'" "cfg.py|password: \"hunter2hunter2\""; do
    path="${entry%%|*}"
    content="${entry#*|}"
    git reset -q --hard "${start}"
    commit_file "${path}" "${content}"
    gate_push
    expect_park secrets "${path}"
  done
}

@test "parks an unquoted secret assignment" {
  local entry path content
  for entry in "app.env.txt|AWS_SECRET_ACCESS_KEY=abcdefgh12345" "cfg.yml|password: hunter2hunter2" \
    "cfg.toml|api_token = abcdefgh12345" "run.sh|export DB_PASSWORD=abcdefgh12345;"; do
    path="${entry%%|*}"
    content="${entry#*|}"
    git reset -q --hard "${start}"
    commit_file "${path}" "${content}"
    gate_push
    expect_park secrets "${path}"
  done
}

@test "allows an assignment whose value is a reference or a call, not a literal" {
  commit_file run.sh $'PASSWORD=$DB_PASSWORD\nTOKEN=${TOKEN_VALUE}\nsecret=read_secret(name)\nkey=short'
  gate_push
  expect "${status}" 0
  expect "$(field .verdict)" allow
}

@test "parks a file that is named like a secret" {
  local entry
  for entry in "$(printf '.%s' env)" "$(printf '.%s.production' env)" certs/server.pem id_rsa config/credentials.json; do
    git reset -q --hard "${start}"
    commit_file "${entry}" "X=1"
    gate_push
    expect_park secrets "${entry}"
  done
}

@test "parks a secret that an earlier commit added and a later commit removed" {
  commit_file leak.txt "$(github_token)"
  git rm -q leak.txt
  git commit -q -m "remove it again"
  gate_push
  expect_park secrets leak.txt
}

@test "parks a secret in a commit message" {
  commit_file src.txt fix "fix with $(github_token)"
  gate_push
  expect_park secrets "commit message"
}

@test "parks outbound network access" {
  local entry path line
  for entry in "run.sh|curl -s example.invalid" "doc.md|see https://example.invalid/x" "a.js|fetch('/api')" \
    "a.py|requests.get(url)" "a.go|http.Get(url)" "a.js|new XMLHttpRequest()"; do
    path="${entry%%|*}"
    line="${entry#*|}"
    git reset -q --hard "${start}"
    commit_file "${path}" "${line}"
    gate_push
    expect_park network "${path}"
  done
}

@test "parks a binary file it cannot read" {
  printf '\000\001\002' >image.bin
  git add -- image.bin
  git commit -q -m "add image"
  gate_push
  expect_park binary image.bin
}

@test "lists every matched category, each once" {
  commit_file .github/workflows/ci.yml "name: ci"
  commit_file package.json "{}"
  commit_file run.sh "curl example.invalid"
  gate_push
  expect_park ci
  expect_park deps
  expect_park network
}

@test "parks a commit that a replace ref disguises as a harmless one" {
  local evil benign
  commit_file .github/workflows/ci.yml "name: evil"
  evil="$(git rev-parse HEAD)"
  git reset -q --hard "${start}"
  commit_file docs.md "doc"
  benign="$(git rev-parse HEAD)"
  git reset -q --hard "${evil}"
  git replace "${evil}" "${benign}"
  gate_push
  expect_park ci .github/workflows/ci.yml
}

@test "parks a secret in the root commit of an unrelated history that a merge then drops" {
  git switch -q --orphan unrelated
  commit_file leak.txt "$(github_token)"
  git switch -q feat/x
  git merge -q --allow-unrelated-histories --no-commit --no-ff unrelated
  git rm -q -f leak.txt
  git commit -q -m "merge, without the file"
  gate_push
  expect_park secrets leak.txt
}

@test "parks a secret even when the caller's environment changes how Git reads paths" {
  local variable
  commit_file cfg.txt "$(github_token)"
  for variable in GIT_LITERAL_PATHSPECS GIT_GLOB_PATHSPECS GIT_NOGLOB_PATHSPECS GIT_ICASE_PATHSPECS; do
    export "${variable}=1"
    gate_push
    echo "variable: ${variable}" >&2
    unset "${variable}"
    expect_park secrets cfg.txt
  done
}

@test "parks a secret when the worktree given is a subdirectory of the checkout" {
  commit_file docs/guide.md "Run the tests."
  publish
  commit_file docs/secret-note.txt "$(github_token)"
  run bash "${gate}" push o/r 7 --session "${token}" --worktree "${tmp}/wt/docs" --start "${start}" -- \
    git push origin "$(git rev-parse HEAD):refs/heads/feat/x"
  expect_park secrets docs/secret-note.txt
}

@test "refuses before parking when an allow condition fails" {
  commit_file .github/workflows/ci.yml "name: ci"
  set_snap '.isCrossRepository = true'
  gate_push
  expect_refuse fork
}

@test "allows a new test file, an edited test, a removed source file, and a docs change" {
  commit_file calc_test.py $'def test_add():\n    assert add(1, 1) == 2'
  publish
  commit_file calc_test.py $'def test_add():\n    assert add(1, 1) == 2\n    assert add(2, 2) == 4\n\ndef test_sub():\n    assert sub(2, 1) == 1'
  commit_file docs/guide.md "Run the tests with make test."
  git rm -q feature.txt
  git commit -q -m "drop unused file"
  gate_push
  expect "${status}" 0
  expect "$(field .verdict)" allow
}

@test "parks a merge of the base that brings in a workflow and a lockfile" {
  base_commit .github/workflows/ci.yml "name: base ci"
  base_commit package-lock.json "{}"
  git merge -q --no-ff -m "merge main" main
  gate_push
  expect_park ci .github/workflows/ci.yml
  expect_park deps package-lock.json
}

@test "rejects a reply call, which the gate does not handle" {
  printf 'Thanks.\n' >"${tmp}/body.txt"
  expect_usage reply o/r 7 --session "${token}" --body-file "${tmp}/body.txt"
}

@test "inspects a merge of a branch other than the base in full" {
  git switch -q -c other main
  commit_file .github/workflows/ci.yml "name: other ci"
  git switch -q feat/x
  git merge -q --no-ff -m "merge other" other
  gate_push
  expect_park ci .github/workflows/ci.yml
}

@test "inspects a merge of the base followed by another commit in full" {
  base_commit .github/workflows/ci.yml "name: base ci"
  git merge -q --no-ff -m "merge main" main
  commit_file src.txt fix
  gate_push
  expect_park ci .github/workflows/ci.yml
}
