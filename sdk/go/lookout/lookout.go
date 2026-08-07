// Package lookout is the plugin side of the Lookout ABI, in Go.
//
// # This public surface is PROVISIONAL
//
// The plugin-facing API is being simplified — declarative inputs with their own
// freshness, a draw callback over a retained scene, typed settings, managed
// connections — and this package will be rewritten to that shape. What is below
// mirrors today's plugins/common/lk.zig and will not survive as it stands.
//
// What IS settled, and what this package is worth reading for, is everything
// between the language and the ABI: the //go:wasmimport and //go:wasmexport
// bindings, the lk_alloc and lk_free buffer bookkeeping, the reactor rules, and
// the fact that all of it works on the host's WASI floor. That plumbing carries
// over unchanged.
//
// Import it, write two methods, register your plugin, and you have a plugin.
//
//	package main
//
//	import lk "github.com/beetlebugorg/lookout-marine/sdk/go/lookout"
//
//	type plugin struct{}
//
//	func init() { lk.Register(&plugin{}) }
//	func main() {}
//
//	func (p *plugin) Start(s lk.Start) error {
//	    lk.SubscribePaths("navigation.position")
//	    return nil
//	}
//
//	func (p *plugin) OnEvent(e lk.Event) error {
//	    switch e.Kind {
//	    case lk.StoreChanged:
//	        for _, r := range e.Readings() { _ = r }
//	    }
//	    return nil
//	}
//
// The package writes the five exports the ABI requires — lk_abi, lk_alloc,
// lk_free, lk_start, lk_event — and routes lk_start and lk_event to your two
// methods. An event kind it does not recognise is answered 0 without reaching
// you, which is what the ABI says must happen.
//
// # Register in init, not in main
//
// Build a plugin with -buildmode=c-shared and the module is a WASI reactor:
// the host calls _initialize, which runs package initialisation, and then
// calls the exports. YOUR func main NEVER RUNS. Package main still needs one
// to compile; leave it empty and do your setup in an init function, in Start,
// or in a package-level variable.
//
// # Single-threaded, and it is not a suggestion
//
// One plugin is one thread, and it runs only while the host is inside one of
// your exports. A goroutine you start makes no progress after you return,
// because nothing is scheduling it; time.Sleep does not sleep, it fails,
// because the host refuses the WASI call that would park the thread. So:
//
//   - Do the work in the handler and return.
//   - No background goroutines, no worker pools, no channels between events.
//   - To wake up later, ask for TimerSet and handle the Timer event.
//   - To read a socket, ask for TCPConnect and handle the TCPData event.
//
// The reason is time isolation, not taste. The host gives every call into your
// module a budget and kills the instance when it runs out, so that a plugin
// that stops answering delays nobody but itself.
//
// # What WASI gives you, which is almost nothing
//
// The Go runtime needs WASI to boot, so it is there: clocks, randomness, and
// stdout and stderr. Everything else is refused. There is no filesystem — os.Open
// fails on every path — no sockets, no environment variables, no arguments, and
// no threads. fmt.Println works and goes to your plugin's log, one line per call.
//
// # Size
//
// The Go runtime costs a few megabytes in the module, whatever the plugin does.
// That is the price of the standard library and its garbage collector. TinyGo
// (tinygo build -target=wasip1) emits tens of kilobytes from the same source,
// with the usual TinyGo standard library caveats.
package lookout

import (
	"encoding/json"
	"math"
	"strconv"
	"unsafe"
)

// ABIVersion is the ABI this library speaks. lk_abi returns it.
const ABIVersion uint32 = 1

// ---------------------------------------------------------------------------
// The host imports, exactly as the ABI freezes them
// ---------------------------------------------------------------------------

//go:wasmimport lookout log
func hostLog(level uint32, ptr unsafe.Pointer, n uint32)

//go:wasmimport lookout now_ms
func hostNowMs() int64

//go:wasmimport lookout mono_ms
func hostMonoMs() int64

//go:wasmimport lookout publish
func hostPublish(ptr unsafe.Pointer, n uint32) int32

//go:wasmimport lookout ais_upsert
func hostAISUpsert(ptr unsafe.Pointer, n uint32) int32

//go:wasmimport lookout overlay
func hostOverlay(ptr unsafe.Pointer, n uint32) int32

//go:wasmimport lookout chrome_status
func hostChromeStatus(ptr unsafe.Pointer, n uint32)

//go:wasmimport lookout alert
func hostAlert(ptr unsafe.Pointer, n uint32) int32

//go:wasmimport lookout tcp_connect
func hostTCPConnect(hostPtr unsafe.Pointer, hostLen uint32, port uint32) int64

//go:wasmimport lookout tcp_send
func hostTCPSend(id int64, ptr unsafe.Pointer, n uint32) int32

//go:wasmimport lookout tcp_close
func hostTCPClose(id int64)

//go:wasmimport lookout timer_set
func hostTimerSet(delayMs int64, periodic uint32) int64

//go:wasmimport lookout timer_cancel
func hostTimerCancel(id int64)

//go:wasmimport lookout subscribe
func hostSubscribe(ptr unsafe.Pointer, n uint32) int32

//go:wasmimport lookout ais_subscribe
func hostAISSubscribe() int32

// bytesOf is the (pointer, length) pair every import above takes. The slice
// must stay reachable until the call returns, which it does: it is an argument
// here and Go's collector does not move heap objects.
func bytesOf(b []byte) (unsafe.Pointer, uint32) {
	if len(b) == 0 {
		return unsafe.Pointer(&zeroByte), 0
	}
	return unsafe.Pointer(unsafe.SliceData(b)), uint32(len(b))
}

func stringOf(s string) (unsafe.Pointer, uint32) {
	if len(s) == 0 {
		return unsafe.Pointer(&zeroByte), 0
	}
	return unsafe.Pointer(unsafe.StringData(s)), uint32(len(s))
}

// A real address for an empty range. A wasm address of 0 is a valid offset the
// host would bounds-check, and passing the address of nothing is clearer than
// passing null.
var zeroByte byte

// ---------------------------------------------------------------------------
// Logging and clocks — no capability needed for either
// ---------------------------------------------------------------------------

// Level is how loud a log line is.
type Level uint32

const (
	Debug Level = 0
	Info  Level = 1
	Warn  Level = 2
	Error Level = 3
)

// Log writes one line. Nothing is added: no prefix, no newline. The host
// stamps the plugin id and the level.
func Log(level Level, msg string) {
	p, n := stringOf(msg)
	hostLog(uint32(level), p, n)
}

// NowMs is the wall clock, milliseconds since the epoch. Stamp published
// values with this.
func NowMs() int64 { return hostNowMs() }

// MonoMs is monotonic milliseconds. Measure intervals with this; it does not
// jump when the boat's clock is set from a fresh GPS fix.
func MonoMs() int64 { return hostMonoMs() }

// ---------------------------------------------------------------------------
// Talking to the host
// ---------------------------------------------------------------------------

// PublishJSON sends a {"updates":[...]} batch. It returns the number of
// updates the host accepted, or -1. Publish below writes the JSON for you.
func PublishJSON(b []byte) int32 { p, n := bytesOf(b); return hostPublish(p, n) }

// AISUpsertJSON sends a {"targets":[...]} batch. Speed over ground is METRES
// PER SECOND, not knots: everything crossing this ABI is SI.
func AISUpsertJSON(b []byte) int32 { p, n := bytesOf(b); return hostAISUpsert(p, n) }

// OverlayJSON posts an overlay batch, {"set":[...],"del":[...]}.
func OverlayJSON(b []byte) int32 { p, n := bytesOf(b); return hostOverlay(p, n) }

// StatusJSON posts one line of chrome, {"state":"running","detail":"42 msg/s"}.
// The host keeps the latest per plugin and logs transitions, so posting the
// same status repeatedly is free.
func StatusJSON(b []byte) { p, n := bytesOf(b); hostChromeStatus(p, n) }

// AlertJSON raises an alert. It needs the alerts.raise capability; without it
// this returns -1 and the host logs the refusal.
func AlertJSON(b []byte) int32 { p, n := bytesOf(b); return hostAlert(p, n) }

// TCPConnect opens a connection. It returns a connection id at once — the
// connect itself completes on the host's I/O thread and arrives as
// TCPConnected, or as TCPClosed if it failed. RECONNECTING IS YOURS: the host
// never retries.
func TCPConnect(host string, port uint16) int64 {
	p, n := stringOf(host)
	return hostTCPConnect(p, n, uint32(port))
}

func TCPSend(id int64, data []byte) int32 { p, n := bytesOf(data); return hostTCPSend(id, p, n) }

func TCPClose(id int64) { hostTCPClose(id) }

// TimerSet asks to be woken. A periodic timer repeats every delayMs; otherwise
// it fires once. It arrives as a Timer event carrying the id this returns.
//
// This is how a Go plugin waits. time.Sleep is not.
func TimerSet(delayMs int64, periodic bool) int64 {
	var p uint32
	if periodic {
		p = 1
	}
	return hostTimerSet(delayMs, p)
}

func TimerCancel(id int64) { hostTimerCancel(id) }

// SubscribePaths subscribes to vessel paths. One subscription per plugin:
// calling again REPLACES the path list. Changes arrive as StoreChanged.
func SubscribePaths(paths ...string) int32 {
	b := make([]byte, 0, 64)
	b = append(b, '[')
	for i, p := range paths {
		if i > 0 {
			b = append(b, ',')
		}
		b = appendJSONString(b, p)
	}
	b = append(b, ']')
	p, n := bytesOf(b)
	return hostSubscribe(p, n)
}

// AISSubscribe asks for the AIS target set. The whole snapshot arrives as an
// AISChanged event, at most twice a second and only when something moved.
func AISSubscribe() int32 { return hostAISSubscribe() }

// Status posts one line of chrome.
func Status(state, detail string) {
	b := make([]byte, 0, 96)
	b = append(b, `{"state":`...)
	b = appendJSONString(b, state)
	b = append(b, `,"detail":`...)
	b = appendJSONString(b, detail)
	b = append(b, '}')
	StatusJSON(b)
}

// Severity is how loud an alert is. The host maps these to log levels: Alarm
// at error, Warning at warn, Notice at info.
type Severity string

const (
	Alarm   Severity = "alarm"
	Warning Severity = "warning"
	Notice  Severity = "notice"
)

// Alert raises an alert. It needs alerts.raise; -1 means the grant is missing.
func Alert(sev Severity, title, body string) int32 {
	b := make([]byte, 0, 128)
	b = append(b, `{"severity":`...)
	b = appendJSONString(b, string(sev))
	b = append(b, `,"title":`...)
	b = appendJSONString(b, title)
	b = append(b, `,"body":`...)
	b = appendJSONString(b, body)
	b = append(b, '}')
	return AlertJSON(b)
}

// ---------------------------------------------------------------------------
// What the host sends
// ---------------------------------------------------------------------------

// Kind is the event kind. Switch on it in OnEvent.
type Kind uint32

const (
	ConfigChanged Kind = 1
	Timer         Kind = 3
	TCPConnected  Kind = 4
	TCPData       Kind = 5
	TCPClosed     Kind = 6
	StoreChanged  Kind = 10
	AISChanged    Kind = 11
	Shutdown      Kind = 99
)

// Event is everything that happens.
//
// Payload BELONGS TO THE HOST. It is valid for the length of your OnEvent call
// and freed after it. Copy anything you keep.
type Event struct {
	Kind Kind
	// Handle correlates: which timer, which connection. Zero for the events
	// that have nothing to correlate.
	Handle  int64
	Payload []byte
}

// Data is the bytes of a TCPData event.
func (e Event) Data() []byte { return e.Payload }

// Config unmarshals a ConfigChanged payload — your whole settings object, with
// every field the manifest's schema declares present, so you read what you
// want and never merge.
func (e Event) Config(v any) error { return json.Unmarshal(e.Payload, v) }

// Start is what your Start method receives.
type Start struct {
	ABI uint32 `json:"abi"`
	// Config is your settings object as the host sent it.
	Config json.RawMessage `json:"config"`
}

// Unmarshal reads the start config into a struct of your own.
func (s Start) Unmarshal(v any) error {
	if len(s.Config) == 0 {
		return nil
	}
	return json.Unmarshal(s.Config, v)
}

// String reads one string out of the start config, or returns fallback.
func (s Start) String(key, fallback string) string {
	var m map[string]json.RawMessage
	if json.Unmarshal(s.Config, &m) != nil {
		return fallback
	}
	var out string
	if raw, ok := m[key]; !ok || json.Unmarshal(raw, &out) != nil {
		return fallback
	}
	return out
}

// Int reads one integer out of the start config, or returns fallback.
func (s Start) Int(key string, fallback int64) int64 {
	var m map[string]json.RawMessage
	if json.Unmarshal(s.Config, &m) != nil {
		return fallback
	}
	var out float64
	if raw, ok := m[key]; !ok || json.Unmarshal(raw, &out) != nil {
		return fallback
	}
	return int64(out)
}

// Reading is one entry of a StoreChanged payload.
type Reading struct {
	Path string `json:"path"`
	// Value is null when the path has NO value any more — the source was
	// cleared — not when a source published a null. Removed reports it.
	Value json.RawMessage `json:"value"`
	TsMs  int64           `json:"ts"`
	AgeMs int64           `json:"age_ms"`
}

// Removed is true when the path has no value at all any more. Treat it as
// removal: stop drawing whatever the value fed.
func (r Reading) Removed() bool { return len(r.Value) == 0 || string(r.Value) == "null" }

// Number reads the value as a number.
func (r Reading) Number() (float64, bool) {
	var v float64
	if r.Removed() || json.Unmarshal(r.Value, &v) != nil {
		return 0, false
	}
	return v, true
}

// Position reads the value as a fix.
func (r Reading) Position() (lat, lon float64, ok bool) {
	var v struct {
		Lat *float64 `json:"lat"`
		Lon *float64 `json:"lon"`
	}
	if r.Removed() || json.Unmarshal(r.Value, &v) != nil || v.Lat == nil || v.Lon == nil {
		return 0, 0, false
	}
	return *v.Lat, *v.Lon, true
}

// Readings parses a StoreChanged payload. It returns nothing for any other
// event, and nothing for a payload that will not parse.
func (e Event) Readings() []Reading {
	var doc struct {
		Values []Reading `json:"values"`
	}
	if json.Unmarshal(e.Payload, &doc) != nil {
		return nil
	}
	return doc.Values
}

// Target is one AIS target from an AISChanged payload. An absent field is nil:
// "never heard" and "heard as zero" are different things at sea.
type Target struct {
	MMSI uint32   `json:"mmsi"`
	Lat  *float64 `json:"lat"`
	Lon  *float64 `json:"lon"`
	// SOG is metres per second.
	SOG         *float64 `json:"sog"`
	COG         *float64 `json:"cog"`
	Heading     *float64 `json:"heading"`
	Name        string   `json:"name"`
	ATON        bool     `json:"aton"`
	ATONType    *uint8   `json:"aton_type"`
	VirtualATON bool     `json:"virtual"`
	OffPosition *bool    `json:"off_position"`
	TsMs        int64    `json:"ts"`
	AgeMs       int64    `json:"age_ms"`
}

// HasPosition is true when the target has been heard with a fix.
func (t Target) HasPosition() bool { return t.Lat != nil && t.Lon != nil }

// Targets parses an AISChanged payload: the whole target set, every time.
func (e Event) Targets() []Target {
	var doc struct {
		Targets []Target `json:"targets"`
	}
	if json.Unmarshal(e.Payload, &doc) != nil {
		return nil
	}
	return doc.Targets
}

// ---------------------------------------------------------------------------
// Writing what the host reads
// ---------------------------------------------------------------------------

func appendJSONString(b []byte, s string) []byte {
	b = append(b, '"')
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case c == '"':
			b = append(b, '\\', '"')
		case c == '\\':
			b = append(b, '\\', '\\')
		case c == '\n':
			b = append(b, '\\', 'n')
		case c == '\r':
			b = append(b, '\\', 'r')
		case c == '\t':
			b = append(b, '\\', 't')
		case c < 0x20:
			const hex = "0123456789abcdef"
			b = append(b, '\\', 'u', '0', '0', hex[c>>4], hex[c&0xf])
		default:
			b = append(b, c)
		}
	}
	return append(b, '"')
}

// A finite number, or null. An infinity or a NaN in a payload is a bug the
// host would reject, so it never leaves here.
func appendNum(b []byte, v float64) []byte {
	if math.IsNaN(v) || math.IsInf(v, 0) {
		return append(b, "null"...)
	}
	return strconv.AppendFloat(b, v, 'g', -1, 64)
}

// Publish builds {"updates":[...]} and sends it.
//
//	p := lk.NewPublish()
//	p.Position("navigation.position", lat, lon, ts)
//	p.Number("navigation.speedOverGround", sogMPS, ts)
//	p.Send()
type Publish struct {
	b []byte
	n int
}

func NewPublish() *Publish {
	return &Publish{b: append(make([]byte, 0, 256), `{"updates":[`...)}
}

func (p *Publish) open(path string) {
	if p.n > 0 {
		p.b = append(p.b, ',')
	}
	p.n++
	p.b = append(p.b, `{"path":`...)
	p.b = appendJSONString(p.b, path)
	p.b = append(p.b, `,"value":`...)
}

func (p *Publish) Number(path string, v float64, tsMs int64) {
	p.open(path)
	p.b = appendNum(p.b, v)
	p.b = append(p.b, `,"ts":`...)
	p.b = strconv.AppendInt(p.b, tsMs, 10)
	p.b = append(p.b, '}')
}

func (p *Publish) Position(path string, lat, lon float64, tsMs int64) {
	p.open(path)
	p.b = append(p.b, `{"lat":`...)
	p.b = appendNum(p.b, lat)
	p.b = append(p.b, `,"lon":`...)
	p.b = appendNum(p.b, lon)
	p.b = append(p.b, `},"ts":`...)
	p.b = strconv.AppendInt(p.b, tsMs, 10)
	p.b = append(p.b, '}')
}

// Clear publishes a null: this source has the path but no value for it now.
func (p *Publish) Clear(path string, tsMs int64) {
	p.open(path)
	p.b = append(p.b, `null,"ts":`...)
	p.b = strconv.AppendInt(p.b, tsMs, 10)
	p.b = append(p.b, '}')
}

// Send posts the batch. Nothing to say is not an error: an empty batch is
// simply not sent.
func (p *Publish) Send() int32 {
	if p.n == 0 {
		return 0
	}
	return PublishJSON(append(p.b, ']', '}'))
}

// Color is a palette token. A plugin names a token; the core resolves it per
// day, dusk and night scheme, which is why an overlay never holds an RGB.
type Color string

const (
	ColorOwnship      Color = "ownship"
	ColorTarget       Color = "target"
	ColorTargetDanger Color = "target_danger"
	ColorTrack        Color = "track"
	ColorLaylinePort  Color = "layline_port"
	ColorLaylineStbd  Color = "layline_stbd"
	ColorWarning      Color = "warning"
)

// Sym is a symbol shape the core draws. ATON is a physical aid to navigation
// and ATONVirtual one that exists only as a broadcast.
type Sym string

const (
	SymOwnship     Sym = "ownship"
	SymTarget      Sym = "target"
	SymATON        Sym = "aton"
	SymATONVirtual Sym = "aton_virtual"
)

// Overlay builds {"set":[...],"del":[...]}.
//
// DELETES FIRST. Call Del before any Symbol, Polyline or Polygon; a delete
// after a shape is dropped with a log line. The host applies deletes before
// sets whatever the order in the JSON, so this only makes the builder match
// the semantics.
type Overlay struct {
	b     []byte
	dels  int
	sets  int
	inSet bool
}

func NewOverlay() *Overlay {
	return &Overlay{b: append(make([]byte, 0, 512), `{"del":[`...)}
}

func (o *Overlay) Del(id string) {
	if o.inSet {
		Log(Warn, "overlay: del(\""+id+"\") after a set is ignored")
		return
	}
	if o.dels > 0 {
		o.b = append(o.b, ',')
	}
	o.dels++
	o.b = appendJSONString(o.b, id)
}

func (o *Overlay) beginSet() {
	if !o.inSet {
		o.b = append(o.b, `],"set":[`...)
		o.inSet = true
	} else {
		o.b = append(o.b, ',')
	}
	o.sets++
}

func (o *Overlay) symbolOpen(id string, sym Sym, lon, lat, rotDeg float64, color Color, scale float64) {
	o.beginSet()
	o.b = append(o.b, `{"id":`...)
	o.b = appendJSONString(o.b, id)
	o.b = append(o.b, `,"kind":"symbol","sym":`...)
	o.b = appendJSONString(o.b, string(sym))
	o.b = append(o.b, `,"at":[`...)
	o.b = appendNum(o.b, lon)
	o.b = append(o.b, ',')
	o.b = appendNum(o.b, lat)
	o.b = append(o.b, `],"rot_deg":`...)
	o.b = appendNum(o.b, rotDeg)
	o.b = append(o.b, `,"scale":`...)
	o.b = appendNum(o.b, scale)
	o.b = append(o.b, `,"color":`...)
	o.b = appendJSONString(o.b, string(color))
}

// Symbol places a symbol at lon/lat, rotated to a TRUE bearing (clockwise from
// north).
func (o *Overlay) Symbol(id string, sym Sym, lon, lat, rotDeg float64, color Color, scale float64) {
	o.symbolOpen(id, sym, lon, lat, rotDeg, color, scale)
	o.b = append(o.b, '}')
}

// ShipSymbol places a symbol that rides own ship's DISPLAY position: the core
// carries the newest fix forward and substitutes it every frame, so the boat
// sits still on screen instead of stepping once a second.
func (o *Overlay) ShipSymbol(id string, sym Sym, lon, lat, rotDeg float64, color Color, scale float64) {
	o.symbolOpen(id, sym, lon, lat, rotDeg, color, scale)
	o.b = append(o.b, `,"anchor":"ownship"}`...)
}

// SymbolPick is a symbol plus a pick payload: a title and rows the shell shows
// on hover or on a tap. Values are strings, not numbers — the payload is what
// the mariner reads, and only the plugin knows the unit.
func (o *Overlay) SymbolPick(id string, sym Sym, lon, lat, rotDeg float64, color Color, scale float64, title string, rows [][2]string) {
	o.symbolOpen(id, sym, lon, lat, rotDeg, color, scale)
	o.b = append(o.b, `,"pick":{"title":`...)
	o.b = appendJSONString(o.b, title)
	o.b = append(o.b, `,"rows":[`...)
	for i, r := range rows {
		if i > 0 {
			o.b = append(o.b, ',')
		}
		o.b = append(o.b, '[')
		o.b = appendJSONString(o.b, r[0])
		o.b = append(o.b, ',')
		o.b = appendJSONString(o.b, r[1])
		o.b = append(o.b, ']')
	}
	o.b = append(o.b, `]}}`...)
}

// Polyline draws through pts, each {lon, lat}. widthPt is screen points, not
// metres — the core converts at the live zoom.
func (o *Overlay) Polyline(id string, pts [][2]float64, widthPt float64, color Color, dash bool) {
	o.polyline(id, pts, widthPt, color, dash, false)
}

// ShipPolyline is a line that travels with own ship's display position,
// keeping its shape and its first point on the boat — the heading line and the
// speed vector, which must not lag the hull between fixes.
func (o *Overlay) ShipPolyline(id string, pts [][2]float64, widthPt float64, color Color, dash bool) {
	o.polyline(id, pts, widthPt, color, dash, true)
}

func (o *Overlay) polyline(id string, pts [][2]float64, widthPt float64, color Color, dash, ship bool) {
	o.beginSet()
	o.b = append(o.b, `{"id":`...)
	o.b = appendJSONString(o.b, id)
	o.b = append(o.b, `,"kind":"polyline","pts":[`...)
	o.points(pts)
	o.b = append(o.b, `],"width_pt":`...)
	o.b = appendNum(o.b, widthPt)
	o.b = append(o.b, `,"dash":`...)
	if dash {
		o.b = append(o.b, "true"...)
	} else {
		o.b = append(o.b, "false"...)
	}
	o.b = append(o.b, `,"color":`...)
	o.b = appendJSONString(o.b, string(color))
	if ship {
		o.b = append(o.b, `,"anchor":"ownship"`...)
	}
	o.b = append(o.b, '}')
}

// Polygon is a filled ring. alpha multiplies the token's own alpha.
func (o *Overlay) Polygon(id string, ring [][2]float64, color Color, alpha float64) {
	o.beginSet()
	o.b = append(o.b, `{"id":`...)
	o.b = appendJSONString(o.b, id)
	o.b = append(o.b, `,"kind":"polygon","ring":[`...)
	o.points(ring)
	o.b = append(o.b, `],"alpha":`...)
	o.b = appendNum(o.b, alpha)
	o.b = append(o.b, `,"color":`...)
	o.b = appendJSONString(o.b, string(color))
	o.b = append(o.b, '}')
}

func (o *Overlay) points(pts [][2]float64) {
	for i, p := range pts {
		if i > 0 {
			o.b = append(o.b, ',')
		}
		o.b = append(o.b, '[')
		o.b = appendNum(o.b, p[0])
		o.b = append(o.b, ',')
		o.b = appendNum(o.b, p[1])
		o.b = append(o.b, ']')
	}
}

func (o *Overlay) Send() int32 {
	if o.dels == 0 && o.sets == 0 {
		return 0
	}
	if !o.inSet {
		o.b = append(o.b, `],"set":[`...)
	}
	return OverlayJSON(append(o.b, ']', '}'))
}

// AISUpsert builds {"targets":[...]} for ais_upsert. SOG is metres per second.
type AISUpsert struct {
	b []byte
	n int
}

func NewAISUpsert() *AISUpsert {
	return &AISUpsert{b: append(make([]byte, 0, 256), `{"targets":[`...)}
}

func (u *AISUpsert) Target(t Target) {
	if u.n > 0 {
		u.b = append(u.b, ',')
	}
	u.n++
	u.b = append(u.b, `{"mmsi":`...)
	u.b = strconv.AppendUint(u.b, uint64(t.MMSI), 10)
	u.field("lat", t.Lat)
	u.field("lon", t.Lon)
	u.field("sog", t.SOG)
	u.field("cog", t.COG)
	u.field("heading", t.Heading)
	if t.Name != "" {
		u.b = append(u.b, `,"name":`...)
		u.b = appendJSONString(u.b, t.Name)
	}
	if t.ATON {
		u.b = append(u.b, `,"aton":true`...)
		if t.ATONType != nil {
			u.b = append(u.b, `,"aton_type":`...)
			u.b = strconv.AppendUint(u.b, uint64(*t.ATONType), 10)
		}
		if t.VirtualATON {
			u.b = append(u.b, `,"virtual":true`...)
		}
		if t.OffPosition != nil {
			u.b = append(u.b, `,"off_position":`...)
			u.b = strconv.AppendBool(u.b, *t.OffPosition)
		}
	}
	u.b = append(u.b, `,"ts":`...)
	u.b = strconv.AppendInt(u.b, t.TsMs, 10)
	u.b = append(u.b, '}')
}

func (u *AISUpsert) field(name string, v *float64) {
	if v == nil {
		return
	}
	u.b = append(u.b, ',', '"')
	u.b = append(u.b, name...)
	u.b = append(u.b, '"', ':')
	u.b = appendNum(u.b, *v)
}

func (u *AISUpsert) Send() int32 {
	if u.n == 0 {
		return 0
	}
	return AISUpsertJSON(append(u.b, ']', '}'))
}

// ---------------------------------------------------------------------------
// The five exports
// ---------------------------------------------------------------------------

// Plugin is what you write. Both methods run on the one thread the host gives
// you, one call at a time.
type Plugin interface {
	// Start begins. Return an error and the host records the plugin as failed
	// to start, with the error text in the log.
	Start(s Start) error
	// OnEvent handles everything that happens. Ignore the kinds you do not
	// care about.
	OnEvent(e Event) error
}

var registered Plugin

// Register wires the five exports to p. Call it once, from an init function or
// a package-level variable — NOT from main, which a reactor module never runs.
func Register(p Plugin) { registered = p }

// Buffers the host owns while it hands us a payload. The key is the wasm
// address lk_alloc returned; the value keeps the slice reachable so the
// collector leaves it alone until lk_free. A plugin has one or two of these
// live at a time, never more.
var allocs = map[uint32][]byte{}

//go:wasmexport lk_abi
func lkABI() uint32 { return ABIVersion }

//go:wasmexport lk_alloc
func lkAlloc(n uint32) uint32 {
	if n == 0 {
		n = 1
	}
	b := make([]byte, n)
	addr := uint32(uintptr(unsafe.Pointer(unsafe.SliceData(b))))
	if addr == 0 {
		// The host reads 0 as "the plugin is out of memory", so an allocation
		// that landed on address zero has to be refused rather than reported.
		return 0
	}
	allocs[addr] = b
	return addr
}

//go:wasmexport lk_free
func lkFree(addr uint32, n uint32) {
	_ = n
	delete(allocs, addr)
}

// payload finds the host's bytes without turning an integer back into a
// pointer. The host always writes into a buffer lk_alloc handed it, so the
// address is either a key of allocs or inside one of its buffers.
func payload(addr, n uint32) []byte {
	if n == 0 {
		return nil
	}
	if b, ok := allocs[addr]; ok && uint32(len(b)) >= n {
		return b[:n]
	}
	for base, b := range allocs {
		end := uint64(base) + uint64(len(b))
		if addr >= base && uint64(addr)+uint64(n) <= end {
			off := addr - base
			return b[off : off+n]
		}
	}
	Log(Error, "lk_event: payload is not in a buffer this plugin allocated")
	return nil
}

//go:wasmexport lk_start
func lkStart(addr uint32, n uint32) int32 {
	if registered == nil {
		Log(Error, "lk_start: no plugin registered — call lookout.Register from an init function")
		return -1
	}
	var s Start
	if err := json.Unmarshal(payload(addr, n), &s); err != nil {
		Log(Error, "lk_start: config is not JSON")
		return -1
	}
	if s.ABI != ABIVersion {
		Log(Error, "lk_start: host speaks ABI "+strconv.FormatUint(uint64(s.ABI), 10)+
			", this plugin speaks "+strconv.FormatUint(uint64(ABIVersion), 10))
		return -1
	}
	if err := registered.Start(s); err != nil {
		Log(Error, "start failed: "+err.Error())
		return -1
	}
	return 0
}

//go:wasmexport lk_event
func lkEvent(kind uint32, handle uint64, addr uint32, n uint32) int32 {
	if registered == nil {
		return -1
	}
	k := Kind(kind)
	switch k {
	case ConfigChanged, Timer, TCPConnected, TCPData, TCPClosed, StoreChanged, AISChanged, Shutdown:
	default:
		// The ABI says an unknown kind is ignored and answered 0. A future
		// host must be able to add events without breaking a plugin built
		// today.
		return 0
	}
	e := Event{Kind: k, Handle: int64(handle), Payload: payload(addr, n)}
	if err := registered.OnEvent(e); err != nil {
		Log(Error, "event "+strconv.FormatUint(uint64(kind), 10)+" failed: "+err.Error())
		return -1
	}
	return 0
}
