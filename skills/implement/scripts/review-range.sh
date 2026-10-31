#!/usr/bin/env bash
# Opens difit on a commit range, waits for the window to close, and reports whether a review really happened.
# Usage: review-range.sh <target> <compare-with>   (run from inside the worktree)
# The last output line is always one `DIFIT_RESULT status=<s> comments=<c> launcher=<l> run=<id>` line.
# A run that prints no such line, as when the harness killed it, is not approval either.
# Exit:
#   0   status=closed, comments=none: a difit window opened in this run and was closed without comments. The only approval.
#   10  status=closed, comments=present: the comments of this run are printed above the result line.
#   1   status=not-opened: no launcher started a server, so nothing was reviewed.
#   3   status=interrupted: a server started but did not end in a closed window (killed, Ctrl+C, nonzero exit).
#   2   usage error.
# `difit` is tried first, then `npx difit`. A launcher counts as opened only when its output says the
# server started, because a broken shim can exit 0 having done nothing. Once one has opened, the other
# is never tried, so a second window cannot appear. `--clean` drops comments stored by an earlier run,
# and only this run's captured output is read, so nothing earlier can pass for the result.
set -uo pipefail

target="${1:-}"
compare_with="${2:-}"
if [[ -z "${target}" || -z "${compare_with}" ]]; then
  echo "Usage: review-range.sh <target> <compare-with>" >&2
  exit 2
fi

started_marker='difit server started on '
closed_marker='Client disconnected, shutting down server...'

out="$(mktemp "${TMPDIR:-/tmp}/review-range.XXXXXX")"
log="${out}.log"
rest="${out}.rest"
run_id="${out##*.}"
trap 'rm -f "${out}" "${log}" "${rest}"' EXIT

child=""
stopped=no
# Stopping this script signals the launcher it started, which ends the run as interrupted. For `npx` that is
# the wrapper, and whether it forwards the signal to the server is up to npx.
trap 'stopped=yes; [[ -z "${child}" ]] || kill "${child}" 2>/dev/null' INT TERM HUP

diagnostics=""
opened_by=""
rc=0

# Runs launcher $1 (a label) with command $2.. on the range. Returns 0 when its server started.
try_launcher() {
  local label="$1"
  shift
  : >"${out}"
  : >"${log}"
  "$@" "${target}" "${compare_with}" --clean >"${out}" 2>"${log}" </dev/null &
  child=$!
  wait "${child}"
  rc=$?
  # A trapped signal ends the first wait early; the child is reaped once it is gone.
  while kill -0 "${child}" 2>/dev/null; do
    wait "${child}"
    rc=$?
  done
  child=""
  if grep -qF -- "${started_marker}" "${out}"; then
    opened_by="${label}"
    return 0
  fi
  diagnostics+="${label} did not start a server (exit ${rc}):"$'\n'
  diagnostics+="$(tail -n 5 "${log}" "${out}" 2>/dev/null)"$'\n'
  return 1
}

if command -v difit >/dev/null 2>&1; then
  try_launcher difit difit
else
  diagnostics+="difit is not on PATH"$'\n'
fi
if [[ -z "${opened_by}" && "${stopped}" == no ]]; then
  if command -v npx >/dev/null 2>&1; then
    try_launcher npx npx difit
  else
    diagnostics+="npx is not on PATH"$'\n'
  fi
fi

if [[ -z "${opened_by}" ]]; then
  printf '%s' "${diagnostics}"
  echo "DIFIT_RESULT status=not-opened comments=n/a launcher=none run=${run_id}"
  exit 1
fi

cat "${out}"
if [[ "${rc}" -ne 0 ]] || ! grep -qxF -- "${closed_marker}" "${out}"; then
  echo "DIFIT_RESULT status=interrupted comments=n/a launcher=${opened_by} run=${run_id}"
  exit 3
fi
# Whatever difit prints after the closing message is the comments of this run.
# It goes to a file first: `grep -q` at the end of a pipe stops early, and the SIGPIPE it causes
# fails the pipeline under pipefail, which would report comments as none.
if ! sed -n "/^${closed_marker//./\\.}\$/,\$p" "${out}" | tail -n +2 >"${rest}"; then
  # Comments cannot be ruled out, so this is not approval.
  echo "DIFIT_RESULT status=interrupted comments=n/a launcher=${opened_by} run=${run_id}"
  exit 3
fi
if grep -q '[^[:space:]]' "${rest}"; then
  echo "DIFIT_RESULT status=closed comments=present launcher=${opened_by} run=${run_id}"
  exit 10
fi
echo "DIFIT_RESULT status=closed comments=none launcher=${opened_by} run=${run_id}"
exit 0
