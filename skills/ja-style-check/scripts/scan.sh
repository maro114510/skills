#!/usr/bin/env bash
# Deterministic scanner for ja-style-check.
# Uses only shell, awk, git, mktemp, and mv. Semantic style issues are emitted
# as candidates for agent judgment; only safe line joining can be applied.

set -euo pipefail

fix=0
files=()

while [[ $# -gt 0 ]]; do
  case "$1" in
  --fix)
    fix=1
    shift
    ;;
  -h | --help)
    cat <<'USAGE'
Usage: scan.sh [--fix] [file...]

Emits JSON with deterministic Japanese style candidates.
--fix applies only safe line-join fixes.
USAGE
    exit 0
    ;;
  *)
    files+=("$1")
    shift
    ;;
  esac
done

if [[ ${#files[@]} -eq 0 ]]; then
  while IFS= read -r line; do
    status="${line:0:2}"
    path="${line:3}"
    if [[ "${path}" == *" -> "* ]]; then
      path="${path##* -> }"
    fi
    [[ "${status}" == *D* ]] && continue
    [[ -n "${path}" ]] && files+=("${path}")
  done < <(git status --short -- '*.md' 2>/dev/null || true)
fi

json_escape() {
  local s=${1-}
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\t'/\\t}
  s=${s//$'\r'/\\r}
  s=${s//$'\n'/\\n}
  printf '%s' "${s}"
}

print_issue_json() {
  local issue=$1
  local rule severity path line quote reason suggestion auto
  IFS=$'\t' read -r rule severity path line quote reason suggestion auto <<<"${issue}"
  printf '{'
  printf '"rule":"%s",' "$(json_escape "${rule}")"
  printf '"severity":"%s",' "$(json_escape "${severity}")"
  printf '"path":"%s",' "$(json_escape "${path}")"
  printf '"line":%s,' "${line}"
  printf '"quote":"%s",' "$(json_escape "${quote}")"
  printf '"reason":"%s",' "$(json_escape "${reason}")"
  printf '"suggestion":"%s",' "$(json_escape "${suggestion}")"
  printf '"auto_fixable":%s' "${auto}"
  printf '}'
}

scan_file() {
  local file=$1
  local issues_file=$2
  local applied_file=$3
  local fixed_file
  fixed_file="$(mktemp)"

  awk -v path="${file}" -v do_fix="${fix}" -v issues="${issues_file}" -v fixed="${fixed_file}" -v applied_out="${applied_file}" '
    function has_japanese(s) {
      return s ~ /[ぁ-んァ-ヶ一-龠]/
    }
    function trim(s) {
      sub(/^[[:space:]]+/, "", s)
      sub(/[[:space:]]+$/, "", s)
      return s
    }
    function is_structural(s, in_code, stripped) {
      stripped = trim(s)
      if (in_code || stripped == "") return 1
      if (stripped ~ /^```/) return 1
      if (stripped ~ /^(#|\||- |\* |> )/) return 1
      if (stripped ~ /^[0-9]+\.[[:space:]]/) return 1
      if (stripped ~ /https?:\/\//) return 1
      return 0
    }
    function ends_sentence(s) {
      return s ~ /[。！？!?」』）)\]`.;；:]$/
    }
    function emit(rule, severity, line, quote, reason, suggestion, auto) {
      printf "%s\t%s\t%s\t%d\t%s\t%s\t%s\t%s\n", rule, severity, path, line, quote, reason, suggestion, auto >> issues
    }
    function sep(left, right) {
      return ""
    }
    function weak_term(s) {
      return s ~ /(適切に|適切な|必要に応じて|十分に|基本的に|可能なら|考慮する|担保する|いい感じに|ある程度|なるべく)/
    }
    function meta_phrase(s) {
      return s ~ /(まず|以下に|本節では|このドキュメントでは|説明します|示します|述べます|以上を踏まえると|これをまとめると|つまり|前述した通り|後述するように)/
    }
    function passive_phrase(s) {
      return s ~ /(される|されます|られる|行われる|行われます|求められます|必要です|判断される)/
    }
    function implementation_term(s) {
      return s ~ /(処理|実行|取得|更新|削除|登録|設定|呼び出|返す|戻り値|引数|変数|関数|配列|ループ|分岐|条件|判定|例外|エラー|フラグ|ステータス|true|false|null|nil|undefined|if|else|for|while|switch|case|かつ)/
    }
    function identifier(s) {
      return s ~ /`[^`]+`|[A-Za-z_][A-Za-z0-9_]*\.[A-Za-z_][A-Za-z0-9_]*|[a-z]+[A-Z][A-Za-z0-9]*|[a-z]+_[a-z0-9_]+|[A-Z]{1,4}-[0-9]+|§[[:space:]]*[0-9]+(\.[0-9]+)*/
    }
    function assignment_notation(s) {
      if (s ~ /[A-Za-z_][A-Za-z0-9_]* *= *[A-Za-z][A-Za-z0-9_]*/) return 1
      if (s ~ /`[^`]+`[[:space:]]*(が|を|は|に)[[:space:]]*(true|false|active|inactive|enabled|disabled|null|nil)/) return 1
      return 0
    }
    function notation_issue(s) {
      return s ~ /(——|──|―|—|・|非常に|極めて|不可欠|核心的|多角的|包括的|深掘り|掘り下げ|正面から)/
    }
    {
      line[NR] = $0
    }
    END {
      frontmatter_end = 0
      if (NR >= 1 && trim(line[1]) == "---") {
        for (i = 2; i <= NR; i++) {
          if (trim(line[i]) == "---") {
            frontmatter_end = i
            break
          }
        }
      }

      in_code = 0
      for (i = 1; i < NR; i++) {
        if (i <= frontmatter_end || i + 1 <= frontmatter_end) continue
        current = trim(line[i])
        next_line = trim(line[i + 1])
        if (current ~ /^```/) {
          in_code = !in_code
          continue
        }
        if (is_structural(line[i], in_code) || is_structural(line[i + 1], in_code)) continue
        if (!has_japanese(current next_line)) continue
        combined_len = length(current) + length(next_line)
        mechanical = (length(current) >= 78 && length(current) <= 82 && !ends_sentence(current))
        mid_sentence = !ends_sentence(current)
        if ((mechanical || mid_sentence) && combined_len <= 200) {
          rule = mechanical ? "mechanical-wrap" : "line-break"
          auto = mechanical ? "true" : "false"
          emit(rule, "low", i, current, "Sentence appears to continue across a line break.", "Join this line with the following line.", auto)
          if (mechanical) {
            fix_line[i] = 1
          }
        }
      }

      applied = 0
      if (do_fix) {
        for (i = 1; i <= NR; i++) {
          if (fix_line[i] && i < NR) {
            left = trim(line[i])
            right = line[i + 1]
            sub(/^[[:space:]]+/, "", right)
            print left sep(left, right) right >> fixed
            i++
            applied++
          } else {
            print line[i] >> fixed
          }
        }
      }

      in_code = 0
      paragraph_parens = 0
      paragraph_start = 1
      for (i = 1; i <= NR; i++) {
        if (i <= frontmatter_end) continue
        current = trim(line[i])
        if (current ~ /^```/) {
          in_code = !in_code
          continue
        }
        if (is_structural(line[i], in_code)) {
          if (paragraph_parens >= 2) {
            emit("brackets", "medium", paragraph_start, "paragraph", "Parenthetical supplements appear repeatedly in one paragraph.", "Move supplements into direct prose or remove them.", "false")
          }
          paragraph_parens = 0
          paragraph_start = i + 1
          continue
        }
        if (!has_japanese(current)) continue

        paren_source = current
        parens = gsub(/（|\(/, "", paren_source)
        paragraph_parens += parens
        if (parens >= 2 || current ~ /[）)]$/) {
          emit("brackets", "medium", i, trim(line[i]), "Parenthetical supplements interrupt the sentence rhythm.", "Keep only first-use definitions; rewrite other supplements as prose.", "false")
        }
        if (weak_term(current)) {
          emit("vague-claim", "medium", i, trim(line[i]), "A vague term lacks a concrete condition or threshold.", "State the condition, scope, threshold, or effect.", "false")
        }
        if (meta_phrase(current)) {
          emit("meta-prose", "low", i, trim(line[i]), "Meta prose may announce the text instead of adding content.", "Delete it if the next sentence already carries the content.", "false")
        }
        if (passive_phrase(current)) {
          emit("reader-facing-japanese", "medium", i, trim(line[i]), "The sentence may hide the actor.", "Name who acts, decides, or requires the action.", "false")
        }
        if (assignment_notation(current)) {
          emit("assignment-notation", "high", i, trim(line[i]), "Implementation identifier appears as a prose actor, condition, or value assignment.", "Rewrite as reader-visible behavior without code identifiers.", "false")
        } else if (identifier(current)) {
          emit("reader-facing-japanese", "medium", i, trim(line[i]), "Code identifiers or internal references appear in prose.", "Explain reader-facing behavior and move raw references to evidence when needed.", "false")
        }
        if (implementation_term(current)) {
          emit("implementation-transcription", "medium", i, trim(line[i]), "The sentence may describe implementation mechanics.", "Rewrite as user-visible behavior without control-flow terms.", "false")
        }
        if (notation_issue(current)) {
          emit("notation-emphasis", "low", i, trim(line[i]), "Decorative notation or empty emphasis may be carrying the prose.", "Use sentence order, concrete wording, or plain punctuation instead.", "false")
        }
      }
      print applied > applied_out
    }
  ' "${file}"

  if [[ ${fix} -eq 1 ]]; then
    mv "${fixed_file}" "${file}"
  else
    rm -f "${fixed_file}"
  fi
}

all_issues="$(mktemp)"
applied_total=0

for file in "${files[@]}"; do
  [[ -f "${file}" ]] || continue
  applied_file="$(mktemp)"
  scan_file "${file}" "${all_issues}" "${applied_file}"
  applied="$(cat "${applied_file}")"
  rm -f "${applied_file}"
  applied_total=$((applied_total + applied))
done

issue_count=0
auto_count=0
manual_count=0
while IFS=$'\t' read -r _rule _severity _path _line _quote _reason _suggestion auto; do
  [[ -z "${_rule:-}" ]] && continue
  issue_count=$((issue_count + 1))
  if [[ "${auto}" == "true" ]]; then
    auto_count=$((auto_count + 1))
  else
    manual_count=$((manual_count + 1))
  fi
done <"${all_issues}"

printf '{\n'
printf '  "mode": "%s",\n' "$([[ ${fix} -eq 1 ]] && printf 'fix' || printf 'report')"
printf '  "files": ['
printed=0
for file in "${files[@]}"; do
  [[ -f "${file}" ]] || continue
  if [[ ${printed} -gt 0 ]]; then printf ', '; fi
  printf '"%s"' "$(json_escape "${file}")"
  printed=$((printed + 1))
done
printf '],\n'
printf '  "applied_fixes": %d,\n' "${applied_total}"
printf '  "issues": [\n'
printed=0
while IFS= read -r issue; do
  [[ -z "${issue}" ]] && continue
  if [[ ${printed} -gt 0 ]]; then printf ',\n'; fi
  printf '    '
  print_issue_json "${issue}"
  printed=$((printed + 1))
done <"${all_issues}"
printf '\n  ],\n'
printf '  "summary": {\n'
printf '    "issue_count": %d,\n' "${issue_count}"
printf '    "auto_fixable_count": %d,\n' "${auto_count}"
printf '    "manual_count": %d\n' "${manual_count}"
printf '  }\n'
printf '}\n'

rm -f "${all_issues}"
