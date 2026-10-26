package coord

import "github.com/maro114510/skills/oe/internal/state"

// RecordPublishIntent records, before the push, the pair about to be published.
type RecordPublishIntent struct {
	// SHA and Base are the approval's reviewed_sha and verified_base.
	SHA  string
	Base string
	// PrevSHA is the remote head when the intent is recorded, empty when the branch is not there.
	PrevSHA string
}

// Name implements Transition.
func (RecordPublishIntent) Name() string { return "record_publish_intent" }

func (t RecordPublishIntent) apply(applyInput) (*state.Issue, error) {
	return nil, refused("%s is not implemented", t.Name())
}

// RecordPublished moves a publish forward after the push: to pushed, then to linked once the
// pull request is known.
type RecordPublished struct {
	// PR is the pull request number, or 0 to record only that the push landed.
	PR int
}

// Name implements Transition.
func (RecordPublished) Name() string { return "record_published" }

func (t RecordPublished) apply(applyInput) (*state.Issue, error) {
	return nil, refused("%s is not implemented", t.Name())
}
