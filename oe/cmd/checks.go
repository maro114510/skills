package cmd

import (
	"os"
	"strings"

	"github.com/spf13/cobra"

	"github.com/maro114510/skills/oe/internal/checks"
	"github.com/maro114510/skills/oe/internal/exitcode"
	"github.com/maro114510/skills/oe/internal/gh"
)

// newChecksCmd is the CHECKS_SET group: one read-only derivation and one execution of its
// runnable entries.
func newChecksCmd(env Env, g *globals) *cobra.Command {
	return newGroup("checks", "Derive and run CHECKS_SET",
		newChecksDeriveCmd(env, g), newChecksRunCmd(env, g))
}

func newChecksDeriveCmd(env Env, g *globals) *cobra.Command {
	var base, ref string
	cmd := &cobra.Command{
		Use:   "derive",
		Short: "Derive CHECKS_SET from the workflows at a ref (read-only)",
		Args:  cobra.NoArgs,
		RunE: func(c *cobra.Command, _ []string) error {
			client, err := g.client(c, env)
			if err != nil {
				return err
			}
			branch, target, err := resolveBase(c, client, base, ref)
			if err != nil {
				return err
			}
			set, err := checks.Derive(c.Context(), client, branch, target)
			if err != nil {
				return coded(err)
			}
			return printJSON(c.OutOrStdout(), set)
		},
	}
	cmd.Flags().StringVar(&base, "base", "", "default branch name; default: origin/HEAD")
	cmd.Flags().StringVar(&ref, "ref", "", "git ref holding the workflows; default: origin/<base>")
	return cmd
}

// resolveBase resolves the default branch name and the ref its workflows are read from. It never
// assumes main.
func resolveBase(c *cobra.Command, client *gh.Client, base, ref string) (string, string, error) {
	if base == "" {
		out, err := client.Git(c.Context(), "symbolic-ref", "--short", "refs/remotes/origin/HEAD")
		if err != nil {
			return "", "", exitcode.Wrap(exitcode.Unreadable, err, "cannot resolve origin/HEAD; pass --base")
		}
		base = strings.TrimPrefix(strings.TrimSpace(string(out)), "origin/")
		if base == "" {
			return "", "", exitcode.New(exitcode.Unreadable, "cannot resolve the default branch; pass --base")
		}
	}
	if ref == "" {
		ref = "origin/" + base
	}
	return base, ref, nil
}

func newChecksRunCmd(env Env, g *globals) *cobra.Command {
	var setPath, worktree string
	cmd := &cobra.Command{
		Use:   "run",
		Short: "Run CHECKS_SET's runnable entries in a worktree",
		Args:  cobra.NoArgs,
		RunE: func(c *cobra.Command, _ []string) error {
			snapshot, err := snapshotMode(c, g)
			if err != nil {
				return err
			}
			if snapshot {
				return exitcode.New(exitcode.Refused, "--snapshot cannot run checks; it starts processes")
			}
			if setPath == "" {
				return exitcode.New(exitcode.Usage, "--set needs a CHECKS_SET file from `oe checks derive`")
			}
			set, err := checks.LoadSet(setPath)
			if err != nil {
				return coded(err)
			}
			dir := worktree
			if dir == "" {
				if dir, err = os.Getwd(); err != nil {
					return coded(err)
				}
			}
			report, err := checks.RunSet(c.Context(), gh.New(env.Exec, false), checks.Exec{}, dir, set)
			if err != nil {
				return coded(err)
			}
			if err := printJSON(c.OutOrStdout(), report); err != nil {
				return err
			}
			if !report.OK {
				return &payloadError{err: exitcode.New(exitcode.Stop, "one or more runnable checks failed")}
			}
			return nil
		},
	}
	cmd.Flags().StringVar(&setPath, "set", "", "CHECKS_SET `file` written by `oe checks derive`")
	cmd.Flags().StringVar(&worktree, "worktree", "", "worktree `path` to run in; default: the current directory")
	return cmd
}
