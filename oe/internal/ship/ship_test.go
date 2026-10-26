package ship_test

import (
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/maro114510/skills/oe/internal/exitcode"
	"github.com/maro114510/skills/oe/internal/ship"
	"github.com/maro114510/skills/oe/internal/state"
)

func publish(sha, prev, base string, phase string) *state.Publish {
	return &state.Publish{SHA: sha, PrevSHA: prev, Base: base, Branch: "feat/issue-7", PR: 0, Phase: phase}
}

// TestBodyCarriesTheReviewersEvidenceAndTheBoundPair shows what a pull request body holds.
// The evidence is the reviewer's, in the reviewer's own line format, and the pair is the one the approval binds.
func TestBodyCarriesTheReviewersEvidenceAndTheBoundPair(t *testing.T) {
	t.Parallel()

	b := ship.Body{
		Summary: "Adds the flag.", Checks: "go test ./... -> exit 0", Nits: "",
		Evidence: state.ReviewEvidence{BehaviorChange: true, Basis: "adds a flag", Criteria: []state.Criterion{
			{Text: "the flag exists", Result: "verified", Kind: "behavior", Evidence: "ran oe --help and saw --flag"},
			{Text: "(derived) the help is short", Result: "verified", Kind: "static", Evidence: "help.go:12"},
		}},
		ReviewedSHA: "aaa111", VerifiedBase: "bbb222", Closing: []string{"Closes #7"}, Epic: 277,
	}
	want := `## Summary
Adds the flag.

## Check evidence
go test ./... -> exit 0

## Acceptance evidence
Gathered by the independent reviewer on reviewed_sha against verified_base; valid only while both still match. This is a snapshot taken when the PR was created; the Issue's state holds the evidence currently bound, and is the one every gate reads.
BEHAVIOR_CHANGE: yes — adds a flag
1. the flag exists -> verified [behavior] — ran oe --help and saw --flag
2. (derived) the help is short -> verified [static] — help.go:12

## Review
- reviewed_sha: aaa111
- verified_base: bbb222
- Reviewer nits and resolution: なし

Closes #7
Part of Epic #277
`
	if got := b.Render(); got != want {
		t.Errorf("body =\n%s\nwant\n%s", got, want)
	}
}

// TestBodyFillsEmptySectionsAndKeepsTheNits shows an empty summary or check list reads as none, and a nit keeps the resolution it was given.
func TestBodyFillsEmptySectionsAndKeepsTheNits(t *testing.T) {
	t.Parallel()

	b := ship.Body{
		Summary: "", Checks: "", Nits: "a.go:3 — rename -> renamed in 1f2e3d4",
		Evidence:    state.ReviewEvidence{BehaviorChange: false, Basis: "docs only", Criteria: []state.Criterion{{Text: "t", Result: "verified", Kind: "static", Evidence: "e"}}},
		ReviewedSHA: "a", VerifiedBase: "b", Closing: []string{"Related #7", "Closes #9"}, Epic: 1,
	}
	got := b.Render()
	for _, want := range []string{"## Summary\nなし\n", "## Check evidence\nなし\n", "BEHAVIOR_CHANGE: no — docs only\n",
		"- Reviewer nits and resolution: a.go:3 — rename -> renamed in 1f2e3d4\n", "Related #7\nCloses #9\nPart of Epic #1\n"} {
		if !strings.Contains(got, want) {
			t.Errorf("body lacks %q:\n%s", want, got)
		}
	}
}

func TestClosingLines(t *testing.T) {
	t.Parallel()

	cases := map[string]struct {
		out     string
		skipped bool
		want    []string
	}{
		"nothing printed, nothing skipped":   {"", false, []string{"Closes #7"}},
		"nothing printed, something skipped": {"", true, []string{"Related #7"}},
		"the script names the Issue":         {"Closes #7\n", true, []string{"Closes #7"}},
		"the script names only another":      {"Related #5\n", false, []string{"Related #5", "Closes #7"}},
		"blank lines are dropped":            {"\nRelated #7\n\n", false, []string{"Related #7"}},
	}
	for name, c := range cases {
		if got := ship.ClosingLines(c.out, 7, c.skipped); !slices.Equal(got, c.want) {
			t.Errorf("%s: %q, want %q", name, got, c.want)
		}
	}
}

func TestSkipped(t *testing.T) {
	t.Parallel()

	for field, want := range map[string]bool{
		"": false, "none": false, "None": false, "なし": false, "  \n": false,
		"criterion 2 -> done by hand, because X": true,
	} {
		if got := ship.Skipped(field); got != want {
			t.Errorf("Skipped(%q) = %v, want %v", field, got, want)
		}
	}
}

func TestPRNumberReadsTheLastLineOfTheScript(t *testing.T) {
	t.Parallel()

	cases := map[string]struct {
		out  string
		want int
		ok   bool
	}{
		"url only":                {"https://github.com/o/r/pull/31\n", 31, true},
		"notice, url, link lines": {"NOTICE: rewrote\nhttps://github.com/o/r/pull/31\nLINKED #7\n", 31, true},
		"no url":                  {"LINKED #7\n", 0, false},
		"empty":                   {"", 0, false},
	}
	for name, c := range cases {
		got, found := ship.PRNumber(c.out)
		if got != c.want || found != c.ok {
			t.Errorf("%s: %d %v, want %d %v", name, got, found, c.want, c.ok)
		}
	}
}

// TestExpectExplainsOnlyTheRemoteTheRecordAccountsFor covers contract §8 Push.
// Equal to the published sha is pushed, equal to prev_sha or absent with none recorded is re-gate and push, and anything else stops.
func TestExpectExplainsOnlyTheRemoteTheRecordAccountsFor(t *testing.T) {
	t.Parallel()

	cases := map[string]struct {
		p      *state.Publish
		remote string
		want   ship.Remote
	}{
		"no record, no branch":             {nil, "", ship.RemoteAbsent},
		"no record, a branch":              {nil, "x1", ship.RemoteExternal},
		"intent, branch at the sha":        {publish("s1", "", "b", "intent"), "s1", ship.RemoteAtPublished},
		"intent, no branch, none recorded": {publish("s1", "", "b", "intent"), "", ship.RemoteAbsent},
		"intent, branch at prev":           {publish("s1", "p1", "b", "intent"), "p1", ship.RemoteAtPrev},
		"intent, prev recorded, no branch": {publish("s1", "p1", "b", "intent"), "", ship.RemoteExternal},
		"intent, another sha":              {publish("s1", "p1", "b", "intent"), "x1", ship.RemoteExternal},
		"pushed, branch at the sha":        {publish("s1", "", "b", "pushed"), "s1", ship.RemoteAtPublished},
		"pushed, no branch":                {publish("s1", "", "b", "pushed"), "", ship.RemoteExternal},
		"linked, branch at the sha":        {publish("s1", "", "b", "linked"), "s1", ship.RemoteAtPublished},
		"linked, no branch":                {publish("s1", "", "b", "linked"), "", ship.RemoteExternal},
		"linked, another sha":              {publish("s1", "", "b", "linked"), "x1", ship.RemoteExternal},
		"pushed, branch back at prev":      {publish("s1", "p1", "b", "pushed"), "p1", ship.RemoteExternal},
	}
	for name, c := range cases {
		if got := ship.Expect(c.p, c.remote); got != c.want {
			t.Errorf("%s: %q, want %q", name, got, c.want)
		}
	}
}

func TestCreateAndLinkArgs(t *testing.T) {
	t.Parallel()

	got := ship.CreateArgs("o/r", "feat/issue-7", "main", "Add the flag", "/tmp/body.md")
	want := []string{"--repo", "o/r", "--head", "feat/issue-7", "--base", "main", "--title", "Add the flag", "--body-file", "/tmp/body.md"}
	if !slices.Equal(got, want) {
		t.Errorf("create args = %q, want %q", got, want)
	}
	if got, want := ship.LinkArgs("o/r", 31), []string{"--repo", "o/r", "--link", "31"}; !slices.Equal(got, want) {
		t.Errorf("link args = %q, want %q", got, want)
	}
}

func writeScripts(t *testing.T, names ...string) string {
	t.Helper()
	dir := t.TempDir()
	for _, n := range names {
		if err := os.WriteFile(filepath.Join(dir, n), []byte("#!/usr/bin/env bash\n"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	return dir
}

func TestResolveScriptsNeedsBothScriptsAtAnAbsolutePath(t *testing.T) {
	t.Parallel()

	both := writeScripts(t, "create-linked-pr.sh", "issue-refs.sh")
	got, err := ship.ResolveScripts(both)
	if err != nil || got.Create != filepath.Join(both, "create-linked-pr.sh") || got.Refs != filepath.Join(both, "issue-refs.sh") {
		t.Errorf("resolved %+v, %v", got, err)
	}
	for name, dir := range map[string]string{
		"relative":       "skills/create-pr/scripts",
		"empty":          "",
		"no scripts":     writeScripts(t),
		"no refs script": writeScripts(t, "create-linked-pr.sh"),
		"missing":        filepath.Join(both, "nowhere"),
	} {
		if _, err := ship.ResolveScripts(dir); exitcode.CodeOf(err) != exitcode.Refused {
			t.Errorf("%s: %v, want refused", name, err)
		}
	}
}

// TestExecRunsTheScriptWithBashInItsDirectory shows the real runner: arguments reach the script, the working directory is the one named, and a non-zero exit is a result.
// GH_HOST is pinned to github.com whatever the caller's environment says.
func TestExecRunsTheScriptWithBashInItsDirectory(t *testing.T) { //nolint:paralleltest // t.Setenv cannot run in parallel.
	dir := t.TempDir()
	script := filepath.Join(t.TempDir(), "probe.sh")
	body := "#!/usr/bin/env bash\npwd -P\nprintf '%s|' \"$@\"\necho \"host=$GH_HOST\"\necho oops >&2\nexit 3\n"
	if err := os.WriteFile(script, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("GH_HOST", "ghe.example.com")
	real, err := filepath.EvalSymlinks(dir)
	if err != nil {
		t.Fatal(err)
	}
	res, err := ship.Exec{}.RunScript(t.Context(), ship.Script{Path: script, Args: []string{"--link", "31"}, Dir: dir})
	if err != nil {
		t.Fatal(err)
	}
	want := ship.ScriptResult{ExitCode: 3, Stdout: real + "\n--link|31|host=github.com\n", Stderr: "oops\n"}
	if res != want {
		t.Errorf("result = %+v, want %+v", res, want)
	}
}
