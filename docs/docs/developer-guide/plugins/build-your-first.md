---
id: build-your-first
title: Build your first plugin
sidebar_position: 3
---

# Build your first plugin

You are going to draw a dashed line on a chart: one nautical mile downwind from
the boat, taken off the chart the moment the wind or the fix goes stale.

It is a small plugin, but it touches everything a drawing plugin ever needs:
subscribing to boat data, a timer, state that survives between events, an overlay
batch, and a status line the app can show. It is the `laylines` plugin that ships
with Lookout, cut down to one line instead of two — so when you want to go
further, there is a finished example of the same shape sitting in the tree.

The walkthrough is in Zig, which is the only language whose plugin-side library
is settled. Go and Rust modules load and run — see
[building the plugin in Go and in Rust](#building-the-plugin-in-go-and-in-rust) for the
toolchains and the build commands — but their libraries are being rewritten, so
read the Zig listing first for the shape of the thing.

## Before you start

- **Zig 0.16.** Lookout's build is Zig, and so is the walkthrough. A Go or Rust
  plugin still needs it, to build the harness you will run the plugin in.
- **A checkout of Lookout.** Note the commit you are on: the ABI is unstable,
  and this is what you will pin to.
- **macOS.** It is the only platform where the whole loop — build, harness,
  app — has been run.
- **A baked chart**, a `.pmtiles` file. If you do not have one,
  [Getting your charts](../../user-guide/getting-started.md#getting-your-charts) takes
  about ten minutes.

## Laying out the plugin directory

A plugin is a directory with two files in it.

```
plugins/windline/
  manifest.json     who it is, and what it may do
  main.zig          the module
```

Those names are fixed by Lookout's build: `zig build plugins` reads
`manifest.json` for the plugin's id, compiles `main.zig`, and installs the pair
into `zig-out/plugins` as `<id>.wasm` and `<id>.manifest.json`. That pair, in one
directory, is what the host loads.

## Writing the manifest

```json
{
  "id": "org.example.windline",
  "name": "Downwind line",
  "abi": 1,
  "capabilities": ["vessel.read", "overlay.draw"]
}
```

Only `name` is optional. `abi` must be 1; the host refuses anything else. Leave
`capabilities` out and your plugin is granted nothing, which for this one means
it cannot draw.

A **capability** is a permission. Most of what your module can ask the host to do
sits behind one — logging, the clocks and timers do not — and the host checks
every call against this list. Here you are asking for the two you need: read boat
data, and draw. You are not asking for `net.tcp-client` or `alerts.raise`, so if
you called `tcp_connect` or `alert` they would be refused.

Ask for the least you need. Refusals cost you nothing today beyond a `-1` and a
log line, but [the rules](rules.md#a-refused-call-returns--1-and-logs) explain
why you want to find them in the harness rather than at sea.

Later you will want the settings block, which puts your own controls in the
mariner's settings window. That is in
[the ABI reference](abi.md#the-manifest), along with every other manifest field.

## Writing the module

`plugins/common/lk.zig` is the plugin side of the ABI. It writes the five wasm
exports for you, routes two of them to functions you write, and hands you a
scratch allocator, JSON readers for what the host sends, and JSON builders for
what you send back.

```zig
//! Windline: one dashed line downwind from own ship, 1 nm long.
//!
//! The plugin keeps the last position and the last true wind in globals and
//! redraws from a 1 Hz timer, because the store fans out at up to 10 Hz and a
//! line that twitches ten times a second is harder to read than one that steps
//! once a second. Data older than the 5 s staleness window takes the line off
//! the chart.

const std = @import("std");
const lk = @import("lk");

comptime {
    lk.registerPlugin(@This());
}

const id_line = "windline";
const max_age_ms: i64 = 5_000;
const redraw_ms: i64 = 1000;
const length_m: f64 = 1852.0;
const earth_radius_m: f64 = 6371008.8;

/// A value and enough to age it between events: the host stamps `age_ms` at
/// delivery, and the monotonic clock carries it on from there.
const Sample = struct {
    have: bool = false,
    at_mono_ms: i64 = 0,
    age_at_ms: i64 = 0,

    fn stamp(self: *Sample, age_ms: i64) void {
        self.have = true;
        self.at_mono_ms = lk.monoMs();
        self.age_at_ms = age_ms;
    }

    fn fresh(self: Sample, mono_ms: i64) bool {
        return self.have and self.age_at_ms + (mono_ms - self.at_mono_ms) <= max_age_ms;
    }
};

var pos: Sample = .{};
var lat: f64 = 0;
var lon: f64 = 0;

var wind: Sample = .{};
var twd_deg: f64 = 0;

var timer_id: i64 = -1;
var drawn = false;

/// The chrome only hears about a change of state: the host logs every status
/// line it has not seen, so a 1 Hz repeat would be a 1 Hz log line.
const State = enum { starting, running, degraded, stopped };
var state: State = .starting;

fn say(next: State, comptime detail: []const u8) void {
    if (state == next) return;
    state = next;
    lk.status(@tagName(next), detail, .{});
}

pub fn start(s: lk.Start) !void {
    _ = s;
    if (lk.subscribePaths(&.{ "navigation.position", "environment.wind.directionTrue" }) < 0)
        return error.SubscribeRefused;
    timer_id = lk.timerSet(redraw_ms, true);
    if (timer_id < 0) return error.TimerRefused;
    lk.status("starting", "waiting for wind and position", .{});
}

pub fn onEvent(e: lk.Event) !void {
    switch (e) {
        .store_changed => |payload| take(payload),
        .timer => |id| if (id == timer_id) redraw(),
        .shutdown => {
            if (timer_id >= 0) lk.timerCancel(timer_id);
            clearLine();
            say(.stopped, "shut down");
        },
        else => {},
    }
}

/// Record what the store sent. Nothing draws here; the timer does that.
fn take(payload: []const u8) void {
    for (lk.readings(payload)) |r| {
        if (std.mem.eql(u8, r.path, "navigation.position")) {
            if (r.removed()) {
                pos.have = false;
                continue;
            }
            const p = r.position() orelse continue;
            lat = p[0];
            lon = p[1];
            pos.stamp(r.age_ms);
        } else if (std.mem.eql(u8, r.path, "environment.wind.directionTrue")) {
            if (r.removed()) {
                wind.have = false;
                continue;
            }
            const v = r.number() orelse continue;
            if (!std.math.isFinite(v)) continue;
            twd_deg = v;
            wind.stamp(r.age_ms);
        }
    }
}

fn redraw() void {
    const mono = lk.monoMs();
    if (!pos.fresh(mono) or !wind.fresh(mono)) {
        clearLine();
        say(.degraded, "no wind or no position");
        return;
    }

    // The wind direction is where the wind blows FROM, so downwind is the
    // reciprocal.
    const end = destination(lat, lon, twd_deg + 180.0, length_m);
    const pts = [2][2]f64{ .{ lon, lat }, .{ end[0], end[1] } };

    var buf: [512]u8 = undefined;
    var ov = lk.Overlay.init(&buf);
    ov.polyline(id_line, &pts, 1.5, .warning, true);
    if (ov.send() < 0) return;
    drawn = true;
    say(.running, "downwind line drawn");
}

/// Take the line off the chart. Idempotent: nothing is sent once it is gone.
fn clearLine() void {
    if (!drawn) return;
    var buf: [128]u8 = undefined;
    var ov = lk.Overlay.init(&buf);
    ov.del(id_line);
    _ = ov.send();
    drawn = false;
}

/// Great-circle destination, `{ lon, lat }`. A sphere, not the ellipsoid the
/// chart is drawn on: the error over 1 nm is under 4 m.
fn destination(from_lat: f64, from_lon: f64, bearing_deg: f64, distance_m: f64) [2]f64 {
    const lat1 = std.math.degreesToRadians(from_lat);
    const lon1 = std.math.degreesToRadians(from_lon);
    const brg = std.math.degreesToRadians(bearing_deg);
    const d = distance_m / earth_radius_m;
    const lat2 = std.math.asin(@sin(lat1) * @cos(d) + @cos(lat1) * @sin(d) * @cos(brg));
    const lon2 = lon1 + std.math.atan2(
        @sin(brg) * @sin(d) * @cos(lat1),
        @cos(d) - @sin(lat1) * @sin(lat2),
    );
    return .{ std.math.radiansToDegrees(lon2), std.math.radiansToDegrees(lat2) };
}
```

Four things in that listing are the shape of every plugin you will write, and
each one is a rule with a reason behind it.

- **`registerPlugin(@This())` at container scope.** It writes `lk_abi`,
  `lk_alloc`, `lk_free`, `lk_start` and `lk_event`, and routes the last two to
  your `start` and `onEvent`. An event kind it does not recognise is answered `0`
  without ever reaching you, so a future Lookout that adds an event will not
  break the module you build today.
- **Anything that outlives an event is a global.** `lk.scratch()` is reset the
  moment your handler returns. There is no heap, no free list and nothing to
  reclaim, so a pointer you keep past the end of a handler is a use-after-free
  nothing will catch. See
  [state lives in globals](rules.md#state-lives-in-globals).
- **The timer draws, not the event.** Boat data arrives at up to 10 Hz and only
  updates globals here. Redrawing at 1 Hz keeps the core from rebuilding vertex
  buffers ten times a second, and it is also the only way to notice that a fix
  went stale — staleness is time passing, not an event that arrives.
- **A batch that cannot be built is not sent.** `lk.Overlay` writes into a buffer
  you own, remembers an overflow, and refuses the whole batch at `send` rather
  than posting half a line.

## Compiling the plugin

`zig build plugins` builds plugins **in Lookout's tree**. It walks a fixed list
of directory names in `build.zig`, so add yours:

```zig
for ([_][]const u8{ "echo", "nmea0183", "signalk", "ownship", "ais", "laylines", "windline" }) |name| {
```

Then:

```sh
zig build plugins
ls zig-out/plugins/
# org.example.windline.manifest.json
# org.example.windline.wasm
```

There is no out-of-tree plugin project yet: no template, no package format and
no `lkplug pack`. Building outside the tree means doing the same thing by hand,
from any toolchain that emits wasm — the contract is the five exports and the
import table, nothing more. With Zig it is one command:

```sh
zig build-exe -target wasm32-freestanding -O ReleaseSmall -fno-entry -rdynamic \
    --dep lk -Mroot=main.zig -Mlk=/path/to/lookout-marine/plugins/common/lk.zig
```

`-fno-entry` because a plugin is a reactor with no `main`, and `-rdynamic` so the
linker keeps the five exports. Rename the result to `<id>.wasm`, put
`<id>.manifest.json` beside it, and the host will load it. Copying
`plugins/common/lk.zig` into your own project works too — it imports only `std`.

## Building the plugin in Go and in Rust

Zig is not the only way in. The plugin above exists in all three languages, line
for line, so you can read the one you already know:

```
plugins/windline/                 the Zig listing above
sdk/go/examples/windline/         the same plugin in Go
sdk/rust/examples/windline/       the same plugin in Rust
```

Neither is built by `zig build`. You build the module with your own toolchain and
drop the pair into a plugin directory yourself — which is what an out-of-tree
plugin does anyway.

:::caution The Go and Rust libraries are being rewritten

The **ABI** below — the five exports, the imports, the WASI floor — is settled,
and a Go or Rust module that speaks it loads and runs today. The plugin-side
libraries in `sdk/` are not settled: the whole plugin-facing API is being
simplified, and `sdk/go/lookout` and `sdk/rust/lookout` will be rewritten to the
new shape rather than kept as they are. Read them as working proof that the
language boots, not as an API to build on. This page will grow the walkthrough in
each language when that shape lands.

:::

### Building in Go

Go 1.24 or later. `GOOS=wasip1 GOARCH=wasm` with `-buildmode=c-shared` emits a
reactor module, and `//go:wasmexport` and `//go:wasmimport` bind the ABI.

```sh
cd sdk/go/examples/windline
GOOS=wasip1 GOARCH=wasm go build -buildmode=c-shared -o windline.wasm .

cp windline.wasm    ../../../../zig-out/plugins/org.example.windline.go.wasm
cp manifest.json    ../../../../zig-out/plugins/org.example.windline.go.manifest.json
```

Three things a Go author has to know whatever the library looks like, and none of
them is optional.

- **`main` never runs.** A reactor is initialised by `_initialize`, which runs
  package initialisation and then hands control back. Package `main` still needs
  a `main` function to compile; leave it empty and do your setup in an `init`
  function or in the plugin's own start.
- **Goroutines make no progress after you return.** There is one thread and it is
  only inside your module while the host is calling it. No background workers, no
  `time.Sleep` — it returns at once rather than sleeping, so a sleep loop is a
  spin loop and the watchdog will kill it. Ask the host for a timer.
- **The module is about 3.4 MB**, whatever the plugin does; that is the Go
  runtime. `tinygo build -target=wasip1` emits tens of kilobytes from the same
  source, with the usual TinyGo standard library caveats.

### Building in Rust

`wasm32-wasip1`, `crate-type = ["cdylib"]`. Add the target once with
`rustup target add wasm32-wasip1`.

```sh
cd sdk/rust
cargo build --release --target wasm32-wasip1

cp target/wasm32-wasip1/release/windline.wasm \
   ../../zig-out/plugins/org.example.windline.rs.wasm
cp examples/windline/manifest.json \
   ../../zig-out/plugins/org.example.windline.rs.manifest.json
```

`std` works: `String`, `Vec`, `format!`, `SystemTime` and `println!` all do what
you expect. `File::open`, `TcpStream::connect` and `thread::spawn` do not — see
[the WASI floor](abi.md#the-wasi-floor) for the exact list, and read it before
you spend an afternoon on a path that cannot resolve. A panic traps the instance
and the message reaches your log, so do not panic on data off the wire.

The module is about 120 KB, near the Zig one.

## Running the plugin in the harness

The **dev harness** is Lookout's chart core running offscreen with the real
plugin host inside it, plus a loopback TCP server that plays a recorded NMEA log
to whichever plugin dials it. It is the fastest way to see your plugin work, and
the only way to see it work without building a Mac app.

```sh
zig build plugin-dev
zig run tools/nmea_gen.zig -- test/annapolis.nmea      # write the replay log, once

./zig-out/bin/lookout-plugin-dev \
    --chart ~/Charts/ENC_ROOT/US5MD1MC/US5MD1MC.pmtiles \
    --plugins zig-out/plugins \
    --replay test/annapolis.nmea --rate 20 --until 60 \
    --view -76.4767,38.9763,15 --png windline.png --print status
```

Point `--chart` at your own `.pmtiles` file, and `--view` at water you have a
chart for. The plugins load in sorted filename order, the `nmea0183` plugin
dials the loopback server, and the log plays at twenty times real time. The run
above prints:

```
plugin org.example.windline [info] started (Downwind line, source 5)
t=    0.0s [info] org.example.windline: status {"state":"degraded","detail":"no wind or no position"}
t=   20.0s [info] org.example.windline: status {"state":"running","detail":"downwind line drawn"}
...
  org.example.windline/windline: polyline warning 2 pts dashed
plugin org.example.windline: live, 0 denied call(s), status {"state":"running","detail":"downwind line drawn"}
replay: 61 group(s), 275 line(s), 60.0 s at 20x, 1 connection(s)
frames: 14 rendered, 1 alert(s) raised
```

Read three things there.

- **The object inventory** near the end says what is actually on the chart, under
  the id the host gave it: `<your plugin id>/<your object id>`.
- **`0 denied call(s)`** means your manifest asked for everything your plugin
  used. Any other number is a capability you forgot.
- **`windline.png`** is the chart with your overlay drawn on it. Open it. It is
  the only way to find out that your line is in the wrong place, or the wrong
  colour, or a thousand miles away because you swapped a lat and a lon.

The exit code is 0 only if a frame rendered and no plugin trapped.

[The dev harness](dev-harness.md) has every flag, the delta streams, and how to
turn a run like this into a regression test.

## Running the plugin in the app

Two environment variables are the whole install story for now.

```sh
export LOOKOUT_PLUGINS=/path/to/lookout-marine/zig-out/plugins
export LOOKOUT_NMEA=127.0.0.1:10110
open macos/build-mac/Build/Products/Debug/LookoutMarine.app   # or Run from Xcode
```

`LOOKOUT_PLUGINS` names a directory of `<id>.wasm` + `<id>.manifest.json` pairs;
the core loads and starts all of them while it opens the chart. `LOOKOUT_NMEA` is
the one piece of configuration the host owns rather than the mariner: it reaches
the `nmea0183` plugin in its start config, and points it at your multiplexer or
at a server replaying a log. An app that wants control of loading instead calls
`lookout_plugins_load(h, dir)` and leaves the variable unset.

A plugin that fails to load is logged and skipped, so the app still opens. Look
for the reason on stderr:

```
plugin org.example.windline [error] load failed: ...
plugin host [error] plugins: windline not loaded: BadManifest
```

On the iOS simulator, which reads paths on the host machine, the same directory
works through `SIMCTL_CHILD_LOOKOUT_PLUGINS`. On an iOS device there is no import
path at all, so only plugins bundled with the app can run.

## What to read next

The plugins that ship with Lookout are the worked examples, in rising order of
difficulty: `laylines` draws; `ownship` draws and uses the own-ship anchor;
`nmea0183` opens a socket, reassembles a stream and publishes; `signalk` does
the same from a JSON protocol, converts its units and keeps its transport
behind a seam; `ais` adds settings, an alarm and pick payloads.

Before you copy one, read [the rules](rules.md). Every rule there is a mistake
that costs a mariner something at sea.
