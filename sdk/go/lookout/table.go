package lookout

// Tables: the dialogs a plugin fills. A table is data, not drawing. There is no
// capability to ask for, and the library runs its cycle on the data path,
// around OnUpdate.
//
// Declare one as a package-level variable, the way an input is declared, and
// the library tells the host about it at start:
//
//	var Targets = lk.NewTable(lk.TableOpts{
//		Key: "targets", Title: "AIS Targets", Menu: "Vessels",
//		Columns: []lk.Column{{Key: "cpa", Label: "CPA", Type: lk.ColDistance}},
//		Sort:    &lk.TableSort{Key: "cpa", Ascending: true},
//	})
//
//	func (p *plugin) OnUpdate() {
//		if !Targets.IsOpen() {
//			return
//		}
//		for _, t := range traffic.Targets() {
//			r := Targets.Row(mmsiText(t.MMSI))
//			r.Cell("cpa", cpaOf(t))
//			r.Done()
//		}
//	}

import (
	"strconv"
	"time"
)

// ColumnType is what a column carries. THE PLUGIN SENDS SI AND THE SHELL
// FORMATS: metres, metres per second, degrees true, seconds. That is the
// reverse of a pick row, and it is what lets the shell sort a column
// numerically and show it in the mariner's own units.
type ColumnType string

const (
	ColDistance ColumnType = "distance"
	ColSpeed    ColumnType = "speed"
	ColBearing  ColumnType = "bearing"
	ColDuration ColumnType = "duration"
	ColNumber   ColumnType = "number"
	ColText     ColumnType = "text"
	// ColFlag is a state word the shell colours: "alarm", "warning".
	ColFlag ColumnType = "flag"
)

// Column is one declared column. An empty label is a column with no heading,
// which is what a flag column usually wants.
type Column struct {
	Key   string
	Label string
	Type  ColumnType
}

// TableSort is the column the shell sorts by until the mariner says otherwise.
type TableSort struct {
	Key       string
	Ascending bool
}

// TableAt names the two row keys carrying a position. A row that has them is
// locatable: the mariner activates it and the chart centres on it. They need
// not be columns; a position is usually not worth a column of its own.
type TableAt struct {
	Lat string
	Lon string
}

// TableOpts declares a dialog. The declaration is the whole contract: the shell
// builds the dialog from it, opens it from the menu it names, sorts any column,
// and formats every value for the mariner.
type TableOpts struct {
	Key   string
	Title string
	// Menu is where the shell opens the dialog from: "Vessels".
	Menu    string
	Columns []Column
	Sort    *TableSort
	At      *TableAt
}

// MaxColumns is the host's budget, and the reason for it: a table wider than
// this is a spreadsheet, and nobody reads a spreadsheet on a moving boat.
const MaxColumns = 16

// MaxRows is what one plugin's diff holds between cycles. The host takes 512.
const MaxRows = 256

// TableInterval is the shortest gap between two batches, measured from the
// start of one cycle to the start of the next. The library holds a batch back
// rather than have the host refuse it, and it leaves itself the margin between
// this and the host's own 900 ms.
const TableInterval = 950 * time.Millisecond

// Table is one declared dialog and the rows it holds. Build it with [NewTable].
type Table struct {
	opts TableOpts
	cols map[string]ColumnType

	entries []tableEntry
	index   map[string]int

	b    []byte
	sets int
	// building is true between the cycle's start and its end, and only while
	// the dialog is open and the cadence allows another batch.
	building bool
	open     bool
	// lastMs is when the last batch that went out was BUILT, monotonic.
	// Measuring from the start of a cycle rather than from the send keeps the
	// gap the host sees a shade wider than the one measured here.
	lastMs  int64
	cycleMs int64

	// warned holds the row keys already complained about, so a typo is one log
	// line rather than one a second forever.
	warned map[string]bool
}

type tableEntry struct {
	id   string
	hash uint64
	live bool
	seen bool
}

// NewTable declares a dialog and registers it. Call it from a package-level
// variable, the way an input is declared; the library tells the host about it
// when the plugin starts.
func NewTable(opts TableOpts) *Table {
	t := &Table{opts: opts, cols: map[string]ColumnType{}, index: map[string]int{}}
	for _, c := range opts.Columns {
		if _, dup := t.cols[c.Key]; dup {
			noteWiring("table " + opts.Key + ": two columns called " + strconv.Quote(c.Key))
		}
		t.cols[c.Key] = c.Type
	}
	t.check()
	registerTable(t)
	return t
}

// check reports a declaration the shell cannot build a dialog from. These are
// held until the host is listening, the same as any other wiring complaint.
func (t *Table) check() {
	switch {
	case t.opts.Key == "":
		noteWiring("a table needs a key")
	case t.opts.Title == "":
		noteWiring("table " + t.opts.Key + " needs a title: it is the dialog's own name")
	case t.opts.Menu == "":
		noteWiring("table " + t.opts.Key + " needs a menu: the shell opens the dialog from it")
	case len(t.opts.Columns) == 0:
		noteWiring("table " + t.opts.Key + " needs at least one column")
	case len(t.opts.Columns) > MaxColumns:
		noteWiring("table " + t.opts.Key + " declares " + strconv.Itoa(len(t.opts.Columns)) +
			" columns; the host allows " + strconv.Itoa(MaxColumns))
	}
	if s := t.opts.Sort; s != nil {
		if _, ok := t.cols[s.Key]; !ok {
			noteWiring("table " + t.opts.Key + ": the default sort names column " +
				strconv.Quote(s.Key) + ", which is not declared")
		}
	}
}

// Key is the table's key, as the manifest and the host know it.
func (t *Table) Key() string { return t.opts.Key }

// IsOpen is true while the mariner has the dialog on screen. Skip the work of
// building rows nobody is looking at.
func (t *Table) IsOpen() bool { return t.open }

// Row starts one row. id names it for its whole life. Set the cells, then call
// Done; a row you do not describe this cycle leaves the table.
//
// DESCRIBE THE WHOLE SET EVERY CYCLE, the way Draw describes the whole picture.
// There is no delete call.
func (t *Table) Row(id string) *TableRow {
	r := &TableRow{t: t, id: id}
	if !t.building || id == "" {
		return r
	}
	r.live = true
	r.start = len(t.b)
	if t.sets > 0 {
		t.b = append(t.b, ',')
	}
	r.body = len(t.b)
	t.b = append(t.b, `{"id":`...)
	t.b = appendString(t.b, id)
	return r
}

// Remove takes one row out now, without waiting for a cycle to pass it by.
func (t *Table) Remove(id string) {
	if i, ok := t.index[id]; ok {
		t.entries[i].seen = false
	}
}

// begin starts a cycle. The library calls this before OnUpdate.
func (t *Table) begin(mono int64) {
	t.building = t.open && (t.lastMs == 0 || mono-t.lastMs >= TableInterval.Milliseconds())
	if !t.building {
		return
	}
	t.cycleMs = mono
	for i := range t.entries {
		t.entries[i].seen = false
	}
	t.b = append(t.b[:0], `{"key":`...)
	t.b = appendString(t.b, t.opts.Key)
	t.b = append(t.b, `,"upsert":[`...)
	t.sets = 0
}

// flush sends what changed and takes off what this cycle did not describe. The
// library calls this after OnUpdate.
func (t *Table) flush() {
	if !t.building {
		return
	}
	t.building = false

	dels := 0
	for i := range t.entries {
		if t.entries[i].live && !t.entries[i].seen {
			dels++
		}
	}
	if t.sets == 0 && dels == 0 {
		return
	}

	t.b = append(t.b, `],"remove":[`...)
	k := 0
	for i := range t.entries {
		e := &t.entries[i]
		if !e.live || e.seen {
			continue
		}
		if k > 0 {
			t.b = append(t.b, ',')
		}
		k++
		t.b = appendString(t.b, e.id)
	}
	t.b = append(t.b, `]}`...)

	if TableUpdateJSON(t.b) < 0 {
		// The host refused the batch, so what is on screen no longer matches
		// what is held here. Forget it and describe the whole set next cycle.
		t.forget()
		return
	}
	t.lastMs = t.cycleMs
	kept := t.entries[:0]
	for _, e := range t.entries {
		if e.live && e.seen {
			kept = append(kept, e)
		}
	}
	t.entries = kept
	t.index = make(map[string]int, len(t.entries))
	for i, e := range t.entries {
		t.index[e.id] = i
	}
}

// setOpen routes one TableOpen or TableClosed event. It is true when the event
// named this table.
func (t *Table) setOpen(key string, open bool) bool {
	if key != t.opts.Key {
		return false
	}
	t.open = open
	if !open {
		// The host dropped the rows when it closed the dialog, so the diff must
		// forget them too, or the next opening sends nothing.
		t.forget()
		t.lastMs = 0
	}
	return true
}

func (t *Table) forget() {
	t.entries = t.entries[:0]
	t.index = map[string]int{}
	t.b = t.b[:0]
	t.sets = 0
}

// take records one finished row, or rewinds it when the table already holds
// exactly that row.
func (t *Table) take(id string, start, body int) {
	sum := fnv1a(t.b[body:])
	if i, ok := t.index[id]; ok {
		e := &t.entries[i]
		e.seen = true
		if e.live && e.hash == sum {
			t.b = t.b[:start]
			return
		}
		e.hash = sum
		e.live = true
		t.sets++
		return
	}
	if len(t.entries) == MaxRows {
		t.b = t.b[:start]
		t.warnOnce("rows", "table "+t.opts.Key+": more than "+strconv.Itoa(MaxRows)+" rows; "+
			strconv.Quote(id)+" dropped")
		return
	}
	t.index[id] = len(t.entries)
	t.entries = append(t.entries, tableEntry{id: id, hash: sum, live: true, seen: true})
	t.sets++
}

func (t *Table) warnOnce(key, msg string) {
	if t.warned == nil {
		t.warned = map[string]bool{}
	}
	if t.warned[key] {
		return
	}
	t.warned[key] = true
	Log(Warn, "%s", msg)
}

// TableRow is one row under construction. Set its cells and call Done.
type TableRow struct {
	t    *Table
	id   string
	live bool
	// start is where the row began in the batch, body where its content did.
	// A row the table already holds is rewound to start; the hash is taken
	// over body onwards, so a leading comma cannot change it.
	start int
	body  int
}

// Band is the ordering policy: band 0 first, and the mariner's column sort
// never crosses a band. An alarmed row rides in band 0 and holds the top of the
// table whatever column the mariner sorted by.
func (r *TableRow) Band(band int) {
	if !r.live {
		return
	}
	r.t.b = append(r.t.b, `,"band":`...)
	r.t.b = strconv.AppendInt(r.t.b, int64(band), 10)
}

// Cell sets one declared column. The column's declared type decides how the
// value is written, so a text column takes a string and every other column
// takes a number.
//
// A nil value is null on the wire and a dash on screen: never heard and heard
// as zero are different values. A *float64, *string or *bool is read through,
// and a nil pointer is a dash.
func (r *TableRow) Cell(key string, value any) {
	if !r.live {
		return
	}
	ctype, ok := r.t.cols[key]
	if !ok {
		r.t.warnOnce("col:"+key, "table "+r.t.opts.Key+" declares no column "+strconv.Quote(key))
		return
	}
	r.t.b = append(r.t.b, ',')
	r.t.b = appendString(r.t.b, key)
	r.t.b = append(r.t.b, ':')
	r.appendValue(key, ctype == ColText || ctype == ColFlag, value)
}

// At sets the row's position, under the two keys the declaration named. A row
// with no TableAt in its declaration has nowhere to put it, and this does
// nothing.
func (r *TableRow) At(at Point) {
	if !r.live || r.t.opts.At == nil {
		return
	}
	r.t.b = append(r.t.b, ',')
	r.t.b = appendString(r.t.b, r.t.opts.At.Lat)
	r.t.b = append(r.t.b, ':')
	r.t.b = appendNum(r.t.b, at.Lat)
	r.t.b = append(r.t.b, ',')
	r.t.b = appendString(r.t.b, r.t.opts.At.Lon)
	r.t.b = append(r.t.b, ':')
	r.t.b = appendNum(r.t.b, at.Lon)
}

// Done closes the row and hands it to the diff.
func (r *TableRow) Done() {
	if !r.live {
		return
	}
	r.live = false
	r.t.b = append(r.t.b, '}')
	r.t.take(r.id, r.start, r.body)
}

// appendValue writes the cell the column's declared type asks for. A pointer is
// read through, and nil at any depth is a dash.
func (r *TableRow) appendValue(key string, text bool, value any) {
	v, have := deref(value)
	if !have {
		r.t.b = append(r.t.b, "null"...)
		return
	}
	if text {
		s, ok := v.(string)
		if !ok {
			r.mismatch(key, "text")
			return
		}
		r.t.b = appendString(r.t.b, s)
		return
	}
	n, ok := asFloat(v)
	if !ok {
		r.mismatch(key, "a number")
		return
	}
	r.t.b = appendNum(r.t.b, n)
}

// mismatch is a cell the column cannot hold. It goes out as a dash, because a
// number written into a text column would break the shell's sort, and it is
// logged once: the plugin is passing the wrong thing every cycle.
func (r *TableRow) mismatch(key, want string) {
	r.t.b = append(r.t.b, "null"...)
	r.t.warnOnce("cell:"+key, "table "+r.t.opts.Key+": column "+strconv.Quote(key)+" holds "+want)
}

// deref unwraps a pointer once. It reports false for a nil of any shape.
func deref(value any) (any, bool) {
	switch v := value.(type) {
	case nil:
		return nil, false
	case *string:
		if v == nil {
			return nil, false
		}
		return *v, true
	case *float64:
		if v == nil {
			return nil, false
		}
		return *v, true
	case *int:
		if v == nil {
			return nil, false
		}
		return *v, true
	case *bool:
		if v == nil {
			return nil, false
		}
		return *v, true
	}
	return value, true
}

// asFloat is every numeric shape a plugin holds a value in. A bool counts:
// a flag column is text, so a bool in a number column is a count of one.
func asFloat(value any) (float64, bool) {
	switch v := value.(type) {
	case float64:
		return v, true
	case float32:
		return float64(v), true
	case int:
		return float64(v), true
	case int32:
		return float64(v), true
	case int64:
		return float64(v), true
	case uint32:
		return float64(v), true
	case uint64:
		return float64(v), true
	case bool:
		if v {
			return 1, true
		}
		return 0, true
	}
	return 0, false
}

// TablesJSON is the "tables" array a manifest must carry for these
// declarations. A plugin's own test compares it with the manifest it ships, the
// way [SettingsJSON] is compared.
func TablesJSON(tables ...*Table) []byte {
	b := append(make([]byte, 0, 256), '[')
	for i, t := range tables {
		if i > 0 {
			b = append(b, ',')
		}
		b = t.declaration(b)
	}
	return append(b, ']')
}

// declaration is the manifest's entry for one table, which is the same text the
// host is given at start.
func (t *Table) declaration(b []byte) []byte {
	b = append(b, `{"key":`...)
	b = appendString(b, t.opts.Key)
	b = append(b, `,"title":`...)
	b = appendString(b, t.opts.Title)
	b = append(b, `,"menu":`...)
	b = appendString(b, t.opts.Menu)
	b = append(b, `,"columns":[`...)
	for i, c := range t.opts.Columns {
		if i > 0 {
			b = append(b, ',')
		}
		b = append(b, `{"key":`...)
		b = appendString(b, c.Key)
		b = append(b, `,"label":`...)
		b = appendString(b, c.Label)
		b = append(b, `,"type":`...)
		b = appendString(b, string(c.Type))
		b = append(b, '}')
	}
	b = append(b, ']')
	if s := t.opts.Sort; s != nil {
		b = append(b, `,"sort":{"key":`...)
		b = appendString(b, s.Key)
		b = append(b, `,"ascending":`...)
		b = appendBool(b, s.Ascending)
		b = append(b, '}')
	}
	if a := t.opts.At; a != nil {
		b = append(b, `,"at":{"lat":`...)
		b = appendString(b, a.Lat)
		b = append(b, `,"lon":`...)
		b = appendString(b, a.Lon)
		b = append(b, '}')
	}
	return append(b, '}')
}

// declare tells the host about this table. The library calls it at start.
func (t *Table) declare() {
	if TableDeclareJSON(t.declaration(nil)) < 0 {
		Log(Warn, "table %s: the host refused the declaration", t.opts.Key)
	}
}
