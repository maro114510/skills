package coord

import (
	"cmp"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"path/filepath"
	"slices"
	"strconv"
	"strings"

	"github.com/maro114510/skills/oe/internal/exitcode"
	"github.com/maro114510/skills/oe/internal/handoff"
	"github.com/maro114510/skills/oe/internal/protocol"
	"github.com/maro114510/skills/oe/internal/scan"
	"github.com/maro114510/skills/oe/internal/signals"
	"github.com/maro114510/skills/oe/internal/state"
)

// BriefContext is what the Issue's comments give a brief: its state, every retained human
// comment re-fetched by ID, the loop's questions and answers, and the failure a retry follows.
type BriefContext struct {
	State        state.Issue
	Context      []handoff.Comment
	Notes        []handoff.Note
	PriorFailure string
}

// BriefContext reads Issue n for a brief, contract §16. It refuses an Issue with no state, one
// its state parks, and one with trusted comments the watermark has not consumed yet, so no
// answer posted since the last apply_signals is left out. Context is never pruned, so a brief
// still carries an answer after the watermark passed it, in this session or a later one.
func (s *Session) BriefContext(ctx context.Context, n int) (BriefContext, error) {
	r, err := s.read(ctx, n)
	if err != nil {
		return BriefContext{}, err
	}
	var st state.Issue
	id, err := r.decode(state.IssueKey(n), state.EntityIssue, &st)
	if err != nil {
		return BriefContext{}, err
	}
	switch {
	case id == 0:
		return BriefContext{}, refused("#%d has no state; oe state start creates it before any dispatch", n)
	case parkedByState(&st):
		return BriefContext{}, refused("#%d is parked; only a trusted epic-retry or epic-redo dispatches it again", n)
	}
	if pending := unconsumed(r, st.SignalWatermark); len(pending) > 0 {
		return BriefContext{}, refused("#%d has trusted comments %v above its watermark; run oe state apply-signals --issue %d first", n, pending, n)
	}
	out := BriefContext{State: st, Context: []handoff.Comment{}, Notes: questionNotes(r, n), PriorFailure: ""}
	for _, c := range st.Context {
		hc, err := s.refetch(ctx, c)
		if err != nil {
			return BriefContext{}, err
		}
		out.Context = append(out.Context, hc)
	}
	if st.ConsecutiveFailures > 0 {
		out.PriorFailure = latestFailure(r, n)
	}
	return out, nil
}

// DispatchState reads the state a dispatch works from. An Issue with no state, or one its state
// parks, gets no worktree and no worker.
func (s *Session) DispatchState(ctx context.Context, n int) (state.Issue, error) {
	r, err := s.read(ctx, n)
	if err != nil {
		return state.Issue{}, err
	}
	var st state.Issue
	id, err := r.decode(state.IssueKey(n), state.EntityIssue, &st)
	switch {
	case err != nil:
		return state.Issue{}, err
	case id == 0:
		return state.Issue{}, refused("#%d has no state; oe state start creates it before any dispatch", n)
	case parkedByState(&st):
		return state.Issue{}, refused("#%d is parked; only a trusted epic-retry or epic-redo dispatches it again", n)
	}
	return st, nil
}

// unconsumed lists the trusted comments above the watermark that apply_signals would consume:
// everything but blank comments and the Epic-level commands a child Issue ignores.
func unconsumed(r comments, watermark int64) []int64 {
	var out []int64
	for _, c := range r.list {
		if c.ID <= watermark || !signals.Trusted(c.Association, c.Body) || signals.Blank(c.Body) {
			continue
		}
		switch signals.Parse(c.Body) {
		case signals.Approve, signals.AutoMerge, signals.RevokeAutoMerge, signals.Release:
			continue
		case signals.None, signals.Retry, signals.Redo, signals.Drop:
			out = append(out, c.ID)
		}
	}
	slices.Sort(out)
	return out
}

// noteText is a note's text without its marker line.
func noteText(c protocol.Comment) string {
	_, text, _ := strings.Cut(strings.TrimLeft(c.Body, " \t\r\n"), "\n")
	return text
}

// questionNotes are the loop's blocked and answered-Q&A notes on Issue n, one per key, in
// comment order.
func questionNotes(r comments, n int) []handoff.Note {
	out := []handoff.Note{}
	for key := range r.idx.Notes {
		if !strings.HasPrefix(key, fmt.Sprintf("blocked:%d:", n)) && !strings.HasPrefix(key, fmt.Sprintf("qa:%d:", n)) {
			continue
		}
		id := r.noteID(key)
		for _, c := range r.idx.Notes[key] {
			if c.ID == id {
				out = append(out, handoff.Note{ID: id, Key: key, Text: noteText(c)})
			}
		}
	}
	slices.SortFunc(out, func(a, b handoff.Note) int { return cmp.Compare(a.ID, b.ID) })
	return out
}

// latestFailure is the text of the newest FAILED report note on Issue n, or "".
func latestFailure(r comments, n int) string {
	var top protocol.Comment
	for key, cs := range r.idx.Notes {
		if !strings.HasPrefix(key, fmt.Sprintf("report:%d:", n)) {
			continue
		}
		for _, c := range cs {
			if c.ID > top.ID && handoff.IsFailedReport(noteText(c)) {
				top = c
			}
		}
	}
	if top.ID == 0 {
		return ""
	}
	return noteText(top)
}

type restHumanComment struct {
	ID                int64  `json:"id"`
	Body              string `json:"body"`
	AuthorAssociation string `json:"author_association"`
}

// refetch reads a retained comment by ID: a body whose digest changed is passed as edited, a
// deleted one is listed as deleted, and one whose author is no longer trusted is withheld.
func (s *Session) refetch(ctx context.Context, c state.Context) (handoff.Comment, error) {
	hc := handoff.Comment{ID: c.ID, Author: c.Author, Time: c.Time, Kind: c.Kind, Status: handoff.BodyDeleted, Body: ""}
	path := fmt.Sprintf("repos/%s/%s/issues/comments/%d", s.owner, s.name, c.ID)
	out, found, err := s.c.ReadMissing(ctx, "Not Found", "api", path)
	if err != nil || !found {
		return hc, err
	}
	var got restHumanComment
	if err := json.Unmarshal(out, &got); err != nil || got.ID != c.ID {
		return hc, exitcode.New(exitcode.Unreadable, "comment "+strconv.FormatInt(c.ID, 10)+" was not read")
	}
	switch {
	case !signals.Trusted(got.AuthorAssociation, got.Body):
		hc.Status = handoff.BodyWithheld
	case Digest(got.Body) != c.Digest:
		hc.Status, hc.Body = handoff.BodyEdited, got.Body
	default:
		hc.Status, hc.Body = handoff.BodyCurrent, got.Body
	}
	return hc, nil
}

// The routes a report takes, and what the loop does next.
const (
	RouteDone      = "DONE"
	RouteBlocked   = "BLOCKED"
	RouteFailed    = "FAILED"
	RouteShipClass = "SHIP-CLASS"

	NextReview     = "review"
	NextRedispatch = "redispatch"
	NextAwaitHuman = "await-human"
	NextParked     = "parked"

	AnswerNone    = "none"
	AnswerPosted  = "posted"
	AnswerRefused = "refused"
)

// minSHA is the shortest HEAD_SHA a report may give.
const minSHA = 7

// Triage is one worker report and what the caller read around it.
type Triage struct {
	// Report is the parsed report, and ParseErr why it could not be parsed.
	Report   handoff.Report
	ParseErr error
	// Worktree is the worktree the worker was dispatched to, verified on the Issue's branch,
	// Head its HEAD now, and Dirty whether it holds uncommitted work.
	Worktree string
	Head     string
	Dirty    bool
	// ShipClass are the kinds the Publisher judged the questions to be; any parks the Issue.
	ShipClass []handoff.ShipClass
	// CommitApproval marks a question that asks to approve a commit; it is never auto-answered.
	CommitApproval bool
	// Answer is the Publisher's answer from written sources, or "".
	Answer string
}

// TriageResult is how a report was routed.
type TriageResult struct {
	Issue      int          `json:"issue"`
	Reported   string       `json:"reported"`
	Route      string       `json:"route"`
	Reason     string       `json:"reason"`
	Next       string       `json:"next"`
	AutoAnswer string       `json:"auto_answer"`
	Notes      []NoteResult `json:"notes"`
	State      state.Issue  `json:"state"`
}

// Triage routes a worker report by one set of rules, contract §16. A report that is malformed,
// names another dispatch, or claims DONE on a head the worktree does not have, or with work left
// uncommitted, is FAILED, never DONE. Every note is posted before the state records the report,
// so a re-dispatch never runs ahead of the question, answer, or failure it depends on.
func (s *Session) Triage(ctx context.Context, n int, t Triage) (TriageResult, error) {
	var res TriageResult
	res.Issue, res.Reported, res.AutoAnswer, res.Notes = n, t.Report.Status, AnswerNone, []NoteResult{}
	r, err := s.read(ctx, n)
	if err != nil {
		return res, err
	}
	var st state.Issue
	id, err := r.decode(state.IssueKey(n), state.EntityIssue, &st)
	if err != nil {
		return res, err
	}
	if id == 0 {
		return res, refused("#%d has no state, so no worker was dispatched for it", n)
	}
	rep, reason := route(n, &st, t)
	res.Route, res.Reason = rep.Status, reason
	switch {
	case rep.Status == RouteDone:
		err = s.triageDone(ctx, n, rep, &res)
	case rep.Status == RouteBlocked && len(t.ShipClass) > 0:
		err = s.triageShipClass(ctx, n, t, &res)
	case rep.Status == RouteBlocked:
		err = s.triageBlocked(ctx, n, rep, t, &res)
	default:
		err = s.triageFailed(ctx, n, &st, rep, t.Head, &res)
	}
	return res, err
}

// route is normalize, saying when a report it made FAILED drops the Publisher's judgment.
func route(n int, st *state.Issue, t Triage) (handoff.Report, string) {
	rep, reason := normalize(n, st, t)
	if reason != "" && judged(t) {
		reason += " (the Publisher's judgment on its questions was not applied)"
		rep.Error = reason
	}
	return rep, reason
}

// normalize checks a report against its dispatch and returns the report to record: the one
// given when it holds, else a FAILED one naming the dispatch and the reason.
func normalize(n int, st *state.Issue, t Triage) (handoff.Report, string) {
	rep := t.Report
	failed := func(why string) (handoff.Report, string) {
		return handoff.Report{
			Status: handoff.StatusFailed, Issue: n, Branch: st.Branch, Worktree: t.Worktree, HeadSHA: t.Head, ChangedFiles: "",
			Checks: "", Criteria: "", Skipped: "", Found: "", Summary: "", Questions: "", Error: why,
		}, why
	}
	switch {
	case t.ParseErr != nil:
		return failed(t.ParseErr.Error())
	case rep.Status == handoff.StatusFailed:
		return failed(cmp.Or(rep.Error, "the worker reported FAILED without an ERROR"))
	case rep.Issue != n || !known(rep.Branch, st.Branch, eq) || !known(rep.Worktree, t.Worktree, samePath):
		return failed(fmt.Sprintf("the report names #%d on %q in %q, not this dispatch's #%d on %q in %q",
			rep.Issue, rep.Branch, rep.Worktree, n, st.Branch, t.Worktree))
	case rep.Status != handoff.StatusDone:
		rep.HeadSHA, rep.Branch, rep.Worktree = t.Head, st.Branch, t.Worktree
		return rep, ""
	case len(rep.HeadSHA) < minSHA || !strings.HasPrefix(t.Head, rep.HeadSHA):
		return failed(fmt.Sprintf("the report's HEAD_SHA %s is not the worktree's HEAD %s", rep.HeadSHA, t.Head))
	case t.Dirty:
		return failed("the worktree holds uncommitted work; the worker commits, and the loop never does")
	}
	rep.HeadSHA, rep.Branch, rep.Worktree = t.Head, st.Branch, t.Worktree
	return rep, ""
}

func judged(t Triage) bool { return len(t.ShipClass) > 0 || t.CommitApproval || t.Answer != "" }

// unknownField is what a report gives for a field the worker could not tell.
const unknownField = "UNKNOWN"

// known accepts a field the worker could not tell, since oe checked the dispatch itself, and
// otherwise requires it to match.
func known(got, want string, same func(a, b string) bool) bool {
	return got == unknownField || same(got, want)
}

func eq(a, b string) bool { return a == b }

func samePath(a, b string) bool {
	if a == "" || b == "" {
		return false
	}
	ca, errA := filepath.EvalSymlinks(a)
	cb, errB := filepath.EvalSymlinks(b)
	if errA != nil || errB != nil {
		return filepath.Clean(a) == filepath.Clean(b)
	}
	return ca == cb
}

// post posts a note and records it in res. A secret-scan refusal is returned as is.
func (s *Session) post(ctx context.Context, n int, key, text string, res *TriageResult) error {
	nr, err := s.PostNote(ctx, n, key, text)
	if err != nil {
		return err
	}
	res.Notes = append(res.Notes, nr)
	return nil
}

// parkOnSecret parks the Issue on a suspected secret in what the worker gave, posting a note
// that withholds the text.
func (s *Session) parkOnSecret(ctx context.Context, n int, what, head string, res *TriageResult) error {
	text := handoff.ShipClassNote(n, handoff.ShipSecret, "")
	key := fmt.Sprintf("ship-class:%d:%s:%s", n, handoff.ShipSecret, DigestPlaceholder)
	if err := s.post(ctx, n, key, text, res); err != nil {
		return err
	}
	return s.parkWith(ctx, n, []string{"ship-class secret: " + what + " holds a suspected secret"}, head, res)
}

// parkWith parks the Issue, recording the head the worker left, so a later epic-retry resumes
// from the worktree as it is instead of stopping on a divergence.
func (s *Session) parkWith(ctx context.Context, n int, blockers []string, head string, res *TriageResult) error {
	st, err := s.Update(ctx, n, Park{Blockers: blockers, Head: head})
	res.State, res.Route, res.Next = st, RouteShipClass, NextParked
	return err
}

func isScan(err error) bool {
	_, ok := errors.AsType[*ScanError](err)
	return ok
}

func headKey(h string) string { return cmp.Or(h, "none") }

func (s *Session) triageDone(ctx context.Context, n int, rep handoff.Report, res *TriageResult) error {
	key := fmt.Sprintf("report:%d:%s:%s", n, rep.HeadSHA, DigestPlaceholder)
	if err := s.post(ctx, n, key, handoff.DoneReportNote(rep.HeadSHA, rep), res); isScan(err) {
		return s.parkOnSecret(ctx, n, "the DONE report", rep.HeadSHA, res)
	} else if err != nil {
		return err
	}
	next, err := s.Update(ctx, n, WorkerResult{Report: asReport(rep), Worktree: rep.Worktree, QuestionKey: ""})
	res.State, res.Next = next, NextReview
	return err
}

func (s *Session) triageShipClass(ctx context.Context, n int, t Triage, res *TriageResult) error {
	res.Route = RouteShipClass
	blockers := make([]string, 0, len(t.ShipClass))
	// A question the Publisher judged a secret is published under no kind.
	questions := t.Report.Questions
	if slices.Contains(t.ShipClass, handoff.ShipSecret) {
		questions = ""
	}
	for _, kind := range t.ShipClass {
		key := fmt.Sprintf("ship-class:%d:%s:%s", n, kind, DigestPlaceholder)
		err := s.post(ctx, n, key, handoff.ShipClassNote(n, kind, questions), res)
		if isScan(err) {
			return s.parkOnSecret(ctx, n, "the worker's questions", t.Head, res)
		}
		if err != nil {
			return err
		}
		blockers = append(blockers, fmt.Sprintf("ship-class %s: %s", kind, res.Notes[len(res.Notes)-1].Key))
	}
	return s.parkWith(ctx, n, blockers, t.Head, res)
}

func (s *Session) triageBlocked(ctx context.Context, n int, rep handoff.Report, t Triage, res *TriageResult) error {
	key := fmt.Sprintf("blocked:%d:%s:%s", n, headKey(t.Head), DigestPlaceholder)
	err := s.post(ctx, n, key, handoff.BlockedNote(n, t.Report.Questions), res)
	if isScan(err) {
		return s.parkOnSecret(ctx, n, "the worker's questions", t.Head, res)
	}
	if err != nil {
		return err
	}
	question := res.Notes[len(res.Notes)-1].Key
	// The answer is posted before the state records the report, so no dispatch can read an
	// in-progress state whose question has an answer the brief would miss.
	res.Next = NextAwaitHuman
	if err := s.autoAnswer(ctx, n, t, res); err != nil {
		return err
	}
	next, err := s.Update(ctx, n, WorkerResult{Report: asReport(rep), Worktree: rep.Worktree, QuestionKey: question})
	res.State = next
	return err
}

// autoAnswer posts the Publisher's answer once per Issue per session. A commit-approval
// question, a second BLOCKED in the same session, or an answer the scan refuses is left for a
// person, and the Issue stays in progress.
func (s *Session) autoAnswer(ctx context.Context, n int, t Triage, res *TriageResult) error {
	if strings.TrimSpace(t.Answer) == "" {
		return nil
	}
	res.AutoAnswer = AnswerRefused
	if t.CommitApproval {
		res.Reason = "a commit-approval question is never auto-answered"
		return nil
	}
	r, err := s.read(ctx, n)
	if err != nil {
		return err
	}
	session := Digest(s.token)
	text := handoff.AnswerNote(t.Report.Questions, t.Answer, session)
	key := fmt.Sprintf("qa:%d:%s", n, Digest(text))
	if id := r.noteID(key); id != 0 {
		// This very answer is already on the Issue: a re-run after a failed state write.
		res.Notes = append(res.Notes, NoteResult{On: n, Key: key, Posted: false, CommentID: id, Findings: []scan.Finding{}})
		res.AutoAnswer, res.Next = AnswerPosted, NextRedispatch
		return nil
	}
	if answeredIn(r, n, session) {
		res.Reason = "this session already auto-answered #" + strconv.Itoa(n) + "; a second BLOCKED waits for a person"
		return nil
	}
	err = s.post(ctx, n, key, text, res)
	if isScan(err) {
		res.Reason = "the answer holds a suspected secret; it was not posted"
		return nil
	}
	if err != nil {
		return err
	}
	res.AutoAnswer, res.Next = AnswerPosted, NextRedispatch
	return nil
}

// answeredIn reports whether the session with this digest already auto-answered Issue n.
func answeredIn(r comments, n int, session string) bool {
	for key, cs := range r.idx.Notes {
		if !strings.HasPrefix(key, fmt.Sprintf("qa:%d:", n)) {
			continue
		}
		for _, c := range cs {
			if handoff.AnsweredIn(c.Body, session) {
				return true
			}
		}
	}
	return false
}

func (s *Session) triageFailed(ctx context.Context, n int, st *state.Issue, rep handoff.Report, head string, res *TriageResult) error {
	res.Route = RouteFailed
	reason := rep.Error
	key := fmt.Sprintf("report:%d:%s:%s", n, headKey(head), DigestPlaceholder)
	err := s.post(ctx, n, key, handoff.FailedReportNote(reason), res)
	if isScan(err) {
		reason = "the worker's error text holds a suspected secret and is withheld"
		err = s.post(ctx, n, key, handoff.FailedReportNote(reason), res)
	}
	if err != nil {
		return err
	}
	parks := st.ConsecutiveFailures >= 1
	if parks {
		// The note comes first, so a run that stops before the state write leaves the reason.
		pk := fmt.Sprintf("parked:%d:failed:%s", n, DigestPlaceholder)
		if err := s.post(ctx, n, pk, handoff.ParkedNote(n, "2 回続けて FAILED になりました。\n\n"+reason), res); err != nil {
			return err
		}
	}
	rep.Error = reason
	next, err := s.Update(ctx, n, WorkerResult{Report: asReport(rep), Worktree: rep.Worktree, QuestionKey: ""})
	res.State, res.Next = next, NextRedispatch
	if parks {
		res.Next = NextParked
	}
	return err
}

func asReport(r handoff.Report) Report {
	return Report{Status: r.Status, Issue: r.Issue, Branch: r.Branch, Worktree: r.Worktree, HeadSHA: r.HeadSHA, Error: r.Error}
}
