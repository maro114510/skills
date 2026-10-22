package snapshot

import (
	"context"
	"fmt"
	"slices"
	"strings"

	"github.com/maro114510/skills/oe/internal/gh"
	"github.com/maro114510/skills/oe/internal/protocol"
)

// aliasChunk is how many Issues one comments query reads. The count of calls grows with the
// Epic only past this many open Issues.
const aliasChunk = 50

// Comment is one Issue comment. Author carries GitHub's `[bot]` suffix for a bot, so a login
// compares equal whether it was read through GraphQL, which omits the suffix, or through REST.
type Comment struct {
	ID          int64
	CreatedAt   string
	Author      string
	Association string
	Body        string
}

// Protocol returns the comment as the protocol codec reads it.
func (c Comment) Protocol() protocol.Comment {
	return protocol.Comment{ID: c.ID, Author: c.Author, Body: c.Body}
}

type commentNode struct {
	DatabaseID        int64  `json:"databaseId"`
	CreatedAt         string `json:"createdAt"`
	AuthorAssociation string `json:"authorAssociation"`
	Author            *struct {
		Typename string `json:"__typename"`
		Login    string `json:"login"`
	} `json:"author"`
	Body string `json:"body"`
}

func (n commentNode) comment() Comment {
	author := ""
	if n.Author != nil {
		author = n.Author.Login
		if n.Author.Typename == "Bot" {
			author += "[bot]"
		}
	}
	return Comment{ID: n.DatabaseID, CreatedAt: n.CreatedAt, Author: author, Association: n.AuthorAssociation, Body: n.Body}
}

type commentConn struct {
	TotalCount int           `json:"totalCount"`
	PageInfo   PageInfo      `json:"pageInfo"`
	Nodes      []commentNode `json:"nodes"`
}

type commentIssue struct {
	Number   int          `json:"number"`
	Comments *commentConn `json:"comments"`
}

const commentFields = `number comments(first: 100) { totalCount pageInfo { hasNextPage endCursor } ` +
	`nodes { databaseId createdAt authorAssociation author { __typename login } body } }`

const moreCommentsQuery = `query($owner: String!, $name: String!, $number: Int!, $after: String) {
  repository(owner: $owner, name: $name) { issue(number: $number) { number comments(first: 100, after: $after) {
    totalCount pageInfo { hasNextPage endCursor }
    nodes { databaseId createdAt authorAssociation author { __typename login } body } } } }
}`

// commentsQuery reads the first page of the comments of every listed Issue in one query, with
// one alias per Issue, so the call count does not grow with the Epic.
func commentsQuery(numbers []int) string {
	var b strings.Builder
	b.WriteString("query($owner: String!, $name: String!) { repository(owner: $owner, name: $name) {")
	for _, n := range numbers {
		fmt.Fprintf(&b, " i%d: issue(number: %d) { %s }", n, n, commentFields)
	}
	b.WriteString(" } }")
	return b.String()
}

// ReadComments reads every comment of the listed Issues, by number, with the board's own full
// read: a partial or failed read returns an error and taints the client.
func ReadComments(ctx context.Context, c *gh.Client, repo string, numbers []int) (map[int][]Comment, error) {
	return readComments(ctx, c, repo, numbers)
}

// readComments reads every comment of the listed Issues. An Issue with more comments than one
// page is read on page by page; a count that does not add up is a partial read.
func readComments(ctx context.Context, c *gh.Client, repo string, numbers []int) (map[int][]Comment, error) {
	owner, name := splitRepo(repo)
	out := make(map[int][]Comment, len(numbers))
	for chunk := range slices.Chunk(numbers, aliasChunk) {
		var data struct {
			Repository map[string]*commentIssue `json:"repository"`
		}
		vars := []gh.Var{gh.String("owner", owner), gh.String("name", name)}
		if err := c.GraphQL(ctx, commentsQuery(chunk), vars, &data); err != nil {
			return nil, err
		}
		for _, n := range chunk {
			iss := data.Repository[fmt.Sprintf("i%d", n)]
			if iss == nil || iss.Number != n || iss.Comments == nil {
				return nil, unreadable("the comments of #%d were not read", n)
			}
			all, err := allComments(ctx, c, owner, name, n, iss.Comments)
			if err != nil {
				return nil, err
			}
			out[n] = all
		}
	}
	return out, nil
}

func allComments(ctx context.Context, c *gh.Client, owner, name string, number int, first *commentConn) ([]Comment, error) {
	var all []Comment
	conn := first
	after := ""
	for {
		for _, n := range conn.Nodes {
			all = append(all, n.comment())
		}
		next, more, err := nextPage(after, conn.PageInfo, fmt.Sprintf("the comments of #%d", number))
		if err != nil {
			return nil, err
		}
		if !more {
			break
		}
		after = next
		var data struct {
			Repository *struct {
				Issue *commentIssue `json:"issue"`
			} `json:"repository"`
		}
		vars := []gh.Var{gh.String("owner", owner), gh.String("name", name), gh.Int("number", number), gh.String("after", after)}
		if err := c.GraphQL(ctx, moreCommentsQuery, vars, &data); err != nil {
			return nil, err
		}
		if data.Repository == nil || data.Repository.Issue == nil || data.Repository.Issue.Comments == nil {
			return nil, unreadable("the comments of #%d were not read", number)
		}
		conn = data.Repository.Issue.Comments
	}
	if len(all) != first.TotalCount {
		return nil, unreadable("#%d has %d comments but %d were read", number, first.TotalCount, len(all))
	}
	return all, nil
}
