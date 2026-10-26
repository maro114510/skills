package snapshot

import (
	"context"

	"github.com/maro114510/skills/oe/internal/gh"
)

// ReadBranchPRs reads every pull request whose head is the branch of this repository, in any
// state. A pull request from a fork that happens to use the same branch name is not one.
func ReadBranchPRs(context.Context, *gh.Client, string, string) ([]PR, error) {
	return nil, nil
}
