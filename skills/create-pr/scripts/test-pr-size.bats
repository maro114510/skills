#!/usr/bin/env bats
# Tests for pr-size.sh, against a throwaway repository.
# shellcheck disable=SC2292 # bats fails a test on a mid-test `[[ ]]` only under bash 4.1+; `[ ]` works on every bash.

setup() {
  target="${BATS_TEST_DIRNAME}/pr-size.sh"
  repo="${BATS_TEST_TMPDIR}/repo"
  git init -q -b main "${repo}"
  cd "${repo}" || return 1
  git config user.name t
  git config user.email t@t
  git config core.hooksPath /dev/null
  mkdir -p src tests docs/design
  echo 'seed' >src/seed.sh
  commit "chore: init"
  base="$(git rev-parse HEAD)"
}

commit() {
  git add -A
  git commit -q -m "$1"
}

# Writes $2 new lines to file $1.
lines() {
  mkdir -p "$(dirname "$1")"
  seq 1 "$2" | sed 's/^/line /' >"$1"
}

# Writes .agents/skills.toml from stdin.
config() {
  mkdir -p .agents
  cat >.agents/skills.toml
}

paths_config() {
  config <<'EOF'
[paths]
tests = ["tests/**"]
generated = "gen/**"
design_docs = ["docs/design/**"]
EOF
  commit "chore: config"
  base="$(git rev-parse HEAD)"
}

size() {
  run bash "${target}" "${base}"
}

# Succeeds when the output holds line $1 exactly.
has_line() {
  printf '%s\n' "${output}" | grep -qxF -- "$1"
}

# Succeeds when some output line matches the extended regex $1.
has_match() {
  printf '%s\n' "${output}" | grep -qE -- "$1"
}

# Succeeds when no output line matches the extended regex $1; a bare `! has_match` would never fail a test.
lacks_match() {
  ! has_match "$1"
}

@test "400 production lines pass however many test lines come with them" {
  paths_config
  lines src/app.sh 400
  lines tests/app_test.sh 5000
  commit "feat: app"
  size
  [ "${status}" -eq 0 ]
  has_line "production: 400 lines (limit 400)"
  has_line "tests: 5000 lines, not counted"
  has_line "  tests/app_test.sh: test ([paths] tests)"
  has_line "result: pass"
}

@test "401 production lines fail" {
  lines src/app.sh 400
  lines src/more.sh 1
  commit "feat: app"
  size
  [ "${status}" -eq 1 ]
  has_line "production: 401 lines (limit 400)"
  has_line "fail: 401 production lines exceed the 400-line limit"
  has_line "result: fail"
}

@test "added and deleted lines both count as changed production lines" {
  lines src/app.sh 300
  commit "feat: app"
  base="$(git rev-parse HEAD)"
  lines src/app.sh 100
  sed -i.bak 's/^line /edited /' src/app.sh
  rm src/app.sh.bak
  commit "fix: app"
  size
  [ "${status}" -eq 0 ]
  # 100 lines rewritten and 200 removed: 100 added plus 300 deleted.
  has_line "production: 400 lines (limit 400)"
  has_line "  400  src/app.sh"
}

@test "a lockfile is not counted and is listed as a lockfile" {
  lines src/app.sh 10
  lines package-lock.json 900
  lines sub/go.sum 900
  commit "feat: deps"
  size
  [ "${status}" -eq 0 ]
  has_line "production: 10 lines (limit 400)"
  has_line "  package-lock.json: lockfile"
  has_line "  sub/go.sum: lockfile"
}

@test "a linguist-generated file is not counted and is listed as generated" {
  echo 'api/*.pb.go linguist-generated' >.gitattributes
  echo 'api/keep.pb.go -linguist-generated' >>.gitattributes
  lines api/x.pb.go 900
  lines api/keep.pb.go 3
  commit "feat: api"
  size
  [ "${status}" -eq 0 ]
  # .gitattributes itself is 2 production lines.
  has_line "production: 5 lines (limit 400)"
  has_line "  api/x.pb.go: generated (linguist-generated)"
  has_line "  3  api/keep.pb.go"
}

@test "a file under [paths] generated is not counted" {
  paths_config
  lines gen/out.sh 900
  commit "feat: gen"
  size
  [ "${status}" -eq 0 ]
  has_line "  gen/out.sh: generated ([paths] generated)"
  has_line "result: pass"
}

@test "a deleted file is not counted and is listed as deleted" {
  lines src/old.sh 900
  commit "feat: old"
  base="$(git rev-parse HEAD)"
  git rm -q src/old.sh
  lines src/new.sh 4
  commit "refactor: drop old"
  size
  [ "${status}" -eq 0 ]
  has_line "production: 4 lines (limit 400)"
  has_line "  src/old.sh: deleted"
}

@test "a renamed file counts only its edited lines" {
  lines src/old.sh 900
  commit "feat: old"
  base="$(git rev-parse HEAD)"
  git mv src/old.sh src/new.sh
  echo 'extra' >>src/new.sh
  commit "refactor: rename"
  size
  [ "${status}" -eq 0 ]
  has_line "production: 1 lines (limit 400)"
  has_line "  1  src/new.sh"
}

@test "a design doc mixed with production code fails" {
  paths_config
  lines docs/design/adr-1.md 30
  lines src/app.sh 5
  commit "docs: adr"
  size
  [ "${status}" -eq 1 ]
  has_line "  docs/design/adr-1.md: design doc ([paths] design_docs)"
  has_line "fail: design docs must land in their own PR, but the range also changes src/app.sh"
  has_line "result: fail"
}

@test "a design doc mixed with a test fails" {
  paths_config
  lines docs/design/adr-1.md 30
  lines tests/app_test.sh 5
  commit "docs: adr"
  size
  [ "${status}" -eq 1 ]
  has_line "fail: design docs must land in their own PR, but the range also changes tests/app_test.sh"
}

@test "a design doc alone, or with other docs, passes and counts no lines" {
  paths_config
  echo 'README.md linguist-documentation' >.gitattributes
  commit "chore: attributes"
  base="$(git rev-parse HEAD)"
  lines docs/design/adr-1.md 900
  lines README.md 10
  commit "docs: adr"
  size
  [ "${status}" -eq 0 ]
  has_line "production: 0 lines (limit 400)"
  has_line "docs: 910 lines, not counted"
  has_line "  README.md: docs (linguist-documentation)"
}

@test "a linguist-documentation file is reported as docs and does not count" {
  echo 'docs/** linguist-documentation' >.gitattributes
  commit "chore: attributes"
  base="$(git rev-parse HEAD)"
  lines docs/guide.md 600
  lines src/app.sh 400
  commit "feat: app"
  size
  [ "${status}" -eq 0 ]
  has_line "production: 400 lines (limit 400)"
  has_line "docs: 600 lines, not counted"
  has_line "  docs/guide.md: docs (linguist-documentation)"
}

@test "the output lists every excluded file with its reason, and every counted file with its lines" {
  paths_config
  echo 'api/*.pb.go linguist-generated' >.gitattributes
  echo 'notes/** linguist-documentation' >>.gitattributes
  lines src/gone.sh 3
  commit "feat: gone"
  base="$(git rev-parse HEAD)"
  git rm -q src/gone.sh
  lines src/app.sh 7
  lines tests/app_test.sh 2
  lines gen/out.sh 2
  lines api/x.pb.go 2
  lines yarn.lock 2
  lines notes/n.md 2
  printf '\0\1\2' >src/blob.bin
  commit "feat: all"
  size
  [ "${status}" -eq 0 ]
  has_line "counted:"
  has_line "  7  src/app.sh"
  has_line "excluded:"
  has_line "  src/gone.sh: deleted"
  has_line "  tests/app_test.sh: test ([paths] tests)"
  has_line "  gen/out.sh: generated ([paths] generated)"
  has_line "  api/x.pb.go: generated (linguist-generated)"
  has_line "  yarn.lock: lockfile"
  has_line "  notes/n.md: docs (linguist-documentation)"
  has_line "  src/blob.bin: binary"
  has_line "production: 7 lines (limit 400)"
}

@test "a path with spaces is classified and listed" {
  paths_config
  lines "tests/my test.sh" 3
  lines "src/my app.sh" 3
  commit "feat: spaces"
  size
  [ "${status}" -eq 0 ]
  has_line "  tests/my test.sh: test ([paths] tests)"
  has_line "  3  src/my app.sh"
}

@test "without a config file only the built-in exclusions apply, and the output says so" {
  lines tests/app_test.sh 401
  commit "test: app"
  size
  [ "${status}" -eq 1 ]
  has_line "config: no .agents/skills.toml, so only the built-in exclusions apply: deleted, lockfile, linguist-generated, linguist-documentation"
  has_line "production: 401 lines (limit 400)"
}

@test "without a [paths] section only the built-in exclusions apply, and the output says so" {
  config <<'EOF'
[implement.testing]
run_one = "true"
EOF
  commit "chore: config"
  base="$(git rev-parse HEAD)"
  lines tests/app_test.sh 3
  lines Cargo.lock 900
  commit "test: app"
  size
  [ "${status}" -eq 0 ]
  has_line "config: no [paths] section in .agents/skills.toml, so only the built-in exclusions apply: deleted, lockfile, linguist-generated, linguist-documentation"
  has_line "  3  tests/app_test.sh"
  has_line "  Cargo.lock: lockfile"
  lacks_match ': test \('
}

@test "a [paths] section reports which keys it sets and which are unset" {
  config <<'EOF'
[paths]
tests = "tests/**"
EOF
  lines src/app.sh 1
  commit "feat: app"
  size
  [ "${status}" -eq 0 ]
  has_line "config: [paths] tests; unset: generated, design_docs"
}

@test "an invalid [paths] value is a config error" {
  config <<'EOF'
[paths]
tests = 3
EOF
  commit "chore: config"
  size
  [ "${status}" -eq 2 ]
  has_match 'paths\.tests must be a non-empty string or an array of them'
}

@test "an unknown base is a usage error" {
  run bash "${target}" no-such-ref
  [ "${status}" -eq 2 ]
  has_match 'Unknown base: no-such-ref'
}

@test "the range starts at the merge base, so commits only on the base are not counted" {
  git switch -q -c topic
  lines src/app.sh 5
  commit "feat: app"
  git switch -q main
  lines src/main-only.sh 900
  commit "feat: main"
  git switch -q topic
  run bash "${target}" main
  [ "${status}" -eq 0 ]
  has_line "production: 5 lines (limit 400)"
  lacks_match 'main-only'
}
