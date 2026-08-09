//go:build !wasip1

// The library's own tests run on a development machine, against the
// recording host in host_native.go. Nothing here is built into a plugin.

package lookout

import (
	"encoding/json"
	"math"
	"testing"
)

var annapolis = Point{Lat: 38.9763, Lon: -76.4767}

func near(t *testing.T, want, got, tol float64, what string) {
	t.Helper()
	if math.Abs(want-got) > tol {
		t.Fatalf("%s: want %v, got %v", what, want, got)
	}
}

func TestOneMileEastLandsWhereTheFlatEarthCheckSays(t *testing.T) {
	p := annapolis.Destination(90, NauticalMile)

	// Flat approximation for the same leg: dlon = d / (R cos lat).
	dlon := (NauticalMile / (earthRadiusM * math.Cos(annapolis.Lat*math.Pi/180))) * 180 / math.Pi
	near(t, annapolis.Lon+dlon, p.Lon, 1e-6, "lon")
	near(t, -76.4552757, p.Lon, 1e-7, "lon against the Zig fixture")

	// Due east is the vertex of its great circle, so the latitude falls off by
	// a fraction of a metre rather than holding exactly.
	near(t, annapolis.Lat, p.Lat, 1e-5, "lat")
	if p.Lat >= annapolis.Lat {
		t.Fatal("due east should lose a little latitude")
	}
	near(t, NauticalMile, annapolis.DistanceTo(p), 0.01, "distance")
	near(t, 90, annapolis.BearingTo(p), 1e-6, "bearing")
}

func TestCardinalLegsAreOneMileLongAndPointWhereTheyWereSent(t *testing.T) {
	for _, brg := range []float64{0, 45, 90, 135, 180, 225, 270, 315, 359} {
		p := annapolis.Destination(brg, NauticalMile)
		near(t, NauticalMile, annapolis.DistanceTo(p), 0.01, "distance")
		near(t, brg, annapolis.BearingTo(p), 1e-6, "bearing")
	}
	// Due north: the latitude change is the arc over the radius, exactly.
	north := annapolis.Destination(0, NauticalMile)
	near(t, annapolis.Lat+(NauticalMile/earthRadiusM)*180/math.Pi, north.Lat, 1e-9, "lat")
	near(t, annapolis.Lon, north.Lon, 1e-12, "lon")
}

func TestALegAcrossTheAntimeridianKeepsItsLongitudeOnTheChart(t *testing.T) {
	fiji := Point{Lat: -17, Lon: 179.95}
	p := fiji.Destination(90, NM(10))
	if p.Lon >= 0 || p.Lon <= -180 {
		t.Fatalf("longitude did not fold: %v", p.Lon)
	}
	near(t, NM(10), fiji.DistanceTo(p), 0.1, "distance")
}

func TestFoldingAndValidity(t *testing.T) {
	near(t, 10, NormalizeDeg(370), 1e-9, "370")
	near(t, 350, NormalizeDeg(-10), 1e-9, "-10")
	near(t, 0, NormalizeDeg(math.NaN()), 0, "NaN")
	near(t, -179, WrapLon(181), 1e-12, "181")
	near(t, 179, WrapLon(-181), 1e-12, "-181")

	if !(Point{Lat: 38.9, Lon: -76.4}).Valid() {
		t.Fatal("Annapolis is on the earth")
	}
	if (Point{Lat: 91}).Valid() || (Point{Lon: math.NaN()}).Valid() {
		t.Fatal("a position off the earth must be refused")
	}
}

// The retained scene: what a plugin describes, and what actually goes out.

type drawn struct {
	Set []map[string]any `json:"set"`
	Del []string         `json:"del"`
}

func batch(t *testing.T, text string) drawn {
	t.Helper()
	var d drawn
	if err := json.Unmarshal([]byte(text), &d); err != nil {
		t.Fatalf("the batch is not JSON: %v\n%s", err, text)
	}
	return d
}

func TestAnUnchangedObjectIsNotSentAgain(t *testing.T) {
	resetHost()
	line := []Point{annapolis, annapolis.Destination(90, NM(1))}

	Scene(func(c *Chart) { c.Line("a", line, Line{Color: ColorWarning, Dash: true}) })
	if len(testHost.Overlays) != 1 {
		t.Fatalf("the first frame must be sent: %d batches", len(testHost.Overlays))
	}
	first := batch(t, lastOverlay())
	if len(first.Set) != 1 || first.Set[0]["id"] != "a" {
		t.Fatalf("want one object 'a', got %s", lastOverlay())
	}

	// The same picture again: nothing changed, so nothing goes out.
	Scene(func(c *Chart) { c.Line("a", line, Line{Color: ColorWarning, Dash: true}) })
	if len(testHost.Overlays) != 1 {
		t.Fatalf("an unchanged scene must send nothing: %v", testHost.Overlays[1:])
	}

	// A changed colour is one set and no delete.
	Scene(func(c *Chart) { c.Line("a", line, Line{Color: ColorTrack, Dash: true}) })
	if len(testHost.Overlays) != 2 {
		t.Fatal("a changed object must be sent")
	}
	second := batch(t, lastOverlay())
	if len(second.Set) != 1 || len(second.Del) != 0 {
		t.Fatalf("want one set and no delete, got %s", lastOverlay())
	}
}

func TestAnObjectNotDrawnThisCallIsDeleted(t *testing.T) {
	resetHost()
	line := []Point{annapolis, annapolis.Destination(90, NM(1))}
	Scene(func(c *Chart) {
		c.Line("a", line, Line{Color: ColorWarning})
		c.Line("b", line, Line{Color: ColorTrack})
	})
	Scene(func(c *Chart) { c.Line("a", line, Line{Color: ColorWarning}) })

	last := batch(t, lastOverlay())
	if len(last.Set) != 0 {
		t.Fatalf("nothing changed about 'a', so nothing is set: %s", lastOverlay())
	}
	if len(last.Del) != 1 || last.Del[0] != "b" {
		t.Fatalf("want 'b' deleted, got %s", lastOverlay())
	}

	// And once it is gone it is not deleted twice.
	n := len(testHost.Overlays)
	Scene(func(c *Chart) { c.Line("a", line, Line{Color: ColorWarning}) })
	if len(testHost.Overlays) != n {
		t.Fatalf("a second empty frame must send nothing: %s", lastOverlay())
	}
}

func TestTheWireFormatPutsLongitudeFirst(t *testing.T) {
	resetHost()
	Scene(func(c *Chart) {
		c.Symbol("s", SymTarget, annapolis, Symbol{Color: ColorTarget, RotDeg: 90})
	})
	got := batch(t, lastOverlay())
	at, ok := got.Set[0]["at"].([]any)
	if !ok || len(at) != 2 {
		t.Fatalf("no position in %s", lastOverlay())
	}
	near(t, annapolis.Lon, at[0].(float64), 1e-12, "lon first")
	near(t, annapolis.Lat, at[1].(float64), 1e-12, "lat second")
	// A zero Scale draws at 1 rather than at nothing.
	near(t, 1, got.Set[0]["scale"].(float64), 0, "scale")
}

func TestALineOfOnePointIsNotDrawn(t *testing.T) {
	resetHost()
	Scene(func(c *Chart) { c.Line("a", []Point{annapolis}, Line{Color: ColorWarning}) })
	if len(testHost.Overlays) != 0 {
		t.Fatalf("a line needs two points: %s", lastOverlay())
	}
}
