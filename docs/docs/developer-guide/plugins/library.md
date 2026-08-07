---
id: library
title: The plugin library
sidebar_position: 3.5
---

import Tabs from '@theme/Tabs';
import TabItem from '@theme/TabItem';

# The plugin library

A plugin declares what it reads off the boat and describes what it draws. The
library owns everything between those two: the subscription, the ageing, the
timer, the difference between this scene and the last, the status line, the
settings and the connections.

There are three tiers. Tier 1 is a declaration of inputs and a `draw` function.
Tier 2 adds a connection list, where the library holds the sockets and the
plugin writes the parser. Tier 3 is one hook that receives every event the
first two did not consume.

Zig is where the API is decided. `plugins/common/lk2.zig` is the library, and
its doc comments are the authority when this page and the code disagree. The Go
and Rust libraries implement the same three tiers under the same names in each
language's idiom.

This page is the reference. [Recipes](recipes.md) is the same surface arranged
by what you are trying to do, and
[Build your first plugin](build-your-first.md) walks one plugin from an empty
directory to a chart with a line on it.

## The entry points

Four declarations. Everything further down this page is detail on one of them.
Each listing below is a whole module: there is no setup step, no event loop and
no teardown to write.

### Registering the plugin

<Tabs groupId="plugin-language">
<TabItem value="zig" label="Zig" default>

```zig
const lk = @import("lk2");

comptime {
    lk.plugin(@This());
}
```

</TabItem>
<TabItem value="go" label="Go">

```go
package main

import lk "github.com/beetlebugorg/lookout-marine/sdk/go/lookout"

type windline struct{}

// Registration happens here because a reactor module never runs main.
func init() { lk.Register(&windline{}) }

func main() {}
```

</TabItem>
<TabItem value="rust" label="Rust">

```rust
use lookout as lk;

#[derive(Default)]
struct Windline;

lk::plugin!(Windline);

impl lk::Plugin for Windline {}
```

</TabItem>
</Tabs>

`lk.plugin` registers your plugin. It reads what the module declares and wires
only that, so a module with nothing else registers, starts and does nothing.
Add any of the three declarations below and the library wires that as well.

In Go, register from `init` or from a package-level variable. `main` never
runs, and package `main` still needs an empty one to compile. In Rust the
instance is built with `Default` on the first call into the module.

### Drawing the scene

<Tabs groupId="plugin-language">
<TabItem value="zig" label="Zig" default>

```zig
const lk = @import("lk2");

comptime {
    lk.plugin(@This());
}

pub const inputs = struct {
    pub const boat = lk.position("navigation.position", .{});
    pub const twd = lk.number("environment.wind.directionTrue", .{ .label = "wind" });
};

pub fn draw(c: *lk.Chart) void {
    const from = inputs.boat.get();
    // The wind direction is where the wind blows FROM, so downwind is the
    // reciprocal.
    const to = from.destination(inputs.twd.get() + 180, lk.nm(1));
    c.line("windline", &.{ from, to }, .{ .color = .warning, .dash = true });
}
```

</TabItem>
<TabItem value="go" label="Go">

```go
package main

import lk "github.com/beetlebugorg/lookout-marine/sdk/go/lookout"

var (
	boat = lk.Position("navigation.position")
	twd  = lk.Number("environment.wind.directionTrue", lk.InputOpts{Label: "wind"})
)

type windline struct{}

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

</TabItem>
<TabItem value="rust" label="Rust">

```rust
use lookout as lk;

struct Windline {
    boat: lk::Position,
    twd: lk::Number,
}

impl Default for Windline {
    fn default() -> Self {
        Windline {
            boat: lk::Position::new("navigation.position"),
            twd: lk::Number::new("environment.wind.directionTrue").label("wind"),
        }
    }
}

lk::plugin!(Windline);

impl lk::Plugin for Windline {
    fn inputs(&mut self) -> Vec<&mut dyn lk::AnyInput> {
        vec![&mut self.boat, &mut self.twd]
    }

    fn draw(&mut self, c: &mut lk::Chart<'_>) {
        let from = self.boat.get();
        // The wind direction is where the wind blows FROM, so downwind is the
        // reciprocal.
        let to = from.destination(self.twd.get() + 180.0, lk::nm(1.0));
        c.line(
            "windline",
            &[from, to],
            lk::Line::new(lk::Color::Warning).dashed(),
        );
    }
}
```

</TabItem>
</Tabs>

That is a complete plugin. The library subscribes to both paths, records and
ages what arrives, runs `draw` once a second, and sends the difference between
this scene and the last. When either reading passes its 5 s window the line
comes off the chart and the status reads `no position, no wind`.

The same plugin is in the tree three times: `plugins/windline/`,
`sdk/go/examples/windline/` and `sdk/rust/examples/windline/`.

### Handling one connection's bytes

<Tabs groupId="plugin-language">
<TabItem value="zig" label="Zig" default>

```zig
const lk = @import("lk2");

comptime {
    lk.plugin(@This());
}

pub const Connections = lk.connections(.{
    .key = "servers",
    .group = "Signal K servers",
    .add_label = "Add Server",
    .status_empty = "no servers",
    .rate_noun = "delta",
    .Extra = struct {
        websocket: lk.Flag = .{
            .label = "WebSocket",
            .desc = "Connect with a websocket instead of a plain TCP stream.",
            .default = false,
        },
    },
    // Per-row parse state: the partial line.
    .State = struct { partial: lk.Str(512) = .{} },
});

/// The bytes off one row's socket.
pub fn onData(row: *Connections.Row, bytes: []const u8) void {
    row.state.partial.append(bytes);
    row.count(1);
}
```

</TabItem>
<TabItem value="go" label="Go">

```go
package main

import lk "github.com/beetlebugorg/lookout-marine/sdk/go/lookout"

// One row: the plugin's extra columns, and the state its parser keeps.
type feed struct {
	WebSocket bool `lk:"websocket" label:"WebSocket" desc:"Connect with a websocket instead of a plain TCP stream." default:"false"`

	partial []byte
}

var servers = lk.Connections(lk.ConnOpts{
	Key:         "servers",
	Group:       "Signal K servers",
	AddLabel:    "Add Server",
	StatusEmpty: "no servers",
	RateNoun:    "delta",
	Row:         func() any { return &feed{} },
})

type signalK struct{}

func init() { lk.Register(&signalK{}) }

func main() {}

// OnData is the bytes off one row's socket.
func (p *signalK) OnData(row *lk.Row, data []byte) {
	s := row.State.(*feed)
	s.partial = append(s.partial, data...)
	row.Count(1)
}
```

</TabItem>
<TabItem value="rust" label="Rust">

```rust
use lookout as lk;

lk::columns! {
    pub struct SkColumns {
        websocket: Flag {
            label: "WebSocket",
            desc: "Connect with a websocket instead of a plain TCP stream.",
            default: false,
        },
    }
}

struct Servers;

impl lk::ConnSpec for Servers {
    type Columns = SkColumns;       // beyond the four every list carries
    type State = Vec<u8>;           // per-row parse state: the partial line
    const OPTS: lk::ConnOpts = lk::ConnOpts {
        key: "servers",
        group: "Signal K servers",
        add_label: "Add Server",
        status_empty: "no servers",
        rate_noun: "delta",
        ..lk::ConnOpts::DEFAULT
    };
}

#[derive(Default)]
struct SignalK;

lk::plugin!(SignalK, connections: Servers);

impl lk::Plugin for SignalK {
    // It publishes and draws nothing, so it asks for no draw timer.
    const DRAW_RATE_MS: i64 = 0;
}

impl lk::Source<Servers> for SignalK {
    /// The bytes off one row's socket.
    fn on_data(&mut self, row: &mut lk::Row<Servers>, bytes: &[u8]) {
        row.state.extend_from_slice(bytes);
        row.count(1);
    }
}
```

</TabItem>
</Tabs>

A connection list is a group of rows in the settings window that the mariner
fills in and switches on and off. The library gives each row a socket, a
reconnect clock, a pause switch and a line of its own in the settings window.
The plugin writes the protocol.

Every row carries four columns the library owns: the name, the address, the
port and the on switch. The `websocket` column above is the plugin's own, and
so is the parse state each row keeps between reads.

### Handling the rest of the events

<Tabs groupId="plugin-language">
<TabItem value="zig" label="Zig" default>

```zig
const lk = @import("lk2");

comptime {
    lk.plugin(@This());
}

/// Every event the library did not consume.
pub fn onEvent(e: lk.raw.Event) !void {
    switch (e) {
        .http_response => |r| lk.log(.info, "{d}, {d} bytes", .{ r.status, r.body.len }),
        else => {},
    }
}
```

</TabItem>
<TabItem value="go" label="Go">

```go
package main

import lk "github.com/beetlebugorg/lookout-marine/sdk/go/lookout"

type probe struct{}

func init() { lk.Register(&probe{}) }

func main() {}

// OnEvent is every event the library did not consume.
func (p *probe) OnEvent(e lk.Event) error {
	if e.Kind == lk.HTTPResponded {
		r := e.Response()
		lk.Log(lk.Info, "%d, %d bytes", r.Status, len(r.Body))
	}
	return nil
}
```

</TabItem>
<TabItem value="rust" label="Rust">

```rust
use lookout as lk;

#[derive(Default)]
struct Probe;

lk::plugin!(Probe);

impl lk::Plugin for Probe {
    /// Every event the library did not consume.
    fn on_event(&mut self, e: &lk::raw::Event<'_>) -> lk::Result {
        if let lk::raw::Event::HttpResponse(r) = e {
            lk::log!(lk::Level::Info, "{}, {} bytes", r.status, r.body.len());
        }
        Ok(())
    }
}
```

</TabItem>
</Tabs>

This hook is tier 3. A plugin that also declares inputs, `draw` or a connection
list still gets it, and receives only what the library left over — so a
drawing plugin can answer an HTTP response without giving up the scene diff.
[Where the library stops](#where-the-library-stops) says what is behind it.

## The names in Zig, Go and Rust

| What it does | Zig | Go | Rust |
|---|---|---|---|
| Register | `lk.plugin(@This())` | `lk.Register(&p{})` | `lk::plugin!(P)` |
| A number input | `lk.number(path, .{})` | `lk.Number(path)` | `lk::Number::new(path)` |
| A position input | `lk.position(path, .{})` | `lk.Position(path)` | `lk::Position::new(path)` |
| The AIS set | `lk.ais(.{})` | `lk.AIS()` | `lk::Ais::new(max)` |
| Read a value | `in.get()`, `in.fresh()` | `in.Get()`, `in.Fresh()` | `in.get()`, `in.fresh()` |
| The draw hook | `pub fn draw(c)` | `Draw(*lk.Chart)` | `fn draw(&mut self, c)` |
| Draw a line | `c.line(id, pts, style)` | `c.Line(id, pts, style)` | `c.line(id, pts, style)` |
| The status line | `c.status(fmt, args)` | `c.Status(format, a…)` | `c.status(&text)` |
| Settings values | `lk.settings(G)` | the `Settings` field | `G::get()` |
| A connection list | `lk.connections(.{})` | `lk.Connections(opts)` | `impl lk::ConnSpec` |
| The data hook | `pub fn onData(row, b)` | `OnData(*lk.Row, []byte)` | `fn on_data(&mut self, …)` |
| Publish readings | `lk.Publish.begin()` | `lk.NewPublish()` | `lk::Publish::begin()` |
| Raise an alarm | `lk.alert(sev, t, b)` | `lk.Alert(sev, t, b)` | `lk::alert(sev, t, b)` |

Three differences between the languages are not cosmetic.

- **Zig catches a misused optional input at compile time.** `get()` on an
  optional input is a compile error naming the two ways out. Rust encodes the
  same thing in the type. Go has no way to say it, so `Get()` answers the last
  value whether or not it is stale.
- **Zig's limits are fixed arrays.** The scene batch is 64 KiB, an overlay id
  is kept to 48 bytes and a connection list holds 8 rows. Go and Rust grow
  instead, so a scene or a row count that Zig drops still goes out from them.
- **Only Zig is checked by `zig build test`.** A Go plugin's manifest check is
  a `go test` you run, and a Rust plugin's is a `cargo test`.

The full listings for each language are in `sdk/go/ENTRYPOINTS.md` and
`sdk/rust/ENTRYPOINTS.md`.

## Declaring what the plugin reads

**Capabilities:** `vessel.read`, and `ais.read` for the target set.

Inputs are declared once. The library subscribes, records every value that
arrives, ages it against the monotonic clock, and holds `draw` until every
required one is inside its window.

```zig
pub const inputs = struct {
    pub const boat = lk.position("navigation.position", .{});
    pub const twd = lk.number("environment.wind.directionTrue", .{ .label = "wind" });
    pub const depth = lk.number("environment.depth.belowKeel", .{
        .max_age_ms = 10_000,
        .optional = true,
    });
    pub const traffic = lk.ais(.{});
};
```

| Declaration | What it holds |
|---|---|
| `lk.number(path, opts)` | an `f64` off the vessel store |
| `lk.position(path, opts)` | an `lk.Point` off the vessel store |
| `lk.ais(.{ .max = 128 })` | the AIS target set |

`opts` is an `lk.InputOpts`:

| Field | Default | What it does |
|---|---|---|
| `label` | the last segment of the path | what the status line calls this reading when it is missing |
| `max_age_ms` | `5_000` | how old the value may be and still count |
| `optional` | `false` | takes the input out of the freshness gate and out of the status line |

The paths are the vessel store's own: `navigation.position`,
`navigation.speedOverGround`, `environment.wind.directionTrue`,
`environment.depth.belowTransducer` and the rest.

### Choosing between get and fresh

| Call | Answers | Where it is correct |
|---|---|---|
| `get()` | the value | inside `draw`, where the library has already gated on freshness |
| `fresh()` | `?T`, null past the window | anywhere, at any time |
| `ageMs()` | `?i64` | anywhere |

An optional input has no `get`. Calling it is a compile error that names both
ways out: read it with `fresh()` and handle the null, or drop
`.optional = true` and let the library hold the draw until the value arrives.

A tier-2 plugin reading an input from `onData` is outside the gate, so it uses
`fresh()` there as well.

### What happens when a reading goes stale

The library clears everything this plugin drew, skips the call to `draw`, and
posts one degraded line naming every missing input at once: `no wind, no
position`. Naming all of them matters, because a line that says only "no wind"
while the GPS is also out sends the mariner to the wrong instrument. The word
in that list is the input's `label`.

The AIS set never holds `draw` back. No targets in range is a normal condition
rather than a missing instrument.

### What one AIS target carries

`inputs.traffic.targets()` is the whole set, aged to now.
`inputs.traffic.find(mmsi)` is one of them or null. An absent field is null:
never heard and heard as zero are different things at sea.

| Field | Type | Note |
|---|---|---|
| `mmsi` | `u32` | |
| `at` | `?lk.Point` | |
| `sog_mps` | `?f64` | metres per second |
| `cog_deg`, `heading_deg` | `?f64` | degrees true |
| `aton`, `virtual_aton` | `bool` | an aid to navigation, and one that exists only as a broadcast |
| `aton_type` | `?u8` | |
| `off_position` | `?bool` | |
| `age_ms` | `i64` | |
| `name()` | `[]const u8` | |

A target that stops being heard drops out of the set. Draw from the set each
call and the library takes the symbol off the chart for you.

## Drawing on the chart

**Capabilities:** `overlay.draw`.

`draw` runs on the library's timer, once a second unless the plugin declares
`pub const draw_rate_ms: i64 = …`. Describe the whole picture every call. The
library compares it with the last one: an object with the same id and the same
shape is left alone, a changed one is replaced, and one you did not draw is
taken off the chart. There is no delete call, no batch and no buffer.

```zig
pub fn draw(c: *lk.Chart) void {
    const boat = inputs.boat.get();

    c.line("ahead", &.{ boat, boat.destination(90, lk.nm(1)) }, .{
        .color = .ownship,
        .width_pt = 2,
    });
    c.symbol("mark", .target, boat.destination(45, lk.nm(0.5)), .{
        .color = .target,
        .rot_deg = 45,
    });

    // 72 points is a ring with no visible corners at harbour zoom.
    var ring: [72]lk.Point = undefined;
    for (&ring, 0..) |*p, i| p.* = boat.destination(@as(f64, @floatFromInt(i)) * 5.0, lk.nm(1));
    c.area("guard", &ring, .{ .color = .warning, .alpha = 0.12 });
}
```

`c.line` takes at least two points. `c.area` takes at least three and closes
the ring for you. Each takes a style struct:

| `lk.Chart.Line` | Default | What it is |
|---|---|---|
| `color` | required | a palette token |
| `width_pt` | `1.5` | screen points, converted at the live zoom |
| `dash` | `false` | |
| `anchor` | `.fixed` | |

| `lk.Chart.Symbol` | Default | What it is |
|---|---|---|
| `color` | required | a palette token |
| `rot_deg` | `0` | a true bearing, clockwise from north |
| `scale` | `1` | |
| `anchor` | `.fixed` | |
| `pick` | `null` | what the shell shows on hover or tap |

| `lk.Chart.Area` | Default | What it is |
|---|---|---|
| `color` | required | a palette token |
| `alpha` | `1` | multiplies the token's own alpha |

**Colours are tokens, never RGB.** The tokens are `ownship`, `target`,
`target_danger`, `track`, `layline_port`, `layline_stbd` and `warning`. The
core resolves each one for the day, dusk and night schemes.

**The symbols are** `ownship`, `target`, `aton` and `aton_virtual`.

**`.anchor = .ownship`** rides own ship's display position, which the core
carries forward between fixes, so the object stays still on screen instead of
stepping once a second. Own ship's heading line uses it.

**A pick payload** is `.{ .title = …, .rows = &.{ .{ "MMSI", "367123450" } } }`,
and only a symbol carries one: a line and an area have no single point to
measure a tap against. The row values are strings the plugin has already
formatted, because only the plugin knows the unit.

Places are `lk.Point`, latitude first. The overlay's wire format puts longitude
first and this type is what keeps that out of plugin code.

| Call | Answers |
|---|---|
| `p.destination(bearing_deg, dist_m)` | where you get to, over a sphere |
| `p.bearingTo(other)` | the initial great-circle bearing, degrees true |
| `p.distanceTo(other)` | metres |
| `p.valid()` | false for a position off the earth or carrying a NaN |
| `lk.nm(n)` | metres from nautical miles |
| `lk.knots(mps)` | knots from metres per second |
| `lk.normalizeDeg(d)`, `lk.wrapLon(d)` | a bearing folded into 0–360, a longitude into ±180 |

One plugin's scene holds 512 objects and serializes into 64 KiB. An overflow
drops the whole batch and logs, and the next call rebuilds the scene from
nothing.

### Posting the status line

```zig
c.status("TWD {d:.0} deg", .{twd});          // working, and what it is doing
c.degraded("the chart is out of date", .{}); // short of something, and which
```

The library posts these once. The host logs every status text it has not seen
before, so a line that repeats at 1 Hz would be a log line a second; the
library sends nothing while the text is unchanged. Round anything live before
you print it, or the text changes every tick and the dedupe cannot help.

Say nothing at all in `draw` and the plugin reads `running`. A missing input
already produces the degraded line, so `c.degraded` is for what the library
cannot see. Outside `draw`, `lk.say(.running, fmt, args)` posts the same line;
the states are `starting`, `running`, `degraded` and `stopped`.

## Declaring settings the mariner can change

**Capabilities:** none. A setting is declared, not granted.

A settings group is a struct. Each field carries its label, range and default
as its own default value, and the same declaration renders the manifest's
schema, so a range cannot drift from the code that clamps against it.

```zig
pub const Settings = struct {
    pub const group = "Downwind line";
    pub const tab: lk.Tab = .display;

    length_nm: lk.Num = .{
        .label = "Line length",
        .desc = "How far downwind the line reaches.",
        .unit = "nm",
        .min = 0.1,
        .max = 10,
        .default = 1,
    },
    dashed: lk.Flag = .{
        .label = "Dashed",
        .desc = "Draw the line broken, so it does not read as something charted.",
        .default = true,
    },
};

pub fn draw(c: *lk.Chart) void {
    const s = lk.settings(Settings);
    const from = inputs.boat.get();
    c.line("windline", &.{ from, from.destination(180, lk.nm(s.length_nm)) }, .{
        .color = .warning,
        .dash = s.dashed,
    });
}
```

`lk.settings(Settings)` is a plain struct of the values in force: `f64` for an
`lk.Num`, `bool` for an `lk.Flag`. A number outside its range is clamped before
it arrives, and a value of the wrong type is refused rather than coerced.

| Declaration | The mariner sees | The plugin reads |
|---|---|---|
| `lk.Num` | a number field with its unit beside it | `f64`, clamped into `min`–`max` |
| `lk.Flag` | a switch | `bool` |
| `lk.Text` | a text field | a fixed string — legal only as a connection column |
| `pub const group` | the heading above the fields | |
| `pub const tab` | which settings tab it lands on | |

The tabs are `display`, `depths`, `text`, `charts`, `vessels`, `alarms`,
`connections` and `advanced`. A group with no `tab` lands on `advanced`. The
app files your group under that tab beside its own settings and does not say
which plugin added it.

For more than one group, declare `pub const Settings = .{ Alarm, Display };`
and read each with `lk.settings(Alarm)`. One plugin declares at most 16 fields,
counting every group and every connection column.

There is no scalar text setting. `lk.Text` outside a connection row is a
compile error, because the host keeps no scalar string.

Declare `pub fn onSettings() void` to recompute something after a change. You
do not need it to redraw: the library re-reads the values and calls `draw`
again the moment the mariner changes one.

### Checking the manifest against the struct

The manifest is verified rather than generated. Put the settings in a file that
imports only the library and test it:

```zig
test "the manifest ships the schema this file declares" {
    try lk.expectManifest(@embedFile("manifest.json"), .{Settings});
}
```

The test parses both sides, so key order and whitespace do not matter. When
they differ it prints the JSON to paste into the manifest.
`lk.settingsJson(.{Settings})` returns the same text on its own.
`plugins/signalk/config.zig` does this for a connection list.

Reference: [the settings schema](abi.md#settings-schema-v2).

## Keeping a list of connections

**Capabilities:** `net.tcp-client`, or `net.ws` with the hosts named, plus
`vessel.publish` and `ais.publish` for what you put in the stores.

One declaration gives the plugin a group of rows in the settings window and a
socket per row. The library owns the list schema, the dialling, the reconnect
clock, the failure count behind "unreachable", the pause switch, the per-row
status item and the plugin's own status line.

```zig
pub const Connections = lk.connections(.{
    .key = "gateways",
    .group = "NMEA gateways",
    .footer = "Give the address of your instrument network's gateway.",
    .empty = "No gateways yet.",
    .add_label = "Add Gateway",
    .status_empty = "no gateways",
    .rate_noun = "msg",
    .columns = .{
        .port = .{
            .label = "Port",
            .desc = "Most WiFi gateways serve NMEA 0183 on port 10110.",
            .min = 1,
            .max = 65535,
            .default = 10110,
        },
    },
    .Extra = struct {
        websocket: lk.Flag = .{ .label = "WebSocket", .default = false },
    },
    .State = struct { line: lk.Str(96) = .{} },
});
```

| Option | Default | What it does |
|---|---|---|
| `key` | required | the config key the row array arrives under |
| `group` | required | the section heading in the settings window |
| `tab` | `.connections` | which settings tab the group lands on |
| `footer`, `empty`, `add_label` | empty | the list's own wording in the settings window |
| `columns` | the library's wording | words the four standard columns and sets the port's range |
| `Extra` | `struct {}` | columns beyond the four, shaped like a settings group |
| `State` | `struct {}` | per-row state the plugin keeps: a framer, a parser, an identity |
| `reconnect_ms` | `2_000` | delay before a dropped connection is retried |
| `unreachable_after` | `3` | failed connects in a row before the row reads as unreachable |
| `status_ms` | `2_000` | how often the status is rebuilt, and the window a rate is averaged over |
| `rate_noun` | `"msg"` | what `row.count` counts, for the status: `42 msg/s` |
| `status_empty` | `"nothing configured"` | the plugin's detail when the mariner has added no rows |
| `no_answer_detail` | `"check the address"` | what a row says once it has read as unreachable |
| `refused_detail` | `"the host refused this address"` | what a row says when the host would not dial it |

Every row carries four columns the library owns — name, address, port and the
on switch — plus whatever `Extra` declares. Rows are matched to sockets by the
id the shell assigned, so editing one row never disturbs another's connection.
Only an address change, a column change, a pause or a delete closes a socket. A
Zig connection list holds 8 rows.

### The hooks a source plugin declares

| Hook | When |
|---|---|
| `onData(row, bytes)` | the bytes off one row's socket. Required |
| `onOpen(row)` | a stream came up. Send a subscription here |
| `onClose(row)` | a stream ended |
| `rowNote(row)` | a phrase to add after a connected row's rate |
| `endpoint(row)` | where to dial, when it is not the row's host and port |

`endpoint` returns an `lk.Endpoint`: `.{ .tcp = .{ .host = …, .port = … } }`,
`.{ .ws = url }`, or `.{ .refused = "why" }`. A refused row stops retrying and
shows that sentence as its status.

```zig
pub fn endpoint(row: *Connections.Row) lk.Endpoint {
    if (!row.cols.websocket) return .{ .tcp = .{ .host = row.host.text(), .port = row.port } };
    return .{ .ws = buildUrl(row) };
}
```

### What a row carries

| Field | Type | What it is |
|---|---|---|
| `id` | `lk.Str(32)` | the shell's id. It survives an edit |
| `name` | `lk.Str(48)` | what the mariner calls it. May be empty |
| `host` | `lk.Str(128)` | |
| `port` | `u16` | |
| `enabled` | `bool` | false means paused |
| `cols` | the `Extra` values | `f64`, `bool` or a fixed string per column |
| `state` | the `State` struct | the plugin's own, reset when the row changes address |

| Call | What it does |
|---|---|
| `row.label()` | the mariner's name, or the address |
| `row.connected()` | true while the stream is up |
| `row.send(bytes)` | write to this row's stream |
| `row.count(n)` | count `n` of whatever this row carries, for the rate |
| `row.setDetail(fmt, args)` | add a phrase to this row's status line |
| `Connections.all()` | every row |
| `Connections.byId(id)` | one row, or null |

The library posts the plugin's status line and one item per row under the row
id: `connected`, `reconnecting`, `unreachable`, `paused`, `no_address` or
`refused`. The plugin's own line counts what is up: `2 of 3 connected, 44
msg/s`.

Reference: [lists](abi.md#lists-a-group-the-mariner-adds-rows-to) and
[status items](abi.md#status-items-one-line-per-row).

## Publishing readings and AIS targets

**Capabilities:** `vessel.publish`, `ais.publish`.

```zig
var p = lk.Publish.begin();
p.number("navigation.speedOverGround", mps);
p.position("navigation.position", .{ .lat = lat, .lon = lon });
p.clear("environment.wind.speedTrue");   // held by this source, no reading right now
_ = p.send();

var u = lk.Upsert.begin();
u.target(.{ .mmsi = 367123450, .at = at, .sog_mps = mps, .cog_deg = cog });
_ = u.send();
```

Both batches are stamped with the host's wall clock, which is what the store
ages against. `send` answers the number of values the host took, or -1; an
empty batch is not sent and answers 0.

Everything crossing the boundary is SI: metres and metres per second, whatever
the wire format reported. Bearings are degrees true. Convert for display only,
in the text a mariner reads.

Everything one plugin publishes lands in one source, whatever row it came off.
Two sources carrying the same path are arbitrated by the store's election.

## Logging, the clocks and alerts

| Call | What it does |
|---|---|
| `lk.log(.info, fmt, args)` | one log line, truncated at 512 bytes. Levels `debug`, `info`, `warn`, `err` |
| `lk.nowMs()` | wall clock, milliseconds since the epoch |
| `lk.monoMs()` | monotonic milliseconds. Measure intervals with this |
| `lk.scratch()` | an allocator reset the moment your function returns |
| `lk.alert(.alarm, title, body)` | raise an alert. Needs `alerts.raise` |

Logging and the clocks need no capability. Anything that must outlive an event
is a global: a plugin is single-threaded by contract, and `lk.scratch()` is
gone as soon as you return.

Severity is `alarm`, `warning`, `notice` or `caution`. Raise one when the
mariner must act now and would not otherwise know; everything else is a status
line. An alarm that fires when nothing is wrong gets switched off, and then the
real one is not heard.

## Where the library stops

Declare `pub fn onEvent(e: lk.raw.Event) !void` and every event the library did
not consume arrives there — timers you set yourself, HTTP responses, datagrams,
websocket frames, a file the mariner handed over. `lk.raw` is the whole
host-call surface under the library: storage, HTTP, UDP, files, sockets and
timers, each answering -1 when the manifest did not ask for it. A tier-1 or
tier-2 plugin reaches all of it without giving up the inputs, the scene diff or
the connections, so the hook is an addition to the tiers rather than a way out
of them. [Event kinds](abi.md#event-kinds) lists what can arrive.
