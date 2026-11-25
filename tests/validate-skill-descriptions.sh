#!/usr/bin/env bash
# Fails when the description of a model-invocable skill exceeds 400 bytes.
# Usage: tests/validate-skill-descriptions.sh [skills-dir], by default the skills/ of this repository.
#
# Every session and every subagent starts with the description of each skill the model can load on its own,
# so the cap keeps that fixed cost small. A skill with `disable-model-invocation: true` is never injected and is skipped.
# The size is the byte count of the description value: a folded or literal block joins its lines with one space,
# and the quotes around a single-line value are not counted.
set -euo pipefail

limit=400
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
skills_dir="${1:-${script_dir}/../skills}"

# frontmatter_field <file>: prints "invocable" or "manual", then the description value on the next line.
# Prints nothing for a missing description.
describe() {
  awk '
    NR == 1 { if ($0 ~ /^---[[:space:]]*$/) infront = 1; next }
    !infront { next }
    /^---[[:space:]]*$/ { exit }
    /^description:/ {
      indesc = 1
      v = $0
      sub(/^description:[[:space:]]*/, "", v)
      if (v ~ /^[>|][+-]?[0-9]*[[:space:]]*$/) { v = "" } else { single = 1 }
      value = v
      next
    }
    indesc && /^[[:space:]]/ {
      line = $0
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
      if (line == "") next
      value = (value == "" ? line : value " " line)
      next
    }
    { indesc = 0 }
    /^disable-model-invocation:[[:space:]]*true[[:space:]]*$/ { manual = 1 }
    END {
      gsub(/[[:space:]]+$/, "", value)
      if (single && value ~ /^".*"$/) value = substr(value, 2, length(value) - 2)
      else if (single && value ~ /^'\''.*'\''$/) value = substr(value, 2, length(value) - 2)
      if (value == "") exit
      print (manual ? "manual" : "invocable")
      print value
    }
  ' "$1"
}

status=0
count=0
for skill_path in "${skills_dir}"/*/SKILL.md; do
  [[ -f "${skill_path}" ]] || continue
  skill="$(basename "$(dirname "${skill_path}")")"
  parsed="$(describe "${skill_path}")"
  if [[ -z "${parsed}" ]]; then
    printf 'skills/%s: no description in the frontmatter\n' "${skill}" >&2
    status=1
    continue
  fi
  [[ "${parsed%%$'\n'*}" == "invocable" ]] || continue
  count=$((count + 1))
  size="$(printf '%s' "${parsed#*$'\n'}" | LC_ALL=C wc -c | tr -d '[:space:]')"
  if ((size > limit)); then
    printf 'skills/%s: description is %s bytes, over the %s-byte limit\n' "${skill}" "${size}" "${limit}" >&2
    status=1
  fi
done

if [[ "${status}" -ne 0 ]]; then
  printf '%s\n' 'shorten the description: it is injected into every session, so keep the purpose and the phrasings users say, and move the rest into the body' >&2
  exit 1
fi

printf 'skill descriptions OK (%s model-invocable skill(s), each at most %s bytes)\n' "${count}" "${limit}"
