package snapshot

import (
	"context"
	"encoding/json"
	"net/url"
	"strings"

	"github.com/maro114510/skills/oe/internal/gh"
)

// MergeSettings are the merge methods the repository allows.
type MergeSettings struct {
	MergeCommit bool
	Squash      bool
}

const mergeSettingsQuery = `query($owner: String!, $repo: String!) {
  repository(owner: $owner, name: $repo) { mergeCommitAllowed squashMergeAllowed }
}`

// ReadMergeSettings reads which merge methods the repository allows.
// It uses GraphQL, because REST omits the allow_* fields for a token without admin rights, and a null in either field is a failed read.
func ReadMergeSettings(ctx context.Context, c *gh.Client, repo string) (MergeSettings, error) {
	owner, name := splitRepo(repo)
	var data struct {
		Repository *struct {
			MergeCommitAllowed *bool `json:"mergeCommitAllowed"`
			SquashMergeAllowed *bool `json:"squashMergeAllowed"`
		} `json:"repository"`
	}
	if err := c.GraphQL(ctx, mergeSettingsQuery, []gh.Var{gh.String("owner", owner), gh.String("repo", name)}, &data); err != nil {
		return MergeSettings{}, err
	}
	r := data.Repository
	if r == nil || r.MergeCommitAllowed == nil || r.SquashMergeAllowed == nil {
		return MergeSettings{}, unreadable("the merge settings of %s were not read", repo)
	}
	return MergeSettings{MergeCommit: *r.MergeCommitAllowed, Squash: *r.SquashMergeAllowed}, nil
}

// ReadBranchHead reads the commit a branch of the repository points at, from GitHub and not from a local ref.
func ReadBranchHead(ctx context.Context, c *gh.Client, repo, branch string) (string, error) {
	out, err := c.Read(ctx, "api", "repos/"+repo+"/git/ref/heads/"+escapeRef(branch))
	if err != nil {
		return "", err
	}
	var ref struct {
		Object *struct {
			SHA string `json:"sha"`
		} `json:"object"`
	}
	if err := json.Unmarshal(out, &ref); err != nil || ref.Object == nil || ref.Object.SHA == "" {
		return "", unreadable("the head of %s was not read", branch)
	}
	return ref.Object.SHA, nil
}

// ReadFirstParent reads the first parent of a commit, which is the branch a merge landed on.
func ReadFirstParent(ctx context.Context, c *gh.Client, repo, sha string) (string, error) {
	out, err := c.Read(ctx, "api", "repos/"+repo+"/commits/"+sha)
	if err != nil {
		return "", err
	}
	var commit struct {
		Parents []struct {
			SHA string `json:"sha"`
		} `json:"parents"`
	}
	if err := json.Unmarshal(out, &commit); err != nil || len(commit.Parents) == 0 || commit.Parents[0].SHA == "" {
		return "", unreadable("the first parent of %s was not read", sha)
	}
	return commit.Parents[0].SHA, nil
}

// escapeRef escapes each segment of a ref name for use in an endpoint path, and keeps the slashes between them.
func escapeRef(ref string) string {
	parts := strings.Split(ref, "/")
	for i, p := range parts {
		parts[i] = url.PathEscape(p)
	}
	return strings.Join(parts, "/")
}
