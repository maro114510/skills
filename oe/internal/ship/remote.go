package ship

import (
	"github.com/maro114510/skills/oe/internal/coord"
	"github.com/maro114510/skills/oe/internal/state"
)

// Remote says how the remote branch relates to the recorded publish.
type Remote string

// The relations of the remote branch to the recorded publish.
const (
	// RemoteAbsent is a branch that is not on the remote where none is expected.
	RemoteAbsent Remote = "absent"
	// RemoteAtPublished is a branch at the SHA the publish records.
	RemoteAtPublished Remote = "at-published"
	// RemoteAtPrev is a branch still at the head the intent was recorded against.
	RemoteAtPrev Remote = "at-prev"
	// RemoteExternal is a branch the recorded publish does not explain.
	RemoteExternal Remote = "external"
)

// Expect classifies the remote head against the recorded publish, contract §8. An empty remote
// means no branch.
//   - With no record, only an absent branch is expected: any other is an external push.
//   - A publish in intent explains its sha, its prev_sha, and an absent branch when it recorded none.
//   - A pushed or linked publish explains only its sha, since the push it names landed.
func Expect(p *state.Publish, remote string) Remote {
	if p == nil {
		if remote == "" {
			return RemoteAbsent
		}
		return RemoteExternal
	}
	switch {
	case remote != "" && remote == p.SHA:
		return RemoteAtPublished
	case p.Phase != coord.PublishIntent:
		return RemoteExternal
	case remote == "" && p.PrevSHA == "":
		return RemoteAbsent
	case remote != "" && remote == p.PrevSHA:
		return RemoteAtPrev
	}
	return RemoteExternal
}
