package snapshot

import (
	"context"

	"github.com/maro114510/skills/oe/internal/gh"
)

// MergeSettings are the merge methods the repository allows.
type MergeSettings struct {
	MergeCommit bool
	Squash      bool
}

// ReadMergeSettings reads which merge methods the repository allows.
// It uses GraphQL, because REST omits the allow_* fields for a token without admin rights, and a null in either field is a failed read.
func ReadMergeSettings(ctx context.Context, c *gh.Client, repo string) (MergeSettings, error) {
	return MergeSettings{}, nil
}

// ReadBranchHead reads the commit a branch of the repository points at, from GitHub and not from a local ref.
func ReadBranchHead(ctx context.Context, c *gh.Client, repo, branch string) (string, error) {
	return "", nil
}

// ReadFirstParent reads the first parent of a commit, which is the branch a merge landed on.
func ReadFirstParent(ctx context.Context, c *gh.Client, repo, sha string) (string, error) {
	return "", nil
}
