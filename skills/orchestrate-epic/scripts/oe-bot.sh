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
# A person's own worktree of the same clone carries no identity and keeps acting as the person.

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

# Prints the numeric id GitHub assigns the Bot, which its noreply address needs.
bot_user_id() {
  local login="$1" id
  id="$(gh api "/users/${login}%5Bbot%5D" --jq .id 2>/dev/null)" || id=""
  if [[ ! "${id}" =~ ^[0-9]+$ ]]; then
    echo "cannot read the GitHub user id of ${login}[bot]" >&2
    return 1
  fi
  printf '%s\n' "${id}"
}

# Puts a fresh token in GH_TOKEN when this worktree carries the identity, and does nothing otherwise.
# A worktree with no marker keeps acting as the person: the person's own checkouts must stay theirs,
# and every agent worktree is created with the marker, so no agent starts without it.
bot_env() {
  local token
  [[ -n "$(bot_identity_login)" ]] || return 0
  token="$(bot_token "$1")" || return 1
  export GH_TOKEN="${token}"
}

# Refuses with a reason when the clone opts in but the start cannot act as the Bot.
# It runs before any step, so a failed check consumes no attempt and creates no branch.
# The id it reads is exported, because the worktree step runs in a child process.
bot_require_ready() {
  local login id
  login="$(bot_login)"
  [[ -n "${login}" ]] || return 0
  bot_token "$1" >/dev/null || return 1
  id="$(bot_user_id "${login}")" || return 1
  export OE_BOT_ID="${id}"
}

# Applies the Bot identity to worktree $1, or does nothing when the clone does not opt in.
# The Bot user's numeric id makes its noreply address; GitHub assigns it, so it is read once.
bot_identity_apply() {
  local wt="$1" login helper id
  login="$(bot_login)"
  [[ -n "${login}" ]] || return 0
  helper="$(bot_helper)" || {
    echo "git config --global skills.bot.helper is unset, so ${wt} cannot act as the Bot" >&2
    return 1
  }
  id="${OE_BOT_ID:-}"
  [[ -n "${id}" ]] || id="$(bot_user_id "${login}")" || return 1
  git -C "${wt}" config extensions.worktreeConfig true || return 1
  # Every SSH spelling GitHub documents becomes HTTPS, where the Bot helper answers. An SSH remote
  # would authenticate with the person's key and bypass what the Bot may do.
  git -C "${wt}" config --worktree --add url.https://github.com/.insteadOf "git@github.com:" || return 1
  git -C "${wt}" config --worktree --add url.https://github.com/.insteadOf "ssh://git@github.com/" || return 1
  git -C "${wt}" config --worktree --add url.https://github.com/.insteadOf "ssh://git@github.com:22/" || return 1
  git -C "${wt}" config --worktree --add url.https://github.com/.insteadOf "ssh://git@github.com:443/" || return 1
  git -C "${wt}" config --worktree --add url.https://github.com/.insteadOf "git@ssh.github.com:" || return 1
  git -C "${wt}" config --worktree --add url.https://github.com/.insteadOf "ssh://git@ssh.github.com/" || return 1
  git -C "${wt}" config --worktree --add url.https://github.com/.insteadOf "ssh://git@ssh.github.com:443/" || return 1
  # A remote still reached another way, such as an SSH port or host not rewritten above, would
  # authenticate as the person, so refuse before writing a marker that claims otherwise.
  local push_url
  push_url="$(git -C "${wt}" remote get-url --push origin 2>/dev/null)" || push_url=""
  if [[ -n "${push_url}" && "${push_url}" != https://github.com/* ]]; then
    echo "the push URL ${push_url} would not answer with the Bot helper, so ${wt} cannot act as the Bot" >&2
    return 1
  fi
  git -C "${wt}" config --worktree user.name "${login}[bot]" || return 1
  git -C "${wt}" config --worktree user.email "${id}+${login}[bot]@users.noreply.github.com" || return 1
  # The empty value clears the helpers the person's config registers for github.com, so this
  # worktree asks the Bot helper only and never answers from the person's own login.
  git -C "${wt}" config --worktree credential.https://github.com.helper "" || return 1
  git -C "${wt}" config --worktree --add credential.https://github.com.helper "!${helper}" || return 1
  git -C "${wt}" config --worktree credential.https://github.com.useHttpPath true || return 1
  git -C "${wt}" config --worktree skills.bot.identity "${login}" || return 1
}
