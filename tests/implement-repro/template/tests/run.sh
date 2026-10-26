#!/usr/bin/env bash
# Runs test files in one shell, so a global that one test sets is seen by the next, the way shared fixtures leak.
# Usage: run.sh [--seed N] [--only NAME] [FILE ...]
# A test is a test_* function. Without FILE, tests/test_*.sh run. They run in name order, or with --seed in an
# order shuffled by N, which differs between awk implementations. With --only just that test runs.
# A failed assert_* is printed as FAIL and any other failing test as ERROR.
# Exit: 0 all passed, 1 a test failed, 2 usage error or nothing to run.

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

assert_eq() { # expected actual
  [[ "$1" == "$2" ]] || {
    echo "  expected '$1', got '$2'"
    FAILED=1
    return 1
  }
}

assert_status() { # expected command...
  local want="$1" rc
  shift
  "$@"
  rc=$?
  [[ "${rc}" -eq "${want}" ]] || {
    echo "  '$*' exited ${rc}, expected ${want}"
    FAILED=1
    return 1
  }
}

die() {
  echo "ERROR: $1" >&2
  exit 2
}

seed="" only="" files=()
while [[ $# -gt 0 ]]; do
  case "$1" in
  --seed | --only)
    [[ $# -ge 2 ]] || die "$1 needs a value"
    [[ "$1" == --seed ]] && seed="$2" || only="$2"
    shift 2
    ;;
  *)
    files+=("$1")
    shift
    ;;
  esac
done
[[ -z "${seed}" || "${seed}" =~ ^[0-9]+$ ]] || die "--seed must be a non-negative integer"
[[ ${#files[@]} -gt 0 ]] || files=("${root}"/tests/test_*.sh)

for f in "${root}"/src/*.sh "${root}/tests/fixtures.sh" "${files[@]}"; do
  # shellcheck disable=SC1090 # the files are chosen at run time
  . "${f}" || die "cannot load ${f}"
done

names=()
while IFS= read -r name; do
  names+=("${name}")
done < <(compgen -A function | grep '^test_' | LC_ALL=C sort)
if [[ -n "${only}" ]]; then
  if [[ "${only}" != test_* ]] || ! declare -F "${only}" >/dev/null; then
    die "no test named ${only}"
  fi
  names=("${only}")
fi
[[ ${#names[@]} -gt 0 ]] || die "no tests found"
if [[ -n "${seed}" ]]; then
  shuffled=()
  while IFS= read -r name; do
    shuffled+=("${name}")
  done < <(printf '%s\n' "${names[@]}" | awk -v seed="${seed}" 'BEGIN { srand(seed) } { print rand() "\t" $0 }' | sort -n | cut -f2-)
  names=("${shuffled[@]}")
fi

failed=0
for name in "${names[@]}"; do
  FAILED=""
  "${name}"
  rc=$?
  if [[ -n "${FAILED}" ]]; then
    echo "FAIL: ${name}"
    failed=$((failed + 1))
  elif [[ "${rc}" -ne 0 ]]; then
    echo "ERROR: ${name} (status ${rc})"
    failed=$((failed + 1))
  fi
done
echo "Ran ${#names[@]} tests, ${failed} failed"
[[ "${failed}" -eq 0 ]]
