package cmd

import (
	"context"
	"errors"
	"io"
	"os"

	"github.com/spf13/cobra"

	"github.com/maro114510/skills/oe/internal/board"
	"github.com/maro114510/skills/oe/internal/coord"
	"github.com/maro114510/skills/oe/internal/exitcode"
	"github.com/maro114510/skills/oe/internal/gh"
	"github.com/maro114510/skills/oe/internal/inputs"
	"github.com/maro114510/skills/oe/internal/snapshot"
)

// The coordination subcommands below are the only ones that write loop comments. Each refuses
// --snapshot before any call, takes the Epic's host-wide lock, resolves the inputs, and, except
// lease acquire, confirms this session still holds the lease before anything else; a lock held
// by another process or a foreign or lost lease stops it with exit 7.

// session is what a coordination subcommand runs with.
type session struct {
	s      *coord.Session
	client *gh.Client
	in     inputs.Inputs
	token  string
}

type sessionFn func(ctx context.Context, ss session) error

func (g *globals) coordinate(c *cobra.Command, env Env, token string, acquire bool, fn sessionFn) error {
	snap, err := snapshotMode(c, g)
	if err != nil {
		return err
	}
	if snap {
		return exitcode.New(exitcode.Refused, "--snapshot disables every mutation; "+c.CommandPath()+" did nothing")
	}
	if !acquire && token == "" {
		return exitcode.New(exitcode.Usage, "--lease-token is required; run oe lease acquire first")
	}
	client := gh.New(env.Exec, false)
	in, err := inputs.Resolve(c.Context(), client, g.args(c))
	if err != nil {
		return coded(err)
	}
	s, err := env.newSession(client, in, token)
	if err != nil {
		return err
	}
	if err := s.Lock(); err != nil {
		return err
	}
	defer s.Close()
	if !acquire {
		if err := s.Verify(c.Context()); err != nil {
			return coded(err)
		}
	}
	return coded(fn(c.Context(), session{s: s, client: client, in: in, token: token}))
}

func (env Env) newSession(client *gh.Client, in inputs.Inputs, token string) (*coord.Session, error) {
	dir, err := coord.LockDir(env.getenv())
	if err != nil {
		return nil, err
	}
	host, err := env.hostname()
	if err != nil {
		return nil, exitcode.Wrap(exitcode.Refused, err, "this host has no name to record in the lease")
	}
	return coord.New(coord.Config{Client: client, Inputs: in, Token: token, LockDir: dir, Host: host, Alive: nil, Now: nil}), nil
}

func (env Env) getenv() func(string) string {
	if env.Getenv != nil {
		return env.Getenv
	}
	return os.Getenv
}

func (env Env) hostname() (string, error) {
	if env.Hostname != nil {
		return env.Hostname()
	}
	h, err := os.Hostname()
	if err != nil {
		return "", exitcode.Wrap(exitcode.Refused, err, "cannot read the host name")
	}
	return h, nil
}

// emit prints a payload and returns err without a second verdict line, so a stop such as a
// freeze still reports what it wrote.
func emit(c *cobra.Command, payload any, err error) error {
	if perr := printJSON(c.OutOrStdout(), payload); perr != nil {
		return perr
	}
	if err != nil {
		return &payloadError{err: coded(err)}
	}
	return nil
}

func tokenFlag(c *cobra.Command, token *string) {
	c.Flags().StringVar(token, "lease-token", "", "this session's lease `token`, from oe lease acquire")
}

func newLeaseCmd(env Env, g *globals) *cobra.Command {
	var pid int
	var token string
	acquire := &cobra.Command{
		Use:   "acquire",
		Short: "Take the Epic's lease for this session, or resume it with --lease-token",
		Args:  cobra.NoArgs,
		RunE: func(c *cobra.Command, _ []string) error {
			if pid <= 0 {
				return exitcode.New(exitcode.Usage, "--pid needs the session's positive process ID")
			}
			return g.coordinate(c, env, token, true, func(ctx context.Context, ss session) error {
				res, err := ss.s.Acquire(ctx, pid)
				if err != nil {
					return err
				}
				return printJSON(c.OutOrStdout(), res)
			})
		},
	}
	acquire.Flags().IntVar(&pid, "pid", 0, "process `id` of the session that holds the lease, such as the agent harness")
	tokenFlag(acquire, &token)
	var endToken string
	end := &cobra.Command{
		Use:   "end",
		Short: "End this session cleanly: the lease stays with pid 0",
		Args:  cobra.NoArgs,
		RunE: func(c *cobra.Command, _ []string) error {
			return g.coordinate(c, env, endToken, false, func(ctx context.Context, ss session) error {
				res, err := ss.s.End(ctx)
				if err != nil {
					return err
				}
				return printJSON(c.OutOrStdout(), res)
			})
		},
	}
	tokenFlag(end, &endToken)
	return newGroup("lease", "Hold one Publisher per Epic", acquire, end)
}

func newNoteCmd(env Env, g *globals) *cobra.Command {
	var on int
	var key, file, token string
	post := &cobra.Command{
		Use:   "post",
		Short: "Post one note at most once per key, after a secret scan",
		Args:  cobra.NoArgs,
		RunE: func(c *cobra.Command, _ []string) error {
			if on <= 0 || key == "" {
				return exitcode.New(exitcode.Usage, "note post needs --on <issue> and --key <key>")
			}
			text, err := readText(c, file)
			if err != nil {
				return err
			}
			return g.coordinate(c, env, token, false, func(ctx context.Context, ss session) error {
				res, err := ss.s.PostNote(ctx, on, key, text)
				if _, isScan := errors.AsType[*coord.ScanError](err); isScan || err == nil {
					return emit(c, res, err)
				}
				return err
			})
		},
	}
	post.Flags().IntVar(&on, "on", 0, "Issue `number` to post on: the Epic or a child Issue")
	post.Flags().StringVar(&key, "key", "", "dedup `key` from contract section 7; {digest} is replaced by the text's digest")
	post.Flags().StringVar(&file, "file", "", "`file` holding the note text; default or -: stdin")
	tokenFlag(post, &token)
	return newGroup("note", "Post loop notes through the single comment writer", post)
}

func readText(c *cobra.Command, file string) (string, error) {
	var data []byte
	var err error
	if file == "" || file == "-" {
		data, err = io.ReadAll(c.InOrStdin())
	} else {
		data, err = os.ReadFile(file) //nolint:gosec // G304: the caller names the file.
	}
	if err != nil {
		return "", exitcode.New(exitcode.Unreadable, "cannot read the text")
	}
	return string(data), nil
}

// notDone counts the Epic's dispatchable Issues that are not done, from a fresh board read.
func notDone(ctx context.Context, ss session) (int, error) {
	res, _, err := classifyBoard(ctx, ss)
	if err != nil {
		return 0, err
	}
	return countNotDone(res), nil
}

func classifyBoard(ctx context.Context, ss session) (board.Result, *snapshot.Board, error) {
	b, err := snapshot.ReadBoard(ctx, ss.client, ss.in)
	if err != nil {
		return board.Result{}, nil, err
	}
	res, err := board.Classify(b, board.Options{LeaseToken: ss.token, Observe: false})
	return res, b, err
}

func newLedgerCmd(env Env, g *globals) *cobra.Command {
	return newGroup("ledger", "Reserve the Epic-wide budget and own freeze and release",
		newLedgerCreateCmd(env, g), newLedgerCheckCmd(env, g), newLedgerReserveCmd(env, g),
		newLedgerFreezeCmd(env, g), newLedgerReleaseCmd(env, g))
}

func newLedgerCreateCmd(env Env, g *globals) *cobra.Command {
	var token string
	c := &cobra.Command{
		Use:   "create",
		Short: "Create the ledger for the dispatchable Issues not done; an existing one is kept",
		Args:  cobra.NoArgs,
		RunE: func(c *cobra.Command, _ []string) error {
			return g.coordinate(c, env, token, false, func(ctx context.Context, ss session) error {
				n, err := notDone(ctx, ss)
				if err != nil {
					return err
				}
				res, err := ss.s.CreateLedger(ctx, n)
				if err != nil {
					return err
				}
				return printJSON(c.OutOrStdout(), res)
			})
		},
	}
	tokenFlag(c, &token)
	return c
}

func newLedgerCheckCmd(env Env, g *globals) *cobra.Command {
	var token string
	c := &cobra.Command{
		Use:   "check",
		Short: "Freeze check without a reservation: exit 4 when frozen",
		Args:  cobra.NoArgs,
		RunE: func(c *cobra.Command, _ []string) error {
			return g.coordinate(c, env, token, false, func(ctx context.Context, ss session) error {
				res, err := ss.s.Check(ctx)
				if res.Ledger == nil {
					return err
				}
				return emit(c, res, err)
			})
		},
	}
	tokenFlag(c, &token)
	return c
}

func newLedgerReserveCmd(env Env, g *globals) *cobra.Command {
	var token string
	var req coord.Request
	c := &cobra.Command{
		Use:   "reserve",
		Short: "Reserve a batch before spawning; exceeding a bound freezes the Epic instead",
		Args:  cobra.NoArgs,
		RunE: func(c *cobra.Command, _ []string) error {
			if req.WorkerDispatches < 0 || req.ReviewerPasses < 0 || req.FixCycles < 0 || req == (coord.Request{}) {
				return exitcode.New(exitcode.Usage, "reserve needs at least one positive count and no negative one")
			}
			return g.coordinate(c, env, token, false, func(ctx context.Context, ss session) error {
				_, res, err := ss.s.Reserve(ctx, req)
				if res.Ledger == nil {
					return err
				}
				return emit(c, res, err)
			})
		},
	}
	c.Flags().IntVar(&req.WorkerDispatches, "worker-dispatches", 0, "worker spawns to reserve")
	c.Flags().IntVar(&req.ReviewerPasses, "reviewer-passes", 0, "charged reviewer spawns to reserve")
	c.Flags().IntVar(&req.FixCycles, "fix-cycles", 0, "fix cycles to reserve")
	tokenFlag(c, &token)
	return c
}

func newLedgerFreezeCmd(env Env, g *globals) *cobra.Command {
	var token, reason, merge, health string
	c := &cobra.Command{
		Use:   "freeze",
		Short: "Freeze the Epic, then post its note once; always exits 4",
		Args:  cobra.NoArgs,
		RunE: func(c *cobra.Command, _ []string) error {
			if reason == "" {
				return exitcode.New(exitcode.Usage, "freeze needs --reason")
			}
			return g.coordinate(c, env, token, false, func(ctx context.Context, ss session) error {
				res, err := ss.s.Freeze(ctx, reason, merge, health)
				if res.Ledger == nil {
					return err
				}
				return emit(c, res, err)
			})
		},
	}
	c.Flags().StringVar(&reason, "reason", "", "why the Epic freezes")
	c.Flags().StringVar(&merge, "merge", "", "merge `sha` whose default-branch health froze it, if any")
	c.Flags().StringVar(&health, "health", "", "that merge's health `status`, if any")
	tokenFlag(c, &token)
	return c
}

func newLedgerReleaseCmd(env Env, g *globals) *cobra.Command {
	var token string
	c := &cobra.Command{
		Use:   "release",
		Short: "Apply the epic-release that lifts the freeze, once; exit 4 while none does",
		Args:  cobra.NoArgs,
		RunE: func(c *cobra.Command, _ []string) error {
			return g.coordinate(c, env, token, false, func(ctx context.Context, ss session) error {
				n, err := notDone(ctx, ss)
				if err != nil {
					return err
				}
				res, err := ss.s.Release(ctx, n)
				if res.Ledger == nil {
					return err
				}
				return emit(c, res, err)
			})
		},
	}
	tokenFlag(c, &token)
	return c
}

func newStateCmd(env Env, g *globals) *cobra.Command {
	return newGroup("state", "Change an Issue state through its named transitions",
		newStateStartCmd(env, g), newApplySignalsCmd(env, g), newParkCmd(env, g), newInvalidateCmd(env, g))
}

// needIssue checks an Issue number before any call.
func needIssue(n int) error {
	if n <= 0 {
		return exitcode.New(exitcode.Usage, "--issue needs a positive Issue number")
	}
	return nil
}

// leafOf finds a dispatchable Issue of the Epic on the board.
func leafOf(res board.Result, n int) (board.Issue, error) {
	for _, i := range res.Issues {
		if i.Number == n {
			return i, nil
		}
	}
	return board.Issue{}, exitcode.New(exitcode.Refused, "the Issue is not a dispatchable Issue of the Epic")
}

func update(ctx context.Context, c *cobra.Command, ss session, n int, t coord.Transition) error {
	st, err := ss.s.Update(ctx, n, t)
	if err != nil {
		return err
	}
	return printJSON(c.OutOrStdout(), st)
}

func newStateStartCmd(env Env, g *globals) *cobra.Command {
	var token, branch string
	var n int
	c := &cobra.Command{
		Use:   "start",
		Short: "Create an Issue's state at dispatch; only this creates state",
		Args:  cobra.NoArgs,
		RunE: func(c *cobra.Command, _ []string) error {
			if err := needIssue(n); err != nil {
				return err
			}
			return g.coordinate(c, env, token, false, func(ctx context.Context, ss session) error {
				res, _, err := classifyBoard(ctx, ss)
				if err != nil {
					return err
				}
				leaf, err := leafOf(res, n)
				if err != nil {
					return err
				}
				if leaf.State != board.Ready && leaf.State != board.InProgress {
					return exitcode.New(exitcode.Refused, "the Issue is "+string(leaf.State)+"; state starts only for a ready or in-progress Issue")
				}
				if branch == "" {
					branch = leaf.Branch
				}
				return update(ctx, c, ss, n, coord.Start{Branch: branch})
			})
		},
	}
	c.Flags().IntVar(&n, "issue", 0, "child Issue `number`")
	c.Flags().StringVar(&branch, "branch", "", "branch to record; default: the board's branch for the Issue")
	tokenFlag(c, &token)
	return c
}

func newApplySignalsCmd(env Env, g *globals) *cobra.Command {
	var token string
	var n int
	c := &cobra.Command{
		Use:   "apply-signals",
		Short: "Consume the human comments above the Issue's watermark, applying a decision once",
		Args:  cobra.NoArgs,
		RunE: func(c *cobra.Command, _ []string) error {
			if err := needIssue(n); err != nil {
				return err
			}
			return g.coordinate(c, env, token, false, func(ctx context.Context, ss session) error {
				res, b, err := classifyBoard(ctx, ss)
				if err != nil {
					return err
				}
				leaf, err := leafOf(res, n)
				if err != nil {
					return err
				}
				return update(ctx, c, ss, n, coord.ApplySignals{Standing: standing(leaf.State), Taken: taken(b)})
			})
		},
	}
	c.Flags().IntVar(&n, "issue", 0, "child Issue `number`")
	tokenFlag(c, &token)
	return c
}

func standing(s board.State) coord.Standing {
	switch s {
	case board.Parked:
		return coord.StandingParked
	case board.Rejected:
		return coord.StandingRejected
	case board.Done, board.Verifying, board.AwaitingMerge, board.Reverify, board.InProgress, board.Ready, board.Waiting:
		return coord.StandingOther
	}
	return coord.StandingOther
}

// taken are the branch names a redo must not reuse: every branch read and every PR's head.
func taken(b *snapshot.Board) []string {
	out := append([]string{}, b.Branches...)
	for _, pr := range b.PRs {
		out = append(out, pr.Branch)
	}
	return out
}

func newParkCmd(env Env, g *globals) *cobra.Command {
	var token string
	var n int
	var blockers []string
	c := &cobra.Command{
		Use:   "park",
		Short: "Park an Issue for a person with its blockers",
		Args:  cobra.NoArgs,
		RunE: func(c *cobra.Command, _ []string) error {
			if err := needIssue(n); err != nil {
				return err
			}
			if len(blockers) == 0 {
				return exitcode.New(exitcode.Usage, "park needs at least one --blocker")
			}
			return g.coordinate(c, env, token, false, func(ctx context.Context, ss session) error {
				return update(ctx, c, ss, n, coord.Park{Blockers: blockers})
			})
		},
	}
	c.Flags().IntVar(&n, "issue", 0, "child Issue `number`")
	c.Flags().StringArrayVar(&blockers, "blocker", nil, "what parks the Issue; repeat for each")
	tokenFlag(c, &token)
	return c
}

func newInvalidateCmd(env Env, g *globals) *cobra.Command {
	var token string
	var n int
	c := &cobra.Command{
		Use:   "invalidate-approval",
		Short: "Clear an Issue's bound approval",
		Args:  cobra.NoArgs,
		RunE: func(c *cobra.Command, _ []string) error {
			if err := needIssue(n); err != nil {
				return err
			}
			return g.coordinate(c, env, token, false, func(ctx context.Context, ss session) error {
				return update(ctx, c, ss, n, coord.InvalidateApproval{})
			})
		},
	}
	c.Flags().IntVar(&n, "issue", 0, "child Issue `number`")
	tokenFlag(c, &token)
	return c
}
