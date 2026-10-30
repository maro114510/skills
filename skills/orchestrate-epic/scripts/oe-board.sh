#!/usr/bin/env bash
# oe board
#
# Opens the Epic's board: a Herdr pane that runs oe status --watch.
#
# Usage
#
#   oe board <owner/repo> <epic-number>
set -uo pipefail

usage() {
  echo "$1" >&2
  echo "Usage: oe board <owner/repo> <epic-number>" >&2
  exit 2
}

[[ $# -eq 2 ]] || usage "Expected <owner/repo> <epic-number>"
[[ "$1" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || usage "Invalid repository: $1"
[[ "$2" =~ ^[1-9][0-9]*$ ]] || usage "Invalid Epic number: $2"
