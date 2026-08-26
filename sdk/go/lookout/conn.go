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
//		State:    func() any { return &server{} },
//	})
//
//	func (p *plugin) OnData(conn *lk.Conn, data []byte) { … }
//
// and the library owns everything else: the settings list schema, one socket per
// connection, the reconnect clock, the failure count behind "unreachable", the
// pause switch, the per-row status item and the plugin's own status line.
//
// CONNECTIONS ARE MATCHED BY ID. Editing one connection never disturbs another:
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
	// Key is the config key the connection array arrives under.
	Key string
	// Group is the section heading in the settings window.
	Group string
	Tab   Tab
	// Footer, Empty and AddLabel are the list's own wording in the settings
	// window.
	Footer   string
	Empty    string
	AddLabel string
	// Discover is what a shell browses the boat's network for on this list's
	// behalf, so a source already running is offered ready to add.
	Discover []Discover
	// Columns words the four standard columns and sets the port's range. A zero
	// column keeps the library's wording.
	Columns RowColumns
	// State makes one connection's struct: the plugin's extra columns, which
	// are its exported fields with an lk tag, and its own per-connection
	// state, which is everything else. The library fills the columns in and
	// leaves the state alone.
	State func() any

	// Reconnect is the delay before a dropped connection is retried. Default 2 s.
	Reconnect time.Duration
	// UnreachableAfter is failed connects in a row before a connection reads
	// as unreachable rather than reconnecting. Default 3, which is six seconds
	// of silence.
	UnreachableAfter uint32
	// StatusEvery is how often the status is rebuilt, and the window a rate is
	// averaged over. Default 2 s.
	StatusEvery time.Duration
	// RateNoun is what Conn.Count counts, for the status: "42 msg/s".
	RateNoun string
	// StatusEmpty is the plugin's status detail when the mariner has added no
	// connections.
	StatusEmpty string
	// NoAnswerDetail is what a connection says once it has read as unreachable.
	NoAnswerDetail string
	// RefusedDetail is what a connection says when the host would not dial it at all.
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
	// RowNoAddress is a connection with no address, or a port nothing can dial.
	RowNoAddress RowState = "no_address"
	// RowRefused is an endpoint the host would not dial: a grant that does not
	// cover it.
	RowRefused RowState = "refused"
)

// Endpoint is where one connection is dialled. Build one with [TCPEndpoint],
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

// RefusedEndpoint says this connection cannot be dialled, and why. The library
// stops retrying and shows the reason on the connection's line.
func RefusedEndpoint(why string) Endpoint { return Endpoint{kind: "refused", text: why} }

// Conn is one connection: the row the mariner filled in, the plugin's own
// state for it, and the socket the library holds.
type Conn struct {
	// ID is the shell's id for this row. It survives an edit, and it is what a
	// status item points at.
	ID string
	// Name is what the mariner calls it. It may be empty.
	Name string
	Host string
	Port uint16
	// Enabled false means PAUSED: the stream closes and nothing reconnects.
	Enabled bool
	// State is what ConnOpts.State returned: the plugin's columns and its own
	// per-connection state. Assert it to your own type.
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

// Label is what to call this connection: the mariner's name, or the address.
func (conn *Conn) Label() string {
	if conn.Name != "" {
		return conn.Name
	}
	return conn.Host
}

// Connected is true while the stream is up.
func (conn *Conn) Connected() bool { return conn.conn == RowConnected }

// Rate is what Count counted over the last status window, per second.
func (conn *Conn) Rate() uint64 { return conn.rate }

// Send writes to this connection's stream and returns the bytes queued, or -1.
func (conn *Conn) Send(data []byte) int32 {
	if conn.sock < 0 {
		return -1
	}
	if conn.ws {
		return hostWSSend(conn.sock, data)
	}
	return hostTCPSend(conn.sock, data)
}

// Count counts n of whatever this connection carries. The library turns it
// into the rate on the connection's status line and in the plugin's.
func (conn *Conn) Count(n uint64) { conn.counted += n }

// SetDetail adds a phrase to this connection's status line, after the state. Say
// nothing that only repeats the state.
func (conn *Conn) SetDetail(format string, a ...any) {
	if len(a) == 0 {
		conn.detail = format
		return
	}
	conn.detail = fmt.Sprintf(format, a...)
}

// A connection with no address cannot be dialled.
func (conn *Conn) usable() bool { return conn.Host != "" && conn.Port > 0 }

func (conn *Conn) closeSocket() {
	if conn.sock >= 0 {
		if conn.ws {
			hostWSClose(conn.sock)
		} else {
			hostTCPClose(conn.sock)
		}
	}
	conn.sock = -1
	if conn.retryTimer >= 0 {
		hostTimerCancel(conn.retryTimer)
	}
	conn.retryTimer = -1
	conn.rate = 0
}

func (conn *Conn) scheduleRetry(delayMs int64) {
	if conn.retryTimer >= 0 || !conn.Enabled || !conn.usable() {
		return
	}
	if id := hostTimerSet(delayMs, false); id >= 0 {
		conn.retryTimer = id
	}
}

func (conn *Conn) noteFailure(limit uint32, detail string) {
	if conn.failures < limit {
		conn.failures++
	}
	if conn.failures >= limit {
		conn.conn = RowNoAnswer
		conn.detail = detail
	} else {
		conn.conn = RowReconnecting
		conn.detail = ""
	}
}

// Conns is a list of connections. Declare it as a package-level variable with
// [Connections]; the library finds it at start.
type Conns struct {
	opts    ConnOpts
	columns RowColumns
	conns   []*Conn

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

// All is every connection the mariner has, in the order the settings window
// shows.
func (c *Conns) All() []*Conn { return c.conns }

// ByID is the connection with this id, or nil.
func (c *Conns) ByID(id string) *Conn {
	for _, conn := range c.conns {
		if conn.ID == id {
			return conn
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
		discover:  c.opts.Discover,
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

// extraColumns reads the plugin's own columns off the state struct: its
// exported fields with an lk tag. Everything else on that struct is the
// plugin's state.
func (c *Conns) extraColumns() ([]specField, error) {
	if c.opts.State == nil {
		return nil, nil
	}
	v := reflect.ValueOf(c.opts.State())
	for v.Kind() == reflect.Pointer {
		if v.IsNil() {
			return nil, fmt.Errorf("connections %q: State returned a nil pointer", c.opts.Key)
		}
		v = v.Elem()
	}
	if v.Kind() != reflect.Struct {
		return nil, fmt.Errorf("connections %q: State must return a pointer to a struct", c.opts.Key)
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
	for _, conn := range c.conns {
		if conn.retryTimer != id {
			continue
		}
		conn.retryTimer = -1
		c.open(conn)
		return true
	}
	return false
}

// event answers true when the event belonged to one of these connections.
func (c *Conns) event(e Event) bool {
	switch e.Kind {
	case TCPConnected:
		conn := c.bySocket(e.Handle, false)
		if conn == nil {
			return false
		}
		c.opened(conn)
	case WSOpen:
		conn := c.bySocket(e.Handle, true)
		if conn == nil {
			return false
		}
		c.opened(conn)
	case TCPData:
		conn := c.bySocket(e.Handle, false)
		if conn == nil {
			return false
		}
		if h, ok := reg.plugin.(DataHandler); ok {
			h.OnData(conn, e.Payload)
		}
	case WSData:
		conn := c.bySocket(e.Handle, true)
		if conn == nil {
			return false
		}
		if h, ok := reg.plugin.(DataHandler); ok {
			h.OnData(conn, e.Payload)
		}
	case TCPClosed:
		conn := c.bySocket(e.Handle, false)
		if conn == nil {
			return false
		}
		c.ended(conn)
	case WSClosed:
		conn := c.bySocket(e.Handle, true)
		if conn == nil {
			return false
		}
		c.ended(conn)
	default:
		return false
	}
	return true
}

func (c *Conns) shutdown() {
	for _, conn := range c.conns {
		conn.closeSocket()
		conn.used = false
	}
	c.conns = nil
	if c.statusTimer >= 0 {
		hostTimerCancel(c.statusTimer)
	}
	c.statusTimer = -1
}

// ---- the connection itself ------------------------------------------------

func (c *Conns) bySocket(id int64, ws bool) *Conn {
	for _, conn := range c.conns {
		if conn.sock == id && conn.ws == ws {
			return conn
		}
	}
	return nil
}

func (c *Conns) where(conn *Conn) Endpoint {
	if e, ok := reg.plugin.(Endpointer); ok {
		return e.Endpoint(conn)
	}
	return TCPEndpoint(conn.Host, conn.Port)
}

// open asks for a connection. The result arrives later as an open or a close
// event, so only an outright refusal is visible here.
func (c *Conns) open(conn *Conn) {
	if !conn.Enabled {
		conn.conn = RowPaused
		return
	}
	if !conn.usable() {
		conn.conn = RowNoAddress
		return
	}
	switch e := c.where(conn); e.kind {
	case "ws":
		conn.ws = true
		conn.sock = WSConnect(e.text)
	case "refused":
		conn.conn = RowRefused
		conn.detail = e.text
		return
	default:
		conn.ws = false
		conn.sock = hostTCPConnect(e.host, e.port)
	}
	if conn.sock < 0 {
		conn.sock = -1
		// The host would not make the call at all, and the only reason it does
		// that is the grant. Retrying is a refusal every two seconds for ever,
		// so the connection stops and says what is wrong.
		if conn.ws {
			conn.conn = RowRefused
			conn.detail = c.opts.RefusedDetail
			return
		}
		conn.noteFailure(c.opts.UnreachableAfter, c.opts.NoAnswerDetail)
		conn.scheduleRetry(c.opts.Reconnect.Milliseconds())
	}
}

func (c *Conns) opened(conn *Conn) {
	conn.conn = RowConnected
	conn.failures = 0
	conn.lastCounted = conn.counted
	conn.rate = 0
	conn.detail = ""
	if h, ok := reg.plugin.(Opener); ok {
		h.OnOpen(conn)
	}
	c.postStatus()
}

func (c *Conns) ended(conn *Conn) {
	conn.sock = -1
	if h, ok := reg.plugin.(Closer); ok {
		h.OnClose(conn)
	}
	// The close of a connection the mariner just switched off is not a
	// failure, and must not read as one.
	if conn.Enabled && conn.usable() {
		conn.noteFailure(c.opts.UnreachableAfter, c.opts.NoAnswerDetail)
		conn.scheduleRetry(c.opts.Reconnect.Milliseconds())
	}
	c.postStatus()
}

// connConfig is the four standard columns as the shell writes them.
type connConfig struct {
	ID      string   `json:"id"`
	Name    string   `json:"name"`
	Host    string   `json:"host"`
	Port    *float64 `json:"port"`
	Enabled *bool    `json:"enabled"`
}

// reconcile takes the mariner's list and makes the streams match it.
func (c *Conns) reconcile(cfg map[string]json.RawMessage) {
	for _, conn := range c.conns {
		conn.seen = false
	}

	var items []json.RawMessage
	if raw, ok := cfg[c.opts.Key]; ok {
		_ = json.Unmarshal(raw, &items)
	}

	for order, item := range items {
		var in connConfig
		if json.Unmarshal(item, &in) != nil || in.ID == "" {
			continue
		}
		conn := c.ByID(in.ID)
		fresh := conn == nil
		if fresh {
			conn = &Conn{ID: in.ID, sock: -1, retryTimer: -1, conn: RowReconnecting}
			c.conns = append(c.conns, conn)
		}
		wasEnabled := !fresh && conn.Enabled
		oldHost, oldPort := conn.Host, conn.Port

		conn.used = true
		conn.seen = true
		conn.order = order
		conn.Name = in.Name
		conn.Host = in.Host
		port := c.columns.Port.Default
		if in.Port != nil {
			port = *in.Port
		}
		if port >= 1 && port <= 65535 {
			conn.Port = uint16(port)
		} else {
			conn.Port = 0
		}
		conn.Enabled = in.Enabled == nil || *in.Enabled

		// The columns land in a fresh state struct, which is also where the
		// plugin's per-connection state lives. A column that changed adopts
		// the new struct and so resets the state; an unchanged one keeps the
		// old.
		state, cols := c.readConn(item)
		moved := fresh || oldHost != conn.Host || oldPort != conn.Port || !sameColumns(conn, cols)
		if moved || !wasEnabled {
			conn.State = state
		}

		switch {
		case !conn.Enabled:
			conn.closeSocket()
			conn.conn = RowPaused
			conn.failures = 0
		case !conn.usable():
			conn.closeSocket()
			conn.conn = RowNoAddress
		case moved || !wasEnabled:
			// A new address, or a connection just switched back on: start
			// over, including the count behind "unreachable".
			conn.closeSocket()
			conn.failures = 0
			conn.conn = RowReconnecting
			c.open(conn)
		case conn.sock < 0 && conn.retryTimer < 0:
			c.open(conn)
		}
	}

	// A connection the mariner deleted takes its stream with it.
	kept := c.conns[:0]
	for _, conn := range c.conns {
		if conn.seen {
			kept = append(kept, conn)
			continue
		}
		conn.closeSocket()
	}
	c.conns = kept
	// In the mariner's order, not the order the connections were added, so the
	// status items come back in the order the settings window shows.
	slices.SortStableFunc(c.conns, func(a, b *Conn) int { return a.order - b.order })
}

// readConn makes one connection's state struct and fills its columns in from
// the config.
func (c *Conns) readConn(item json.RawMessage) (any, []any) {
	if c.opts.State == nil {
		return nil, nil
	}
	state := c.opts.State()
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

// sameColumns is true when the connection's live columns are the ones just read. A
// column of the plugin's own may pick the transport, so a change to one is a
// change of address.
func sameColumns(conn *Conn, cols []any) bool {
	if conn.State == nil {
		return len(cols) == 0
	}
	v := reflect.ValueOf(conn.State)
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
	for _, conn := range c.conns {
		c.sampleRate(conn)
		if conn.Connected() {
			live++
			total += conn.rate
		}
	}
	state := "degraded"
	if live > 0 {
		state = "running"
	}

	var detail string
	switch {
	case len(c.conns) == 0:
		detail = c.opts.StatusEmpty
	case live > 0:
		detail = fmt.Sprintf("%d of %d connected, %d %s/s", live, len(c.conns), total, c.opts.RateNoun)
	default:
		detail = fmt.Sprintf("0 of %d connected", len(c.conns))
	}

	b := append(make([]byte, 0, 512), `{"state":`...)
	b = appendString(b, state)
	b = append(b, `,"detail":`...)
	b = appendString(b, detail)
	b = append(b, `,"items":[`...)
	for i, conn := range c.conns {
		if i > 0 {
			b = append(b, ',')
		}
		b = append(b, `{"id":`...)
		b = appendString(b, conn.ID)
		b = append(b, `,"state":`...)
		b = appendString(b, string(conn.conn))
		b = append(b, `,"detail":`...)
		line := conn.detail
		if conn.Connected() {
			line = fmt.Sprintf("%d %s/s", conn.rate, c.opts.RateNoun)
			if n, ok := reg.plugin.(Noter); ok {
				if note := n.ConnNote(conn); note != "" {
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

func (c *Conns) sampleRate(conn *Conn) {
	diff := conn.counted - conn.lastCounted
	conn.lastCounted = conn.counted
	if !conn.Connected() {
		conn.rate = 0
		return
	}
	ms := uint64(c.opts.StatusEvery.Milliseconds())
	conn.rate = (diff*1000 + ms/2) / ms
}
