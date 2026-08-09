//go:build !wasip1

package lookout

import (
	"testing"
)

// The chart grant, and what the library does when the mariner takes it away.

func grantsOff(t *testing.T) {
	t.Helper()
	if rc := dispatchEvent(GrantsChanged, 0, []byte(`{"v":1,"granted":["vessel.read"]}`)); rc != 0 {
		t.Fatalf("the grants event answered %d", rc)
	}
}

func grantsOn(t *testing.T) {
	t.Helper()
	rc := dispatchEvent(GrantsChanged, 0, []byte(`{"v":1,"granted":["vessel.read","overlay.draw"]}`))
	if rc != 0 {
		t.Fatalf("the grants event answered %d", rc)
	}
}

func TestGrantedReadsTheCapabilityList(t *testing.T) {
	e := Event{Kind: GrantsChanged, Payload: []byte(`{"v":1,"granted":["ais.read","overlay.draw"]}`)}
	if !e.Granted("overlay.draw") || !e.Granted("ais.read") {
		t.Fatal("a listed capability reads as held")
	}
	if e.Granted("alerts.raise") {
		t.Fatal("a capability nobody granted reads as held")
	}
	// The safe answer for a list that will not parse is that nothing is held.
	broken := Event{Kind: GrantsChanged, Payload: []byte(`{`)}
	if broken.Granted("overlay.draw") {
		t.Fatal("an unparsable list reads as a grant")
	}
}

func TestTheDrawTimerStandsDownWithTheChartGrant(t *testing.T) {
	p := startWindline(t)
	dispatchEvent(StoreChanged, 0, []byte(positionAndWind))
	timer := reg.drawTimer

	grantsOff(t)
	if reg.drawTimer >= 0 {
		t.Fatalf("the timer is still armed as %d", reg.drawTimer)
	}
	if len(testHost.Cancelled) != 1 || testHost.Cancelled[0] != timer {
		t.Fatalf("the draw timer was not cancelled: %v", testHost.Cancelled)
	}
	if got := lastStatus(); got != `{"state":"degraded","detail":"`+noDrawLine+`"}` {
		t.Fatalf("the plugin went quiet instead of saying why: %s", got)
	}

	// Nothing is described while the grant is off, so no overlay call is made
	// and none is refused.
	before := len(testHost.Overlays)
	dispatchEvent(StoreChanged, 0, []byte(positionAndWind))
	if len(testHost.Overlays) != before {
		t.Fatalf("a scene went out without the grant: %v", testHost.Overlays)
	}

	// The grant comes back and the whole scene is described again.
	grantsOn(t)
	if reg.drawTimer < 0 {
		t.Fatal("the timer did not come back with the grant")
	}
	if p.draws == 0 || len(testHost.Overlays) == before {
		t.Fatalf("the scene was not redrawn: %d draws", p.draws)
	}
}

func TestATableKeepsFillingWhileTheChartGrantIsOff(t *testing.T) {
	p := startTabled(t)
	openTable(t, "targets")
	grantsOff(t)

	// A table costs no capability, so the dialog follows the data whatever the
	// chart grant says.
	testHost.Mono += TableInterval.Milliseconds()
	dispatchEvent(StoreChanged, 0, []byte(oneSpeed))
	if p.updates != 2 {
		t.Fatalf("the decision stopped with the chart: %d updates", p.updates)
	}
	if len(testHost.TableBatches) != 2 {
		t.Fatalf("the rows stopped with the chart: %v", testHost.TableBatches)
	}
	if p.draws != 0 {
		t.Fatalf("the dialog drove a draw: %d draws", p.draws)
	}
}

func TestAnUnknownKindIsIgnored(t *testing.T) {
	startWindline(t)
	if rc := dispatchEvent(Kind(42), 0, nil); rc != 0 {
		t.Fatalf("an unknown kind answered %d, want 0", rc)
	}
	// Every kind the API defines reaches the dispatch.
	for _, k := range []Kind{TableOpen, TableClosed, GrantsChanged} {
		if !k.known() {
			t.Fatalf("kind %d is not known to the library", uint32(k))
		}
	}
}

func TestTheTableKeyIsReadOffTheEvent(t *testing.T) {
	e := Event{Kind: TableOpen, Payload: []byte(`{"key":"targets"}`)}
	if e.TableKey() != "targets" {
		t.Fatalf("the key reads as %q", e.TableKey())
	}
}
