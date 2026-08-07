package lookout

// Drawing, and the places drawn on.
//
// A plugin describes the whole picture every call. The library compares it with
// the last one: an object with the same id and the same shape is left alone, a
// changed one is replaced, and one that was not drawn this call is taken off the
// chart. There is no delete call and no batch to hold.

import (
	"fmt"
	"math"
)

// NauticalMile is metres in a nautical mile.
const NauticalMile = 1852.0

// MaxObjects is the most objects one plugin's scene may hold. The host's own
// budget is 4096 across every plugin; this is the table the diff keeps.
const MaxObjects = 512

const earthRadiusM = 6371008.8

// NM is a distance in metres from a distance in nautical miles.
func NM(n float64) float64 { return n * NauticalMile }

// Knots is knots from metres per second. Everything crossing the API is SI;
// this is for text a mariner reads.
func Knots(mps float64) float64 { return mps * 1.9438444924406046 }

// ---------------------------------------------------------------------------
// Places
// ---------------------------------------------------------------------------

// Point is a place on the earth. Latitude first, always: the overlay wire
// format puts longitude first and this type is what keeps that out of plugin
// code.
type Point struct {
	Lat float64
	Lon float64
}

// Destination is where you get to on bearingDeg true after distM. A sphere, not
// the ellipsoid the chart is drawn on: the error over 1 nm is under 4 m.
func (p Point) Destination(bearingDeg, distM float64) Point {
	lat1 := p.Lat * math.Pi / 180
	lon1 := p.Lon * math.Pi / 180
	brg := NormalizeDeg(bearingDeg) * math.Pi / 180
	d := distM / earthRadiusM

	sinLat1, cosLat1 := math.Sincos(lat1)
	sinD, cosD := math.Sincos(d)

	sinLat2 := clamp(sinLat1*cosD+cosLat1*sinD*math.Cos(brg), -1, 1)
	lat2 := math.Asin(sinLat2)
	lon2 := lon1 + math.Atan2(math.Sin(brg)*sinD*cosLat1, cosD-sinLat1*sinLat2)
	return Point{
		Lat: lat2 * 180 / math.Pi,
		// Folded, so a leg across the antimeridian does not post a longitude
		// the host would refuse.
		Lon: WrapLon(lon2 * 180 / math.Pi),
	}
}

// BearingTo is the initial great-circle bearing to other, degrees true.
func (p Point) BearingTo(other Point) float64 {
	lat1 := p.Lat * math.Pi / 180
	lat2 := other.Lat * math.Pi / 180
	dlon := WrapLon(other.Lon-p.Lon) * math.Pi / 180
	y := math.Sin(dlon) * math.Cos(lat2)
	x := math.Cos(lat1)*math.Sin(lat2) - math.Sin(lat1)*math.Cos(lat2)*math.Cos(dlon)
	return NormalizeDeg(math.Atan2(y, x) * 180 / math.Pi)
}

// DistanceTo is metres to other, over the same sphere.
func (p Point) DistanceTo(other Point) float64 {
	lat1 := p.Lat * math.Pi / 180
	lat2 := other.Lat * math.Pi / 180
	dlat := lat2 - lat1
	dlon := WrapLon(other.Lon-p.Lon) * math.Pi / 180
	s1 := math.Sin(dlat / 2)
	s2 := math.Sin(dlon / 2)
	h := s1*s1 + math.Cos(lat1)*math.Cos(lat2)*s2*s2
	return 2 * earthRadiusM * math.Asin(math.Sqrt(clamp(h, 0, 1)))
}

// Valid is false for a position off the earth or carrying a NaN. The library
// refuses one before it records it.
func (p Point) Valid() bool {
	return !math.IsNaN(p.Lat) && !math.IsNaN(p.Lon) &&
		!math.IsInf(p.Lat, 0) && !math.IsInf(p.Lon, 0) &&
		math.Abs(p.Lat) <= 90 && math.Abs(p.Lon) <= 180
}

// NormalizeDeg folds a bearing into 0..360.
func NormalizeDeg(deg float64) float64 {
	if math.IsNaN(deg) || math.IsInf(deg, 0) {
		return 0
	}
	r := math.Mod(deg, 360)
	if r < 0 {
		r += 360
	}
	return r
}

// WrapLon folds a longitude into -180..180.
func WrapLon(deg float64) float64 {
	if math.IsNaN(deg) || math.IsInf(deg, 0) {
		return 0
	}
	// Floored, not truncated: math.Mod keeps the sign of the dividend, so
	// -181 would come back as itself rather than as 179.
	r := math.Mod(deg+180, 360)
	if r < 0 {
		r += 360
	}
	return r - 180
}

func clamp(v, lo, hi float64) float64 { return math.Max(lo, math.Min(hi, v)) }

// ---------------------------------------------------------------------------
// What a plugin draws with
// ---------------------------------------------------------------------------

// Color is a palette token. A plugin names a token; the core resolves it per
// day, dusk and night scheme, which is why an overlay never carries an RGB.
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

// Sym is a symbol shape the core draws. SymATON is a physical aid to navigation
// and SymATONVirtual one that exists only as a broadcast.
type Sym string

const (
	SymOwnship     Sym = "ownship"
	SymTarget      Sym = "target"
	SymATON        Sym = "aton"
	SymATONVirtual Sym = "aton_virtual"
)

// Anchor is where an object sits. AnchorOwnship rides own ship's display
// position, which the core carries forward between fixes, so the object does not
// step once a second while the chart slides smoothly.
type Anchor string

const (
	AnchorFixed   Anchor = ""
	AnchorOwnship Anchor = "ownship"
)

// Line is a line's weight, colour and whether it is dashed. WidthPt is screen
// points, not metres: the core converts at the live zoom. A zero WidthPt draws
// at 1.5.
type Line struct {
	Color   Color
	WidthPt float64
	Dash    bool
	Anchor  Anchor
}

// Symbol is a symbol's colour, rotation and size. RotDeg is a true bearing,
// clockwise from north. A zero Scale draws at 1.
type Symbol struct {
	Color  Color
	RotDeg float64
	Scale  float64
	Anchor Anchor
	Pick   *Pick
}

// Area is a filled ring. Alpha multiplies the token's own alpha; a zero Alpha
// draws at 1.
type Area struct {
	Color Color
	Alpha float64
}

// Pick is what the shell shows when the mariner hovers or taps a symbol. The
// values are strings you have already formatted: only the plugin knows the unit.
// Lines and areas carry no payload — there is no single point to measure a tap
// against.
type Pick struct {
	Title string
	Rows  [][2]string
}

// Chart is what a plugin draws on, handed to Draw.
type Chart struct {
	state  State
	detail string
	said   bool
}

// Line draws a line through pts, in order. Two points at least.
func (c *Chart) Line(id string, pts []Point, style Line) {
	if len(pts) < 2 {
		return
	}
	width := style.WidthPt
	if width == 0 {
		width = 1.5
	}
	o := scene.open()
	o.b = append(o.b, `{"id":`...)
	o.b = appendString(o.b, id)
	o.b = append(o.b, `,"kind":"polyline","pts":[`...)
	o.points(pts)
	o.b = append(o.b, `],"width_pt":`...)
	o.b = appendNum(o.b, width)
	o.b = append(o.b, `,"dash":`...)
	o.b = appendBool(o.b, style.Dash)
	o.b = append(o.b, `,"color":`...)
	o.b = appendString(o.b, string(style.Color))
	o.anchor(style.Anchor)
	o.b = append(o.b, '}')
	o.done(id)
}

// Symbol draws a symbol at at.
func (c *Chart) Symbol(id string, sym Sym, at Point, style Symbol) {
	if !at.Valid() {
		return
	}
	scale := style.Scale
	if scale == 0 {
		scale = 1
	}
	o := scene.open()
	o.b = append(o.b, `{"id":`...)
	o.b = appendString(o.b, id)
	o.b = append(o.b, `,"kind":"symbol","sym":`...)
	o.b = appendString(o.b, string(sym))
	o.b = append(o.b, `,"at":[`...)
	o.b = appendNum(o.b, at.Lon)
	o.b = append(o.b, ',')
	o.b = appendNum(o.b, at.Lat)
	o.b = append(o.b, `],"rot_deg":`...)
	o.b = appendNum(o.b, style.RotDeg)
	o.b = append(o.b, `,"scale":`...)
	o.b = appendNum(o.b, scale)
	o.b = append(o.b, `,"color":`...)
	o.b = appendString(o.b, string(style.Color))
	o.anchor(style.Anchor)
	if p := style.Pick; p != nil {
		o.b = append(o.b, `,"pick":{"title":`...)
		o.b = appendString(o.b, p.Title)
		o.b = append(o.b, `,"rows":[`...)
		for i, r := range p.Rows {
			if i > 0 {
				o.b = append(o.b, ',')
			}
			o.b = append(o.b, '[')
			o.b = appendString(o.b, r[0])
			o.b = append(o.b, ',')
			o.b = appendString(o.b, r[1])
			o.b = append(o.b, ']')
		}
		o.b = append(o.b, `]}`...)
	}
	o.b = append(o.b, '}')
	o.done(id)
}

// Area draws a filled area. The ring is closed for you; three points at least.
func (c *Chart) Area(id string, ring []Point, style Area) {
	if len(ring) < 3 {
		return
	}
	alpha := style.Alpha
	if alpha == 0 {
		alpha = 1
	}
	o := scene.open()
	o.b = append(o.b, `{"id":`...)
	o.b = appendString(o.b, id)
	o.b = append(o.b, `,"kind":"polygon","ring":[`...)
	o.points(ring)
	o.b = append(o.b, `],"alpha":`...)
	o.b = appendNum(o.b, alpha)
	o.b = append(o.b, `,"color":`...)
	o.b = appendString(o.b, string(style.Color))
	o.b = append(o.b, '}')
	o.done(id)
}

// Status says the plugin is working, and what it is doing. It is posted once;
// the library sends nothing while the text is unchanged.
func (c *Chart) Status(format string, a ...any) { c.say(StateRunning, format, a...) }

// Degraded says the plugin is short of something. The library adds nothing:
// name the instrument, so a mariner knows which one to look at.
func (c *Chart) Degraded(format string, a ...any) { c.say(StateDegraded, format, a...) }

func (c *Chart) say(s State, format string, a ...any) {
	c.state = s
	if len(a) == 0 {
		c.detail = format
	} else {
		c.detail = fmt.Sprintf(format, a...)
	}
	c.said = true
}

// Scene describes the whole picture now, outside the draw timer, and sends what
// changed. A tier-1 plugin never calls it: the library calls Draw. A tier-3
// plugin with no Draw method uses it to draw when it decides to, and gets the
// same diff and the same deletes.
func Scene(f func(c *Chart)) {
	var c Chart
	scene.begin()
	f(&c)
	scene.commit()
	if c.said {
		sayText(string(c.state), c.detail)
	}
}

// ---------------------------------------------------------------------------
// The retained scene
// ---------------------------------------------------------------------------

var scene sceneState

type sceneEntry struct {
	id   string
	hash uint64
	live bool
	seen bool
}

type sceneState struct {
	entries []sceneEntry
	index   map[string]int

	// The batch, built in place: {"set":[ while Draw runs, then the deletes and
	// the closing brace at commit.
	buf  []byte
	sets int
	// One object is serialized at a time, so the writer is reused rather than
	// allocated per object.
	obj object
}

const scenePrefix = `{"set":[`

func (s *sceneState) begin() {
	for i := range s.entries {
		s.entries[i].seen = false
	}
	s.buf = append(s.buf[:0], scenePrefix...)
	s.sets = 0
}

// object writes one overlay object straight into the batch, so an unchanged
// object costs a serialize and no allocation.
type object struct {
	// start is where this object's separator began and body where the object
	// itself did; an object that has not changed since the last call rewinds
	// both, and leaves no comma behind.
	start, body int
	b           []byte
}

func (s *sceneState) open() *object {
	s.obj = object{start: len(s.buf)}
	if s.sets > 0 {
		s.buf = append(s.buf, ',')
	}
	s.obj.body = len(s.buf)
	s.obj.b = s.buf
	return &s.obj
}

func (o *object) points(pts []Point) {
	for i, p := range pts {
		if i > 0 {
			o.b = append(o.b, ',')
		}
		o.b = append(o.b, '[')
		o.b = appendNum(o.b, p.Lon)
		o.b = append(o.b, ',')
		o.b = appendNum(o.b, p.Lat)
		o.b = append(o.b, ']')
	}
}

func (o *object) anchor(a Anchor) {
	if a == AnchorOwnship {
		o.b = append(o.b, `,"anchor":"ownship"`...)
	}
}

// done closes the object and hands it to the diff.
func (o *object) done(id string) { scene.take(id, o) }

// fnv1a hashes one serialized object. It is written out rather than taken from
// hash/fnv so that the diff allocates nothing per object.
func fnv1a(b []byte) uint64 {
	var h uint64 = 14695981039346656037
	for _, c := range b {
		h ^= uint64(c)
		h *= 1099511628211
	}
	return h
}

func (s *sceneState) take(id string, o *object) {
	s.buf = o.b
	sum := fnv1a(s.buf[o.body:])

	if s.index == nil {
		s.index = map[string]int{}
	}
	if i, ok := s.index[id]; ok {
		e := &s.entries[i]
		e.seen = true
		if e.live && e.hash == sum {
			// Already on the chart, and the same shape.
			s.buf = s.buf[:o.start]
			return
		}
		e.hash = sum
		e.live = true
		s.sets++
		return
	}
	if len(s.entries) == MaxObjects {
		s.buf = s.buf[:o.start]
		Log(Warn, "overlay: more than %d objects; %q dropped", MaxObjects, id)
		return
	}
	s.index[id] = len(s.entries)
	s.entries = append(s.entries, sceneEntry{id: id, hash: sum, live: true, seen: true})
	s.sets++
}

// commit sends what changed and deletes what this call did not draw.
func (s *sceneState) commit() {
	dels := 0
	for i := range s.entries {
		if s.entries[i].live && !s.entries[i].seen {
			dels++
		}
	}
	if s.sets == 0 && dels == 0 {
		return
	}

	s.buf = append(s.buf, `],"del":[`...)
	k := 0
	for i := range s.entries {
		e := &s.entries[i]
		if !e.live || e.seen {
			continue
		}
		if k > 0 {
			s.buf = append(s.buf, ',')
		}
		k++
		s.buf = appendString(s.buf, e.id)
	}
	s.buf = append(s.buf, `]}`...)

	if OverlayJSON(s.buf) < 0 {
		// The host refused the batch, so what is on the chart no longer matches
		// the table. Forget it; the next call redraws in full.
		s.forget()
		return
	}
	// An object deleted this call leaves the table.
	kept := s.entries[:0]
	for _, e := range s.entries {
		if e.live && e.seen {
			kept = append(kept, e)
		}
	}
	s.entries = kept
	s.index = make(map[string]int, len(s.entries))
	for i, e := range s.entries {
		s.index[e.id] = i
	}
}

// forget drops every memory of what is drawn. The next call sends the whole
// scene again.
func (s *sceneState) forget() {
	s.entries = s.entries[:0]
	s.index = map[string]int{}
	s.buf = s.buf[:0]
	s.sets = 0
}
