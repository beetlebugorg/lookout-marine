# The Go entry points

The canonical listings for the Go SDK, for the plugin guide to use as they
stand. Every complete listing here was compiled against `sdk/go/lookout` for
`wasip1` before it was written down; the signature blocks are copied from the
source. Copy them verbatim; if one needs a change, change it here first so the
SDK and the page cannot drift.

Import path and alias, used everywhere:

```go
import lk "github.com/beetlebugorg/lookout-marine/sdk/go/lookout"
```

Build, from the plugin's own directory. Go 1.24 or later, because the module
needs `go:wasmexport`:

```sh
GOOS=wasip1 GOARCH=wasm go build -buildmode=c-shared -o org.example.windline.go.wasm .
cp org.example.windline.go.wasm zig-out/plugins/
cp manifest.json zig-out/plugins/org.example.windline.go.manifest.json
```

## Registration

```go
func init() { lk.Register(&windline{}) }
func main() {}
```

`Register` takes any value. Call it from `init` or a package-level variable: a
reactor module never runs `main`, and package main still needs an empty one to
compile.

## Tier 1 — a drawing plugin

The whole plugin. This is `sdk/go/examples/windline/main.go`.

```go
package main

import lk "github.com/beetlebugorg/lookout-marine/sdk/go/lookout"

var (
	boat = lk.SubscribePosition("navigation.position")
	twd  = lk.SubscribeNumber("environment.wind.directionTrue", lk.InputOpts{Label: "wind"})
)

type windline struct{}

// Registration happens here because a reactor module never runs main.
func init() { lk.Register(&windline{}) }

func main() {}

func (p *windline) Draw(c *lk.Chart) {
	from := boat.Get()
	// The wind direction is where the wind blows FROM, so downwind is the
	// reciprocal.
	to := from.Destination(twd.Get()+180, lk.NM(1))
	c.Line("windline", []lk.Point{from, to}, lk.Line{Color: lk.ColorWarning, Dash: true})
}
```

## Inputs

Declared as package-level variables, so they are registered before the host
starts the plugin.

```go
func lk.SubscribeNumber(path string, opts ...lk.InputOpts) *lk.NumberInput
func lk.SubscribePosition(path string, opts ...lk.InputOpts) *lk.PositionInput
func lk.SubscribeAIS(opts ...lk.AISOpts) *lk.AISInput

type lk.InputOpts struct {
	Label    string        // what the status line calls it; default: the last path segment
	MaxAge   time.Duration // default lk.DefaultMaxAge, 5 s
	Optional bool          // out of the freshness gate and out of the status line
}

func (n *lk.NumberInput) Get() float64            // inside Draw, always fresh
func (n *lk.NumberInput) Fresh() (float64, bool)  // anywhere
func (p *lk.PositionInput) Get() lk.Point
func (p *lk.PositionInput) Fresh() (lk.Point, bool)
func (i *lk.NumberInput) Age() (time.Duration, bool)

func (a *lk.AISInput) Targets() []lk.Target
func (a *lk.AISInput) Find(mmsi uint32) *lk.Target
```

`Draw` runs only when every required input is inside its window. Otherwise the
library clears the scene and posts one line naming all of them: `no position, no
wind`. An optional input never gates the draw, and `Get` on one answers the last
value whether or not it is stale — read it with `Fresh`.

## Drawing

```go
func (c *lk.Chart) Line(id string, pts []lk.Point, style lk.Line)
func (c *lk.Chart) Symbol(id string, sym lk.Sym, at lk.Point, style lk.Symbol)
func (c *lk.Chart) Area(id string, ring []lk.Point, style lk.Area)
func (c *lk.Chart) Status(format string, a ...any)
func (c *lk.Chart) Degraded(format string, a ...any)

type lk.Line struct {
	Color   lk.Color
	WidthPt float64 // zero draws at 1.5
	Dash    bool
	Anchor  lk.Anchor // lk.AnchorOwnship rides own ship's display position
}

type lk.Symbol struct {
	Color  lk.Color
	RotDeg float64 // a true bearing, clockwise from north
	Scale  float64 // zero draws at 1
	Anchor lk.Anchor
	Pick   *lk.Pick // title and rows the shell shows on hover or tap
}

type lk.Area struct {
	Color lk.Color
	Alpha float64 // zero draws at 1
}
```

Describe the whole picture every call. An object with the same id and the same
shape is left alone, a changed one is replaced, and one that was not drawn this
call is taken off the chart.

Geometry, on `lk.Point{Lat, Lon}`:

```go
func (p lk.Point) Destination(bearingDeg, distM float64) lk.Point
func (p lk.Point) BearingTo(other lk.Point) float64
func (p lk.Point) DistanceTo(other lk.Point) float64
func (p lk.Point) Valid() bool
func lk.NM(n float64) float64      // nautical miles to metres
func lk.Knots(mps float64) float64
```

## Settings

A field named `Settings`, whose own fields carry their metadata as struct tags.
The library fills it in before `OnStart`, again on every change, and then
redraws.

```go
type guard struct {
	Settings struct {
		RangeNM float64 `lk:"range_nm" label:"Guard ring" desc:"How far out the ring sits." unit:"nm" min:"0.25" max:"6" default:"1"`
		Alarm   bool    `lk:"alarm" label:"Sound the alarm" default:"true"`
	} `label:"Guard ring" tab:"alarms"`
}

var boat = lk.SubscribePosition("navigation.position")

func (p *guard) Draw(c *lk.Chart) {
	ring := make([]lk.Point, 0, 60)
	for deg := 0; deg < 360; deg += 6 {
		ring = append(ring, boat.Get().Destination(float64(deg), lk.NM(p.Settings.RangeNM)))
	}
	c.Area("guard", ring, lk.Area{Color: lk.ColorWarning, Alpha: 0.2})
}

// OnSettings runs after a change, before the redraw.
func (p *guard) OnSettings() {
	lk.Log(lk.Info, "guard ring at %g nm", p.Settings.RangeNM)
}
```

The tags:

| Tag | On | Meaning |
|---|---|---|
| `lk:"key"` | every field | the config key. A field without it is a mistake and the start says so. |
| `label:"…"` | every field | what the mariner reads. Required. |
| `desc:"…"` | every field | the line under the control. |
| `unit:"…"` | a number | shown beside the control. The value crosses the API in that unit. |
| `min:"…"` `max:"…"` `default:"…"` | a number | required. A value outside the range is clamped before the plugin sees it. |
| `default:"true"` | a bool | required. |
| `label:"…"` `tab:"…"` | the `Settings` field | the group heading, and where it appears. Tabs: `display`, `depths`, `text`, `charts`, `vessels`, `alarms`, `connections`, `advanced`. |

A field is a `float64`, an `int` or a `bool`. A string is legal only as a
connection column: the host keeps no scalar string. For more than one group,
give `Settings` a struct field per group, each with its own `label` and `tab`.

The same declaration generates the manifest's `settings` object, and a plain
`go test` on your machine checks that the manifest you ship says the same thing:

```go
//go:embed manifest.json
var manifest []byte

func TestManifest(t *testing.T) {
	if err := lk.CheckManifest(manifest, &guard{}); err != nil {
		t.Fatal(err)
	}
}
```

`lk.SettingsJSON(&guard{})` prints the block to paste into `manifest.json`. Pass
every connection list too: `lk.CheckManifest(manifest, &source{}, servers)`.

## Tier 2 — connections

The library owns the sockets, the reconnect clock, the pause switch, the per-row
status items and the list's settings schema. The plugin writes `OnData`.

```go
// One connection: the columns the mariner fills in, and the state the parser
// keeps between reads. An exported field with an lk tag is a column;
// everything else is yours.
type feed struct {
	WebSocket bool `lk:"websocket" label:"WebSocket" desc:"Read the WebSocket stream instead of the plain one." default:"false"`

	partial string
}

var servers = lk.Connections(lk.ConnOpts{
	Key:      "servers",
	Group:    "Signal K servers",
	AddLabel: "Add Server",
	RateNoun: "deltas",
	Columns: lk.RowColumns{
		Port: lk.NumSpec{Label: "Port", Desc: "Most servers stream on 8375.", Min: 1, Max: 65535, Default: 8375},
	},
	State:       func() any { return &feed{} },
	StatusEmpty: "no servers",
})

type source struct{}

func init() { lk.Register(&source{}) }
func main() {}

// OnData is bytes from one connection's socket, in whatever sizes they
// arrived.
func (p *source) OnData(conn *lk.Conn, data []byte) {
	s := conn.State.(*feed)
	s.partial += string(data)
	pub := lk.NewPublish()
	for {
		i := strings.IndexByte(s.partial, '\n')
		if i < 0 {
			break
		}
		line := s.partial[:i]
		s.partial = s.partial[i+1:]
		conn.Count(1)
		if sog, ok := parseSOG(line); ok {
			pub.Number("navigation.speedOverGround", sog)
		}
	}
	pub.Send()
}

// OnOpen: a stream came up. Send the subscription here.
func (p *source) OnOpen(conn *lk.Conn) { conn.Send([]byte("subscribe\n")) }

// Endpoint: where to dial, when it is not the connection's host and port.
func (p *source) Endpoint(conn *lk.Conn) lk.Endpoint {
	if conn.State.(*feed).WebSocket {
		return lk.WSEndpoint("ws://" + conn.Host + "/signalk/v1/stream")
	}
	return lk.TCPEndpoint(conn.Host, conn.Port)
}
```

What a connection carries and what it answers:

```go
type lk.Conn struct {
	ID      string // the shell's id. It survives an edit.
	Name    string // what the mariner calls it; may be empty
	Host    string
	Port    uint16
	Enabled bool // false means PAUSED
	State   any  // what ConnOpts.State returned
}

func (conn *lk.Conn) Label() string     // the name, or the address
func (conn *lk.Conn) Connected() bool
func (conn *lk.Conn) Rate() uint64      // what Count counted, per second
func (conn *lk.Conn) Send(data []byte) int32
func (conn *lk.Conn) Count(n uint64)
func (conn *lk.Conn) SetDetail(format string, a ...any)

func (c *lk.Conns) All() []*lk.Conn
func (c *lk.Conns) ByID(id string) *lk.Conn

func lk.TCPEndpoint(host string, port uint16) lk.Endpoint
func lk.WSEndpoint(url string) lk.Endpoint
func lk.RefusedEndpoint(why string) lk.Endpoint
```

Connections are matched by id: editing one never disturbs another. Only an
address change, a column change, a pause or a delete closes a socket.

Publishing, from `OnData`:

```go
pub := lk.NewPublish()
pub.Number("navigation.speedOverGround", mps)          // SI, always
pub.Position("navigation.position", lk.Point{Lat: lat, Lon: lon})
pub.Clear("environment.wind.speedTrue")                // held, and nothing to report
pub.Send()

up := lk.NewUpsert()
up.Target(lk.Target{MMSI: mmsi, Lat: &lat, Lon: &lon, SOG: &sog})
up.Send()
```

## Every method a plugin may implement

`Register` takes any value and finds these by type assertion. All are optional,
and one that is absent is not wired.

| Method | What it is |
|---|---|
| `Draw(*lk.Chart)` | the scene, on the library's timer |
| `DrawRate() time.Duration` | how often, default 1 s |
| `OnUpdate()` | after an input changed: the decision, and the rows |
| `OnSettings()` | after a settings change, before the redraw |
| `OnData(*lk.Conn, []byte)` | bytes from one connection's socket |
| `OnOpen(*lk.Conn)` | a stream came up; send a subscription |
| `OnClose(*lk.Conn)` | a stream ended |
| `ConnNote(*lk.Conn) string` | a phrase after the connection's rate |
| `Endpoint(*lk.Conn) lk.Endpoint` | where to dial, when it is not host:port |
| `OnStart(lk.Start) error` | anything else at startup |
| `OnEvent(lk.Event) error` | every event the library did not consume |
| `OnShutdown()` | the last word |

A method with the wrong signature does not satisfy the interface, so the library
looks for `Draw` and `OnData` by name at registration and logs the mismatch. A
plugin with none of `Draw`, `OnUpdate`, `OnData`, `OnEvent` and `OnStart` is
refused at `lk_start` rather than started to do nothing, and so is one that
declares a table with no `OnUpdate` to fill it.

## Tables

A table is a dialog the shell builds from the declaration. Declare one as a
package-level variable, the way an input is declared, and the library tells the
host about it at `lk_start`.

```go
var targets = lk.NewTable(lk.TableOpts{
	Key: "targets", Title: "AIS Targets", Menu: "Vessels",
	Columns: []lk.Column{
		{Key: "name", Label: "Vessel", Type: lk.ColText},
		{Key: "cpa", Label: "CPA", Type: lk.ColDistance},
		{Key: "state", Type: lk.ColFlag},
	},
	Sort: &lk.TableSort{Key: "cpa", Ascending: true},
	At:   &lk.TableAt{Lat: "lat", Lon: "lon"},
})

func (p *ais) OnUpdate() {
	if !targets.IsOpen() {
		return
	}
	r := targets.Row("899000101")
	r.Band(0)
	r.Cell("name", "ANNE")
	r.Cell("cpa", 124.0)
	r.At(lk.Point{Lat: 38.97, Lon: -76.46})
	r.Done()
}
```

The rows are written from `OnUpdate` and nowhere else: the library opens a
cycle before that call and sends what changed after it. A row the cycle does
not describe leaves the table. `lk.TablesJSON(targets)` renders the `"tables"`
array the manifest must carry, for a `go test` to compare.

`Cell` takes any value and reads the declared column type to decide how to
write it. A `nil`, or a nil `*float64`, `*string` or `*bool`, is a dash. A value
the column cannot hold is a dash too, and one log line.

## The chart grant

The library reads `GRANTS_CHANGED` and follows `overlay.draw`. When the grant
goes it cancels the draw timer, forgets the scene diff and posts one status line
saying why the chart is empty; when it comes back it arms the timer and sends
the whole scene again. `OnUpdate` and the tables carry on throughout: a table
costs no capability.

`e.Granted("overlay.draw")` reads the payload, for a tier-3 plugin that handles
the event itself.

## Tier 3 — the raw layer

`OnEvent(e lk.Event) error` receives everything the library did not consume:
`lk.Timer`, `lk.TCPData`, `lk.WSData`, `lk.HTTPResponded`, `lk.FileOpened` and
the rest. `e.Kind` is the kind, `e.Handle` correlates, `e.Payload` belongs to the
host until the call returns. The parsers hang off the event —`e.Readings()`,
`e.Targets()`, `e.Response()`, `e.File()` — and the host calls are package
functions: `lk.TCPConnect`, `lk.TimerSet`, `lk.HTTPFetch`, `lk.StorageGet`,
`lk.SubscribePaths`, `lk.Alert`.

A raw plugin that draws calls `lk.Scene(func(c *lk.Chart) { … })`, which
gives it the same retained scene and the same deletes as `Draw`.

## What Go does not do that Zig does

Facts for the page, so it does not promise more than the SDK gives:

- `Get` on an optional input is a compile error in Zig. Go has no way to say
  that, so it answers the last value and the doc points at `Fresh`.
- Zig checks the manifest against the schema at `zig build test`. Go checks it
  in `go test`, which the plugin author runs; nothing in `zig build` reaches a
  Go plugin.
- Zig's scene is a 64 KiB fixed buffer and 512 objects. Go's is 512 objects and
  a slice that grows, so a scene too large for Zig still goes out from Go.
- Zig holds 8 connection rows. Go holds as many as the mariner adds.
