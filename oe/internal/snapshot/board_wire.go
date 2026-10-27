package snapshot

import (
	"context"
	"encoding/json"
	"fmt"
	"regexp"
	"slices"
	"strconv"
	"strings"

	"github.com/maro114510/skills/oe/internal/exitcode"
	"github.com/maro114510/skills/oe/internal/gh"
	"github.com/maro114510/skills/oe/internal/inputs"
)

// The states of an Issue and of a pull request as GitHub reports them. A merged pull request is
// reported by mergedAt, so it carries the state MERGED here.
const (
	StateOpen   = "OPEN"
	StateClosed = "CLOSED"
	StateMerged = "MERGED"
)

// BranchPrefix starts every loop branch name.
const BranchPrefix = "feat/issue-"

// Blocker is one blockedBy edge of an Issue and the state of the Issue it points to.
type Blocker struct {
	Number int    `json:"number"`
	State  string `json:"state"`
	Repo   string `json:"-"`
}

// UnmarshalJSON reads the repository identity nested in GitHub's blocker object.
func (b *Blocker) UnmarshalJSON(data []byte) error {
	var wire struct {
		Number     int    `json:"number"`
		State      string `json:"state"`
		Repository *struct {
			NameWithOwner string `json:"nameWithOwner"`
		} `json:"repository"`
	}
	if err := json.Unmarshal(data, &wire); err != nil {
		return fmt.Errorf("decode blocker: %w", err)
	}
	b.Number, b.State = wire.Number, wire.State
	if wire.Repository != nil {
		b.Repo = wire.Repository.NameWithOwner
	}
	return nil
}

// Issue is a child of the Epic, or a grandchild under a container. A container has Children.
// The body is kept only for the Epic's direct children, where a leftover placeholder token in a
// container is looked for; it is never printed.
type Issue struct {
	Number    int
	State     string
	Title     string
	Body      string
	CreatedAt string
	Blockers  []Blocker
	Children  []Issue
}

// PR is a pull request on a loop branch. Its State is OPEN, CLOSED, or MERGED.
type PR struct {
	Number    int
	State     string
	Branch    string
	HeadSHA   string
	CreatedAt string
}

// IssueOfBranch returns the Issue number a loop branch name belongs to.
func IssueOfBranch(name string) (int, bool) {
	m := loopBranchRe.FindStringSubmatch(name)
	if m == nil {
		return 0, false
	}
	n, err := strconv.Atoi(m[1])
	return n, err == nil && n > 0
}

var loopBranchRe = regexp.MustCompile(`^` + regexp.QuoteMeta(BranchPrefix) + `([0-9]+)(?:-.*)?$`)

// treeQuery reads the Epic and its children, and one level of grandchildren under them, with
// every blockedBy edge, in one query whatever the Epic size. The per-node limits keep the
// query under GitHub's node budget; a connection that exceeds its limit is read on, never cut.
const treeQuery = `query($owner: String!, $name: String!, $epic: Int!, $after: String) {
  repository(owner: $owner, name: $name) {
    defaultBranchRef { name target { oid } }
    issue(number: $epic) {
      number state body createdAt
      subIssues(first: 100, after: $after) {
        totalCount pageInfo { hasNextPage endCursor }
        nodes {
          id number state title body createdAt
          blockedBy(first: 20) { totalCount pageInfo { hasNextPage endCursor } nodes { number state repository { nameWithOwner } } }
          subIssues(first: 100) {
            totalCount pageInfo { hasNextPage endCursor }
            nodes {
              id number state title createdAt
              blockedBy(first: 10) { totalCount pageInfo { hasNextPage endCursor } nodes { number state repository { nameWithOwner } } }
            }
          }
        }
      }
    }
  }
}`

const blockersQuery = `query($id: ID!, $after: String) {
  node(id: $id) { ... on Issue { blockedBy(first: 100, after: $after) {
    pageInfo { hasNextPage endCursor } nodes { number state repository { nameWithOwner } } } } }
}`

type blockerConn struct {
	TotalCount int       `json:"totalCount"`
	PageInfo   PageInfo  `json:"pageInfo"`
	Nodes      []Blocker `json:"nodes"`
}

type subConn struct {
	TotalCount int         `json:"totalCount"`
	PageInfo   PageInfo    `json:"pageInfo"`
	Nodes      []issueNode `json:"nodes"`
}

type issueNode struct {
	ID        string      `json:"id"`
	Number    int         `json:"number"`
	State     string      `json:"state"`
	Title     string      `json:"title"`
	Body      string      `json:"body"`
	CreatedAt string      `json:"createdAt"`
	BlockedBy blockerConn `json:"blockedBy"`
	SubIssues *subConn    `json:"subIssues"`
}

type treeData struct {
	Repository *struct {
		DefaultBranchRef *struct {
			Name   string `json:"name"`
			Target *struct {
				OID string `json:"oid"`
			} `json:"target"`
		} `json:"defaultBranchRef"`
		Issue *struct {
			Number    int     `json:"number"`
			State     string  `json:"state"`
			Body      string  `json:"body"`
			CreatedAt string  `json:"createdAt"`
			SubIssues subConn `json:"subIssues"`
		} `json:"issue"`
	} `json:"repository"`
}

type blockersData struct {
	Node *struct {
		BlockedBy *blockerConn `json:"blockedBy"`
	} `json:"node"`
}

// check refuses a page that does not hold the Epic and the head of the default branch.
func (d treeData) check(in inputs.Inputs) error {
	repo := d.Repository
	switch {
	case repo == nil || repo.Issue == nil || repo.Issue.Number != in.Epic:
		return unreadable("Epic #%d in %s was not read", in.Epic, in.Repo)
	case repo.DefaultBranchRef == nil || repo.DefaultBranchRef.Target == nil || repo.DefaultBranchRef.Target.OID == "":
		return unreadable("the head of %s's default branch was not read", in.Repo)
	default:
		return nil
	}
}

// tree is the Epic's own facts and its children.
type tree struct {
	branch    string
	baseSHA   string
	body      string
	createdAt string
	children  []Issue
}

func unreadable(format string, args ...any) error {
	return exitcode.New(exitcode.Unreadable, fmt.Sprintf(format, args...))
}

func readTree(ctx context.Context, c *gh.Client, in inputs.Inputs) (tree, error) {
	var t tree
	var nodes []issueNode
	total := -1
	err := eachPage("the Epic's sub-issues", func(after string) (PageInfo, bool, error) {
		var data treeData
		vars := pageVars(in.Repo, after, gh.Int("epic", in.Epic))
		if err := c.GraphQL(ctx, treeQuery, vars, &data); err != nil {
			return PageInfo{}, false, err
		}
		if err := data.check(in); err != nil {
			return PageInfo{}, false, err
		}
		repo := data.Repository
		if total < 0 {
			total = repo.Issue.SubIssues.TotalCount
			t = tree{
				branch: repo.DefaultBranchRef.Name, baseSHA: repo.DefaultBranchRef.Target.OID,
				body: repo.Issue.Body, createdAt: repo.Issue.CreatedAt, children: nil,
			}
		}
		nodes = append(nodes, repo.Issue.SubIssues.Nodes...)
		return repo.Issue.SubIssues.PageInfo, false, nil
	})
	if err != nil {
		return tree{}, err
	}
	if len(nodes) != total {
		return tree{}, unreadable("Epic #%d lists %d sub-issues but %d were read", in.Epic, total, len(nodes))
	}
	for _, n := range nodes {
		child, err := buildIssue(ctx, c, n, true)
		if err != nil {
			return tree{}, err
		}
		t.children = append(t.children, child)
	}
	return t, nil
}

// buildIssue converts a node, reading on any blockedBy edge past its first page. A container
// with more sub-issues than one page is refused rather than cut.
func buildIssue(ctx context.Context, c *gh.Client, n issueNode, top bool) (Issue, error) {
	blockers, err := allBlockers(ctx, c, n)
	if err != nil {
		return Issue{}, err
	}
	out := Issue{Number: n.Number, State: n.State, Title: n.Title, Body: "", CreatedAt: n.CreatedAt, Blockers: blockers, Children: nil}
	if top {
		out.Body = n.Body
	}
	if n.SubIssues == nil {
		return out, nil
	}
	if n.SubIssues.PageInfo.HasNextPage || n.SubIssues.TotalCount > len(n.SubIssues.Nodes) {
		return Issue{}, unreadable("#%d has %d sub-issues; oe reads at most %d under one container",
			n.Number, n.SubIssues.TotalCount, pageSize)
	}
	for _, g := range n.SubIssues.Nodes {
		child, err := buildIssue(ctx, c, g, false)
		if err != nil {
			return Issue{}, err
		}
		out.Children = append(out.Children, child)
	}
	return out, nil
}

func allBlockers(ctx context.Context, c *gh.Client, n issueNode) ([]Blocker, error) {
	blockers := slices.Clone(n.BlockedBy.Nodes)
	page := n.BlockedBy.PageInfo
	after := ""
	for {
		next, more, err := nextPage(after, page, fmt.Sprintf("the blockedBy edges of #%d", n.Number))
		if err != nil {
			return nil, err
		}
		if !more {
			break
		}
		var data blockersData
		after = next
		if err := c.GraphQL(ctx, blockersQuery, []gh.Var{gh.String("id", n.ID), gh.String("after", after)}, &data); err != nil {
			return nil, err
		}
		if data.Node == nil || data.Node.BlockedBy == nil {
			return nil, unreadable("the blockedBy edges of #%d were not read", n.Number)
		}
		blockers = append(blockers, data.Node.BlockedBy.Nodes...)
		page = data.Node.BlockedBy.PageInfo
	}
	if len(blockers) != n.BlockedBy.TotalCount {
		return nil, unreadable("#%d has %d blockedBy edges but %d were read", n.Number, n.BlockedBy.TotalCount, len(blockers))
	}
	for _, blocker := range blockers {
		if blocker.Repo == "" {
			return nil, unreadable("the repository of blocker #%d of #%d was not read", blocker.Number, n.Number)
		}
	}
	return blockers, nil
}

const pullsQuery = `query($owner: String!, $name: String!, $after: String) {
  repository(owner: $owner, name: $name) {
    pullRequests(first: 100, after: $after, orderBy: {field: CREATED_AT, direction: DESC}) {
      pageInfo { hasNextPage endCursor }
      nodes { number state mergedAt createdAt headRefName headRefOid isCrossRepository }
    }
  }
}`

type pullsData struct {
	Repository *struct {
		PullRequests *struct {
			PageInfo PageInfo   `json:"pageInfo"`
			Nodes    []pullNode `json:"nodes"`
		} `json:"pullRequests"`
	} `json:"repository"`
}

type pullNode struct {
	Number            int     `json:"number"`
	State             string  `json:"state"`
	MergedAt          *string `json:"mergedAt"`
	CreatedAt         string  `json:"createdAt"`
	HeadRefName       string  `json:"headRefName"`
	BaseRefName       string  `json:"baseRefName"`
	HeadRefOid        string  `json:"headRefOid"`
	IsCrossRepository *bool   `json:"isCrossRepository"`
}

func loopPR(n pullNode) (PR, bool, error) {
	if n.IsCrossRepository == nil {
		return PR{}, false, unreadable("PR #%d has no cross-repository marker", n.Number)
	}
	if *n.IsCrossRepository {
		return PR{Number: 0, State: "", Branch: "", HeadSHA: "", CreatedAt: ""}, false, nil
	}
	if _, ok := IssueOfBranch(n.HeadRefName); !ok {
		return PR{Number: 0, State: "", Branch: "", HeadSHA: "", CreatedAt: ""}, false, nil
	}
	state := n.State
	if n.MergedAt != nil {
		state = StateMerged
	}
	return PR{Number: n.Number, State: state, Branch: n.HeadRefName, HeadSHA: n.HeadRefOid, CreatedAt: n.CreatedAt}, true, nil
}

// readPRs reads every pull request on a loop branch. Pull requests come newest first and are
// read page by page until one is older than since: a pull request for an Issue cannot be older
// than the Issue, so the list is complete from there. A page the connection cannot continue
// from is a truncated listing and stops the read.
func readPRs(ctx context.Context, c *gh.Client, repo, since string) ([]PR, error) {
	var out []PR
	err := eachPage("the pull request listing", func(after string) (PageInfo, bool, error) {
		var data pullsData
		if err := c.GraphQL(ctx, pullsQuery, pageVars(repo, after), &data); err != nil {
			return PageInfo{}, false, err
		}
		if data.Repository == nil || data.Repository.PullRequests == nil {
			return PageInfo{}, false, unreadable("the pull requests of %s were not read", repo)
		}
		list := data.Repository.PullRequests
		for _, n := range list.Nodes {
			pr, include, err := loopPR(n)
			if err != nil {
				return PageInfo{}, false, err
			}
			if include {
				out = append(out, pr)
			}
		}
		oldest := len(list.Nodes) - 1
		older := since != "" && oldest >= 0 && list.Nodes[oldest].CreatedAt < since
		return list.PageInfo, older, nil
	})
	return out, err
}

const refsQuery = `query($owner: String!, $name: String!, $after: String) {
  repository(owner: $owner, name: $name) {
    refs(refPrefix: "refs/heads/", query: "feat/issue-", first: 100, after: $after) {
      pageInfo { hasNextPage endCursor } nodes { name }
    }
  }
}`

type refsData struct {
	Repository *struct {
		Refs *struct {
			PageInfo PageInfo `json:"pageInfo"`
			Nodes    []struct {
				Name string `json:"name"`
			} `json:"nodes"`
		} `json:"refs"`
	} `json:"repository"`
}

// readBranches lists the loop branches on origin and locally, sorted and without repeats.
func readBranches(ctx context.Context, c *gh.Client, repo string) ([]string, error) {
	var names []string
	err := eachPage("the branch listing", func(after string) (PageInfo, bool, error) {
		var data refsData
		if err := c.GraphQL(ctx, refsQuery, pageVars(repo, after), &data); err != nil {
			return PageInfo{}, false, err
		}
		if data.Repository == nil || data.Repository.Refs == nil {
			return PageInfo{}, false, unreadable("the branches of %s were not read", repo)
		}
		for _, n := range data.Repository.Refs.Nodes {
			names = append(names, n.Name)
		}
		return data.Repository.Refs.PageInfo, false, nil
	})
	if err != nil {
		return nil, err
	}
	local, err := localBranches(ctx, c, repo)
	if err != nil {
		return nil, err
	}
	names = append(names, local...)
	names = slices.DeleteFunc(names, func(n string) bool { _, ok := IssueOfBranch(n); return !ok })
	slices.Sort(names)
	return slices.Compact(names), nil
}

// localBranches lists the loop branches of the checkout oe runs in, when that checkout is of
// repo. A checkout of another repository says nothing about this one, so its branches are left
// out; a checkout that cannot be read is an error, never an empty list.
func localBranches(ctx context.Context, c *gh.Client, repo string) ([]string, error) {
	url, err := c.Git(ctx, "remote", "get-url", "origin")
	if err != nil {
		return nil, err
	}
	if origin, err := inputs.ParseRemote(string(url)); err != nil || !strings.EqualFold(origin, repo) {
		return nil, nil //nolint:nilerr // An origin that is not this repository is not an error, only not this repository's checkout.
	}
	out, err := c.Git(ctx, "for-each-ref", "--format=%(refname:short)", "refs/heads/"+BranchPrefix+"*")
	if err != nil {
		return nil, err
	}
	var names []string
	for l := range strings.SplitSeq(string(out), "\n") {
		if l = strings.TrimSpace(l); l != "" {
			names = append(names, l)
		}
	}
	return names, nil
}
