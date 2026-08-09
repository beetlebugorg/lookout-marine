//go:build !wasip1

package lookout

import (
	"strings"
	"testing"
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

	// A batch of readings does: the data path is what the cycle rides.
	testHost.Mono += TableInterval.Milliseconds()
	dispatchEvent(StoreChanged, 0, []byte(oneSpeed))
	if p.updates != 2 {
		t.Fatalf("the reading did not reach OnUpdate: %d updates", p.updates)
	}
	if !strings.Contains(lastTableBatch(), `"cpa":2`) {
		t.Fatalf("the row did not follow the reading: %s", lastTableBatch())
	}
}

func TestTheCadenceGateHoldsARebuildToOneASecond(t *testing.T) {
	p := startTabled(t)
	openTable(t, "targets")
	if len(testHost.TableBatches) != 1 {
		t.Fatalf("want the opening batch, got %v", testHost.TableBatches)
	}

	// Eleven batches of readings across the next 990 ms, each changing the
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
	r.Cell("state", (*string)(nil)) // a reading the plugin does not have
	r.Cell("heading", 180.0)        // a column nobody declared
	r.Done()

	// The same cells through pointers, which is how a plugin holds a reading
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
