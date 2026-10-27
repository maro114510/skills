package snapshot

import (
	"context"

	"github.com/maro114510/skills/oe/internal/checks"
	"github.com/maro114510/skills/oe/internal/gh"
)

// Feedback is one comment or review written on a pull request.
// Trusted says its author is an owner, member, collaborator, or a bot, which is the only feedback a worker may be given.
type Feedback struct {
	ID      int64
	Author  string
	Trusted bool
	Body    string
}

// FeedbackThread is one unresolved review thread with every comment it holds.
type FeedbackThread struct {
	Path     string
	Line     int
	Comments []Feedback
}

// FailedCheck is a check on the head that did not pass, with the link a worker reads its log from.
type FailedCheck struct {
	Name string
	URL  string
}

// RepairRead is what a repair is built from: the head it was read at, the failed checks, the unresolved threads, and each reviewer's current request for changes.
type RepairRead struct {
	Number  int
	Head    string
	Failed  []FailedCheck
	Threads []FeedbackThread
	Reviews []Feedback
}

const repairQuery = `query($owner: String!, $repo: String!, $num: Int!) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $num) {
      number headRefOid
      reviewThreads(first: 100) { totalCount nodes { isResolved path line
        comments(first: 50) { totalCount nodes { databaseId authorAssociation author { __typename login } body } } } }
      latestOpinionatedReviews(first: 100) { totalCount nodes { databaseId state authorAssociation author { __typename login } body } }
      commits(last: 1) { nodes { commit { oid statusCheckRollup {
        contexts(first: 100) { totalCount nodes { __typename
          ... on CheckRun { name status conclusion startedAt checkSuite { databaseId } detailsUrl }
          ... on StatusContext { context state createdAt targetUrl } } } } } } }
    }
  }
}`

type feedbackAuthor struct {
	Typename string `json:"__typename"`
	Login    string `json:"login"`
}

type feedbackNode struct {
	DatabaseID        *int64          `json:"databaseId"`
	AuthorAssociation string          `json:"authorAssociation"`
	Author            *feedbackAuthor `json:"author"`
	Body              *string         `json:"body"`
}

type reviewNode struct {
	feedbackNode

	State *string `json:"state"`
}

type threadNode struct {
	IsResolved *bool               `json:"isResolved"`
	Path       string              `json:"path"`
	Line       *int                `json:"line"`
	Comments   *Conn[feedbackNode] `json:"comments"`
}

type repairData struct {
	Repository *struct {
		PullRequest *struct {
			Number                   int               `json:"number"`
			HeadRefOid               string            `json:"headRefOid"`
			ReviewThreads            *Conn[threadNode] `json:"reviewThreads"`
			LatestOpinionatedReviews *Conn[reviewNode] `json:"latestOpinionatedReviews"`
			Commits                  *Commits          `json:"commits"`
		} `json:"pullRequest"`
	} `json:"repository"`
}

// feedback turns a node into a Feedback, or fails when it cannot be ordered, since a window by comment ID needs every ID.
func (n feedbackNode) feedback() (Feedback, error) {
	if n.DatabaseID == nil || n.Body == nil {
		return Feedback{}, unreadable("a review comment has no ID or no body")
	}
	f := Feedback{ID: *n.DatabaseID, Author: "", Trusted: false, Body: *n.Body}
	bot := false
	if n.Author != nil {
		f.Author, bot = n.Author.Login, n.Author.Typename == "Bot"
	}
	switch n.AuthorAssociation {
	case "OWNER", "MEMBER", "COLLABORATOR":
		f.Trusted = true
	default:
		f.Trusted = bot
	}
	return f, nil
}

// ReadRepairInput reads a pull request's repair input in one query, complete or not at all.
func ReadRepairInput(ctx context.Context, c *gh.Client, repo string, num int) (RepairRead, error) {
	owner, name := splitRepo(repo)
	var data repairData
	vars := []gh.Var{gh.String("owner", owner), gh.String("repo", name), gh.Int("num", num)}
	if err := c.GraphQL(ctx, repairQuery, vars, &data); err != nil {
		return RepairRead{}, err
	}
	if data.Repository == nil || data.Repository.PullRequest == nil {
		return RepairRead{}, unreadable("pull request #%d was not found in %s", num, repo)
	}
	pr := data.Repository.PullRequest
	if pr.Number != num {
		return RepairRead{}, unreadable("the response is for pull request #%d, not #%d", pr.Number, num)
	}
	if pr.HeadRefOid == "" {
		return RepairRead{}, unreadable("pull request #%d has no head commit", num)
	}
	out := RepairRead{Number: num, Head: pr.HeadRefOid, Failed: nil, Threads: nil, Reviews: nil}
	var err error
	if out.Failed, err = failedChecks(pr.Commits, pr.HeadRefOid); err != nil {
		return RepairRead{}, err
	}
	if out.Threads, err = unresolvedThreads(pr.ReviewThreads); err != nil {
		return RepairRead{}, err
	}
	if out.Reviews, err = requestedChanges(pr.LatestOpinionatedReviews); err != nil {
		return RepairRead{}, err
	}
	return out, nil
}

// failedChecks lists the checks of the head commit that did not pass, and fails when the commit read is not the head.
func failedChecks(commits *Commits, head string) ([]FailedCheck, error) {
	if commits == nil || len(commits.Nodes) == 0 || commits.Nodes[0].Commit == nil {
		return nil, unreadable("the head commit was not read")
	}
	if commits.Nodes[0].Commit.OID != head {
		return nil, unreadable("the checks were read at %s, not the head %s", commits.Nodes[0].Commit.OID, head)
	}
	rollup := commits.Nodes[0].Commit.StatusCheckRollup
	if rollup == nil {
		return nil, nil
	}
	if p := Problem(rollup.Contexts, "checks"); p != "" {
		return nil, unreadable("%s", p)
	}
	var out []FailedCheck
	for _, ch := range checks.Latest(Items(rollup.Contexts)) {
		if ch.Class == checks.Failed || ch.Class == checks.Cancelled {
			out = append(out, FailedCheck{Name: ch.Name, URL: ch.URL})
		}
	}
	return out, nil
}

func unresolvedThreads(conn *Conn[threadNode]) ([]FeedbackThread, error) {
	if p := Problem(conn, "reviewThreads"); p != "" {
		return nil, unreadable("%s", p)
	}
	var out []FeedbackThread
	for _, t := range Items(conn) {
		if t.IsResolved == nil {
			return nil, unreadable("a review thread has no resolved state")
		}
		if *t.IsResolved {
			continue
		}
		th, err := t.thread()
		if err != nil {
			return nil, err
		}
		out = append(out, th)
	}
	return out, nil
}

// thread reads the comments of an unresolved thread, of which the query returns the first ones.
func (t threadNode) thread() (FeedbackThread, error) {
	if t.Comments == nil || t.Comments.TotalCount == nil || t.Comments.Nodes == nil {
		return FeedbackThread{}, unreadable("the comments of a review thread on %s were not read", t.Path)
	}
	if *t.Comments.TotalCount > len(*t.Comments.Nodes) {
		return FeedbackThread{}, unreadable("the thread on %s holds %d comments and only %d were read", t.Path, *t.Comments.TotalCount, len(*t.Comments.Nodes))
	}
	th := FeedbackThread{Path: t.Path, Line: 0, Comments: nil}
	if t.Line != nil {
		th.Line = *t.Line
	}
	for _, n := range *t.Comments.Nodes {
		f, err := n.feedback()
		if err != nil {
			return FeedbackThread{}, err
		}
		th.Comments = append(th.Comments, f)
	}
	return th, nil
}

func requestedChanges(conn *Conn[reviewNode]) ([]Feedback, error) {
	if p := Problem(conn, "latestOpinionatedReviews"); p != "" {
		return nil, unreadable("%s", p)
	}
	var out []Feedback
	for _, r := range Items(conn) {
		if r.State == nil {
			return nil, unreadable("a review has no state")
		}
		f, err := r.feedback()
		if err != nil {
			return nil, err
		}
		if *r.State == "CHANGES_REQUESTED" {
			out = append(out, f)
		}
	}
	return out, nil
}
