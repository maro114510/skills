package signals_test

import (
	"testing"

	"github.com/maro114510/skills/oe/internal/signals"
)

func TestParseStrictCommands(t *testing.T) {
	t.Parallel()

	tests := map[string]struct {
		body string
		want signals.Command
	}{
		"plain":                   {"epic-retry", signals.Retry},
		"surrounding whitespace":  {"  epic-redo \n", signals.Redo},
		"repeated on every line":  {"epic-drop\n\nepic-drop", signals.Drop},
		"windows line endings":    {"epic-approve\r\nepic-approve\r\n", signals.Approve},
		"auto merge":              {"epic-auto-merge", signals.AutoMerge},
		"revoke":                  {"epic-revoke-auto-merge", signals.RevokeAutoMerge},
		"release":                 {"epic-release", signals.Release},
		"inside other text":       {"let's not epic-retry yet", signals.None},
		"trailing words":          {"epic-retry please", signals.None},
		"uppercase":               {"EPIC-RETRY", signals.None},
		"two different commands":  {"epic-retry\nepic-drop", signals.None},
		"command with a reason":   {"epic-retry\nthe fix landed", signals.None},
		"unknown command":         {"epic-nope", signals.None},
		"blank":                   {" \n\t\n", signals.None},
		"empty":                   {"", signals.None},
		"a quoted command":        {"> epic-retry", signals.None},
		"a command with a bullet": {"- epic-retry", signals.None},
	}
	for name, tc := range tests {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			if got := signals.Parse(tc.body); got != tc.want {
				t.Errorf("Parse(%q) = %q, want %q", tc.body, got, tc.want)
			}
		})
	}
}

func TestTrusted(t *testing.T) {
	t.Parallel()

	tests := map[string]struct {
		association string
		body        string
		want        bool
	}{
		"owner":             {"OWNER", "epic-retry", true},
		"member":            {"MEMBER", "hello", true},
		"collaborator":      {"COLLABORATOR", "hello", true},
		"contributor":       {"CONTRIBUTOR", "epic-retry", false},
		"none":              {"NONE", "epic-retry", false},
		"first timer":       {"FIRST_TIME_CONTRIBUTOR", "epic-retry", false},
		"empty association": {"", "epic-retry", false},
		"loop marker":       {"OWNER", "<!-- oe:v2 note x -->", false},
		"loop plain prefix": {"OWNER", "orchestrate-epic: parked", false},
		"marker after text": {"OWNER", "see <!-- x -->", true},
	}
	for name, tc := range tests {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			if got := signals.Trusted(tc.association, tc.body); got != tc.want {
				t.Errorf("Trusted(%q, %q) = %v, want %v", tc.association, tc.body, got, tc.want)
			}
		})
	}
}

func TestBlank(t *testing.T) {
	t.Parallel()

	if !signals.Blank(" \n\t") || signals.Blank("x") {
		t.Error("Blank() misjudged a body")
	}
}
