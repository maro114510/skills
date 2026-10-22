package snapshot_test

import (
	"slices"
	"testing"

	"github.com/maro114510/skills/oe/internal/exitcode"
	"github.com/maro114510/skills/oe/internal/gh"
	"github.com/maro114510/skills/oe/internal/runner"
	"github.com/maro114510/skills/oe/internal/snapshot"
)

func protectionCall(stdout, stderr string, exit int) runner.Call {
	return runner.Call{
		Argv:   []string{"gh", "api", "--hostname", "github.com", "repos/o/r/branches/main/protection"},
		Stdout: stdout, Stderr: stderr, ExitCode: exit,
	}
}

// TestOnlyAConfirmedNotProtectedMeansNoProtection guards RF-01 and CMD-14: GitHub's
// "Branch not protected" 404 is no protection; any other 404 or failure stops the read.
func TestOnlyAConfirmedNotProtectedMeansNoProtection(t *testing.T) {
	t.Parallel()

	c := gh.New(runner.NewSnapshot([]runner.Call{protectionCall(
		`{"message":"Branch not protected","status":"404"}`, "gh: Branch not protected (HTTP 404)", 1)}), false)
	p, err := snapshot.ReadProtection(t.Context(), c, "o/r", "main")
	if err != nil || p.Configured || p.Gated() || c.Err() != nil {
		t.Errorf("ReadProtection() = %+v, %v; client err %v", p, err, c.Err())
	}
	for name, call := range map[string]runner.Call{
		"hidden 404": protectionCall(`{"message":"Not Found"}`, "gh: Not Found (HTTP 404)", 1),
		"403":        protectionCall(`{"message":"Must have admin rights to Repository."}`, "gh: Must have admin rights to Repository. (HTTP 403)", 1),
		"bad body":   protectionCall(`{`, "", 0),
	} {
		c := gh.New(runner.NewSnapshot([]runner.Call{call}), false)
		if _, err := snapshot.ReadProtection(t.Context(), c, "o/r", "main"); exitcode.CodeOf(err) != exitcode.Unreadable {
			t.Errorf("%s: err = %v, want exit 1", name, err)
		}
	}
}

func TestProtectionReadsRequiredChecksAndReviewers(t *testing.T) {
	t.Parallel()

	body := `{"required_status_checks":{"contexts":["test","lint"],"checks":[{"context":"test"},{"context":"build"}]},` +
		`"required_pull_request_reviews":{"required_approving_review_count":2}}`
	c := gh.New(runner.NewSnapshot([]runner.Call{protectionCall(body, "", 0)}), false)
	p, err := snapshot.ReadProtection(t.Context(), c, "o/r", "main")
	if err != nil || !p.Configured || !p.Gated() || p.RequiredReviewers != 2 || !slices.Equal(p.RequiredChecks, []string{"build", "lint", "test"}) {
		t.Errorf("ReadProtection() = %+v, %v", p, err)
	}
	c = gh.New(runner.NewSnapshot([]runner.Call{protectionCall(`{"enforce_admins":{"enabled":true}}`, "", 0)}), false)
	if p, err := snapshot.ReadProtection(t.Context(), c, "o/r", "main"); err != nil || !p.Configured || p.Gated() {
		t.Errorf("protection with no checks or reviews = %+v, %v; want configured and not gated", p, err)
	}
}
