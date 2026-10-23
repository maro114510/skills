#!/usr/bin/env bash
# Checks the test policy over the non-merge commits in <base>..HEAD, with the target repository's own test runner.
# Usage: gate-tests.sh [<base>]
# Run from inside the repository. <base> defaults to origin/HEAD; the range starts at its merge base with HEAD.
#
# | Check         | Fails when |
# |---------------|------------|
# | before-change | A new or changed test case passes, or fails only with a build error, when the test files of its commit are applied to the commit's parent. refactor: commits are skipped |
# | isolation     | A test case new or changed in the range fails when run alone |
# | shuffle       | The test files changed in the range fail when run in shuffled order; the seed is always printed |
# | removed       | A test case in the base that is gone from HEAD is not named by a `Removed-Test: <name> -- <reason>` trailer in the range |
#
# Config: .agents/skills.toml at the repository root, read with Python 3.11+ tomllib. A check whose keys are
# missing is reported as not-run; without the file, every check is.
#
# | Key                                | Used by | Value |
# |------------------------------------|---------|-------|
# | `[paths] tests`                    | all | Git glob pathspecs of test files, as a string or an array |
# | `[implement.testing] test_case`    | before-change, isolation, removed | Python regex matching one line that declares a test case; group 1, or else the whole match, is its name |
# | `[implement.testing] run_one`      | before-change, isolation | Shell command running one test case, named by $TEST_NAME in file $TEST_FILE |
# | `[implement.testing] run_shuffled` | shuffle | Shell command running the test files given as "$@" in an order shuffled by the integer $TEST_SEED |
# | `[implement.testing] build_failure`| before-change | Python regex matching output that marks a build, import, or setup failure rather than a failed assertion |
# | `[implement.testing] setup`        | before-change, isolation, shuffle | Shell command run once, before the first check that runs a test |
#
# Commands run under bash from the repository root, or from a temporary worktree at the parent for before-change.
# That worktree holds only tracked files, and setup does not run in it, so run_one must install what it needs
# there, or build_failure must match the output of its absence.
# Values reach them only through the environment and arguments, never by substitution into the command text.
# A test case counts as changed when a changed non-blank line falls between its declaration and the next one,
# where the lines right above a declaration that a blank line sets apart, such as a comment or annotation, belong to it.
# isolation and shuffle run the working tree as it is, uncommitted edits included, but pick their tests from the
# commits only. Set GATE_TESTS_SEED to replay a shuffle.
#
# | Exit | Meaning |
# |------|---------|
# | 0    | Every check that ran passed |
# | 1    | A check failed |
# | 2    | Usage, repository, or config error |
# | 3    | setup failed; no check ran |
set -uo pipefail

die() {
  echo "gate-tests: $1" >&2
  exit 2
}

[[ $# -le 1 ]] || die "Usage: gate-tests.sh [<base>]"
top="$(git rev-parse --show-toplevel 2>/dev/null)" || die "Not inside a Git repository"
cd "${top}" || die "Cannot enter ${top}"
head="$(git rev-parse -q --verify 'HEAD^{commit}')" || die "HEAD has no commit"
base_ref="${1:-origin/HEAD}"
git rev-parse -q --verify "${base_ref}^{commit}" >/dev/null || die "Unknown base: ${base_ref}"
base="$(git merge-base "${base_ref}" HEAD)" || die "No merge base between ${base_ref} and HEAD"

seed="${GATE_TESTS_SEED:-$(((RANDOM << 15) | RANDOM))}"
[[ "${seed}" =~ ^[0-9]{1,18}$ ]] || die "GATE_TESTS_SEED must be a non-negative integer"

work="$(mktemp -d "${TMPDIR:-/tmp}/gate-tests.XXXXXX")" || die "Cannot create a temporary directory"
wt="${work}/parent"
# shellcheck disable=SC2329 # invoked by the EXIT trap
cleanup() {
  [[ -d "${wt}" ]] && git worktree remove --force "${wt}" >/dev/null 2>&1
  rm -rf "${work}"
}
trap cleanup EXIT

read -r -d '' PY <<'EOF'
import re, sys

def die(msg):
    print("gate-tests: " + msg, file=sys.stderr)
    sys.exit(2)

def read(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        return f.read()

def decls(rx, text):
    out = []
    for no, line in enumerate(text.splitlines(), 1):
        m = rx.search(line)
        if m:
            name = (m.group(1) if rx.groups else m.group(0)) or ""
            name = name.strip()
            if name and "\0" not in name:
                out.append((no, name))
    return out

def emit(names):
    seen = set()
    for n in names:
        if n not in seen:
            seen.add(n)
            sys.stdout.write(n + "\0")

cmd = sys.argv[1]
if cmd == "config":
    try:
        import tomllib
    except ImportError:
        die("reading .agents/skills.toml needs Python 3.11 or later")
    try:
        with open(sys.argv[2], "rb") as f:
            doc = tomllib.load(f)
    except (OSError, tomllib.TOMLDecodeError) as e:
        die(f"cannot read .agents/skills.toml: {e}")
    paths = doc.get("paths", {})
    impl = doc.get("implement", {})
    if not isinstance(paths, dict) or not isinstance(impl, dict):
        die("[paths] and [implement] must be tables")
    testing = impl.get("testing", {})
    if not isinstance(testing, dict):
        die("[implement.testing] must be a table")
    out = []
    tests = paths.get("tests")
    if tests is not None:
        if isinstance(tests, str):
            tests = [tests]
        if not isinstance(tests, list) or not tests or not all(isinstance(t, str) and t and "\0" not in t for t in tests):
            die("paths.tests must be a non-empty string or an array of them")
        out += [("tests", t) for t in tests]
    for key in ("test_case", "run_one", "run_shuffled", "build_failure", "setup"):
        v = testing.get(key)
        if v is None:
            continue
        if not isinstance(v, str) or not v.strip() or "\0" in v:
            die(f"implement.testing.{key} must be a non-empty string")
        if key in ("test_case", "build_failure"):
            try:
                re.compile(v)
            except re.error as e:
                die(f"implement.testing.{key} is not a valid regex: {e}")
        out.append((key, v))
    sys.stdout.write("".join(f"{k}\0{v}\0" for k, v in out))
elif cmd == "cases":
    # Names of the cases in new file argv[3] that hold a line changed by the -U0 diff in argv[4].
    # A case runs from its declaration, or from the lines right above it that a blank line sets apart, such as a
    # comment, decorator, or annotation, to the line before the next case. A blank line changes no case, so the
    # blank lines that separate an added case from the one above it never mark that one as changed.
    rx = re.compile(sys.argv[2])
    text = read(sys.argv[3])
    lines = text.splitlines()

    def blank(no):
        # Line 0 is the start of the file.
        return no < 1 or no > len(lines) or not lines[no - 1].strip()

    changed = set()
    hunk = re.compile(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@")
    deletion = None
    for line in read(sys.argv[4]).splitlines() + ["@@ -0 +0 @@"]:
        m = hunk.match(line)
        if m:
            # A pure deletion sits after line start. It changes the case holding that line only when it removes
            # text of that case, before the first case declaration it removes. Removed lines right above that
            # declaration, set apart by a blank line, belong to the removed case instead.
            if deletion is not None and (own or block):
                changed.add(deletion)
            start, count = int(m.group(1)), int(m.group(2) or 1)
            changed.update(no for no in range(start, start + count) if not blank(no))
            deletion, own, seen = (start if count == 0 else None), False, False
            block, block_after_blank, after_blank = False, False, blank(start)
        elif deletion is not None and line.startswith("-") and not seen:
            removed = line[1:]
            if rx.search(removed):
                seen = True
                own = own or (block and not block_after_blank)
                block = False
            elif not removed.strip():
                own = own or block
                block, after_blank = False, True
            else:
                if not block:
                    block, block_after_blank = True, after_blank
                after_blank = False
    found = decls(rx, text)
    starts = {no for no, _ in found}

    def first_line(no):
        top = no
        while not blank(top - 1) and top - 1 not in starts:
            top -= 1
        return top if top - 1 >= 1 and blank(top - 1) else no

    firsts = [first_line(no) for no, _ in found]
    names = []
    for i, (_, name) in enumerate(found):
        end = firsts[i + 1] - 1 if i + 1 < len(found) else float("inf")
        if any(firsts[i] <= c <= end for c in changed):
            names.append(name)
    emit(names)
elif cmd == "names":
    rx = re.compile(sys.argv[2])
    # Duplicates stay, so the removed check can count the cases of each name.
    sys.stdout.write("".join(n + "\0" for path in sys.argv[3:] for _, n in decls(rx, read(path))))
elif cmd == "match":
    sys.exit(0 if re.search(sys.argv[2], read(sys.argv[3]), re.M) else 1)
else:
    die("unknown helper command " + cmd)
EOF

py() {
  python3 -c "${PY}" "$@"
}

tests=()
test_case=""
run_one=""
run_shuffled=""
build_failure=""
setup=""
config="${top}/.agents/skills.toml"
if [[ -f "${config}" ]]; then
  command -v python3 >/dev/null 2>&1 || die "reading .agents/skills.toml needs python3"
  py config "${config}" >"${work}/config" || exit 2
  while IFS= read -r -d '' key && IFS= read -r -d '' value; do
    case "${key}" in
    tests) tests+=(":(glob)${value}") ;;
    test_case) test_case="${value}" ;;
    run_one) run_one="${value}" ;;
    run_shuffled) run_shuffled="${value}" ;;
    build_failure) build_failure="${value}" ;;
    setup) setup="${value}" ;;
    esac
  done <"${work}/config"
fi

# Prints the keys among $@, given as name=value, whose value is empty, as a not-run reason; prints nothing when
# none is missing.
missing() {
  local list="" pair
  for pair in "$@"; do
    [[ -n "${pair#*=}" ]] || list="${list:+${list}, }${pair%%=*}"
  done
  [[ -z "${list}" ]] || printf 'not-run (missing %s)' "${list}"
}

has_tests=""
[[ ${#tests[@]} -gt 0 ]] && has_tests=1
case_reason="$(missing "paths.tests=${has_tests}" "implement.testing.test_case=${test_case}" "implement.testing.run_one=${run_one}")"
shuffle_reason="$(missing "paths.tests=${has_tests}" "implement.testing.run_shuffled=${run_shuffled}")"
removed_reason="$(missing "paths.tests=${has_tests}" "implement.testing.test_case=${test_case}")"

# Prints the status and path of each test file changed between commits $1 and $2, NUL-separated, without renames.
changed_files() {
  git -c core.quotePath=false diff --no-ext-diff --no-renames --name-status -z "$1" "$2" -- "${tests[@]}"
}

# Prints the test cases changed between commits $1 and $2, as file and name pairs, NUL-separated.
changed_cases() {
  local status file name
  changed_files "$1" "$2" >"${work}/files" || return 1
  while IFS= read -r -d '' status && IFS= read -r -d '' file; do
    [[ "${status}" == D ]] && continue
    git cat-file blob "$2:${file}" >"${work}/new" || return 1
    git diff --no-color --no-ext-diff --no-renames -U0 "$1" "$2" -- "${file}" >"${work}/diff" || return 1
    py cases "${test_case}" "${work}/new" "${work}/diff" >"${work}/names" || return 1
    while IFS= read -r -d '' name; do
      printf '%s\0%s\0' "${file}" "${name}"
    done <"${work}/names"
  done <"${work}/files"
}

# Runs command $2 in directory $1 with the remaining arguments as "$@", output to ${work}/log.
run_in() {
  local dir="$1" command="$2"
  shift 2
  (cd "${dir}" && bash -c "${command}" gate-tests "$@") >"${work}/log" 2>&1 </dev/null
}

# Prints the end of the last command's output, indented.
show_log() {
  tail -n 20 "${work}/log" | sed 's/^/    | /'
}

short() {
  git rev-parse --short "$1"
}

failed=0
results=()

if [[ -n "${setup}" ]]; then
  if [[ -z "${case_reason}" || -z "${shuffle_reason}" ]]; then
    if ! run_in "${top}" "${setup}"; then
      echo "setup: fail"
      show_log
      exit 3
    fi
    results+=("setup: ran")
  else
    results+=("setup: not-run (no check runs a test)")
  fi
else
  results+=("setup: not-run (missing implement.testing.setup)")
fi

# before-change
if [[ -n "${case_reason}" ]]; then
  results+=("before-change: ${case_reason}")
  results+=("isolation: ${case_reason}")
else
  echo "[before-change]"
  [[ -n "${build_failure}" ]] ||
    echo "  no implement.testing.build_failure: any failure on the parent, even a missing dependency, counts as failing"
  verdict=pass
  for commit in $(git rev-list --reverse --no-merges "${base}..${head}"); do
    parent="$(git rev-parse -q --verify "${commit}^")" || continue
    changed_cases "${parent}" "${commit}" >"${work}/cases" || die "Cannot read the test changes of $(short "${commit}")"
    [[ -s "${work}/cases" ]] || continue
    if git log -1 --format=%s "${commit}" | grep -qE '^refactor(\([^)]*\))?!?:'; then
      echo "  $(short "${commit}"): skipped (refactor commit)"
      continue
    fi
    if [[ -d "${wt}" ]]; then
      git -C "${wt}" -c core.hooksPath=/dev/null checkout -q --detach --force "${parent}" &&
        git -C "${wt}" clean -q -d --force
    else
      git -c core.hooksPath=/dev/null worktree add -q --detach "${wt}" "${parent}"
    fi || die "Cannot check out $(short "${parent}") in ${wt}"
    changed_files "${parent}" "${commit}" >"${work}/files"
    while IFS= read -r -d '' status && IFS= read -r -d '' file; do
      if [[ "${status}" == D ]]; then
        rm -f "${wt}/${file}"
      else
        if ! mkdir -p "$(dirname "${wt}/${file}")" || ! git cat-file blob "${commit}:${file}" >"${wt}/${file}"; then
          die "Cannot apply ${file} from $(short "${commit}")"
        fi
      fi
    done <"${work}/files"
    where="$(short "${commit}") on parent $(short "${parent}")"
    while IFS= read -r -d '' file && IFS= read -r -d '' name; do
      if TEST_FILE="${file}" TEST_NAME="${name}" run_in "${wt}" "${run_one}"; then
        echo "  ${where}: ${file} ${name}: passed on the parent"
        verdict=fail
      elif [[ -n "${build_failure}" ]] && py match "${build_failure}" "${work}/log"; then
        echo "  ${where}: ${file} ${name}: failed with a build error on the parent"
        show_log
        verdict=fail
      else
        echo "  ${where}: ${file} ${name}: failed on the parent"
      fi
    done <"${work}/cases"
  done
  results+=("before-change: ${verdict}")
  [[ "${verdict}" == pass ]] || failed=1

  echo "[isolation]"
  verdict=pass
  changed_cases "${base}" "${head}" >"${work}/cases" || die "Cannot read the test changes of the range"
  while IFS= read -r -d '' file && IFS= read -r -d '' name; do
    if TEST_FILE="${file}" TEST_NAME="${name}" run_in "${top}" "${run_one}"; then
      echo "  ${file} ${name}: passed when run alone"
    else
      echo "  ${file} ${name}: failed when run alone"
      show_log
      verdict=fail
    fi
  done <"${work}/cases"
  results+=("isolation: ${verdict}")
  [[ "${verdict}" == pass ]] || failed=1
fi

if [[ -n "${shuffle_reason}" ]]; then
  results+=("shuffle: ${shuffle_reason}")
else
  echo "[shuffle] seed=${seed}"
  files=()
  changed_files "${base}" "${head}" >"${work}/files" || die "Cannot read the test changes of the range"
  while IFS= read -r -d '' status && IFS= read -r -d '' file; do
    [[ "${status}" == D ]] || files+=("${file}")
  done <"${work}/files"
  if [[ ${#files[@]} -eq 0 ]]; then
    results+=("shuffle: pass (no test file changed)")
  elif TEST_SEED="${seed}" run_in "${top}" "${run_shuffled}" "${files[@]}"; then
    results+=("shuffle: pass (seed=${seed})")
  else
    show_log
    results+=("shuffle: fail (seed=${seed})")
    failed=1
  fi
fi

if [[ -n "${removed_reason}" ]]; then
  results+=("removed: ${removed_reason}")
else
  echo "[removed]"
  verdict=pass
  : >"${work}/old-names"
  : >"${work}/new-names"
  changed_files "${base}" "${head}" >"${work}/files" || die "Cannot read the test changes of the range"
  while IFS= read -r -d '' status && IFS= read -r -d '' file; do
    if [[ "${status}" != A ]]; then
      if ! git cat-file blob "${base}:${file}" >"${work}/blob" || ! py names "${test_case}" "${work}/blob" >>"${work}/old-names"; then
        die "Cannot read the test cases of ${file} at the base"
      fi
    fi
    if [[ "${status}" != D ]]; then
      if ! git cat-file blob "${head}:${file}" >"${work}/blob" || ! py names "${test_case}" "${work}/blob" >>"${work}/new-names"; then
        die "Cannot read the test cases of ${file} at HEAD"
      fi
    fi
  done <"${work}/files"
  git log --no-merges --format='%(trailers:key=Removed-Test,valueonly,unfold)' "${base}..${head}" >"${work}/trailers"
  # A name comes from one line, so it holds no newline. comm keeps duplicates, so a name counts as deleted when
  # the changed files hold fewer cases of it at HEAD than at the base, and a case moved between files does not.
  tr '\0' '\n' <"${work}/new-names" | LC_ALL=C sort >"${work}/kept"
  tr '\0' '\n' <"${work}/old-names" | LC_ALL=C sort >"${work}/had"
  LC_ALL=C comm -23 "${work}/had" "${work}/kept" | LC_ALL=C sort -u >"${work}/gone"
  while IFS= read -r name; do
    covered=""
    # Git strips trailing whitespace from a trailer, so any text after the separator is a reason.
    while IFS= read -r line; do
      [[ "${line}" == "${name} -- "?* ]] && covered=1
    done <"${work}/trailers"
    if [[ -z "${covered}" ]]; then
      echo "  ${name}: deleted without a Removed-Test trailer"
      verdict=fail
    fi
  done <"${work}/gone"
  results+=("removed: ${verdict}")
  [[ "${verdict}" == pass ]] || failed=1
fi

printf '%s\n' "${results[@]}"
exit "${failed}"
