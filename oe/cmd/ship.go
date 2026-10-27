package cmd

import (
	"context"
	"os"
	"path/filepath"

	"github.com/spf13/cobra"

	"github.com/maro114510/skills/oe/internal/exitcode"
	"github.com/maro114510/skills/oe/internal/handoff"
	"github.com/maro114510/skills/oe/internal/ship"
)

// The ship subcommand publishes an approved Issue, contract §18.
// Like every coordination subcommand it refuses --snapshot before any call, takes the Epic's lock, and confirms the lease.
// It is one of the only two subcommands that may push or open a pull request.

func newShipCmd(env Env, g *globals) *cobra.Command {
	return newGroup("ship", "Ship approved work", newPublishCmd(env, g))
}

type publishArgs struct {
	reviewArgs

	title, reportFile, nitsFile, scripts string
}

func newPublishCmd(env Env, g *globals) *cobra.Command {
	var a publishArgs
	c := &cobra.Command{
		Use:   "publish",
		Short: "Push the approved head and open or link its PR, from whatever point an earlier run stopped",
		Args:  cobra.NoArgs,
		RunE: func(c *cobra.Command, _ []string) error {
			// A mutation is refused under --snapshot before anything else is read.
			if snapshot, err := snapshotMode(c, g); err != nil || snapshot {
				if err != nil {
					return err
				}
				return exitcode.New(exitcode.Refused, "--snapshot disables every mutation; "+c.CommandPath()+" did nothing")
			}
			req, err := a.request()
			if err != nil {
				return err
			}
			return g.coordinate(c, env, a.token, false, func(ctx context.Context, ss session) error {
				res, err := a.publish(ctx, env, ss, req)
				if res.Route == "" {
					return err
				}
				return emit(c, res, err)
			})
		},
	}
	a.flags(c)
	c.Flags().StringVar(&a.title, "title", "", "the pull request `title`")
	c.Flags().StringVar(&a.reportFile, "report-file", "", "`file` holding the worker's DONE report, the source of the summary, checks, and skipped items")
	c.Flags().StringVar(&a.nitsFile, "nits-file", "", "`file` saying how each reviewer nit was resolved; default: none")
	c.Flags().StringVar(&a.scripts, "create-pr-scripts", "", "absolute `path` of the create-pr skill's scripts directory")
	return c
}

// request checks every argument and reads every file before any call.
func (a *publishArgs) request() (ship.Request, error) {
	var req ship.Request
	set, err := a.check()
	if err != nil {
		return req, err
	}
	if a.title == "" || a.reportFile == "" || a.scripts == "" {
		return req, exitcode.New(exitcode.Usage, "publish needs --title, --report-file, and --create-pr-scripts")
	}
	scripts, err := ship.ResolveScripts(a.scripts)
	if err != nil {
		return req, err
	}
	report, err := readDoneReport(a.reportFile)
	if err != nil {
		return req, err
	}
	nits := ""
	if a.nitsFile != "" {
		data, err := os.ReadFile(filepath.Clean(a.nitsFile))
		if err != nil {
			return req, exitcode.New(exitcode.Refused, "the nits file is unreadable")
		}
		nits = string(data)
	}
	return ship.Request{Issue: a.n, Set: set, Scripts: scripts, Title: a.title, Report: report, Nits: nits}, nil
}

// readDoneReport reads the worker report the pull request body is composed from, which must be a well-formed DONE one.
func readDoneReport(path string) (handoff.Report, error) {
	text, err := os.ReadFile(filepath.Clean(path))
	if err != nil {
		return handoff.Report{}, exitcode.New(exitcode.Refused, "the worker report is unreadable")
	}
	report, err := handoff.Parse(string(text))
	if err != nil || report.Status != handoff.StatusDone {
		return handoff.Report{}, exitcode.New(exitcode.Refused, "--report-file must hold a well-formed DONE worker report")
	}
	return report, nil
}

func (a *publishArgs) publish(ctx context.Context, env Env, ss session, req ship.Request) (ship.Result, error) {
	rs, err := site(ctx, ss, &a.reviewArgs)
	if err != nil {
		return ship.NewResult(a.n), err
	}
	req.State, req.Worktree = rs.st, rs.e.Path
	return ship.Publish(ctx, ship.Deps{S: ss.s, Client: ss.client, In: ss.in, Scripts: env.scripts(), Checks: env.checks()}, req)
}
