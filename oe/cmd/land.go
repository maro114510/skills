package cmd

import (
	"context"

	"github.com/spf13/cobra"

	"github.com/maro114510/skills/oe/internal/exitcode"
	"github.com/maro114510/skills/oe/internal/land"
)

// The land subcommands merge a shipped pull request and hand a failing one back to a worker, contract §19.
// Like every coordination subcommand each refuses --snapshot before any call, takes the Epic's lock, and confirms the lease.
// oe land merge is one of the only two subcommands that may merge.

func newLandCmd(env Env, g *globals) *cobra.Command {
	return newGroup("land", "Land shipped PRs", newMergeCmd(env, g), newRepairCmd(env, g))
}

type landArgs struct {
	n     int
	token string
}

func (a *landArgs) flags(c *cobra.Command) {
	c.Flags().IntVar(&a.n, "issue", 0, "child Issue `number`")
	tokenFlag(c, &a.token)
}

func newMergeCmd(env Env, g *globals) *cobra.Command {
	var a landArgs
	c := &cobra.Command{
		Use:   "merge",
		Short: "Merge one PR at its reviewed head, or settle the record of a merge an earlier run left unresolved",
		Args:  cobra.NoArgs,
		RunE: func(c *cobra.Command, _ []string) error {
			// A mutation is refused under --snapshot before anything else is read.
			if snapshot, err := snapshotMode(c, g); err != nil || snapshot {
				if err != nil {
					return err
				}
				return exitcode.New(exitcode.Refused, "--snapshot disables every mutation; "+c.CommandPath()+" did nothing")
			}
			if err := needIssue(a.n); err != nil {
				return err
			}
			return g.coordinate(c, env, a.token, false, func(ctx context.Context, ss session) error {
				res, err := land.Merge(ctx, land.Deps{S: ss.s, Client: ss.client, In: ss.in}, a.n)
				if res.Route == "" {
					return err
				}
				return emit(c, res, err)
			})
		},
	}
	a.flags(c)
	return c
}

func newRepairCmd(env Env, g *globals) *cobra.Command {
	var a landArgs
	c := &cobra.Command{
		Use:   "repair",
		Short: "Hand a pull request's failed checks, conflict, and review feedback to a fresh worker",
		Args:  cobra.NoArgs,
		RunE: func(c *cobra.Command, _ []string) error {
			if snapshot, err := snapshotMode(c, g); err != nil || snapshot {
				if err != nil {
					return err
				}
				return exitcode.New(exitcode.Refused, "--snapshot disables every mutation; "+c.CommandPath()+" did nothing")
			}
			if err := needIssue(a.n); err != nil {
				return err
			}
			return g.coordinate(c, env, a.token, false, func(context.Context, session) error {
				return exitcode.New(exitcode.Refused, "oe land repair is not built yet")
			})
		},
	}
	a.flags(c)
	return c
}
