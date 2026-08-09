---
id: build-your-first
title: Build your first plugin
sidebar_position: 3
---

# Build your first plugin

You are going to draw a dashed line on a chart: one nautical mile downwind from
the boat, taken off the chart the moment the wind or the fix goes stale. It is
twenty-four lines of Zig, header comment included.

Small as it is, it has the shape every drawing plugin has. You declare what you
read off the boat and you describe what you want on the chart. Lookout owns
everything else: the subscription, the staleness window, the redraw timer, the
difference between this picture and the last one, and the status line Lookout
shows.

`plugins/windline/` is this plugin, already in the tree. `zig build plugins`
compiles it and does not install it: it is the worked example the recipes are
checked against, and installed beside the shipped plugins it would draw a second
line off own ship. You are going to write your own copy under your own id, so
that yours is installed and you can change it without touching the reference.

The walkthrough is in Zig.
[The plugin SDK](sdk/index.md) has the same entry points in
Go and Rust, and
[building the plugin in Go and in Rust](#building-the-plugin-in-go-and-in-rust)
has those toolchains.

## Before you start

- **Zig 0.16.** Lookout's build is Zig, and so is the walkthrough. A Go or Rust
  plugin still needs it, to build the harness you will run the plugin in.
- **A checkout of Lookout.** Note the commit you are on: the ABI is unstable,
  and this is what you will pin to.
- **macOS.** It is the only platform where the whole loop (build, harness, app)
  has been run.
- **A baked chart**, a `.pmtiles` file. If you do not have one,
  [Getting your charts](../../user-guide/getting-started.md#getting-your-charts) takes
  about ten minutes.

## Laying out the plugin directory

A plugin is a directory with two files in it.

```
plugins/downwind/
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
  "id": "org.example.downwind",
  "name": "Downwind line",
  "api": 1,
  "capabilities": ["vessel.read", "overlay.draw"]
}
```

Use your own domain in the id. Only `name` is optional. `api` must be 1; the
host refuses anything else. Leave `capabilities` out and your plugin is granted
nothing, which for this one means it cannot draw.

A **capability** is a permission. Most of what your module can ask the host to do
sits behind one. Logging, the clocks and the timers do not. The host checks
every call against this list. Here you are asking for the two you need: read boat
data, and draw. You are not asking for `net.tcp-client` or `alerts.raise`, so if
you called either it would be refused.

Ask for the least you need. Refusals cost you nothing today beyond a `-1` and a
log line, but [the rules](rules.md#a-refused-call-returns--1-and-logs) explain
why you want to find them in the harness rather than at sea.

Later you will want the settings block, which puts your own controls in the
mariner's settings window. Declare it as a Zig struct and check it against the
manifest in a test. See
[adding settings](sdk/settings.md).
[The wire protocol](wire.md#the-manifest) has every other manifest field.

## Writing the module

`plugins/common/lk2.zig` is the plugin SDK. You import it as `lk2`.

```zig
//! Downwind line: one dashed line 1 nm downwind from own ship.
//!
//! The whole plugin. The library subscribes, ages both values against the
//! 5 s window, runs `draw` once a second, and takes the line off the chart and
//! says which instrument is missing when either one goes stale.

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
    c.line("downwind", &.{ from, to }, .{ .color = .warning, .dash = true });
}
```

Four things in that listing are the shape of every drawing plugin you will
write.

- **`lk.plugin(@This())` at container scope.** It registers your plugin. It
  reads what your module declares, here `inputs` and `draw`, and wires only
  that. A declaration you leave out costs nothing.
- **The `inputs` block subscribes your plugin to both paths.** Lookout
  records every value that arrives and stamps its age. Each input accepts a
  freshness window, `max_age_ms`; neither declaration sets one here, so both
  use the default of 5 seconds. Lookout calls your `draw` function only while
  both values are younger than their window. When one is not, Lookout takes
  the line off the chart and posts `no position, no wind`. The
  `.label = "wind"` is the word in that list, in place of the path's last
  segment.
- **Your `draw` function draws its entire view, every call.** Lookout
  compares it with the last one and sends the difference. An object you did
  not draw this call is taken off the chart. There is no delete call and no
  batch to build.
- **Anything that outlives an event is a global.** `lk.scratch()` is reset the
  moment your function returns. There is no heap, no free list and nothing to
  reclaim, so a pointer you keep past the end of a call is a use-after-free
  nothing will catch. See
  [state lives in globals](rules.md#state-lives-in-globals).

`draw` runs on the SDK's timer at 1 Hz, not on every value. Boat data
arrives at up to 10 Hz, and redrawing at that rate makes the core rebuild vertex
buffers ten times a second for a line nobody can see move. It is also the only
way to notice that a fix went stale, because staleness is time passing rather
than an event that arrives. Declare `pub const draw_rate_ms: i64 = 250` when you
draw something that has to move smoothly.

That rate is for the picture, and nothing else should hang off it. Work that
has to keep up with the boat goes in `pub fn onUpdate() void`, which the SDK
calls as soon as an input has a new value.

[The plugin SDK](sdk/index.md) is the full surface: the other input kinds, the
symbol and area calls, the settings struct, connections, and publishing.

## Compiling the plugin

`zig build plugins` builds plugins **in Lookout's tree**. It walks a fixed list
of directory names in `build.zig`, so add yours:

```zig
for ([_][]const u8{ "echo", "nmea0183", "signalk", "ownship", "ais", "laylines", "windline", "downwind" }) |name| {
```

Then:

```sh
zig build plugins
ls zig-out/plugins/
# org.example.downwind.manifest.json
# org.example.downwind.wasm
```

There is no out-of-tree plugin project yet: no template, no package format and
no `lkplug pack`. Building outside the tree means doing the same thing by hand.
With Zig it is one command:

```sh
zig build-exe -target wasm32-freestanding -O ReleaseSmall -fno-entry -rdynamic \
    --dep lk2 -Mroot=main.zig -Mlk2=/path/to/lookout-marine/plugins/common/lk2.zig
```

`-fno-entry` because a plugin has no `main`, and `-rdynamic` so the linker keeps
what `lk.plugin` declared. The command emits `root.wasm`. Rename it to
`<id>.wasm`, put `<id>.manifest.json` beside it, and Lookout will load it. Copying
`plugins/common/` into your own project works too: `lk2.zig` and the three files
under it import only `std`.

The module is about 80 KB.

## Building the plugin in Go and in Rust

Zig is not the only way in. The plugin above exists in all three languages, so
you can read the one you already know:

```
plugins/windline/                 the Zig listing above
sdk/go/examples/windline/         the same plugin in Go
sdk/rust/examples/windline/       the same plugin in Rust
```

All three SDKs give you the same API under the same names.
[The plugin SDK](sdk/index.md) shows them side by side, and
[the names in Zig, Go and Rust](sdk/index.md#the-names-in-zig-go-and-rust) is the
name-by-name mapping and the three differences that are not cosmetic.

Neither the Go nor the Rust module is built by `zig build`. You build it with
your own toolchain and drop the pair into a plugin directory yourself, which is
what an out-of-tree plugin does anyway.

### Building in Go

Go 1.24 or later. `GOOS=wasip1 GOARCH=wasm` with `-buildmode=c-shared` emits a
reactor module.

```sh
cd sdk/go/examples/windline
GOOS=wasip1 GOARCH=wasm go build -buildmode=c-shared -o org.example.windline.go.wasm .

cp org.example.windline.go.wasm ../../../../zig-out/plugins/
cp manifest.json ../../../../zig-out/plugins/org.example.windline.go.manifest.json
```

Three things a Go author has to know.

- **`main` never runs.** A reactor is initialised by `_initialize`, which runs
  package initialisation and then hands control back. Package `main` still needs
  a `main` function to compile; leave it empty and register in an `init`
  function or in a package-level variable.
- **Goroutines make no progress after you return.** There is one thread and it is
  only inside your module while the host is calling it. No background workers, no
  `time.Sleep`: it fails rather than sleeping, so a sleep loop is a spin loop
  and the watchdog will kill it. Ask the host for a timer.
- **The module is about 4.6 MB**, whatever the plugin does; that is the Go
  runtime. `tinygo build -target=wasip1` emits tens of kilobytes from the same
  source, with the usual TinyGo standard library caveats.

### Building in Rust

`wasm32-wasip1`, `crate-type = ["cdylib"]`. Add the target once.

```sh
rustup target add wasm32-wasip1
cd sdk/rust
cargo build --release --target wasm32-wasip1

cp target/wasm32-wasip1/release/windline.wasm \
   ../../zig-out/plugins/org.example.windline.rs.wasm
cp examples/windline/manifest.json \
   ../../zig-out/plugins/org.example.windline.rs.manifest.json
```

`cargo test` runs on your own machine, off wasm, where every host call answers
"refused". The geodesy, the scene diff, the settings schema and the connection
list are all testable there without a boat or an emulator.

`std` works: `String`, `Vec`, `format!`, `SystemTime` and `println!` all do what
you expect. `File::open`, `TcpStream::connect` and `thread::spawn` do not. See
[the WASI floor](wire.md#the-wasi-floor) for the exact list. A panic traps the
instance and the message reaches your log, so do not panic on data off the wire.

The module is about 110 KB.

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
    --view -76.4767,38.9763,15 --png downwind.png --print status
```

Point `--chart` at your own `.pmtiles` file, and `--view` at water you have a
chart for. The plugins load in sorted filename order, the `nmea0183` plugin
dials the loopback server, and the log plays at twenty times real time.

The plugin directory must hold a publishing plugin as well as yours.
`zig-out/plugins` already carries `nmea0183`, which is what reads the replay
and fills the store your inputs read from. A directory holding only your
plugin sits at `waiting for position, wind` forever, because nothing is
publishing.

Your plugin's lines in that run:

```
plugin org.example.downwind [info] status {"state":"starting","detail":"waiting for position, wind"}
plugin org.example.downwind [info] started (Downwind line, source 6)
t=   19.0s [info] org.example.downwind: status {"state":"running","detail":""}
...
overlay: 17 object(s)
  org.example.downwind/downwind: polyline warning 2 pts dashed
plugin org.example.downwind: live, 0 denied call(s), status {"state":"running","detail":""}
replay: 61 group(s), 275 line(s), 60.0 s at 20x, 1 connection(s)
frames: 14 rendered, 1 alert(s) raised
```

Read four things there.

- **`waiting for position, wind`** is the SDK, before either value has
  arrived. It names both, and it names them from the input declarations. Once
  the fix and the wind sentence have both landed inside their windows, the
  plugin goes to `running`. The `t` stamps are replay seconds, and `--rate`
  scales the log against the real staleness clocks, so the exact second moves
  with the rate; [the dev harness](dev-harness.md) explains.
- **The empty detail** is your `draw` saying nothing. Call `c.status(…)` in it
  and your own words appear there instead.
- **The object inventory** near the end says what is actually on the chart,
  under the id the host gave it: `<your plugin id>/<your object id>`.
- **`0 denied call(s)`** means your manifest asked for everything your plugin
  used. Any other number is a capability you forgot.

`downwind.png` is the chart with your overlay drawn on it. Open it. It is the
only way to find out that your line is in the wrong place, or the wrong colour,
or a thousand miles away because you swapped a lat and a lon.

The exit code is 0 only if a frame rendered and no plugin trapped.

[The dev harness](dev-harness.md) has every flag, the delta streams, and how to
turn a run like this into a regression test.

## Running the plugin in Lookout

Two environment variables are the whole install story for now.

```sh
export LOOKOUT_PLUGINS=/path/to/lookout-marine/zig-out/plugins
export LOOKOUT_NMEA=127.0.0.1:10110
open macos/build-mac/Build/Products/Debug/LookoutMarine.app   # or Run from Xcode
```

[The macOS page](../macos.md) covers building that app if you do not have it
yet.

`LOOKOUT_PLUGINS` names a directory of `<id>.wasm` + `<id>.manifest.json`
pairs. Plugins load while a chart opens, so open one: a fresh install with no
chart shows no plugins until you do, and `LOOKOUT_OPEN=/path/to/chart.pmtiles`
opens one at launch. `LOOKOUT_NMEA` is
the one piece of configuration the host owns rather than the mariner: it reaches
the `nmea0183` plugin in its start config, and points it at your multiplexer or
at a server replaying a log. An app that wants control of loading instead calls
`lookout_plugins_load(h, dir)` and leaves the variable unset.

Nothing serves that port by itself. Point it at your gateway if you have one
on the network, or replay the test log:

```sh
# serve test/annapolis.nmea on 10110, one sentence every 100 ms
while true; do
  (while IFS= read -r l; do printf '%s\r\n' "$l"; sleep 0.1; done \
    < test/annapolis.nmea) | nc -l 10110
done
```

A plugin that fails to load is logged and skipped, so Lookout still opens.
The reason is on stderr, and `open` detaches from your terminal: launch the
binary inside the app bundle directly, or pass `open --stderr /tmp/lookout.log`
and tail the file. You will see:

```
plugin org.example.downwind [error] load failed: ...
plugin host [error] plugins: downwind not loaded: BadManifest
```

On the iOS simulator, which reads paths on the host machine, the same directory
works through `SIMCTL_CHILD_LOOKOUT_PLUGINS`. On an iOS device there is no import
path at all, so only plugins bundled with Lookout can run.

## What to read next

[Recipes](recipes.md) is a dozen more things a plugin can do, each with a
complete short listing: a setting, a guard ring, AIS traffic, a connection list,
an alarm, storage. [The plugin SDK](sdk/index.md) is the reference for
everything those recipes call.

The plugins that ship with Lookout are the worked examples, in rising order of
difficulty: `laylines` draws two lines from the same two values as yours;
`ownship` draws the boat and keeps a track between calls; `nmea0183` opens
sockets the mariner configures, reassembles a stream and publishes; `signalk`
does the same from a JSON protocol over two transports; `ais` adds settings, an
alarm and pick payloads.

Before you copy one, read [the rules](rules.md). Every rule there is a mistake
that costs a mariner something at sea.
