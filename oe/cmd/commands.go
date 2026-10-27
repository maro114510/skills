package cmd

import (
	"fmt"

	"github.com/spf13/cobra"

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
