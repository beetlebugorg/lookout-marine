package lookout

// The raw layer: the API as it is, with no library on top. Tier 3 is written
// against this file — an event switch, a socket, a timer — and tiers 1 and 2
// are written against everything else in the package and never need it.
//
// The docs teach this last. Read chart.go, input.go, settings.go and conn.go
// first; what is here is what the library uses to implement them.

import (
	"encoding/binary"
	"encoding/json"
	"fmt"
	"strconv"
)

// APIVersion is the API this library speaks. lk_abi returns it.
const APIVersion uint32 = 1

// ---------------------------------------------------------------------------
// Logging and clocks: no capability to request for either
// ---------------------------------------------------------------------------

// Level is how loud a log line is.
type Level uint32

const (
	Debug Level = 0
	Info  Level = 1
	Warn  Level = 2
	Error Level = 3
)

// Log writes one line, formatted the way fmt.Sprintf formats. The host stamps
// the plugin id and the level; nothing else is added, and no newline.
func Log(level Level, format string, a ...any) {
	if len(a) == 0 {
		hostLog(level, format)
		return
	}
	hostLog(level, fmt.Sprintf(format, a...))
}

// NowMs is the wall clock, milliseconds since the epoch. Values published to
// the store are stamped with this, and [Publish] does it for you.
func NowMs() int64 { return hostNow() }

// MonoMs is monotonic milliseconds. Measure intervals with this; it does not
// jump when the boat's clock is set from a fresh GPS fix.
func MonoMs() int64 { return hostMono() }

// ---------------------------------------------------------------------------
// Talking to the host
// ---------------------------------------------------------------------------

// PublishJSON sends a {"updates":[...]} batch and returns the number of updates
// the host took, or -1. [Publish] writes the JSON.
func PublishJSON(b []byte) int32 { return hostPublish(b) }

// AISUpsertJSON sends a {"targets":[...]} batch. Speed over ground is METRES
// PER SECOND: everything crossing this API is SI.
func AISUpsertJSON(b []byte) int32 { return hostAISUpsert(b) }

// OverlayJSON posts an overlay batch, {"set":[...],"del":[...]}. A tier-1
// plugin never calls this: [Chart] owns the batch and the diff behind it.
func OverlayJSON(b []byte) int32 { return hostOverlay(b) }

// StatusJSON posts one line of chrome, {"state":"running","detail":"42 msg/s"}.
// The host logs every text it has not seen, so post only on a change. [Say]
// does that for you.
func StatusJSON(b []byte) { hostStatus(b) }

// AlertJSON raises an alert. It needs the alerts.raise capability; without it
// this returns -1 and the host logs the refusal.
func AlertJSON(b []byte) int32 { return hostAlert(b) }

// TableDeclareJSON tells the host about one dialog, which is what makes it
// appear in the shell's menu. A tier-1 plugin never calls this: [NewTable]
// declares itself at start.
func TableDeclareJSON(b []byte) int32 { return hostTableDeclare(b) }

// TableUpdateJSON posts one batch of rows, {"key":…,"upsert":[…],"remove":[…]}.
// The host takes at most one batch per table per 900 ms. [Table] owns the batch
// and the diff behind it.
func TableUpdateJSON(b []byte) int32 { return hostTableUpdate(b) }

// TCPConnect opens a connection and returns a connection id at once — the
// connect completes on the host's I/O thread and arrives as [TCPConnected], or
// as [TCPClosed] if it failed. RECONNECTING IS YOURS: the host never retries.
// A tier-2 plugin never calls this; [Connections] owns the socket.
func TCPConnect(host string, port uint16) int64 { return hostTCPConnect(host, port) }

// TCPSend queues bytes on a connection and returns what it took, or -1.
func TCPSend(id int64, data []byte) int32 { return hostTCPSend(id, data) }

// TCPClose ends a connection. No event follows a close you asked for.
func TCPClose(id int64) { hostTCPClose(id) }

// WSConnect opens a WebSocket. The manifest must grant net.ws for the URL's
// host. The answer arrives as [WSOpen] or [WSClosed].
func WSConnect(url string, protocols ...string) int64 {
	b := append(make([]byte, 0, 128), `{"url":`...)
	b = appendString(b, url)
	if len(protocols) > 0 {
		b = append(b, `,"protocols":[`...)
		for i, p := range protocols {
			if i > 0 {
				b = append(b, ',')
			}
			b = appendString(b, p)
		}
		b = append(b, ']')
	}
	return hostWSConnect(append(b, '}'))
}

// WSSend sends one TEXT message. The host frames it.
func WSSend(id int64, text []byte) int32 { return hostWSSend(id, text) }

// WSClose ends a WebSocket.
func WSClose(id int64) { hostWSClose(id) }

// UDPOpen binds a UDP port and returns a socket id, or -1. Datagrams arrive as
// [UDPData].
func UDPOpen(port uint16) int64 { return hostUDPOpen(port) }

// UDPSend sends one datagram. address is an IP LITERAL — the host resolves no
// name here — so "255.255.255.255" works and "gateway.local" does not.
func UDPSend(id int64, data []byte, address string, port uint16) int32 {
	return hostUDPSend(id, data, address, port)
}

// UDPClose closes a UDP socket.
func UDPClose(id int64) { hostUDPClose(id) }

// HTTPHeader is one request header.
type HTTPHeader struct{ Name, Value string }

// HTTPRequest is what [HTTPFetch] sends. Only URL matters for most callers.
type HTTPRequest struct {
	// Method is GET or HEAD. The host refuses anything else. Empty means GET.
	Method  string
	URL     string
	Headers []HTTPHeader
	// Range is "bytes=0-1048575", or empty. This is how to read a file larger
	// than the 4 MiB body cap: ask for it a range at a time.
	Range string
}

// HTTPFetch starts a fetch and returns a request id, or -1 when the manifest
// does not name the URL's host. The answer arrives as one [HTTPResponse] event
// carrying that id, whether it worked or not.
func HTTPFetch(req HTTPRequest) int64 {
	method := req.Method
	if method == "" {
		method = "GET"
	}
	b := append(make([]byte, 0, 256), `{"method":`...)
	b = appendString(b, method)
	b = append(b, `,"url":`...)
	b = appendString(b, req.URL)
	if req.Range != "" {
		b = append(b, `,"range":`...)
		b = appendString(b, req.Range)
	}
	if len(req.Headers) > 0 {
		b = append(b, `,"headers":{`...)
		for i, h := range req.Headers {
			if i > 0 {
				b = append(b, ',')
			}
			b = appendString(b, h.Name)
			b = append(b, ':')
			b = appendString(b, h.Value)
		}
		b = append(b, '}')
	}
	return hostHTTPFetch(append(b, '}'))
}

// StorageGet reads a key this plugin wrote. It returns nil when the key is not
// there or does not fit in out.
func StorageGet(key string, out []byte) []byte {
	n := hostStorageGet(key, out)
	if n < 0 || int(n) > len(out) {
		return nil
	}
	return out[:n]
}

// StoragePut writes a key. It returns the bytes stored, or -1.
func StoragePut(key string, value []byte) int32 { return hostStoragePut(key, value) }

// StorageDelete forgets a key. An empty value IS the delete; there is no
// separate import.
func StorageDelete(key string) int32 { return hostStoragePut(key, nil) }

// FileRead reads from a file the mariner granted, at an offset. It returns nil
// on a refusal and an empty slice at the end of the file.
func FileRead(handle, offset int64, out []byte) []byte {
	n := hostFileRead(handle, offset, out)
	if n < 0 || int(n) > len(out) {
		return nil
	}
	return out[:n]
}

// FileWrite appends to a granted write file and returns the bytes written, or
// -1.
func FileWrite(handle int64, data []byte) int32 { return hostFileWrite(handle, data) }

// FileClose gives a granted file back.
func FileClose(handle int64) { hostFileClose(handle) }

// TimerSet asks to be woken. A periodic timer repeats every delayMs; otherwise
// it fires once. It arrives as a [Timer] event carrying the id this returns.
//
// This is how a Go plugin waits. time.Sleep is not.
func TimerSet(delayMs int64, periodic bool) int64 { return hostTimerSet(delayMs, periodic) }

// TimerCancel stops a timer.
func TimerCancel(id int64) { hostTimerCancel(id) }

// SubscribePaths subscribes to vessel paths. One subscription per plugin:
// calling again REPLACES the path list. Changes arrive as [StoreChanged]. A
// tier-1 plugin never calls this; declaring an input does it.
func SubscribePaths(paths ...string) int32 {
	b := append(make([]byte, 0, 64), '[')
	for i, p := range paths {
		if i > 0 {
			b = append(b, ',')
		}
		b = appendString(b, p)
	}
	return hostSubscribe(append(b, ']'))
}

// AISSubscribe asks for the AIS target set. The whole snapshot arrives as an
// [AISChanged] event, at most twice a second and only when something moved.
func AISSubscribe() int32 { return hostAISSubscribe() }

// Severity is how loud an alert is. The host maps these to log levels: Alarm at
// error, Warning at warn, Notice at info.
type Severity string

const (
	Alarm   Severity = "alarm"
	Warning Severity = "warning"
	Notice  Severity = "notice"
)

// Alert raises an alert. It needs the alerts.raise capability; -1 means the
// grant is missing.
//
// Raise one when the mariner must act now and would not otherwise know.
// Everything else is a status line: an alarm that cries wolf is switched off,
// and then the real one is not heard.
func Alert(sev Severity, title, body string) int32 {
	return hostAlert(alertPayload("", sev, title, body))
}

// AlertKeyed raises an alert under a key of your own. The host holds one alert
// per plugin per key, so a raise under a key it already holds updates that
// alert instead of adding one, and the mariner's acknowledgement survives it.
//
// Key on the identity of the thing in danger, such as a vessel's MMSI, and not
// on the words. An empty key is no key, and the host then tells the alert from
// another by the title and the body alone. The key is cut at 64 bytes.
func AlertKeyed(key string, sev Severity, title, body string) int32 {
	return hostAlert(alertPayload(key, sev, title, body))
}

func alertPayload(key string, sev Severity, title, body string) []byte {
	b := append(make([]byte, 0, 192), `{"severity":`...)
	b = appendString(b, string(sev))
	if key != "" {
		b = append(b, `,"key":`...)
		b = appendString(b, key)
	}
	b = append(b, `,"title":`...)
	b = appendString(b, title)
	b = append(b, `,"body":`...)
	b = appendString(b, body)
	return append(b, '}')
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
	UDPData       Kind = 7
	HTTPResponded Kind = 8
	FileOpened    Kind = 9
	StoreChanged  Kind = 10
	AISChanged    Kind = 11
	WSOpen        Kind = 12
	WSData        Kind = 13
	WSClosed      Kind = 14
	TableOpen     Kind = 15
	TableClosed   Kind = 16
	GrantsChanged Kind = 17
	Shutdown      Kind = 99
)

// known is the set the API defines. An unknown kind is answered 0 without
// reaching a plugin, so a future host can add events without breaking a plugin
// built today.
func (k Kind) known() bool {
	switch k {
	case ConfigChanged, Timer, TCPConnected, TCPData, TCPClosed, UDPData,
		HTTPResponded, FileOpened, StoreChanged, AISChanged, WSOpen, WSData,
		WSClosed, TableOpen, TableClosed, GrantsChanged, Shutdown:
		return true
	}
	return false
}

// Event is everything that happens.
//
// Payload BELONGS TO THE HOST. It is valid for the length of the call and freed
// after it. Copy anything you keep.
type Event struct {
	Kind Kind
	// Handle correlates: which timer, which connection, which request. Zero for
	// the events that have nothing to correlate.
	Handle  int64
	Payload []byte
}

// Data is the bytes of a TCPData, WSData or UDPData event.
func (e Event) Data() []byte { return e.Payload }

// Config unmarshals a ConfigChanged payload — the whole settings object, with
// every field the manifest's schema declares present, so a handler reads what
// it wants and never merges.
func (e Event) Config(v any) error { return json.Unmarshal(e.Payload, v) }

// Protocol is the subprotocol the server chose on a WSOpen event, or empty when
// it chose none.
func (e Event) Protocol() string {
	var doc struct {
		Protocol string `json:"protocol"`
	}
	_ = json.Unmarshal(e.Payload, &doc)
	return doc.Protocol
}

// TableKey is the table a TableOpen or TableClosed event is about. A tier-1
// plugin never reads this: [Table] tracks its own dialog.
func (e Event) TableKey() string {
	var doc struct {
		Key string `json:"key"`
	}
	_ = json.Unmarshal(e.Payload, &doc)
	return doc.Key
}

// Granted is true when a GrantsChanged event lists this capability, by its
// manifest name: "overlay.draw", "alerts.raise". It is false for a payload that
// will not parse, which is the safe answer for a permissions list.
//
// GRANTS_CHANGED IS THE ONLY WAY TO KNOW WHAT YOU HOLD. The manifest is what
// the plugin asked for; this is what the mariner left switched on.
func (e Event) Granted(capability string) bool {
	var doc struct {
		Granted []string `json:"granted"`
	}
	if json.Unmarshal(e.Payload, &doc) != nil {
		return false
	}
	for _, c := range doc.Granted {
		if c == capability {
			return true
		}
	}
	return false
}

// Close reads a WSClosed event: the RFC 6455 code, or 0 when the connection
// never opened, in which case reason names what stopped it.
func (e Event) Close() (code uint16, reason string) {
	var doc struct {
		Code   uint16 `json:"code"`
		Reason string `json:"reason"`
	}
	_ = json.Unmarshal(e.Payload, &doc)
	return doc.Code, doc.Reason
}

// File is a file the mariner chose and the host handed over, off a FileOpened
// event. Handle is what [FileRead] and [FileWrite] take.
type File struct {
	Handle int64
	Name   string `json:"name"`
	Size   uint64 `json:"size"`
	// Mode is "read" or "write". A read handle refuses FileWrite.
	Mode string `json:"mode"`
}

// Writable is true when the plugin may write to the file.
func (f File) Writable() bool { return f.Mode == "write" }

// File reads a FileOpened event.
func (e Event) File() File {
	f := File{Handle: e.Handle, Mode: "read"}
	_ = json.Unmarshal(e.Payload, &f)
	return f
}

// Response is the answer to one [HTTPFetch]. Status is 0 when the fetch never
// reached a server, and Head then carries an "error" naming what stopped it.
type Response struct {
	Request int64
	Status  uint16
	// Head is {"status":200,"url":…,"headers":{…}}.
	Head []byte
	// Body is the bytes as they arrived. Empty for a failure.
	Body []byte
}

// Header reads one response header by its LOWER-CASE name. The host lower-cases
// every name it writes, so "content-length" finds Content-Length.
func (r Response) Header(name string) string {
	var doc struct {
		Headers map[string]string `json:"headers"`
	}
	if json.Unmarshal(r.Head, &doc) != nil {
		return ""
	}
	return doc.Headers[name]
}

// Response splits an HTTPResponded payload: u32 head length, the head JSON, the
// raw body. One event carries both because a plugin needs both and the API
// carries one payload per event.
func (e Event) Response() Response {
	r := Response{Request: e.Handle}
	if len(e.Payload) < 4 {
		return r
	}
	n := binary.LittleEndian.Uint32(e.Payload[:4])
	if 4+int(n) > len(e.Payload) {
		return r
	}
	r.Head = e.Payload[4 : 4+n]
	r.Body = e.Payload[4+n:]
	var doc struct {
		Status uint16 `json:"status"`
	}
	_ = json.Unmarshal(r.Head, &doc)
	r.Status = doc.Status
	return r
}

// Start is what OnStart receives.
type Start struct {
	API uint32 `json:"abi"`
	// Config is the settings object as the host sent it. A plugin with a
	// Settings struct never reads this: the library has already filled the
	// struct in by the time OnStart runs.
	Config json.RawMessage `json:"config"`
}

// Unmarshal reads the start config into a struct of your own.
func (s Start) Unmarshal(v any) error {
	if len(s.Config) == 0 {
		return nil
	}
	return json.Unmarshal(s.Config, v)
}

// PathValue is one entry of a StoreChanged payload.
type PathValue struct {
	Path string `json:"path"`
	// Value is null when the path has NO value any more — the source was
	// cleared — not when a source published a null. Removed reports it.
	Value json.RawMessage `json:"value"`
	TsMs  int64           `json:"ts"`
	AgeMs int64           `json:"age_ms"`
}

// Removed is true when the path has no value at all any more. Treat it as
// removal: stop drawing whatever the value fed.
func (r PathValue) Removed() bool { return len(r.Value) == 0 || string(r.Value) == "null" }

// Number reads the value as a number.
func (r PathValue) Number() (float64, bool) {
	var v float64
	if r.Removed() || json.Unmarshal(r.Value, &v) != nil {
		return 0, false
	}
	return v, true
}

// Position reads the value as a fix.
func (r PathValue) Position() (Point, bool) {
	var v struct {
		Lat *float64 `json:"lat"`
		Lon *float64 `json:"lon"`
	}
	if r.Removed() || json.Unmarshal(r.Value, &v) != nil || v.Lat == nil || v.Lon == nil {
		return Point{}, false
	}
	return Point{Lat: *v.Lat, Lon: *v.Lon}, true
}

// PathValues parses a StoreChanged payload. It returns nothing for any other
// event, and nothing for a payload that will not parse.
func (e Event) PathValues() []PathValue {
	var doc struct {
		Values []PathValue `json:"values"`
	}
	if json.Unmarshal(e.Payload, &doc) != nil {
		return nil
	}
	return doc.Values
}

// Target is one vessel or aid the AIS receiver has heard. An absent field is
// nil: "never heard" and "heard as zero" are different things at sea.
type Target struct {
	MMSI uint32   `json:"mmsi"`
	Lat  *float64 `json:"lat"`
	Lon  *float64 `json:"lon"`
	// SOG is metres per second.
	SOG     *float64 `json:"sog"`
	COG     *float64 `json:"cog"`
	Heading *float64 `json:"heading"`
	Name    string   `json:"name"`
	// NavStatus is the navigation status, 0..14, as a class A position report
	// carries it. Class B sends none.
	NavStatus *uint8 `json:"nav_status"`
	// ShipType is the ship and cargo type, 0..99.
	ShipType *uint8 `json:"ship_type"`
	// ClassB is true when the last position report came on class B, false on
	// class A, and nil until one has said which.
	ClassB      *bool  `json:"class_b"`
	CallSign    string `json:"callsign"`
	Destination string `json:"destination"`
	// IMO is the number alone, without the "IMO" a mariner reads in front of it.
	IMO *uint32 `json:"imo"`
	// DraughtM is the maximum static draught, metres.
	DraughtM *float64 `json:"draught"`
	// LengthM and BeamM are the overall figures, metres.
	LengthM *uint16 `json:"length"`
	BeamM   *uint16 `json:"beam"`
	// ATON is true for an aid to navigation, which has its own aging and no CPA.
	ATON        bool   `json:"aton"`
	ATONType    *uint8 `json:"aton_type"`
	VirtualATON bool   `json:"virtual"`
	OffPosition *bool  `json:"off_position"`
	TsMs        int64  `json:"ts"`
	// AgeMs is how old the report is, carried forward from delivery.
	AgeMs int64 `json:"age_ms"`
}

// At is the target's position, and false when it has never been heard with a
// fix.
func (t Target) At() (Point, bool) {
	if t.Lat == nil || t.Lon == nil {
		return Point{}, false
	}
	return Point{Lat: *t.Lat, Lon: *t.Lon}, true
}

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
// Publishing
// ---------------------------------------------------------------------------

// Publish is a batch of vessel values. Every value is stamped with the host's
// wall clock, which is what the store ages against.
//
//	p := lk.NewPublish()
//	p.Number("navigation.speedOverGround", mps)
//	p.Position("navigation.position", lk.Point{Lat: lat, Lon: lon})
//	p.Send()
type Publish struct {
	b  []byte
	n  int
	ts int64
}

// NewPublish begins a batch.
func NewPublish() *Publish {
	return &Publish{b: append(make([]byte, 0, 256), `{"updates":[`...), ts: NowMs()}
}

func (p *Publish) open(path string) {
	if p.n > 0 {
		p.b = append(p.b, ',')
	}
	p.n++
	p.b = append(p.b, `{"path":`...)
	p.b = appendString(p.b, path)
	p.b = append(p.b, `,"value":`...)
}

func (p *Publish) close() {
	p.b = append(p.b, `,"ts":`...)
	p.b = strconv.AppendInt(p.b, p.ts, 10)
	p.b = append(p.b, '}')
}

// Number adds one numeric value. Everything crossing the API is SI.
func (p *Publish) Number(path string, v float64) {
	p.open(path)
	p.b = appendNum(p.b, v)
	p.close()
}

// Position adds one fix.
func (p *Publish) Position(path string, at Point) {
	p.open(path)
	p.b = append(p.b, `{"lat":`...)
	p.b = appendNum(p.b, at.Lat)
	p.b = append(p.b, `,"lon":`...)
	p.b = appendNum(p.b, at.Lon)
	p.b = append(p.b, '}')
	p.close()
}

// Clear says this source holds the path and has no value for it right now.
func (p *Publish) Clear(path string) {
	p.open(path)
	p.b = append(p.b, "null"...)
	p.close()
}

// Send posts the batch and returns the number of values the host took, or -1.
// An empty batch is not sent and answers 0.
func (p *Publish) Send() int32 {
	if p.n == 0 {
		return 0
	}
	return PublishJSON(append(p.b, ']', '}'))
}

// Upsert is a batch of AIS targets. SOG is metres per second, whatever the wire
// format reported.
type Upsert struct {
	b  []byte
	n  int
	ts int64
}

// NewUpsert begins a batch.
func NewUpsert() *Upsert {
	return &Upsert{b: append(make([]byte, 0, 256), `{"targets":[`...), ts: NowMs()}
}

// Target adds one target. A nil field is left out of the JSON, so the host
// keeps what it already knows rather than overwriting it with a zero.
func (u *Upsert) Target(t Target) {
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
		u.b = appendString(u.b, t.Name)
	}
	u.code("nav_status", t.NavStatus)
	u.code("ship_type", t.ShipType)
	if t.ClassB != nil {
		u.b = append(u.b, `,"class_b":`...)
		u.b = strconv.AppendBool(u.b, *t.ClassB)
	}
	if t.CallSign != "" {
		u.b = append(u.b, `,"callsign":`...)
		u.b = appendString(u.b, t.CallSign)
	}
	if t.Destination != "" {
		u.b = append(u.b, `,"destination":`...)
		u.b = appendString(u.b, t.Destination)
	}
	if t.IMO != nil {
		u.b = append(u.b, `,"imo":`...)
		u.b = strconv.AppendUint(u.b, uint64(*t.IMO), 10)
	}
	u.field("draught", t.DraughtM)
	u.metres("length", t.LengthM)
	u.metres("beam", t.BeamM)
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
	u.b = strconv.AppendInt(u.b, u.ts, 10)
	u.b = append(u.b, '}')
}

func (u *Upsert) code(name string, v *uint8) {
	if v == nil {
		return
	}
	u.b = append(u.b, ',', '"')
	u.b = append(u.b, name...)
	u.b = append(u.b, '"', ':')
	u.b = strconv.AppendUint(u.b, uint64(*v), 10)
}

func (u *Upsert) metres(name string, v *uint16) {
	if v == nil {
		return
	}
	u.b = append(u.b, ',', '"')
	u.b = append(u.b, name...)
	u.b = append(u.b, '"', ':')
	u.b = strconv.AppendUint(u.b, uint64(*v), 10)
}

func (u *Upsert) field(name string, v *float64) {
	if v == nil {
		return
	}
	u.b = append(u.b, ',', '"')
	u.b = append(u.b, name...)
	u.b = append(u.b, '"', ':')
	u.b = appendNum(u.b, *v)
}

// Send posts the batch and returns the number of targets the host took, or -1.
func (u *Upsert) Send() int32 {
	if u.n == 0 {
		return 0
	}
	return AISUpsertJSON(append(u.b, ']', '}'))
}
