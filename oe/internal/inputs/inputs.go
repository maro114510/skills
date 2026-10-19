// Package inputs resolves the inputs every oe subcommand starts from, one way: the repository,
// the Epic number, the authenticated login, the default branch, and the worker cap. It rejects
// a gh below the supported floor and a host without sub-issue or blocked-by support.
package inputs

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"regexp"
	"strconv"
	"strings"

	"github.com/maro114510/skills/oe/internal/exitcode"
	"github.com/maro114510/skills/oe/internal/gh"
)

// DefaultMaxParallel is the worker cap used when none, or an invalid one, is given.
const DefaultMaxParallel = 3

// The oldest gh oe supports. Every gh flag oe uses predates it.
const (
	minGHMajor = 2
	minGHMinor = 40
	minGHPatch = 0
)

const host = "github.com"

// ProbeQuery reads the default branch and the Epic, and fails on a host whose schema lacks
// sub-issues or blocked-by.
const ProbeQuery = `query($owner:String!,$name:String!,$epic:Int!){repository(owner:$owner,name:$name){` +
	`defaultBranchRef{name} issue(number:$epic){number subIssues(first:0){totalCount} blockedBy(first:0){totalCount}}}}`

// Args are the raw inputs from the command line.
type Args struct {
	Repo           string
	Epic           string
	MaxParallel    string
	MaxParallelSet bool
}

// Inputs are the resolved inputs.
type Inputs struct {
	Repo              string `json:"repo"`
	Epic              int    `json:"epic"`
	Me                string `json:"me"`
	DefaultBranch     string `json:"default_branch"`
	MaxParallel       int    `json:"max_parallel"`
	MaxParallelReason string `json:"max_parallel_reason"`
	GHVersion         string `json:"gh_version"`
}

var (
	repoRe      = regexp.MustCompile(`^[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?/[A-Za-z0-9._-]+$`)
	ghVersionRe = regexp.MustCompile(`gh version (\d+)\.(\d+)\.(\d+)`)
	scpRemoteRe = regexp.MustCompile(`^[^@/]+@([^:/]+):(.+)$`)
)

func usage(msg string) error { return exitcode.New(exitcode.Usage, msg) }

// Resolve validates the arguments before any call, then confirms gh and reads GitHub. Every
// failed or partial read stops it.
func Resolve(ctx context.Context, c *gh.Client, a Args) (Inputs, error) {
	epic, repo, err := parseTarget(a)
	if err != nil {
		return Inputs{}, err
	}
	maxParallel, reason := ParseMaxParallel(a.MaxParallel, a.MaxParallelSet)

	version, err := checkGH(ctx, c)
	if err != nil {
		return Inputs{}, err
	}
	me, err := readLogin(ctx, c)
	if err != nil {
		return Inputs{}, err
	}
	if repo == "" {
		if repo, err = originRepo(ctx, c); err != nil {
			return Inputs{}, err
		}
	}
	branch, err := probe(ctx, c, repo, epic)
	if err != nil {
		return Inputs{}, err
	}
	return Inputs{
		Repo: repo, Epic: epic, Me: me, DefaultBranch: branch,
		MaxParallel: maxParallel, MaxParallelReason: reason, GHVersion: version,
	}, nil
}

// parseTarget validates the Epic and repository arguments without any call. An Epic URL names
// the repository, and a --repo that disagrees with it is a usage error.
func parseTarget(a Args) (int, string, error) {
	epic, urlRepo, err := ParseEpic(a.Epic)
	if err != nil {
		return 0, "", err
	}
	repo := a.Repo
	if repo != "" && !repoRe.MatchString(repo) {
		return 0, "", usage(fmt.Sprintf("--repo %q is not owner/name", repo))
	}
	if urlRepo == "" {
		return epic, repo, nil
	}
	if repo != "" && !strings.EqualFold(repo, urlRepo) {
		return 0, "", usage(fmt.Sprintf("--repo %s conflicts with the Epic URL's repository %s", repo, urlRepo))
	}
	return epic, urlRepo, nil
}

// ParseEpic accepts a positive number or a github.com Issue URL, which also names the
// repository. An empty value is a usage error: oe never guesses an Epic.
func ParseEpic(raw string) (int, string, error) {
	if raw == "" {
		return 0, "", usage("no Epic given; pass --epic <number|url>. oe never guesses one")
	}
	if n, err := strconv.Atoi(raw); err == nil {
		if n <= 0 {
			return 0, "", usage(fmt.Sprintf("--epic %q is not a positive Issue number", raw))
		}
		return n, "", nil
	}
	return parseIssueURL(raw)
}

func parseIssueURL(raw string) (int, string, error) {
	u, err := url.Parse(raw)
	if err != nil || u.Scheme != "https" || u.Host != host {
		return 0, "", usage(fmt.Sprintf("--epic %q is neither an Issue number nor a https://github.com Issue URL", raw))
	}
	parts := strings.Split(strings.Trim(u.Path, "/"), "/")
	const issueURLParts = 4 // owner/name/issues/<n>
	if len(parts) != issueURLParts || parts[2] != "issues" {
		return 0, "", usage(fmt.Sprintf("--epic %q is not an Issue URL", raw))
	}
	n, err := strconv.Atoi(parts[3])
	repo := parts[0] + "/" + parts[1]
	if err != nil || n <= 0 || !repoRe.MatchString(repo) {
		return 0, "", usage(fmt.Sprintf("--epic %q is not an Issue URL", raw))
	}
	return n, repo, nil
}

// ParseMaxParallel returns the worker cap and, when an invalid value fell back to the
// default, the reason to print.
func ParseMaxParallel(raw string, set bool) (int, string) {
	if !set {
		return DefaultMaxParallel, ""
	}
	n, err := strconv.Atoi(raw)
	if err != nil || n <= 0 {
		return DefaultMaxParallel, fmt.Sprintf("max-parallel %q is not a positive integer; using the default %d", raw, DefaultMaxParallel)
	}
	return n, ""
}

// ParseRemote returns owner/name for a github.com remote URL in https, scp, or ssh form.
func ParseRemote(remote string) (string, error) {
	r := strings.TrimSpace(remote)
	var hostname, path string
	if m := scpRemoteRe.FindStringSubmatch(r); m != nil && !strings.Contains(r, "://") {
		hostname, path = m[1], m[2]
	} else {
		u, err := url.Parse(r)
		if err != nil || u.Host == "" {
			return "", exitcode.New(exitcode.Refused, fmt.Sprintf("origin %q is not a GitHub remote URL", r))
		}
		hostname, path = u.Hostname(), u.Path
	}
	repo := strings.TrimSuffix(strings.Trim(path, "/"), ".git")
	if hostname != host || !repoRe.MatchString(repo) {
		return "", exitcode.New(exitcode.Refused, fmt.Sprintf("origin %q is not a github.com repository; pass --repo", r))
	}
	return repo, nil
}

func checkGH(ctx context.Context, c *gh.Client) (string, error) {
	out, err := c.Read(ctx, "--version")
	if err != nil {
		return "", err
	}
	m := ghVersionRe.FindStringSubmatch(string(out))
	if m == nil {
		return "", exitcode.New(exitcode.Unreadable, "cannot parse `gh --version` output")
	}
	v := [3]int{}
	for i := range v {
		v[i], _ = strconv.Atoi(m[i+1]) // The regexp admits digits only.
	}
	if below(v, [3]int{minGHMajor, minGHMinor, minGHPatch}) {
		return "", exitcode.New(exitcode.Refused, fmt.Sprintf("gh %d.%d.%d is older than the supported %d.%d.%d; upgrade gh",
			v[0], v[1], v[2], minGHMajor, minGHMinor, minGHPatch))
	}
	if _, err := c.Read(ctx, "auth", "status", "--hostname", host); err != nil {
		// Only a completed check that said no is a refusal; a rate limit or a call that never
		// ran stays unreadable.
		if errors.Is(err, gh.ErrExitStatus) {
			return "", exitcode.Wrap(exitcode.Refused, err, "gh auth status failed for "+host+"; run gh auth login")
		}
		return "", err
	}
	return fmt.Sprintf("%d.%d.%d", v[0], v[1], v[2]), nil
}

func below(v, floor [3]int) bool {
	for i := range v {
		if v[i] != floor[i] {
			return v[i] < floor[i]
		}
	}
	return false
}

func readLogin(ctx context.Context, c *gh.Client) (string, error) {
	out, err := c.Read(ctx, "api", "user")
	if err != nil {
		return "", err
	}
	var user struct {
		Login string `json:"login"`
	}
	if err := json.Unmarshal(out, &user); err != nil || user.Login == "" {
		return "", exitcode.New(exitcode.Unreadable, "gh api user returned no login")
	}
	return user.Login, nil
}

func originRepo(ctx context.Context, c *gh.Client) (string, error) {
	out, err := c.Git(ctx, "remote", "get-url", "origin")
	if err != nil {
		return "", exitcode.Wrap(exitcode.Unreadable, err, "no --repo given and origin is unreadable")
	}
	return ParseRemote(string(out))
}

func probe(ctx context.Context, c *gh.Client, repo string, epic int) (string, error) {
	owner, name, _ := strings.Cut(repo, "/")
	var data struct {
		Repository *struct {
			DefaultBranchRef *struct {
				Name string `json:"name"`
			} `json:"defaultBranchRef"` //nolint:tagliatelle // GitHub's field name.
			Issue *struct {
				Number int `json:"number"`
			} `json:"issue"`
		} `json:"repository"`
	}
	err := c.GraphQL(ctx, ProbeQuery, []gh.Var{gh.String("owner", owner), gh.String("name", name), gh.Int("epic", epic)}, &data)
	if err != nil {
		if qe, ok := errors.AsType[*gh.QueryError](err); ok && (qe.UndefinedField("subIssues") || qe.UndefinedField("blockedBy")) {
			return "", exitcode.Wrap(exitcode.Refused, qe, "the host has no sub-issue or blocked-by support")
		}
		return "", err
	}
	switch {
	case data.Repository == nil || data.Repository.Issue == nil || data.Repository.Issue.Number != epic:
		return "", exitcode.New(exitcode.Unreadable, fmt.Sprintf("Epic #%d in %s was not read", epic, repo))
	case data.Repository.DefaultBranchRef == nil || data.Repository.DefaultBranchRef.Name == "":
		return "", exitcode.New(exitcode.Refused, repo+" has no default branch")
	}
	return data.Repository.DefaultBranchRef.Name, nil
}
