---
id: index
title: The plugin SDK
---

import Tabs from '@theme/Tabs';
import TabItem from '@theme/TabItem';

# The plugin SDK

Your plugin declares what it reads. It draws on the chart, publishes values
into the store, or does both. Lookout does the rest: it delivers each
declared input, calls your `draw` function on a timer, puts your scene on
the chart, dials your connections, and stores your settings.

These pages are the reference. [Recipes](../recipes.md) is the same surface
arranged by what you are trying to do, and
[Build your first plugin](../build-your-first.md) walks one plugin from an
empty directory to a chart with a line on it.

## Which way the data flows

Everything a plugin does moves in one of two directions, and the vessel
store sits in the middle.

**In:** `inputs` are values your plugin reads from the store: the current
position, the wind, the AIS targets. Declaring an input subscribes your
plugin to it. A connection brings bytes in from
the network. `onEvent` brings in anything else you asked Lookout for, such as
an HTTP response or a file the mariner opened.

**Out:** your `draw` function puts your scene on the chart. `publish` and the AIS upsert
write values into the store. The status line and alerts go to the person at
the helm.

The store connects plugins to each other: the position `nmea0183` publishes
is the position `ownship` reads as an input. One plugin can read an
instrument and publish what it hears, another can read the store and draw,
and one plugin can do both.

The Zig SDK, `plugins/common/lk2.zig`, defines the API. When these pages and
its doc comments disagree, the code is correct. The Go and Rust SDKs
implement the same API with the same names, in each language's own style.

## What a plugin declares

`lk.plugin` reads your module and wires only what it finds, so a module with
nothing else registers, starts and does nothing. Every declaration is
optional, and the names are exact: Lookout looks each one up by name, so a
typo like `Setting` is not an error, it is a plugin with no settings.

| Declaration | What it does | Documented in |
|---|---|---|
| `inputs` | subscribes the plugin to store values | [Subscribing to data](subscribing.md) |
| `draw(c)` | describes the scene, on a timer | [Drawing on the chart](drawing.md) |
| `draw_rate_ms` | how often `draw` runs, default 1000 | [Drawing on the chart](drawing.md) |
| `onUpdate()` | runs when an input has a new value or expires, and fills any table | [Subscribing to data](subscribing.md#acting-on-a-value-as-it-arrives) |
| `lk.table(…)` | a dialog the mariner opens from a menu | [Subscribing to data](subscribing.md#filling-a-dialog) |
| `Settings` | settings the mariner can change | [Adding settings](settings.md) |
| `onSettings()` | runs after a settings change | [Adding settings](settings.md) |
| `Connections` | a connection list | [Connecting to instruments](connections.md) |
| `onData(conn, bytes)` | bytes from one connection's socket | [Connecting to instruments](connections.md) |
| `onOpen`, `onClose`, `connectionNote`, `endpoint` | the other connection hooks | [Connecting to instruments](connections.md) |
| `onStart(s)` | runs once at startup | [below](#starting-and-stopping) |
| `onEvent(e)` | every event the SDK did not consume | [Handling events](events.md) |
| `onShutdown()` | runs once at shutdown | [below](#starting-and-stopping) |

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

In Go, register from `init` or from a package-level variable. `main` never
runs, and package `main` still needs an empty one to compile. In Rust the
instance is built with `Default` on the first call into the module.

### Starting and stopping

You rarely need either hook. Declare `pub fn onStart(s: lk.raw.Start) !void`
to run something once, after the wiring and before the first event; return an
error and the plugin does not start. Declare `pub fn onShutdown() void` for
the last word before the plugin stops. After it returns, Lookout drops every
overlay object the plugin drew, so there is nothing to clean up on the chart.

## A complete plugin

<Tabs groupId="plugin-language">
<TabItem value="zig" label="Zig" default>

```zig
const lk = @import("lk2");

comptime {
    lk.plugin(@This());
}

pub const inputs = struct {
    pub const boat = lk.subscribePosition("navigation.position", .{});
    pub const twd = lk.subscribeNumber("environment.wind.directionTrue", .{ .label = "wind" });
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
	boat = lk.SubscribePosition("navigation.position")
	twd  = lk.SubscribeNumber("environment.wind.directionTrue", lk.InputOpts{Label: "wind"})
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
            boat: lk::subscribe_position("navigation.position"),
            twd: lk::subscribe_number("environment.wind.directionTrue").label("wind"),
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

That is a complete plugin. The plugin subscribes to both paths. Lookout
records and ages what arrives, calls your `draw` function once a second (the
default; see [Drawing on the chart](drawing.md)), and sends the difference
between this scene and the last. When either value passes its 5 s window the line comes
off the chart and the status reads `no position, no wind`.

The windline example is available in each language: `plugins/windline/`,
`sdk/go/examples/windline/` and `sdk/rust/examples/windline/`.

## The names in Zig, Go and Rust

| What it does | Zig | Go | Rust |
|---|---|---|---|
| Register | `lk.plugin(@This())` | `lk.Register(&p{})` | `lk::plugin!(P)` |
| A number input | `lk.subscribeNumber(path, .{})` | `lk.SubscribeNumber(path)` | `lk::subscribe_number(path)` |
| A position input | `lk.subscribePosition(path, .{})` | `lk.SubscribePosition(path)` | `lk::subscribe_position(path)` |
| The AIS set | `lk.subscribeAis(.{})` | `lk.SubscribeAIS()` | `lk::subscribe_ais(max)` |
| Read a value | `in.get()`, `in.fresh()` | `in.Get()`, `in.Fresh()` | `in.get()`, `in.fresh()` |
| The draw hook | `pub fn draw(c)` | `Draw(*lk.Chart)` | `fn draw(&mut self, c)` |
| Draw a line | `c.line(id, pts, style)` | `c.Line(id, pts, style)` | `c.line(id, pts, style)` |
| The status line | `c.status(fmt, args)` | `c.Status(format, a…)` | `c.status(&text)` |
| The update hook | `pub fn onUpdate()` | `OnUpdate()` | `fn on_update(&mut self)` |
| Declare a table | `lk.table(.{})` | `lk.NewTable(opts)` | `lk::TableSpec` |
| Write a row | `T.upsert(.{ … })` | `t.Row(id)…Done()` | `t.row(id)…done()` |
| Settings values | `lk.settings(G)` | the `Settings` field | `G::get()` |
| A connection list | `lk.connections(.{})` | `lk.Connections(opts)` | `impl lk::ConnSpec` |
| The data hook | `pub fn onData(conn, b)` | `OnData(*lk.Conn, []byte)` | `fn on_data(&mut self, …)` |
| Publish values | `lk.Publish.begin()` | `lk.NewPublish()` | `lk::Publish::begin()` |
| Raise an alarm | `lk.alert(sev, t, b)` | `lk.Alert(sev, t, b)` | `lk::alert(sev, t, b)` |

Four differences between the languages are not cosmetic.

- **Zig catches a misused optional input at compile time.** `get()` on an
  optional input is a compile error naming the two ways out. Rust encodes the
  same thing in the type. Go has no way to say it, so `Get()` answers the
  last value whether or not it is stale.
- **Zig catches a misdeclared table cell at compile time.** A row field that
  names no column is a compile error. Rust has one method for a text cell and
  one for a number, so the column type is checked where you write it. Go takes
  any value and answers a mismatch with a dash on screen and one log line.
- **Zig's limits are fixed arrays.** The scene batch is 64 KiB, an overlay id
  is kept to 48 bytes and a connection list holds 8 connections. Go and Rust
  grow instead, so a scene or a connection count that Zig drops still goes
  out from them.
- **Only Zig is checked by `zig build test`.** A Go plugin's manifest check
  is a `go test` you run, and a Rust plugin's is a `cargo test`.

The full listings for each language are in `sdk/go/ENTRYPOINTS.md` and
`sdk/rust/ENTRYPOINTS.md`.
