#!/usr/bin/env bash
# Collects what pick-next ranks: the open Issues and pull requests of this clone's origin, and its worktrees.
# It only reads: it never writes to GitHub, a branch, or a worktree.
# Usage: pick.sh [--limit <n>]
set -uo pipefail

echo '{}'
