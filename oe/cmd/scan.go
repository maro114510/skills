package cmd

import (
	"io"
	"os"

	"github.com/spf13/cobra"

	"github.com/maro114510/skills/oe/internal/exitcode"
	"github.com/maro114510/skills/oe/internal/gh"
	"github.com/maro114510/skills/oe/internal/scan"
)

// newScanCmd is the secret scan of contract §14.
func newScanCmd(env Env, g *globals) *cobra.Command {
	return newGroup("scan", "Scan what the loop would publish for suspected secrets",
		newScanOutgoingCmd(env, g), newScanTextCmd())
}

func newScanOutgoingCmd(env Env, g *globals) *cobra.Command {
	var base, worktree string
	cmd := &cobra.Command{
		Use:   "outgoing",
		Short: "Scan every outgoing commit and the worktree, read-only",
		Args:  cobra.NoArgs,
		RunE: func(c *cobra.Command, _ []string) error {
			snapshot, err := snapshotMode(c, g)
			if err != nil {
				return err
			}
			if snapshot {
				return exitcode.New(exitcode.Refused, "--snapshot cannot scan; it reads the worktree's files")
			}
			dir := worktree
			if dir == "" {
				if dir, err = os.Getwd(); err != nil {
					return coded(err)
				}
			}
			report, err := scan.Outgoing(c.Context(), gh.New(env.Exec, false), dir, base)
			if err != nil {
				return coded(err)
			}
			return printScan(c, report, report.Clean)
		},
	}
	cmd.Flags().StringVar(&base, "base", "origin/HEAD", "`ref` whose commits are already published")
	cmd.Flags().StringVar(&worktree, "worktree", "", "worktree `path` to scan; default: the current directory")
	return cmd
}

func newScanTextCmd() *cobra.Command {
	var source, file string
	cmd := &cobra.Command{
		Use:   "text",
		Short: "Scan one text before it is published",
		Args:  cobra.NoArgs,
		RunE: func(c *cobra.Command, _ []string) error {
			var data []byte
			var err error
			if file == "" || file == "-" {
				data, err = io.ReadAll(c.InOrStdin())
			} else {
				data, err = os.ReadFile(file) //nolint:gosec // G304: the caller names the file.
			}
			if err != nil {
				return exitcode.New(exitcode.Unreadable, "scan cannot read the text")
			}
			report := scan.Text(source, data)
			return printScan(c, report, report.Clean)
		},
	}
	cmd.Flags().StringVar(&source, "source", "stdin", "`label` naming the text in the report, such as pr-body")
	cmd.Flags().StringVar(&file, "file", "", "`file` holding the text; default or -: stdin")
	return cmd
}

// printScan prints the report and exits 8 on a finding without a second verdict line.
func printScan(c *cobra.Command, report any, clean bool) error {
	if err := printJSON(c.OutOrStdout(), report); err != nil {
		return err
	}
	if !clean {
		return &payloadError{err: exitcode.New(exitcode.Refused, "scan found suspected secrets; publish nothing")}
	}
	return nil
}
