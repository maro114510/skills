package snapshot

import (
	"context"
	"fmt"
	"strings"

	"github.com/maro114510/skills/oe/internal/checks"
	"github.com/maro114510/skills/oe/internal/exitcode"
	"github.com/maro114510/skills/oe/internal/gh"
)

// Reviewer is who a review was requested from.
type Reviewer struct {
	Typename string  `json:"__typename"`
	Login    *string `json:"login"`
	Slug     *string `json:"slug"`
}

// ReviewRequest is one outstanding review request.
type ReviewRequest struct {
	RequestedReviewer *Reviewer `json:"requestedReviewer"`
}

// Author is the author of a review.
type Author struct {
	Login *string `json:"login"`
}

// Review is the latest opinionated review by one reviewer.
type Review struct {
	State  *string `json:"state"`
	Author *Author `json:"author"`
}

// Thread is one review thread.
type Thread struct {
	IsResolved *bool `json:"isResolved"`
}

// Rollup is the status check rollup of a commit.
type Rollup struct {
	State    *string               `json:"state"`
	Contexts *Conn[checks.Context] `json:"contexts"`
}

// Commit is a commit and its checks.
type Commit struct {
	OID               string  `json:"oid"`
	StatusCheckRollup *Rollup `json:"statusCheckRollup"`
}

// CommitNode wraps a commit in the commits connection.
type CommitNode struct {
	Commit *Commit `json:"commit"`
}

// Commits is the last commit of a pull request.
type Commits struct {
	Nodes []CommitNode `json:"nodes"`
}

// PullRequest is everything merge readiness is classified from, read in one query. A field
// the response omitted is nil, which the classifier reads as unreadable, never as a default.
type PullRequest struct {
	Number                   int                  `json:"number"`
	State                    *string              `json:"state"`
	IsDraft                  *bool                `json:"isDraft"`
	Mergeable                *string              `json:"mergeable"`
	MergeStateStatus         *string              `json:"mergeStateStatus"`
	ReviewDecision           *string              `json:"reviewDecision"`
	IsMergeQueueEnabled      *bool                `json:"isMergeQueueEnabled"`
	HeadRefOid               string               `json:"headRefOid"`
	ReviewRequests           *Conn[ReviewRequest] `json:"reviewRequests"`
	LatestOpinionatedReviews *Conn[Review]        `json:"latestOpinionatedReviews"`
	ReviewThreads            *Conn[Thread]        `json:"reviewThreads"`
	Commits                  *Commits             `json:"commits"`
}

// MergeCommit is the commit a merged pull request created.
type MergeCommit struct {
	OID               *string `json:"oid"`
	StatusCheckRollup *Rollup `json:"statusCheckRollup"`
}

// MergePull is a pull request read for the default-branch health check.
type MergePull struct {
	Number      int          `json:"number"`
	State       *string      `json:"state"`
	MergedAt    *string      `json:"mergedAt"`
	MergeCommit *MergeCommit `json:"mergeCommit"`
}

// readinessQuery reads the state, draft flag, conflicts, checks, reviews, review requests,
// review threads, and merge state of one pull request. Every connection carries totalCount
// so a cut-off connection is detected.
const readinessQuery = `query($owner: String!, $repo: String!, $num: Int!) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $num) {
      number state isDraft mergeable mergeStateStatus reviewDecision isMergeQueueEnabled headRefOid
      reviewRequests(first: 100) { totalCount nodes { requestedReviewer { __typename
        ... on User { login } ... on Team { slug } ... on Bot { login } ... on Mannequin { login } } } }
      latestOpinionatedReviews(first: 100) { totalCount nodes { state author { login } } }
      reviewThreads(first: 100) { totalCount nodes { isResolved } }
      commits(last: 1) { nodes { commit { oid statusCheckRollup { state
        contexts(first: 100) { totalCount nodes { __typename
          ... on CheckRun { name status conclusion startedAt checkSuite { databaseId } }
          ... on StatusContext { context state createdAt } } } } } } }
    }
  }
}`

// mergeQuery reads a merged pull request and the checks on its merge commit.
const mergeQuery = `query($owner: String!, $repo: String!, $num: Int!) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $num) {
      number state mergedAt
      mergeCommit { oid statusCheckRollup { state
        contexts(first: 100) { totalCount nodes { __typename
          ... on CheckRun { name status conclusion startedAt checkSuite { databaseId } }
          ... on StatusContext { context state createdAt } } } } }
    }
  }
}`

type pullData[T any] struct {
	Repository *struct {
		PullRequest *T `json:"pullRequest"`
	} `json:"repository"`
}

// splitRepo splits owner/name, which inputs.Resolve already validated.
func splitRepo(repo string) (owner, name string) {
	owner, name, _ = strings.Cut(repo, "/")
	return owner, name
}

func readPull[T any](ctx context.Context, c *gh.Client, query, repo string, num int) (*T, error) {
	owner, name := splitRepo(repo)
	var data pullData[T]
	vars := []gh.Var{gh.String("owner", owner), gh.String("repo", name), gh.Int("num", num)}
	if err := c.GraphQL(ctx, query, vars, &data); err != nil {
		return nil, err
	}
	if data.Repository == nil || data.Repository.PullRequest == nil {
		return nil, exitcode.New(exitcode.Unreadable, fmt.Sprintf("pull request #%d was not found in %s", num, repo))
	}
	return data.Repository.PullRequest, nil
}

// ReadPullRequest reads the signals merge readiness is classified from.
func ReadPullRequest(ctx context.Context, c *gh.Client, repo string, num int) (*PullRequest, error) {
	return readPull[PullRequest](ctx, c, readinessQuery, repo, num)
}

// ReadMergePull reads a pull request and the checks on its merge commit.
func ReadMergePull(ctx context.Context, c *gh.Client, repo string, num int) (*MergePull, error) {
	return readPull[MergePull](ctx, c, mergeQuery, repo, num)
}
