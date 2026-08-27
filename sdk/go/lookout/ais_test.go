//go:build !wasip1

package lookout

import "testing"

func u8p(v uint8) *uint8       { return &v }
func u16p(v uint16) *uint16    { return &v }
func u32p(v uint32) *uint32    { return &v }
func f64p(v float64) *float64  { return &v }
func boolp(v bool) *bool       { return &v }

// THE OTHER END OF THE SAME WIRE. plugins/common/lk2.zig asserts its writer
// produces this byte for byte, and src/plugin/broker/natives.zig reads it back
// on the host's side. A Go plugin that spelled one key differently would drop
// that field in silence, so the three are pinned to one literal.
func TestATargetsIdentityAndVoyageGoOutAsTheHostReadsThem(t *testing.T) {
	u := &Upsert{b: append(make([]byte, 0, 256), `{"targets":[`...), ts: 1000}
	u.Target(Target{
		MMSI:        899000404,
		Lat:         f64p(38.98),
		Lon:         f64p(-76.47),
		SOG:         f64p(2.5),
		COG:         f64p(210),
		Heading:     f64p(211),
		Name:        "TANGERINE OTTER",
		NavStatus:   u8p(1),
		ShipType:    u8p(71),
		ClassB:      boolp(false),
		CallSign:    "3FOF8",
		Destination: "NEW YORK",
		IMO:         u32p(9134270),
		DraughtM:    f64p(12.5),
		LengthM:     u16p(294),
		BeamM:       u16p(32),
	})
	got := string(append(u.b, ']', '}'))
	want := `{"targets":[{"mmsi":899000404,"lat":38.98,"lon":-76.47,"sog":2.5,` +
		`"cog":210,"heading":211,"name":"TANGERINE OTTER","nav_status":1,` +
		`"ship_type":71,"class_b":false,"callsign":"3FOF8",` +
		`"destination":"NEW YORK","imo":9134270,"draught":12.5,` +
		`"length":294,"beam":32,"ts":1000}]}`
	if got != want {
		t.Fatalf("wire mismatch:\n got %s\nwant %s", got, want)
	}
}

// A field the vessel never reported is absent, not a zero: "never heard" and
// "heard as zero" are different things at sea.
func TestAFieldNeverReportedIsLeftOut(t *testing.T) {
	u := &Upsert{b: append(make([]byte, 0, 256), `{"targets":[`...), ts: 500}
	u.Target(Target{MMSI: 7, Name: "SILENT"})
	got := string(append(u.b, ']', '}'))
	want := `{"targets":[{"mmsi":7,"name":"SILENT","ts":500}]}`
	if got != want {
		t.Fatalf("wire mismatch:\n got %s\nwant %s", got, want)
	}
}

// And what the host sends back parses into the same fields it was given.
func TestASnapshotParsesBackIntoIdentity(t *testing.T) {
	e := Event{Payload: []byte(`{"targets":[{"mmsi":899000404,"lat":38.98,"lon":-76.47,` +
		`"nav_status":1,"ship_type":71,"class_b":false,"callsign":"3FOF8",` +
		`"destination":"NEW YORK","imo":9134270,"draught":12.5,"length":294,` +
		`"beam":32,"ts":1000,"age_ms":540}]}`)}
	got := e.Targets()
	if len(got) != 1 {
		t.Fatalf("want 1 target, got %d", len(got))
	}
	g := got[0]
	if g.NavStatus == nil || *g.NavStatus != 1 {
		t.Fatalf("nav_status: %v", g.NavStatus)
	}
	if g.ShipType == nil || *g.ShipType != 71 {
		t.Fatalf("ship_type: %v", g.ShipType)
	}
	if g.ClassB == nil || *g.ClassB != false {
		t.Fatalf("class_b: %v", g.ClassB)
	}
	if g.CallSign != "3FOF8" || g.Destination != "NEW YORK" {
		t.Fatalf("callsign %q destination %q", g.CallSign, g.Destination)
	}
	if g.IMO == nil || *g.IMO != 9134270 {
		t.Fatalf("imo: %v", g.IMO)
	}
	if g.DraughtM == nil || *g.DraughtM != 12.5 {
		t.Fatalf("draught: %v", g.DraughtM)
	}
	if g.LengthM == nil || *g.LengthM != 294 || g.BeamM == nil || *g.BeamM != 32 {
		t.Fatalf("length %v beam %v", g.LengthM, g.BeamM)
	}
}
