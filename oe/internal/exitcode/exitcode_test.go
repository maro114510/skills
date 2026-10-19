package exitcode_test

import (
	"errors"
	"fmt"
	"testing"

	"github.com/maro114510/skills/oe/internal/exitcode"
)

// TestContractExitCodes pins the numeric values of contract §9, so a caller routing on
// `$?` never sees a renumbered code. Exit 3 means stale and exit 4 means stop (MC-01).
func TestContractExitCodes(t *testing.T) {
	t.Parallel()

	want := map[exitcode.Code]int{
		exitcode.OK:           0,
		exitcode.Unreadable:   1,
		exitcode.Usage:        2,
		exitcode.Stale:        3,
		exitcode.Stop:         4,
		exitcode.Wait:         5,
		exitcode.Protocol:     6,
		exitcode.Coordination: 7,
		exitcode.Refused:      8,
	}
	for code, n := range want {
		if int(code) != n {
			t.Errorf("code %s = %d, want %d", code.Word(), int(code), n)
		}
	}
}

func TestCodeOf(t *testing.T) {
	t.Parallel()

	tests := map[string]struct {
		err  error
		want exitcode.Code
	}{
		"nil is OK":                                {err: nil, want: exitcode.OK},
		"typed error keeps code":                   {err: exitcode.New(exitcode.Protocol, "dup"), want: exitcode.Protocol},
		"wrapped typed error":                      {err: fmt.Errorf("outer: %w", exitcode.New(exitcode.Refused, "no")), want: exitcode.Refused},
		"untyped error fails closed as unreadable": {err: errors.New("boom"), want: exitcode.Unreadable},
	}
	for name, tt := range tests {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			if got := exitcode.CodeOf(tt.err); got != tt.want {
				t.Errorf("CodeOf() = %d, want %d", got, tt.want)
			}
		})
	}
}

func TestVerdictIsOneLine(t *testing.T) {
	t.Parallel()

	err := exitcode.Wrap(exitcode.Unreadable, errors.New("line one\nline two"), "gh api user failed")
	got := exitcode.Verdict(err)
	want := "unreadable: gh api user failed: line one line two"
	if got != want {
		t.Errorf("Verdict() = %q, want %q", got, want)
	}
}

func TestErrorUnwraps(t *testing.T) {
	t.Parallel()

	inner := errors.New("inner")
	err := exitcode.Wrap(exitcode.Stop, inner, "outer")
	if !errors.Is(err, inner) {
		t.Error("errors.Is(Wrap(inner), inner) = false, want true")
	}
}
