#!/usr/bin/env bats
# Tests for the Bot identity the agents act as, in oe-bot.sh and the oe start guard.
#
# - The identity lives in one worktree: the clone opts in with git config skills.bot, and
#   bot_identity_apply writes the Bot's user, credential helper, and marker into that worktree only.
# - Fake gh answers the Bot user lookup; a fake helper prints tokens and records each call; a bare
#   origin and a clone keep the worktrees real.
# shellcheck disable=SC2292 # bats fails a test on a mid-test `[[ ]]` only under bash 4.1+; `[ ]` works on every bash.

setup() {
  bats_require_minimum_version 1.5.0
  script="${BATS_TEST_DIRNAME}/oe-bot.sh"
  start="${BATS_TEST_DIRNAME}/oe-start.sh"
  tmp="$(cd "${BATS_TEST_TMPDIR}" && pwd -P)"
  export GIT_CONFIG_GLOBAL="${tmp}/gitconfig"
  export GIT_CONFIG_NOSYSTEM=1
  git config --global user.name owner
  git config --global user.email owner@example.com
  git config --global init.defaultBranch main
  git config --global credential.https://github.com.helper '!owner-helper'
  unset OE_WORKTREE_ROOT

  mkdir -p "${tmp}/bin"
  cat >"${tmp}/bin/gh" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = api ] && [ "\${2:-}" = "/users/maronium%5Bbot%5D" ]; then
  printf '%s\n' "\${GH_BOT_ID:-123}"
  exit 0
fi
echo "unexpected gh: \$*" >&2
exit 1
EOF
  cat >"${tmp}/bin/bot-helper" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"${tmp}/helper-calls"
if [ "\${1:-}" = get ]; then
  cat >/dev/null
  printf 'username=x-access-token\npassword=ghs_test_token\n'
  exit 0
fi
if [ "\${1:-}" = token ]; then
  printf 'ghs_test_token\n'
  exit 0
fi
exit 1
EOF
  cat >"${tmp}/bin/owner-helper" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"${tmp}/owner-calls"
cat >/dev/null
printf 'username=owner\npassword=ghs_owner\n'
EOF
  chmod +x "${tmp}/bin/gh" "${tmp}/bin/bot-helper" "${tmp}/bin/owner-helper"
  export PATH="${tmp}/bin:${PATH}"

  git init -q --bare "${tmp}/origin.git"
  git clone -q "${tmp}/origin.git" "${tmp}/seed"
  git -C "${tmp}/seed" commit -q --allow-empty -m base
  git -C "${tmp}/seed" push -q origin main
  git clone -q "${tmp}/origin.git" "${tmp}/clone"
  cd "${tmp}/clone" || return 1
  # A real opt-in clone reaches GitHub over HTTPS; the bare origin above is only for the trees.
  git remote set-url origin "https://github.com/maro/x.git"
  git worktree add -q "${tmp}/wt" -b feat/issue-5
  wt="${tmp}/wt"
  clone="${tmp}/clone"
}

opt_in() {
  git config skills.bot 'maronium[bot]'
}

bot_login_in() {
  (cd "${1}" && source "${script}" && bot_login)
}

apply_in() {
  (cd "${1}" && source "${script}" && bot_identity_apply "${2}")
}

bot_env_in() {
  (cd "${1}" && source "${script}" && bot_env "${2}" && printf '%s\n' "${GH_TOKEN-}")
}

bot_token_in() {
  (cd "${1}" && source "${script}" && bot_token "${2}")
}

require_in() {
  (cd "${1}" && source "${script}" && bot_require_ready "${2}")
}

@test "bot_login prints the opt-in login without the suffix it carries in REST" {
  opt_in
  run bot_login_in "${clone}"
  [ "${status}" -eq 0 ]
  [ "${output}" = "maronium" ]

  git config --unset skills.bot
  run bot_login_in "${clone}"
  [ "${status}" -eq 0 ]
  [ "${output}" = "" ]
}

@test "bot_identity_apply writes the Bot identity into the worktree only" {
  opt_in
  git config --global skills.bot.helper bot-helper

  run apply_in "${clone}" "${wt}"
  [ "${status}" -eq 0 ]
  [ "$(git -C "${wt}" config user.name)" = "maronium[bot]" ]
  [ "$(git -C "${wt}" config user.email)" = "123+maronium[bot]@users.noreply.github.com" ]
  [ "$(git -C "${wt}" config --get skills.bot.identity)" = "maronium" ]
  [ "$(git -C "${wt}" config --get credential.https://github.com.useHttpPath)" = "true" ]
  [ "$(git -C "${wt}" config --get-all credential.https://github.com.helper | tail -n2 | tr '\n' ' ')" = " !bot-helper " ]
  [ "$(git config user.name)" = "owner" ]
}

@test "the worktree answers git's credential request with the Bot, not the owner" {
  opt_in
  git config --global skills.bot.helper bot-helper
  run apply_in "${clone}" "${wt}"
  [ "${status}" -eq 0 ]

  printf 'protocol=https\nhost=github.com\npath=maro/x.git\n\n' >"${tmp}/request"
  run bash -c 'git -C "$1" credential fill <"$2"' _ "${wt}" "${tmp}/request"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"password=ghs_test_token"* ]]
  run cat "${tmp}/helper-calls"
  [[ "${output}" == *"get"* ]]
  [ ! -e "${tmp}/owner-calls" ]
}

@test "bot_identity_apply changes nothing when the clone does not opt in" {
  git config --global skills.bot.helper bot-helper
  run apply_in "${clone}" "${wt}"
  [ "${status}" -eq 0 ]
  [ "$(git -C "${wt}" config --get user.name)" = "owner" ]
  [ -z "$(git -C "${wt}" config --get skills.bot.identity)" ]
}

@test "bot_identity_apply refuses when the clone opts in but the helper is unset" {
  opt_in
  git config --global --unset skills.bot.helper || true
  run apply_in "${clone}" "${wt}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"skills.bot.helper"* ]]
}

@test "bot_env puts a fresh token in GH_TOKEN only where the identity is carried" {
  opt_in
  git config --global skills.bot.helper bot-helper
  run apply_in "${clone}" "${wt}"
  [ "${status}" -eq 0 ]

  run bot_env_in "${wt}" maro/x
  [ "${status}" -eq 0 ]
  [ "${output}" = "ghs_test_token" ]
  grep -q -- "token maro/x" "${tmp}/helper-calls"

  run bot_env_in "${clone}" maro/x
  [ "${status}" -eq 0 ]
  [ "${output}" = "" ]
}

@test "bot_env refuses with a reason when the helper is unset" {
  opt_in
  git config --global skills.bot.helper bot-helper
  run apply_in "${clone}" "${wt}"
  [ "${status}" -eq 0 ]
  git config --global --unset skills.bot.helper || true

  run bot_env_in "${wt}" maro/x
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"skills.bot.helper"* ]]
}

@test "bot_require_ready passes without opt-in, mints when the helper works, and refuses when it fails" {
  run require_in "${clone}" maro/x
  [ "${status}" -eq 0 ]

  opt_in
  git config --global skills.bot.helper bot-helper
  run require_in "${clone}" maro/x
  [ "${status}" -eq 0 ]
  grep -q -- "token maro/x" "${tmp}/helper-calls"

  cat >"${tmp}/bin/failing-helper" <<'EOF'
#!/usr/bin/env bash
echo "1Password is locked" >&2
exit 1
EOF
  chmod +x "${tmp}/bin/failing-helper"
  git config --global skills.bot.helper failing-helper
  run require_in "${clone}" maro/x
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"1Password is locked"* ]]
}

@test "a commit in the worktree is authored by the Bot" {
  opt_in
  git config --global skills.bot.helper bot-helper
  run apply_in "${clone}" "${wt}"
  [ "${status}" -eq 0 ]

  (cd "${wt}" && echo content >file && git add file && git commit -q -m change)
  [ "$(git -C "${wt}" log -1 --format='%an <%ae>')" = "maronium[bot] <123+maronium[bot]@users.noreply.github.com>" ]
}

@test "apply refuses an SSH remote instead of pushing with the person's key" {
  opt_in
  git config --global skills.bot.helper bot-helper
  git remote set-url origin "ssh://git@github.com:443/maro/x.git"

  run apply_in "${clone}" "${wt}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"not an HTTPS GitHub URL"* ]]
  [ -z "$(git -C "${wt}" config --get skills.bot.identity)" ]
}

@test "apply clears the identity when the clone opts out, so a reused worktree keeps nothing" {
  opt_in
  git config --global skills.bot.helper bot-helper
  run apply_in "${clone}" "${wt}"
  [ "${status}" -eq 0 ]

  git config --unset skills.bot
  run apply_in "${clone}" "${wt}"
  [ "${status}" -eq 0 ]
  [ "$(git -C "${wt}" config user.name)" = "owner" ]
  [ -z "$(git -C "${wt}" config --get skills.bot.identity)" ]
  [ "$(git -C "${wt}" config --get credential.https://github.com.helper)" = "!owner-helper" ]
}

@test "apply refuses a clone with submodules, whose own settings would keep the person's credentials" {
  opt_in
  git config --global skills.bot.helper bot-helper
  : >"${clone}/.gitmodules"

  run apply_in "${clone}" "${wt}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"submodules"* ]]
}

@test "a helper named by the clone's own config is ignored" {
  opt_in
  git config skills.bot.helper "sh -c 'echo leaked >${tmp}/leaked'"
  git config --global --unset skills.bot.helper || true

  run bot_token_in "${clone}" maro/x
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"skills.bot.helper"* ]]
  [ ! -e "${tmp}/leaked" ]
}

@test "oe start reads the Bot id before any step and starts nothing when it fails" {
  opt_in
  git config --global skills.bot.helper bot-helper

  GH_BOT_ID=nope run bash "${start}" owner maro/x 5
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"GitHub user id"* ]]
  [ "$(git worktree list --porcelain | grep -c '^worktree ')" -eq 2 ]
}

@test "oe start refuses to start an agent when the clone opts in but the helper is unset" {
  opt_in
  git config --global --unset skills.bot.helper || true

  run bash "${start}" owner maro/x 5
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"skills.bot.helper"* ]]
  [ "$(git worktree list --porcelain | grep -c '^worktree ')" -eq 2 ]
}
