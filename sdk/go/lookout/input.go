package lookout

// Inputs: what a plugin reads off the boat.
//
// Declare each one as a package-level variable. The library subscribes at
// start, records one value per input, ages it against the monotonic clock, and
// holds Draw back while a required input is missing or stale.
//
//	var (
//		boat = lk.SubscribePosition("navigation.position")
//		twd  = lk.SubscribeNumber("environment.wind.directionTrue", lk.InputOpts{Label: "wind"})
//	)

import (
	"math"
	"strings"
	"time"
)

// DefaultMaxAge is how old a reading may be and still count. One 5 s window
// rules all vessel data; the store and every shipped plugin use the same number.
const DefaultMaxAge = 5 * time.Second

// InputOpts is how one declared input behaves.
type InputOpts struct {
	// Label is what the status line calls this reading when it is missing:
	// "no wind". It defaults to the last segment of the path.
	Label string
	// MaxAge overrides DefaultMaxAge, for a reading that arrives on a slower
	// clock.
	MaxAge time.Duration
	// Optional keeps this input out of the freshness gate and out of the status
	// line. Read it with Fresh and decide yourself; Get answers the last value
	// whether or not it is stale.
	Optional bool
}

// input is the state behind every declared input: the value, and enough to age
// it between events. The host stamps AgeMs at delivery and the monotonic clock
// carries it on from there.
type input struct {
	path     string
	label    string
	maxAge   int64
	optional bool
	position bool

	have   bool
	atMono int64
	ageAt  int64
	num    float64
	pos    Point
}

// Path is the vessel path this input subscribed to.
func (i *input) Path() string { return i.path }

// Label is what the status line calls this reading.
func (i *input) Label() string { return i.label }

// Age is how old the value is, and false when there is none.
func (i *input) Age() (time.Duration, bool) {
	if !i.have {
		return 0, false
	}
	return time.Duration(i.ageMs(MonoMs())) * time.Millisecond, true
}

func (i *input) ageMs(mono int64) int64 { return i.ageAt + (mono - i.atMono) }

func (i *input) freshAt(mono int64) bool { return i.have && i.ageMs(mono) <= i.maxAge }

// staleAt is the monotonic moment this value stops counting, and false when it
// already has. The window is known the moment the reading lands, so its expiry
// is an appointment rather than something to poll for.
func (i *input) staleAt(mono int64) (int64, bool) {
	if !i.have {
		return 0, false
	}
	at := i.atMono + i.maxAge - i.ageAt
	if at <= mono {
		return 0, false
	}
	return at, true
}

func (i *input) stamp(ageMs, mono int64) {
	i.have = true
	i.atMono = mono
	if ageMs > 0 {
		i.ageAt = ageMs
	} else {
		i.ageAt = 0
	}
}

func (i *input) record(r Reading, mono int64) {
	// A null value means the path has no source left. Treat it as removal: the
	// reading is gone, not zero.
	if r.Removed() {
		i.have = false
		return
	}
	if i.position {
		at, ok := r.Position()
		if !ok || !at.Valid() {
			return
		}
		i.pos = at
		i.stamp(r.AgeMs, mono)
		return
	}
	v, ok := r.Number()
	if !ok || math.IsNaN(v) || math.IsInf(v, 0) {
		return
	}
	i.num = v
	i.stamp(r.AgeMs, mono)
}

func newInput(path string, position bool, opts []InputOpts) input {
	var o InputOpts
	if len(opts) > 0 {
		o = opts[0]
	}
	if len(opts) > 1 {
		noteWiring("input " + path + ": more than one InputOpts; the first is used")
	}
	label := o.Label
	if label == "" {
		label = lastSegment(path)
	}
	maxAge := o.MaxAge
	if maxAge == 0 {
		maxAge = DefaultMaxAge
	}
	return input{
		path:     path,
		label:    label,
		maxAge:   maxAge.Milliseconds(),
		optional: o.Optional,
		position: position,
	}
}

func lastSegment(path string) string {
	if i := strings.LastIndexByte(path, '.'); i >= 0 {
		return path[i+1:]
	}
	return path
}

// NumberInput is a number off the vessel store: a speed, a depth, a wind
// direction.
type NumberInput struct{ input }

// SubscribeNumber declares a numeric input. Call it from a package-level variable, so it
// is registered before the host starts the plugin. Pass at most one InputOpts.
func SubscribeNumber(path string, opts ...InputOpts) *NumberInput {
	n := &NumberInput{input: newInput(path, false, opts)}
	register(&n.input)
	return n
}

// Get is the value. A required input is fresh whenever Draw runs, so Draw needs
// no check. Outside Draw, and for an optional input, use Fresh.
func (n *NumberInput) Get() float64 { return n.num }

// Fresh is the value, and false when nothing has arrived or what arrived is
// older than the window. Safe anywhere, at any time.
func (n *NumberInput) Fresh() (float64, bool) {
	if !n.freshAt(MonoMs()) {
		return 0, false
	}
	return n.num, true
}

// PositionInput is a position off the vessel store.
type PositionInput struct{ input }

// SubscribePosition declares a position input. Pass at most one InputOpts.
func SubscribePosition(path string, opts ...InputOpts) *PositionInput {
	p := &PositionInput{input: newInput(path, true, opts)}
	register(&p.input)
	return p
}

// Get is the value. A required input is fresh whenever Draw runs, so Draw needs
// no check. Outside Draw, and for an optional input, use Fresh.
func (p *PositionInput) Get() Point { return p.pos }

// Fresh is the value, and false when nothing has arrived or what arrived is
// older than the window.
func (p *PositionInput) Fresh() (Point, bool) {
	if !p.freshAt(MonoMs()) {
		return Point{}, false
	}
	return p.pos, true
}

// ---------------------------------------------------------------------------
// AIS traffic
// ---------------------------------------------------------------------------

// DefaultAISMaxAge is how long a vessel's report stays interesting, and
// DefaultAtonMaxAge the same for an aid to navigation. Both match the host's
// eviction clocks: past them the target is out of the store and no snapshot can
// carry it again.
const (
	DefaultAISMaxAge  = 600 * time.Second
	DefaultAtonMaxAge = 1800 * time.Second
)

// AISOpts is how the target set behaves.
type AISOpts struct {
	// Max is the most targets kept. A snapshot longer than this is truncated
	// and logged. It defaults to 128.
	Max int
	// MaxAge is how long a vessel's report stays interesting. Past it the
	// target can no longer change anything the plugin decides, so the library
	// stops waking for it. Set it to the age at which this plugin drops a
	// target.
	MaxAge time.Duration
	// AtonMaxAge is the same, for an aid to navigation. An aid reports about
	// every three minutes, so a vessel's window would age one out while it is
	// still on station.
	AtonMaxAge time.Duration
}

// AISInput is the AIS target set, recorded and aged by the library. Declare it
// beside the vessel inputs; it never holds Draw back, because an empty sea is
// not a missing instrument.
type AISInput struct {
	max        int
	maxAge     int64
	atonMaxAge int64
	list       []Target
	atMono     int64
}

// SubscribeAIS declares the AIS target set. The library subscribes at start.
func SubscribeAIS(opts ...AISOpts) *AISInput {
	var o AISOpts
	if len(opts) > 0 {
		o = opts[0]
	}
	max := 128
	if o.Max > 0 {
		max = o.Max
	}
	maxAge := o.MaxAge
	if maxAge == 0 {
		maxAge = DefaultAISMaxAge
	}
	atonMaxAge := o.AtonMaxAge
	if atonMaxAge == 0 {
		atonMaxAge = DefaultAtonMaxAge
	}
	a := &AISInput{max: max, maxAge: maxAge.Milliseconds(), atonMaxAge: atonMaxAge.Milliseconds()}
	registerAIS(a)
	return a
}

// staleAt is when the next target in the set ages out, and false when none can.
// Each target keeps its own clock, so the set produces one appointment per
// target rather than one for the snapshot.
func (a *AISInput) staleAt(mono int64) (int64, bool) {
	next := int64(0)
	found := false
	for i := range a.list {
		window := a.maxAge
		if a.list[i].ATON {
			window = a.atonMaxAge
		}
		at := a.atMono + window - a.list[i].AgeMs
		if at <= mono {
			continue
		}
		if !found || at < next {
			next = at
			found = true
		}
	}
	return next, found
}

// Targets is every target in the last snapshot, aged to now.
func (a *AISInput) Targets() []Target {
	carried := MonoMs() - a.atMono
	for i := range a.list {
		a.list[i].AgeMs += carried
	}
	a.atMono += carried
	return a.list
}

// Find is the target with this MMSI, or nil.
func (a *AISInput) Find(mmsi uint32) *Target {
	for i := range a.list {
		if a.list[i].MMSI == mmsi {
			return &a.list[i]
		}
	}
	return nil
}

func (a *AISInput) record(e Event, mono int64) {
	in := e.Targets()
	if len(in) > a.max {
		Log(Warn, "ais: %d targets, keeping %d", len(in), a.max)
		in = in[:a.max]
	}
	a.list = append(a.list[:0], in...)
	a.atMono = mono
}
