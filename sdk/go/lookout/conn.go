package lookout

// Connections the mariner keeps, owned by the library.
//
// A source plugin declares the list once:
//
//	var servers = lk.Connections(lk.ConnOpts{
//		Key:      "servers",
//		Group:    "Signal K servers",
//		AddLabel: "Add Server",
//		RateNoun: "deltas",
//		Columns:  lk.RowColumns{Port: lk.NumSpec{Label: "Port", Min: 1, Max: 65535, Default: 8375}},
//		Row:      func() any { return &server{} },
//	})
//
//	func (p *plugin) OnData(row *lk.Row, data []byte) { … }
//
// and the library owns everything else: the settings list schema, one socket per
// row, the reconnect clock, the failure count behind "unreachable", the pause
// switch, the per-row status item and the plugin's own status line.
//
// ROWS ARE MATCHED BY ID. Editing one row never disturbs another's connection:
// only an address change, a pause or a delete closes a socket.

import (
	"encoding/json"
	"fmt"
	"reflect"
	"slices"
	"time"
)

// ConnOpts is how one connection list behaves. Only Key and Group are required.
type ConnOpts struct {
	// Key is the config key the row array arrives under.
	Key string
	// Group is the section heading in the settings window.
	Group string
	Tab   Tab
	// Footer, Empty and AddLabel are the list's own wording in the settings
	// window.
	Footer   string
	Empty    string
	AddLabel string
	// Columns words the four standard columns and sets the port's range. A zero
	// column keeps the library's wording.
	Columns RowColumns
	// Row makes one row's struct: the plugin's extra columns, which are its
	// exported fields with an lk tag, and its own per-row state, which is
	// everything else. The library fills the columns in and leaves the state
	// alone.
	Row func() any

	// Reconnect is the delay before a dropped connection is retried. Default 2 s.
	Reconnect time.Duration
	// UnreachableAfter is failed connects in a row before a row reads as
	// unreachable rather than reconnecting. Default 3, which is six seconds of
	// silence.
	UnreachableAfter uint32
	// StatusEvery is how often the status is rebuilt, and the window a rate is
	// averaged over. Default 2 s.
	StatusEvery time.Duration
	// RateNoun is what Row.Count counts, for the status: "42 msg/s".
	RateNoun string
	// StatusEmpty is the plugin's status detail when the mariner has added no
	// rows.
	StatusEmpty string
	// NoAnswerDetail is what a row says once it has read as unreachable.
	NoAnswerDetail string
	// RefusedDetail is what a row says when the host would not dial it at all.
	// That only happens when the manifest's grant does not cover the address,
	// and only the plugin knows which grant it asked for.
	RefusedDetail string
}

// RowColumns is the wording of the four columns every connection list carries,
// in the order a shell draws them. The keys and the kinds are fixed, because the
// library dials the row itself. The switch column always starts on.
type RowColumns struct {
	Name    TextSpec
	Host    TextSpec
	Port    NumSpec
	Enabled FlagSpec
}

func (c RowColumns) merged() RowColumns {
	if c.Name.Label == "" {
		c.Name = TextSpec{
			Label:    "Name",
			Desc:     "What you call this source. Leave it empty to show the address.",
			Optional: true,
		}
	}
	if c.Host.Label == "" {
		c.Host = TextSpec{Label: "Address", Desc: "The name or IP address to connect to."}
	}
	if c.Port.Label == "" {
		c.Port.Label = "Port"
	}
	if c.Port.Desc == "" && c.Port.Min == 0 && c.Port.Max == 0 {
		c.Port.Desc = "The port to connect to."
	}
	if c.Port.Min == 0 && c.Port.Max == 0 {
		c.Port.Min, c.Port.Max = 1, 65535
	}
	if c.Port.Default == 0 {
		c.Port.Default = 10110
	}
	if c.Enabled.Label == "" {
		c.Enabled = FlagSpec{Label: "On", Desc: "Off closes the connection and stops reconnecting."}
	}
	// A new row starts on. The switch is what pauses a row, and a list whose
	// rows arrive paused would read as broken.
	c.Enabled.Default = true
	return c
}

// RowState is what one connection is doing, in the words the shell shows.
type RowState string

const (
	RowConnected    RowState = "connected"
	RowReconnecting RowState = "reconnecting"
	// RowNoAnswer is dialled and dialled and nothing answered.
	RowNoAnswer RowState = "unreachable"
	RowPaused   RowState = "paused"
	// RowNoAddress is a row with no address, or a port nothing can dial.
	RowNoAddress RowState = "no_address"
	// RowRefused is an endpoint the host would not dial: a grant that does not
	// cover it.
	RowRefused RowState = "refused"
)

// Endpoint is where one row is dialled. Build one with [TCPEndpoint],
// [WSEndpoint] or [RefusedEndpoint].
type Endpoint struct {
	kind string
	host string
	port uint16
	text string
}

// TCPEndpoint dials a host and port.
func TCPEndpoint(host string, port uint16) Endpoint {
	return Endpoint{kind: "tcp", host: host, port: port}
}

// WSEndpoint dials a WebSocket URL. The manifest must grant net.ws for its host.
func WSEndpoint(url string) Endpoint { return Endpoint{kind: "ws", text: url} }

// RefusedEndpoint says this row cannot be dialled, and why. The library stops
// retrying and shows the reason on the row.
func RefusedEndpoint(why string) Endpoint { return Endpoint{kind: "refused", text: why} }

// Row is one connection: the row the mariner filled in, the plugin's own state
// for it, and the socket the library holds.
type Row struct {
	// ID is the shell's id for this row. It survives an edit, and it is what a
	// status item points at.
	ID string
	// Name is what the mariner calls it. It may be empty.
	Name string
	Host string
	Port uint16
	// Enabled false means PAUSED: the stream closes and nothing reconnects.
	Enabled bool
	// State is what ConnOpts.Row returned: the plugin's columns and its own
	// per-row state. Assert it to your own type.
	State any

	used  bool
	seen  bool
	order int

	sock       int64
	ws         bool
	retryTimer int64
	failures   uint32
	conn       RowState

	counted     uint64
	lastCounted uint64
	rate        uint64
	detail      string
}

// Label is what to call this row: the mariner's name, or the address.
func (r *Row) Label() string {
	if r.Name != "" {
		return r.Name
	}
	return r.Host
}

// Connected is true while the stream is up.
func (r *Row) Connected() bool { return r.conn == RowConnected }

// Rate is what Count counted over the last status window, per second.
func (r *Row) Rate() uint64 { return r.rate }

// Send writes to this row's stream and returns the bytes queued, or -1.
func (r *Row) Send(data []byte) int32 {
	if r.sock < 0 {
		return -1
	}
	if r.ws {
		return hostWSSend(r.sock, data)
	}
	return hostTCPSend(r.sock, data)
}

// Count counts n of whatever this row carries. The library turns it into the
// rate on the row's status line and in the plugin's.
func (r *Row) Count(n uint64) { r.counted += n }

// SetDetail adds a phrase to this row's status line, after the state. Say
// nothing that only repeats the state.
func (r *Row) SetDetail(format string, a ...any) {
	if len(a) == 0 {
		r.detail = format
		return
	}
	r.detail = fmt.Sprintf(format, a...)
}

// A row with no address cannot be dialled.
func (r *Row) usable() bool { return r.Host != "" && r.Port > 0 }

func (r *Row) closeSocket() {
	if r.sock >= 0 {
		if r.ws {
			hostWSClose(r.sock)
		} else {
			hostTCPClose(r.sock)
		}
	}
	r.sock = -1
	if r.retryTimer >= 0 {
		hostTimerCancel(r.retryTimer)
	}
	r.retryTimer = -1
	r.rate = 0
}

func (r *Row) scheduleRetry(delayMs int64) {
	if r.retryTimer >= 0 || !r.Enabled || !r.usable() {
		return
	}
	if id := hostTimerSet(delayMs, false); id >= 0 {
		r.retryTimer = id
	}
}

func (r *Row) noteFailure(limit uint32, detail string) {
	if r.failures < limit {
		r.failures++
	}
	if r.failures >= limit {
		r.conn = RowNoAnswer
		r.detail = detail
	} else {
		r.conn = RowReconnecting
		r.detail = ""
	}
}

// Conns is a list of connections. Declare it as a package-level variable with
// [Connections]; the library finds it at start.
type Conns struct {
	opts    ConnOpts
	columns RowColumns
	rows    []*Row

	statusTimer int64
	lastStatus  string
}

// Connections declares the list. One list per plugin.
func Connections(opts ConnOpts) *Conns {
	if opts.Tab == "" {
		opts.Tab = TabConnections
	}
	if opts.Reconnect == 0 {
		opts.Reconnect = 2 * time.Second
	}
	if opts.UnreachableAfter == 0 {
		opts.UnreachableAfter = 3
	}
	if opts.StatusEvery == 0 {
		opts.StatusEvery = 2 * time.Second
	}
	if opts.RateNoun == "" {
		opts.RateNoun = "msg"
	}
	if opts.StatusEmpty == "" {
		opts.StatusEmpty = "nothing configured"
	}
	if opts.NoAnswerDetail == "" {
		opts.NoAnswerDetail = "check the address"
	}
	if opts.RefusedDetail == "" {
		opts.RefusedDetail = "the host refused this address"
	}
	c := &Conns{opts: opts, columns: opts.Columns.merged(), statusTimer: -1}
	registerConns(c)
	return c
}

// All is every row the mariner has, in the order the settings window shows.
func (c *Conns) All() []*Row { return c.rows }

// ByID is the row with this id, or nil.
func (c *Conns) ByID(id string) *Row {
	for _, r := range c.rows {
		if r.ID == id {
			return r
		}
	}
	return nil
}

// group is the settings group this list declares, for the manifest schema.
func (c *Conns) group() (specGroup, error) {
	l := &listSpec{
		key:       c.opts.Key,
		footer:    c.opts.Footer,
		empty:     c.opts.Empty,
		addLabel:  c.opts.AddLabel,
		switchKey: "enabled",
	}
	// The standard columns come first because a shell draws them in order and
	// the address is what a mariner fills in first. The switch goes last.
	l.columns = append(l.columns,
		textField("name", c.columns.Name),
		textField("host", c.columns.Host),
		numField("port", c.columns.Port))
	cols, err := c.extraColumns()
	if err != nil {
		return specGroup{}, err
	}
	l.columns = append(l.columns, cols...)
	l.columns = append(l.columns, flagField("enabled", c.columns.Enabled))
	return specGroup{label: c.opts.Group, tab: c.opts.Tab, list: l}, nil
}

// extraColumns reads the plugin's own columns off the row struct: its exported
// fields with an lk tag. Everything else on that struct is the plugin's state.
func (c *Conns) extraColumns() ([]specField, error) {
	if c.opts.Row == nil {
		return nil, nil
	}
	v := reflect.ValueOf(c.opts.Row())
	for v.Kind() == reflect.Pointer {
		if v.IsNil() {
			return nil, fmt.Errorf("connections %q: Row returned a nil pointer", c.opts.Key)
		}
		v = v.Elem()
	}
	if v.Kind() != reflect.Struct {
		return nil, fmt.Errorf("connections %q: Row must return a pointer to a struct", c.opts.Key)
	}
	var out []specField
	t := v.Type()
	for i := 0; i < t.NumField(); i++ {
		f, ok, err := fieldOf(t.Field(i), i)
		if err != nil {
			return nil, fmt.Errorf("connections %q: %w", c.opts.Key, err)
		}
		if !ok {
			continue
		}
		if f.key == "id" {
			return nil, fmt.Errorf("connections %q: a column may not be called 'id': the host writes that key itself", c.opts.Key)
		}
		out = append(out, f)
	}
	return out, nil
}

// ---- what the dispatcher calls -------------------------------------------

func (c *Conns) start(cfg map[string]json.RawMessage) {
	c.reconcile(cfg)
	c.statusTimer = hostTimerSet(c.opts.StatusEvery.Milliseconds(), true)
	c.postStatus()
}

func (c *Conns) config(cfg map[string]json.RawMessage) {
	c.reconcile(cfg)
	c.postStatus()
}

// timer answers true when the timer was the library's.
func (c *Conns) timer(id int64) bool {
	if id == c.statusTimer {
		c.postStatus()
		return true
	}
	for _, r := range c.rows {
		if r.retryTimer != id {
			continue
		}
		r.retryTimer = -1
		c.open(r)
		return true
	}
	return false
}

// event answers true when the event belonged to one of these connections.
func (c *Conns) event(e Event) bool {
	switch e.Kind {
	case TCPConnected:
		r := c.bySocket(e.Handle, false)
		if r == nil {
			return false
		}
		c.opened(r)
	case WSOpen:
		r := c.bySocket(e.Handle, true)
		if r == nil {
			return false
		}
		c.opened(r)
	case TCPData:
		r := c.bySocket(e.Handle, false)
		if r == nil {
			return false
		}
		if h, ok := reg.plugin.(DataHandler); ok {
			h.OnData(r, e.Payload)
		}
	case WSData:
		r := c.bySocket(e.Handle, true)
		if r == nil {
			return false
		}
		if h, ok := reg.plugin.(DataHandler); ok {
			h.OnData(r, e.Payload)
		}
	case TCPClosed:
		r := c.bySocket(e.Handle, false)
		if r == nil {
			return false
		}
		c.ended(r)
	case WSClosed:
		r := c.bySocket(e.Handle, true)
		if r == nil {
			return false
		}
		c.ended(r)
	default:
		return false
	}
	return true
}

func (c *Conns) shutdown() {
	for _, r := range c.rows {
		r.closeSocket()
		r.used = false
	}
	c.rows = nil
	if c.statusTimer >= 0 {
		hostTimerCancel(c.statusTimer)
	}
	c.statusTimer = -1
}

// ---- the connection itself ------------------------------------------------

func (c *Conns) bySocket(id int64, ws bool) *Row {
	for _, r := range c.rows {
		if r.sock == id && r.ws == ws {
			return r
		}
	}
	return nil
}

func (c *Conns) where(r *Row) Endpoint {
	if e, ok := reg.plugin.(Endpointer); ok {
		return e.Endpoint(r)
	}
	return TCPEndpoint(r.Host, r.Port)
}

// open asks for a connection. The result arrives later as an open or a close
// event, so only an outright refusal is visible here.
func (c *Conns) open(r *Row) {
	if !r.Enabled {
		r.conn = RowPaused
		return
	}
	if !r.usable() {
		r.conn = RowNoAddress
		return
	}
	switch e := c.where(r); e.kind {
	case "ws":
		r.ws = true
		r.sock = WSConnect(e.text)
	case "refused":
		r.conn = RowRefused
		r.detail = e.text
		return
	default:
		r.ws = false
		r.sock = hostTCPConnect(e.host, e.port)
	}
	if r.sock < 0 {
		r.sock = -1
		// The host would not make the call at all, and the only reason it does
		// that is the grant. Retrying is a refusal every two seconds for ever,
		// so the row stops and says what is wrong.
		if r.ws {
			r.conn = RowRefused
			r.detail = c.opts.RefusedDetail
			return
		}
		r.noteFailure(c.opts.UnreachableAfter, c.opts.NoAnswerDetail)
		r.scheduleRetry(c.opts.Reconnect.Milliseconds())
	}
}

func (c *Conns) opened(r *Row) {
	r.conn = RowConnected
	r.failures = 0
	r.lastCounted = r.counted
	r.rate = 0
	r.detail = ""
	if h, ok := reg.plugin.(Opener); ok {
		h.OnOpen(r)
	}
	c.postStatus()
}

func (c *Conns) ended(r *Row) {
	r.sock = -1
	if h, ok := reg.plugin.(Closer); ok {
		h.OnClose(r)
	}
	// The close of a row the mariner just switched off is not a failure, and
	// must not read as one.
	if r.Enabled && r.usable() {
		r.noteFailure(c.opts.UnreachableAfter, c.opts.NoAnswerDetail)
		r.scheduleRetry(c.opts.Reconnect.Milliseconds())
	}
	c.postStatus()
}

// rowConfig is the four standard columns as the shell writes them.
type rowConfig struct {
	ID      string   `json:"id"`
	Name    string   `json:"name"`
	Host    string   `json:"host"`
	Port    *float64 `json:"port"`
	Enabled *bool    `json:"enabled"`
}

// reconcile takes the mariner's list and makes the streams match it.
func (c *Conns) reconcile(cfg map[string]json.RawMessage) {
	for _, r := range c.rows {
		r.seen = false
	}

	var items []json.RawMessage
	if raw, ok := cfg[c.opts.Key]; ok {
		_ = json.Unmarshal(raw, &items)
	}

	for order, item := range items {
		var in rowConfig
		if json.Unmarshal(item, &in) != nil || in.ID == "" {
			continue
		}
		r := c.ByID(in.ID)
		fresh := r == nil
		if fresh {
			r = &Row{ID: in.ID, sock: -1, retryTimer: -1, conn: RowReconnecting}
			c.rows = append(c.rows, r)
		}
		wasEnabled := !fresh && r.Enabled
		oldHost, oldPort := r.Host, r.Port

		r.used = true
		r.seen = true
		r.order = order
		r.Name = in.Name
		r.Host = in.Host
		port := c.columns.Port.Default
		if in.Port != nil {
			port = *in.Port
		}
		if port >= 1 && port <= 65535 {
			r.Port = uint16(port)
		} else {
			r.Port = 0
		}
		r.Enabled = in.Enabled == nil || *in.Enabled

		// The columns land in a fresh row struct, which is also where the
		// plugin's per-row state lives. A column that changed adopts the new
		// struct and so resets the state; an unchanged one keeps the old.
		state, cols := c.readRow(item)
		moved := fresh || oldHost != r.Host || oldPort != r.Port || !sameColumns(r, cols)
		if moved || !wasEnabled {
			r.State = state
		}

		switch {
		case !r.Enabled:
			r.closeSocket()
			r.conn = RowPaused
			r.failures = 0
		case !r.usable():
			r.closeSocket()
			r.conn = RowNoAddress
		case moved || !wasEnabled:
			// A new address, or a row just switched back on: start over,
			// including the count behind "unreachable".
			r.closeSocket()
			r.failures = 0
			r.conn = RowReconnecting
			c.open(r)
		case r.sock < 0 && r.retryTimer < 0:
			c.open(r)
		}
	}

	// A row the mariner deleted takes its stream with it.
	kept := c.rows[:0]
	for _, r := range c.rows {
		if r.seen {
			kept = append(kept, r)
			continue
		}
		r.closeSocket()
	}
	c.rows = kept
	// In the mariner's order, not the order the rows were added, so the status
	// items come back in the order the settings window shows.
	slices.SortStableFunc(c.rows, func(a, b *Row) int { return a.order - b.order })
}

// readRow makes one row's struct and fills its columns in from the config.
func (c *Conns) readRow(item json.RawMessage) (any, []any) {
	if c.opts.Row == nil {
		return nil, nil
	}
	state := c.opts.Row()
	v := reflect.ValueOf(state)
	for v.Kind() == reflect.Pointer && !v.IsNil() {
		v = v.Elem()
	}
	if v.Kind() != reflect.Struct || !v.CanSet() {
		return state, nil
	}
	var obj map[string]json.RawMessage
	_ = json.Unmarshal(item, &obj)

	var values []any
	t := v.Type()
	for i := 0; i < t.NumField(); i++ {
		f, ok, err := fieldOf(t.Field(i), i)
		if err != nil || !ok {
			continue
		}
		f.setDefault(v.Field(i))
		if raw, there := obj[f.key]; there {
			f.set(v.Field(i), raw)
		}
		values = append(values, v.Field(i).Interface())
	}
	return state, values
}

// sameColumns is true when the row's live columns are the ones just read. A
// column of the plugin's own may pick the transport, so a change to one is a
// change of address.
func sameColumns(r *Row, cols []any) bool {
	if r.State == nil {
		return len(cols) == 0
	}
	v := reflect.ValueOf(r.State)
	for v.Kind() == reflect.Pointer && !v.IsNil() {
		v = v.Elem()
	}
	if v.Kind() != reflect.Struct {
		return len(cols) == 0
	}
	i := 0
	t := v.Type()
	for k := 0; k < t.NumField(); k++ {
		_, ok, err := fieldOf(t.Field(k), k)
		if err != nil || !ok {
			continue
		}
		if i >= len(cols) || v.Field(k).Interface() != cols[i] {
			return false
		}
		i++
	}
	return i == len(cols)
}

// ---- the status line -------------------------------------------------------

// postStatus writes the plugin's line and one item per row for the settings
// window. The item ids are the row ids the shell assigned, which is how each
// row's line finds its way back to the right row.
func (c *Conns) postStatus() {
	live, total := 0, uint64(0)
	for _, r := range c.rows {
		c.sampleRate(r)
		if r.Connected() {
			live++
			total += r.rate
		}
	}
	state := "degraded"
	if live > 0 {
		state = "running"
	}

	var detail string
	switch {
	case len(c.rows) == 0:
		detail = c.opts.StatusEmpty
	case live > 0:
		detail = fmt.Sprintf("%d of %d connected, %d %s/s", live, len(c.rows), total, c.opts.RateNoun)
	default:
		detail = fmt.Sprintf("0 of %d connected", len(c.rows))
	}

	b := append(make([]byte, 0, 512), `{"state":`...)
	b = appendString(b, state)
	b = append(b, `,"detail":`...)
	b = appendString(b, detail)
	b = append(b, `,"items":[`...)
	for i, r := range c.rows {
		if i > 0 {
			b = append(b, ',')
		}
		b = append(b, `{"id":`...)
		b = appendString(b, r.ID)
		b = append(b, `,"state":`...)
		b = appendString(b, string(r.conn))
		b = append(b, `,"detail":`...)
		line := r.detail
		if r.Connected() {
			line = fmt.Sprintf("%d %s/s", r.rate, c.opts.RateNoun)
			if n, ok := reg.plugin.(Noter); ok {
				if note := n.RowNote(r); note != "" {
					line += ", " + note
				}
			}
		}
		b = appendString(b, line)
		b = append(b, '}')
	}
	b = append(b, `]}`...)

	// The host logs a status text it has not seen, so a 2 s repeat of the same
	// line would be a log line every 2 s.
	if string(b) == c.lastStatus {
		return
	}
	c.lastStatus = string(b)
	StatusJSON(b)
}

func (c *Conns) sampleRate(r *Row) {
	diff := r.counted - r.lastCounted
	r.lastCounted = r.counted
	if !r.Connected() {
		r.rate = 0
		return
	}
	ms := uint64(c.opts.StatusEvery.Milliseconds())
	r.rate = (diff*1000 + ms/2) / ms
}
