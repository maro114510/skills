package coord

import (
	"context"

	"github.com/maro114510/skills/oe/internal/state"
)

// MergeIntent names the merge the loop is about to request, contract §4.3.
type MergeIntent struct {
	PR           int
	Issue        int
	ReviewedSHA  string
	VerifiedBase string
}

// MergeOutcome is how a requested merge ended, or what reconciling it from the pull request found.
type MergeOutcome struct {
	PR          int
	ReviewedSHA string
	// Phase is one of the result phases of contract §4.3, never intent.
	Phase string
	// MergeSHA is the merge commit, and only a merged phase carries one.
	MergeSHA string
}

// LoadPostMerge reads the post-merge record, or nil when the loop recorded no merge.
func (s *Session) LoadPostMerge(ctx context.Context) (*state.PostMerge, error) {
	return nil, nil
}

// RecordMergeIntent writes the record before the merge request, so a session that dies right after the merge still finds it.
func (s *Session) RecordMergeIntent(ctx context.Context, in MergeIntent) (state.PostMerge, error) {
	return state.PostMerge{}, nil
}

// RecordMergeResult records how the merge ended, resolving an intent or an unknown outcome.
func (s *Session) RecordMergeResult(ctx context.Context, out MergeOutcome) (state.PostMerge, error) {
	return state.PostMerge{}, nil
}
