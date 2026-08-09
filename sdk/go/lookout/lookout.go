// Package lookout is the Lookout plugin API in Go. Declare what you read, and
// draw.
//
//	package main
//
//	import lk "github.com/beetlebugorg/lookout-marine/sdk/go/lookout"
//
//	var (
//		boat = lk.SubscribePosition("navigation.position")
//		twd  = lk.SubscribeNumber("environment.wind.directionTrue", lk.InputOpts{Label: "wind"})
//	)
//
//	type windline struct{}
//
//	func init() { lk.Register(&windline{}) }
//	func main() {}
//
//	func (p *windline) Draw(c *lk.Chart) {
//		from := boat.Get()
//		to := from.Destination(twd.Get()+180, lk.NM(1))
//		c.Line("windline", []lk.Point{from, to}, lk.Line{Color: lk.ColorWarning, Dash: true})
//	}
//
// # Three tiers
//
// Tier 1 is the block above: inputs and Draw. Tier 2 adds [Connections] — the
// library owns the sockets, the reconnect clock and the per-row status, and the
// plugin writes OnData. Tier 3 is OnEvent, the raw event stream, for whatever
// the first two do not cover.
//
// # What the library owns, so an author never writes it
//
//   - the subscription, and one recorded value per declared input, aged against
//     the monotonic clock rather than the wall clock;
//   - the draw timer. Draw runs at [DefaultDrawRate], not on every store change:
//     the store fans out at up to 10 Hz. It runs only while there is somewhere
//     for a scene to land, so a plugin whose overlay.draw grant the mariner has
//     switched off stops drawing until it comes back;
//   - the freshness gate. Draw runs only when every required input is inside its
//     window. Otherwise the scene is cleared and the status names every missing
//     input at once;
//   - the scene. Draw describes the whole picture each call; the library
//     compares it with the last one and sends only what changed. An object not
//     drawn this call is deleted. There is no delete call and no buffer;
//   - the status line, deduped. The host logs every status text it has not seen,
//     so a repeat would be a log line a second;
//   - the settings, read into a struct of your own, with the manifest's schema
//     generated from the same declaration.
//
// # What a plugin may implement
//
// [Register] takes any value. Every method below is optional and is wired only
// when the value has it:
//
//	Draw(*Chart)                the scene, on the library's timer
//	DrawRate() time.Duration    how often, default 1 s
//	OnUpdate()                  after an input changed: the decision, and the rows
//	OnSettings()                after a settings change, before the redraw
//	OnData(*Conn, []byte)       bytes from one connection's socket    (tier 2)
//	OnOpen(*Conn)               a stream came up; send a subscription (tier 2)
//	OnClose(*Conn)              a stream ended                        (tier 2)
//	ConnNote(*Conn) string      a phrase after the connection's rate  (tier 2)
//	Endpoint(*Conn) Endpoint    where to dial, when it is not host:port (tier 2)
//	OnStart(Start) error        anything else at startup
//	OnEvent(Event) error        every event the library did not consume (tier 3)
//	OnShutdown()                the last word
//
// A settings struct is a field named Settings on the registered value; see
// [SettingsJSON]. Inputs, connection lists and tables are package-level
// variables; see [SubscribeNumber], [Connections] and [NewTable].
//
// # Where a decision belongs
//
// OnUpdate runs the moment a declared input has a new value, with every input
// already current. It is the clock for work that is not drawing: a plugin that
// only watches a condition implements OnUpdate and no Draw, and a plugin that
// does both keeps the decision there and renders it here. DrawRate is a
// graphics rate you chose, so a decision taken in Draw runs at whatever rate
// suits the picture.
//
// OnUpdate also runs when a value expires. A plugin that only heard about
// arrivals could never notice an absence. A value carries its window, so the
// moment it stops counting is known when it lands: the library arms a one-shot
// for the earliest such moment across the declared inputs and runs the cycle
// there. The input reads stale in that call, and the plugin empties what
// depended on it. Windows differ, so each input expires on its own wakeup.
// Nothing polls: once every input has expired there is no next moment, nothing
// is armed, and an idle plugin costs nothing at all until the next value
// arrives. A plugin with no declared inputs has nothing that can expire and
// hears only about arrivals.
//
// The declared inputs decide that, not the methods beside them. A plugin that
// only draws is woken the same way, because a picture held up by a value that
// stopped counting is a confident drawing of a guess and has to come off the
// chart.
//
// A table is filled from OnUpdate. Rows are data. The library opens a table
// cycle before that call and closes it after, so a plugin upserts its rows
// there and nowhere else. A plugin does not need to request a capability to
// fill a table, so its rows keep arriving while the chart grant is off and the
// draw timer is down.
//
// # Register in init, not in main
//
// Build a plugin with -buildmode=c-shared and the module is a WASI reactor: the
// host calls _initialize, which runs package initialisation, and then calls the
// exports. YOUR func main NEVER RUNS. Package main still needs one to compile;
// leave it empty and do your setup in an init function, in OnStart, or in a
// package-level variable.
//
// # Single-threaded, and it is not a suggestion
//
// One plugin is one thread, and it runs only while the host is inside one of the
// exports. A goroutine you start makes no progress after you return, because
// nothing is scheduling it; time.Sleep does not sleep, it fails, because the
// host refuses the WASI call that would park the thread. So:
//
//   - Do the work in the handler and return.
//   - No background goroutines, no worker pools, no channels between events.
//   - To wake up later, ask for [TimerSet] and handle the [Timer] event.
//   - To read a socket, declare a connection list, or ask for [TCPConnect] and
//     handle the [TCPData] event.
//
// The reason is time isolation. The host gives every call into the module a
// budget and kills the instance when it runs out, so a plugin that stops
// answering delays nobody but itself.
//
// # What WASI gives you
//
// The Go runtime needs WASI to boot, so it is there: clocks, randomness, stdout
// and stderr. Everything else is refused. There is no filesystem — os.Open fails
// on every path — no sockets, no environment variables, no arguments and no
// threads. fmt.Println works and goes to the plugin's log, one line per call.
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
	"errors"
	"fmt"
	"reflect"
	"strconv"
	"strings"
	"time"
)

// DefaultDrawRate is how often Draw runs when a plugin declares no rate.
const DefaultDrawRate = time.Second

// Drawer is the tier-1 entry point: describe the whole scene, every call.
type Drawer interface{ Draw(c *Chart) }

// DrawRater sets how often Draw runs.
type DrawRater interface{ DrawRate() time.Duration }

// Updater is the data path: a batch of values has landed and every declared
// input holds its new value. Decide here, and fill any table here.
type Updater interface{ OnUpdate() }

// SettingsWatcher hears about a settings change, after the library has filled
// the Settings struct in and before it redraws.
type SettingsWatcher interface{ OnSettings() }

// DataHandler is the tier-2 entry point: bytes from one connection's socket.
type DataHandler interface{ OnData(conn *Conn, data []byte) }

// Opener hears that a connection's stream came up. Send a subscription here.
type Opener interface{ OnOpen(conn *Conn) }

// Closer hears that a connection's stream ended.
type Closer interface{ OnClose(conn *Conn) }

// Noter adds a phrase after the rate on a connection's status line while the
// stream is up.
type Noter interface{ ConnNote(conn *Conn) string }

// Endpointer says where a connection is dialled, when it is not the
// connection's host and port: a websocket URL, say.
type Endpointer interface{ Endpoint(conn *Conn) Endpoint }

// Starter does anything else at startup, after the library has subscribed and
// armed its timers.
type Starter interface{ OnStart(s Start) error }

// EventHandler is the tier-3 entry point: every event the library did not
// consume.
type EventHandler interface{ OnEvent(e Event) error }

// Shutdowner gets the last word. Sockets and timers are closed for you.
type Shutdowner interface{ OnShutdown() }

// State is what the chrome says about a plugin.
type State string

const (
	StateStarting State = "starting"
	StateRunning  State = "running"
	StateDegraded State = "degraded"
	StateStopped  State = "stopped"
)

// ---------------------------------------------------------------------------
// Registration
// ---------------------------------------------------------------------------

type registry struct {
	plugin any
	inputs []*input
	ais    *AISInput
	conns  *Conns
	tables []*Table
	groups []specGroup

	drawTimer int64
	drawEvery int64
	missing   []string

	// updateTimer is the appointment for the next value to expire, and -1
	// when there is none. A plugin with nothing that can go stale never holds
	// one. updateDue is the moment it is set for, read only while it is up.
	updateTimer int64
	updateDue   int64

	// mayDraw is true while the mariner leaves overlay.draw on. The host
	// refuses every overlay call without it, so a scene described then is work
	// thrown away. Assumed on until the host says otherwise, which it does once
	// the module has started.
	mayDraw bool

	// Complaints found while wiring, held until the host is listening: the
	// module is instantiated before lk_start and a log line written during
	// package initialisation has nowhere to go.
	wiring []string
	// fatal is a declaration the library cannot work with. The start refuses.
	fatal error
}

var reg = newRegistry()

func newRegistry() registry { return registry{drawTimer: -1, updateTimer: -1, mayDraw: true} }

// Register wires the exports to p. Call it once, from an init function or a
// package-level variable — NOT from main, which a reactor module never runs.
func Register(p any) {
	if reg.plugin != nil {
		noteWiring("Register was called more than once; the last plugin wins")
	}
	reg.plugin = p
	checkMethod(p, "Draw", "Draw(*lookout.Chart)")
	checkMethod(p, "OnData", "OnData(*lookout.Conn, []byte)")

	groups, err := settingsOf(p)
	if err != nil {
		// A misdeclared setting reads as its zero value for ever, so the start
		// refuses rather than running the plugin on numbers nobody chose.
		reg.fatal = errors.New("settings: " + err.Error())
		return
	}
	reg.groups = groups
	for _, g := range groups {
		g.applyDefaults()
	}
}

// register records one declared input. Inputs are package-level variables, so
// this runs before Register does.
func register(in *input) { reg.inputs = append(reg.inputs, in) }

func registerAIS(a *AISInput) {
	if reg.ais != nil {
		noteWiring("more than one AIS input; the first is used")
		return
	}
	reg.ais = a
}

func registerConns(c *Conns) {
	if reg.conns != nil {
		noteWiring("more than one connection list; the first is used")
		return
	}
	reg.conns = c
}

func registerTable(t *Table) {
	for _, other := range reg.tables {
		if other.opts.Key == t.opts.Key {
			noteWiring("two tables called " + strconv.Quote(t.opts.Key) + "; the first is used")
			return
		}
	}
	reg.tables = append(reg.tables, t)
}

func noteWiring(msg string) { reg.wiring = append(reg.wiring, msg) }

// checkMethod catches the method that is there under a name Go will not match:
// a wrong signature makes the interface assertion fail silently, and the plugin
// then does nothing at all.
func checkMethod(p any, name, want string) {
	t := reflect.TypeOf(p)
	if t == nil {
		return
	}
	if _, ok := t.MethodByName(name); !ok {
		return
	}
	switch name {
	case "Draw":
		if _, ok := p.(Drawer); ok {
			return
		}
	case "OnData":
		if _, ok := p.(DataHandler); ok {
			return
		}
	}
	noteWiring(name + " has the wrong signature and is not wired; it must be " + want)
}

// resetRegistry puts the package back to how it starts. The library's own tests
// register a plugin per test; a plugin calls Register once and never this.
func resetRegistry() {
	reg = newRegistry()
	scene = sceneState{}
	lastState, lastDetail, saidOnce = "", "", false
}

// ---------------------------------------------------------------------------
// The status line
// ---------------------------------------------------------------------------

var (
	lastState  string
	lastDetail string
	saidOnce   bool
)

// Say posts one status line, deduped. Nothing is sent while the state and the
// detail are what they already were. A tier-1 plugin uses [Chart.Status] and
// [Chart.Degraded] instead.
func Say(state State, format string, a ...any) {
	detail := format
	if len(a) > 0 {
		detail = fmt.Sprintf(format, a...)
	}
	sayText(string(state), detail)
}

func sayText(state, detail string) {
	if saidOnce && lastState == state && lastDetail == detail {
		return
	}
	saidOnce = true
	lastState, lastDetail = state, detail
	b := append(make([]byte, 0, 96), `{"state":`...)
	b = appendString(b, state)
	b = append(b, `,"detail":`...)
	b = appendString(b, detail)
	StatusJSON(append(b, '}'))
}

// ---------------------------------------------------------------------------
// The lifecycle
// ---------------------------------------------------------------------------

// dispatchStart is lk_start: read the settings, subscribe, arm the timers, and
// hand control to the plugin.
func dispatchStart(raw []byte) int32 {
	for _, w := range reg.wiring {
		Log(Error, "%s", w)
	}
	if reg.plugin == nil {
		Log(Error, "lk_start: no plugin registered — call lookout.Register from an init function")
		return -1
	}
	var s Start
	if err := json.Unmarshal(raw, &s); err != nil {
		Log(Error, "lk_start: config is not JSON")
		return -1
	}
	if s.API != APIVersion {
		Log(Error, "lk_start: host speaks API %d, this plugin speaks %d", s.API, APIVersion)
		return -1
	}
	if err := wiringComplaint(); err != nil {
		Log(Error, "lk_start: %s", err.Error())
		return -1
	}

	cfg := configOf(s.Config)
	readSettings(cfg)

	if len(reg.inputs) > 0 {
		paths := make([]string, len(reg.inputs))
		for i, in := range reg.inputs {
			paths[i] = in.path
		}
		if SubscribePaths(paths...) < 0 {
			Log(Error, "lk_start: subscribe refused")
			return -1
		}
	}
	if reg.ais != nil && AISSubscribe() < 0 {
		Log(Error, "lk_start: ais_subscribe refused")
		return -1
	}
	if reg.conns != nil {
		reg.conns.start(cfg)
	}
	for _, t := range reg.tables {
		t.declare()
	}
	if _, ok := reg.plugin.(Drawer); ok {
		reg.drawEvery = DefaultDrawRate.Milliseconds()
		if r, ok := reg.plugin.(DrawRater); ok && r.DrawRate() > 0 {
			reg.drawEvery = r.DrawRate().Milliseconds()
		}
		reg.drawTimer = TimerSet(reg.drawEvery, true)
		if reg.drawTimer < 0 {
			Log(Error, "lk_start: timer refused")
			return -1
		}
		if labels := requiredLabels(); len(labels) > 0 {
			Say(StateStarting, "waiting for %s", strings.Join(labels, ", "))
		} else {
			Say(StateStarting, "")
		}
	}
	if st, ok := reg.plugin.(Starter); ok {
		if err := st.OnStart(s); err != nil {
			Log(Error, "start failed: %s", err.Error())
			return -1
		}
	}
	return 0
}

// wiringComplaint is the wiring that makes a plugin do nothing at all, which is
// worth refusing the start over rather than logging and running.
func wiringComplaint() error {
	if reg.fatal != nil {
		return reg.fatal
	}
	_, draws := reg.plugin.(Drawer)
	_, handles := reg.plugin.(DataHandler)
	_, raws := reg.plugin.(EventHandler)
	_, starts := reg.plugin.(Starter)
	_, updates := reg.plugin.(Updater)
	if !draws && !handles && !raws && !starts && !updates {
		return errors.New("the registered plugin has none of Draw, OnUpdate, OnData, OnEvent or OnStart")
	}
	if reg.conns != nil && !handles {
		return errors.New("a connection list is declared and the plugin has no OnData method")
	}
	if len(reg.tables) > 0 && !updates {
		// A table is filled from OnUpdate. Without it the dialog opens empty
		// and stays empty, which looks like a broken shell rather than a
		// plugin that never wrote a row.
		return errors.New("a table is declared and the plugin has no OnUpdate method to fill it")
	}
	return nil
}

// dispatchEvent is lk_event: consume what the library owns, and pass the rest
// on.
func dispatchEvent(kind Kind, handle int64, raw []byte) int32 {
	if reg.plugin == nil {
		return -1
	}
	if !kind.known() {
		// The API says an unknown kind is ignored and answered 0. A future host
		// must be able to add events without breaking a plugin built today.
		return 0
	}
	e := Event{Kind: kind, Handle: handle, Payload: raw}

	switch kind {
	case StoreChanged:
		if len(reg.inputs) > 0 {
			mono := MonoMs()
			claimed := 0
			for _, r := range e.PathValues() {
				for _, in := range reg.inputs {
					if in.path == r.Path {
						in.record(r, mono)
						claimed++
					}
				}
			}
			// A batch that touched none of the declared inputs is not an
			// update: nothing this plugin reads has changed.
			if claimed > 0 {
				runUpdate(mono)
			}
			return 0
		}
	case AISChanged:
		if reg.ais != nil {
			mono := MonoMs()
			reg.ais.record(e, mono)
			runUpdate(mono)
			return 0
		}
	case ConfigChanged:
		cfg := configOf(raw)
		readSettings(cfg)
		if reg.conns != nil {
			reg.conns.config(cfg)
		}
		if w, ok := reg.plugin.(SettingsWatcher); ok {
			w.OnSettings()
		}
		// A changed setting must show now, not at the next tick.
		if _, ok := reg.plugin.(Drawer); ok {
			runDraw()
		}
		return 0
	case GrantsChanged:
		if _, ok := reg.plugin.(Drawer); ok {
			setMayDraw(e.Granted("overlay.draw"))
		}
	case TableOpen, TableClosed:
		// A table the mariner just opened is filled at once: the dialog must
		// not sit empty until the next batch of values.
		mine := false
		for _, t := range reg.tables {
			if t.setOpen(e.TableKey(), kind == TableOpen) {
				mine = true
			}
		}
		if mine {
			if kind == TableOpen {
				runUpdate(MonoMs())
			}
			return 0
		}
	case Timer:
		if reg.drawTimer >= 0 && handle == reg.drawTimer {
			runDraw()
			return 0
		}
		if reg.updateTimer >= 0 && handle == reg.updateTimer {
			// The host drops a one-shot when it fires, so the handle is spent
			// and the cycle makes the next.
			reg.updateTimer = -1
			runUpdate(MonoMs())
			return 0
		}
		if reg.conns != nil && reg.conns.timer(handle) {
			return 0
		}
	case Shutdown:
		if reg.drawTimer >= 0 {
			TimerCancel(reg.drawTimer)
			reg.drawTimer = -1
		}
		if reg.updateTimer >= 0 {
			TimerCancel(reg.updateTimer)
			reg.updateTimer = -1
		}
		if reg.conns != nil {
			reg.conns.shutdown()
		}
		if s, ok := reg.plugin.(Shutdowner); ok {
			s.OnShutdown()
		}
		// The host drops every overlay object a stopped plugin owns, so there
		// is nothing to delete here.
		sayText(string(StateStopped), "shut down")
		return 0
	default:
		if reg.conns != nil && reg.conns.event(e) {
			return 0
		}
	}

	if h, ok := reg.plugin.(EventHandler); ok {
		if err := h.OnEvent(e); err != nil {
			Log(Error, "event %d failed: %s", uint32(kind), err.Error())
			return -1
		}
	}
	return 0
}

// noDrawLine is what the status says while the chart grant is off.
const noDrawLine = "not drawing: permission to draw on the chart is off"

// runUpdate is one pass on the data path: the plugin's decision, and the rows it
// fills around it. The chart grant does not reach here. A table is data, it
// no manifest has to ask for it, and a dialog on screen fills whether or not
// the plugin may draw.
// The cycle runs when a value arrives and when one expires. A plugin that
// only heard about arrivals could never notice an absence. A plugin with no
// hook and no table runs it for the appointment alone.
func runUpdate(mono int64) {
	u, updates := reg.plugin.(Updater)
	if updates || len(reg.tables) > 0 {
		for _, t := range reg.tables {
			t.begin(mono)
		}
		if updates {
			u.OnUpdate()
		}
		for _, t := range reg.tables {
			t.flush()
		}
	}
	if wantsUpdateTimer() {
		armUpdate(mono)
	}
}

// wantsUpdateTimer is true when an input can go stale, so an expiry is worth
// waiting for. The inputs decide this and the methods do not: an expiry changes
// what the plugin should show whether or not it wrote an OnUpdate.
func wantsUpdateTimer() bool {
	return len(reg.inputs) > 0 || reg.ais != nil
}

// armUpdate wakes the plugin once, exactly when the next value expires.
//
// A value carries its window, so the moment it stops counting is known when
// it lands. The library takes the earliest such moment across the declared
// inputs and arms a one-shot for it; the cycle it fires reads that input as
// stale, and the plugin empties whatever depended on it. Windows differ, so
// each input expires on its own wakeup and the plugin can say which one went.
//
// When every input has already expired there is no next moment and nothing is
// armed. The next arrival runs a cycle, and the cycle makes the next
// appointment.
//
// The chart grant does not reach here. A plugin that may not draw still has a
// dialog to fill and a condition to watch.
func armUpdate(mono int64) {
	next := int64(0)
	found := false
	for _, in := range reg.inputs {
		if at, ok := in.staleAt(mono); ok && (!found || at < next) {
			next = at
			found = true
		}
	}
	if reg.ais != nil {
		if at, ok := reg.ais.staleAt(mono); ok && (!found || at < next) {
			next = at
			found = true
		}
	}
	// A value is still fresh on the last millisecond of its window, so the
	// appointment is one past it. A wakeup that found the value fresh would
	// have nothing to tell the plugin.
	due := next + 1

	if reg.updateTimer >= 0 {
		if found && due == reg.updateDue {
			return
		}
		TimerCancel(reg.updateTimer)
		reg.updateTimer = -1
	}
	if !found {
		return
	}
	reg.updateTimer = TimerSet(due-mono, false)
	if reg.updateTimer < 0 {
		Log(Error, "update timer refused; a value going stale will pass unnoticed")
		return
	}
	reg.updateDue = due
}

// setMayDraw takes the chart grant on or off.
//
// The host has already removed what this plugin drew, so the diff held here
// describes objects that are gone. Forget it: the next draw sends the whole
// scene rather than a difference against nothing.
func setMayDraw(on bool) {
	if on == reg.mayDraw {
		return
	}
	reg.mayDraw = on
	scene.forget()
	armTimer()
	if on {
		runDraw()
		return
	}
	// The chart is empty and the mariner is the reason. Say so, or the plugin
	// looks broken.
	sayText(string(StateDegraded), noDrawLine)
}

// armTimer runs the draw timer exactly while the chart grant is on. Without it
// every overlay call is refused, so a scene described then is work thrown away.
func armTimer() {
	if reg.mayDraw == (reg.drawTimer >= 0) {
		return
	}
	if reg.mayDraw {
		reg.drawTimer = TimerSet(reg.drawEvery, true)
		if reg.drawTimer < 0 {
			Log(Error, "draw timer refused; nothing will be drawn")
		}
		return
	}
	TimerCancel(reg.drawTimer)
	reg.drawTimer = -1
}

// runDraw is one frame: gate on freshness, let the plugin describe the scene,
// send the difference, and post the status.
func runDraw() {
	d, ok := reg.plugin.(Drawer)
	if !ok {
		return
	}
	mono := MonoMs()
	reg.missing = reg.missing[:0]
	for _, in := range reg.inputs {
		if !in.optional && !in.freshAt(mono) {
			reg.missing = append(reg.missing, in.label)
		}
	}
	if len(reg.missing) > 0 {
		// Every missing input is named: a line that says "no wind" while the
		// GPS is also out sends the mariner to the wrong instrument.
		scene.begin()
		sendScene() // draws nothing, so everything drawn is deleted
		sayStatus(string(StateDegraded), "no "+strings.Join(reg.missing, ", no "))
		return
	}

	var c Chart
	scene.begin()
	d.Draw(&c)
	sendScene()
	if c.said {
		sayStatus(string(c.state), c.detail)
		return
	}
	sayStatus(string(StateRunning), "")
}

// sendScene posts the scene when the chart will take it. Without the grant the
// batch is dropped in the module: every call in it would be refused, and a
// refusal costs a crossing into the host and a denied count.
func sendScene() {
	if reg.mayDraw {
		scene.commit()
		return
	}
	scene.forget()
}

// sayStatus posts the status a frame produced, or the reason there is no frame.
//
// A frame runs on a settings change whatever the chart grant says, so the line
// it wrote has to give way to the one thing the mariner needs to read. While
// the grant is off nothing else calls this, so a plugin is free to post its own
// line from OnUpdate.
func sayStatus(state, detail string) {
	if reg.mayDraw {
		sayText(state, detail)
		return
	}
	sayText(string(StateDegraded), noDrawLine)
}

func requiredLabels() []string {
	var out []string
	for _, in := range reg.inputs {
		if !in.optional {
			out = append(out, in.label)
		}
	}
	return out
}

// configOf parses the settings object the host sends. Every group's fields
// share one flat namespace, and a connection list is one key in it.
func configOf(raw []byte) map[string]json.RawMessage {
	var cfg map[string]json.RawMessage
	if len(raw) == 0 {
		return nil
	}
	_ = json.Unmarshal(raw, &cfg)
	return cfg
}

func readSettings(cfg map[string]json.RawMessage) {
	for _, g := range reg.groups {
		g.read(cfg)
	}
}
