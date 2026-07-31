#!/usr/bin/env bash
# Test suite for scan.sh.
#
# Every assertion requires scan.sh to exit 0 and to emit parseable JSON, and
# every negative assertion requires non-empty output, so a scanner that
# crashes or does nothing fails instead of passing vacuously.
#
# Scope note: the scanner is a candidate finder. It does not judge whether a
# parenthesis is a first-use definition, nor whether a line is Japanese prose
# or English prose quoting Japanese. Those are the agent's calls under
# rubric.md, so there are no tests for them here.
#
# Test list:
#   read-only contract
#     1. The scanner never modifies a file, with or without --fix.
#     2. --fix is accepted, warns on stderr, and still exits 0.
#     3. An unwritable file and an unwritable directory are scanned normally.
#     4. An unreadable file is skipped without discarding other findings.
#     5. An empty file list exits non-zero rather than faking a clean run.
#   output integrity
#     6. Output is valid JSON for a line containing a TAB.
#     7. Output is valid JSON when the file path contains a TAB.
#     8. applied_fixes is always 0.
#   brackets
#     9. A full-width parenthetical supplement is high severity.
#    10. A half-width parenthetical supplement is high severity.
#    11. Repeated supplements in one paragraph are reported once for the paragraph.
#   line joins
#    12. A 26-character Japanese line is not a mechanical-wrap candidate.
#    13. An 80-character Japanese line is a mechanical-wrap candidate.
#    14. mechanical-wrap is auto_fixable; line-break is not.
#    15. Reported line numbers address the file as it is on disk.
#   unchanged rules still fire
#    16. A vague term is reported.
#    17. Assignment notation is high severity.

# Fixtures quote Markdown backticks literally, so single quotes are deliberate.
# shellcheck disable=SC2016

set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
scan="${script_dir}/scan.sh"

pass=0
fail=0

work="$(mktemp -d)"
trap 'chmod -R u+rwx "${work}" 2>/dev/null; rm -rf "${work}"' EXIT

triples() {
  sed -n 's/.*"rule":"\([^"]*\)","severity":"\([^"]*\)","path":"[^"]*","line":\([0-9]*\).*/\1:\2:\3/p'
}

run_scan() {
  SCAN_JSON="$(bash "${scan}" "$@" 2>/dev/null)"
  SCAN_RC=$?
  SCAN_OUT="$(printf '%s\n' "${SCAN_JSON}" | triples)"
}

report() {
  local ok=$1 name=$2 detail=${3-}
  if [[ "${ok}" == "1" ]]; then
    pass=$((pass + 1))
    printf 'ok   %s\n' "${name}"
  else
    fail=$((fail + 1))
    printf 'FAIL %s\n' "${name}"
    [[ -n "${detail}" ]] && printf '     %s\n' "${detail}"
  fi
}

scan_ok() {
  local name=$1
  if [[ "${SCAN_RC}" != "0" ]]; then
    report 0 "${name}" "scan.sh exited ${SCAN_RC}"
    return 1
  fi
  if ! printf '%s' "${SCAN_JSON}" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
    report 0 "${name}" "output is not valid JSON"
    return 1
  fi
  return 0
}

assert_has() {
  local name=$1 want=$2
  scan_ok "${name}" || return
  if grep -qx "${want}" <<<"${SCAN_OUT}"; then
    report 1 "${name}"
  else
    report 0 "${name}" "expected ${want}; got: $(tr '\n' ' ' <<<"${SCAN_OUT}")"
  fi
}

assert_lacks() {
  local name=$1 unwanted=$2
  scan_ok "${name}" || return
  if [[ -z "${SCAN_OUT}" ]]; then
    report 0 "${name}" "no findings at all — cannot distinguish exemption from a dead scanner"
  elif grep -q "${unwanted}" <<<"${SCAN_OUT}"; then
    report 0 "${name}" "did not expect ${unwanted}; got: $(tr '\n' ' ' <<<"${SCAN_OUT}")"
  else
    report 1 "${name}"
  fi
}

assert_eq() {
  local name=$1 want=$2 got=$3
  if [[ "${want}" == "${got}" ]]; then
    report 1 "${name}"
  else
    report 0 "${name}" "expected ${want}, got ${got}"
  fi
}

fixture() {
  local name=$1 body=$2
  local path="${work}/${name}"
  printf '%s' "${body}" >"${path}"
  chmod 644 "${path}"
  printf '%s' "${path}"
}

long_ja="$(python3 -c "print('あ'*80, end='')")"
short_ja="$(python3 -c "print('あ'*26, end='')")"

# --------------------------------------------------- read-only contract

f="$(fixture ro1.md "${long_ja}
次の行です。
注文を確定します（自動処理）。
")"
before="$(cat "${f}")"
run_scan "${f}"
run_scan --fix "${f}"
scan_ok "1. the scanner never modifies a file" &&
  assert_eq "1. the scanner never modifies a file" "${before}" "$(cat "${f}")"

bash "${scan}" --fix "${f}" >/dev/null 2>"${work}/err.txt"
rc=$?
if [[ "${rc}" == "0" ]] && grep -q "read-only" "${work}/err.txt"; then
  report 1 "2. --fix is accepted and warns"
else
  report 0 "2. --fix is accepted and warns" "rc=${rc}, stderr=$(cat "${work}/err.txt")"
fi

mkdir -p "${work}/rodir"
printf '注文を確定します（自動処理）。\n' >"${work}/rodir/a.md"
chmod 444 "${work}/rodir/a.md"
chmod 555 "${work}/rodir"
run_scan --fix "${work}/rodir/a.md"
assert_has "3. unwritable file and directory still scan" "brackets:high:1"
chmod 755 "${work}/rodir"
assert_eq "3b. no temp file left beside the target" "0" \
  "$(find "${work}/rodir" -name 'a.md.*' | wc -l | tr -d ' ')"

ok="$(fixture rd_ok.md '注文を確定します（自動処理）。
')"
bad="$(fixture rd_bad.md '在庫を引き当てます（自動処理）。
')"
chmod 000 "${bad}"
run_scan "${ok}" "${bad}"
scan_ok "4. an unreadable file is skipped, others still reported" &&
  assert_has "4. an unreadable file is skipped, others still reported" "brackets:high:1"
chmod 644 "${bad}"

# With nothing to scan, the output must say so rather than look like a clean
# document: valid JSON carrying an empty files array.
mkdir -p "${work}/empty"
SCAN_JSON="$(cd "${work}/empty" && bash "${scan}" 2>/dev/null)"
SCAN_RC=$?
scan_ok "5a. an empty file list still emits valid JSON" &&
  assert_eq "5a. an empty file list still emits valid JSON" "yes" \
    "$(python3 -c 'import json,sys; d=json.load(sys.stdin); print("yes" if d["files"]==[] and d["issues"]==[] else "no")' <<<"${SCAN_JSON}")"

# The EXIT trap must not overwrite a failing status with the trap body's own.
# Without `exit "${rc}"` in the trap, an abort reports success and the agent
# reads an empty scan as a clean document.
sed 's|^all_issues=.*|&\nexit 7|' "${scan}" >"${work}/exitcode.sh"
bash "${work}/exitcode.sh" >/dev/null 2>&1
assert_eq "5b. the EXIT trap preserves a failing status" "7" "$?"

# ------------------------------------------------------ output integrity

run_scan "$(fixture tabs.md '本文に	タブを含む（補足）。
')"
assert_has "6. a TAB in the line keeps the JSON valid" "brackets:high:1"

mkdir -p "${work}/tab dir"
tabbed="${work}/tab dir/$(printf 'a\tb').md"
printf '注文を確定します（自動処理）。\n' >"${tabbed}"
run_scan "${tabbed}"
assert_has "7. a TAB in the path keeps the JSON valid" "brackets:high:1"

run_scan "$(fixture af.md "${long_ja}
次の行です。
")"
scan_ok "8. applied_fixes is always 0" &&
  assert_eq "8. applied_fixes is always 0" "0" \
    "$(sed -n 's/.*"applied_fixes": \([0-9]*\).*/\1/p' <<<"${SCAN_JSON}")"

# ------------------------------------------------------------- brackets

run_scan "$(fixture b9.md '注文を確定します（自動処理）。
')"
assert_has "9. full-width supplement is high" "brackets:high:1"

run_scan "$(fixture b10.md '注文を確定します(自動処理)。
')"
assert_has "10. half-width supplement is high" "brackets:high:1"

run_scan "$(fixture b11.md '注文を確定します（自動処理）。在庫を引き当てます（非同期）。
')"
assert_has "11. repeated supplements are reported for the paragraph" "brackets:high:1"

# ------------------------------------------------------------ line joins

run_scan "$(fixture w12.md "${short_ja}
次の行です。
")"
assert_lacks "12. 26-char line is not a mechanical-wrap candidate" "mechanical-wrap"

run_scan "$(fixture w13.md "${long_ja}
次の行です。
")"
assert_has "13. 80-char line is a mechanical-wrap candidate" "mechanical-wrap:low:1"

# The two join rules carry different auto_fixable values, and the docs say so.
run_scan "$(fixture w14.md "${long_ja}
次の行です。
")"
scan_ok "14a. mechanical-wrap is auto_fixable" &&
  assert_eq "14a. mechanical-wrap is auto_fixable" "1" \
    "$(grep -c '"rule":"mechanical-wrap","severity":"low","path":"[^"]*","line":1,"quote":"[^"]*","reason":"[^"]*","suggestion":"[^"]*","auto_fixable":true' <<<"${SCAN_JSON}")"

run_scan "$(fixture w14b.md 'これは途中で切れた文で
続きます。
')"
scan_ok "14b. line-break is not auto_fixable" &&
  assert_eq "14b. line-break is not auto_fixable" "1" \
    "$(grep -c '"rule":"line-break".*"auto_fixable":false' <<<"${SCAN_JSON}")"

f="$(fixture w15.md "${long_ja}
続きの文です。

注文を確定します（自動処理）。
")"
run_scan "${f}"
if scan_ok "15. line numbers address the file on disk"; then
  actual_line="$(grep -n '（自動処理）' "${f}" | cut -d: -f1)"
  reported_line="$(grep '^brackets:' <<<"${SCAN_OUT}" | head -1 | cut -d: -f3)"
  if [[ -z "${actual_line}" || -z "${reported_line}" ]]; then
    report 0 "15. line numbers address the file on disk" \
      "missing data: file '${actual_line}', reported '${reported_line}'"
  else
    assert_eq "15. line numbers address the file on disk" "${actual_line}" "${reported_line}"
  fi
fi

# --------------------------------------------- unchanged rules still fire

run_scan "$(fixture r16.md '必要に応じて適切にリトライします。
')"
assert_has "16. a vague term is reported" "vague-claim:medium:1"

run_scan "$(fixture r17.md 'isPaid = true のとき、order_status を active に設定します。
')"
assert_has "17. assignment notation is high" "assignment-notation:high:1"

printf '\n%d passed, %d failed\n' "${pass}" "${fail}"
[[ ${fail} -eq 0 ]]
