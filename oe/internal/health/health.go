// Package health classifies the default-branch health after this loop's latest merge, so no
// further PR merges onto a default branch whose checks have not passed. The merge it judges is
// the one the post-merge record names; the record is written before every merge request, so a
// restart between the merge and its checks still finds it. It is the Go form of the earlier
// base-health.sh and keeps its statuses and next actions. It reads only: it never posts.
package health

import (
	"fmt"
	"slices"
	"strings"
	"time"

	"github.com/maro114510/skills/oe/internal/checks"
	"github.com/maro114510/skills/oe/internal/snapshot"
	"github.com/maro114510/skills/oe/internal/state"
)

// The timings, in seconds since the merge. PassSettle lets a slower workflow create its checks
// before an early, all-passing set counts as healthy. PendingLimit turns a check that never
// finishes, such as a job waiting for environment approval, into a freeze instead of an
// endless, silent wait. NoChecksGrace is how long a merge may report no checks at all.
const (
	PassSettle    = 120
	NoChecksGrace = 600
	PendingLimit  = 3600
)

// Status is the health of the default branch after the latest recorded merge.
type Status string

// The statuses.
const (
	// Clear is no record, or a recorded PR that did not merge.
	Clear Status = "CLEAR"
	// Pass is every check on the merge commit passed.
	Pass Status = "PASS"
	// Pending is a pending check, no check reported yet, or a pass that has not settled.
	Pending Status = "PENDING"
	// Fail is a check on the merge commit that did not pass.
	Fail Status = "FAIL"
	// Unconfirmed is a cancelled check, no check reported in time, or one still pending too long.
	Unconfirmed Status = "UNCONFIRMED"
	// Handled is a Fail or Unconfirmed that a freeze already names, so the freeze and its
	// release own it.
	Handled Status = "HANDLED"
	// Unreadable is a signal that could not be read.
	Unreadable Status = "UNREADABLE"
)

// Next is what the result calls for.
type Next string

// The next actions. Merge only on proceed; every other result holds every merge.
const (
	NextProceed Next = "proceed"
	NextWait    Next = "wait"
	NextFreeze  Next = "freeze"
	NextHold    Next = "hold"
)

const (
	stateOpen   = "OPEN"
	stateClosed = "CLOSED"
	stateMerged = "MERGED"
)

// Record is the post-merge record of the latest merge this loop requested.
type Record struct {
	// ID is the record's comment ID.
	ID    int64
	PR    int
	Issue int
}

// Input is everything the classification reads.
type Input struct {
	// Record is nil when the loop recorded no merge.
	Record *Record
	// Freezes are the freezes the loop recorded. A released freeze must stay among them, or a
	// released Epic would freeze again on the result it was released from.
	Freezes []state.Freeze
	// Pull is the recorded PR with the checks on its merge commit, or nil when it was not read.
	Pull *snapshot.MergePull
	// Now is the time the checks are judged at.
	Now time.Time
}

// Result is the health of the default branch.
type Result struct {
	Status   Status `json:"status"`
	Reason   string `json:"reason"`
	RecordID int64  `json:"record_id"`
	PR       int    `json:"pr,omitempty"`
	Issue    int    `json:"issue,omitempty"`
	Merge    string `json:"merge,omitempty"`
	Next     Next   `json:"next"`
}

// FromBoard builds the input from a board read and classifies it.
func FromBoard(b *snapshot.Board) Result {
	in := Input{Record: nil, Freezes: nil, Pull: b.PostMergePull, Now: b.Now}
	if b.PostMerge != nil {
		in.Record = &Record{ID: b.PostMerge.CommentID, PR: b.PostMerge.State.PR, Issue: b.PostMerge.State.Issue}
	}
	if b.Ledger != nil && b.Ledger.Freeze != nil {
		in.Freezes = []state.Freeze{*b.Ledger.Freeze}
	}
	return Classify(in)
}

// Classify judges the checks on the recorded merge. A failure is never retried into a pass by
// waiting, and an unreadable signal is never a pass. ACTION_REQUIRED, a human hold on a PR, is a
// failure here: a merge that already landed cannot wait for one. A cancelled run, usually one
// superseded by a later push, leaves health unconfirmed rather than failed.
func Classify(in Input) Result {
	if in.Record == nil {
		return finish(Result{Status: Clear, Reason: "no loop merge recorded", RecordID: 0, PR: 0, Issue: 0, Merge: "", Next: ""})
	}
	base := Result{Status: "", Reason: "", RecordID: in.Record.ID, PR: in.Record.PR, Issue: in.Record.Issue, Merge: "", Next: ""}
	return finish(classifyRecorded(in, base))
}

func with(base Result, status Status, reason string) Result {
	base.Status = status
	base.Reason = reason
	return base
}

func classifyRecorded(in Input, base Result) Result {
	rec, pull := in.Record, in.Pull
	switch {
	case rec.PR <= 0 || rec.Issue <= 0:
		return with(base, Unreadable, fmt.Sprintf("post-merge record %d has no readable pr or issue", rec.ID))
	case pull == nil:
		return with(base, Unreadable, fmt.Sprintf("no pull request read for PR #%d", rec.PR))
	case pull.Number != rec.PR:
		return with(base, Unreadable, fmt.Sprintf("response is for PR #%d, not #%d", pull.Number, rec.PR))
	}
	if r, done := notMerged(base, pull, rec.PR); done {
		return r
	}
	merge := *pull.MergeCommit.OID
	base.Merge = merge
	rollup := pull.MergeCommit.StatusCheckRollup
	var latest []checks.Check
	if rollup != nil {
		if p := rollupProblem(rollup, merge); p != "" {
			return with(base, Unreadable, p)
		}
		latest = checks.Latest(snapshot.Items(rollup.Contexts))
	}
	age, ageOK := mergedAge(in.Now, pull.MergedAt)
	return judge(in, base, merge, latest, age, ageOK)
}

// notMerged answers for a recorded PR that is open, closed, unknown, or merged without a merge
// commit. It reports done when it did.
func notMerged(base Result, pull *snapshot.MergePull, number int) (Result, bool) {
	switch st := deref(pull.State); {
	case st == stateOpen || st == stateClosed:
		return with(base, Clear, fmt.Sprintf("PR #%d not merged (%s); nothing landed", number, st)), true
	case st != stateMerged:
		return with(base, Unreadable, "PR state "+orMissing(pull.State)), true
	case pull.MergeCommit == nil || pull.MergeCommit.OID == nil:
		return with(base, Unreadable, fmt.Sprintf("merged PR #%d has no merge commit", number)), true
	default:
		return base, false
	}
}

// rollupProblem names why the checks on a merge commit are not a full read.
func rollupProblem(rollup *snapshot.Rollup, merge string) string {
	c := rollup.Contexts
	switch {
	case c == nil || c.TotalCount == nil || c.Nodes == nil:
		return "checks missing on " + merge
	case *c.TotalCount > len(*c.Nodes):
		return fmt.Sprintf("checks truncated on %s (%d > %d)", merge, *c.TotalCount, len(*c.Nodes))
	default:
		return ""
	}
}

// mergedAge is the seconds since the merge, or false when either time cannot be read.
func mergedAge(now time.Time, mergedAt *string) (int, bool) {
	if mergedAt == nil || now.IsZero() {
		return 0, false
	}
	t, err := time.Parse(time.RFC3339, *mergedAt)
	if err != nil {
		return 0, false
	}
	return int(now.Sub(t).Seconds()), true
}

// tally sorts the latest checks by what they say, each as the reason to give for it.
type tally struct {
	bad, failed, pending, canceled []string
}

func tallyChecks(latest []checks.Check) tally {
	var t tally
	for _, c := range latest {
		switch c.Class {
		case checks.Unreadable:
			t.bad = append(t.bad, "check state missing: "+c.Name)
		case checks.Failed, checks.Action:
			t.failed = append(t.failed, "check failed: "+c.Name)
		case checks.Pending:
			t.pending = append(t.pending, "check pending: "+c.Name)
		case checks.Cancelled:
			t.canceled = append(t.canceled, "check cancelled, possibly superseded by a later push: "+c.Name)
		case checks.Pass:
		}
	}
	return t
}

func judge(in Input, base Result, merge string, latest []checks.Check, age int, ageOK bool) Result {
	t := tallyChecks(latest)
	switch {
	case len(t.bad) > 0:
		return with(base, Unreadable, strings.Join(t.bad, "; "))
	case len(t.failed) > 0:
		return handled(in, with(base, Fail, strings.Join(t.failed, "; ")), merge)
	case !ageOK:
		return with(base, Unreadable, "merge time or current time unreadable")
	}
	return judgeByAge(in, base, merge, t, len(latest), age)
}

// judgeByAge decides what the time since the merge makes of checks that did not fail.
func judgeByAge(in Input, base Result, merge string, t tally, reported, age int) Result {
	switch {
	case len(t.pending) > 0 && age >= PendingLimit:
		return handled(in, with(base, Unconfirmed, fmt.Sprintf("still pending %ds after merge, such as a job awaiting approval: %s",
			age, strings.Join(t.pending, "; "))), merge)
	case len(t.pending) > 0:
		return with(base, Pending, strings.Join(t.pending, "; "))
	case len(t.canceled) > 0:
		return handled(in, with(base, Unconfirmed, strings.Join(t.canceled, "; ")), merge)
	case reported > 0 && age < PassSettle:
		return with(base, Pending, fmt.Sprintf("checks on %s passed so far; settling until every workflow has reported (%ds since merge)", merge, age))
	case reported > 0:
		return with(base, Pass, "every check on "+merge+" passed")
	case age < NoChecksGrace:
		return with(base, Pending, fmt.Sprintf("no checks reported on %s yet (%ds since merge)", merge, age))
	default:
		return handled(in, with(base, Unconfirmed, fmt.Sprintf("no checks reported on %s %ds after merge; health cannot be confirmed", merge, age)), merge)
	}
}

// handled turns a Fail or Unconfirmed into Handled when a freeze already names this merge
// commit and this very status. A freeze for another commit or another status handles nothing.
func handled(in Input, r Result, merge string) Result {
	var named []state.Freeze
	for _, f := range in.Freezes {
		if f.MergeSHA == merge && f.Health == string(r.Status) {
			named = append(named, f)
		}
	}
	if len(named) == 0 {
		return r
	}
	first := slices.MinFunc(named, func(a, b state.Freeze) int { return a.Seq - b.Seq })
	r.Reason = fmt.Sprintf("%s on %s already frozen by freeze %d: %s", r.Status, merge, first.Seq, r.Reason)
	r.Status = Handled
	return r
}

func finish(r Result) Result {
	switch r.Status {
	case Clear, Pass, Handled:
		r.Next = NextProceed
	case Pending:
		r.Next = NextWait
	case Fail, Unconfirmed:
		r.Next = NextFreeze
	case Unreadable:
		r.Next = NextHold
	default:
		r.Next = NextHold
	}
	return r
}

func deref(s *string) string {
	if s == nil {
		return ""
	}
	return *s
}

func orMissing(s *string) string {
	if s == nil {
		return "missing"
	}
	return *s
}
