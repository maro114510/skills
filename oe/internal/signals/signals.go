// Package signals decides which comments are human signals, contract §2. Trust guards against
// model mistakes, not forgery: a human and the loop share one identity.
package signals

import "strings"

// Command is one of the seven strict human commands.
type Command string

// The strict commands. A comment is a command only when every non-blank line is exactly one of
// them, in lowercase.
const (
	None            Command = ""
	Approve         Command = "epic-approve"
	AutoMerge       Command = "epic-auto-merge"
	RevokeAutoMerge Command = "epic-revoke-auto-merge"
	Release         Command = "epic-release"
	Retry           Command = "epic-retry"
	Redo            Command = "epic-redo"
	Drop            Command = "epic-drop"
)

// The prefixes of a loop comment: a marker, or the plain-text opening the earlier version used.
const (
	loopPrefixPlain    = "orchestrate-epic"
	loopPrefixMarkdown = "<!--"
)

func known(c Command) bool {
	switch c {
	case Approve, AutoMerge, RevokeAutoMerge, Release, Retry, Redo, Drop:
		return true
	case None:
		return false
	default:
		return false
	}
}

// Trusted reports whether a comment can carry a human signal: its author is an owner, member,
// or collaborator, and its body starts with neither a loop marker nor the loop's plain prefix.
func Trusted(authorAssociation, body string) bool {
	switch authorAssociation {
	case "OWNER", "MEMBER", "COLLABORATOR":
	default:
		return false
	}
	return !strings.HasPrefix(body, loopPrefixPlain) && !strings.HasPrefix(body, loopPrefixMarkdown)
}

// Blank reports whether a body has no non-blank line. A blank comment signals nothing.
func Blank(body string) bool { return len(lines(body)) == 0 }

// Parse returns the strict command a body holds, or None. "let's not epic-retry yet",
// "EPIC-RETRY", "epic-retry please", and two different commands in one comment are not commands.
func Parse(body string) Command {
	ls := lines(body)
	if len(ls) == 0 {
		return None
	}
	for _, l := range ls[1:] {
		if l != ls[0] {
			return None
		}
	}
	if c := Command(ls[0]); known(c) {
		return c
	}
	return None
}

func lines(body string) []string {
	var out []string
	for l := range strings.SplitSeq(body, "\n") {
		if t := strings.TrimSpace(l); t != "" {
			out = append(out, t)
		}
	}
	return out
}
