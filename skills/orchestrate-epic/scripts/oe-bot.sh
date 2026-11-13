# shellcheck shell=bash
# The Bot identity the agents act as, when a clone opts in with git config skills.bot.
#
# | Function | Does |
# |---|---|
# | bot_login | Prints the opt-in login of this clone, without the [bot] suffix, or nothing |
# | bot_identity_login | Prints the Bot login this worktree carries, or nothing |
# | bot_identity_apply <worktree> | Applies the identity to one fresh worktree, or does nothing when the clone does not opt in |
# | bot_env <owner/repo> | Puts a fresh Bot token in GH_TOKEN when this worktree carries the identity |
# | bot_require_ready <owner/repo> | Refuses with a reason when the clone opts in but the Bot helper is unusable |
#
# The helper command is read from the global git config skills.bot.helper only, never from a
# clone's own config, so a repository cannot name the command that mints its credentials.

bot_login() {
  return 1
}

bot_identity_login() {
  return 1
}

bot_identity_apply() {
  return 1
}

bot_env() {
  return 1
}

bot_require_ready() {
  return 1
}
