// Package cmd wires oe's subcommands. Every subcommand prints one JSON payload on success or
// one verdict line on failure, and exits with a contract §9 code.
package cmd

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"

	"github.com/spf13/cobra"

	"github.com/maro114510/skills/oe/internal/exitcode"
	"github.com/maro114510/skills/oe/internal/gh"
	"github.com/maro114510/skills/oe/internal/inputs"
	"github.com/maro114510/skills/oe/internal/runner"
)

// Env is what the process gives oe: output streams, the runner for real calls, and the
// build version.
type Env struct {
	Stdout  io.Writer
	Stderr  io.Writer
	Exec    runner.Runner
	Version string
}

type globals struct {
	snapshot    string
	repo        string
	epic        string
	maxParallel string
}

// Main runs oe with args and returns the process exit code.
func Main(args []string, env Env) int {
	root := newRoot(env)
	root.SetArgs(args)
	root.SetOut(env.Stdout)
	root.SetErr(env.Stderr)
	err := root.Execute()
	if err == nil {
		return int(exitcode.OK)
	}
	if _, ok := errors.AsType[*exitcode.Error](err); !ok {
		// Only cobra's own argument parsing returns an uncoded error.
		err = exitcode.Wrap(exitcode.Usage, err, "invalid arguments")
	}
	_, _ = fmt.Fprintln(env.Stdout, exitcode.Verdict(err))
	return int(exitcode.CodeOf(err))
}

func newRoot(env Env) *cobra.Command {
	g := &globals{snapshot: "", repo: "", epic: "", maxParallel: ""}
	root := &cobra.Command{
		Use:           "oe",
		Short:         "Deterministic engine for the orchestrate-epic skill",
		Version:       env.Version,
		SilenceUsage:  true,
		SilenceErrors: true,
		Args:          cobra.NoArgs,
		RunE: func(*cobra.Command, []string) error {
			return exitcode.New(exitcode.Usage, "missing subcommand; run oe --help")
		},
	}
	root.SetVersionTemplate("{{.Version}}\n")
	root.SetFlagErrorFunc(func(_ *cobra.Command, err error) error {
		return exitcode.Wrap(exitcode.Usage, err, "invalid flag")
	})
	pf := root.PersistentFlags()
	pf.StringVar(&g.snapshot, "snapshot", "", "replay recorded gh and git responses from `file`; no network, no mutation")
	pf.StringVar(&g.repo, "repo", "", "repository as owner/name; default: the origin remote")
	pf.StringVar(&g.epic, "epic", "", "Epic Issue `number or URL`; never guessed")
	pf.StringVar(&g.maxParallel, "max-parallel", "", "concurrent worker cap; an invalid value falls back to 3")

	root.AddCommand(
		newVersionCmd(env),
		newResolveCmd(env, g),
		newGroup("ship", "Ship approved work", newMutatingCmd(env, g, "publish", "Push the approved head and open its PR", "#289")),
		newGroup("land", "Land shipped PRs", newMutatingCmd(env, g, "merge", "Merge one PR at its reviewed head", "#290")),
	)
	return root
}

func newGroup(name, short string, children ...*cobra.Command) *cobra.Command {
	c := &cobra.Command{
		Use:   name,
		Short: short,
		Args:  cobra.NoArgs,
		RunE: func(*cobra.Command, []string) error {
			return exitcode.New(exitcode.Usage, "missing subcommand for oe "+name)
		},
	}
	c.AddCommand(children...)
	return c
}

func newVersionCmd(env Env) *cobra.Command {
	return &cobra.Command{
		Use:   "version",
		Short: "Print the oe version",
		Args:  cobra.NoArgs,
		RunE: func(c *cobra.Command, _ []string) error {
			_, err := fmt.Fprintln(c.OutOrStdout(), env.Version)
			return coded(err)
		},
	}
}

// snapshotMode reports whether --snapshot was given at all. An empty value, such as one built
// from an unset variable, is a usage error rather than a silent switch to real calls.
func snapshotMode(c *cobra.Command, g *globals) (bool, error) {
	if !c.Flags().Changed("snapshot") {
		return false, nil
	}
	if g.snapshot == "" {
		return true, exitcode.New(exitcode.Usage, "--snapshot needs a file path")
	}
	return true, nil
}

// client returns a gh client over the snapshot when --snapshot is set, else over real calls.
func (g *globals) client(c *cobra.Command, env Env) (*gh.Client, error) {
	snapshot, err := snapshotMode(c, g)
	if err != nil {
		return nil, err
	}
	if !snapshot {
		return gh.New(env.Exec, false), nil
	}
	snap, err := runner.LoadSnapshot(g.snapshot)
	if err != nil {
		return nil, exitcode.Wrap(exitcode.Usage, err, "unusable --snapshot")
	}
	return gh.New(snap, true), nil
}

func (g *globals) args(c *cobra.Command) inputs.Args {
	return inputs.Args{
		Repo:           g.repo,
		Epic:           g.epic,
		MaxParallel:    g.maxParallel,
		MaxParallelSet: c.Flags().Changed("max-parallel"),
	}
}

func printJSON(w io.Writer, v any) error {
	data, err := json.Marshal(v)
	if err != nil {
		return coded(err)
	}
	_, err = fmt.Fprintln(w, string(data))
	return coded(err)
}

// coded gives an uncoded internal error the fail-closed code, so Main never mistakes it for
// a cobra usage error.
func coded(err error) error {
	if err == nil {
		return nil
	}
	if _, ok := errors.AsType[*exitcode.Error](err); ok {
		return err
	}
	return exitcode.Wrap(exitcode.Unreadable, err, "internal error")
}
