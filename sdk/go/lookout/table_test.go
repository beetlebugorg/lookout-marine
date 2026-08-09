//go:build !wasip1

package lookout

import (
	"strings"
	"testing"
	"time"
)

// A plugin that draws and keeps a dialog. Draw fills no rows: the rows are
// OnUpdate's work.
type tabledTest struct {
	speed   *NumberInput
	table   *Table
	updates int
	draws   int
	// hide stops the plugin describing its row, the way a target leaving range
	// stops being described.
	hide bool
}

func (p *tabledTest) OnUpdate() {
	p.updates++
	if !p.table.IsOpen() || p.hide {
		return
	}
	r := p.table.Row("899000101")
	r.Band(0)
	r.Cell("name", "ANNE")
	r.Cell("cpa", float64(p.updates))
	r.At(Point{Lat: 38.97, Lon: -76.46})
	r.Done()
}

func (p *tabledTest) Draw(c *Chart) {
	p.draws++
	c.Status("%d drawn", p.draws)
}

func newTargetsTable() *Table {
	return NewTable(TableOpts{
		Key: "targets", Title: "AIS Targets", Menu: "Vessels",
		Columns: []Column{
			{Key: "name", Label: "Vessel", Type: ColText},
			{Key: "cpa", Label: "CPA", Type: ColDistance},
			{Key: "state", Type: ColFlag},
		},
		Sort: &TableSort{Key: "cpa", Ascending: true},
		At:   &TableAt{Lat: "lat", Lon: "lon"},
	})
}

func startTabled(t *testing.T) *tabledTest {
	t.Helper()
	resetHost()
	// A monotonic clock that has already run. Zero is the library's "no batch
	// has gone out yet", so a test that leaves the clock there never closes
	// the cadence gate.
	testHost.Mono = 1
	p := &tabledTest{
		speed: SubscribeNumber("navigation.speedOverGround", InputOpts{Optional: true}),
		table: newTargetsTable(),
	}
	Register(p)
	if rc := dispatchStart([]byte(`{"abi":1,"config":{}}`)); rc != 0 {
		t.Fatalf("lk_start answered %d: %v", rc, testHost.Logs)
	}
	return p
}

const oneSpeed = `{"values":[{"path":"navigation.speedOverGround","value":3.2,"ts":1,"age_ms":0}]}`

func openTable(t *testing.T, key string) {
	t.Helper()
	if rc := dispatchEvent(TableOpen, 0, []byte(`{"key":"`+key+`"}`)); rc != 0 {
		t.Fatalf("the table opening answered %d", rc)
	}
}

func TestTheDeclarationIsTheEntryTheManifestCarries(t *testing.T) {
	resetHost()
	want := `[{"key":"targets","title":"AIS Targets","menu":"Vessels","columns":[` +
		`{"key":"name","label":"Vessel","type":"text"},` +
		`{"key":"cpa","label":"CPA","type":"distance"},` +
		`{"key":"state","label":"","type":"flag"}],` +
		`"sort":{"key":"cpa","ascending":true},"at":{"lat":"lat","lon":"lon"}}]`
	if got := string(TablesJSON(newTargetsTable())); got != want {
		t.Fatalf("the declaration is\n%s\nwant\n%s", got, want)
	}
}

func TestStartDeclaresTheTableToTheHost(t *testing.T) {
	startTabled(t)
	if len(testHost.TablesDeclared) != 1 {
		t.Fatalf("want one declaration, got %v", testHost.TablesDeclared)
	}
	if !strings.Contains(testHost.TablesDeclared[0], `"key":"targets"`) {
		t.Fatalf("the declaration is %s", testHost.TablesDeclared[0])
	}
}

func TestATableIsFilledFromOnUpdateAndNotFromDraw(t *testing.T) {
	p := startTabled(t)
	openTable(t, "targets")

	// The dialog opens and fills at once. Nothing was drawn to produce the
	// rows: no overlay batch went out.
	if p.updates != 1 || p.draws != 0 {
		t.Fatalf("%d updates, %d draws", p.updates, p.draws)
	}
	want := `{"key":"targets","upsert":[{"id":"899000101","band":0,"name":"ANNE","cpa":1,` +
		`"lat":38.97,"lon":-76.46}],"remove":[]}`
	if got := lastTableBatch(); got != want {
		t.Fatalf("the batch is\n%s\nwant\n%s", got, want)
	}
	if len(testHost.Overlays) != 0 {
		t.Fatalf("the table cycle drew: %v", testHost.Overlays)
	}

	// A frame draws and says its line. It runs no decision and sends no rows.
	tick(t)
	if p.draws != 1 || p.updates != 1 {
		t.Fatalf("the frame ran the decision: %d updates, %d draws", p.updates, p.draws)
	}
	if len(testHost.TableBatches) != 1 {
		t.Fatalf("the frame sent rows: %v", testHost.TableBatches)
	}

	// A batch of values does: the data path is what the cycle rides.
	testHost.Mono += TableInterval.Milliseconds()
	dispatchEvent(StoreChanged, 0, []byte(oneSpeed))
	if p.updates != 2 {
		t.Fatalf("the value did not reach OnUpdate: %d updates", p.updates)
	}
	if !strings.Contains(lastTableBatch(), `"cpa":2`) {
		t.Fatalf("the row did not follow the value: %s", lastTableBatch())
	}
}

func TestTheCadenceGateHoldsARebuildToOneASecond(t *testing.T) {
	p := startTabled(t)
	openTable(t, "targets")
	if len(testHost.TableBatches) != 1 {
		t.Fatalf("want the opening batch, got %v", testHost.TableBatches)
	}

	// Eleven batches of values across the next 990 ms, each changing the
	// row. Exactly one of them clears the 950 ms gate.
	for i := 0; i < 11; i++ {
		testHost.Mono += 90
		dispatchEvent(StoreChanged, 0, []byte(oneSpeed))
	}
	if p.updates != 12 {
		t.Fatalf("want twelve decisions, got %d", p.updates)
	}
	if len(testHost.TableBatches) != 2 {
		t.Fatalf("want two batches in a second, got %d: %v", len(testHost.TableBatches), testHost.TableBatches)
	}
	if !strings.Contains(lastTableBatch(), `"cpa":12`) {
		t.Fatalf("the batch carries the wrong cycle: %s", lastTableBatch())
	}
}

func TestNoRowsAreBuiltWhileTheDialogIsShut(t *testing.T) {
	p := startTabled(t)

	dispatchEvent(StoreChanged, 0, []byte(oneSpeed))
	if p.updates != 1 {
		t.Fatalf("want one decision, got %d", p.updates)
	}
	if len(testHost.TableBatches) != 0 {
		t.Fatalf("rows were built for a dialog nobody has open: %v", testHost.TableBatches)
	}
}

func TestClosingTheDialogForgetsWhatWasOnIt(t *testing.T) {
	startTabled(t)
	openTable(t, "targets")

	// The host drops the rows when the dialog closes, so the library must too:
	// the next opening has to describe the whole set again.
	dispatchEvent(TableClosed, 0, []byte(`{"key":"targets"}`))
	openTable(t, "targets")
	if len(testHost.TableBatches) != 2 {
		t.Fatalf("the second opening sent %d batches", len(testHost.TableBatches))
	}
	if !strings.Contains(testHost.TableBatches[1], `"name":"ANNE"`) {
		t.Fatalf("the second opening did not describe the row: %s", testHost.TableBatches[1])
	}
}

func TestARowLeavesWhenACycleDoesNotDescribeIt(t *testing.T) {
	p := startTabled(t)
	openTable(t, "targets")

	// The plugin stops describing the row. The cycle that follows takes it off:
	// a row you do not upsert leaves the table, and there is no delete call.
	p.hide = true
	testHost.Mono += TableInterval.Milliseconds()
	dispatchEvent(StoreChanged, 0, []byte(oneSpeed))
	if !strings.Contains(lastTableBatch(), `"remove":["899000101"]`) {
		t.Fatalf("the row did not leave: %s", lastTableBatch())
	}

	// The plugin describes it again and it comes back.
	p.hide = false
	testHost.Mono += TableInterval.Milliseconds()
	dispatchEvent(StoreChanged, 0, []byte(oneSpeed))
	if !strings.Contains(lastTableBatch(), `"id":"899000101"`) {
		t.Fatalf("the row never came back: %s", lastTableBatch())
	}
}

func TestATableWithNoOnUpdateIsRefusedAtStart(t *testing.T) {
	resetHost()
	newTargetsTable()
	Register(&windlineTest{
		boat: SubscribePosition("navigation.position"),
		twd:  SubscribeNumber("environment.wind.directionTrue"),
	})
	if rc := dispatchStart([]byte(`{"abi":1,"config":{}}`)); rc != -1 {
		t.Fatalf("lk_start answered %d, want a refusal", rc)
	}
	if len(logsWith("no OnUpdate method to fill it")) == 0 {
		t.Fatalf("the refusal did not name the missing hook: %v", testHost.Logs)
	}
}

// A plugin that writes cells its declaration cannot hold.
type oddCellsTest struct{ table *Table }

func (p *oddCellsTest) OnUpdate() {
	if !p.table.IsOpen() {
		return
	}
	r := p.table.Row("899000202")
	r.Cell("name", 12.0)            // a number in a text column
	r.Cell("cpa", "close")          // a string in a number column
	r.Cell("state", (*string)(nil)) // a value the plugin does not have
	r.Cell("heading", 180.0)        // a column nobody declared
	r.Done()

	// The same cells through pointers, which is how a plugin holds a value
	// that may be absent.
	r = p.table.Row("899000303")
	r.Cell("name", ptr("ANNE"))
	r.Cell("cpa", ptr(124.0))
	r.Done()
}

func ptr[T any](v T) *T { return &v }

func TestACellTheColumnCannotHoldIsADash(t *testing.T) {
	resetHost()
	p := &oddCellsTest{table: newTargetsTable()}
	Register(p)
	if rc := dispatchStart([]byte(`{"abi":1,"config":{}}`)); rc != 0 {
		t.Fatalf("lk_start answered %d: %v", rc, testHost.Logs)
	}
	openTable(t, "targets")

	// A dash rather than the wrong shape: a number written into a text column
	// would break the shell's sort. The column nobody declared is left out
	// altogether.
	want := `{"key":"targets","upsert":[{"id":"899000202","name":null,"cpa":null,"state":null},` +
		`{"id":"899000303","name":"ANNE","cpa":124}],"remove":[]}`
	if got := lastTableBatch(); got != want {
		t.Fatalf("the batch is\n%s\nwant\n%s", got, want)
	}
	if len(logsWith(`column "heading"`)) == 0 {
		t.Fatalf("the undeclared column was not logged: %v", testHost.Logs)
	}
}

func TestACellOutsideACycleIsDropped(t *testing.T) {
	p := startTabled(t)
	openTable(t, "targets")

	// Between cycles nothing is building, so a row written then is not held
	// and cannot reach the host.
	before := len(testHost.TableBatches)
	r := p.table.Row("899000303")
	r.Cell("name", "LATE")
	r.Done()
	if len(testHost.TableBatches) != before {
		t.Fatalf("a row outside a cycle went out: %v", testHost.TableBatches)
	}
}

// -- the cycle runs when a value expires -------------------------------------

// feedTest is a plugin with one value and a dialog. The row exists only while
// the value counts, so the table has to follow the feed both ways.
type feedTest struct {
	depth   *NumberInput
	table   *Table
	updates int
}

func (p *feedTest) OnUpdate() {
	p.updates++
	d, ok := p.depth.Fresh()
	if !ok {
		return
	}
	r := p.table.Row("belowTransducer")
	r.Cell("depth", d)
	r.Done()
}

func startFeed(t *testing.T) *feedTest {
	t.Helper()
	resetHost()
	testHost.Mono = 1
	p := &feedTest{
		depth: SubscribeNumber("environment.depth.belowTransducer"),
		table: NewTable(TableOpts{
			Key: "sounder", Title: "Sounder", Menu: "Test",
			Columns: []Column{{Key: "depth", Label: "Depth", Type: ColDistance}},
		}),
	}
	Register(p)
	if rc := dispatchStart([]byte(`{"abi":1,"config":{}}`)); rc != 0 {
		t.Fatalf("lk_start answered %d: %v", rc, testHost.Logs)
	}
	return p
}

const oneDepth = `{"values":[{"path":"environment.depth.belowTransducer","value":3.4,"ts":1,"age_ms":0}]}`

func TestATableEmptiesWhenItsFeedStops(t *testing.T) {
	p := startFeed(t)
	openTable(t, "sounder")

	// Nothing has arrived, so nothing can expire and nothing is waiting.
	if len(testHost.Timers) != 0 {
		t.Fatalf("a timer was armed with nothing to wait for: %v", testHost.Timers)
	}

	// A sounding lands. The row is on the dialog, and the cycle has taken an
	// appointment for the moment that value stops counting: one millisecond
	// past its window, because the last millisecond still counts.
	dispatchEvent(StoreChanged, 0, []byte(oneDepth))
	if got := lastTableBatch(); !strings.Contains(got, `"depth":3.4`) {
		t.Fatalf("the sounding is not on the dialog: %s", got)
	}
	appt := reg.updateTimer
	if appt < 0 {
		t.Fatal("the value took no appointment")
	}
	if testHost.Periodic[appt] {
		t.Fatal("the appointment is a poll, not a one-shot")
	}
	if want := DefaultMaxAge.Milliseconds() + 1; testHost.Timers[appt] != want {
		t.Fatalf("the appointment is in %d ms, want %d", testHost.Timers[appt], want)
	}

	// Now the feed stops. Nothing else arrives, ever. The appointment comes
	// round, the cycle runs on a value that no longer counts, and the row it
	// fed leaves the dialog instead of sitting there for good.
	testHost.Mono += testHost.Timers[appt]
	armed := len(testHost.Timers)
	dispatchEvent(Timer, appt, nil)
	if p.updates != 3 {
		// Opening the dialog, the sounding, and the expiry.
		t.Fatalf("the cycle ran %d times, want 3", p.updates)
	}
	want := `{"key":"sounder","upsert":[],"remove":["belowTransducer"]}`
	if got := lastTableBatch(); got != want {
		t.Fatalf("the batch is\n%s\nwant\n%s", got, want)
	}

	// The plugin has been told, and there is no later moment to tell it about.
	// Nothing is armed, so a boat whose instruments are off costs nothing until
	// a value arrives.
	if reg.updateTimer >= 0 {
		t.Fatalf("an appointment was kept with nothing left to expire")
	}
	if len(testHost.Timers) != armed {
		t.Fatalf("a timer was armed after everything had expired: %v", testHost.Timers)
	}
}

// twoClocksTest reads two values on different clocks: the wind is slower than
// the position, so they stop counting at different moments.
type twoClocksTest struct {
	boat     *PositionInput
	twd      *NumberInput
	haveBoat bool
	haveWind bool
}

func (p *twoClocksTest) OnUpdate() {
	_, p.haveBoat = p.boat.Fresh()
	_, p.haveWind = p.twd.Fresh()
}

func TestEachInputExpiresOnItsOwnWakeup(t *testing.T) {
	resetHost()
	testHost.Mono = 1
	const windMaxAge = 20 * time.Second
	p := &twoClocksTest{
		boat: SubscribePosition("navigation.position", InputOpts{Optional: true}),
		twd: SubscribeNumber("environment.wind.directionTrue", InputOpts{
			Optional: true,
			MaxAge:   windMaxAge,
		}),
	}
	Register(p)
	if rc := dispatchStart([]byte(`{"abi":1,"config":{}}`)); rc != 0 {
		t.Fatalf("lk_start answered %d: %v", rc, testHost.Logs)
	}

	dispatchEvent(StoreChanged, 0, []byte(
		`{"values":[{"path":"navigation.position","value":{"lat":38.97,"lon":-76.46},"ts":1,"age_ms":0}]}`))
	dispatchEvent(StoreChanged, 0, []byte(
		`{"values":[{"path":"environment.wind.directionTrue","value":210,"ts":1,"age_ms":0}]}`))
	if !p.haveBoat || !p.haveWind {
		t.Fatal("both values should count")
	}

	// The earliest window rules the appointment. The wind has fifteen seconds
	// left, so waking for it now would find nothing to say.
	first := reg.updateTimer
	if want := DefaultMaxAge.Milliseconds() + 1; testHost.Timers[first] != want {
		t.Fatalf("the first appointment is in %d ms, want %d", testHost.Timers[first], want)
	}

	// The position goes and the wind stays. The plugin is told which one, and
	// the next appointment is the wind's own.
	testHost.Mono += testHost.Timers[first]
	dispatchEvent(Timer, first, nil)
	if p.haveBoat {
		t.Fatal("the position should have expired")
	}
	if !p.haveWind {
		t.Fatal("the wind should still count")
	}
	second := reg.updateTimer
	if want := (windMaxAge - DefaultMaxAge).Milliseconds(); testHost.Timers[second] != want {
		t.Fatalf("the second appointment is in %d ms, want %d", testHost.Timers[second], want)
	}

	// The wind goes too. Both are stale, nothing further can change, and
	// nothing is armed.
	testHost.Mono += testHost.Timers[second]
	dispatchEvent(Timer, second, nil)
	if p.haveWind {
		t.Fatal("the wind should have expired")
	}
	if reg.updateTimer >= 0 {
		t.Fatal("an appointment was kept with nothing left to expire")
	}
}

func TestTheAppointmentIsKeptWhileTheChartGrantIsOff(t *testing.T) {
	p := startTabled(t)
	drawTimer := reg.drawTimer

	// The mariner switches drawing off and the draw timer goes down.
	dispatchEvent(GrantsChanged, 0, []byte(`{"granted":[]}`))
	if reg.drawTimer >= 0 {
		t.Fatal("the draw timer is still up")
	}

	// A value still arrives and still takes its appointment. A plugin with no
	// permission to draw has a dialog to fill and a condition to watch.
	before := p.updates
	dispatchEvent(StoreChanged, 0, []byte(oneSpeed))
	appt := reg.updateTimer
	if appt < 0 {
		t.Fatal("the value took no appointment while the grant was off")
	}
	if appt == drawTimer {
		t.Fatal("the appointment is the draw timer")
	}
	if testHost.Periodic[appt] {
		t.Fatal("the appointment is a poll, not a one-shot")
	}

	// And it is delivered, without the draw timer coming back.
	testHost.Mono += testHost.Timers[appt]
	dispatchEvent(Timer, appt, nil)
	if p.updates != before+2 {
		t.Fatalf("the cycle ran %d times, want %d", p.updates-before, 2)
	}
	if reg.drawTimer >= 0 {
		t.Fatal("the draw timer came back on an expiry")
	}
}
