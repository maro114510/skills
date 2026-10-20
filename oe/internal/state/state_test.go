package state_test

import (
	"testing"

	"github.com/maro114510/skills/oe/internal/protocol"
	"github.com/maro114510/skills/oe/internal/state"
)

func TestLedgerFreezeRoundTripsThroughStrictStateCodec(t *testing.T) {
	t.Parallel()

	ledger := state.Ledger{
		Envelope: protocol.Envelope{ProtocolVersion: protocol.Version, Entity: state.EntityLedger, Key: state.KeyLedger, Revision: 1, UpdatedBy: "token"},
		N:        1, Counters: state.Counters{
			WorkerDispatches: state.Counter{Used: 0, Bound: 0},
			ReviewerPasses:   state.Counter{Used: 0, Bound: 0},
			FixCycles:        state.Counter{Used: 0, Bound: 0},
		},
		Freeze:    &state.Freeze{Seq: 1, Reason: "failed checks", MergeSHA: "merge", Health: "FAIL"},
		FreezeSeq: 1, ReleaseWatermark: 0,
	}
	body, err := protocol.EncodeState(&ledger)
	if err != nil {
		t.Fatalf("EncodeState() error = %v", err)
	}
	var decoded state.Ledger
	if _, err := protocol.DecodeState(body, &decoded); err != nil {
		t.Fatalf("DecodeState() error = %v", err)
	}
	if decoded.Freeze == nil || decoded.Freeze.Seq != ledger.Freeze.Seq || decoded.Freeze.Health != ledger.Freeze.Health {
		t.Errorf("decoded freeze = %+v, want %+v", decoded.Freeze, ledger.Freeze)
	}
}
