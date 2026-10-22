// Package state holds the typed entities of contract §4 that the loop keeps in state comments.
// These are the read model: oe decodes them strictly through the protocol codec, and the board
// classifies from them. The single writer and its transitions are not here.
package state

import (
	"strconv"

	"github.com/maro114510/skills/oe/internal/protocol"
)

// The entity names written in every state object's envelope.
const (
	EntityLease     = "lease"
	EntityLedger    = "ledger"
	EntityPostMerge = "post-merge"
	EntityIssue     = "issue"
)

// The state keys of the Epic-level entities.
const (
	KeyLease     = "lease"
	KeyLedger    = "ledger"
	KeyPostMerge = "post-merge"
)

// IssueKey is the state key of a child Issue.
func IssueKey(n int) string { return "issue:" + strconv.Itoa(n) }

// Lease is the Publisher's claim on an Epic, contract §4.1. A PID of 0 is a clean session end.
type Lease struct {
	protocol.Envelope

	Token     string `json:"token"`
	Host      string `json:"host"`
	PID       int    `json:"pid"`
	StartedAt string `json:"started_at"`
	RenewedAt string `json:"renewed_at"`
}

// Counter is one budget counter with its bound.
type Counter struct {
	Used  int `json:"used"`
	Bound int `json:"bound"`
}

// Counters are the three Epic-wide budgets.
type Counters struct {
	WorkerDispatches Counter `json:"worker_dispatches"`
	ReviewerPasses   Counter `json:"reviewer_passes"`
	FixCycles        Counter `json:"fix_cycles"`
}

// Freeze is the freeze recorded on the ledger. An epic-release does not remove it: the merge
// commit and status it names are what lets health read the same result as HANDLED afterwards,
// and a record that were cleared would freeze the Epic again on the very result it was released
// from. Released says the freeze no longer holds the Epic. It is required, never defaulted, so
// a freeze whose state is unknown is refused rather than read as active or released.
type Freeze struct {
	Seq      int    `json:"seq"`
	Reason   string `json:"reason"`
	MergeSHA string `json:"merge_sha"`
	Health   string `json:"health"`
	Released bool   `json:"released"`
}

// Ledger is the Epic-wide budget and freeze, contract §4.2.
type Ledger struct {
	protocol.Envelope

	N                int      `json:"n"`
	Counters         Counters `json:"counters"`
	Freeze           *Freeze  `json:"freeze"`
	FreezeSeq        int      `json:"freeze_seq"`
	ReleaseWatermark int64    `json:"release_watermark"`
}

// PostMerge phases, contract §4.3.
const (
	PhaseIntent               = "intent"
	PhaseMerged               = "merged"
	PhaseMergedUnverifiedBase = "merged-unverified-base"
	PhaseHeadMoved            = "head-moved"
	PhaseRejected             = "rejected"
	PhaseUnknown              = "unknown"
	PhaseNotMerged            = "not-merged"
)

// PostMerge is the record of the latest merge this loop requested, contract §4.3.
type PostMerge struct {
	protocol.Envelope

	PR           int    `json:"pr"`
	Issue        int    `json:"issue"`
	ReviewedSHA  string `json:"reviewed_sha"`
	VerifiedBase string `json:"verified_base"`
	Phase        string `json:"phase"`
	MergeSHA     string `json:"merge_sha"`
	RequestedAt  string `json:"requested_at"`
}

// Criterion is one acceptance criterion and the evidence for it.
type Criterion struct {
	Text     string `json:"text"`
	Result   string `json:"result"`
	Kind     string `json:"kind"`
	Evidence string `json:"evidence"`
}

// ReviewEvidence is what an approval rests on.
type ReviewEvidence struct {
	BehaviorChange bool        `json:"behavior_change"`
	Basis          string      `json:"basis"`
	Criteria       []Criterion `json:"criteria"`
}

// Present reports whether the evidence holds at least one criterion. Evidence with none is no
// evidence, and a pair without present evidence is no approval.
func (e ReviewEvidence) Present() bool { return len(e.Criteria) > 0 }

// Approval binds a verdict to one head, one base, and its evidence, as one value.
type Approval struct {
	ReviewedSHA    string         `json:"reviewed_sha"`
	VerifiedBase   string         `json:"verified_base"`
	ReviewEvidence ReviewEvidence `json:"review_evidence"`
}

// Decision is the latest applied human command.
type Decision struct {
	Command    string `json:"command"`
	CommentID  int64  `json:"comment_id"`
	RedoBranch string `json:"redo_branch"`
}

// Context is one retained human comment.
type Context struct {
	ID     int64  `json:"id"`
	Author string `json:"author"`
	Time   string `json:"time"`
	Digest string `json:"digest"`
	Kind   string `json:"kind"`
}

// Publish is the push-and-PR record. PR is 0 until a PR is linked.
type Publish struct {
	SHA     string `json:"sha"`
	PrevSHA string `json:"prev_sha"`
	Base    string `json:"base"`
	Branch  string `json:"branch"`
	PR      int    `json:"pr"`
	Phase   string `json:"phase"`
}

// Repair is the last repair handed to a worker.
type Repair struct {
	PR    int    `json:"pr"`
	Head  string `json:"head"`
	Since int64  `json:"since"`
}

// Issue is the state of one child Issue, contract §4.4.
type Issue struct {
	protocol.Envelope

	Branch              string    `json:"branch"`
	Cycle               int       `json:"cycle"`
	ConsecutiveFailures int       `json:"consecutive_failures"`
	HeadSHA             *string   `json:"head_sha"`
	Approval            *Approval `json:"approval"`
	PendingFindings     []string  `json:"pending_findings"`
	UnresolvedBlockers  []string  `json:"unresolved_blockers"`
	Decision            *Decision `json:"decision"`
	SignalWatermark     int64     `json:"signal_watermark"`
	Context             []Context `json:"context"`
	Publish             *Publish  `json:"publish"`
	Repair              *Repair   `json:"repair"`
	// StalePass is the lease-token digest of the session that ran the latest staleness pass, and is empty before the first.
	// A second staleness in that session defers the Issue.
	StalePass string `json:"stale_pass"`
}
