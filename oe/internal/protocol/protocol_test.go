package protocol_test

import (
	"strings"
	"testing"

	"github.com/maro114510/skills/oe/internal/exitcode"
	"github.com/maro114510/skills/oe/internal/protocol"
)

// sample is a stand-in entity; the real ones arrive with #285 and #290.
type sample struct {
	protocol.Envelope

	Count  int      `json:"count"`
	Note   *string  `json:"note"`
	Items  []item   `json:"items"`
	Nested inner    `json:"nested"`
	Tags   []string `json:"tags"`
}

type item struct {
	Name string `json:"name"`
}

type inner struct {
	Flag bool `json:"flag"`
}

const validJSON = `{"protocol_version":2,"entity":"sample","key":"issue:7","revision":3,"updated_by":"tok",` +
	`"count":1,"note":null,"items":[{"name":"a"}],"nested":{"flag":true},"tags":[]}`

func stateBody(key, js string) string {
	return "<!-- oe:v2 state " + key + " -->\n```json\n" + js + "\n```\n"
}

func wantProtocol(t *testing.T, err error) {
	t.Helper()
	if err == nil {
		t.Fatal("error = nil, want a protocol error")
	}
	if got := exitcode.CodeOf(err); got != exitcode.Protocol {
		t.Errorf("CodeOf(%v) = %d, want Protocol (6)", err, got)
	}
}

type omitted struct {
	protocol.Envelope

	Maybe string `json:"maybe,omitempty"`
}

func TestOmitemptyFieldIsRejected(t *testing.T) {
	t.Parallel()

	defer func() {
		if recover() == nil {
			t.Error("DecodeState(omitempty type) did not panic")
		}
	}()
	var s omitted
	_, _ = protocol.DecodeState(stateBody("k", `{"protocol_version":2}`), &s)
}

func TestDecodeStateValid(t *testing.T) {
	t.Parallel()

	var s sample
	m, err := protocol.DecodeState(stateBody("issue:7", validJSON), &s)
	if err != nil {
		t.Fatalf("DecodeState() error = %v", err)
	}
	if m.Kind != protocol.KindState || m.Key != "issue:7" {
		t.Errorf("marker = %+v, want state issue:7", m)
	}
	if s.ProtocolVersion != 2 || s.Revision != 3 || s.UpdatedBy != "tok" || s.Count != 1 || len(s.Items) != 1 || !s.Nested.Flag {
		t.Errorf("decoded = %+v", s)
	}
}

func TestEncodeDecodeRoundTrip(t *testing.T) {
	t.Parallel()

	note := "n"
	in := sample{
		Envelope: protocol.Envelope{ProtocolVersion: 0, Entity: "sample", Key: "ledger", Revision: 1, UpdatedBy: "tok"},
		Count:    2, Note: &note, Items: []item{}, Nested: inner{Flag: false}, Tags: []string{"x"},
	}
	body, err := protocol.EncodeState(&in)
	if err != nil {
		t.Fatalf("EncodeState() error = %v", err)
	}
	if !strings.HasPrefix(body, "<!-- oe:v2 state ledger -->\n```json\n") {
		t.Errorf("body = %q, want a v2 state marker then a json fence", body)
	}
	var out sample
	if _, err := protocol.DecodeState(body, &out); err != nil {
		t.Fatalf("DecodeState(EncodeState()) error = %v", err)
	}
	if out.ProtocolVersion != protocol.Version || *out.Note != "n" || out.Count != 2 {
		t.Errorf("round trip = %+v", out)
	}
}

func TestEncodeStateRejectsBadKey(t *testing.T) {
	t.Parallel()

	for _, key := range []string{"", "has space", "x-->y", "tab\vkey", "nb\u00a0sp"} {
		in := sample{Envelope: protocol.Envelope{ProtocolVersion: 2, Entity: "sample", Key: key, Revision: 1, UpdatedBy: "t"},
			Count: 0, Note: nil, Items: nil, Nested: inner{Flag: false}, Tags: nil,
		}
		if _, err := protocol.EncodeState(&in); err == nil {
			t.Errorf("EncodeState(key %q) error = nil, want an error", key)
		}
	}
}

// TestDecodeStateFailsClosed covers every malformed state of contract §3: each exits 6.
// TestEncodeStateKeepsCodeFences: a string value carrying a Markdown code fence still reads
// back, unchanged, from the encoded body.
func TestEncodeStateKeepsCodeFences(t *testing.T) {
	t.Parallel()

	fence := "see:\n```go\nx := 1\n```\n`inline`"
	in := sample{
		Envelope: protocol.Envelope{ProtocolVersion: 2, Entity: "sample", Key: "issue:7", Revision: 1, UpdatedBy: "t"},
		Count:    0, Note: &fence, Items: []item{{Name: "```"}}, Nested: inner{Flag: false}, Tags: []string{"`"},
	}
	body, err := protocol.EncodeState(&in)
	if err != nil {
		t.Fatalf("EncodeState() error = %v", err)
	}
	var out sample
	if _, err := protocol.DecodeState(body, &out); err != nil {
		t.Fatalf("DecodeState(EncodeState()) error = %v", err)
	}
	if *out.Note != fence || out.Items[0].Name != "```" || out.Tags[0] != "`" {
		t.Errorf("round trip = %+v, want the backticks unchanged", out)
	}
}

// TestEncodeStateRejectsUnreadableEnvelope: the writer refuses any state its own reader would
// reject, so a bad write cannot leave every later run stopping with exit 6.
func TestEncodeStateRejectsUnreadableEnvelope(t *testing.T) {
	t.Parallel()

	tests := map[string]protocol.Envelope{
		"empty entity":      {ProtocolVersion: 2, Entity: "", Key: "ledger", Revision: 1, UpdatedBy: "t"},
		"empty updated_by":  {ProtocolVersion: 2, Entity: "sample", Key: "ledger", Revision: 1, UpdatedBy: ""},
		"negative revision": {ProtocolVersion: 2, Entity: "sample", Key: "ledger", Revision: -1, UpdatedBy: "t"},
	}
	for name, env := range tests {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			in := sample{Envelope: env, Count: 0, Note: nil, Items: []item{}, Nested: inner{Flag: false}, Tags: []string{}}
			body, err := protocol.EncodeState(&in)
			if err == nil {
				t.Fatalf("EncodeState() = %q, nil; want an error", body)
			}
			wantProtocol(t, err)
		})
	}
}

func TestDecodeStateFailsClosed(t *testing.T) {
	t.Parallel()

	replace := func(old, repl string) string { return strings.Replace(validJSON, old, repl, 1) }
	tests := map[string]string{
		"malformed JSON":             stateBody("issue:7", `{"protocol_version":2,`),
		"protocol version 1":         stateBody("issue:7", replace(`"protocol_version":2`, `"protocol_version":1`)),
		"protocol version 3":         stateBody("issue:7", replace(`"protocol_version":2`, `"protocol_version":3`)),
		"protocol version as float":  stateBody("issue:7", replace(`"protocol_version":2`, `"protocol_version":2.0`)),
		"protocol version as string": stateBody("issue:7", replace(`"protocol_version":2`, `"protocol_version":"2"`)),
		"missing protocol version":   stateBody("issue:7", replace(`"protocol_version":2,`, ``)),
		"missing entity field":       stateBody("issue:7", replace(`"count":1,`, ``)),
		"missing nested field":       stateBody("issue:7", replace(`{"flag":true}`, `{}`)),
		"missing field in list item": stateBody("issue:7", replace(`[{"name":"a"}]`, `[{}]`)),
		"unknown top-level field":    stateBody("issue:7", replace(`"count":1`, `"count":1,"extra":0`)),
		"unknown nested field":       stateBody("issue:7", replace(`{"flag":true}`, `{"flag":true,"x":1}`)),
		"duplicate key":              stateBody("issue:7", replace(`"count":1`, `"count":1,"count":2`)),
		"null for a non-nullable":    stateBody("issue:7", replace(`"count":1`, `"count":null`)),
		"key differs from marker":    stateBody("issue:8", validJSON),
		"empty entity":               stateBody("issue:7", replace(`"entity":"sample"`, `"entity":""`)),
		"empty updated_by":           stateBody("issue:7", replace(`"updated_by":"tok"`, `"updated_by":""`)),
		"negative revision":          stateBody("issue:7", replace(`"revision":3`, `"revision":-1`)),
		"not an object":              stateBody("issue:7", `[]`),
		"trailing data":              stateBody("issue:7", validJSON+` {}`),
		"no fence":                   "<!-- oe:v2 state issue:7 -->\n" + validJSON,
		"two fences":                 stateBody("issue:7", validJSON) + "```json\n{}\n```\n",
		"note marker":                "<!-- oe:v2 note issue:7 -->\n```json\n" + validJSON + "\n```",
		"not a loop comment":         "hello",
		"v1 marker":                  "<!-- orchestrate-epic state -->\n```json\n" + validJSON + "\n```",
		"unknown marker version":     "<!-- oe:v3 state issue:7 -->\n```json\n" + validJSON + "\n```",
	}
	for name, body := range tests {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			var s sample
			_, err := protocol.DecodeState(body, &s)
			wantProtocol(t, err)
		})
	}
}

func TestParseMarker(t *testing.T) {
	t.Parallel()

	m, ok, err := protocol.ParseMarker("<!-- oe:v2 note freeze:3 -->\n本文")
	if err != nil || !ok || m.Kind != protocol.KindNote || m.Key != "freeze:3" {
		t.Errorf("ParseMarker(note) = %+v, %v, %v", m, ok, err)
	}
}

// TestParseMarkerIgnoresOtherComments: comments that are not loop comments, HTML comments
// mentioning a word ending in "oe:" included, are neither markers nor errors.
func TestParseMarkerIgnoresOtherComments(t *testing.T) {
	t.Parallel()

	for _, body := range []string{
		"ordinary human comment",
		"<!-- a plain HTML comment -->\ntext",
		"<!-- Joe: please check -->",
		"<!-- shoe: size -->",
	} {
		if _, ok, err := protocol.ParseMarker(body); ok || err != nil {
			t.Errorf("ParseMarker(%q) = %v, %v; want not a marker, nil", body, ok, err)
		}
	}
}

// TestParseMarkerRejects covers v1 markers, unknown versions, and malformed v2 markers.
func TestParseMarkerRejects(t *testing.T) {
	t.Parallel()

	tests := []string{
		"<!-- orchestrate-epic:state issue=3 -->",
		"  <!-- orchestrate-epic ledger -->",
		"orchestrate-epic: started #3",
		"orchestrate-epic state: cycle=1",
		"orchestrate-epic ledger: used=1",
		"orchestrate-epic post-merge: pr=4",
		"orchestrate-epic Q&A: answer",
		"<!-- oe:v1 state ledger -->",
		"<!-- oe:v3 state ledger -->",
		"<!-- oe:v2 bogus ledger -->",
		"<!-- oe:v2 state -->",
		"<!-- oe:v2 state ledger extra -->",
		"<!-- oe:v2 state ledger",
		"<!--oe:v2 state ledger -->",
		"<!--  oe:v2 state ledger -->",
		"<!-- OE:v2 state ledger -->",
		"<!-- oe:V2 state ledger -->",
	}
	for _, body := range tests {
		t.Run(body, func(t *testing.T) {
			t.Parallel()
			_, _, err := protocol.ParseMarker(body)
			wantProtocol(t, err)
		})
	}
}

func TestScan(t *testing.T) {
	t.Parallel()

	comments := []protocol.Comment{
		{ID: 1, Author: "me", Body: stateBody("ledger", "{}")},
		{ID: 2, Author: "me", Body: "<!-- oe:v2 note freeze:1 -->\nfrozen"},
		{ID: 3, Author: "me", Body: "<!-- oe:v2 note freeze:1 -->\nfrozen again"},
		{ID: 4, Author: "other", Body: stateBody("ledger", "{}")},
		{ID: 5, Author: "other", Body: "<!-- orchestrate-epic:state -->"},
		{ID: 6, Author: "me", Body: "plain text by me"},
	}
	idx, err := protocol.Scan(comments, "me")
	if err != nil {
		t.Fatalf("Scan() error = %v", err)
	}
	if got := idx.States["ledger"].ID; got != 1 || len(idx.States) != 1 {
		t.Errorf("States = %+v, want only comment 1", idx.States)
	}
	if got := len(idx.Notes["freeze:1"]); got != 2 {
		t.Errorf("Notes[freeze:1] = %d comments, want 2; duplicate notes are harmless", got)
	}
}

func TestScanFailsClosed(t *testing.T) {
	t.Parallel()

	tests := map[string][]protocol.Comment{
		"two state comments for one key": {
			{ID: 1, Author: "me", Body: stateBody("issue:3", "{}")},
			{ID: 9, Author: "me", Body: stateBody("issue:3", "{}")},
		},
		"v1 marker by me":       {{ID: 1, Author: "me", Body: "<!-- orchestrate-epic:state -->"}},
		"unknown version by me": {{ID: 1, Author: "me", Body: "<!-- oe:v9 state ledger -->"}},
	}
	for name, comments := range tests {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			_, err := protocol.Scan(comments, "me")
			wantProtocol(t, err)
		})
	}
}

func TestScanRequiresMe(t *testing.T) {
	t.Parallel()

	if _, err := protocol.Scan(nil, ""); err == nil {
		t.Error("Scan(me empty) error = nil, want an error")
	}
}
