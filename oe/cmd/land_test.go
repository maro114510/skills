package cmd_test

import (
	"encoding/json"
	"fmt"
	"slices"
	"strings"
	"sync"
	"testing"

	"github.com/maro114510/skills/oe/internal/coord"
	"github.com/maro114510/skills/oe/internal/ghfake"
	"github.com/maro114510/skills/oe/internal/protocol"
	"github.com/maro114510/skills/oe/internal/state"
)

const (
	landReviewed = "rev0001"
	landBase     = "base001"
	landMerge    = "merge01"
	landPR       = 12
)

// landFlow is Issue 7 shipped as pull request 12 at its reviewed head on the verified base, with the Epic approved and merging granted.
// The fake GitHub answers a merge with 200 and the pull request as merged on the verified base, unless a test says otherwise.
type landFlow struct {
	w   *coordWorld
	tok string

	mu sync.Mutex
	// puts holds the fields of every merge request the fake received, and refs the base reads it answered.
	puts []map[string]string
	refs int
	// intentSeen holds the post-merge phase the store held when each merge request arrived.
	intentSeen []string
	// base answers the n-th read of the default branch's head, counting from 1.
	base func(n int) string
	// pulls answers the merged-pull query by pull request number.
	pulls func(num string) string
}

func newLandFlow(t *testing.T) *landFlow {
	t.Helper()
	w := newCoordWorld(t)
	f := &landFlow{w: w, tok: w.acquire(t), mu: sync.Mutex{}, puts: nil, refs: 0, intentSeen: nil,
		base:  func(int) string { return landBase },
		pulls: func(string) string { return mergedPullBody(landPR, landMerge, "SUCCESS") }}
	l := coord.NewLedger(1)
	w.put(t, 277, &l)
	w.store.Add(277, "loop", "OWNER", "<!-- oe:v2 note run-plan -->\nplan")
	w.store.Add(277, "alice", "MEMBER", "epic-approve")
	w.store.Add(277, "alice", "MEMBER", "epic-auto-merge")
	w.put(t, 7, f.issue(landReviewed))
	w.r.On(ghfake.PullsByHead, func(map[string]string) string {
		return ghfake.PullPage("["+ghfake.PullNodeOnBase(landPR, "OPEN", "feat/issue-7", "main", "Closes #7", "2026-10-05T00:00:00Z", false)+"]", false, "")
	})
	w.r.On(ghfake.Readiness, func(map[string]string) string { return pullBody(readyPull(landReviewed)) })
	w.r.On(ghfake.Settings, func(map[string]string) string { return ghfake.SettingsReply(true, true) })
	w.r.On(ghfake.Ref, func(map[string]string) string {
		f.mu.Lock()
		f.refs++
		n := f.refs
		f.mu.Unlock()
		return ghfake.RefReply(f.base(n))
	})
	w.r.On(ghfake.Commit, func(map[string]string) string { return ghfake.CommitReply(landMerge, landBase, landReviewed) })
	w.r.On(ghfake.MergePull, func(v map[string]string) string { return f.pulls(v["num"]) })
	w.r.On(ghfake.Merge, func(v map[string]string) string {
		f.mu.Lock()
		f.puts = append(f.puts, v)
		f.intentSeen = append(f.intentSeen, f.phase())
		f.mu.Unlock()
		return ghfake.HTTP(200, `{"sha":"`+landMerge+`","merged":true,"message":"Pull Request successfully merged"}`)
	})
	return f
}

// issue is Issue 7's state: approved at head, shipped as pull request 12.
func (f *landFlow) issue(head string) *state.Issue {
	var st state.Issue
	st.Entity, st.Key = state.EntityIssue, state.IssueKey(7)
	st.Branch = "feat/issue-7"
	st.HeadSHA = &head
	st.PendingFindings, st.UnresolvedBlockers, st.Context = []string{}, []string{}, []state.Context{}
	st.Approval = &state.Approval{ReviewedSHA: head, VerifiedBase: landBase, ReviewEvidence: state.ReviewEvidence{
		BehaviorChange: false, Basis: "docs only",
		Criteria: []state.Criterion{{Text: "the change is documented", Result: "verified", Kind: "static", Evidence: "README.md:3"}},
	}}
	st.Publish = &state.Publish{SHA: head, PrevSHA: "", Base: landBase, Branch: "feat/issue-7", PR: landPR, Phase: "linked"}
	return &st
}

// phase is the post-merge record's phase right now, or "none". The caller holds mu or is a handler.
func (f *landFlow) phase() string {
	if pm := f.record(); pm != nil {
		return pm.Phase
	}
	return "none"
}

func (f *landFlow) record() *state.PostMerge {
	for _, c := range f.w.store.Comments(277) {
		if !strings.HasPrefix(c.Body, "<!-- oe:v2 state post-merge -->") {
			continue
		}
		var pm state.PostMerge
		if _, err := protocol.DecodeState(c.Body, &pm); err != nil {
			return nil
		}
		return &pm
	}
	return nil
}

func (f *landFlow) ledger(t *testing.T) state.Ledger {
	t.Helper()
	for _, c := range f.w.store.Comments(277) {
		if strings.HasPrefix(c.Body, "<!-- oe:v2 state ledger -->") {
			var l state.Ledger
			if _, err := protocol.DecodeState(c.Body, &l); err != nil {
				t.Fatal(err)
			}
			return l
		}
	}
	t.Fatal("no ledger")
	return state.Ledger{}
}

func (f *landFlow) merge(extra ...string) result {
	args := append([]string{"--epic", "277", "land", "merge", "--issue", "7", "--lease-token", f.tok}, extra...)
	return f.w.run(args...)
}

// putCount is how many merge requests the fake GitHub received.
func (f *landFlow) putCount() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.puts)
}

func (f *landFlow) notes(issue int, prefix string) int {
	return countPrefix(f.w.store.Comments(issue), "<!-- oe:v2 note "+prefix)
}

// writeIndex is the position among the store's writes of the first one whose body holds every text, or -1.
func (f *landFlow) writeIndex(texts ...string) int {
	for i, w := range f.w.store.Writes() {
		if !slices.ContainsFunc(texts, func(s string) bool { return !strings.Contains(w.Body, s) }) {
			return i
		}
	}
	return -1
}

// wantNoRequest checks that no merge was requested, and that nothing but reads and the named writes reached GitHub.
func (f *landFlow) wantNoRequest(t *testing.T) {
	t.Helper()
	if n := f.putCount(); n != 0 {
		t.Errorf("%d merge requests were sent, want none", n)
	}
	f.wantNoBypass(t)
}

// wantNoBypass checks that no call went through gh pr, which can enable auto-merge, or used --admin.
func (f *landFlow) wantNoBypass(t *testing.T) {
	t.Helper()
	for _, c := range f.w.r.Calls() {
		if len(c) > 1 && c[1] == "pr" || slices.Contains(c, "--admin") {
			t.Errorf("call %q uses gh pr or --admin", c)
		}
	}
}

type landed struct {
	Issue        int    `json:"issue"`
	PR           int    `json:"pr"`
	Route        string `json:"route"`
	Reason       string `json:"reason"`
	Next         string `json:"next"`
	Method       string `json:"method"`
	ReviewedSHA  string `json:"reviewed_sha"`
	VerifiedBase string `json:"verified_base"`
	MergeSHA     string `json:"merge_sha"`
	Result       string `json:"result"`
	Repair       []string
	Reconciled   *struct {
		PR     int    `json:"pr"`
		Issue  int    `json:"issue"`
		Result string `json:"result"`
	} `json:"reconciled"`
	Freeze *struct {
		Seq    int    `json:"seq"`
		Reason string `json:"reason"`
	} `json:"freeze"`
}

func parseLanded(t *testing.T, r result) landed {
	t.Helper()
	var out landed
	if err := json.Unmarshal([]byte(strings.SplitN(r.stdout, "\n", 2)[0]), &out); err != nil {
		t.Fatalf("stdout %q is not the land payload: %v", r.stdout, err)
	}
	return out
}

// pullOpts is a pull request as the readiness query reads it.
type pullOpts struct {
	head, mergeable, mergeState string
	draft                       bool
	reviews, threads, contexts  string
}

func readyPull(head string) pullOpts {
	return pullOpts{
		head: head, mergeable: "MERGEABLE", mergeState: "CLEAN", draft: false,
		reviews: `{"totalCount":0,"nodes":[]}`, threads: `{"totalCount":0,"nodes":[]}`,
		contexts: `{"totalCount":1,"nodes":[{"__typename":"CheckRun","name":"test","status":"COMPLETED","conclusion":"SUCCESS"}]}`,
	}
}

func pullBody(o pullOpts) string {
	return fmt.Sprintf(`{"data":{"repository":{"pullRequest":{"number":%d,"state":"OPEN","isDraft":%t,"mergeable":%q,`+
		`"mergeStateStatus":%q,"reviewDecision":null,"isMergeQueueEnabled":false,"headRefOid":%q,`+
		`"reviewRequests":{"totalCount":0,"nodes":[]},"latestOpinionatedReviews":%s,"reviewThreads":%s,`+
		`"commits":{"nodes":[{"commit":{"oid":%q,"statusCheckRollup":{"state":"SUCCESS","contexts":%s}}}]}}}}}`,
		landPR, o.draft, o.mergeable, o.mergeState, o.head, o.reviews, o.threads, o.head, o.contexts)
}

// mergedPullBody is a merged pull request with one check of the given conclusion on its merge commit.
func mergedPullBody(num int, merge, conclusion string) string {
	return fmt.Sprintf(`{"data":{"repository":{"pullRequest":{"number":%d,"state":"MERGED","mergedAt":"2026-10-19T00:00:00Z",`+
		`"mergeCommit":{"oid":%q,"statusCheckRollup":{"state":"SUCCESS","contexts":{"totalCount":1,"nodes":[`+
		`{"__typename":"CheckRun","name":"test","status":"COMPLETED","conclusion":%q}]}}}}}}}`, num, merge, conclusion)
}

// unreadableBody is a GraphQL answer carrying only an error, which no read may act on.
const unreadableBody = `{"errors":[{"message":"boom"}]}`

func openPullBody(num int) string {
	return fmt.Sprintf(`{"data":{"repository":{"pullRequest":{"number":%d,"state":"OPEN","mergedAt":null,"mergeCommit":null}}}}`, num)
}

// TestLandMergeMergesTheReviewedHeadAndRecordsTheIntentFirst guards MQ-01, PH-02, and LC-07: the request names the reviewed head
// as its expected SHA, the post-merge record already says intent when it arrives, and the result is recorded once.
func TestLandMergeMergesTheReviewedHeadAndRecordsTheIntentFirst(t *testing.T) {
	t.Parallel()

	f := newLandFlow(t)
	r := f.merge()
	out := parseLanded(t, r)
	if r.code != 0 || out.Route != "MERGED" || out.Next != "rescan" || out.MergeSHA != landMerge || out.Method != "merge" || out.PR != landPR {
		t.Fatalf("exit %d, stdout %q; want MERGED on pull request %d with merge commit %s by merge commit", r.code, r.stdout, landPR, landMerge)
	}
	if len(f.puts) != 1 || f.puts[0]["sha"] != landReviewed || f.puts[0]["merge_method"] != "merge" {
		t.Errorf("merge requests = %v, want one with sha=%s and merge_method=merge", f.puts, landReviewed)
	}
	if len(f.intentSeen) != 1 || f.intentSeen[0] != state.PhaseIntent {
		t.Errorf("the record held %v when the request arrived, want intent", f.intentSeen)
	}
	pm := f.record()
	if pm == nil || pm.Phase != state.PhaseMerged || pm.MergeSHA != landMerge || pm.PR != landPR || pm.Issue != 7 || pm.ReviewedSHA != landReviewed || pm.VerifiedBase != landBase {
		t.Errorf("record = %+v, want merged with %s for pull request %d", pm, landMerge, landPR)
	}
	if n := f.notes(7, fmt.Sprintf("merge-result:%d:%s:merged -->", landPR, landReviewed)); n != 1 {
		t.Errorf("merge-result notes = %d, want one for the pull request, head, and result", n)
	}
	f.wantNoBypass(t)
}

// TestLandMergePrefersAMergeCommitThenSquashAndNeverRebases guards MQ-03 and MQ-04.
func TestLandMergePrefersAMergeCommitThenSquashAndNeverRebases(t *testing.T) {
	t.Parallel()

	for name, tc := range map[string]struct {
		mergeCommit, squash bool
		method              string
	}{
		"both allowed": {true, true, "merge"},
		"merge commit": {true, false, "merge"},
		"squash only":  {false, true, "squash"},
		"rebase only":  {false, false, ""},
	} {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			f := newLandFlow(t)
			f.w.r.On(ghfake.Settings, func(map[string]string) string { return ghfake.SettingsReply(tc.mergeCommit, tc.squash) })
			r := f.merge()
			if tc.method == "" {
				out := parseLanded(t, r)
				if r.code != 0 || out.Route != "HELD" || out.Next != "human" {
					t.Errorf("exit %d, stdout %q; want HELD for a person, since only rebase merging is allowed", r.code, r.stdout)
				}
				f.wantNoRequest(t)
				return
			}
			if r.code != 0 || len(f.puts) != 1 || f.puts[0]["merge_method"] != tc.method {
				t.Errorf("exit %d, requests %v; want one with merge_method=%s", r.code, f.puts, tc.method)
			}
		})
	}
}

// TestLandMergeOnAMovedHeadRoutesToReverificationWithoutARetry: a 409 says the head is no longer the reviewed commit,
// so the Issue goes back to review, and the same request is never sent again.
func TestLandMergeOnAMovedHeadRoutesToReverificationWithoutARetry(t *testing.T) {
	t.Parallel()

	f := newLandFlow(t)
	f.w.r.On(ghfake.Merge, func(v map[string]string) string {
		f.mu.Lock()
		f.puts = append(f.puts, v)
		f.mu.Unlock()
		return ghfake.HTTP(409, `{"message":"Head branch was modified. Review and try the merge again."}`)
	})
	f.w.r.Exit(ghfake.Merge, 1)
	f.w.r.Stderr(ghfake.Merge, "gh: Head branch was modified. Review and try the merge again. (HTTP 409)")
	r := f.merge()
	out := parseLanded(t, r)
	if r.code != 3 || out.Route != "HEAD_MOVED" || out.Next != "reverify" || out.Result != "head-moved" {
		t.Errorf("exit %d, stdout %q; want exit 3, HEAD_MOVED, next reverify", r.code, r.stdout)
	}
	if f.putCount() != 1 {
		t.Errorf("merge requests = %d, want exactly one", f.putCount())
	}
	if pm := f.record(); pm == nil || pm.Phase != state.PhaseHeadMoved || pm.MergeSHA != "" {
		t.Errorf("record = %+v, want head-moved without a merge commit", pm)
	}
	if n := f.notes(7, fmt.Sprintf("merge-result:%d:%s:head-moved -->", landPR, landReviewed)); n != 1 {
		t.Errorf("merge-result notes = %d, want one", n)
	}
}

// TestLandMergeRejectedByTheRepositoryIsRecordedAndHeldForAPerson guards MA-04 and LC-05: a refused request is a
// repository control the loop never bypasses, so it records the result, holds the pull request, and never retries.
func TestLandMergeRejectedByTheRepositoryIsRecordedAndHeldForAPerson(t *testing.T) {
	t.Parallel()

	f := newLandFlow(t)
	f.w.r.On(ghfake.Merge, func(v map[string]string) string {
		f.mu.Lock()
		f.puts = append(f.puts, v)
		f.mu.Unlock()
		return ghfake.HTTP(405, `{"message":"Repository rule violations found"}`)
	})
	f.w.r.Exit(ghfake.Merge, 1)
	f.w.r.Stderr(ghfake.Merge, "gh: Repository rule violations found (HTTP 405)")
	r := f.merge()
	out := parseLanded(t, r)
	if r.code != 0 || out.Route != "REJECTED" || out.Next != "human" || out.Result != "rejected" {
		t.Errorf("exit %d, stdout %q; want REJECTED for a person", r.code, r.stdout)
	}
	if f.putCount() != 1 || f.notes(7, "merge-hold:") != 1 {
		t.Errorf("requests %d, merge holds %d; want one request and one hold naming the rejection", f.putCount(), f.notes(7, "merge-hold:"))
	}
	if pm := f.record(); pm == nil || pm.Phase != state.PhaseRejected {
		t.Errorf("record = %+v, want rejected", pm)
	}
}

// TestLandMergeWithoutAResponseIsReconciledFromThePullRequestAndNeverSentTwice: a request that was sent and unanswered
// may have merged, so the pull request says what happened and the loop records merged or unknown.
func TestLandMergeWithoutAResponseIsReconciledFromThePullRequestAndNeverSentTwice(t *testing.T) {
	t.Parallel()

	noResponse := func(f *landFlow) {
		f.w.r.On(ghfake.Merge, func(v map[string]string) string {
			f.mu.Lock()
			f.puts = append(f.puts, v)
			f.mu.Unlock()
			return ""
		})
		f.w.r.Exit(ghfake.Merge, 1)
		f.w.r.Stderr(ghfake.Merge, "gh: error connecting to api.github.com")
	}
	tests := map[string]struct {
		pulls  func(string) string
		code   int
		route  string
		result string
		merge  string
	}{
		"the pull request merged on the verified base": {
			func(string) string { return mergedPullBody(landPR, landMerge, "SUCCESS") }, 0, "MERGED", "merged", landMerge,
		},
		"the pull request is still open": {
			func(string) string { return openPullBody(landPR) }, 4, "UNKNOWN", "unknown", "",
		},
		"the pull request cannot be read": {
			func(string) string { return unreadableBody }, 4, "UNKNOWN", "unknown", "",
		},
	}
	for name, tc := range tests {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			f := newLandFlow(t)
			noResponse(f)
			// Health reads the pull request only once a record exists, so the answer applies from the reconciliation on.
			f.pulls = tc.pulls
			r := f.merge()
			out := parseLanded(t, r)
			if r.code != tc.code || out.Route != tc.route || out.Result != tc.result || out.MergeSHA != tc.merge {
				t.Errorf("exit %d, stdout %q; want exit %d, %s, result %s", r.code, r.stdout, tc.code, tc.route, tc.result)
			}
			if f.putCount() != 1 {
				t.Errorf("merge requests = %d, want exactly one, never a second", f.putCount())
			}
			if pm := f.record(); pm == nil || pm.Phase != tc.result || pm.MergeSHA != tc.merge {
				t.Errorf("record = %+v, want %s", pm, tc.result)
			}
			if f.notes(7, fmt.Sprintf("merge-result:%d:%s:%s -->", landPR, landReviewed, tc.result)) != 1 {
				t.Errorf("want one merge-result note for %s", tc.result)
			}
		})
	}
}

// TestLandMergeOnAnUnverifiedBaseFreezesTheEpicBeforeAnyOtherWrite guards MQ-05 and LC-08: a merge commit whose first parent is not
// the verified base, or whose parent cannot be read, freezes the Epic first, then notes and records the result, and nothing else merges.
func TestLandMergeOnAnUnverifiedBaseFreezesTheEpicBeforeAnyOtherWrite(t *testing.T) {
	t.Parallel()

	for name, setup := range map[string]func(f *landFlow){
		"the first parent is another commit": func(f *landFlow) {
			f.w.r.On(ghfake.Commit, func(map[string]string) string { return ghfake.CommitReply(landMerge, "moved01", landReviewed) })
		},
		"the first parent cannot be read": func(f *landFlow) {
			f.w.r.On(ghfake.Commit, func(map[string]string) string { return `{"message":"boom"}` })
			f.w.r.Exit(ghfake.Commit, 1)
		},
	} {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			f := newLandFlow(t)
			setup(f)
			r := f.merge()
			out := parseLanded(t, r)
			if r.code != 4 || out.Route != "MERGED_UNVERIFIED_BASE" || out.Result != "merged-unverified-base" || out.MergeSHA != landMerge || out.Freeze == nil {
				t.Fatalf("exit %d, stdout %q; want exit 4, MERGED_UNVERIFIED_BASE with the freeze", r.code, r.stdout)
			}
			freeze := f.writeIndex("<!-- oe:v2 state ledger -->", `"released": false`)
			note := f.writeIndex("<!-- oe:v2 note merge-result:")
			record := f.writeIndex("<!-- oe:v2 state post-merge -->", state.PhaseMergedUnverifiedBase)
			if freeze < 0 || note < 0 || record < 0 || freeze > note || note > record {
				t.Errorf("write order: freeze %d, result note %d, record %d; want the freeze first", freeze, note, record)
			}
			if l := f.ledger(t); l.Freeze == nil || l.Freeze.Released || !strings.Contains(l.Freeze.Reason, "PR #12 merged on an unverified base") {
				t.Errorf("ledger freeze = %+v, want an active freeze naming the pull request", l.Freeze)
			}
			// A second pull request never merges on top of it.
			before := f.putCount()
			again := f.merge()
			if again.code != 4 || f.putCount() != before {
				t.Errorf("second land: exit %d, requests %d -> %d; want the frozen Epic to stop it", again.code, before, f.putCount())
			}
		})
	}
}

// TestLandMergeIsRefusedWithoutAGrantOrWhileFrozen guards MA-02, MA-03, and FZ-01: a missing, revoked, or unreadable grant,
// a missing approval, and a frozen Epic each stop the merge before any request or write.
func TestLandMergeIsRefusedWithoutAGrantOrWhileFrozen(t *testing.T) {
	t.Parallel()

	tests := map[string]struct {
		setup func(f *landFlow)
		code  int
	}{
		"the grant was revoked": {func(f *landFlow) { f.w.store.Add(277, "alice", "MEMBER", "epic-revoke-auto-merge") }, 8},
		"the grant was never given": {func(f *landFlow) {
			for _, c := range f.w.store.Comments(277) {
				if c.Body == "epic-auto-merge" {
					f.w.store.Delete(c.ID)
				}
			}
		}, 8},
		"the grant is by a stranger": {func(f *landFlow) {
			for _, c := range f.w.store.Comments(277) {
				if c.Body == "epic-auto-merge" {
					f.w.store.Delete(c.ID)
				}
			}
			f.w.store.Add(277, "stranger", "NONE", "epic-auto-merge")
		}, 8},
		"the Epic was never approved": {func(f *landFlow) {
			for _, c := range f.w.store.Comments(277) {
				if c.Body == "epic-approve" {
					f.w.store.Delete(c.ID)
				}
			}
		}, 8},
		"the comments cannot be read": {func(f *landFlow) {
			f.w.r.Exit(ghfake.CommentsName, 1)
		}, 1},
		"the Epic is frozen": {func(f *landFlow) {
			l := frozenLedger()
			for _, c := range f.w.store.Comments(277) {
				if strings.HasPrefix(c.Body, "<!-- oe:v2 state ledger -->") {
					f.w.store.Delete(c.ID)
				}
			}
			f.w.put(t, 277, &l)
		}, 4},
	}
	for name, tc := range tests {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			f := newLandFlow(t)
			tc.setup(f)
			before := f.w.r.Mutations()
			r := f.merge()
			if r.code != tc.code {
				t.Errorf("exit %d, stdout %q; want %d", r.code, r.stdout, tc.code)
			}
			f.wantNoRequest(t)
			if f.record() != nil {
				t.Errorf("a post-merge record exists: %+v", f.record())
			}
			// A frozen Epic posts only its own missing freeze note.
			if got := f.w.r.Mutations() - before; got > 1 {
				t.Errorf("%d writes reached GitHub, want none beyond a missing freeze note", got)
			}
		})
	}
}
