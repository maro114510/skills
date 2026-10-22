package checks_test

import (
	"encoding/json"
	"slices"
	"strconv"
	"testing"

	"github.com/maro114510/skills/oe/internal/checks"
)

func nodes(t *testing.T, raw string) []checks.Context {
	t.Helper()
	var out []checks.Context
	if err := json.Unmarshal([]byte(raw), &out); err != nil {
		t.Fatalf("fixture: %v", err)
	}
	return out
}

func classOf(t *testing.T, raw string) checks.Class {
	t.Helper()
	got := checks.Latest(nodes(t, raw))
	if len(got) != 1 {
		t.Fatalf("Latest() = %v, want one check", got)
	}
	return got[0].Class
}

func TestClassOfOneCheck(t *testing.T) {
	t.Parallel()

	run := func(status, conclusion string) string {
		return `[{"__typename":"CheckRun","name":"x","status":` + status + `,"conclusion":` + conclusion + `}]`
	}
	status := func(state string) string {
		return `[{"__typename":"StatusContext","context":"x","state":` + state + `}]`
	}
	tests := map[string]struct {
		raw  string
		want checks.Class
	}{
		"success":              {run(`"COMPLETED"`, `"SUCCESS"`), checks.Pass},
		"neutral":              {run(`"COMPLETED"`, `"NEUTRAL"`), checks.Pass},
		"skipped":              {run(`"COMPLETED"`, `"SKIPPED"`), checks.Pass},
		"in progress":          {run(`"IN_PROGRESS"`, `null`), checks.Pending},
		"queued":               {run(`"QUEUED"`, `null`), checks.Pending},
		"failure":              {run(`"COMPLETED"`, `"FAILURE"`), checks.Failed},
		"timed out":            {run(`"COMPLETED"`, `"TIMED_OUT"`), checks.Failed},
		"stale":                {run(`"COMPLETED"`, `"STALE"`), checks.Failed},
		"startup failure":      {run(`"COMPLETED"`, `"STARTUP_FAILURE"`), checks.Failed},
		"action required":      {run(`"COMPLETED"`, `"ACTION_REQUIRED"`), checks.Action},
		"cancelled":            {run(`"COMPLETED"`, `"CANCELLED"`), checks.Cancelled},
		"no status":            {run(`null`, `null`), checks.Unreadable},
		"completed, no result": {run(`"COMPLETED"`, `null`), checks.Unreadable},
		"status success":       {status(`"SUCCESS"`), checks.Pass},
		"status pending":       {status(`"PENDING"`), checks.Pending},
		"status expected":      {status(`"EXPECTED"`), checks.Pending},
		"status failure":       {status(`"FAILURE"`), checks.Failed},
		"status error":         {status(`"ERROR"`), checks.Failed},
		"status without state": {status(`null`), checks.Unreadable},
		"unknown kind":         {`[{"__typename":"SomethingElse"}]`, checks.Unreadable},
		"null node":            {`[null]`, checks.Unreadable},
	}
	for name, tc := range tests {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			if got := classOf(t, tc.raw); got != tc.want {
				t.Errorf("class = %s, want %s", got, tc.want)
			}
		})
	}
}

func TestChecksAreOrderedByKey(t *testing.T) {
	t.Parallel()

	got := checks.Latest(nodes(t, `[
		null,
		{"__typename":"CheckRun","name":"run","status":"COMPLETED","conclusion":"SUCCESS","checkSuite":{"databaseId":9}},
		{"__typename":"StatusContext","context":"ci/lint","state":"SUCCESS"}]`))
	names := make([]string, 0, len(got))
	for _, c := range got {
		names = append(names, c.Name)
	}
	// Statuses first, then suites, then runs without a suite by position.
	if want := []string{"ci/lint", "run", checks.UnnamedCheck}; !slices.Equal(names, want) {
		t.Errorf("names = %v, want %v", names, want)
	}
}

func TestLatestKeepsTheNewestRunOfACheck(t *testing.T) {
	t.Parallel()

	run := func(conclusion, started string, suite int) string {
		return `{"__typename":"CheckRun","name":"test","status":"COMPLETED","conclusion":"` + conclusion +
			`","startedAt":"` + started + `","checkSuite":{"databaseId":` + strconv.Itoa(suite) + `}}`
	}
	tests := map[string]struct {
		raw  string
		want []checks.Class
	}{
		"a re-run in the same suite supersedes": {
			`[` + run("FAILURE", "2026-10-19T01:00:00Z", 1) + `,` + run("SUCCESS", "2026-10-19T02:00:00Z", 1) + `]`,
			[]checks.Class{checks.Pass},
		},
		"order in the list does not matter": {
			`[` + run("SUCCESS", "2026-10-19T02:00:00Z", 1) + `,` + run("FAILURE", "2026-10-19T01:00:00Z", 1) + `]`,
			[]checks.Class{checks.Pass},
		},
		"a run that has not started counts as the latest": {
			`[{"__typename":"CheckRun","name":"test","status":"QUEUED","conclusion":null,"checkSuite":{"databaseId":1}},` +
				run("FAILURE", "2026-10-19T01:00:00Z", 1) + `]`,
			[]checks.Class{checks.Pending},
		},
		"another suite is another check": {
			`[` + run("FAILURE", "2026-10-19T01:00:00Z", 1) + `,` + run("SUCCESS", "2026-10-19T02:00:00Z", 2) + `]`,
			[]checks.Class{checks.Failed, checks.Pass},
		},
		"runs without a suite are never collapsed": {
			`[{"__typename":"CheckRun","name":"test","status":"COMPLETED","conclusion":"FAILURE","startedAt":"2026-10-19T01:00:00Z"},` +
				`{"__typename":"CheckRun","name":"test","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-10-19T02:00:00Z"}]`,
			[]checks.Class{checks.Failed, checks.Pass},
		},
		"a re-posted status supersedes the earlier one": {
			`[{"__typename":"StatusContext","context":"a","state":"FAILURE","createdAt":"2026-10-19T01:00:00Z"},` +
				`{"__typename":"StatusContext","context":"a","state":"SUCCESS","createdAt":"2026-10-19T02:00:00Z"}]`,
			[]checks.Class{checks.Pass},
		},
	}
	for name, tc := range tests {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			latest := checks.Latest(nodes(t, tc.raw))
			got := make([]checks.Class, 0, len(latest))
			for _, c := range latest {
				got = append(got, c.Class)
			}
			if !slices.Equal(got, tc.want) {
				t.Errorf("classes = %v, want %v", got, tc.want)
			}
		})
	}
}

func TestNamed(t *testing.T) {
	t.Parallel()

	all := []checks.Check{{Name: "a", Class: checks.Failed}, {Name: "b", Class: checks.Pass}, {Name: "c", Class: checks.Failed}}
	if got := checks.Named(all, checks.Failed); !slices.Equal(got, []string{"a", "c"}) {
		t.Errorf("Named() = %v, want [a c]", got)
	}
	if got := checks.Named(all, checks.Pending); got != nil {
		t.Errorf("Named() = %v, want nil", got)
	}
}
