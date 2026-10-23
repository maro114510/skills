package cmd_test

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/maro114510/skills/oe/internal/runner"
)

// mixed runs git against a real temporary repository for every `git -C <dir>` call, and sends
// gh and every other git call to the fake, so nothing touches the repository the test runs in.
// The shared checkout's origin is a local bare repository, so its URL reads as o/r here.
type mixed struct {
	fake runner.Runner
}

func (m mixed) Run(ctx context.Context, prog runner.Program, args []string) (runner.Result, error) {
	if prog != runner.Git || len(args) < 2 || args[0] != "-C" && args[0] != "-c" {
		return m.fake.Run(ctx, prog, args)
	}
	if strings.Contains(strings.Join(args, " "), "remote get-url origin") {
		return runner.Result{Stdout: []byte("https://github.com/o/r.git\n"), Stderr: nil, ExitCode: 0}, nil
	}
	return runner.Exec{}.Run(ctx, prog, args)
}

func gitIn(t *testing.T, dir string, args ...string) string {
	t.Helper()
	ident := []string{"-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false", "-C", dir}
	res, err := runner.Exec{}.Run(t.Context(), runner.Git, append(ident, args...))
	if err != nil || res.ExitCode != 0 {
		t.Fatalf("git %v: %v, exit %d\n%s", args, err, res.ExitCode, res.Stderr)
	}
	return strings.TrimSpace(string(res.Stdout))
}

func commitIn(t *testing.T, dir, file, text string) string {
	t.Helper()
	if err := os.WriteFile(filepath.Join(dir, file), []byte(text), 0o600); err != nil {
		t.Fatal(err)
	}
	gitIn(t, dir, "add", file)
	gitIn(t, dir, "commit", "-q", "-m", text)
	return gitIn(t, dir, "rev-parse", "HEAD")
}

// sharedRepo is a shared checkout on main with origin/main fetched from a bare origin.
func sharedRepo(t *testing.T) string {
	t.Helper()
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	shared, origin := filepath.Join(root, "r"), filepath.Join(root, "origin.git")
	gitIn(t, root, "init", "-q", "--bare", "-b", "main", origin)
	gitIn(t, root, "init", "-q", "-b", "main", shared)
	commitIn(t, shared, "a.txt", "one")
	gitIn(t, shared, "remote", "add", "origin", origin)
	gitIn(t, shared, "push", "-q", "origin", "main")
	gitIn(t, shared, "fetch", "-q", "origin")
	return shared
}

func implementPath(t *testing.T) string {
	t.Helper()
	p, err := filepath.Abs("../../skills/implement/SKILL.md")
	if err != nil {
		t.Fatal(err)
	}
	return p
}

// checksSet writes a CHECKS_SET for main derived at revision with one runnable and one requires-runner entry.
func checksSet(t *testing.T, revision string) string {
	t.Helper()
	return checksSetFor(t, "main", revision)
}

// checksSetFor is checksSet for the default branch base.
func checksSetFor(t *testing.T, base, revision string) string {
	t.Helper()
	entry := func(step, command string, runnable bool) map[string]any {
		return map[string]any{
			"file": ".github/workflows/ci.yml", "job": "test", "step": step, "step_index": 0, "kind": "run", "command": command,
			"action": "", "working_directory": "oe", "env": map[string]string{}, "shell": "bash", "runnable": runnable,
			"requires_runner_reason": "",
		}
	}
	data, err := json.Marshal(map[string]any{
		"ref": "origin/" + base, "base": base, "revision": revision, "default_branch_push": "runs",
		"entries": []any{entry("go test", "go test ./...", true), entry("deploy", "sudo deploy", false)},
	})
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), "checks.json")
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

func (w *coordWorld) runIn(exec runner.Runner, stdin string, args ...string) result {
	return runEnv(exec, w.dir, stdin, append([]string{"--epic", "277"}, args...)...)
}

func decode[T any](t *testing.T, r result) T {
	t.Helper()
	var v T
	if err := json.Unmarshal([]byte(r.stdout), &v); err != nil {
		t.Fatalf("exit %d, stdout %q: %v", r.code, r.stdout, err)
	}
	return v
}

// TestWorkerHandoffFlow: state, worktree, brief, and report, end to end, with the shared
// checkout left exactly as it was.
func TestWorkerHandoffFlow(t *testing.T) {
	t.Parallel()

	w := newCoordWorld(t)
	m := mixed{fake: w.r}
	shared := sharedRepo(t)
	before := gitIn(t, shared, "rev-parse", "HEAD") + gitIn(t, shared, "status", "--porcelain")
	token := w.acquire(t)
	tok := []string{"--lease-token", token, "--repo-dir", shared}
	if r := w.runIn(m, "", "state", "start", "--issue", "7", "--lease-token", token); r.code != 0 {
		t.Fatalf("start: %d %q", r.code, r.stdout)
	}

	wt := decode[struct {
		Worktree string `json:"worktree"`
		Source   string `json:"source"`
		Base     string `json:"base"`
	}](t, w.runIn(m, "", append([]string{"worker", "worktree", "--issue", "7"}, tok...)...))
	if wt.Source != "new-branch" || wt.Base != gitIn(t, shared, "rev-parse", "origin/main") {
		t.Fatalf("worktree = %+v", wt)
	}

	set := checksSet(t, wt.Base)
	r := w.runIn(m, "", append([]string{"worker", "brief", "--issue", "7", "--worktree", wt.Worktree,
		"--implement", implementPath(t), "--checks-set", set}, tok...)...)
	brief := decode[struct {
		Prompt string `json:"prompt"`
	}](t, r)
	for _, want := range []string{"#7", wt.Worktree, "feat/issue-7", "go test ./...", implementPath(t)} {
		if !strings.Contains(brief.Prompt, want) {
			t.Errorf("brief lacks %q", want)
		}
	}
	if strings.Contains(brief.Prompt, "sudo deploy") {
		t.Error("a requires-runner entry reached the brief")
	}

	head := commitIn(t, wt.Worktree, "w.txt", "worker")
	rep := "STATUS: DONE\nISSUE: #7\nBRANCH: feat/issue-7\nWORKTREE: " + wt.Worktree + "\nHEAD_SHA: " + head + "\nSUMMARY: done\n"
	res := decode[struct {
		Route string `json:"route"`
		Next  string `json:"next"`
	}](t, w.runIn(m, rep, append([]string{"worker", "report", "--issue", "7", "--worktree", wt.Worktree}, tok...)...))
	if res.Route != "DONE" || res.Next != "review" {
		t.Errorf("report = %+v", res)
	}
	if after := gitIn(t, shared, "rev-parse", "HEAD") + gitIn(t, shared, "status", "--porcelain"); after != before {
		t.Errorf("shared checkout changed: %q -> %q", before, after)
	}
}

func briefArgsWith(full map[string]string, drop, key, value string) []string {
	args := make([]string, 0, 6+2*len(full))
	args = append(args, "--epic", "277", "worker", "brief", "--lease-token", "tok")
	for k, v := range full {
		switch k {
		case drop:
			continue
		case key:
			v = value
		}
		args = append(args, k, v)
	}
	return args
}

// TestBriefMissingAFieldIsRefusedBeforeAnyCall: a brief without CHECKS_SET, the implement path,
// the worktree, or the Issue exits 8 before any call, so no worker is spawned.
func TestBriefMissingAFieldIsRefusedBeforeAnyCall(t *testing.T) {
	t.Parallel()

	impl, set := implementPath(t), checksSet(t, "base1")
	full := map[string]string{"--issue": "7", "--worktree": "/w", "--implement": impl, "--checks-set": set}
	for drop := range full {
		s := newSpy(healthy(probeOK, 0))
		r := runEnv(s, t.TempDir(), "", briefArgsWith(full, drop, "", "")...)
		if r.code != 8 || !strings.Contains(r.stdout, "incomplete brief") || s.count() != 0 {
			t.Errorf("without %s: exit %d, stdout %q, calls %d", drop, r.code, r.stdout, s.count())
		}
	}
	for name, bad := range map[string][2]string{
		"relative implement": {"--implement", "skills/implement/SKILL.md"},
		"not SKILL.md":       {"--implement", filepath.Dir(impl)},
		"unreadable set":     {"--checks-set", filepath.Join(t.TempDir(), "none.json")},
	} {
		s := newSpy(healthy(probeOK, 0))
		if r := runEnv(s, t.TempDir(), "", briefArgsWith(full, "", bad[0], bad[1])...); r.code != 8 || s.count() != 0 {
			t.Errorf("%s: exit %d, stdout %q, calls %d", name, r.code, r.stdout, s.count())
		}
	}
}

// TestReportJudgmentsApplyOnlyToABlockedReport: a ship-class kind outside the closed set, a
// judgment on a report that is not BLOCKED, and an answer to a question the loop never answers
// are usage errors before any call.
func TestReportJudgmentsApplyOnlyToABlockedReport(t *testing.T) {
	t.Parallel()

	answer := filepath.Join(t.TempDir(), "a.md")
	if err := os.WriteFile(answer, []byte("B"), 0o600); err != nil {
		t.Fatal(err)
	}
	blocked := "STATUS: BLOCKED\nISSUE: #7\nBRANCH: feat/issue-7\nWORKTREE: /w\nQUESTIONS: A or B?\n"
	done := "STATUS: DONE\nISSUE: #7\nBRANCH: feat/issue-7\nWORKTREE: /w\nHEAD_SHA: abcdef0\n"
	tests := map[string]struct {
		report string
		flags  []string
	}{
		"unknown kind":             {blocked, []string{"--ship-class", "size"}},
		"answer on DONE":           {done, []string{"--answer-file", answer}},
		"ship-class on malformed":  {"nonsense", []string{"--ship-class", "scope"}},
		"answer with ship-class":   {blocked, []string{"--ship-class", "scope", "--answer-file", answer}},
		"answer to commit-approve": {blocked, []string{"--commit-approval", "--answer-file", answer}},
	}
	for name, tc := range tests {
		s := newSpy(healthy(probeOK, 0))
		args := append([]string{"--epic", "277", "worker", "report", "--issue", "7", "--worktree", "/w", "--lease-token", "tok"}, tc.flags...)
		if r := runEnv(s, t.TempDir(), tc.report, args...); r.code != 2 || s.count() != 0 {
			t.Errorf("%s: exit %d, stdout %q, calls %d", name, r.code, r.stdout, s.count())
		}
	}
}
