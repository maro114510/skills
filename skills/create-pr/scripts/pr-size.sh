#!/usr/bin/env bash
# Checks whether the commits in <base>..HEAD form one reviewable PR, as defined in the create-pr skill.
# Usage: pr-size.sh [<base>]
# Run from inside the repository. <base> defaults to origin/HEAD; the range starts at its merge base with HEAD.
# Only commits are measured, never uncommitted changes.
#
# Each changed file takes the first category it matches. Renames are detected, so a moved file counts only its
# edited lines. Changed lines are added plus deleted lines.
#
# | Category   | Matches                                                         | Lines        |
# |------------|-----------------------------------------------------------------|--------------|
# | deleted    | The file is gone at HEAD                                        | not counted  |
# | binary     | Git reports no line counts for it                               | not counted  |
# | generated  | `linguist-generated` in .gitattributes, or `[paths] generated`  | not counted  |
# | lockfile   | A built-in lockfile name, such as package-lock.json or go.sum   | not counted  |
# | test       | `[paths] tests`                                                 | reported     |
# | design doc | `[paths] design_docs`                                           | reported as docs |
# | docs       | `linguist-documentation` in .gitattributes                      | reported as docs |
# | production | Anything else                                                   | counted      |
#
# | Check       | Fails when |
# |-------------|------------|
# | size        | Production lines exceed 400 |
# | design docs | A design doc shares the range with any file that is neither a design doc nor docs, deleted ones included |
#
# Config: the `[paths]` section of .agents/skills.toml at the repository root, read with Python 3.11+ tomllib.
# Each of `tests`, `generated`, and `design_docs` is a Git glob pathspec, as a string or an array of them.
# Without the file or the section, only the built-in exclusions apply, and the output says so.
# The config and .gitattributes are read from the working tree.
#
# | Exit | Meaning |
# |------|---------|
# | 0    | The range is one PR |
# | 1    | A check failed |
# | 2    | Usage, repository, or config error |
set -uo pipefail

die() {
  echo "pr-size: $1" >&2
  exit 2
}

[[ $# -le 1 ]] || die "Usage: pr-size.sh [<base>]"
top="$(git rev-parse --show-toplevel 2>/dev/null)" || die "Not inside a Git repository"
cd "${top}" || die "Cannot enter ${top}"
head="$(git rev-parse -q --verify 'HEAD^{commit}')" || die "HEAD has no commit"
base_ref="${1:-origin/HEAD}"
git rev-parse -q --verify "${base_ref}^{commit}" >/dev/null || die "Unknown base: ${base_ref}"
base="$(git merge-base "${base_ref}" HEAD)" || die "No merge base between ${base_ref} and HEAD"
command -v python3 >/dev/null 2>&1 || die "pr-size.sh needs python3"

work="$(mktemp -d "${TMPDIR:-/tmp}/pr-size.XXXXXX")" || die "Cannot create a temporary directory"
# shellcheck disable=SC2329 # invoked by the EXIT trap
cleanup() {
  rm -rf "${work}"
}
trap cleanup EXIT

read -r -d '' PY <<'EOF'
import os, sys

LIMIT = 400
KEYS = ("tests", "generated", "design_docs")
BUILTIN = "deleted, lockfile, linguist-generated, linguist-documentation"
# Lockfiles are written by package managers, never by hand, so a reviewer does not read them line by line.
LOCKFILES = {
    ".terraform.lock.hcl", "Cargo.lock", "Gemfile.lock", "Package.resolved", "Pipfile.lock", "Podfile.lock",
    "bun.lock", "bun.lockb", "composer.lock", "conda-lock.yml", "deno.lock", "flake.lock", "go.sum", "go.work.sum",
    "gradle.lockfile", "mix.lock", "npm-shrinkwrap.json", "package-lock.json", "packages.lock.json", "pdm.lock",
    "pnpm-lock.yaml", "poetry.lock", "pubspec.lock", "uv.lock", "yarn.lock",
}

def die(msg):
    print("pr-size: " + msg, file=sys.stderr)
    sys.exit(2)

def records(path):
    with open(path, "rb") as f:
        data = f.read().decode("utf-8", "surrogateescape")
    out = data.split("\0")
    if out and out[-1] == "":
        out.pop()
    return out

def config(path):
    # Prints the config state, then key and pathspec pairs, NUL-separated.
    if not os.path.isfile(path):
        sys.stdout.write("state\0none\0")
        return
    try:
        import tomllib
    except ImportError:
        die("reading .agents/skills.toml needs Python 3.11 or later")
    try:
        with open(path, "rb") as f:
            doc = tomllib.load(f)
    except (OSError, tomllib.TOMLDecodeError) as e:
        die(f"cannot read .agents/skills.toml: {e}")
    if "paths" not in doc:
        sys.stdout.write("state\0nosection\0")
        return
    paths = doc["paths"]
    if not isinstance(paths, dict):
        die("[paths] must be a table")
    out = ["state", "section"]
    for key in KEYS:
        v = paths.get(key)
        if v is None:
            continue
        if isinstance(v, str):
            v = [v]
        if not isinstance(v, list) or not v or not all(isinstance(p, str) and p and "\0" not in p for p in v):
            die(f"paths.{key} must be a non-empty string or an array of them")
        for p in v:
            out += [key, p]
    sys.stdout.write("".join(s + "\0" for s in out))

def report(work, rng, state, keys):
    # Name and status, with renames: status, path, and a second path for R and C.
    status = {}
    recs = records(os.path.join(work, "status"))
    i = 0
    while i < len(recs):
        code = recs[i]
        if code[:1] in ("R", "C"):
            status[recs[i + 2]] = code[0]
            i += 3
        else:
            status[recs[i + 1]] = code[0]
            i += 2
    # Numstat, with renames: "added<TAB>deleted<TAB>path", or "added<TAB>deleted<TAB>" then the two paths.
    lines = {}
    order = []
    recs = records(os.path.join(work, "numstat"))
    i = 0
    while i < len(recs):
        added, deleted, path = recs[i].split("\t", 2)
        if path == "":
            path = recs[i + 2]
            i += 3
        else:
            i += 1
        lines[path] = None if added == "-" else int(added) + int(deleted)
        order.append(path)
    member = {k: set(records(os.path.join(work, "in-" + k))) for k in KEYS}
    attrs = {}
    recs = records(os.path.join(work, "attrs"))
    for j in range(0, len(recs) - 2, 3):
        if recs[j + 2] in ("set", "true"):
            attrs.setdefault(recs[j], set()).add(recs[j + 1])

    def kind(path):
        # The category of a path, ignoring whether it was deleted, with its reason.
        if "linguist-generated" in attrs.get(path, ()):
            return "generated", "generated (linguist-generated)"
        if path in member["generated"]:
            return "generated", "generated ([paths] generated)"
        if os.path.basename(path) in LOCKFILES:
            return "lockfile", "lockfile"
        if path in member["tests"]:
            return "test", "test ([paths] tests)"
        if path in member["design_docs"]:
            return "design doc", "design doc ([paths] design_docs)"
        if "linguist-documentation" in attrs.get(path, ()):
            return "docs", "docs (linguist-documentation)"
        return "production", None

    counted, excluded = [], []
    totals = {"production": 0, "test": 0, "docs": 0}
    design, others = False, []
    for path in order:
        cat, reason = kind(path)
        if cat == "design doc":
            design = True
        elif cat != "docs":
            others.append(path)
        n = lines[path]
        if status.get(path) == "D":
            excluded.append((path, "deleted"))
        elif n is None:
            excluded.append((path, "binary"))
        elif cat == "production":
            counted.append((path, n))
            totals["production"] += n
        else:
            excluded.append((path, reason))
            if cat == "test":
                totals["test"] += n
            elif cat in ("docs", "design doc"):
                totals["docs"] += n

    print("range: " + rng)
    if state == "none":
        print(f"config: no .agents/skills.toml, so only the built-in exclusions apply: {BUILTIN}")
    elif state == "nosection":
        print(f"config: no [paths] section in .agents/skills.toml, so only the built-in exclusions apply: {BUILTIN}")
    else:
        unset = [k for k in KEYS if k not in keys]
        line = "config: [paths] " + (", ".join(k for k in KEYS if k in keys) or "with no keys")
        print(line + ("; unset: " + ", ".join(unset) if unset else ""))
    print("counted:")
    for path, n in counted:
        print(f"  {n}  {path}")
    if not counted:
        print("  none")
    print("excluded:")
    for path, reason in excluded:
        print(f"  {path}: {reason}")
    if not excluded:
        print("  none")
    print(f"production: {totals['production']} lines (limit {LIMIT})")
    print(f"tests: {totals['test']} lines, not counted")
    print(f"docs: {totals['docs']} lines, not counted")
    failed = False
    if totals["production"] > LIMIT:
        print(f"fail: {totals['production']} production lines exceed the {LIMIT}-line limit")
        failed = True
    if design and others:
        print("fail: design docs must land in their own PR, but the range also changes " + ", ".join(others))
        failed = True
    print("result: " + ("fail" if failed else "pass"))
    sys.exit(1 if failed else 0)

cmd = sys.argv[1]
if cmd == "config":
    config(sys.argv[2])
elif cmd == "report":
    report(sys.argv[2], sys.argv[3], sys.argv[4], set(sys.argv[5:]))
else:
    die("unknown helper command " + cmd)
EOF

py() {
  python3 -c "${PY}" "$@"
}

py config "${top}/.agents/skills.toml" >"${work}/config" || exit 2
state=""
tests=()
generated=()
design_docs=()
while IFS= read -r -d '' key && IFS= read -r -d '' value; do
  case "${key}" in
  state) state="${value}" ;;
  tests) tests+=(":(glob)${value}") ;;
  generated) generated+=(":(glob)${value}") ;;
  design_docs) design_docs+=(":(glob)${value}") ;;
  esac
done <"${work}/config"

diff_z() {
  git -c core.quotePath=false diff --no-ext-diff --no-color -z "$@"
}

diff_z --name-status -M "${base}" "${head}" >"${work}/status" || die "Cannot read the changes of the range"
diff_z --numstat -M "${base}" "${head}" >"${work}/numstat" || die "Cannot read the line counts of the range"
diff_z --name-only -M "${base}" "${head}" >"${work}/paths" || die "Cannot read the changed paths of the range"

# Writes the changed paths matching the pathspecs after $1 to ${work}/in-$1, with renames split so a moved file
# matches by its new path.
members() {
  local key="$1"
  shift
  : >"${work}/in-${key}"
  [[ $# -gt 0 ]] || return 0
  diff_z --name-only --no-renames "${base}" "${head}" -- "$@" >"${work}/in-${key}" ||
    die "Cannot match [paths] ${key}"
}

set_keys=()
# Bash 3.2 treats "${arr[@]}" of an empty array as unbound under set -u, so each list is expanded only when set.
if [[ ${#tests[@]} -gt 0 ]]; then
  members tests "${tests[@]}"
  set_keys+=(tests)
else
  members tests
fi
if [[ ${#generated[@]} -gt 0 ]]; then
  members generated "${generated[@]}"
  set_keys+=(generated)
else
  members generated
fi
if [[ ${#design_docs[@]} -gt 0 ]]; then
  members design_docs "${design_docs[@]}"
  set_keys+=(design_docs)
else
  members design_docs
fi

git check-attr -z --stdin linguist-generated linguist-documentation <"${work}/paths" >"${work}/attrs" ||
  die "Cannot read .gitattributes"

range="$(git rev-parse --short "${base}")..$(git rev-parse --short "${head}")"
if [[ ${#set_keys[@]} -gt 0 ]]; then
  py report "${work}" "${range}" "${state}" "${set_keys[@]}"
else
  py report "${work}" "${range}" "${state}"
fi
