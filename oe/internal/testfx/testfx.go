// Package testfx edits JSON fixtures for tests. A fixture is a clean JSON document and each
// case applies a few path edits to it, the way the earlier bats suites edited theirs with jq.
package testfx

import (
	"encoding/json"
	"strconv"
	"strings"
	"testing"
)

// Doc is a decoded JSON object.
type Doc = map[string]any

// Edit changes a fixture.
type Edit func(t *testing.T, d Doc)

// Parse decodes any JSON value, failing the test on bad input.
func Parse(t *testing.T, raw string) any {
	t.Helper()
	var v any
	if err := json.Unmarshal([]byte(raw), &v); err != nil {
		t.Fatalf("fixture %q: %v", raw, err)
	}
	return v
}

func walk(t *testing.T, root any, path []string) any {
	t.Helper()
	cur := root
	for _, seg := range path {
		switch node := cur.(type) {
		case map[string]any:
			cur = node[seg]
		case []any:
			i, err := strconv.Atoi(seg)
			if err != nil || i < 0 || i >= len(node) {
				t.Fatalf("path %v: bad index %q", path, seg)
			}
			cur = node[i]
		default:
			t.Fatalf("path %v: cannot descend into %T at %q", path, cur, seg)
		}
	}
	return cur
}

// Set replaces the value at a dotted path with raw JSON. A numeric segment indexes an array.
func Set(path, raw string) Edit {
	return func(t *testing.T, d Doc) {
		t.Helper()
		segs := strings.Split(path, ".")
		parent := walk(t, d, segs[:len(segs)-1])
		last := segs[len(segs)-1]
		switch node := parent.(type) {
		case map[string]any:
			node[last] = Parse(t, raw)
		case []any:
			i, err := strconv.Atoi(last)
			if err != nil || i < 0 || i >= len(node) {
				t.Fatalf("path %q: bad index", path)
			}
			node[i] = Parse(t, raw)
		default:
			t.Fatalf("path %q: parent is %T", path, parent)
		}
	}
}

// Del removes a field of the document root.
func Del(field string) Edit {
	return func(_ *testing.T, d Doc) { delete(d, field) }
}

// Apply decodes clean, applies the edits, and returns the result as JSON.
func Apply(t *testing.T, clean string, edits ...Edit) []byte {
	t.Helper()
	d, ok := Parse(t, clean).(Doc)
	if !ok {
		t.Fatal("clean fixture is not a JSON object")
	}
	for _, e := range edits {
		e(t, d)
	}
	raw, err := json.Marshal(d)
	if err != nil {
		t.Fatal(err)
	}
	return raw
}

// Decode applies the edits to clean and decodes the result into T.
func Decode[T any](t *testing.T, clean string, edits ...Edit) *T {
	t.Helper()
	var out T
	if err := json.Unmarshal(Apply(t, clean, edits...), &out); err != nil {
		t.Fatalf("decode fixture: %v", err)
	}
	return &out
}
