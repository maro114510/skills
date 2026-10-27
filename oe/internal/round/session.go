// Package round decides what an orchestrate-epic invocation does between its landing passes,
// contract §20: which work a round starts, how long landing waits, whether the session goes on
// into another round, and when the Epic is complete.
//
// One lease session is one invocation. What an invocation keeps, the polls it spent, the Issues
// it deferred, and the merges it saw, lives in a host-local file named by the lease token, so a
// resumed session continues its counts and a new session starts clean. Nothing in the file
// widens what a round may do: it only narrows it, and GitHub stays the source of every state.
package round

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"slices"
	"strings"

	"github.com/maro114510/skills/oe/internal/coord"
	"github.com/maro114510/skills/oe/internal/exitcode"
)

// sessionVersion is the version of the session file, which a file of any other version never reads as.
const sessionVersion = 1

// fileFields are the fields every session file holds. A file that lacks one is refused, because a
// missing field would decode as zero and silently drop a count, a deferral, or the round.
var fileFields = []string{"version", "known", "mark", "merges", "rounds", "polls", "round", "deferred", "no_checks"} //nolint:gochecknoglobals // A fixed table of the file format.

// The permissions of the session directory and file: this user's only.
const (
	dirPerm  = 0o700
	filePerm = 0o600
)

// The limits of one invocation, contract §20.
const (
	// PollLimit is how many 60-second polls landing spends between two merges.
	PollLimit = 30
	// PollSleepSeconds is one poll's sleep, always its own call.
	PollSleepSeconds = 60
	// NoChecksLimit is how many polls a pull request whose head reports no checks gets.
	NoChecksLimit = 5
)

// Reason says why an Issue was deferred to the next invocation.
type Reason string

// The reasons, a closed set.
const (
	// ReasonBlocked is a BLOCKED worker with no documented answer.
	ReasonBlocked Reason = "blocked"
	// ReasonStale is a verdict that went stale a second time in the session.
	ReasonStale Reason = "stale"
	// ReasonTurn is a landing candidate that gave up its turn.
	ReasonTurn Reason = "gave-up-turn"
)

// ParseReason accepts only a reason of the closed set.
func ParseReason(s string) (Reason, bool) {
	switch r := Reason(s); r {
	case ReasonBlocked, ReasonStale, ReasonTurn:
		return r, true
	}
	return "", false
}

// Deferral is an Issue the invocation left for the next one.
type Deferral struct {
	Issue  int    `json:"issue"`
	Reason Reason `json:"reason"`
}

// Baseline is what a round started from.
type Baseline struct {
	// Mark is the latest merge the loop had recorded when the round began.
	Mark string `json:"mark"`
	// Verifying is whether the round began with an Issue whose merge was still being verified.
	Verifying bool `json:"verifying"`
}

// NoChecks counts the polls a pull request spent with no check reported on its head.
type NoChecks struct {
	Head  string `json:"head"`
	Polls int    `json:"polls"`
}

// Session is what one invocation keeps.
type Session struct {
	Version int `json:"version"`
	// Known says Mark was read at least once, so a merge made before this session never counts.
	Known bool `json:"known"`
	// Mark is the latest merge seen, as "<pr>:<merge sha>".
	Mark string `json:"mark"`
	// Merges counts the merges seen since the session began.
	Merges int `json:"merges"`
	// Rounds counts the rounds begun.
	Rounds int `json:"rounds"`
	// Polls counts the polls spent since the last merge.
	Polls    int                 `json:"polls"`
	Round    *Baseline           `json:"round"`
	Deferred []Deferral          `json:"deferred"`
	NoChecks map[string]NoChecks `json:"no_checks"`
}

// New is a session that has seen nothing.
func New() *Session {
	return &Session{
		Version: sessionVersion, Known: false, Mark: "", Merges: 0, Rounds: 0, Polls: 0, Round: nil,
		Deferred: []Deferral{}, NoChecks: map[string]NoChecks{},
	}
}

// Path is the file of one invocation: <state dir>/sessions/<owner>-<repo>-<epic>-<token digest>.json.
func Path(stateDir, repo string, epic int, token string) string {
	owner, name, _ := strings.Cut(repo, "/")
	return filepath.Join(stateDir, "sessions", fmt.Sprintf("%s-%s-%d-%s.json", owner, name, epic, coord.Digest(token)))
}

// Load reads a session. A file that does not exist is a session that has seen nothing; one that
// cannot be read or decoded stops with exit 1, so a damaged file never reads as a clean start.
func Load(path string) (*Session, error) {
	data, err := os.ReadFile(path) //nolint:gosec // G304: the path is built from the resolved repository, Epic, and lease token.
	if errors.Is(err, fs.ErrNotExist) {
		return New(), nil
	}
	if err != nil {
		return nil, exitcode.Wrap(exitcode.Unreadable, err, "the session file "+path+" cannot be read")
	}
	if err := requireFields(data); err != nil {
		return nil, exitcode.Wrap(exitcode.Unreadable, err, "the session file "+path+" is damaged; delete it to start this invocation's counts over")
	}
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.DisallowUnknownFields()
	s := New()
	s.Version = 0
	if err := dec.Decode(s); err != nil {
		return nil, exitcode.Wrap(exitcode.Unreadable, err, "the session file "+path+" is damaged; delete it to start this invocation's counts over")
	}
	if _, err := dec.Token(); !errors.Is(err, io.EOF) {
		return nil, exitcode.New(exitcode.Unreadable, "the session file "+path+" holds more than one value; delete it to start this invocation's counts over")
	}
	if s.Version != sessionVersion {
		return nil, exitcode.New(exitcode.Unreadable, fmt.Sprintf("the session file %s is version %d, not %d", path, s.Version, sessionVersion))
	}
	if s.Deferred == nil {
		s.Deferred = []Deferral{}
	}
	if s.NoChecks == nil {
		s.NoChecks = map[string]NoChecks{}
	}
	if err := validateSession(s); err != nil {
		return nil, exitcode.Wrap(exitcode.Unreadable, err, "the session file "+path+" holds values no session wrote; delete it to start this invocation's counts over")
	}
	return s, nil
}

// requireFields checks that the file is one JSON object with every field of the format.
func requireFields(data []byte) error {
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(data, &raw); err != nil {
		return fmt.Errorf("the file is not one JSON object: %w", err)
	}
	for _, f := range fileFields {
		if _, ok := raw[f]; !ok {
			return fmt.Errorf("the field %q is missing", f)
		}
	}
	return nil
}

// validateSession refuses a value no session could have written: a negative count, an Issue below 1, or
// a reason outside the closed set.
func validateSession(s *Session) error {
	if s.Merges < 0 || s.Rounds < 0 || s.Polls < 0 {
		return errors.New("a count is negative")
	}
	for _, d := range s.Deferred {
		if _, ok := ParseReason(string(d.Reason)); !ok || d.Issue < 1 {
			return fmt.Errorf("the deferral of Issue %d for %q is not one a session records", d.Issue, d.Reason)
		}
	}
	for pr, nc := range s.NoChecks {
		if nc.Polls < 0 {
			return fmt.Errorf("pull request %s has a negative no-checks count", pr)
		}
	}
	return nil
}

// Save writes the session whole, through a temporary file and a rename.
func (s *Session) Save(path string) error {
	data, err := json.Marshal(s)
	if err != nil {
		return exitcode.Wrap(exitcode.Unreadable, err, "the session cannot be encoded")
	}
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, dirPerm); err != nil {
		return exitcode.Wrap(exitcode.Unreadable, err, "the session directory cannot be created")
	}
	tmp, err := os.CreateTemp(dir, filepath.Base(path)+".*")
	if err != nil {
		return exitcode.Wrap(exitcode.Unreadable, err, "the session file cannot be created")
	}
	_, werr := tmp.Write(append(data, '\n'))
	// The data is on disk before the rename, so a crash never leaves the new name on an empty file.
	serr := tmp.Sync()
	cerr := tmp.Close()
	if err := errors.Join(werr, serr, cerr); err != nil {
		_ = os.Remove(tmp.Name())
		return exitcode.Wrap(exitcode.Unreadable, err, "the session file cannot be written")
	}
	if err := os.Chmod(tmp.Name(), filePerm); err != nil {
		_ = os.Remove(tmp.Name())
		return exitcode.Wrap(exitcode.Unreadable, err, "the session file cannot be protected")
	}
	if err := os.Rename(tmp.Name(), path); err != nil {
		_ = os.Remove(tmp.Name())
		return exitcode.Wrap(exitcode.Unreadable, err, "the session file cannot be replaced")
	}
	return syncDir(dir)
}

// syncDir makes the rename durable.
func syncDir(dir string) error {
	d, err := os.Open(dir) //nolint:gosec // G304: the directory is the session directory this package just wrote to.
	if err != nil {
		return exitcode.Wrap(exitcode.Unreadable, err, "the session directory cannot be opened to sync")
	}
	serr := d.Sync()
	cerr := d.Close()
	if err := errors.Join(serr, cerr); err != nil {
		return exitcode.Wrap(exitcode.Unreadable, err, "the session directory cannot be synced")
	}
	return nil
}

// Defer records an Issue as left for the next invocation. Recording one again changes nothing.
func (s *Session) Defer(issue int, reason Reason) {
	if slices.ContainsFunc(s.Deferred, func(d Deferral) bool { return d.Issue == issue }) {
		return
	}
	s.Deferred = append(s.Deferred, Deferral{Issue: issue, Reason: reason})
	slices.SortFunc(s.Deferred, func(a, b Deferral) int { return a.Issue - b.Issue })
}

// DeferredSet is the deferred Issues by number.
func (s *Session) DeferredSet() map[int]Reason {
	out := make(map[int]Reason, len(s.Deferred))
	for _, d := range s.Deferred {
		out[d.Issue] = d.Reason
	}
	return out
}
