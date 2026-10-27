package cmd

import (
	"cmp"
	"context"
	"fmt"

	"github.com/spf13/cobra"

	"github.com/maro114510/skills/oe/internal/board"
	"github.com/maro114510/skills/oe/internal/coord"
	"github.com/maro114510/skills/oe/internal/exitcode"
	"github.com/maro114510/skills/oe/internal/readiness"
	"github.com/maro114510/skills/oe/internal/round"
	"github.com/maro114510/skills/oe/internal/snapshot"
)

// The round subcommands decide what an invocation does between its landing passes, contract §20.
// Each is a coordination subcommand: it refuses --snapshot, takes the Epic's lock, and confirms
// the lease. One lease session is one invocation, and what it keeps lives in a host-local file
// named by the token's digest, so only the session that holds the lease reads or writes it.

func newRoundCmd(env Env, g *globals) *cobra.Command {
	return newGroup("round", "Schedule rounds, bound polling, and decide continuation and completion",
		newRoundPlanCmd(env, g), newRoundDeferCmd(env, g), newRoundPollCmd(env, g), newRoundNextCmd(env, g),
		newRoundNotifyCmd(env, g), newRoundCompleteCmd(env, g), newRoundCleanupCmd(env, g))
}

// roundCmd builds a round subcommand whose body runs inside the coordination envelope. check
// runs first, before any call, so a usage error never reaches GitHub.
func roundCmd(env Env, g *globals, use, short string, flags func(*cobra.Command), check func() error, body func(context.Context, *cobra.Command, session) error) *cobra.Command {
	var token string
	c := &cobra.Command{
		Use:   use,
		Short: short,
		Args:  cobra.NoArgs,
		RunE: func(c *cobra.Command, _ []string) error {
			if check != nil {
				if err := check(); err != nil {
					return err
				}
			}
			return g.coordinate(c, env, token, false, func(ctx context.Context, ss session) error {
				return body(ctx, c, ss)
			})
		},
	}
	if flags != nil {
		flags(c)
	}
	tokenFlag(c, &token)
	return c
}

// roundState is one invocation's session file, loaded for a command that reads or writes it.
type roundState struct {
	s    *round.Session
	path string
}

func loadRound(env Env, ss session) (roundState, error) {
	dir, err := coord.StateDir(env.getenv())
	if err != nil {
		return roundState{}, err
	}
	path := round.Path(dir, ss.in.Repo, ss.in.Epic, ss.token)
	s, err := round.Load(path)
	return roundState{s: s, path: path}, err
}

func (r roundState) save() error { return r.s.Save(r.path) }

// scheduleOf is the schedule of a fresh classification, for this invocation's deferrals.
func scheduleOf(ss session, res board.Result, b *snapshot.Board, rs roundState) round.Plan {
	return round.Schedule(round.Input{
		Board: res, FixInFlight: round.FixInFlight(b), MaxParallel: ss.in.MaxParallel, Deferred: rs.s.DeferredSet(),
	})
}

func newRoundPlanCmd(env Env, g *globals) *cobra.Command {
	return roundCmd(env, g, "plan", "Begin a round: the work to start, the candidates to land, and what is left out", nil, nil,
		func(ctx context.Context, c *cobra.Command, ss session) error {
			rs, err := loadRound(env, ss)
			if err != nil {
				return err
			}
			res, b, err := classifyBoard(ctx, ss)
			if err != nil {
				return err
			}
			plan := scheduleOf(ss, res, b, rs)
			round.BeginRound(rs.s, round.ObservationOf(b, res).Mark, round.Verifying(res))
			if err := rs.save(); err != nil {
				return err
			}
			return printJSON(c.OutOrStdout(), plan)
		})
}

func newRoundDeferCmd(env Env, g *globals) *cobra.Command {
	var n int
	var reason string
	check := func() error {
		if err := needIssue(n); err != nil {
			return err
		}
		if _, ok := round.ParseReason(reason); !ok {
			return exitcode.New(exitcode.Usage, "--reason must be blocked, stale, or gave-up-turn")
		}
		return nil
	}
	return roundCmd(env, g, "defer", "Leave an Issue for the next invocation", func(c *cobra.Command) {
		c.Flags().IntVar(&n, "issue", 0, "child Issue `number`")
		c.Flags().StringVar(&reason, "reason", "", "`blocked`, `stale`, or `gave-up-turn`")
	}, check, func(_ context.Context, c *cobra.Command, ss session) error {
		rs, err := loadRound(env, ss)
		if err != nil {
			return err
		}
		parsed, _ := round.ParseReason(reason)
		rs.s.Defer(n, parsed)
		if err := rs.save(); err != nil {
			return err
		}
		return printJSON(c.OutOrStdout(), struct {
			Issue    int              `json:"issue"`
			Deferred []round.Deferral `json:"deferred"`
		}{Issue: n, Deferred: rs.s.Deferred})
	})
}

// waiters reads each landing candidate's own readiness, so a poll waits on what the repository
// says and never on a guess. A candidate that cannot be read stops the poll before it counts.
func waiters(ctx context.Context, ss session, res board.Result, plan round.Plan) ([]round.Waiter, error) {
	prOf := map[int]int{}
	for _, i := range res.Issues {
		prOf[i.Number] = i.PR
	}
	var out []round.Waiter
	for _, c := range plan.Landing {
		if c.Stale {
			out = append(out, round.Waiter{Issue: c.Issue, PR: c.PR, Head: c.Head, Stale: true, Readiness: readiness.Result{}})
			continue
		}
		req, err := snapshot.ReadPullRequest(ctx, ss.client, ss.in.Repo, c.PR)
		if err != nil {
			return nil, err
		}
		rd := readiness.Classify(req)
		if rd.Unreadable {
			// Classify reports a signal it cannot read as a result, which is a failed read here, never a wait or a hold.
			return nil, exitcode.New(exitcode.Unreadable, fmt.Sprintf("pull request #%d cannot be read, so nothing is polled: %s", c.PR, rd.Reason))
		}
		out = append(out, round.Waiter{Issue: c.Issue, PR: c.PR, Head: cmp.Or(rd.Head, c.Head), Stale: false, Readiness: rd})
	}
	for _, n := range plan.StaleWaiting {
		out = append(out, round.Waiter{Issue: n, PR: prOf[n], Head: "", Stale: true, Readiness: readiness.Result{}})
	}
	return out, nil
}

func newRoundPollCmd(env Env, g *globals) *cobra.Command {
	return roundCmd(env, g, "poll", "Decide what landing does after a pass: land again, sleep, stop, or settle", nil, nil,
		func(ctx context.Context, c *cobra.Command, ss session) error {
			rs, err := loadRound(env, ss)
			if err != nil {
				return err
			}
			res, b, err := classifyBoard(ctx, ss)
			if err != nil {
				return err
			}
			candidates, err := waiters(ctx, ss, res, scheduleOf(ss, res, b, rs))
			if err != nil {
				return err
			}
			out := round.Poll(rs.s, round.ObservationOf(b, res), candidates)
			if err := rs.save(); err != nil {
				return err
			}
			return printJSON(c.OutOrStdout(), out)
		})
}

func newRoundNextCmd(env Env, g *globals) *cobra.Command {
	return roundCmd(env, g, "next", "Decide, from a fresh read, whether the session goes on into a new round", nil, nil,
		func(ctx context.Context, c *cobra.Command, ss session) error {
			rs, err := loadRound(env, ss)
			if err != nil {
				return err
			}
			// The session alone shows whether a round began, so refuse before a read can fail first.
			if err := round.RequireRound(rs.s); err != nil {
				return err
			}
			res, b, err := classifyBoard(ctx, ss)
			if err != nil {
				return err
			}
			out, err := round.Next(rs.s, round.ObservationOf(b, res))
			if err != nil {
				return err
			}
			if err := rs.save(); err != nil {
				return err
			}
			return printJSON(c.OutOrStdout(), out)
		})
}

func newRoundNotifyCmd(env Env, g *globals) *cobra.Command {
	return roundCmd(env, g, "notify", "Post the notes the board proposes through the single comment writer", nil, nil,
		func(ctx context.Context, c *cobra.Command, ss session) error {
			res, _, err := classifyBoard(ctx, ss)
			if err != nil {
				return err
			}
			out, err := round.Notify(ctx, ss.s, res.Notifications)
			return emit(c, out, err)
		})
}

// completeOut is what a completion decided. Report holds what the comment would say.
type completeOut struct {
	Complete      bool               `json:"complete"`
	Posted        bool               `json:"posted"`
	AlreadyPosted bool               `json:"already_posted"`
	Unfinished    []round.Unfinished `json:"unfinished"`
	Note          *coord.NoteResult  `json:"note,omitempty"`
	Report        round.Report       `json:"report"`
}

// completionKey is the dedup key of the completion note, contract §7.
const completionKey = "completion"

func newRoundCompleteCmd(env Env, g *globals) *cobra.Command {
	return roundCmd(env, g, "complete", "Post the completion comment once, when every Issue is done or dropped", nil, nil,
		func(ctx context.Context, c *cobra.Command, ss session) error {
			res, b, err := classifyBoard(ctx, ss)
			if err != nil {
				return err
			}
			leaves := b.Leaves()
			numbers := make([]int, 0, len(leaves))
			for _, l := range leaves {
				numbers = append(numbers, l.Number)
			}
			comments, err := snapshot.ReadComments(ctx, ss.client, ss.in.Repo, numbers)
			if err != nil {
				return err
			}
			rep, err := round.Assess(res, b, comments)
			if err != nil {
				return err
			}
			out := completeOut{Complete: rep.Complete(), Posted: false, AlreadyPosted: false, Unfinished: rep.Unfinished, Note: nil, Report: rep}
			if !out.Complete {
				return printJSON(c.OutOrStdout(), out)
			}
			if b.Notes[b.Epic][completionKey] {
				out.AlreadyPosted = true
				return printJSON(c.OutOrStdout(), out)
			}
			note, err := ss.s.PostNote(ctx, b.Epic, completionKey, rep.Text())
			out.Note, out.Posted = &note, note.Posted
			out.AlreadyPosted = !note.Posted && err == nil
			return emit(c, out, err)
		})
}

func newRoundCleanupCmd(env Env, g *globals) *cobra.Command {
	var dir string
	return roundCmd(env, g, "cleanup", "Remove the worktrees and merged branches of Issues closed with a merged PR", func(c *cobra.Command) {
		repoDirFlag(c, &dir)
	}, nil, func(ctx context.Context, c *cobra.Command, ss session) error {
		shared, err := sharedCheckout(ctx, ss, dir)
		if err != nil {
			return err
		}
		res, b, err := classifyBoard(ctx, ss)
		if err != nil {
			return err
		}
		out, err := round.Cleanup(ctx, ss.client, shared, round.Targets(res, b.PRs))
		return emit(c, out, err)
	})
}
