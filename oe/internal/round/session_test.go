package round_test

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/maro114510/skills/oe/internal/exitcode"
	"github.com/maro114510/skills/oe/internal/round"
)

func TestLoadOfAMissingFileIsASessionThatHasSeenNothing(t *testing.T) {
	t.Parallel()

	s, err := round.Load(filepath.Join(t.TempDir(), "sessions", "none.json"))

	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if s.Known || s.Merges != 0 || s.Rounds != 0 || s.Polls != 0 || len(s.Deferred) != 0 {
		t.Errorf("session = %+v, want a clean one", s)
	}
}

func TestLoadRefusesADamagedFileWithExit1AndNeverReadsItAsACleanStart(t *testing.T) {
	t.Parallel()

	healthy := filepath.Join(t.TempDir(), "healthy.json")
	if err := os.WriteFile(healthy, []byte(`{"version":1,"known":true,"mark":"1:a","merges":1,"rounds":1,"polls":2,"round":null,"deferred":[],"no_checks":{}}`), 0o600); err != nil {
		t.Fatal(err)
	}
	if s, err := round.Load(healthy); err != nil || s.Mark != "1:a" || s.Polls != 2 {
		t.Fatalf("a well-formed file: Load = %+v, %v; want it read as written", s, err)
	}

	for name, body := range map[string]string{
		"not json":      "{polls: 3",
		"unknown field": `{"version":1,"known":true,"mark":"","merges":0,"rounds":0,"polls":0,"round":null,"deferred":[],"no_checks":{},"extra":1}`,
		"other version": `{"version":2,"known":true,"mark":"","merges":0,"rounds":0,"polls":0,"round":null,"deferred":[],"no_checks":{}}`,
		"empty file":    "",
	} {
		path := filepath.Join(t.TempDir(), "s.json")
		if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}

		s, err := round.Load(path)

		if err == nil || exitcode.CodeOf(err) != exitcode.Unreadable || s != nil {
			t.Errorf("%s: Load = %+v, %v; want exit 1 and no session", name, s, err)
		}
	}
}

func TestSaveThenLoadKeepsEverythingTheInvocationRecorded(t *testing.T) {
	t.Parallel()

	path := filepath.Join(t.TempDir(), "sessions", "s.json")
	s := round.New()
	s.Known, s.Mark, s.Merges, s.Rounds, s.Polls = true, "12:merge01", 2, 3, 7
	s.Round = &round.Baseline{Mark: "9:old", Verifying: true}
	s.Defer(5, round.ReasonBlocked)
	s.NoChecks = map[string]round.NoChecks{"12": {Head: "abc", Polls: 4}}

	if err := s.Save(path); err != nil {
		t.Fatalf("Save: %v", err)
	}
	got, err := round.Load(path)

	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if !reflect.DeepEqual(got, s) {
		t.Errorf("loaded %+v, want %+v", got, s)
	}
	if info, err := os.Stat(path); err != nil || info.Mode().Perm() != 0o600 {
		t.Errorf("session file mode = %v, %v; want 0600, since it names a lease token's digest", info, err)
	}
	if leftovers, _ := filepath.Glob(path + ".*"); len(leftovers) != 0 {
		t.Errorf("temporary files left behind: %v", leftovers)
	}
}

func TestEachLeaseTokenAndEpicHasItsOwnFileThatNeverHoldsTheToken(t *testing.T) {
	t.Parallel()

	a := round.Path("/state", "o/r", 277, "token-a")
	b := round.Path("/state", "o/r", 277, "token-b")
	c := round.Path("/state", "o/r", 278, "token-a")

	if a == b || a == c {
		t.Errorf("paths collide: %s, %s, %s", a, b, c)
	}
	if !strings.HasPrefix(a, "/state/sessions/o-r-277-") || !strings.HasSuffix(a, ".json") {
		t.Errorf("path = %s, want /state/sessions/o-r-277-<digest>.json", a)
	}
	if strings.Contains(a, "token-a") {
		t.Errorf("path %s names the token itself, not its digest", a)
	}
}

func TestDeferringAnIssueTwiceKeepsOneEntryWithTheFirstReason(t *testing.T) {
	t.Parallel()

	s := round.New()
	s.Defer(7, round.ReasonBlocked)
	s.Defer(3, round.ReasonStale)
	s.Defer(7, round.ReasonTurn)

	want := []round.Deferral{{Issue: 3, Reason: round.ReasonStale}, {Issue: 7, Reason: round.ReasonBlocked}}
	if !reflect.DeepEqual(s.Deferred, want) {
		t.Errorf("deferred = %+v, want %+v, sorted by Issue", s.Deferred, want)
	}
	if got := s.DeferredSet(); !reflect.DeepEqual(got, map[int]round.Reason{3: round.ReasonStale, 7: round.ReasonBlocked}) {
		t.Errorf("set = %v", got)
	}
}

func TestOnlyAReasonOfTheClosedSetIsAccepted(t *testing.T) {
	t.Parallel()

	for _, ok := range []string{"blocked", "stale", "gave-up-turn"} {
		if r, found := round.ParseReason(ok); !found || string(r) != ok {
			t.Errorf("ParseReason(%q) = %q, %v", ok, r, found)
		}
	}
	for _, bad := range []string{"", "Blocked", "timeout", "blocked "} {
		if _, found := round.ParseReason(bad); found {
			t.Errorf("ParseReason(%q) accepted", bad)
		}
	}
}

// completeFile is a session file with every field, and the base the incomplete and invalid cases are cut from.
const completeFile = `{"version":1,"known":true,"mark":"1:a","merges":1,"rounds":1,"polls":2,"round":{"mark":"1:a","verifying":false},"deferred":[{"issue":5,"reason":"blocked"}],"no_checks":{"12":{"head":"h1","polls":3}}}`

// writeSession writes a session file with the body and returns its path.
func writeSession(t *testing.T, body string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "s.json")
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

// withoutField is completeFile without one field.
func TestLoadReadsACompleteVersionOneFileAsWritten(t *testing.T) {
	t.Parallel()

	s, err := round.Load(writeSession(t, completeFile))

	if err != nil || s.Polls != 2 || len(s.Deferred) != 1 || s.NoChecks["12"].Polls != 3 {
		t.Errorf("Load = %+v, %v; want the file read as written", s, err)
	}
}
