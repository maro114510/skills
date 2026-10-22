package snapshot

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/url"
	"slices"

	"github.com/maro114510/skills/oe/internal/exitcode"
	"github.com/maro114510/skills/oe/internal/gh"
)

// notProtected is GitHub's message for a branch that has no protection. Only a 404 carrying it
// means none; any other 404, such as a repository or branch that cannot be seen, is unreadable.
const notProtected = "Branch not protected"

// Protection is the branch protection of the default branch, as far as the Run Plan states it.
type Protection struct {
	// Configured is false only for a confirmed absence of protection.
	Configured        bool     `json:"configured"`
	RequiredChecks    []string `json:"required_checks"`
	RequiredReviewers int      `json:"required_reviewers"`
}

// Gated reports whether the repository itself gates a merge: a required check or a required
// approving review. Without either, the loop's own review and CHECKS_SET are the only gate.
func (p Protection) Gated() bool {
	return len(p.RequiredChecks) > 0 || p.RequiredReviewers > 0
}

type protectionWire struct {
	RequiredStatusChecks *struct {
		Contexts []string `json:"contexts"`
		Checks   []struct {
			Context string `json:"context"`
		} `json:"checks"`
	} `json:"required_status_checks"`
	RequiredPullRequestReviews *struct {
		RequiredApprovingReviewCount int `json:"required_approving_review_count"`
	} `json:"required_pull_request_reviews"`
}

// ReadProtection reads the protection of a branch. A confirmed "Branch not protected" 404 is
// no protection; every other failure, and a body that does not decode, is exit 1.
func ReadProtection(ctx context.Context, c *gh.Client, repo, branch string) (Protection, error) {
	none := Protection{Configured: false, RequiredChecks: []string{}, RequiredReviewers: 0}
	path := fmt.Sprintf("repos/%s/branches/%s/protection", repo, url.PathEscape(branch))
	out, found, err := c.ReadMissing(ctx, notProtected, "api", path)
	if err != nil {
		return none, err
	}
	if !found {
		return none, nil
	}
	var w protectionWire
	dec := json.NewDecoder(bytes.NewReader(out))
	if err := dec.Decode(&w); err != nil {
		return none, exitcode.Wrap(exitcode.Unreadable, err, "branch protection of "+branch+" did not decode")
	}
	p := Protection{Configured: true, RequiredChecks: []string{}, RequiredReviewers: 0}
	if rsc := w.RequiredStatusChecks; rsc != nil {
		p.RequiredChecks = append(p.RequiredChecks, rsc.Contexts...)
		for _, ch := range rsc.Checks {
			p.RequiredChecks = append(p.RequiredChecks, ch.Context)
		}
		slices.Sort(p.RequiredChecks)
		p.RequiredChecks = slices.Compact(p.RequiredChecks)
	}
	if rv := w.RequiredPullRequestReviews; rv != nil {
		p.RequiredReviewers = rv.RequiredApprovingReviewCount
	}
	return p, nil
}
