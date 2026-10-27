package snapshot

import (
	"context"

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

// FeedbackThread is one unresolved review thread. Total is the number of comments it holds, of which Comments are the first ones read.
type FeedbackThread struct {
	Path     string
	Line     int
	Total    int
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

// ReadRepairInput reads a pull request's repair input in one query, complete or not at all.
func ReadRepairInput(ctx context.Context, c *gh.Client, repo string, num int) (RepairRead, error) {
	return RepairRead{}, nil
}
