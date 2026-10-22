package scan

import (
	"reflect"
	"testing"
)

func TestParsePatchHeaders(t *testing.T) {
	t.Parallel()

	tests := map[string]struct {
		patch string
		want  []fileDiff
	}{
		"combined binary": {
			"diff --cc b.bin\nindex e7da898,0d84b84..8b07180\nBinary files differ\n",
			[]fileDiff{{path: "b.bin", deleted: false, binary: true, added: nil}},
		},
		"quoted header without +++": {
			"diff --git \"a/x\\ty\" \"b/x\\ty\"\nnew file mode 100644\nindex 0000000..e69de29\n",
			[]fileDiff{{path: "x\ty", deleted: false, binary: false, added: nil}},
		},
		"path with a space ends in a tab": {
			"diff --git a/my key.pem b/my key.pem\nnew file mode 100644\n--- /dev/null\t\n+++ b/my key.pem\t\n@@ -0,0 +1 @@\n+x\n",
			[]fileDiff{{path: "my key.pem", deleted: false, binary: false, added: []addedLine{{line: 1, text: "x"}}}},
		},
		"deleted binary": {
			"diff --git a/b.bin b/b.bin\ndeleted file mode 100644\nindex 1..0\nBinary files a/b.bin and /dev/null differ\n",
			[]fileDiff{{path: "b.bin", deleted: true, binary: false, added: nil}},
		},
	}
	for name, tc := range tests {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			got, err := parsePatch([]byte(tc.patch))
			if err != nil || !reflect.DeepEqual(got, tc.want) {
				t.Errorf("parsePatch() = %+v, %v; want %+v", got, err, tc.want)
			}
		})
	}
}

func TestParsePatchRefusesWhatItCannotFollow(t *testing.T) {
	t.Parallel()

	for name, patch := range map[string]string{
		"content before a header": "+x\n",
		"hunk without new range":  "diff --git a/f b/f\n@@ -1 @@\n",
		"unknown prefix":          "diff --git a/f b/f\n@@ -0,0 +1 @@\n*x\n",
		"parent count mismatch":   "diff --cc f\n@@@ -1 -1 +1 @@@\n@@ -1 +1 @@\n",
	} {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			if _, err := parsePatch([]byte(patch)); err == nil {
				t.Errorf("parsePatch(%q) error = nil; want an error", patch)
			}
		})
	}
}
