package checks_test

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/maro114510/skills/oe/internal/checks"
	"github.com/maro114510/skills/oe/internal/exitcode"
)

const testRevision = "0123456789abcdef0123456789abcdef01234567"

// fakeGit serves workflow files from a map, so derivation never touches a real repository.
type fakeGit struct {
	ref      string
	revision string
	paths    []string
	files    map[string]string
}

func (f *fakeGit) Git(_ context.Context, args ...string) ([]byte, error) {
	switch {
	case len(args) == 3 && args[0] == "rev-parse":
		return []byte(f.revision + "\n"), nil
	case len(args) == 7 && args[0] == "ls-tree":
		return []byte(strings.Join(f.paths, "\n") + "\n"), nil
	case len(args) == 2 && args[0] == "show":
		path, ok := strings.CutPrefix(args[1], f.ref+":")
		if !ok {
			return nil, fmt.Errorf("fakeGit: show %q does not name %s", args[1], f.ref)
		}
		body, ok := f.files[path]
		if !ok {
			return nil, fmt.Errorf("fakeGit: no file %s", path)
		}
		return []byte(body), nil
	}
	return nil, fmt.Errorf("fakeGit: unexpected call %q", args)
}

func deriveFiles(t *testing.T, files map[string]string) checks.Set {
	t.Helper()
	paths := make([]string, 0, len(files))
	for path := range files {
		paths = append(paths, path)
	}
	slices.Sort(paths)
	git := &fakeGit{ref: "origin/main", revision: testRevision, paths: paths, files: files}
	set, err := checks.Derive(t.Context(), git, "main", "origin/main")
	if err != nil {
		t.Fatalf("Derive() error = %v", err)
	}
	return set
}

func repoWorkflow(t *testing.T, name string) string {
	t.Helper()
	path := filepath.Join("..", "..", "..", ".github", "workflows", name)
	data, err := os.ReadFile(path) //nolint:gosec // The path is a fixed repository fixture.
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	return string(data)
}

func singleStep(t *testing.T, step string) checks.Entry {
	t.Helper()
	body := "on: pull_request\njobs:\n  test:\n    steps:\n" + step
	set := deriveFiles(t, map[string]string{".github/workflows/test.yml": body})
	if len(set.Entries) != 1 {
		t.Fatalf("entry count = %d, want 1; entries = %+v", len(set.Entries), set.Entries)
	}
	return set.Entries[0]
}

// TestWorkedExampleClassification checks every row of commands.md §1.6's worked example against
// this repository's own workflow files, and the tag-only release workflow's exclusion.
func TestWorkedExampleClassification(t *testing.T) {
	t.Parallel()

	files := map[string]string{
		".github/workflows/lint-actions.yml":        repoWorkflow(t, "lint-actions.yml"),
		".github/workflows/lint-shell.yml":          repoWorkflow(t, "lint-shell.yml"),
		".github/workflows/release.yml":             repoWorkflow(t, "release.yml"),
		".github/workflows/test-plugin-install.yml": repoWorkflow(t, "test-plugin-install.yml"),
	}
	set := deriveFiles(t, files)

	rows := []workedRow{
		{".github/workflows/lint-actions.yml", "", false, "rhysd/actionlint@914e7df21a07ef503a81201c76d2b11c789d3fca", false, 1},
		{".github/workflows/lint-shell.yml", "", false, "ludeeus/action-shellcheck@00cae500b08a931fb5698e11e79bfbd38e612a38", false, 1},
		{".github/workflows/lint-shell.yml", "pip install semgrep", false, "", false, 1},
		{".github/workflows/lint-shell.yml", "semgrep --config p/security-audit --config p/secrets --error .", false, "", true, 1},
		{".github/workflows/test-plugin-install.yml", "npm install -g @anthropic-ai/claude-code", false, "", false, 2},
		{".github/workflows/test-plugin-install.yml", "claude plugin validate .", false, "", true, 1},
		{".github/workflows/test-plugin-install.yml", "git config --global url.", true, "", false, 1},
		{".github/workflows/test-plugin-install.yml", "claude plugin marketplace add ./", false, "", true, 1},
		{".github/workflows/test-plugin-install.yml", "claude plugin marketplace list", false, "", true, 1},
		{".github/workflows/test-plugin-install.yml", "claude plugin install skills@maro114510-agent-skills --scope user", false, "", false, 1},
		{".github/workflows/test-plugin-install.yml", "claude plugin list | grep skills", false, "", true, 1},
	}
	for _, row := range rows {
		got, foundRunnable := countRow(set, row)
		if got != row.wantOccurrences {
			t.Errorf("%s %q: %d entries, want %d", row.file, row.command+row.action, got, row.wantOccurrences)
		}
		if foundRunnable != row.runnable {
			t.Errorf("%s %q: runnable = %v, want %v", row.file, row.command+row.action, foundRunnable, row.runnable)
		}
	}
	for _, entry := range set.Entries {
		if entry.File == ".github/workflows/release.yml" {
			t.Errorf("tag-only release.yml entry survived: %+v", entry)
		}
	}
}

// workedRow is one row of the commands.md §1.6 worked example.
type workedRow struct {
	file            string
	command         string
	contains        bool
	action          string
	runnable        bool
	wantOccurrences int
}

func matchesRow(entry checks.Entry, row workedRow) bool {
	if entry.File != row.file {
		return false
	}
	if row.action != "" && entry.Action != row.action {
		return false
	}
	if row.command == "" {
		return true
	}
	if row.contains {
		return strings.Contains(entry.Command, row.command)
	}
	return entry.Command == row.command
}

func countRow(set checks.Set, row workedRow) (int, bool) {
	got := 0
	runnable := false
	for _, entry := range set.Entries {
		if !matchesRow(entry, row) {
			continue
		}
		got++
		runnable = entry.Runnable
	}
	return got, runnable
}

func TestDerivePreservesOrderDuplicatesAndContext(t *testing.T) {
	t.Parallel()

	body := `on: pull_request
jobs:
  test:
    env:
      JOB: job
    defaults:
      run:
        working-directory: from-job
        shell: sh
    steps:
      - name: first
        run: |
          echo same
        env:
          STEP: first
      - name: second
        run: |
          echo same
        shell: bash
        working-directory: from-step
        env:
          STEP: second
`
	set := deriveFiles(t, map[string]string{".github/workflows/test.yml": body})
	if len(set.Entries) != 2 {
		t.Fatalf("entry count = %d, want 2: %+v", len(set.Entries), set.Entries)
	}
	checkDuplicate(t, set.Entries[0], 0, "from-job", "sh", "first")
	checkDuplicate(t, set.Entries[1], 1, "from-step", "bash", "second")
}

func checkDuplicate(t *testing.T, entry checks.Entry, index int, workdir, shell, step string) {
	t.Helper()
	if entry.Command != "echo same\n" {
		t.Errorf("command = %q, want the multi-line block", entry.Command)
	}
	if entry.StepIndex != index {
		t.Errorf("step index = %d, want %d", entry.StepIndex, index)
	}
	if entry.WorkingDirectory != workdir {
		t.Errorf("working directory = %q, want %q", entry.WorkingDirectory, workdir)
	}
	if entry.Shell != shell {
		t.Errorf("shell = %q, want %q", entry.Shell, shell)
	}
	if entry.Env["JOB"] != "job" || entry.Env["STEP"] != step {
		t.Errorf("env = %v, want JOB=job and STEP=%s", entry.Env, step)
	}
	if !entry.Runnable {
		t.Errorf("duplicate run entry is not runnable")
	}
}

func TestDeriveWorkflowDefaultsProvideWorkingDirectoryAndShell(t *testing.T) {
	t.Parallel()

	body := `on: pull_request
defaults:
  run:
    working-directory: from-workflow
    shell: sh
jobs:
  test:
    steps:
      - run: echo workflow
      - run: echo job
        shell: bash
jobs2:
  unused: {}
`
	// jobs2 is not part of jobs and must never be traversed.
	set := deriveFiles(t, map[string]string{".github/workflows/test.yml": body})
	if len(set.Entries) != 2 {
		t.Fatalf("entry count = %d, want 2", len(set.Entries))
	}
	if set.Entries[0].WorkingDirectory != "from-workflow" || set.Entries[0].Shell != "sh" {
		t.Errorf("workflow defaults not inherited: %+v", set.Entries[0])
	}
	if set.Entries[1].WorkingDirectory != "from-workflow" || set.Entries[1].Shell != "bash" {
		t.Errorf("step override not applied: %+v", set.Entries[1])
	}
}

func TestDeriveTriggerFilters(t *testing.T) {
	t.Parallel()

	step := "\n    steps:\n      - run: echo ran\n"
	tests := []struct {
		name string
		on   string
		kept bool
		push string
	}{
		{"pull request only", "on: pull_request", true, "none"},
		{"pull request mapping", "on:\n  pull_request:\n    types: [opened]", true, "none"},
		{"push to the base branch", "on:\n  push:\n    branches: [main]", true, "runs"},
		{"push wildcard matching base", "on:\n  push:\n    branches: ['*']", true, "runs"},
		{"push ignoring another branch", "on:\n  push:\n    branches-ignore: [develop]", true, "runs"},
		{"push ignoring the base branch", "on:\n  push:\n    branches-ignore: [main]", false, "none"},
		{"unfiltered push", "on: push", true, "runs"},
		{"push with a path filter", "on:\n  push:\n    branches: [main]\n    paths: ['oe/**']", true, "path_filtered"},
		{"push with a paths-ignore filter", "on:\n  push:\n    branches: [main]\n    paths-ignore: ['docs/**']", true, "path_filtered"},
		{"tag-only push", "on:\n  push:\n    tags: ['v*']", false, "none"},
		{"schedule only", "on:\n  schedule:\n    - cron: '0 0 * * *'", false, "none"},
		{"workflow dispatch only", "on:\n  workflow_dispatch:", false, "none"},
		{"sequence with push", "on: [push, pull_request]", true, "runs"},
		{"negated base branch", "on:\n  push:\n    branches: ['*', '!main']", false, "none"},
		{"double-star glob", "on:\n  push:\n    branches: ['**']", true, "runs"},
		{"single-star within a segment", "on:\n  push:\n    branches: ['ma*']", true, "runs"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			set := deriveFiles(t, map[string]string{".github/workflows/test.yml": tc.on + "\njobs:\n  test:" + step})
			if got := len(set.Entries) == 1; got != tc.kept {
				t.Errorf("kept = %v, want %v; entries = %+v", got, tc.kept, set.Entries)
			}
			if set.DefaultBranchPush != tc.push {
				t.Errorf("default_branch_push = %q, want %q", set.DefaultBranchPush, tc.push)
			}
		})
	}
}

func TestDeriveClassifiesRequiresRunner(t *testing.T) {
	t.Parallel()

	requiresRunner := []struct {
		name string
		step string
	}{
		{"sudo", "      - run: sudo apt-get install -y bats"},
		{"global npm flag", "      - run: npm install -g @anthropic-ai/claude-code"},
		{"long global flag", "      - run: npm install --global @anthropic-ai/claude-code"},
		{"pip install", "      - run: pip install semgrep"},
		{"gh release", "      - run: gh release create v1.0.0"},
		{"git global config", "      - run: git config --global user.name x"},
		{"user scope install", "      - run: claude plugin install x --scope user"},
		{"runner temp", "      - run: echo ${RUNNER_TEMP}/artifact"},
		{"github path", "      - run: echo \"$GITHUB_PATH\""},
		{"line-continued global flag", "      - run: |\n          npm install \\\n            -g pkg\n"},
		{"brew install", "      - run: brew install jq"},
		{"absolute sudo", "      - run: /usr/bin/sudo apt-get update"},
		{"command expression", "      - run: echo ${{ github.sha }}"},
		{"runner shell", "      - run: echo hi\n        shell: pwsh"},
		{"custom bash invocation", "      - run: echo hi\n        shell: bash -e {0}"},
		{"action step", "      - uses: rhysd/actionlint@v1"},
	}
	for _, tc := range requiresRunner {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			entry := singleStep(t, tc.step)
			if entry.Runnable {
				t.Errorf("entry is runnable, want requires-runner: %+v", entry)
			}
			if entry.RequiresRunnerReason == "" {
				t.Errorf("requires-runner entry has no reason: %+v", entry)
			}
		})
	}

	runnable := []struct {
		name string
		step string
	}{
		{"plain run", "      - run: go test ./..."},
		{"bash shell", "      - run: echo hi\n        shell: bash"},
		{"sh shell", "      - run: echo hi\n        shell: sh"},
		{"multiline block", "      - run: |\n          set -eu\n          go vet ./..."},
		{"pipeline", "      - run: claude plugin list | grep skills"},
	}
	for _, tc := range runnable {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			entry := singleStep(t, tc.step)
			if !entry.Runnable {
				t.Errorf("entry is requires-runner (%q), want runnable: %+v", entry.RequiresRunnerReason, entry)
			}
		})
	}
}

func TestDeriveEnvExpressionClassifiesEveryRunInTheJob(t *testing.T) {
	t.Parallel()

	body := `on: pull_request
jobs:
  test:
    env:
      TOKEN: ${{ secrets.TOKEN }}
    steps:
      - run: echo safe-looking
`
	set := deriveFiles(t, map[string]string{".github/workflows/test.yml": body})
	if len(set.Entries) != 1 || set.Entries[0].Runnable {
		t.Fatalf("entries = %+v, want one requires-runner entry", set.Entries)
	}
}

func TestDeriveDropsOnlyCheckoutSetupAndCache(t *testing.T) {
	t.Parallel()

	body := `on: pull_request
jobs:
  test:
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
      - uses: actions/cache@v4
      - uses: actions/upload-artifact@v4
`
	set := deriveFiles(t, map[string]string{".github/workflows/test.yml": body})
	if len(set.Entries) != 1 {
		t.Fatalf("entry count = %d, want 1: %+v", len(set.Entries), set.Entries)
	}
	entry := set.Entries[0]
	if entry.Action != "actions/upload-artifact@v4" || entry.Runnable || entry.RequiresRunnerReason == "" {
		t.Errorf("kept action = %+v, want a requires-runner upload-artifact entry", entry)
	}
}

func TestDeriveReadsOnlyWorkflowFiles(t *testing.T) {
	t.Parallel()

	files := map[string]string{
		".github/workflows/test.yml": "on: pull_request\njobs:\n  test:\n    steps:\n      - run: echo ok\n",
	}
	git := &fakeGit{
		ref: "origin/main", revision: testRevision, files: files,
		paths: []string{
			".github/workflows/README.md", ".github/workflows/test.yml", "package.json", "Makefile",
		},
	}
	set, err := checks.Derive(t.Context(), git, "main", "origin/main")
	if err != nil {
		t.Fatalf("Derive() error = %v", err)
	}
	if len(set.Entries) != 1 {
		t.Fatalf("entry count = %d, want 1: %+v", len(set.Entries), set.Entries)
	}
}

func TestDeriveRejectsUnparseableYAML(t *testing.T) {
	t.Parallel()

	files := map[string]string{
		".github/workflows/a-good.yml": "on: pull_request\njobs:\n  test:\n    steps:\n      - run: echo ok\n",
		".github/workflows/b-bad.yml":  "on: [push\n",
	}
	paths := []string{".github/workflows/a-good.yml", ".github/workflows/b-bad.yml"}
	git := &fakeGit{ref: "origin/main", revision: testRevision, paths: paths, files: files}
	set, err := checks.Derive(t.Context(), git, "main", "origin/main")
	if err == nil {
		t.Fatal("Derive() error = nil, want unparseable YAML to fail")
	}
	if exitcode.CodeOf(err) == exitcode.OK {
		t.Errorf("exit code = 0, want non-zero")
	}
	if len(set.Entries) != 0 || set.Revision != "" {
		t.Errorf("Derive() returned a partial set %+v, want no set on error", set)
	}
}

func TestDeriveIsFreshEachCall(t *testing.T) {
	t.Parallel()

	git := &fakeGit{
		ref: "origin/main", revision: testRevision,
		paths: []string{".github/workflows/test.yml"},
		files: map[string]string{".github/workflows/test.yml": "on: pull_request\njobs:\n  test:\n    steps:\n      - run: echo first\n"},
	}
	first, err := checks.Derive(t.Context(), git, "main", "origin/main")
	if err != nil {
		t.Fatalf("Derive() error = %v", err)
	}
	git.files[".github/workflows/test.yml"] = "on: pull_request\njobs:\n  test:\n    steps:\n      - run: echo second\n"
	git.revision = "fedcba9876543210fedcba9876543210fedcba98"
	second, err := checks.Derive(t.Context(), git, "main", "origin/main")
	if err != nil {
		t.Fatalf("Derive() error = %v", err)
	}
	if first.Entries[0].Command == second.Entries[0].Command {
		t.Errorf("both derivations returned %q, want a fresh read", second.Entries[0].Command)
	}
	if second.Revision == first.Revision {
		t.Errorf("revision did not change: %s", second.Revision)
	}
}

func TestDeriveRequiresBaseAndRef(t *testing.T) {
	t.Parallel()

	git := &fakeGit{ref: "origin/main", revision: testRevision, paths: nil, files: map[string]string{}}
	if _, err := checks.Derive(t.Context(), git, "", "origin/main"); exitcode.CodeOf(err) != exitcode.Usage {
		t.Errorf("empty base error = %v, want usage", err)
	}
	if _, err := checks.Derive(t.Context(), git, "main", ""); exitcode.CodeOf(err) != exitcode.Usage {
		t.Errorf("empty ref error = %v, want usage", err)
	}
}

func TestLoadSetRejectsBadFiles(t *testing.T) {
	t.Parallel()

	dir := t.TempDir()
	tests := map[string]string{
		"malformed JSON": `{`,
		"unknown field":  `{"ref":"origin/main","revision":"abc","base":"main","default_branch_push":"none","entries":[],"extra":1}`,
		"missing ref":    `{"revision":"abc"}`,
		"trailing data":  `{"ref":"origin/main","revision":"abc","base":"main","default_branch_push":"none","entries":[]} {}`,
	}
	for name, body := range tests {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			path := filepath.Join(dir, strings.ReplaceAll(name, " ", "-")+".json")
			if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
				t.Fatal(err)
			}
			if _, err := checks.LoadSet(path); err == nil {
				t.Error("LoadSet() error = nil, want an error")
			}
		})
	}
}

func TestLoadSetAcceptsDeriveOutput(t *testing.T) {
	t.Parallel()

	body := `{"ref":"origin/main","base":"main","revision":"abc","default_branch_push":"none","entries":[` +
		`{"file":"a.yml","job":"j","step":"s","step_index":0,"kind":"run","command":"true","action":"",` +
		`"working_directory":"","env":{},"shell":"","runnable":true,"requires_runner_reason":""}]}`
	path := filepath.Join(t.TempDir(), "set.json")
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	set, err := checks.LoadSet(path)
	if err != nil {
		t.Fatalf("LoadSet() error = %v", err)
	}
	if set.Revision != "abc" || len(set.Entries) != 1 || !set.Entries[0].Runnable {
		t.Errorf("LoadSet() = %+v", set)
	}
}

func TestClassifyNeverUsesScriptNames(t *testing.T) {
	t.Parallel()

	step := singleStep(t, "      - run: npm run lint")
	if !step.Runnable {
		t.Errorf("entry = %+v, want runnable: classification may not infer from a script name", step)
	}
}

func TestDeriveErrorsAreNotSilentlyEmpty(t *testing.T) {
	t.Parallel()

	git := &fakeGit{ref: "origin/main", revision: "", paths: nil, files: map[string]string{}}
	if _, err := checks.Derive(t.Context(), git, "main", "origin/main"); err == nil {
		t.Error("Derive() with no revision error = nil, want an error")
	}
}

func TestDeriveWrapsGitReadErrors(t *testing.T) {
	t.Parallel()

	git := &errorGit{err: errors.New("git failed")}
	if _, err := checks.Derive(t.Context(), git, "main", "origin/main"); err == nil {
		t.Error("Derive() error = nil, want the git read error")
	}
}

type errorGit struct {
	err error
}

func (g *errorGit) Git(context.Context, ...string) ([]byte, error) { return nil, g.err }

func TestDeriveResolvesAliasedJobsAndSteps(t *testing.T) {
	t.Parallel()

	body := `on: pull_request
x-steps: &steps
  - run: echo one
  - run: echo two
x-jobs: &jobs
  test:
    steps: *steps
jobs: *jobs
`
	set := deriveFiles(t, map[string]string{".github/workflows/test.yml": body})
	if len(set.Entries) != 2 {
		t.Fatalf("entry count = %d, want 2; entries = %+v", len(set.Entries), set.Entries)
	}
	if set.Entries[0].Command != "echo one" || set.Entries[1].Command != "echo two" {
		t.Errorf("commands = %q and %q, want the aliased steps in order", set.Entries[0].Command, set.Entries[1].Command)
	}
}

func TestDeriveMergesWorkflowJobStepEnv(t *testing.T) {
	t.Parallel()

	body := `on: pull_request
env:
  WORKFLOW: workflow
  SHARED: workflow
jobs:
  test:
    env:
      JOB: job
      SHARED: job
    steps:
      - run: echo env
        env:
          STEP: step
          SHARED: step
`
	set := deriveFiles(t, map[string]string{".github/workflows/test.yml": body})
	if len(set.Entries) != 1 {
		t.Fatalf("entry count = %d, want 1", len(set.Entries))
	}
	want := map[string]string{"WORKFLOW": "workflow", "JOB": "job", "STEP": "step", "SHARED": "step"}
	if len(set.Entries[0].Env) != len(want) {
		t.Fatalf("env = %v, want %v", set.Entries[0].Env, want)
	}
	for key, value := range want {
		if set.Entries[0].Env[key] != value {
			t.Errorf("env[%s] = %q, want %q", key, set.Entries[0].Env[key], value)
		}
	}
}

func TestDeriveResolvesAliasedRunShellEnvAndTrigger(t *testing.T) {
	t.Parallel()

	body := `x-cfg: &cfg
  branches: [main]
on:
  push: *cfg
x-run: &script echo aliased
x-shell: &shell sh
x-env: &env
  K: v
jobs:
  test:
    steps:
      - run: *script
        shell: *shell
        env: *env
`
	set := deriveFiles(t, map[string]string{".github/workflows/test.yml": body})
	if len(set.Entries) != 1 {
		t.Fatalf("entry count = %d, want 1; entries = %+v", len(set.Entries), set.Entries)
	}
	entry := set.Entries[0]
	if entry.Command != "echo aliased" || entry.Shell != "sh" || entry.Env["K"] != "v" {
		t.Errorf("entry = %+v, want the aliased run, shell, and env", entry)
	}
}

func TestDeriveDropsAliasedPushConfigThatExcludesBase(t *testing.T) {
	t.Parallel()

	body := `x-cfg: &cfg
  branches: [develop]
on:
  push: *cfg
jobs:
  test:
    steps:
      - run: echo no
`
	set := deriveFiles(t, map[string]string{".github/workflows/test.yml": body})
	if len(set.Entries) != 0 {
		t.Errorf("entries = %+v, want the aliased push filter to drop the workflow", set.Entries)
	}
}
