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

# Checks, without a network read, that a worktree of this clone could act as the Bot: the helper
# is named globally, the remote is an HTTPS GitHub one, and no submodule keeps its own settings,
# where the person's credentials would answer instead.
# It runs before a fetch or a start, so a refused one changes nothing on GitHub.
bot_config_ready() {
  local login origin top
  login="$(bot_login)"
  [[ -n "${login}" ]] || return 0
  bot_helper >/dev/null || {
    echo "git config --global skills.bot.helper is unset, so nothing can act as the Bot" >&2
    return 1
  }
  origin="$(git config --get remote.origin.url 2>/dev/null)" || origin=""
  if [[ "${origin}" != https://github.com/* ]]; then
    echo "remote.origin.url is not an HTTPS GitHub URL, so a push would not answer with the Bot helper" >&2
    return 1
  fi
  top="$(git rev-parse --show-toplevel 2>/dev/null)" || top="."
  if [[ -e "${top}/.gitmodules" ]]; then
    echo "${top} has submodules, which keep their own credentials, so it cannot act as the Bot" >&2
    return 1
  fi
}

# Prints the numeric id GitHub assigns the Bot, which makes its noreply commit address.
# Only the worktree step that runs without the preflight's OE_BOT_ID reads it, with the caller's own
# gh auth; a start reads the id from the token itself, in bot_require_ready.
bot_user_id() {
  local login="$1" id
  id="$(gh api "/users/${login}%5Bbot%5D" --jq .id 2>/dev/null)" || id=""
  if [[ ! "${id}" =~ ^[0-9]+$ ]]; then
    echo "cannot read the GitHub user id of ${login}[bot]" >&2
    return 1
  fi
  printf '%s\n' "${id}"
}

# Refuses with a reason unless a start from this clone can act as the Bot: its settings are ready,
# and the token the helper mints for repository $1 acts as the Bot, whose id that same read then
# gives. A helper pointed at another App, or answering with a person's token, stops here instead of
# writing as somebody else, so nothing falls back to the person. The id is passed to the worktree
# step, which runs in a child process.
# It runs before any step, so a refused start spends no attempt and creates no branch.
bot_require_ready() {
  local login token who id actor
  bot_config_ready || return 1
  login="$(bot_login)"
  [[ -n "${login}" ]] || return 0
  token="$(bot_token "$1")" || return 1
  who="$(GH_TOKEN="${token}" gh api /user --jq '.id, .login' 2>/dev/null)" || who=""
  id="$(printf '%s\n' "${who}" | sed -n 1p)"
  actor="$(printf '%s\n' "${who}" | sed -n 2p)"
  if [[ "${actor}" != "${login}[bot]" ]]; then
    echo "the token the helper minted acts as ${actor:-nobody}, not ${login}[bot], so nothing would act as the Bot" >&2
    return 1
  fi
  if [[ ! "${id}" =~ ^[0-9]+$ ]]; then
    echo "cannot read the GitHub user id of ${actor}" >&2
    return 1
  fi
  export OE_BOT_ID="${id}"
}

# Gives worktree $1 the identity its clone opted into, or clears the identity a reused worktree
# may still carry when it opts out. The address is a setting, so neither needs a network read.
bot_identity_apply() {
  local wt="$1" login helper id email
  login="$(bot_login)"
  if [[ -z "${login}" ]]; then
    bot_identity_clear "${wt}"
    return 0
  fi
  bot_config_ready || return 1
  helper="$(bot_helper)"
  id="${OE_BOT_ID:-}"
  [[ -n "${id}" ]] || id="$(bot_user_id "${login}")" || return 1
  email="${id}+${login}[bot]@users.noreply.github.com"
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

# Removes the identity from a worktree its clone no longer opts in for, so nothing it kept can
# make a later run act as the Bot.
bot_identity_clear() {
  local wt="$1" key
  [[ -n "$(git -C "${wt}" config --get skills.bot.identity 2>/dev/null)" ]] || return 0
  git -C "${wt}" config extensions.worktreeConfig true || return 1
  for key in user.name user.email skills.bot.identity \
    credential.https://github.com.helper credential.https://github.com.useHttpPath; do
    git -C "${wt}" config --worktree --unset-all "${key}" >/dev/null 2>&1 || true
  done
}
