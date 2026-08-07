//go:build !wasip1

// The library's own tests run on a development machine, against the
// recording host in host_native.go. Nothing here is built into a plugin.

package lookout

import (
	"strings"
	"testing"
)

// The whole tier-1 lifecycle, driven through the two exports the host calls.

type windlineTest struct {
	boat  *PositionInput
	twd   *NumberInput
	draws int
}

func (p *windlineTest) Draw(c *Chart) {
	p.draws++
	from := p.boat.Get()
	to := from.Destination(p.twd.Get()+180, NM(1))
	c.Line("windline", []Point{from, to}, Line{Color: ColorWarning, Dash: true})
}

func startWindline(t *testing.T) *windlineTest {
	t.Helper()
	resetHost()
	p := &windlineTest{
		boat: Position("navigation.position"),
		twd:  Number("environment.wind.directionTrue", InputOpts{Label: "wind"}),
	}
	Register(p)
	if rc := dispatchStart([]byte(`{"abi":1,"config":{}}`)); rc != 0 {
		t.Fatalf("lk_start answered %d: %v", rc, testHost.Logs)
	}
	return p
}

const positionAndWind = `{"values":[
	{"path":"navigation.position","value":{"lat":38.9763,"lon":-76.4767},"ts":1,"age_ms":0},
	{"path":"environment.wind.directionTrue","value":270,"ts":1,"age_ms":0}]}`

func tick(t *testing.T) {
	t.Helper()
	if rc := dispatchEvent(Timer, reg.drawTimer, nil); rc != 0 {
		t.Fatalf("the draw tick answered %d", rc)
	}
}

func TestStartSubscribesAndSaysWhatItIsWaitingFor(t *testing.T) {
	startWindline(t)

	if len(testHost.Subscribe) != 1 {
		t.Fatalf("want one subscription, got %v", testHost.Subscribe)
	}
	want := `["navigation.position","environment.wind.directionTrue"]`
	if testHost.Subscribe[0] != want {
		t.Fatalf("subscribed to %s, want %s", testHost.Subscribe[0], want)
	}
	if got := lastStatus(); got != `{"state":"starting","detail":"waiting for position, wind"}` {
		t.Fatalf("the start line is %s", got)
	}
	if reg.drawEvery != 1000 {
		t.Fatalf("the draw rate is %d ms", reg.drawEvery)
	}
	if !testHost.Periodic[reg.drawTimer] {
		t.Fatal("the draw timer must repeat")
	}
}

func TestTheStoreFeedsTheInputsAndTheTimerDraws(t *testing.T) {
	p := startWindline(t)

	// Nothing draws on a store change: the timer does that.
	dispatchEvent(StoreChanged, 0, []byte(positionAndWind))
	if p.draws != 0 || len(testHost.Overlays) != 0 {
		t.Fatalf("the store change drew: %d draws, %d batches", p.draws, len(testHost.Overlays))
	}

	tick(t)
	if p.draws != 1 {
		t.Fatalf("want one draw, got %d", p.draws)
	}
	got := batch(t, lastOverlay())
	if len(got.Set) != 1 || got.Set[0]["id"] != "windline" {
		t.Fatalf("want the windline object, got %s", lastOverlay())
	}
	if got.Set[0]["dash"] != true || got.Set[0]["color"] != "warning" {
		t.Fatalf("the style did not survive: %s", lastOverlay())
	}
	if lastStatus() != `{"state":"running","detail":""}` {
		t.Fatalf("the status is %s", lastStatus())
	}

	// A second tick with the same data changes nothing, so nothing is sent and
	// the status is not posted again.
	overlays, statuses := len(testHost.Overlays), len(testHost.Statuses)
	tick(t)
	if len(testHost.Overlays) != overlays || len(testHost.Statuses) != statuses {
		t.Fatalf("an unchanged frame sent %d batches and %d statuses",
			len(testHost.Overlays)-overlays, len(testHost.Statuses)-statuses)
	}
}

func TestAStaleReadingClearsTheSceneAndNamesEveryMissingInstrument(t *testing.T) {
	startWindline(t)
	dispatchEvent(StoreChanged, 0, []byte(positionAndWind))
	tick(t)

	// Five seconds and a millisecond later, both readings are outside the
	// window.
	testHost.Mono += 5001
	tick(t)

	got := batch(t, lastOverlay())
	if len(got.Set) != 0 || len(got.Del) != 1 || got.Del[0] != "windline" {
		t.Fatalf("the scene was not cleared: %s", lastOverlay())
	}
	if lastStatus() != `{"state":"degraded","detail":"no position, no wind"}` {
		t.Fatalf("the degraded line is %s", lastStatus())
	}
}

func TestAClearedPathIsRemovalAndNotZero(t *testing.T) {
	p := startWindline(t)
	dispatchEvent(StoreChanged, 0, []byte(positionAndWind))
	tick(t)
	dispatchEvent(StoreChanged, 0, []byte(`{"values":[{"path":"environment.wind.directionTrue","value":null,"ts":2,"age_ms":0}]}`))
	tick(t)

	if p.draws != 1 {
		t.Fatalf("draw ran %d times; the second tick had no wind", p.draws)
	}
	if !strings.Contains(lastStatus(), "no wind") || strings.Contains(lastStatus(), "no position") {
		t.Fatalf("only the wind is missing: %s", lastStatus())
	}
}

func TestAnOptionalInputNeverHoldsTheDrawBack(t *testing.T) {
	resetHost()
	depth := Number("environment.depth.belowKeel", InputOpts{Optional: true})
	var seen bool
	p := &funcPlugin{draw: func(c *Chart) {
		_, seen = depth.Fresh()
		c.Status("drawn")
	}}
	Register(p)
	dispatchStart([]byte(`{"abi":1,"config":{}}`))
	tick(t)

	if seen {
		t.Fatal("nothing has arrived, so Fresh must answer false")
	}
	if lastStatus() != `{"state":"running","detail":"drawn"}` {
		t.Fatalf("an optional input must not gate the draw: %s", lastStatus())
	}
}

func TestSettingsChangeRedrawsAtOnce(t *testing.T) {
	resetHost()
	p := &lengthPlugin{}
	Register(p)
	dispatchStart([]byte(`{"abi":1,"config":{"length_nm":2.5}}`))
	if p.Settings.Length != 2.5 {
		t.Fatalf("the start config did not reach the struct: %v", p.Settings.Length)
	}
	tick(t)
	if lastStatus() != `{"state":"running","detail":"2.5 nm"}` {
		t.Fatalf("the status is %s", lastStatus())
	}

	draws := p.draws
	dispatchEvent(ConfigChanged, 0, []byte(`{"length_nm":4}`))
	if p.draws != draws+1 {
		t.Fatal("a changed setting must show now, not at the next tick")
	}
	if lastStatus() != `{"state":"running","detail":"4 nm"}` {
		t.Fatalf("the status is %s", lastStatus())
	}
}

func TestShutdownStopsTheTimerAndSaysSo(t *testing.T) {
	startWindline(t)
	dispatchEvent(Shutdown, 0, nil)

	if len(testHost.Cancelled) != 1 {
		t.Fatalf("the draw timer must be cancelled: %v", testHost.Cancelled)
	}
	if lastStatus() != `{"state":"stopped","detail":"shut down"}` {
		t.Fatalf("the last line is %s", lastStatus())
	}
}

func TestAnUnknownEventKindIsAnsweredWithoutReachingThePlugin(t *testing.T) {
	resetHost()
	seen := 0
	Register(&funcPlugin{event: func(e Event) error { seen++; return nil }})
	dispatchStart([]byte(`{"abi":1,"config":{}}`))
	if rc := dispatchEvent(Kind(77), 0, nil); rc != 0 {
		t.Fatalf("an unknown kind must answer 0, got %d", rc)
	}
	if seen != 0 {
		t.Fatal("an unknown kind must not reach the plugin")
	}
}

func TestATierThreePluginSeesTheEventsTheLibraryDoesNotConsume(t *testing.T) {
	resetHost()
	var kinds []Kind
	Register(&funcPlugin{event: func(e Event) error { kinds = append(kinds, e.Kind); return nil }})
	dispatchStart([]byte(`{"abi":1,"config":{}}`))

	// No inputs are declared, so a store change is the plugin's to read.
	dispatchEvent(StoreChanged, 0, []byte(positionAndWind))
	dispatchEvent(TCPData, 7, []byte("$GPRMC"))
	if len(kinds) != 2 || kinds[0] != StoreChanged || kinds[1] != TCPData {
		t.Fatalf("the plugin saw %v", kinds)
	}
}

func TestAPluginWithNoEntryPointIsRefusedRatherThanRunSilently(t *testing.T) {
	resetHost()
	Register(&struct{}{})
	if rc := dispatchStart([]byte(`{"abi":1,"config":{}}`)); rc == 0 {
		t.Fatal("a plugin with no method must not start")
	}
	if len(logsWith("none of Draw")) == 0 {
		t.Fatalf("the log must say why: %v", testHost.Logs)
	}
}

func TestADrawMethodOfTheWrongShapeIsReported(t *testing.T) {
	resetHost()
	Register(&wrongDraw{})
	dispatchStart([]byte(`{"abi":1,"config":{}}`))
	if len(logsWith("Draw has the wrong signature")) == 0 {
		t.Fatalf("the log must name the typo: %v", testHost.Logs)
	}
}

func TestAHostSpeakingAnotherABIIsRefused(t *testing.T) {
	resetHost()
	Register(&funcPlugin{draw: func(c *Chart) {}})
	if rc := dispatchStart([]byte(`{"abi":2,"config":{}}`)); rc == 0 {
		t.Fatal("an ABI mismatch must refuse the start")
	}
}

// ---- the plugins these tests register -------------------------------------

// funcPlugin is a plugin whose methods are fields, so a test declares one
// inline.
type funcPlugin struct {
	draw  func(c *Chart)
	event func(e Event) error
}

func (p *funcPlugin) Draw(c *Chart) {
	if p.draw != nil {
		p.draw(c)
	}
}

func (p *funcPlugin) OnEvent(e Event) error {
	if p.event != nil {
		return p.event(e)
	}
	return nil
}

// lengthPlugin is settings and a draw method, which is what a real tier-1
// plugin with a setting is.
type lengthPlugin struct {
	Settings struct {
		Length float64 `lk:"length_nm" label:"Length" unit:"nm" min:"0.1" max:"10" default:"1"`
	} `label:"Downwind line" tab:"display"`
	draws int
}

func (p *lengthPlugin) Draw(c *Chart) {
	p.draws++
	c.Status("%g nm", p.Settings.Length)
}

type wrongDraw struct{}

// Draw with the wrong argument: the interface assertion misses it, and without
// the check at registration the plugin would start and do nothing.
func (p *wrongDraw) Draw(c Chart) {}

func (p *wrongDraw) OnStart(s Start) error { return nil }

func TestASettingsFieldTheLibraryCannotReadRefusesTheStart(t *testing.T) {
	resetHost()
	Register(&badSettings{})
	if rc := dispatchStart([]byte(`{"abi":1,"config":{}}`)); rc == 0 {
		t.Fatal("a misdeclared setting must not start on its zero value")
	}
	if len(logsWith("needs a min tag")) == 0 {
		t.Fatalf("the log must name the tag: %v", testHost.Logs)
	}
}

// badSettings declares a number with no range, which the shell cannot render
// and the library cannot clamp against.
type badSettings struct {
	Settings struct {
		Length float64 `lk:"length_nm" label:"Length"`
	} `label:"Downwind line" tab:"display"`
}

func (p *badSettings) Draw(c *Chart) {}
