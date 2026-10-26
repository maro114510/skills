// Package ship publishes an approved Issue, contract §18: the pull request body, the remote the
// recorded intent expects, and the create-pr scripts that open and link the pull request. It
// reads and writes nothing itself apart from running those scripts.
package ship

import (
	"context"

	"github.com/maro114510/skills/oe/internal/state"
)

// Body is what the pull request body is composed from.
type Body struct {
	// Summary and Checks are the worker report's SUMMARY and CHECKS.
	Summary string
	Checks  string
	// Nits is how each reviewer nit was resolved, empty for none.
	Nits string
	// Evidence is the reviewer's bound evidence, never the worker's CRITERIA.
	Evidence     state.ReviewEvidence
	ReviewedSHA  string
	VerifiedBase string
	// Closing are the closing lines for the body.
	Closing []string
	Epic    int
}

// Render composes the body.
func (Body) Render() string { return "" }

// ClosingLines turns the output of issue-refs.sh into the closing lines of the body.
// An Issue the script printed nothing for gets Closes when nothing was skipped, else Related.
func ClosingLines(string, int, bool) []string { return nil }

// Skipped reports whether a worker report's SKIPPED field names anything deferred.
func Skipped(string) bool { return false }

// PRNumber reads the pull request number from the last line create-linked-pr.sh printed.
func PRNumber(string) (int, bool) { return 0, false }

// Remote says how the remote branch relates to the recorded publish.
type Remote string

// The relations of the remote branch to the recorded publish.
const (
	// RemoteAbsent is a branch that is not on the remote where none is expected.
	RemoteAbsent Remote = "absent"
	// RemoteAtPublished is a branch at the SHA the publish records.
	RemoteAtPublished Remote = "at-published"
	// RemoteAtPrev is a branch still at the head the intent was recorded against.
	RemoteAtPrev Remote = "at-prev"
	// RemoteExternal is a branch the recorded publish does not explain.
	RemoteExternal Remote = "external"
)

// Expect classifies the remote head against the recorded publish. An empty remote means no branch.
func Expect(*state.Publish, string) Remote { return "" }

// Scripts are the create-pr skill's scripts.
type Scripts struct {
	Create string
	Refs   string
}

// ResolveScripts finds both scripts in the create-pr skill's scripts directory.
func ResolveScripts(string) (Scripts, error) { return Scripts{Create: "", Refs: ""}, nil }

// CreateArgs are the arguments that open a pull request.
func CreateArgs(repo, head, base, title, bodyFile string) []string { return nil }

// LinkArgs are the arguments that link an existing pull request to its Issues.
func LinkArgs(repo string, pr int) []string { return nil }

// Script is one script run: its path, arguments, and working directory.
type Script struct {
	Path string
	Args []string
	Dir  string
}

// ScriptResult is a finished script. A non-zero ExitCode is a result, not an error.
type ScriptResult struct {
	ExitCode int
	Stdout   string
	Stderr   string
}

// ScriptRunner runs a script. Exec runs a real process.
type ScriptRunner interface {
	RunScript(ctx context.Context, s Script) (ScriptResult, error)
}

// Exec runs a script with bash.
type Exec struct{}

// RunScript implements ScriptRunner.
func (Exec) RunScript(context.Context, Script) (ScriptResult, error) {
	return ScriptResult{ExitCode: 0, Stdout: "", Stderr: ""}, nil
}
