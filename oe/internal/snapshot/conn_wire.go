// Package snapshot is the one model of what the loop reads from GitHub. Every read is complete
// or it fails: a connection that was cut off, a page that cannot be followed, a response with
// errors, or a call that cannot be replayed stops classification with exit 1, and nothing is
// ever guessed from a partial list. The classifiers (board, readiness, health) read only the
// types in this package.
package snapshot

import (
	"fmt"

	"github.com/maro114510/skills/oe/internal/exitcode"
	"github.com/maro114510/skills/oe/internal/gh"
)

// pageSize is the page size of every connection read. GitHub allows at most 100.
const pageSize = 100

// PageInfo is a GraphQL page cursor.
type PageInfo struct {
	HasNextPage bool    `json:"hasNextPage"`
	EndCursor   *string `json:"endCursor"`
}

// next returns the cursor for the next page, or an error when the connection says there is
// one but gives no way to reach it.
func (p PageInfo) next(what string) (cursor string, more bool, err error) {
	if !p.HasNextPage {
		return "", false, nil
	}
	if p.EndCursor == nil || *p.EndCursor == "" {
		return "", false, exitcode.New(exitcode.Unreadable, what+" has another page but no cursor to read it")
	}
	return *p.EndCursor, true, nil
}

// Conn is a GraphQL connection read once, without following pages, as readiness and health
// read theirs: a connection that holds more than it returned is not a full read.
type Conn[T any] struct {
	TotalCount *int `json:"totalCount"`
	Nodes      *[]T `json:"nodes"`
}

// Problem names why a connection is not a full read: it is missing, or it holds more than it
// returned. A nil connection is missing. It returns "" for a full read.
func Problem[T any](c *Conn[T], name string) string {
	switch {
	case c == nil || c.TotalCount == nil || c.Nodes == nil:
		return name + " missing"
	case *c.TotalCount > len(*c.Nodes):
		return fmt.Sprintf("%s truncated (%d > %d)", name, *c.TotalCount, len(*c.Nodes))
	default:
		return ""
	}
}

// Items returns the nodes of a connection, or nil when it is missing.
func Items[T any](c *Conn[T]) []T {
	if c == nil || c.Nodes == nil {
		return nil
	}
	return *c.Nodes
}

// eachPage reads pages until the connection ends or the reader says it has what it needs. The
// reader gets the cursor to read from, "" for the first page, and returns that page's info.
func eachPage(what string, read func(after string) (info PageInfo, done bool, err error)) error {
	after := ""
	for {
		info, done, err := read(after)
		if err != nil || done {
			return err
		}
		next, more, err := info.next(what)
		if err != nil || !more {
			return err
		}
		after = next
	}
}

// pageVars are the variables of a paged repository query, with the cursor only after the first
// page.
func pageVars(repo, after string, extra ...gh.Var) []gh.Var {
	owner, name := splitRepo(repo)
	vars := append([]gh.Var{gh.String("owner", owner), gh.String("name", name)}, extra...)
	if after != "" {
		vars = append(vars, gh.String("after", after))
	}
	return vars
}
