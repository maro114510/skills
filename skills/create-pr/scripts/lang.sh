#!/usr/bin/env bash
# Resolves the language a skill writes in. The only place that decides it; skills call this instead of restating the rules.
# Usage: lang.sh [<value>]
# Source: the argument when one is given, even an empty one; else git config skills.lang; else ja.
# Output on exit 0: "<lang> (<source>)", where <source> is argument, git config, or default.
# Exit: 0 ok, 1 git config could not be read, 2 an invalid value or bad usage, reported on stderr.
set -uo pipefail

if [[ $# -gt 1 ]]; then
  echo "Usage: lang.sh [<value>]" >&2
  exit 2
fi

if [[ $# -eq 1 ]]; then
  # An explicit argument never reads git config, so a broken config cannot block it.
  value="$1" source="argument" origin="argument lang"
else
  value="$(git config --get skills.lang)"
  case $? in
  0) source="git config" origin="git config skills.lang" ;;
  # 1 means unset; any other code is a config git could not read, which must not pass for the default.
  1) value="ja" source="default" origin="default" ;;
  *) exit 1 ;;
  esac
fi

if [[ "${value}" != ja && "${value}" != en ]]; then
  echo "Invalid language \"${value}\" from ${origin}; use ja or en." >&2
  exit 2
fi
echo "${value} (${source})"
