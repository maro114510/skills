package coord

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"net/http"
	"strings"
	"unicode"

	"github.com/maro114510/skills/oe/internal/exitcode"
	"github.com/maro114510/skills/oe/internal/protocol"
	"github.com/maro114510/skills/oe/internal/scan"
)

// digestLen is the length of a digest, contract §7.
const digestLen = 12

// DigestPlaceholder in a note key is replaced by the digest of the note's text, so a key such
// as qa:<n>:{digest} names the exact answer it records.
const DigestPlaceholder = "{digest}"

// Digest is the first 12 hex characters of the sha256 of text.
func Digest(text string) string {
	sum := sha256.Sum256([]byte(text))
	return hex.EncodeToString(sum[:])[:digestLen]
}

// NoteResult is what the comment writer did with one note.
type NoteResult struct {
	On  int    `json:"on"`
	Key string `json:"key"`
	// Posted is false when a note with the key already existed; nothing was posted then.
	Posted    bool  `json:"posted"`
	CommentID int64 `json:"comment_id"`
	// Findings are the scan's findings when the text was refused.
	Findings []scan.Finding `json:"findings"`
}

// ScanError is a note refused by the secret scan. Nothing was posted.
type ScanError struct {
	Result NoteResult
}

func (e *ScanError) Error() string {
	rules := make([]string, 0, len(e.Result.Findings))
	for _, f := range e.Result.Findings {
		rules = append(rules, f.Rule)
	}
	return "note " + e.Result.Key + " holds a suspected secret (" + strings.Join(rules, ", ") + "); nothing was posted"
}

// Unwrap gives the error its exit code, 8.
func (e *ScanError) Unwrap() error { return exitcode.New(exitcode.Refused, "scan finding") }

// prepareNote checks the key and the Issue, renders the body, and refuses a scan finding or an
// oversized body before anything is read.
func prepareNote(on int, key, text string) (NoteResult, string, error) {
	key, err := noteKey(key, text)
	res := NoteResult{On: on, Key: key, Posted: false, CommentID: 0, Findings: []scan.Finding{}}
	if err != nil {
		return res, "", err
	}
	if on <= 0 {
		return res, "", exitcode.New(exitcode.Usage, "a note needs a positive Issue number")
	}
	body := fmt.Sprintf("<!-- oe:v%d %s %s -->\n%s", protocol.Version, protocol.KindNote, key, text)
	if report := scan.Text("note:"+key, []byte(body)); !report.Clean {
		res.Findings = report.Findings
		return res, "", &ScanError{Result: res}
	}
	if err := publishable("note "+key, body); err != nil {
		return res, "", err
	}
	return res, body, nil
}

// noteKey checks a dedup key and fills in its digest.
func noteKey(key, text string) (string, error) {
	key = strings.ReplaceAll(key, DigestPlaceholder, Digest(text))
	if key == "" || strings.ContainsFunc(key, unicode.IsSpace) || strings.Contains(key, "-->") || strings.Contains(key, "{") {
		return "", exitcode.New(exitcode.Usage, fmt.Sprintf("invalid note key %q", key))
	}
	return key, nil
}

// PostNote is the single comment writer, contract §7: it scans the text and posts nothing on a
// finding, checks the lease, looks the key up among the loop's own notes with a full read and
// does nothing when it is there, and only then posts. A failed post is re-read by key, so a
// post whose response was lost is not posted again.
func (s *Session) PostNote(ctx context.Context, on int, key, text string) (NoteResult, error) {
	res, body, err := prepareNote(on, key, text)
	if err != nil {
		return res, err
	}
	key = res.Key
	if err := s.checkLease(ctx); err != nil {
		return res, err
	}
	r, err := s.read(ctx, on)
	if err != nil {
		return res, err
	}
	if id := r.noteID(key); id != 0 {
		res.CommentID = id
		return res, nil
	}
	path := fmt.Sprintf("repos/%s/%s/issues/%d/comments", s.owner, s.name, on)
	out, err := s.c.Write(ctx, "api", "-X", http.MethodPost, path, "-f", "body="+body)
	if err != nil {
		if again, rerr := s.read(ctx, on); rerr == nil {
			if id := again.noteID(key); id != 0 {
				res.Posted, res.CommentID = true, id
				return res, nil
			}
		}
		return res, exitcode.Wrap(exitcode.Unreadable, err, "note "+key+" was not posted")
	}
	if res.CommentID, err = postedID(out); err != nil {
		return res, err
	}
	res.Posted = true
	return res, nil
}
