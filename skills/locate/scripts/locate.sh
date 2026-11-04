#!/usr/bin/env bash
# Resolves a GitHub pull request or Issue URL to its local worktrees, branches, and current state.
# Usage: locate.sh <https://github.com/<owner>/<repo>/(pull|issues)/<n>>
set -uo pipefail

printf '{}\n'
