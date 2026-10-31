#!/usr/bin/env bats
# Tests for review-range.sh, using stub difit and npx launchers on PATH.
# shellcheck disable=SC2292 # bats fails a test on a mid-test `[[ ]]` only under bash 4.1+; `[ ]` works on every bash.

setup() {
  target="${BATS_TEST_DIRNAME}/review-range.sh"
  work="${BATS_TEST_TMPDIR}"
  args_file="${work}/args"
  reached_file="${work}/npx-reached"
  store="${work}/comment-store"
  started='echo "🚀 difit server started on http://localhost:4966"'
  closed='echo "Client disconnected, shutting down server..."'
}

# Runs review-range.sh with a stub `difit` whose body is $1 and a stub `npx` whose body is $2.
# `-` for $1 leaves difit off PATH. The npx stub always exists, so a real npx can never launch a viewer.
# The npx body runs after the leading `difit` argument is dropped.
run_stub() {
  local bin
  bin="$(mktemp -d "${work}/bin.XXXXXX")"
  if [ "$1" != "-" ]; then
    printf '#!/bin/sh\n%s\n' "$1" >"${bin}/difit"
    chmod +x "${bin}/difit"
  fi
  printf '#!/bin/sh\nshift\n%s\n' "$2" >"${bin}/npx"
  chmod +x "${bin}/npx"
  run env TMPDIR="${work}" PATH="${bin}:/usr/bin:/bin" ARGS_FILE="${args_file}" REACHED_FILE="${reached_file}" \
    STORE="${store}" "${BASH}" "${target}" HEAD base
}

# Succeeds when the last output line is a DIFIT_RESULT line that starts with the fields in $1.
expect_result() {
  local last="${lines[${#lines[@]} - 1]}"
  case "${last}" in
  "DIFIT_RESULT $1"*) ;;
  *)
    printf 'last line: %s\n' "${last}"
    return 1
    ;;
  esac
}

# Succeeds when the output has a line exactly equal to $1.
has_line() {
  printf '%s\n' "${lines[@]}" | grep -qxF -- "$1"
}

@test "launcher and fallback both failing exits 1 and reports the range as not opened" {
  run_stub 'echo "difit: shim is broken" >&2; exit 127' 'echo "npm error network" >&2; exit 1'
  [ "${status}" -eq 1 ]
  expect_result "status=not-opened comments=n/a"
}

@test "failing launchers show why they failed" {
  run_stub 'echo "difit: shim is broken" >&2; exit 127' 'echo "npm error network" >&2; exit 1'
  has_line "difit: shim is broken"
  has_line "npm error network"
}

@test "launcher absent and fallback failing exits 1" {
  run_stub - 'exit 127'
  [ "${status}" -eq 1 ]
  expect_result "status=not-opened"
}

@test "launcher that exits 0 without starting a server is not an opened viewer" {
  run_stub 'exit 0' 'exit 0'
  [ "${status}" -eq 1 ]
  expect_result "status=not-opened"
}

@test "closing message without a server start is not an opened viewer" {
  run_stub "${closed}" "${closed}"
  [ "${status}" -eq 1 ]
  expect_result "status=not-opened"
}

@test "broken launcher and opening fallback approves after the fallback window closes" {
  run_stub 'echo "difit: shim is broken" >&2; exit 127' "${started}; ${closed}"
  [ "${status}" -eq 0 ]
  expect_result "status=closed comments=none launcher=npx"
}

@test "absent launcher and opening fallback approves after the fallback window closes" {
  run_stub - "${started}; ${closed}"
  [ "${status}" -eq 0 ]
  expect_result "status=closed comments=none launcher=npx"
}

@test "launcher that closes without comments exits 0 and names itself" {
  run_stub "${started}; ${closed}" 'exit 1'
  [ "${status}" -eq 0 ]
  expect_result "status=closed comments=none launcher=difit"
}

@test "launcher that opened is not followed by the fallback" {
  # shellcheck disable=SC2016 # expanded by the stub, not here
  run_stub "${started}; exit 1" 'touch "${REACHED_FILE}"; exit 0'
  [ "${status}" -eq 3 ]
  [ ! -e "${reached_file}" ]
}

@test "comments left in this run exit 10 and are printed before the result" {
  run_stub "${started}; ${closed}; echo 'src/a.sh:L3 rename this'" 'exit 1'
  [ "${status}" -eq 10 ]
  has_line "src/a.sh:L3 rename this"
  expect_result "status=closed comments=present launcher=difit"
}

@test "comments stored by an earlier run are not this run's result" {
  echo "src/a.sh:L1 stale comment from an earlier run" >"${store}"
  # Mirrors difit, which keeps stored comments unless it starts with --clean.
  run_stub "clean=no; for a in \"\$@\"; do [ \"\$a\" = --clean ] && clean=yes; done
${started}; ${closed}; [ \"\$clean\" = yes ] || cat \"\${STORE}\"" 'exit 1'
  [ "${status}" -eq 0 ]
  expect_result "status=closed comments=none launcher=difit"
}

@test "server killed before the window closed exits 3 and is not approval" {
  run_stub "${started}; kill -9 \$\$" 'exit 1'
  [ "${status}" -eq 3 ]
  expect_result "status=interrupted comments=n/a launcher=difit"
}

@test "server that shuts down without a window closing exits 3" {
  run_stub "${started}; echo 'Shutting down difit server...'; exit 0" 'exit 1'
  [ "${status}" -eq 3 ]
  expect_result "status=interrupted"
}

@test "closing message followed by a failing exit is not approval" {
  run_stub "${started}; ${closed}; exit 1" 'exit 1'
  [ "${status}" -eq 3 ]
  expect_result "status=interrupted"
}

@test "script terminated while the window is open exits 3 and still reports the result" {
  local bin pid rc=0
  bin="$(mktemp -d "${work}/bin.XXXXXX")"
  printf '#!/bin/sh\n%s\nexec sleep 30\n' "${started}" >"${bin}/difit"
  printf '#!/bin/sh\nexit 1\n' >"${bin}/npx"
  chmod +x "${bin}/difit" "${bin}/npx"
  env TMPDIR="${work}" PATH="${bin}:/usr/bin:/bin" "${BASH}" "${target}" HEAD base >"${work}/result" 2>&1 &
  pid=$!
  for _ in $(seq 1 100); do
    grep -qs "server started" "${work}"/review-range.* && break
    sleep 0.1
  done
  kill -TERM "${pid}"
  wait "${pid}" || rc=$?
  [ "${rc}" -eq 3 ]
  grep -q "^DIFIT_RESULT status=interrupted comments=n/a launcher=difit" "${work}/result"
}

@test "launcher gets the range and --clean" {
  run_stub "printf '%s\\n' \"\$@\" >\"\${ARGS_FILE}\"; ${started}; ${closed}" 'exit 1'
  [ "${status}" -eq 0 ]
  grep -qxF -- "HEAD" "${args_file}"
  grep -qxF -- "base" "${args_file}"
  grep -qxF -- "--clean" "${args_file}"
}

@test "missing range argument exits 2" {
  run env PATH="/usr/bin:/bin" "${BASH}" "${target}" HEAD
  [ "${status}" -eq 2 ]
}
