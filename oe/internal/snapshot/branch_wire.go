package snapshot

import (
	"context"

	"github.com/maro114510/skills/oe/internal/gh"
)

const branchPullsQuery = `query($owner: String!, $name: String!, $branch: String!, $after: String) {
  repository(owner: $owner, name: $name) {
    pullRequests(headRefName: $branch, states: [OPEN, CLOSED, MERGED], first: 100, after: $after) {
      pageInfo { hasNextPage endCursor }
      nodes { number state mergedAt createdAt headRefName headRefOid isCrossRepository }
    }
  }
}`

// ReadBranchPRs reads every pull request whose head is the branch of this repository, in any
// state. A pull request from a fork that happens to use the same branch name is not one.
// The listing is complete or it is an error, so a caller never opens a second pull request on a
// page it could not read.
func ReadBranchPRs(ctx context.Context, c *gh.Client, repo, branch string) ([]PR, error) {
	out := []PR{}
	err := eachPage("the pull requests of "+branch, func(after string) (PageInfo, bool, error) {
		var data pullsData
		if err := c.GraphQL(ctx, branchPullsQuery, pageVars(repo, after, gh.String("branch", branch)), &data); err != nil {
			return PageInfo{}, false, err
		}
		if data.Repository == nil || data.Repository.PullRequests == nil {
			return PageInfo{}, false, unreadable("the pull requests of %s were not read", branch)
		}
		list := data.Repository.PullRequests
		for _, n := range list.Nodes {
			if n.IsCrossRepository == nil {
				return PageInfo{}, false, unreadable("PR #%d has no cross-repository marker", n.Number)
			}
			if *n.IsCrossRepository {
				continue
			}
			state := n.State
			if n.MergedAt != nil {
				state = StateMerged
			}
			out = append(out, PR{Number: n.Number, State: state, Branch: n.HeadRefName, HeadSHA: n.HeadRefOid, CreatedAt: n.CreatedAt})
		}
		return list.PageInfo, false, nil
	})
	return out, err
}
