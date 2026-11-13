# shellcheck shell=bash
# The Bot identity the agents act as, when a clone opts in with git config skills.bot.
#
# | Function | Does |
# |---|---|
# | bot_login | Prints the opt-in login of this clone, without the [bot] suffix, or nothing |
# | bot_identity_login | Prints the Bot login this worktree carries, or nothing |
# | bot_identity_apply <worktree> | Applies the identity to one fresh worktree, or does nothing when the clone does not opt in |
# | bot_env <owner/repo> | Puts a fresh Bot token in GH_TOKEN when this worktree carries the identity |
# | bot_require_ready <owner/repo> | Refuses with a reason when the clone opts in but a start could not act as the Bot |
#
# The helper command is read from the global git config skills.bot.helper only, never from a
# clone's own config, so a repository cannot name the command that mints its credentials.
# A person's own checkout carries no identity and keeps acting as the person; every agent
# worktree is created with the identity, and a start refuses when it could not be.

# Prints the opt-in login of this clone, without the [bot] suffix REST adds.
bot_login() {
  local login
  login="$(git config --get skills.bot 2>/dev/null)" || login=""
  printf '%s\n' "${login%\[bot\]}"
}

# Prints the Bot login this worktree carries, or nothing outside a Bot worktree.
bot_identity_login() {
  git config --get skills.bot.identity 2>/dev/null || true
}

# Prints the helper command. Only the global config names it.
bot_helper() {
  local helper
  helper="$(git config --global --get skills.bot.helper 2>/dev/null)" || return 1
  [[ -n "${helper}" ]] || return 1
  printf '%s\n' "${helper}"
}

# Prints one token for repository $1, or fails with the helper's own first line of error.
bot_token() {
  local repo="$1" helper err out
  local -a bot_cmd
  helper="$(bot_helper)" || {
    echo "git config --global skills.bot.helper is unset, so no Bot token can be minted" >&2
    return 1
  }
  read -r -a bot_cmd <<<"${helper}"
  err="$(mktemp)" || {
    echo "mktemp failed" >&2
    return 1
  }
  if ! out="$("${bot_cmd[@]}" token "${repo}" 2>"${err}")"; then
    echo "the Bot helper could not print a token for ${repo}: $(head -n1 "${err}")" >&2
    rm -f "${err}"
    return 1
  fi
  rm -f "${err}"
  if [[ -z "${out}" ]]; then
    echo "the Bot helper printed no token for ${repo}" >&2
    return 1
  fi
  printf '%s\n' "${out}"
}

# Puts a fresh token in GH_TOKEN when this worktree carries the identity, and does nothing otherwise.
bot_env() {
  local token
  [[ -n "$(bot_identity_login)" ]] || return 0
  token="$(bot_token "$1")" || return 1
  export GH_TOKEN="${token}"
}

# Refuses with a reason unless a start from this clone can act as the Bot: the helper can mint a
# token, the Bot's commit address is set, and the remote is one the Bot helper answers for.
# It runs before any step, so a refused start spends no attempt and creates no branch.
bot_require_ready() {
  local login email origin
  login="$(bot_login)"
  [[ -n "${login}" ]] || return 0
  bot_token "$1" >/dev/null || return 1
  email="$(git config --get skills.bot.email 2>/dev/null)" || email=""
  if [[ -z "${email}" ]]; then
    echo "git config skills.bot.email is unset, so a commit could not carry the Bot" >&2
    return 1
  fi
  origin="$(git config --get remote.origin.url 2>/dev/null)" || origin=""
  if [[ "${origin}" != https://github.com/* ]]; then
    echo "remote.origin.url is not an HTTPS GitHub URL, so a push would not answer with the Bot helper" >&2
    return 1
  fi
}

# Applies the Bot identity to worktree $1, or does nothing when the clone does not opt in.
# The address is a setting rather than a GitHub read, so applying it needs no network.
bot_identity_apply() {
  local wt="$1" login helper email origin
  login="$(bot_login)"
  [[ -n "${login}" ]] || return 0
  helper="$(bot_helper)" || {
    echo "git config --global skills.bot.helper is unset, so ${wt} cannot act as the Bot" >&2
    return 1
  }
  email="$(git config --get skills.bot.email 2>/dev/null)" || email=""
  if [[ -z "${email}" ]]; then
    echo "git config skills.bot.email is unset, so ${wt} has no Bot address to commit with" >&2
    return 1
  fi
  origin="$(git -C "${wt}" config --get remote.origin.url 2>/dev/null)" || origin=""
  if [[ "${origin}" != https://github.com/* ]]; then
    echo "remote.origin.url is not an HTTPS GitHub URL, so ${wt} cannot act as the Bot" >&2
    return 1
  fi
  git -C "${wt}" config extensions.worktreeConfig true || return 1
  git -C "${wt}" config --worktree user.name "${login}[bot]" || return 1
  git -C "${wt}" config --worktree user.email "${email}" || return 1
  # The empty value clears the helpers the person's config registers for github.com, so this
  # worktree asks the Bot helper only and never answers from the person's own login.
  git -C "${wt}" config --worktree credential.https://github.com.helper "" || return 1
  git -C "${wt}" config --worktree --add credential.https://github.com.helper "!${helper}" || return 1
  git -C "${wt}" config --worktree credential.https://github.com.useHttpPath true || return 1
  git -C "${wt}" config --worktree skills.bot.identity "${login}" || return 1
}
