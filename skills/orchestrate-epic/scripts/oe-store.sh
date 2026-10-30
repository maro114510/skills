# shellcheck shell=bash
# The host-local state of orchestrate-epic: where it lives on this host, and how a repository names its part.
# Each subcommand that touches the state sources this file, so none restates the layout.
#
# | Path under the state directory | Holds | Written by |
# |---|---|---|
# | locks.git | One ref per Epic that a session holds | oe lock |
#
# - The state directory is OE_STATE_DIR when set, and orchestrate-epic under XDG_STATE_HOME or ~/.local/state otherwise.
#   Either default lies outside every checkout, so no agent's worktree ever holds the state.

# Prints the state directory.
state_dir() {
  printf '%s' "${OE_STATE_DIR:-${XDG_STATE_HOME:-${HOME}/.local/state}/orchestrate-epic}"
}

# Prints the key of repository $1 in the state.
# A path or ref component cannot hold every repository name, such as one ending in .lock, so the lowercased name is hashed.
repo_key() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | git hash-object --stdin
}
