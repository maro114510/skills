#!/usr/bin/env bash
# Prints Closes or Related per issue from the newest commit footer since <base>.
# Usage: issue-refs.sh <base>
# Exit: 0 ok, 2 bad usage, 3 an older Closes would still close an issue the newest commit marks Related.
set -uo pipefail

base="${1:-}"
if [[ -z "${base}" ]] || ! git rev-parse --verify -q "${base}^{commit}" >/dev/null; then
  echo "Usage: issue-refs.sh <base>" >&2
  exit 2
fi

git log --reverse --format=%B "${base}..HEAD" | awk '
  { l = tolower($0) }
  l ~ /^[[:space:]]*(close[sd]?|fix(e[sd])?|resolve[sd]?|related):?[[:space:]]+#[0-9]+[[:space:]]*$/ {
    n = l; sub(/^[^#]*#/, "", n); n += 0
    last[n] = (l ~ /^[[:space:]]*related/) ? "Related" : "Closes"
    if (last[n] == "Closes") closed[n] = 1
  }
  END {
    rc = 0
    for (n in last) {
      if (last[n] == "Related" && closed[n]) { print "CONFLICT #" n; rc = 3 } else print last[n] " #" n
    }
    exit rc
  }' | sort -t '#' -k 2 -n
