package review

import (
	"fmt"
	"strings"
)

// StaleNote says a verdict no longer holds for its pair and is verified again.
func StaleNote(head, base, reason string) string {
	return fmt.Sprintf("head %s と default branch %s の組で review 判定が無効になったため、承認を取り消して再検証します。\n\n%s\n\n"+
		"同じ組への通知はこの 1 回だけです。\n", head, base, strings.TrimSpace(reason))
}

// CapNote says why the fix-cycle cap parked an Issue.
func CapNote(limit int, findings []string) string {
	var b strings.Builder
	fmt.Fprintf(&b, "fix cycle が上限の %d 回に達したため、残った指摘は worker に渡さず保留します。\n\n", limit)
	for i, f := range findings {
		fmt.Fprintf(&b, "%d. %s\n", i+1, oneLine(f))
	}
	return b.String()
}
