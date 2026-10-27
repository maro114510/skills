package coord

import (
	"context"
	"fmt"
	"slices"
	"strconv"
	"strings"

	"github.com/maro114510/skills/oe/internal/exitcode"
	"github.com/maro114510/skills/oe/internal/handoff"
	"github.com/maro114510/skills/oe/internal/review"
	"github.com/maro114510/skills/oe/internal/scan"
	"github.com/maro114510/skills/oe/internal/state"
)

// The routes a review pass takes and what follows it.
const (
	RoutePinned    = "PINNED"
	RouteBound     = "BOUND"
	RouteFix       = "FIX"
	RouteParked    = "PARKED"
	RouteStale     = "STALE"
	RouteMalformed = "MALFORMED"

	NextShip     = "ship"
	NextReverify = "reverify"
	NextDefer    = "defer"
)

// ReviewResult is what a review pass did and what the loop does next.
type ReviewResult struct {
	Issue    int          `json:"issue"`
	Route    string       `json:"route"`
	Reason   string       `json:"reason"`
	Next     string       `json:"next"`
	Head     string       `json:"head"`
	Base     string       `json:"base"`
	Findings []string     `json:"findings"`
	Notes    []NoteResult `json:"notes"`
	State    state.Issue  `json:"state"`
}

// NewReviewResult is an empty result for the Issue.
func NewReviewResult(n int) ReviewResult {
	var st state.Issue
	return ReviewResult{Issue: n, Route: "", Reason: "", Next: "", Head: "", Base: "", Findings: []string{}, Notes: []NoteResult{}, State: st}
}

func (s *Session) postReview(ctx context.Context, n int, key, text string, res *ReviewResult) error {
	nr, err := s.PostNote(ctx, n, key, text)
	if err != nil {
		return err
	}
	res.Notes = append(res.Notes, nr)
	return nil
}

// withheld stands in for findings that may hold a secret.
const withheld = "withheld because the findings may hold a suspected secret"

// MarkStale records a staleness pass.
//   - It clears the approval, since a renewed verdict never inherits the old one.
//   - It records the session, so a second staleness in that session defers the Issue to the next invocation.
type MarkStale struct {
	// Session is the digest of the lease token of the session running the pass.
	Session string
}

// Name implements Transition.
func (MarkStale) Name() string { return "mark_stale" }

func (t MarkStale) apply(in applyInput) (*state.Issue, error) {
	if err := needState(in, t.Name()); err != nil {
		return nil, err
	}
	if t.Session == "" {
		return nil, refused("mark_stale needs the session running the pass")
	}
	st := cloneIssue(in.cur)
	st.Approval, st.StalePass = nil, t.Session
	return st, nil
}

// Stale runs a staleness pass for the Issue on the pair of head and base.
//   - An Issue with published work gets one stale note per pair.
//   - The first staleness in a session goes on to an uncharged re-verification.
//   - A second one in the same session defers the Issue to the next invocation, and it stays in progress.
func (s *Session) Stale(ctx context.Context, n int, head, base, reason string, res *ReviewResult) error {
	noteReason := reason
	// The reason quotes the report, so a suspected secret in it is withheld from the printed result and the note alike.
	if report := scan.Text("stale-reason", []byte(reason)); !report.Clean {
		reason = "the report describes another review; its fields hold a suspected secret and are withheld"
		noteReason = "報告の内容は秘密情報を含むおそれがあるため掲載しません。"
	}
	res.Route, res.Reason, res.Head, res.Base = RouteStale, reason, head, base
	st, err := s.DispatchState(ctx, n)
	if err != nil {
		return err
	}
	if st.Publish != nil {
		key := fmt.Sprintf("stale:%d:%s:%s", n, head, base)
		if err := s.postReview(ctx, n, key, review.StaleNote(head, base, noteReason), res); err != nil {
			return err
		}
	}
	session := Digest(s.token)
	res.Next = NextReverify
	if st.StalePass == session {
		res.Next = NextDefer
		res.Reason += "; this session already ran a staleness pass for #" + strconv.Itoa(n) + ", so the next invocation verifies it afresh"
	}
	next, err := s.Update(ctx, n, MarkStale{Session: session})
	res.State = next
	return err
}

// RouteFindings sends findings down the fix-cycle path.
//   - Findings holding a suspected secret are never written and park the Issue as ship-class secret.
//   - A ship-class kind parks the Issue at once and never enters a fix cycle.
//   - At the cap the findings park the Issue.
//   - Otherwise a fix cycle is reserved on the ledger first, so a frozen or exhausted Epic starts none, and begin_fix hands the findings to a fresh worker.
func (s *Session) RouteFindings(ctx context.Context, n int, findings []string, kinds []handoff.ShipClass, head string, res *ReviewResult) error {
	return s.routeFindings(ctx, n, findings, kinds, head, nil, res)
}

// RouteRepair hands a pull request's repair findings down the same fix-cycle path as a review's, and records the repair it is.
// A repair has no bounds of its own: it counts against the Issue's cap and the Epic's budget, and a secret in its input parks the Issue.
func (s *Session) RouteRepair(ctx context.Context, n int, findings []string, repair state.Repair, res *ReviewResult) error {
	return s.routeFindings(ctx, n, findings, nil, repair.Head, &repair, res)
}

func (s *Session) routeFindings(ctx context.Context, n int, findings []string, kinds []handoff.ShipClass, head string, repair *state.Repair, res *ReviewResult) error {
	if len(findings) == 0 && len(kinds) == 0 {
		return exitcode.New(exitcode.Refused, "no finding to route")
	}
	text := strings.Join(findings, "\n")
	// The printed result is withheld like the note and the state, since a caller may log it.
	if report := scan.Text("review-findings", []byte(text)); !report.Clean || slices.Contains(kinds, handoff.ShipSecret) {
		res.Findings = []string{withheld}
		if !report.Clean {
			return s.parkReviewSecret(ctx, n, "the review findings", head, res)
		}
	} else {
		res.Findings = slices.Clone(findings)
	}
	if len(kinds) > 0 {
		return s.parkShipClass(ctx, n, kinds, text, head, res)
	}
	st, err := s.DispatchState(ctx, n)
	if err != nil {
		return err
	}
	return s.fixOrPark(ctx, n, st, findings, head, repair, res)
}

// fixOrPark hands findings to a fix cycle or parks the Issue at the cap.
// A replay of the fix cycle already in flight is charged nothing.
func (s *Session) fixOrPark(ctx context.Context, n int, st state.Issue, findings []string, head string, repair *state.Repair, res *ReviewResult) error {
	if head != "" && deref(st.HeadSHA) == head && slices.Equal(st.PendingFindings, findings) {
		// No worker has reported since begin_fix, so this is a replay such as a resumed session, and nothing is charged.
		res.Route, res.Next, res.State = RouteFix, NextRedispatch, st
		res.Reason = "the fix cycle in flight already carries these findings"
		return nil
	}
	if st.Cycle >= MaxCycle {
		key := fmt.Sprintf("parked:%d:cap:%s", n, DigestPlaceholder)
		if err := s.postReview(ctx, n, key, handoff.ParkedNote(n, review.CapNote(MaxCycle, findings)), res); err != nil {
			return err
		}
		next, err := s.Update(ctx, n, Park{Blockers: findings, Head: ""})
		res.Route, res.Next, res.State = RouteParked, NextParked, next
		return err
	}
	grant, _, err := s.Reserve(ctx, Request{WorkerDispatches: 0, ReviewerPasses: 0, FixCycles: 1})
	if err != nil {
		return err
	}
	next, err := s.Update(ctx, n, BeginFix{Findings: findings, Grant: grant, Repair: repair})
	res.Route, res.Next, res.State = RouteFix, NextRedispatch, next
	return err
}

func (s *Session) parkShipClass(ctx context.Context, n int, kinds []handoff.ShipClass, text, head string, res *ReviewResult) error {
	if slices.Contains(kinds, handoff.ShipSecret) {
		text = ""
	}
	blockers := make([]string, 0, len(kinds))
	for _, kind := range kinds {
		key := fmt.Sprintf("ship-class:%d:%s:%s", n, kind, DigestPlaceholder)
		err := s.postReview(ctx, n, key, handoff.ShipClassNote(n, kind, text), res)
		if isScan(err) {
			return s.parkReviewSecret(ctx, n, "the review findings", head, res)
		}
		if err != nil {
			return err
		}
		blockers = append(blockers, fmt.Sprintf("ship-class %s: %s", kind, res.Notes[len(res.Notes)-1].Key))
	}
	next, err := s.Update(ctx, n, Park{Blockers: blockers, Head: head})
	res.Route, res.Next, res.State = RouteParked, NextParked, next
	return err
}

// parkReviewSecret parks the Issue on a suspected secret in the reviewer's text and posts a note that withholds it.
func (s *Session) parkReviewSecret(ctx context.Context, n int, what, head string, res *ReviewResult) error {
	key := fmt.Sprintf("ship-class:%d:%s:%s", n, handoff.ShipSecret, DigestPlaceholder)
	if err := s.postReview(ctx, n, key, handoff.ShipClassNote(n, handoff.ShipSecret, ""), res); err != nil {
		return err
	}
	next, err := s.Update(ctx, n, Park{Blockers: []string{"ship-class secret: " + what + " holds a suspected secret"}, Head: head})
	res.Route, res.Next, res.State = RouteParked, NextParked, next
	return err
}

// Verdict is one reviewer report and what oe read around it.
type Verdict struct {
	Report review.Report
	// Repo is the repository the run resolved.
	Repo string
	// Head and Base are the worktree HEAD and the default branch as read now.
	// Integrated says whether Base is an ancestor of Head.
	Head       string
	Base       string
	Integrated bool
	// ChecksRevision is the revision of the given CHECKS_SET, and Runnable counts its runnable entries.
	ChecksRevision string
	Runnable       int
	// Dirty are the paths changed in the worktree or index after the review and its checks.
	Dirty []string
	// ShipClass are the kinds the Publisher judged the findings to be, and any one parks the Issue.
	ShipClass []handoff.ShipClass
}

// Verdict applies a reviewer report to the Issue.
//   - A report for another dispatch or pair, or a pair that moved since the pin, runs a staleness pass.
//   - A dirty worktree, failed evidence, a red or missing check, and every finding including a nit go down the fix-cycle path.
//   - A ship-class judgment parks the Issue.
//   - Only a clean APPROVE with valid and scanned evidence binds, and only while the pins are unchanged.
func (s *Session) Verdict(ctx context.Context, n int, v Verdict) (ReviewResult, error) {
	res := NewReviewResult(n)
	res.Head, res.Base = v.Head, v.Base
	st, err := s.DispatchState(ctx, n)
	if err != nil {
		return res, err
	}
	if st.HeadSHA == nil || *st.HeadSHA != v.Head {
		return res, refused("the worktree's HEAD %s is not the recorded head %s; a person must decide which is right", v.Head, headKey(deref(st.HeadSHA)))
	}
	if why := staleReason(n, st.Branch, v); why != "" {
		return res, s.Stale(ctx, n, v.Head, v.Base, why, &res)
	}
	ev := review.Evaluate(v.Report)
	findings := findingsOf(v, ev)
	if len(findings) == 0 && len(v.ShipClass) > 0 {
		return res, exitcode.New(exitcode.Usage, "--ship-class classifies a finding, and this report has none")
	}
	if len(findings) > 0 {
		return res, s.RouteFindings(ctx, n, findings, v.ShipClass, v.Head, &res)
	}
	if len(st.PendingFindings) > 0 {
		// The fix worker has not reported yet, so this clean report predates the fix or duplicates an earlier review.
		return res, refused("#%d has a fix cycle in flight; nothing binds until its worker reports", n)
	}
	return res, s.bind(ctx, n, v, ev.Bound, &res)
}

func (s *Session) bind(ctx context.Context, n int, v Verdict, ev state.ReviewEvidence, res *ReviewResult) error {
	if report := scan.Text("review-evidence", []byte(evidenceText(ev))); !report.Clean {
		return s.parkReviewSecret(ctx, n, "the review evidence", v.Head, res)
	}
	a := state.Approval{ReviewedSHA: v.Head, VerifiedBase: v.Base, ReviewEvidence: ev}
	next, err := s.Update(ctx, n, BindApproval{Approval: a, Head: v.Head, Base: v.Base, Findings: nil})
	res.Route, res.Next, res.State = RouteBound, NextShip, next
	return err
}

func evidenceText(ev state.ReviewEvidence) string {
	var b strings.Builder
	b.WriteString(ev.Basis + "\n")
	for _, c := range ev.Criteria {
		b.WriteString(c.Text + "\n" + c.Evidence + "\n")
	}
	return b.String()
}

// staleReason says why a report does not describe the pinned pair, and is empty when it does.
func staleReason(n int, branch string, v Verdict) string {
	r := v.Report
	switch {
	case !strings.EqualFold(r.Repo, v.Repo) || r.Issue != n || r.Branch != branch:
		return fmt.Sprintf("the report names %s #%d on %q, not %s #%d on %q; it describes another review", r.Repo, r.Issue, r.Branch, v.Repo, n, branch)
	case !sameSHA(r.ReviewedHead, v.Head):
		return fmt.Sprintf("REVIEWED_HEAD %q is not the pinned head %s; the report describes another commit", r.ReviewedHead, v.Head)
	case v.ChecksRevision != v.Base:
		return "CHECKS_SET was derived at " + v.ChecksRevision + ", not the current default branch " + v.Base
	case !sameSHA(r.ReviewedBase, v.Base) || !v.Integrated:
		return fmt.Sprintf("the default branch is at %s, not the reviewed base %q merged into the head", v.Base, r.ReviewedBase)
	case !sameSHA(r.ChecksRevision, v.ChecksRevision):
		return fmt.Sprintf("CHECKS_REVISION %q is not the CHECKS_SET revision %s", r.ChecksRevision, v.ChecksRevision)
	}
	return ""
}

// sameSHA accepts a full SHA or an abbreviation of at least minSHA characters.
func sameSHA(got, want string) bool {
	return len(got) >= minSHA && strings.HasPrefix(want, strings.ToLower(got))
}

// findingsOf collects every reason the report binds nothing.
// The worktree comes first, then the evidence and checks, then the reviewer's own findings.
func findingsOf(v Verdict, ev review.Evidence) []string {
	var out []string
	if len(v.Dirty) > 0 {
		out = append(out, "[blocking] the worktree or index changed after the review: "+strings.Join(v.Dirty, ", ")+
			"; review covers committed content only, so a check or tool that writes files must not leave them behind")
	}
	for _, f := range ev.Failures {
		out = append(out, "[blocking] "+f)
	}
	for _, f := range review.CheckFailures(v.Report, v.Runnable) {
		out = append(out, "[blocking] "+f)
	}
	for _, f := range v.Report.Findings {
		out = append(out, f.String())
	}
	return out
}

func deref(p *string) string {
	if p == nil {
		return ""
	}
	return *p
}
