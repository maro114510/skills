package review

import (
	"fmt"
	"maps"
	"slices"
	"strings"

	"github.com/maro114510/skills/oe/internal/checks"
)

// Brief is everything a reviewer is handed.
// It holds identifiers and the pinned pair and never the worker's report, so the reviewer gathers its own evidence.
type Brief struct {
	Repo          string
	Epic          int
	Issue         int
	Branch        string
	Worktree      string
	DefaultBranch string
	// Base is the default-branch commit merged into Head, and the two form the pinned pair.
	Base           string
	Head           string
	ChecksRevision string
	// Checks are CHECKS_SET's runnable entries, verbatim.
	Checks []checks.Entry
}

// Render is the reviewer's whole prompt.
func Render(b Brief) string {
	var w strings.Builder
	p := func(format string, args ...any) { fmt.Fprintf(&w, format, args...) }
	p("You are a fresh issue-reviewer for orchestrate-epic. You have no memory of any earlier review, and you are never shown " +
		"the worker's report: gather your own evidence for every acceptance criterion.\n\n")
	p("## Assignment\n\n")
	p("- Repository: %s\n", b.Repo)
	p("- Issue: #%d. Read its requirements and acceptance criteria yourself:\n\n", b.Issue)
	p("  ```bash\n  gh issue view %d --repo %s --json title,body --jq .body\n  ```\n\n", b.Issue, b.Repo)
	p("- Epic: #%d, context only. Do not read it for scope.\n", b.Epic)
	p("- Branch: %s\n", b.Branch)
	p("- Worktree: %s\n", b.Worktree)
	p("- Default branch: %s. Use this name and never assume main.\n", b.DefaultBranch)
	p("- REVIEW_BASE: %s, the commit of origin/%s already merged into the branch\n", b.Base, b.DefaultBranch)
	p("- REVIEW_HEAD: %s, the exact commit under review\n\n", b.Head)
	p("## What you review\n\n")
	p("Review the committed content between the pinned pair only, never a branch name that can move:\n\n")
	wt := shellQuote(b.Worktree)
	p("```bash\ngit -C %s diff %s %s\ngit -C %s log --oneline %s..%s\n```\n\n", wt, b.Base, b.Head, wt, b.Base, b.Head)
	p("Confirm `git -C %s rev-parse HEAD` is %s before you start and again before you report. "+
		"Uncommitted or untracked files are not under review and never count as evidence; the worktree and index must stay exactly clean.\n\n",
		wt, b.Head)
	renderChecks(&w, b.ChecksRevision, b.Checks)
	p("## Rules\n\n")
	p("- Never edit, stage, commit, stash, reset, clean, push, or publish anything. If a check changes a tracked or untracked file, " +
		"report it as a blocking finding and leave the file as the check left it.\n")
	p("- Quote each acceptance criterion verbatim. Prefix a criterion you derived from the request's intent with `(derived)`.\n")
	p("- A criterion about behavior needs `[behavior]` evidence you observed through its interface. `[static]` evidence settles only " +
		"a criterion about structure or content. Passing checks alone are never behavior evidence.\n")
	p("- Never approve while any criterion is `unverified`. REQUEST_CHANGES needs at least one blocking finding.\n")
	p("- Every finding is `[blocking]` or `[nit]`. Any finding, a nit included, sends the work back.\n")
	p("- Never paste a token, credential, or environment value into the report.\n\n")
	p("Your final message must be exactly this report and nothing else:\n\n")
	p("```\nVERDICT: APPROVE | REQUEST_CHANGES\nREPO: %s\nISSUE: #%d\nBRANCH: %s\nREVIEWED_HEAD: <git rev-parse HEAD as you observed it>\n"+
		"REVIEWED_BASE: %s\nCHECKS_REVISION: %s\nBEHAVIOR_CHANGE: yes | no — <basis>\n"+
		"CRITERIA:\n1. <criterion verbatim> -> verified [behavior|static] — <evidence>\n2. <criterion verbatim> -> unverified — missing: <evidence that would verify it>\n"+
		"CHECKS:\n1. <command> -> exit <code>\n"+
		"FINDINGS:\n1. [blocking|nit] <file:line> — <defect>; <failure scenario>; <fix direction>\n```\n\n"+
		"Write `none` under FINDINGS when there is none.\n", b.Repo, b.Issue, b.Branch, b.Base, b.ChecksRevision)
	return w.String()
}

func renderChecks(w *strings.Builder, revision string, entries []checks.Entry) {
	fmt.Fprintf(w, "## CHECKS_SET at %s\n\n", revision)
	if len(entries) == 0 {
		w.WriteString("CHECKS_SET has no runnable entry for this repository. Write `none` under CHECKS.\n\n")
		return
	}
	w.WriteString("Run every runnable entry yourself in the worktree, verbatim, and report each exit status under CHECKS with the entry's number below. This is mandatory. " +
		"A red entry is a blocking finding.\n\n")
	for i, e := range entries {
		dir := e.WorkingDirectory
		if dir == "" {
			dir = "."
		}
		fmt.Fprintf(w, "%d. %s / %s / %s, shell %s, working directory %s\n\n", i+1, e.File, e.Job, e.Step, e.Shell, dir)
		if len(e.Env) > 0 {
			w.WriteString("Environment, set exactly as CI sets it:\n\n```\n")
			for _, k := range slices.Sorted(maps.Keys(e.Env)) {
				fmt.Fprintf(w, "%s=%s\n", k, e.Env[k])
			}
			w.WriteString("```\n\n")
		}
		fmt.Fprintf(w, "```\n%s\n```\n\n", e.Command)
	}
}

// shellQuote keeps a path one shell argument, quoting it only when it holds anything beyond safe characters.
func shellQuote(s string) string {
	safe := func(r rune) bool {
		return r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' || strings.ContainsRune("/._-+:@", r)
	}
	if s != "" && !strings.ContainsFunc(s, func(r rune) bool { return !safe(r) }) {
		return s
	}
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}
