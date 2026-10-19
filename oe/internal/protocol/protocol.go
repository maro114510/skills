// Package protocol is the v2 loop-comment codec of contract §3. It fails closed: a v1 marker,
// an unknown protocol version, malformed or incomplete JSON, a key that differs from its marker,
// or two state comments for one key all stop with exit 6 and nothing is written.
package protocol

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"maps"
	"reflect"
	"slices"
	"strconv"
	"strings"
	"unicode"

	"github.com/maro114510/skills/oe/internal/exitcode"
)

// Version is the only protocol version oe reads or writes.
const Version = 2

// Kind is the kind of a loop comment.
type Kind string

// The loop-comment kinds of contract §3.
const (
	KindState Kind = "state"
	KindNote  Kind = "note"
)

const (
	markerOpen  = "<!-- "
	markerClose = " -->"
	v2Prefix    = "<!-- oe:v"
	fenceOpen   = "```json\n"
	fenceClose  = "\n```"
	markerWords = 3 // oe:v<version> <kind> <key>
)

// Marker is a parsed v2 marker.
type Marker struct {
	Kind Kind
	Key  string
}

// Comment is one Issue comment, as far as the codec needs it.
type Comment struct {
	ID     int64
	Author string
	Body   string
}

// Envelope holds the fields every state object carries. Embed it in each entity type.
type Envelope struct {
	ProtocolVersion int    `json:"protocol_version"`
	Entity          string `json:"entity"`
	Key             string `json:"key"`
	Revision        int64  `json:"revision"`
	UpdatedBy       string `json:"updated_by"`
}

// StateEnvelope gives the codec access to an entity's envelope.
func (e *Envelope) StateEnvelope() *Envelope { return e }

// State is any entity type that embeds Envelope.
type State interface {
	StateEnvelope() *Envelope
}

func protoErr(format string, args ...any) error {
	return exitcode.New(exitcode.Protocol, fmt.Sprintf(format, args...))
}

// IsV1 reports whether a body starts with a v1 orchestrate-epic marker.
func IsV1(body string) bool {
	b := strings.TrimLeft(body, " \t\r\n")
	if strings.HasPrefix(b, "<!-- orchestrate-epic") || strings.HasPrefix(b, "orchestrate-epic:") {
		return true
	}
	rest, ok := strings.CutPrefix(b, "orchestrate-epic ")
	if !ok {
		return false
	}
	for _, p := range []string{"state:", "ledger:", "post-merge:", "Q&A:"} {
		if strings.HasPrefix(rest, p) {
			return true
		}
	}
	return false
}

// ParseMarker reads the marker on a comment's first line. It returns ok=false, nil for a body
// that is no loop comment, and a protocol error for a v1 marker, another version, or a
// malformed v2 marker.
func ParseMarker(body string) (Marker, bool, error) {
	if IsV1(body) {
		return Marker{}, false, protoErr("v1 orchestrate-epic marker found; a human must remove v1 leftovers")
	}
	b := strings.TrimLeft(body, " \t\r\n")
	line, _, _ := strings.Cut(b, "\n")
	if !strings.HasPrefix(b, v2Prefix) {
		// A near miss such as `<!--oe:v2` or `<!-- OE:v2` would otherwise read as no state and
		// invite a second state comment for the same key.
		if after, ok := strings.CutPrefix(b, "<!--"); ok && strings.HasPrefix(strings.ToLower(strings.TrimLeft(after, " \t")), "oe:") {
			return Marker{}, false, protoErr("malformed oe marker %q", line)
		}
		return Marker{Kind: "", Key: ""}, false, nil
	}
	return parseV2Line(strings.TrimRight(line, " \t\r"))
}

// parseV2Line parses a first line that starts with the v2 prefix.
func parseV2Line(line string) (Marker, bool, error) {
	inner, ok := strings.CutPrefix(line, markerOpen)
	if ok {
		inner, ok = strings.CutSuffix(inner, markerClose)
	}
	if !ok {
		return Marker{}, false, protoErr("malformed oe marker %q", line)
	}
	words := strings.Fields(inner)
	if len(words) != markerWords {
		return Marker{}, false, protoErr("malformed oe marker %q: want oe:v2 <kind> <key>", line)
	}
	if words[0] != fmt.Sprintf("oe:v%d", Version) {
		return Marker{}, false, protoErr("unknown protocol version in marker %q", line)
	}
	kind := Kind(words[1])
	if kind != KindState && kind != KindNote {
		return Marker{}, false, protoErr("unknown comment kind %q in marker %q", words[1], line)
	}
	return Marker{Kind: kind, Key: words[2]}, true, nil
}

// Index is the result of scanning ME's loop comments.
type Index struct {
	States map[string]Comment
	Notes  map[string][]Comment
}

// Scan indexes ME's loop comments by key. Other authors' comments are ignored, markers
// included. A v1 marker, an unknown or malformed marker, or a second state comment for a key
// stops with a protocol error. Duplicate notes are kept; they are harmless.
func Scan(comments []Comment, me string) (Index, error) {
	if me == "" {
		return Index{}, exitcode.New(exitcode.Unreadable, "the authenticated login (ME) is unknown")
	}
	idx := Index{States: map[string]Comment{}, Notes: map[string][]Comment{}}
	for _, c := range comments {
		if c.Author != me {
			continue
		}
		m, ok, err := ParseMarker(c.Body)
		if err != nil {
			return Index{}, fmt.Errorf("comment %d: %w", c.ID, err)
		}
		if !ok {
			continue
		}
		if m.Kind == KindNote {
			idx.Notes[m.Key] = append(idx.Notes[m.Key], c)
			continue
		}
		if prev, dup := idx.States[m.Key]; dup {
			return Index{}, protoErr("two state comments for key %q: %d and %d; a human must remove one", m.Key, prev.ID, c.ID)
		}
		idx.States[m.Key] = c
	}
	return idx, nil
}

// DecodeState decodes a state comment body into s and checks it against its marker.
func DecodeState(body string, s State) (Marker, error) {
	m, ok, err := ParseMarker(body)
	if err != nil {
		return Marker{}, err
	}
	if !ok || m.Kind != KindState {
		return Marker{}, protoErr("not a v2 state comment")
	}
	b := strings.TrimLeft(body, " \t\r\n")
	_, rest, _ := strings.Cut(b, "\n")
	js, err := fenced(rest)
	if err != nil {
		return Marker{}, err
	}
	if err := decodeStrict(js, s); err != nil {
		return Marker{}, protoErr("state %q: %v", m.Key, err)
	}
	if err := checkEnvelope(s.StateEnvelope(), m.Key); err != nil {
		return Marker{}, err
	}
	return m, nil
}

// EncodeState renders s as a state comment body, setting its protocol version.
func EncodeState(s State) (string, error) {
	env := s.StateEnvelope()
	if env.Key == "" || strings.ContainsFunc(env.Key, unicode.IsSpace) || strings.Contains(env.Key, "-->") {
		return "", exitcode.New(exitcode.Usage, fmt.Sprintf("invalid state key %q", env.Key))
	}
	// The writer applies the reader's envelope checks, so it never posts a state that
	// DecodeState would reject and every later run would stop on.
	if err := checkEnvelope(env, env.Key); err != nil {
		return "", err
	}
	if err := checkSchema(reflect.TypeOf(s)); err != nil {
		return "", protoErr("state %q: %v", env.Key, err)
	}
	env.ProtocolVersion = Version
	js, err := json.MarshalIndent(s, "", "  ")
	if err != nil {
		return "", fmt.Errorf("encode state %q: %w", env.Key, err)
	}
	// A backtick can only sit inside a JSON string, so escaping it is lossless, and a value such
	// as a Markdown code fence can no longer close the comment's json fence.
	js = bytes.ReplaceAll(js, []byte("`"), []byte(`\u0060`))
	body := fmt.Sprintf("<!-- oe:v%d %s %s -->\n%s%s%s\n", Version, KindState, env.Key, fenceOpen, js, fenceClose)
	// Read the body back before anyone posts it: any encode/decode mismatch fails here instead
	// of stopping every later run with exit 6.
	back, ok := reflect.TypeAssert[State](reflect.New(reflect.TypeOf(s).Elem()))
	if !ok {
		return "", exitcode.New(exitcode.Usage, "state type cannot be read back")
	}
	if _, err := DecodeState(body, back); err != nil {
		return "", exitcode.Wrap(exitcode.Protocol, err, fmt.Sprintf("encoded state %q does not read back", env.Key))
	}
	return body, nil
}

// decodeStrict checks the exact protocol version and the presence of every field, then
// decodes with unknown fields rejected.
func decodeStrict(js string, s State) error {
	fields, err := objectFields([]byte(js))
	if err != nil {
		return err
	}
	if v, ok := fields["protocol_version"]; !ok || string(v) != strconv.Itoa(Version) {
		return fmt.Errorf("protocol_version must be the integer %d", Version)
	}
	if err := checkFields(json.RawMessage(js), reflect.TypeOf(s), "$"); err != nil {
		return err
	}
	dec := json.NewDecoder(strings.NewReader(js))
	dec.DisallowUnknownFields()
	if err := dec.Decode(s); err != nil {
		return fmt.Errorf("decode: %w", err)
	}
	return nil
}

func checkEnvelope(env *Envelope, key string) error {
	switch {
	case env.Key != key:
		return protoErr("state key %q differs from its marker key %q", env.Key, key)
	case env.Entity == "":
		return protoErr("state %q: empty entity", key)
	case env.UpdatedBy == "":
		return protoErr("state %q: empty updated_by", key)
	case env.Revision < 0:
		return protoErr("state %q: negative revision", key)
	}
	return nil
}

// fenced returns the content of the one ```json fence that must make up the rest of the body.
func fenced(rest string) (string, error) {
	r := strings.TrimSpace(rest)
	inner, ok := strings.CutPrefix(r, fenceOpen)
	if ok {
		inner, ok = strings.CutSuffix(inner, fenceClose)
	}
	if !ok || strings.Contains(inner, "```") {
		return "", protoErr("state body must be exactly one fenced json block")
	}
	return inner, nil
}

// objectFields decodes one JSON object into its raw fields, rejecting duplicate keys and
// trailing data, both of which encoding/json would otherwise accept silently.
func objectFields(data []byte) (map[string]json.RawMessage, error) {
	dec := json.NewDecoder(bytes.NewReader(data))
	tok, err := dec.Token()
	if err != nil {
		return nil, fmt.Errorf("parse: %w", err)
	}
	if d, ok := tok.(json.Delim); !ok || d != '{' {
		return nil, errors.New("not a JSON object")
	}
	fields := map[string]json.RawMessage{}
	for dec.More() {
		name, v, err := nextField(dec)
		if err != nil {
			return nil, err
		}
		if _, dup := fields[name]; dup {
			return nil, fmt.Errorf("duplicate field %q", name)
		}
		fields[name] = v
	}
	if _, err := dec.Token(); err != nil {
		return nil, fmt.Errorf("parse: %w", err)
	}
	if _, err := dec.Token(); !errors.Is(err, io.EOF) {
		return nil, errors.New("trailing data after the object")
	}
	return fields, nil
}

func nextField(dec *json.Decoder) (string, json.RawMessage, error) {
	tok, err := dec.Token()
	if err != nil {
		return "", nil, fmt.Errorf("parse: %w", err)
	}
	name, ok := tok.(string)
	if !ok {
		return "", nil, errors.New("parse: object key is not a string")
	}
	var v json.RawMessage
	if err := dec.Decode(&v); err != nil {
		return "", nil, fmt.Errorf("parse field %q: %w", name, err)
	}
	return name, v, nil
}

// checkFields requires every field of t to be present in raw, recursively through structs,
// pointers to structs, and slices, and rejects null for a type that cannot hold it.
func checkFields(raw json.RawMessage, t reflect.Type, path string) error {
	if string(bytes.TrimSpace(raw)) == "null" {
		switch t.Kind() {
		case reflect.Pointer, reflect.Slice, reflect.Map, reflect.Interface:
			return nil
		default:
			return fmt.Errorf("%s is null", path)
		}
	}
	for t.Kind() == reflect.Pointer {
		t = t.Elem()
	}
	switch t.Kind() { //nolint:exhaustive // Scalars need no field check.
	case reflect.Struct:
		return checkStruct(raw, t, path)
	case reflect.Slice:
		var elems []json.RawMessage
		if err := json.Unmarshal(raw, &elems); err != nil {
			return fmt.Errorf("%s: %w", path, err)
		}
		for i, e := range elems {
			if err := checkFields(e, t.Elem(), fmt.Sprintf("%s[%d]", path, i)); err != nil {
				return err
			}
		}
	}
	return nil
}

func checkStruct(raw json.RawMessage, t reflect.Type, path string) error {
	fields, err := objectFields(raw)
	if err != nil {
		return fmt.Errorf("%s: %w", path, err)
	}
	want, err := jsonFields(t)
	if err != nil {
		return err
	}
	for _, name := range slices.Sorted(maps.Keys(want)) {
		v, ok := fields[name]
		if !ok {
			return fmt.Errorf("%s.%s is missing", path, name)
		}
		if err := checkFields(v, want[name], path+"."+name); err != nil {
			return err
		}
	}
	for _, name := range slices.Sorted(maps.Keys(fields)) {
		if _, ok := want[name]; !ok {
			return fmt.Errorf("%s.%s is an unknown field", path, name)
		}
	}
	return nil
}

// omittable reports whether json tag options let encoding/json drop the field.
func omittable(opts string) bool {
	o := "," + opts + ","
	return strings.Contains(o, ",omitempty,") || strings.Contains(o, ",omitzero,")
}

// checkSchema walks a state type the way checkFields walks a value, so a type with a field the
// reader cannot require is rejected before anything is marshaled.
func checkSchema(t reflect.Type) error {
	for t.Kind() == reflect.Pointer || t.Kind() == reflect.Slice {
		t = t.Elem()
	}
	if t.Kind() != reflect.Struct {
		return nil
	}
	fields, err := jsonFields(t)
	if err != nil {
		return err
	}
	for _, name := range slices.Sorted(maps.Keys(fields)) {
		if err := checkSchema(fields[name]); err != nil {
			return err
		}
	}
	return nil
}

// jsonFields maps each JSON field name of struct t, embedded structs flattened, to its type.
// Every field is required on read, so a field that could be omitted on write is an error:
// oe would write states it cannot read back.
func jsonFields(t reflect.Type) (map[string]reflect.Type, error) {
	out := map[string]reflect.Type{}
	for f := range t.Fields() {
		tag := f.Tag.Get("json")
		if tag == "-" {
			continue
		}
		name, opts, _ := strings.Cut(tag, ",")
		if omittable(opts) {
			return nil, fmt.Errorf("state field %s.%s must not be omitempty or omitzero", t.Name(), f.Name)
		}
		if f.Anonymous && name == "" && f.Type.Kind() == reflect.Struct {
			embedded, err := jsonFields(f.Type)
			if err != nil {
				return nil, err
			}
			maps.Copy(out, embedded)
			continue
		}
		if !f.IsExported() {
			continue
		}
		if name == "" {
			name = f.Name
		}
		out[name] = f.Type
	}
	return out, nil
}
