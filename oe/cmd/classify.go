package cmd

import (
	"fmt"
	"strings"

	"github.com/spf13/cobra"

	"github.com/maro114510/skills/oe/internal/board"
	"github.com/maro114510/skills/oe/internal/exitcode"
	"github.com/maro114510/skills/oe/internal/health"
	"github.com/maro114510/skills/oe/internal/inputs"
	"github.com/maro114510/skills/oe/internal/readiness"
	"github.com/maro114510/skills/oe/internal/snapshot"
)

// The three subcommands below classify. They only read: every call they make is a GraphQL
// query, a GET, or a read-only git command, so none of them can push, comment, or merge, and
// each prints one JSON payload, or one verdict line when a read fails.

func newBoardCmd(env Env, g *globals) *cobra.Command {
	var leaseToken string
	c := &cobra.Command{
		Use:   "board",
		Short: "Classify every dispatchable Issue and propose actions and notes (read-only)",
		Args:  cobra.NoArgs,
		RunE: func(c *cobra.Command, _ []string) error {
			client, err := g.client(c, env)
			if err != nil {
				return err
			}
			in, err := inputs.Resolve(c.Context(), client, g.args(c))
			if err != nil {
				return coded(err)
			}
			b, err := snapshot.ReadBoard(c.Context(), client, in)
			if err != nil {
				return coded(err)
			}
			res, err := board.Classify(b, board.Options{LeaseToken: leaseToken})
			if err != nil {
				return coded(err)
			}
			return printJSON(c.OutOrStdout(), res)
		},
	}
	c.Flags().StringVar(&leaseToken, "lease-token", "", "this session's lease `token`; a lease held by any other token stops the read with exit 7")
	return c
}

func newHealthCmd(env Env, g *globals) *cobra.Command {
	return &cobra.Command{
		Use:   "health",
		Short: "Classify the default branch after the loop's latest merge (read-only)",
		Args:  cobra.NoArgs,
		RunE: func(c *cobra.Command, _ []string) error {
			client, err := g.client(c, env)
			if err != nil {
				return err
			}
			in, err := inputs.Resolve(c.Context(), client, g.args(c))
			if err != nil {
				return coded(err)
			}
			b, err := snapshot.ReadEpicState(c.Context(), client, in)
			if err != nil {
				return coded(err)
			}
			res := health.FromBoard(b)
			if res.Status == health.Unreadable {
				return exitcode.New(exitcode.Unreadable, "post-merge health is unreadable, so every merge is held: "+res.Reason)
			}
			return printJSON(c.OutOrStdout(), res)
		},
	}
}

func newReadinessCmd(env Env, g *globals) *cobra.Command {
	var pr int
	c := &cobra.Command{
		Use:   "readiness",
		Short: "Classify whether one pull request is ready to merge (read-only)",
		Args:  cobra.NoArgs,
		RunE: func(c *cobra.Command, _ []string) error {
			if pr <= 0 {
				return exitcode.New(exitcode.Usage, "--pr needs a positive pull request number")
			}
			client, err := g.client(c, env)
			if err != nil {
				return err
			}
			in, err := inputs.Resolve(c.Context(), client, g.args(c))
			if err != nil {
				return coded(err)
			}
			req, err := snapshot.ReadPullRequest(c.Context(), client, in.Repo, pr)
			if err != nil {
				return coded(err)
			}
			res := readiness.Classify(req)
			if res.Unreadable {
				reason := strings.TrimPrefix(res.Reason, "unreadable: ")
				return exitcode.New(exitcode.Unreadable, fmt.Sprintf("PR #%d is held (status BLOCKED, next human): %s", pr, reason))
			}
			return printJSON(c.OutOrStdout(), res)
		},
	}
	c.Flags().IntVar(&pr, "pr", 0, "pull request `number`")
	return c
}
