package snapshot

import (
	"context"
	"fmt"
	"net/http"
	"regexp"
	"slices"
	"time"

	"github.com/maro114510/skills/oe/internal/exitcode"
	"github.com/maro114510/skills/oe/internal/gh"
	"github.com/maro114510/skills/oe/internal/inputs"
	"github.com/maro114510/skills/oe/internal/protocol"
	"github.com/maro114510/skills/oe/internal/state"
)

// PostMergeRecord is the post-merge record and the comment it was read from.
type PostMergeRecord struct {
	CommentID int64
	State     state.PostMerge
}

// Board is the complete read of an Epic: its Issues, their pull requests and branches, every
// comment of the Epic and of each open dispatchable Issue, and the loop's own state decoded
// from them. It exists only if every read was full. Nothing in it is a guess.
type Board struct {
	Repo          string
	Epic          int
	Me            string
	DefaultBranch string
	// BaseSHA is the head of the default branch.
	BaseSHA string
	// Now is GitHub's clock, read only when a merge is recorded and its checks are judged.
	Now      time.Time
	EpicBody string
	Children []Issue
	PRs      []PR
	// Branches are the loop branches, on origin and local, sorted.
	Branches []string
	// Comments are the comments of the Epic and of every open dispatchable Issue, by number.
	Comments map[int][]Comment
	// Notes are the keys of the loop's own notes, by number.
	Notes map[int]map[string]bool
	// IssueStates are the decoded Issue states of open dispatchable Issues.
	IssueStates map[int]*state.Issue
	Lease       *state.Lease
	Ledger      *state.Ledger
	PostMerge   *PostMergeRecord
	// PostMergePull is the recorded PR with the checks on its merge commit.
	PostMergePull *MergePull
}

// Leaves returns the dispatchable Issues: every child without sub-issues, and every
// grandchild of a container. A container is never dispatchable.
func (b *Board) Leaves() []Issue {
	var out []Issue
	for _, ch := range b.Children {
		if len(ch.Children) == 0 {
			out = append(out, ch)
			continue
		}
		out = append(out, ch.Children...)
	}
	return out
}

// ReadBoard reads the whole board with a fixed set of queries that does not grow with the
// Epic: the Issue tree with its edges, the pull requests, the branches, one aliased query for
// the comments, and the post-merge pull request. It reads no label, and nothing per child.
func ReadBoard(ctx context.Context, c *gh.Client, in inputs.Inputs) (*Board, error) {
	t, err := readTree(ctx, c, in)
	if err != nil {
		return nil, err
	}
	b := &Board{
		Repo: in.Repo, Epic: in.Epic, Me: in.Me, DefaultBranch: t.branch, BaseSHA: t.baseSHA, Now: time.Time{},
		EpicBody: t.body, Children: t.children, PRs: nil, Branches: nil,
		Comments: nil, Notes: map[int]map[string]bool{}, IssueStates: map[int]*state.Issue{},
		Lease: nil, Ledger: nil, PostMerge: nil, PostMergePull: nil,
	}
	if b.PRs, err = readPRs(ctx, c, in.Repo, oldest(t.createdAt, b.Children)); err != nil {
		return nil, err
	}
	if b.Branches, err = readBranches(ctx, c, in.Repo); err != nil {
		return nil, err
	}
	if b.Comments, err = readComments(ctx, c, in.Repo, commentTargets(in.Epic, b.Leaves())); err != nil {
		return nil, err
	}
	if err := b.decode(); err != nil {
		return nil, err
	}
	if err := b.readMerge(ctx, c); err != nil {
		return nil, err
	}
	return b, nil
}

// ReadEpicState reads only what the default-branch health needs: the Epic's own comments and
// the state decoded from them, then the recorded pull request and the clock. It reads no Issue.
func ReadEpicState(ctx context.Context, c *gh.Client, in inputs.Inputs) (*Board, error) {
	b := &Board{
		Repo: in.Repo, Epic: in.Epic, Me: in.Me, DefaultBranch: in.DefaultBranch, BaseSHA: "", Now: time.Time{},
		EpicBody: "", Children: nil, PRs: nil, Branches: nil,
		Comments: nil, Notes: map[int]map[string]bool{}, IssueStates: map[int]*state.Issue{},
		Lease: nil, Ledger: nil, PostMerge: nil, PostMergePull: nil,
	}
	var err error
	if b.Comments, err = readComments(ctx, c, in.Repo, []int{in.Epic}); err != nil {
		return nil, err
	}
	if err := b.decode(); err != nil {
		return nil, err
	}
	if err := b.readMerge(ctx, c); err != nil {
		return nil, err
	}
	return b, nil
}

// readMerge reads the recorded pull request and the clock, when a merge is recorded.
func (b *Board) readMerge(ctx context.Context, c *gh.Client) error {
	if b.PostMerge == nil || b.PostMerge.State.PR <= 0 {
		return nil
	}
	var err error
	if b.PostMergePull, err = ReadMergePull(ctx, c, b.Repo, b.PostMerge.State.PR); err != nil {
		return err
	}
	b.Now, err = Now(ctx, c)
	return err
}

// commentTargets are the Epic and every open dispatchable Issue.
func commentTargets(epic int, leaves []Issue) []int {
	out := []int{epic}
	for _, l := range leaves {
		if l.State == StateOpen {
			out = append(out, l.Number)
		}
	}
	slices.Sort(out)
	return slices.Compact(out)
}

// oldest is the earliest creation time among the Epic and every Issue under it. A pull request
// for an Issue cannot be older than the Issue.
func oldest(epicCreated string, children []Issue) string {
	low := epicCreated
	var walk func([]Issue)
	walk = func(list []Issue) {
		for _, i := range list {
			if i.CreatedAt != "" && (low == "" || i.CreatedAt < low) {
				low = i.CreatedAt
			}
			walk(i.Children)
		}
	}
	walk(children)
	return low
}

// decode reads the loop's own state out of the comments. A v1 marker, an unknown version, bad
// JSON, a key that differs from its marker, or two states for one key stops with exit 6.
func (b *Board) decode() error {
	numbers := make([]int, 0, len(b.Comments))
	for number := range b.Comments {
		numbers = append(numbers, number)
	}
	slices.Sort(numbers)
	for _, number := range numbers {
		comments := b.Comments[number]
		pcs := make([]protocol.Comment, 0, len(comments))
		for _, c := range comments {
			pcs = append(pcs, c.Protocol())
		}
		idx, err := protocol.Scan(pcs, b.Me)
		if err != nil {
			return fmt.Errorf("#%d: %w", number, err)
		}
		notes := make(map[string]bool, len(idx.Notes))
		for k := range idx.Notes {
			notes[k] = true
		}
		b.Notes[number] = notes
		if number == b.Epic {
			if err := b.decodeEpic(idx); err != nil {
				return err
			}
			continue
		}
		c, ok := idx.States[state.IssueKey(number)]
		if !ok {
			continue
		}
		var st state.Issue
		if err := decodeEntity(c, &st, state.EntityIssue); err != nil {
			return fmt.Errorf("#%d: %w", number, err)
		}
		b.IssueStates[number] = &st
	}
	return nil
}

func (b *Board) decodeEpic(idx protocol.Index) error {
	if c, ok := idx.States[state.KeyLease]; ok {
		b.Lease = new(state.Lease)
		if err := decodeEntity(c, b.Lease, state.EntityLease); err != nil {
			return err
		}
	}
	if c, ok := idx.States[state.KeyLedger]; ok {
		b.Ledger = new(state.Ledger)
		if err := decodeEntity(c, b.Ledger, state.EntityLedger); err != nil {
			return err
		}
	}
	if c, ok := idx.States[state.KeyPostMerge]; ok {
		rec := &PostMergeRecord{CommentID: c.ID, State: zeroPostMerge()}
		if err := decodeEntity(c, &rec.State, state.EntityPostMerge); err != nil {
			return err
		}
		b.PostMerge = rec
	}
	return nil
}

func zeroPostMerge() state.PostMerge {
	var pm state.PostMerge
	return pm
}

// decodeEntity decodes a state comment and checks it holds the entity expected for its key.
func decodeEntity(c protocol.Comment, s protocol.State, entity string) error {
	if _, err := protocol.DecodeState(c.Body, s); err != nil {
		return fmt.Errorf("comment %d: %w", c.ID, err)
	}
	if got := s.StateEnvelope().Entity; got != entity {
		return exitcode.New(exitcode.Protocol, fmt.Sprintf("comment %d: state %q is a %q, not a %q", c.ID, s.StateEnvelope().Key, got, entity))
	}
	return nil
}

var dateHeaderRe = regexp.MustCompile(`(?im)^date:[ \t]*(.+?)[ \t]*\r?$`)

// Now reads the time from GitHub's clock rather than the machine's, so a recorded snapshot
// replays to the same time and the same output on every run.
func Now(ctx context.Context, c *gh.Client) (time.Time, error) {
	out, err := c.Read(ctx, "api", "-i", "meta")
	if err != nil {
		return time.Time{}, err
	}
	m := dateHeaderRe.FindSubmatch(out)
	if m == nil {
		return time.Time{}, exitcode.New(exitcode.Unreadable, "GitHub's response carried no Date header")
	}
	t, err := http.ParseTime(string(m[1]))
	if err != nil {
		return time.Time{}, exitcode.Wrap(exitcode.Unreadable, err, "GitHub's Date header cannot be read")
	}
	return t.UTC(), nil
}
