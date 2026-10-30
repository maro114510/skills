#!/usr/bin/env bash
# Builds one create-pr evaluation sandbox from scratch, without network access or a GitHub token.
# Usage: setup.sh <A|B|C> <dir> [<skill-dir>]
# <skill-dir> holds the SKILL.md the executor follows; the default is the create-pr directory containing this script.
# <dir> must be missing, empty, or an earlier sandbox, which is replaced; anything else is refused.
# Output in <dir>: origin.git (bare origin, so the real gh resolves no GitHub host), repo (the user's clone),
# bin/gh (gh-stub.sh), state (the stub's data and records), prompt.md (the executor prompt for this scenario).
# Dates, identities, and git config are fixed, so every build of a scenario has the same commits.
# Exit: 0 ok, 1 git or a file operation failed, 2 bad usage or a refused <dir>.
set -euo pipefail

eval_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
marker=".create-pr-eval"

usage() {
  sed -n '3p' "$0" | sed 's/^# //' >&2
  exit 2
}

[[ $# -ge 2 && $# -le 3 ]] || usage
scenario="$1"
[[ "${scenario}" =~ ^[ABC]$ ]] || usage
skill_dir="${3:-$(dirname "${eval_dir}")}"
if [[ ! -f "${skill_dir}/SKILL.md" ]]; then
  echo "No SKILL.md in ${skill_dir}" >&2
  exit 2
fi
skill_dir="$(cd "${skill_dir}" && pwd)"

mkdir -p "$2"
dir="$(cd "$2" && pwd)"
if [[ -n "$(ls -A "${dir}")" && ! -f "${dir}/${marker}" ]]; then
  echo "Refusing ${dir}: not empty and not an earlier sandbox" >&2
  exit 2
fi
find "${dir}" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
touch "${dir}/${marker}"
mkdir -p "${dir}/bin" "${dir}/state"

# Neither the user's git config nor git's environment config may change what gets built.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset GIT_CONFIG GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS GIT_DIR GIT_WORK_TREE
export GIT_AUTHOR_NAME=dev GIT_AUTHOR_EMAIL=dev@example.invalid GIT_COMMITTER_NAME=dev GIT_COMMITTER_EMAIL=dev@example.invalid
tick=1767225600

g() { git -C "${dir}/repo" "$@"; }

# commit <file> <content> <message> writes the file and commits it one minute after the previous commit.
commit() {
  mkdir -p "$(dirname "${dir}/repo/$1")"
  printf '%s\n' "$2" >"${dir}/repo/$1"
  tick=$((tick + 60))
  g add -- "$1"
  GIT_AUTHOR_DATE="${tick} +0000" GIT_COMMITTER_DATE="${tick} +0000" g commit -q -m "$3"
}

git init -q --bare -b main "${dir}/origin.git"
git init -q -b main "${dir}/repo"
g remote add origin "${dir}/origin.git"

commit src/auth/session.ts $'export function refresh(token: string) {\n  return fetch("/refresh", { headers: { Authorization: token } });\n}' "feat(auth): add session refresh"
commit README.md "# demo service" "docs: add readme"

# Many plausible labels, so choosing at most two that clearly match is a real choice.
labels='[{"name":"bug","description":"Something isn'"'"'t working"},{"name":"enhancement","description":"New feature or request"},{"name":"documentation","description":"Improvements or additions to documentation"},{"name":"auth","description":"Authentication and sessions"},{"name":"wip","description":"Work in progress"},{"name":"dependencies","description":"Dependency updates"}]'
for i in $(seq 1 40); do
  labels="${labels%]},{\"name\":\"area/module-${i}\",\"description\":\"Legacy area label ${i} kept for historical triage dashboards\"}]"
done
printf '%s\n' "${labels}" >"${dir}/state/labels.json"

case "${scenario}" in
A)
  # Median: a Japanese template, a branch never pushed, one Closes footer. skills.lang is pinned in the clone so a
  # user's global value cannot change the language.
  g config skills.lang ja
  commit .github/PULL_REQUEST_TEMPLATE.md $'## 概要\n\n<!-- 何をなぜ変えたか -->\n\n## 変更点\n\n- \n\n## 動作確認\n\n- [ ] ユニットテスト\n- [ ] 手動確認\n\n## 関連 Issue\n\n<!-- Closes #xxx -->' "chore: add PR template"
  g push -q -u origin main
  g checkout -q -b fix/expired-jwt-refresh
  commit src/auth/session.ts $'export async function refresh(token: string) {\n  const res = await fetch("/refresh", { headers: { Authorization: token } });\n  if (res.status === 401) {\n    throw new SessionExpiredError();\n  }\n  return res;\n}\n\nexport class SessionExpiredError extends Error {}' $'fix(auth): surface expired JWT on refresh as SessionExpiredError\n\nThe refresh call returned the raw 401 response, so callers retried forever\nwith a dead token. Throw a typed error so the UI can send the user to login.\n\nCloses #12'
  commit src/auth/session.test.ts $'import { refresh, SessionExpiredError } from "./session";\ntest("401 throws", async () => {\n  global.fetch = async () => ({ status: 401 }) as Response;\n  await expect(refresh("t")).rejects.toBeInstanceOf(SessionExpiredError);\n});' $'test(auth): cover expired refresh\n\nCloses #12'
  echo "12:Refresh loops forever on an expired JWT:0" >"${dir}/state/issues"
  ;;
B)
  # A branch cut from origin/main while local main is stale, whose upstream is behind HEAD; origin/main carries an
  # unrelated Closes #99.
  g push -q -u origin main
  g checkout -q -b tmp-advance
  commit src/billing/invoice.ts 'export const TAX = 0.1;' $'feat(billing): add tax constant\n\nCloses #99'
  g push -q origin tmp-advance:main
  g checkout -q main
  g branch -q -D tmp-advance
  g fetch -q origin
  g checkout -q -b feat/rate-limit origin/main
  commit src/auth/rate-limit.ts $'export function allow(count: number) {\n  return count < 10;\n}' $'feat(auth): add a login rate limit\n\nRelated #40'
  g push -q -u origin feat/rate-limit
  commit src/auth/rate-limit.ts $'const LIMIT = 10;\nexport function allow(count: number) {\n  return count < LIMIT;\n}' $'refactor(auth): name the rate limit constant\n\nThe limit itself is final; staging QA by the support team happens after merge.\n\nCloses #40'
  printf '%s\n' "40:Rate-limit login attempts:0" "99:Billing tax constant:0" >"${dir}/state/issues"
  ;;
C)
  # A stacked branch whose gh-merge-base is its parent feature branch, and no template.
  g push -q -u origin main
  g checkout -q -b feat/export-api
  commit src/export/api.ts 'export function exportCsv() { return ""; }' $'feat(export): add the export API skeleton\n\nCloses #7'
  g push -q -u origin feat/export-api
  g checkout -q -b feat/export-csv-quoting
  g config branch.feat/export-csv-quoting.gh-merge-base feat/export-api
  commit src/export/api.ts $'export function exportCsv(rows: string[][]) {\n  return rows.map((r) => r.map((c) => `"${c.replaceAll("\\"", "\\"\\"")}"`).join(",")).join("\\n");\n}' $'feat(export): quote CSV cells\n\nCloses #8'
  printf '%s\n' "7:Export API skeleton:0" "8:Quote CSV cells:0" >"${dir}/state/issues"
  ;;
esac

cp "${eval_dir}/gh-stub.sh" "${dir}/bin/gh"
chmod +x "${dir}/bin/gh"

# Bash 5.2 would otherwise expand & in a replacement to the matched text.
shopt -u patsub_replacement 2>/dev/null || true
prompt="$(cat "${eval_dir}/prompt.md")"
prompt="${prompt//\{\{SCENARIO\}\}/$(cat "${eval_dir}/scenarios/${scenario}.md")}"
prompt="${prompt//\{\{SKILL_DIR\}\}/${skill_dir}}"
prompt="${prompt//\{\{SANDBOX\}\}/${dir}}"
prompt="${prompt//\{\{REPO\}\}/${dir}/repo}"
prompt="${prompt//\{\{BIN\}\}/${dir}/bin}"
printf '%s\n' "${prompt}" >"${dir}/prompt.md"

echo "ready: ${dir}"
