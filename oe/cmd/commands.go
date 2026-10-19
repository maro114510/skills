package cmd

import (
	"fmt"

	"github.com/spf13/cobra"

	"github.com/maro114510/skills/oe/internal/exitcode"
	"github.com/maro114510/skills/oe/internal/inputs"
)

func newResolveCmd(env Env, g *globals) *cobra.Command {
	return &cobra.Command{
		Use:   "resolve",
		Short: "Resolve and print the run inputs as JSON (read-only)",
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
			if in.MaxParallelReason != "" {
				_, _ = fmt.Fprintln(c.ErrOrStderr(), in.MaxParallelReason)
			}
			return printJSON(c.OutOrStdout(), in)
		},
	}
}

// newMutatingCmd builds an irreversible subcommand. These are the only places a push, PR
// creation, or merge may happen, so the push-approval hook can detect them by name. It
// refuses under --snapshot before any call, and refuses after a failed or partial read.
func newMutatingCmd(env Env, g *globals, name, short, issue string) *cobra.Command {
	return &cobra.Command{
		Use:   name,
		Short: short,
		Args:  cobra.NoArgs,
		RunE: func(c *cobra.Command, _ []string) error {
			full := c.CommandPath()
			snapshot, err := snapshotMode(c, g)
			if err != nil {
				return err
			}
			if snapshot {
				return exitcode.New(exitcode.Refused, "--snapshot disables every mutation; "+full+" did nothing")
			}
			client, err := g.client(c, env)
			if err != nil {
				return err
			}
			// Resolve stops on any failed or partial read; the client also refuses every
			// later write, so a mutation added here cannot run on a partial read.
			if _, err := inputs.Resolve(c.Context(), client, g.args(c)); err != nil {
				return coded(err)
			}
			return exitcode.New(exitcode.Refused, full+" is not implemented yet; it lands in "+issue)
		},
	}
}
