package scan

import (
	"errors"
	"strconv"
	"strings"
)

// errPatch stops the scan instead of skipping what the parser cannot follow.
var errPatch = errors.New("unparseable patch")

// fileDiff is one file of a patch with its new path and added lines.
type fileDiff struct {
	path    string
	deleted bool
	binary  bool
	added   []addedLine
}

type addedLine struct {
	line int
	text string
}

// parser reads git patches with no context lines, including combined merge diffs.
// A combined diff has one prefix column per parent.
// A line counts as added only when it is new against every parent.
type parser struct {
	files   []fileDiff
	cur     *fileDiff
	inHunk  bool
	parents int
	next    int
}

func parsePatch(out []byte) ([]fileDiff, error) {
	p := parser{files: nil, cur: nil, inHunk: false, parents: 0, next: 0}
	lines := strings.Split(string(out), "\n")
	if lines[len(lines)-1] == "" {
		lines = lines[:len(lines)-1]
	}
	for _, line := range lines {
		if err := p.line(line); err != nil {
			return nil, err
		}
	}
	p.flush()
	return p.files, nil
}

func (p *parser) flush() {
	if p.cur != nil {
		p.files = append(p.files, *p.cur)
		p.cur = nil
	}
}

func (p *parser) start(path string, parents int) {
	p.flush()
	p.cur = &fileDiff{path: path, deleted: false, binary: false, added: nil}
	p.inHunk = false
	p.parents = parents
}

func (p *parser) line(line string) error {
	switch {
	case strings.HasPrefix(line, "diff --git "):
		p.start(gitHeaderPath(strings.TrimPrefix(line, "diff --git ")), 1)
		return nil
	case strings.HasPrefix(line, "diff --cc "):
		p.start(unquote(strings.TrimPrefix(line, "diff --cc ")), 0)
		return nil
	case p.cur == nil:
		return errPatch
	case strings.HasPrefix(line, "@@"):
		return p.hunk(line)
	case p.inHunk:
		return p.content(line)
	default:
		p.header(line)
		return nil
	}
}

func (p *parser) header(line string) {
	switch {
	case strings.HasPrefix(line, "+++ "):
		// Git ends the path with a tab when it holds a space.
		if target := strings.TrimSuffix(strings.TrimPrefix(line, "+++ "), "\t"); target == "/dev/null" {
			p.cur.deleted = true
		} else {
			p.cur.path = strings.TrimPrefix(unquote(target), "b/")
		}
	case strings.HasPrefix(line, "deleted file mode"):
		p.cur.deleted = true
	case strings.HasPrefix(line, "rename to "):
		p.cur.path = unquote(strings.TrimPrefix(line, "rename to "))
	case strings.HasPrefix(line, "copy to "):
		p.cur.path = unquote(strings.TrimPrefix(line, "copy to "))
	case strings.HasPrefix(line, "Binary files "):
		p.cur.binary = !strings.HasSuffix(line, " and /dev/null differ")
	}
}

// hunk reads a hunk header and sets the next line number of the new file.
func (p *parser) hunk(line string) error {
	marks := len(line) - len(strings.TrimLeft(line, "@"))
	if p.parents == 0 {
		p.parents = marks - 1
	}
	if p.parents != marks-1 || p.parents < 1 {
		return errPatch
	}
	for field := range strings.FieldsSeq(line[marks:]) {
		if !strings.HasPrefix(field, "+") {
			continue
		}
		start, _, _ := strings.Cut(field[1:], ",")
		n, err := strconv.Atoi(start)
		if err != nil {
			return errPatch
		}
		p.next = n
		p.inHunk = true
		return nil
	}
	return errPatch
}

func (p *parser) content(line string) error {
	if strings.HasPrefix(line, `\`) {
		return nil // A missing final newline.
	}
	if len(line) < p.parents {
		return errPatch
	}
	prefix := line[:p.parents]
	if strings.Trim(prefix, " +-") != "" {
		return errPatch
	}
	if strings.Contains(prefix, "-") {
		return nil // Not in the new file.
	}
	if strings.Count(prefix, "+") == p.parents {
		p.cur.added = append(p.cur.added, addedLine{line: p.next, text: line[p.parents:]})
	}
	p.next++
	return nil
}

// gitHeaderPath takes the new path from the diff header, for a file whose patch has no new path line.
func gitHeaderPath(rest string) string {
	if strings.HasPrefix(rest, `"`) {
		if q, err := strconv.QuotedPrefix(rest); err == nil {
			rest = strings.TrimPrefix(rest[len(q):], " ")
			return strings.TrimPrefix(unquote(rest), "b/")
		}
	}
	// An unchanged path makes two equal halves around one space.
	if half := len(rest) >> 1; len(rest)&1 == 1 {
		if rest[half] == ' ' && strings.HasPrefix(rest, "a/") && strings.HasPrefix(rest[half+1:], "b/") &&
			rest[2:half] == rest[half+3:] {
			return rest[half+3:]
		}
	}
	if i := strings.LastIndex(rest, " b/"); i >= 0 {
		return unquote(rest[i+3:])
	}
	return unquote(rest)
}

// unquote undoes git's quoting of a path.
func unquote(s string) string {
	if !strings.HasPrefix(s, `"`) {
		return s
	}
	if u, err := strconv.Unquote(s); err == nil {
		return u
	}
	return s
}
