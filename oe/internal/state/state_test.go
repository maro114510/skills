package state_test

import (
	"regexp"
	"strings"
	"testing"

	"github.com/maro114510/skills/oe/internal/exitcode"
	"github.com/maro114510/skills/oe/internal/protocol"
	"github.com/maro114510/skills/oe/internal/state"
)

// releasedField matches the released member and the comma before it, so removing it leaves valid
// JSON and the codec can only object to the missing field.
var releasedField = regexp.MustCompile(`,\s*"released":\s*(true|false)`)

func ledgerOf(freeze *state.Freeze) *state.Ledger {
	return &state.Ledger{
		Envelope: protocol.Envelope{ProtocolVersion: protocol.Version, Entity: state.EntityLedger, Key: state.KeyLedger, Revision: 1, UpdatedBy: "token"},
		N:        1,
		Counters: state.Counters{
			WorkerDispatches: state.Counter{Used: 0, Bound: 0},
			ReviewerPasses:   state.Counter{Used: 0, Bound: 0},
			FixCycles:        state.Counter{Used: 0, Bound: 0},
		},
		Freeze: freeze, FreezeSeq: 1, ReleaseWatermark: 0,
	}
}

// TestLedgerFreezeRoundTripsThroughStrictStateCodec: both an active and a released freeze are
// written and read back, so a release can keep the record health reads as HANDLED.
func TestLedgerFreezeRoundTripsThroughStrictStateCodec(t *testing.T) {
	t.Parallel()

	for _, released := range []bool{false, true} {
		in := ledgerOf(&state.Freeze{Seq: 1, Reason: "failed checks", MergeSHA: "merge", Health: "FAIL", Released: released})
		body, err := protocol.EncodeState(in)
		if err != nil {
			t.Fatalf("released=%v: EncodeState() error = %v", released, err)
		}
		var out state.Ledger
		if _, err := protocol.DecodeState(body, &out); err != nil {
			t.Fatalf("released=%v: DecodeState() error = %v", released, err)
		}
		if out.Freeze == nil || *out.Freeze != *in.Freeze {
			t.Errorf("released=%v: decoded freeze = %+v, want %+v", released, out.Freeze, in.Freeze)
		}
	}
}

// TestAFreezeWithoutReleasedIsNotAFreeze: released is required, never defaulted, so a freeze
// whose state is unknown is refused (exit 6) and never read as active or as released.
func TestAFreezeWithoutReleasedIsNotAFreeze(t *testing.T) {
	t.Parallel()

	body, err := protocol.EncodeState(ledgerOf(&state.Freeze{Seq: 1, Reason: "r", MergeSHA: "m", Health: "FAIL", Released: false}))
	if err != nil {
		t.Fatalf("EncodeState() error = %v", err)
	}
	stripped := releasedField.ReplaceAllString(body, "")
	if stripped == body {
		t.Fatalf("the encoded body has no released field to remove:\n%s", body)
	}
	var out state.Ledger
	_, err = protocol.DecodeState(stripped, &out)
	if exitcode.CodeOf(err) != exitcode.Protocol || err == nil || !strings.Contains(err.Error(), "released is missing") {
		t.Errorf("DecodeState() = %v (exit %d), want a protocol error naming the missing released field", err, exitcode.CodeOf(err))
	}
}
