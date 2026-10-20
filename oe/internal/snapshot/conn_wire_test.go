package snapshot

import (
	"testing"

	"github.com/maro114510/skills/oe/internal/exitcode"
)

func TestEachPageRejectsAnUnchangedCursor(t *testing.T) {
	t.Parallel()
	reads := 0
	err := eachPage("test connection", func(after string) (PageInfo, bool, error) {
		reads++
		if reads == 3 {
			return PageInfo{HasNextPage: false, EndCursor: nil}, true, nil
		}
		cursor := "next"
		if after != "" {
			cursor = after
		}
		return PageInfo{HasNextPage: true, EndCursor: &cursor}, false, nil
	})
	if got := exitcode.CodeOf(err); got != exitcode.Unreadable {
		t.Fatalf("exit code = %d (%v), want unreadable", got, err)
	}
	if reads != 2 {
		t.Errorf("reads = %d, want the first page and one repeated-cursor page", reads)
	}
}
