#!/usr/bin/env bash
# A fake herdr for the oe board tests, so no test depends on a real Herdr server.
#
# - Every call is logged to FAKE_HERDR_DIR/calls, one line per call with its arguments joined by spaces.
# - Errors go to stderr as JSON with exit 1 and leave stdout empty, as the real herdr's do.
#
# | File in FAKE_HERDR_DIR | Meaning |
# |---|---|
# | split-pane | The pane ID the next split returns; w1:p9 when missing |
# | split-fails | The split fails with the error code this file holds |
# | process-<pane>.json | What process-info prints for the pane, with : in the ID written as _; without it the pane does not exist |
# | board.json | When present, a run in a pane makes process-info print this file for that pane, as when the board starts |
set -uo pipefail

d="${FAKE_HERDR_DIR}"
printf '%s\n' "$*" >>"${d}/calls"

error() {
  printf '{"error":{"code":"%s","message":"%s"}}\n' "$1" "$1" >&2
  exit 1
}

pane_file() {
  printf '%s/process-%s.json' "${d}" "${1//:/_}"
}

case "${1:-} ${2:-}" in
"pane split")
  [[ ! -e "${d}/split-fails" ]] || error "$(cat "${d}/split-fails")"
  pane="$(cat "${d}/split-pane" 2>/dev/null || echo w1:p9)"
  # A new pane starts at its shell's prompt.
  printf '{"result":{"process_info":{"foreground_process_group_id":100,"foreground_processes":[{"argv":["-zsh"],"pid":100}],"pane_id":"%s","shell_pid":100},"type":"pane_process_info"}}\n' \
    "${pane}" >"$(pane_file "${pane}")"
  printf '{"result":{"pane":{"pane_id":"%s"},"type":"pane_info"}}\n' "${pane}"
  ;;
"pane process-info")
  [[ "${3:-}" == --pane ]] || error invalid_arguments
  [[ -e "$(pane_file "$4")" ]] || error pane_not_found
  cat "$(pane_file "$4")"
  ;;
"pane run")
  [[ -e "$(pane_file "$3")" ]] || error pane_not_found
  [[ ! -e "${d}/board.json" ]] || cp "${d}/board.json" "$(pane_file "$3")"
  printf '{"result":{"type":"ok"}}\n'
  ;;
"pane rename")
  [[ -e "$(pane_file "$3")" ]] || error pane_not_found
  printf '{"result":{"type":"ok"}}\n'
  ;;
*) error unknown_command ;;
esac
