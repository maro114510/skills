package snapshot_test

import (
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/maro114510/skills/oe/internal/exitcode"
	"github.com/maro114510/skills/oe/internal/gh"
	"github.com/maro114510/skills/oe/internal/ghfake"
	"github.com/maro114510/skills/oe/internal/inputs"
	"github.com/maro114510/skills/oe/internal/runner"
	"github.com/maro114510/skills/oe/internal/snapshot"
)

func in() inputs.Inputs {
	return inputs.Inputs{
		Repo: "o/r", Epic: 277, Me: "loop", DefaultBranch: "main", MaxParallel: 3, MaxParallelReason: "", GHVersion: "2.102.0",
	}
}

func read(t *testing.T, r *ghfake.Router) (*snapshot.Board, error) {
	t.Helper()
	return snapshot.ReadBoard(t.Context(), gh.New(r, false), in())
}

func wantCode(t *testing.T, err error, code exitcode.Code) {
	t.Helper()
	if got := exitcode.CodeOf(err); got != code {
		t.Fatalf("exit code = %d (%v), want %d", got, err, code)
	}
}

func TestReadBoard(t *testing.T) {
	t.Parallel()

	r := ghfake.New()
	r.On(ghfake.Tree, func(map[string]string) string {
		return ghfake.EpicTree("plan", "["+
			ghfake.IssueNode(1, "CLOSED", "", "")+","+
			ghfake.IssueNode(5, "OPEN", ghfake.BlockerConn(1, `{"number":1,"state":"CLOSED"}`), ghfake.SubConn(2, ghfake.IssueNode(51, "OPEN", "", ""), ghfake.IssueNode(52, "CLOSED", "", "")))+","+
			ghfake.IssueNode(7, "OPEN", "", "")+"]", 3, false, "")
	})
	r.On(ghfake.Pulls, func(map[string]string) string {
		return ghfake.PullPage("["+ghfake.PullNode(20, "OPEN", "feat/issue-7", "2026-10-05T00:00:00Z", false)+","+
			ghfake.PullNode(19, "CLOSED", "feat/issue-51-2", "2026-10-04T00:00:00Z", true)+","+
			ghfake.ForkPullNode(21, "OPEN", "feat/issue-7", "2026-10-06T00:00:00Z", false)+","+
			ghfake.PullNode(18, "OPEN", "dependabot/npm", "2026-10-03T00:00:00Z", false)+"]", false, "")
	})
	r.On(ghfake.Refs, func(map[string]string) string {
		return ghfake.RefPage(false, "", "feat/issue-7", "main", "feat/issue-51")
	})
	r.On(ghfake.Git, func(map[string]string) string { return "feat/issue-52\nfeat/issue-7\n" })
	r.Comments(map[string]string{
		"277": ghfake.CommentConn(1, false, "", ghfake.CommentNode(1, "human", "User", "OWNER", "hello")),
		"7":   ghfake.CommentConn(0, false, ""),
	})

	b, err := read(t, r)
	if err != nil {
		t.Fatalf("ReadBoard() error = %v", err)
	}
	checkBoardFacts(t, b)
	checkBoardEdges(t, b)
	checkBoardWork(t, b)
}

func checkBoardFacts(t *testing.T, b *snapshot.Board) {
	t.Helper()
	if b.DefaultBranch != "main" || b.BaseSHA != "base1" || b.EpicBody != "plan" {
		t.Errorf("board = %+v, want main at base1 with the Epic body", b)
	}
	leaves := make([]int, 0, len(b.Leaves()))
	for _, l := range b.Leaves() {
		leaves = append(leaves, l.Number)
	}
	if fmt.Sprint(leaves) != "[1 51 52 7]" {
		t.Errorf("leaves = %v, want [1 51 52 7]: the container is not one", leaves)
	}
}

func checkBoardEdges(t *testing.T, b *snapshot.Board) {
	t.Helper()
	if got := b.Children[1].Blockers; len(got) != 1 || got[0].Number != 1 || got[0].State != "CLOSED" || got[0].Repo != "o/r" {
		t.Errorf("blockers of #5 = %+v", got)
	}
	if len(b.Comments) != 3 || len(b.Comments[277]) != 1 {
		t.Errorf("comments = %+v, want the Epic and the two open Issues", b.Comments)
	}
}

func checkBoardWork(t *testing.T, b *snapshot.Board) {
	t.Helper()
	if len(b.PRs) != 2 || b.PRs[1].State != snapshot.StateMerged || b.PRs[1].Branch != "feat/issue-51-2" {
		t.Errorf("PRs = %+v, want the two loop PRs, the merged one MERGED", b.PRs)
	}
	if fmt.Sprint(b.Branches) != "[feat/issue-51 feat/issue-52 feat/issue-7]" {
		t.Errorf("branches = %v, want the loop branches, sorted, once each", b.Branches)
	}
}

// TestNothingIsReadPerChildAndNoLabelIsRead guards BD-01, CMD-02, and GL-01: the number of
// queries does not grow with the Epic, and no query mentions a label.
func TestNothingIsReadPerChildAndNoLabelIsRead(t *testing.T) {
	t.Parallel()

	count := func(children int) (int, string) {
		r := ghfake.New()
		nodes := make([]string, 0, children)
		for i := 1; i <= children; i++ {
			nodes = append(nodes, ghfake.IssueNode(i, "OPEN", "", ""))
		}
		r.On(ghfake.Tree, func(map[string]string) string {
			return ghfake.EpicTree("", "["+strings.Join(nodes, ",")+"]", children, false, "")
		})
		r.Comments(nil)
		if _, err := read(t, r); err != nil {
			t.Fatalf("ReadBoard() error = %v", err)
		}
		return len(r.Calls()), r.Queries()
	}
	few, queries := count(3)
	many, _ := count(40)
	if few != many {
		t.Errorf("calls: %d for 3 children, %d for 40; want the same", few, many)
	}
	if strings.Contains(strings.ToLower(queries), "label") {
		t.Errorf("a query mentions a label:\n%s", queries)
	}
}

func TestCommentsAreReadInChunks(t *testing.T) {
	t.Parallel()

	r := ghfake.New()
	nodes := make([]string, 0, 120)
	for i := 1; i <= 120; i++ {
		nodes = append(nodes, ghfake.IssueNode(i, "OPEN", "", ""))
	}
	r.On(ghfake.Tree, func(map[string]string) string {
		return ghfake.EpicTree("", "["+strings.Join(nodes, ",")+"]", 120, false, "")
	})
	r.Comments(nil)
	b, err := read(t, r)
	if err != nil {
		t.Fatalf("ReadBoard() error = %v", err)
	}
	if len(b.Comments) != 121 {
		t.Errorf("comments for %d Issues, want 121", len(b.Comments))
	}
	if n := r.Count("comments(first: 100) { totalCount"); n != 3 {
		t.Errorf("comment queries = %d, want 3 (121 Issues in chunks of 50)", n)
	}
}

func TestTheEpicsChildrenArePaged(t *testing.T) {
	t.Parallel()

	r := ghfake.New()
	r.On(ghfake.Tree, func(v map[string]string) string {
		if v["after"] == "" {
			return ghfake.EpicTree("", "["+ghfake.IssueNode(1, "OPEN", "", "")+"]", 2, true, "c1")
		}
		if v["after"] != "c1" {
			t.Errorf("after = %q, want c1", v["after"])
		}
		return ghfake.EpicTree("", "["+ghfake.IssueNode(2, "OPEN", "", "")+"]", 2, false, "")
	})
	r.Comments(nil)
	b, err := read(t, r)
	if err != nil {
		t.Fatalf("ReadBoard() error = %v", err)
	}
	if len(b.Children) != 2 {
		t.Errorf("children = %d, want both pages", len(b.Children))
	}
}

func TestAPartialTreeIsNeverClassified(t *testing.T) {
	t.Parallel()

	tests := map[string]func(*ghfake.Router){
		"the listed count does not match what was read": func(r *ghfake.Router) {
			r.On(ghfake.Tree, func(map[string]string) string {
				return ghfake.EpicTree("", "["+ghfake.IssueNode(1, "OPEN", "", "")+"]", 2, false, "")
			})
		},
		"a next page without a cursor": func(r *ghfake.Router) {
			r.On(ghfake.Tree, func(map[string]string) string {
				return ghfake.EpicTree("", "["+ghfake.IssueNode(1, "OPEN", "", "")+"]", 2, true, "")
			})
		},
		"a next page that cannot be read": func(r *ghfake.Router) {
			r.On(ghfake.Tree, func(v map[string]string) string {
				if v["after"] == "" {
					return ghfake.EpicTree("", "["+ghfake.IssueNode(1, "OPEN", "", "")+"]", 2, true, "c1")
				}
				return `{"errors":[{"message":"boom"}],"data":null}`
			})
			r.Exit(ghfake.Tree, 1)
		},
		"a container with more sub-issues than one page": func(r *ghfake.Router) {
			r.On(ghfake.Tree, func(map[string]string) string {
				over := `{"totalCount":101,"pageInfo":{"hasNextPage":true,"endCursor":"x"},"nodes":[` + ghfake.IssueNode(51, "OPEN", "", "") + `]}`
				return ghfake.EpicTree("", "["+ghfake.IssueNode(5, "OPEN", "", over)+"]", 1, false, "")
			})
		},
		"a blockedBy count that does not add up": func(r *ghfake.Router) {
			r.On(ghfake.Tree, func(map[string]string) string {
				return ghfake.EpicTree("", "["+ghfake.IssueNode(1, "OPEN", ghfake.BlockerConn(2, `{"number":9,"state":"OPEN"}`), "")+"]", 1, false, "")
			})
		},
		"the Epic is missing": func(r *ghfake.Router) {
			r.On(ghfake.Tree, func(map[string]string) string {
				return `{"data":{"repository":{"defaultBranchRef":{"name":"main","target":{"oid":"b"}},"issue":null}}}`
			})
		},
		"data beside errors": func(r *ghfake.Router) {
			r.On(ghfake.Tree, func(map[string]string) string {
				return `{"data":{"repository":{"issue":null}},"errors":[{"type":"NOT_FOUND","message":"x"}]}`
			})
			r.Exit(ghfake.Tree, 1)
		},
	}
	for name, setup := range tests {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			r := ghfake.New()
			setup(r)
			r.Comments(nil)
			_, err := read(t, r)
			wantCode(t, err, exitcode.Unreadable)
		})
	}
}

func TestBlockersPastTheFirstPageAreReadOn(t *testing.T) {
	t.Parallel()

	r := ghfake.New()
	first := `{"totalCount":3,"pageInfo":{"hasNextPage":true,"endCursor":"b1"},"nodes":[{"number":8,"state":"OPEN","repository":{"nameWithOwner":"o/r"}}]}`
	r.On(ghfake.Tree, func(map[string]string) string {
		return ghfake.EpicTree("", "["+ghfake.IssueNode(1, "OPEN", first, "")+"]", 1, false, "")
	})
	r.On(ghfake.Blockers, func(v map[string]string) string {
		if v["id"] != "ID1" || v["after"] != "b1" {
			t.Errorf("vars = %v, want the id and cursor", v)
		}
		return `{"data":{"node":{"blockedBy":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"number":9,"state":"OPEN","repository":{"nameWithOwner":"o/r"}},{"number":10,"state":"CLOSED","repository":{"nameWithOwner":"o/r"}}]}}}}`
	})
	r.Comments(nil)
	b, err := read(t, r)
	if err != nil {
		t.Fatalf("ReadBoard() error = %v", err)
	}
	if got := b.Children[0].Blockers; len(got) != 3 || got[2].Number != 10 {
		t.Errorf("blockers = %+v, want all three", got)
	}
}

// TestATruncatedPRListingStopsClassification: a listing that says there is more and cannot be
// followed is an error, never a shorter list.
func TestATruncatedPRListingStopsClassification(t *testing.T) {
	t.Parallel()

	newer := ghfake.PullNode(20, "CLOSED", "feat/issue-1", "2026-10-09T00:00:00Z", false)
	tests := map[string]func(map[string]string) string{
		"the next page cannot be read": func(v map[string]string) string {
			if v["after"] == "" {
				return ghfake.PullPage("["+newer+"]", true, "p1")
			}
			return `{"errors":[{"message":"boom"}],"data":null}`
		},
		"the next page has no cursor": func(map[string]string) string { return ghfake.PullPage("["+newer+"]", true, "") },
		"the repository is missing":   func(map[string]string) string { return `{"data":{"repository":null}}` },
	}
	for name, h := range tests {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			r := ghfake.New()
			r.On(ghfake.Tree, func(map[string]string) string {
				return ghfake.EpicTree("", "["+ghfake.IssueNode(1, "OPEN", "", "")+"]", 1, false, "")
			})
			r.On(ghfake.Pulls, h)
			r.Exit(ghfake.Pulls, 0)
			r.Comments(nil)
			_, err := read(t, r)
			wantCode(t, err, exitcode.Unreadable)
		})
	}
}

func TestPRsArePagedOnlyBackToTheOldestIssue(t *testing.T) {
	t.Parallel()

	// The Epic was created 2026-10-01 and its child 2026-10-02, so nothing older matters.
	r := ghfake.New()
	r.On(ghfake.Tree, func(map[string]string) string {
		return ghfake.EpicTree("", "["+ghfake.IssueNode(1, "OPEN", "", "")+"]", 1, false, "")
	})
	r.On(ghfake.Pulls, func(v map[string]string) string {
		switch v["after"] {
		case "":
			return ghfake.PullPage("["+ghfake.PullNode(30, "OPEN", "feat/issue-1", "2026-10-09T00:00:00Z", false)+"]", true, "p1")
		case "p1":
			return ghfake.PullPage("["+ghfake.PullNode(29, "CLOSED", "feat/issue-1", "2026-10-03T00:00:00Z", false)+","+
				ghfake.PullNode(5, "CLOSED", "feat/issue-1", "2026-09-01T00:00:00Z", false)+"]", true, "p2")
		default:
			t.Errorf("read past the oldest Issue: after = %q", v["after"])
			return ghfake.PullPage("[]", false, "")
		}
	})
	r.Comments(nil)
	b, err := read(t, r)
	if err != nil {
		t.Fatalf("ReadBoard() error = %v", err)
	}
	if len(b.PRs) != 3 {
		t.Errorf("PRs = %d, want the three read before the cut-off page ended", len(b.PRs))
	}
}

func TestCommentsPastTheFirstPageAreReadOn(t *testing.T) {
	t.Parallel()

	r := ghfake.New()
	r.On(ghfake.Tree, func(map[string]string) string {
		return ghfake.EpicTree("", "["+ghfake.IssueNode(1, "OPEN", "", "")+"]", 1, false, "")
	})
	r.Comments(map[string]string{"1": ghfake.CommentConn(3, true, "c1", ghfake.CommentNode(1, "human", "User", "OWNER", "a"), ghfake.CommentNode(2, "human", "User", "OWNER", "b"))})
	r.On(ghfake.MoreComments, func(v map[string]string) string {
		if v["number"] != "1" || v["after"] != "c1" {
			t.Errorf("vars = %v", v)
		}
		return `{"data":{"repository":{"issue":{"number":1,"comments":` + ghfake.CommentConn(3, false, "", ghfake.CommentNode(3, "human", "User", "OWNER", "c")) + `}}}}`
	})
	b, err := read(t, r)
	if err != nil {
		t.Fatalf("ReadBoard() error = %v", err)
	}
	if len(b.Comments[1]) != 3 {
		t.Errorf("comments = %d, want all 3", len(b.Comments[1]))
	}
}

func TestACommentCountThatDoesNotAddUpIsPartial(t *testing.T) {
	t.Parallel()

	r := ghfake.New()
	r.On(ghfake.Tree, func(map[string]string) string {
		return ghfake.EpicTree("", "["+ghfake.IssueNode(1, "OPEN", "", "")+"]", 1, false, "")
	})
	r.Comments(map[string]string{"1": ghfake.CommentConn(2, false, "", ghfake.CommentNode(1, "human", "User", "OWNER", "a"))})
	_, err := read(t, r)
	wantCode(t, err, exitcode.Unreadable)
}

func TestAnIssueMissingFromTheCommentsReadIsPartial(t *testing.T) {
	t.Parallel()

	r := ghfake.New()
	r.On(ghfake.Tree, func(map[string]string) string {
		return ghfake.EpicTree("", "["+ghfake.IssueNode(1, "OPEN", "", "")+"]", 1, false, "")
	})
	r.On("comments", func(map[string]string) string {
		return `{"data":{"repository":{"i277":{"number":277,"comments":` + ghfake.CommentConn(0, false, "") + `},"i1":null}}}`
	})
	_, err := read(t, r)
	wantCode(t, err, exitcode.Unreadable)
}

func TestABotLoginCarriesItsSuffix(t *testing.T) {
	t.Parallel()

	r := ghfake.New()
	r.On(ghfake.Tree, func(map[string]string) string {
		return ghfake.EpicTree("", "["+ghfake.IssueNode(1, "OPEN", "", "")+"]", 1, false, "")
	})
	r.Comments(map[string]string{"277": ghfake.CommentConn(2, false, "",
		ghfake.CommentNode(1, "github-actions", "Bot", "NONE", "x"), ghfake.CommentNode(2, "alice", "User", "OWNER", "y"))})
	b, err := read(t, r)
	if err != nil {
		t.Fatalf("ReadBoard() error = %v", err)
	}
	if got := b.Comments[277][0].Author; got != "github-actions[bot]" {
		t.Errorf("bot author = %q, want the [bot] suffix REST reports", got)
	}
	if got := b.Comments[277][1].Author; got != "alice" {
		t.Errorf("user author = %q, want alice", got)
	}
}

const leaseFields = `,"token":"tok","host":"h","pid":0,"started_at":"a","renewed_at":"b"`

func TestTheLoopsOwnStateIsDecodedFromItsOwnComments(t *testing.T) {
	t.Parallel()

	r := ghfake.New()
	r.On(ghfake.Tree, func(map[string]string) string {
		return ghfake.EpicTree("", "["+ghfake.IssueNode(1, "OPEN", "", "")+"]", 1, false, "")
	})
	r.Comments(map[string]string{
		"277": ghfake.CommentConn(2, false, "",
			ghfake.CommentNode(1, "loop", "User", "OWNER", ghfake.StateBody("lease", "lease", leaseFields)),
			// Planted by someone else: a marker on anyone else's comment is ignored.
			ghfake.CommentNode(2, "mallory", "User", "NONE", ghfake.StateBody("lease", "lease", `,"token":"x","host":"h","pid":9,"started_at":"a","renewed_at":"b"`))),
	})
	b, err := read(t, r)
	if err != nil {
		t.Fatalf("ReadBoard() error = %v", err)
	}
	if b.Lease == nil || b.Lease.Token != "tok" || b.Lease.PID != 0 {
		t.Errorf("lease = %+v, want the loop's own", b.Lease)
	}
	if b.PostMerge != nil || b.Ledger != nil {
		t.Errorf("record = %+v, ledger = %+v, want none", b.PostMerge, b.Ledger)
	}
}

func TestProtocolViolationsStopTheRead(t *testing.T) {
	t.Parallel()

	tests := map[string][]string{
		"a v1 marker on the Epic": {ghfake.CommentNode(1, "loop", "User", "OWNER", "<!-- orchestrate-epic:ledger -->\nbody")},
		"two states for one key": {
			ghfake.CommentNode(1, "loop", "User", "OWNER", ghfake.StateBody("lease", "lease", leaseFields)),
			ghfake.CommentNode(2, "loop", "User", "OWNER", ghfake.StateBody("lease", "lease", leaseFields)),
		},
		"a state of the wrong entity": {ghfake.CommentNode(1, "loop", "User", "OWNER", ghfake.StateBody("lease", "ledger", leaseFields))},
		"bad JSON":                    {ghfake.CommentNode(1, "loop", "User", "OWNER", "<!-- oe:v2 state lease -->\n```json\n{nope\n```\n")},
		"another protocol version":    {ghfake.CommentNode(1, "loop", "User", "OWNER", "<!-- oe:v3 state lease -->\n```json\n{}\n```\n")},
	}
	for name, nodes := range tests {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			r := ghfake.New()
			r.On(ghfake.Tree, func(map[string]string) string {
				return ghfake.EpicTree("", "["+ghfake.IssueNode(1, "OPEN", "", "")+"]", 1, false, "")
			})
			r.Comments(map[string]string{"277": ghfake.CommentConn(len(nodes), false, "", nodes...)})
			_, err := read(t, r)
			wantCode(t, err, exitcode.Protocol)
		})
	}

	t.Run("a v1 marker by someone else is ignored", func(t *testing.T) {
		t.Parallel()
		r := ghfake.New()
		r.On(ghfake.Tree, func(map[string]string) string {
			return ghfake.EpicTree("", "["+ghfake.IssueNode(1, "OPEN", "", "")+"]", 1, false, "")
		})
		r.Comments(map[string]string{"277": ghfake.CommentConn(1, false, "", ghfake.CommentNode(1, "mallory", "User", "NONE", "<!-- orchestrate-epic:ledger -->"))})
		if _, err := read(t, r); err != nil {
			t.Errorf("ReadBoard() error = %v, want it ignored", err)
		}
	})

	t.Run("a v1 marker on a child Issue", func(t *testing.T) {
		t.Parallel()
		r := ghfake.New()
		r.On(ghfake.Tree, func(map[string]string) string {
			return ghfake.EpicTree("", "["+ghfake.IssueNode(1, "OPEN", "", "")+"]", 1, false, "")
		})
		r.Comments(map[string]string{"1": ghfake.CommentConn(1, false, "", ghfake.CommentNode(1, "loop", "User", "OWNER", "<!-- orchestrate-epic-state -->\n- cycle: 0"))})
		_, err := read(t, r)
		wantCode(t, err, exitcode.Protocol)
	})
}

func TestThePostMergeRecordNamesThePullRequestToJudge(t *testing.T) {
	t.Parallel()

	r := ghfake.New()
	r.On(ghfake.Tree, func(map[string]string) string {
		return ghfake.EpicTree("", "["+ghfake.IssueNode(1, "CLOSED", "", "")+"]", 1, false, "")
	})
	r.Comments(map[string]string{"277": ghfake.CommentConn(1, false, "", ghfake.CommentNode(1, "loop", "User", "OWNER", ghfake.StateBody("post-merge", "post-merge",
		`,"pr":7,"issue":1,"reviewed_sha":"h","verified_base":"b","phase":"merged","merge_sha":"m111","requested_at":"t"`)))})
	r.On(ghfake.MergePull, func(v map[string]string) string {
		if v["num"] != "7" {
			t.Errorf("vars = %v, want PR 7", v)
		}
		return `{"data":{"repository":{"pullRequest":{"number":7,"state":"MERGED","mergedAt":"2026-10-19T00:00:00Z","mergeCommit":{"oid":"m111","statusCheckRollup":null}}}}}`
	})
	b, err := read(t, r)
	if err != nil {
		t.Fatalf("ReadBoard() error = %v", err)
	}
	if b.PostMerge == nil || b.PostMerge.CommentID != 1 || b.PostMergePull == nil || b.PostMergePull.Number != 7 {
		t.Errorf("record = %+v, pull = %+v, want PR 7 read", b.PostMerge, b.PostMergePull)
	}
	if want := time.Date(2026, 10, 19, 0, 5, 0, 0, time.UTC); !b.Now.Equal(want) {
		t.Errorf("now = %v, want GitHub's clock, %v", b.Now, want)
	}
}

func TestNoMergeRecordedReadsNeitherPullNorClock(t *testing.T) {
	t.Parallel()

	r := ghfake.New()
	r.On(ghfake.Tree, func(map[string]string) string {
		return ghfake.EpicTree("", "["+ghfake.IssueNode(1, "OPEN", "", "")+"]", 1, false, "")
	})
	r.Comments(nil)
	b, err := read(t, r)
	if err != nil {
		t.Fatalf("ReadBoard() error = %v", err)
	}
	if !b.Now.IsZero() || b.PostMergePull != nil || r.Count("meta") != 0 || r.Count("mergeCommit") != 0 {
		t.Errorf("board read a pull or the clock without a record: %+v", b)
	}
}

func TestALocalCheckoutOfAnotherRepoSaysNothingAboutThisOne(t *testing.T) {
	t.Parallel()

	r := ghfake.New()
	r.SetOrigin("git@github.com:someone/else.git")
	r.On(ghfake.Tree, func(map[string]string) string {
		return ghfake.EpicTree("", "["+ghfake.IssueNode(1, "OPEN", "", "")+"]", 1, false, "")
	})
	r.On(ghfake.Git, func(map[string]string) string { return "feat/issue-1\n" })
	r.Comments(nil)
	b, err := read(t, r)
	if err != nil {
		t.Fatalf("ReadBoard() error = %v", err)
	}
	if len(b.Branches) != 0 {
		t.Errorf("branches = %v, want the other repository's local branches left out", b.Branches)
	}
	if r.Count("for-each-ref") != 0 {
		t.Error("the other repository's branches were listed")
	}
}

func TestLocalBranchesAreRequired(t *testing.T) {
	t.Parallel()

	r := ghfake.New()
	r.On(ghfake.Tree, func(map[string]string) string {
		return ghfake.EpicTree("", "["+ghfake.IssueNode(1, "OPEN", "", "")+"]", 1, false, "")
	})
	r.Comments(nil)
	r.Exit(ghfake.Git, 128)
	_, err := read(t, r)
	wantCode(t, err, exitcode.Unreadable)
}

func TestIssueOfBranch(t *testing.T) {
	t.Parallel()

	tests := map[string]int{
		"feat/issue-12": 12, "feat/issue-12-2": 12, "feat/issue-3-retry-x": 3,
		"feat/issue-": 0, "feat/issue-x": 0, "feat/issue-12x": 0, "fix/issue-12": 0, "main": 0, "feat/issue-0": 0,
	}
	for name, want := range tests {
		got, ok := snapshot.IssueOfBranch(name)
		if got != want || ok != (want > 0) {
			t.Errorf("IssueOfBranch(%q) = %d, %v; want %d", name, got, ok, want)
		}
	}
}

func TestNow(t *testing.T) {
	t.Parallel()

	for name, out := range map[string]string{
		"no header":  "HTTP/2.0 200 OK\r\n\r\n{}",
		"bad header": "HTTP/2.0 200 OK\r\nDate: yesterday\r\n\r\n{}",
	} {
		c := gh.New(runner.NewSnapshot([]runner.Call{{
			Argv: []string{"gh", "api", "--hostname", "github.com", "-i", "meta"}, Stdout: out, Stderr: "", ExitCode: 0,
		}}), false)
		_, err := snapshot.Now(t.Context(), c)
		if exitcode.CodeOf(err) != exitcode.Unreadable {
			t.Errorf("%s: exit = %d (%v), want unreadable", name, exitcode.CodeOf(err), err)
		}
	}
	c := gh.New(runner.NewSnapshot([]runner.Call{{
		Argv:   []string{"gh", "api", "--hostname", "github.com", "-i", "meta"},
		Stdout: "HTTP/2.0 200 OK\r\nDate: Mon, 19 Oct 2026 00:05:00 GMT\r\nServer: x\r\n\r\n{}", Stderr: "", ExitCode: 0,
	}}), false)
	got, err := snapshot.Now(t.Context(), c)
	if err != nil || !got.Equal(time.Date(2026, 10, 19, 0, 5, 0, 0, time.UTC)) {
		t.Errorf("Now() = %v, %v", got, err)
	}
}

// TestReadBranchPRsListsEveryStateOfOneBranch shows that a branch's open, closed, and merged pull requests are all read, so a publish can link the open one and refuse a second.
// A pull request from a fork that uses the same branch name is not the branch's.
func TestReadBranchPRsListsEveryStateOfOneBranch(t *testing.T) {
	t.Parallel()

	r := ghfake.New()
	var asked []string
	r.On(ghfake.PullsByHead, func(v map[string]string) string {
		asked = append(asked, v["owner"]+"/"+v["name"]+"@"+v["branch"])
		return ghfake.PullPage("["+ghfake.PullNode(20, "OPEN", "feat/issue-7", "2026-10-05T00:00:00Z", false)+","+
			ghfake.PullNode(19, "CLOSED", "feat/issue-7", "2026-10-04T00:00:00Z", false)+","+
			ghfake.PullNode(18, "CLOSED", "feat/issue-7", "2026-10-03T00:00:00Z", true)+","+
			ghfake.ForkPullNode(21, "OPEN", "feat/issue-7", "2026-10-06T00:00:00Z", false)+"]", false, "")
	})
	got, err := snapshot.ReadBranchPRs(t.Context(), gh.New(r, false), "o/r", "feat/issue-7")
	if err != nil {
		t.Fatal(err)
	}
	summary := make([]string, 0, len(got))
	for _, pr := range got {
		summary = append(summary, fmt.Sprintf("%d:%s:%s", pr.Number, pr.State, pr.HeadSHA))
	}
	if want := "[20:OPEN:sha20 19:CLOSED:sha19 18:MERGED:sha18]"; fmt.Sprint(summary) != want {
		t.Errorf("pull requests = %v, want %s", summary, want)
	}
	if fmt.Sprint(asked) != "[o/r@feat/issue-7]" {
		t.Errorf("asked = %v, want one query for o/r@feat/issue-7", asked)
	}
}

// TestReadBranchPRsFollowsPagesAndRefusesATruncatedListing shows that a listing is complete or it is an error, so a publish never creates a second pull request on a page it could not read.
func TestReadBranchPRsFollowsPagesAndRefusesATruncatedListing(t *testing.T) {
	t.Parallel()

	paged := ghfake.New()
	paged.On(ghfake.PullsByHead, func(v map[string]string) string {
		if v["after"] == "" {
			return ghfake.PullPage("["+ghfake.PullNode(20, "CLOSED", "feat/issue-7", "2026-10-05T00:00:00Z", false)+"]", true, "c1")
		}
		return ghfake.PullPage("["+ghfake.PullNode(21, "OPEN", "feat/issue-7", "2026-10-06T00:00:00Z", false)+"]", false, "")
	})
	got, err := snapshot.ReadBranchPRs(t.Context(), gh.New(paged, false), "o/r", "feat/issue-7")
	if err != nil || len(got) != 2 || got[1].Number != 21 {
		t.Errorf("paged listing = %+v, %v; want both pages", got, err)
	}

	cut := ghfake.New()
	cut.On(ghfake.PullsByHead, func(map[string]string) string {
		return ghfake.PullPage("["+ghfake.PullNode(20, "OPEN", "feat/issue-7", "2026-10-05T00:00:00Z", false)+"]", true, "")
	})
	_, err = snapshot.ReadBranchPRs(t.Context(), gh.New(cut, false), "o/r", "feat/issue-7")
	wantCode(t, err, exitcode.Unreadable)
}
