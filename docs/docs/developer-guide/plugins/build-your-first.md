---
id: build-your-first
title: Build your first plugin
sidebar_position: 2
---

# Build your first plugin

This page builds one plugin end to end: a dashed line one nautical mile downwind
from the boat, taken off the chart when the wind or the fix goes stale. It is
`plugins/laylines/` with one line instead of two, and it uses every part of the
ABI a drawing plugin needs — subscribe, a timer, globals, an overlay batch, a
status line.

You need **Zig 0.16** and a checkout of the repository. Everything below was run
against `feat/plugins-prototype`.

## The directory

A plugin is a directory with two files in it.

```
plugins/windline/
  manifest.json     who it is, and what it may do
  main.zig          the module
```

The names are fixed by the build: `zig build plugins` reads `manifest.json` for
the plugin's id, compiles `main.zig`, and installs the pair into `zig-out/plugins`
as `<id>.wasm` and `<id>.manifest.json`. That pair, in one directory, is what the
host loads.

## The manifest

```json
{
  "id": "org.example.windline",
  "name": "Downwind line",
  "abi": 1,
  "capabilities": ["vessel.read", "overlay.draw"]
}
```

Four fields, and only `name` is optional. `abi` must be 1; the host refuses
anything else. The capabilities are the two this plugin uses: it reads vessel
values and it draws. It asks for nothing else, so `tcp_connect` and `alert` would
be refused if it called them — [the rules](rules.md) explain why that is the
posture you want.

The full manifest, including the settings schema that puts a control in the
mariner's settings window, is in [the ABI reference](abi.md#the-manifest).

## The module

`plugins/common/lk.zig` is the plugin side of the ABI. It emits the five exports,
routes them to two functions you write, and gives you a scratch allocator, JSON
readers for what the host sends, and JSON builders for what you send back.

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

Four things in that listing are the whole shape of a plugin, and each one is a
rule with a reason behind it:

- **`registerPlugin(@This())` at container scope.** It emits `lk_abi`,
  `lk_alloc`, `lk_free`, `lk_start` and `lk_event`, and routes the last two to
  your `start` and `onEvent`. An event kind it does not recognise is answered `0`
  without reaching you, so a host that grows a new event does not break a module
  built today.
- **Every value that outlives an event is a global.** `lk.scratch()` is reset the
  moment your handler returns. There is no heap, there is no free list, and there
  is nothing to reclaim. See [state lives in globals](rules.md#state-lives-in-globals).
- **The timer draws, not the event.** `store_changed` arrives at up to 10 Hz and
  only updates globals here. Republishing at 1 Hz keeps the core from rebuilding
  vertex buffers ten times a second, and it is also the only way to notice that a
  fix went stale — that is time passing, not an event.
- **A batch that cannot be built is not sent.** `lk.Overlay` writes into a buffer
  you own, remembers an overflow, and refuses the whole batch at `send` rather
  than posting half a line.

## Compile it

`zig build plugins` builds the plugins **in the tree**. It walks a fixed list of
directory names in `build.zig`, so add yours:

```zig
for ([_][]const u8{ "echo", "nmea0183", "ownship", "ais", "laylines", "windline" }) |name| {
```

Then:

```sh
zig build plugins
ls zig-out/plugins/
# org.example.windline.manifest.json
# org.example.windline.wasm
```

That is honest about where the prototype is: there is no out-of-tree plugin
project, no package format and no `lkplug pack`. An out-of-tree author does the
same thing by hand, from any toolchain that emits wasm. The contract is five
exports and the import table, nothing more — see [the ABI](abi.md). With Zig, one
command does it:

```sh
zig build-exe -target wasm32-freestanding -O ReleaseSmall -fno-entry -rdynamic \
    --dep lk -Mroot=main.zig -Mlk=/path/to/lookout-marine/plugins/common/lk.zig
```

`-fno-entry` because a plugin is a reactor with no `main`, and `-rdynamic` so the
linker keeps the five exports. Rename the result to `<id>.wasm`, put
`<id>.manifest.json` beside it, and the host will load it. Copying
`plugins/common/lk.zig` into your own project works too — it imports only `std`.

## Run it in the harness

`lookout-plugin-dev` is the core opened offscreen with the plugin host inside it,
plus a loopback TCP listener that serves a recorded NMEA log to whichever plugin
dials it. It is the fastest way to see a plugin work, and the only way to see it
work without a Mac app.

```sh
zig build plugin-dev
zig run tools/nmea_gen.zig -- test/annapolis.nmea      # the replay log, once

./zig-out/bin/lookout-plugin-dev \
    --chart ~/Charts/ENC_ROOT/US5MD1MC/US5MD1MC.pmtiles \
    --plugins zig-out/plugins \
    --replay test/annapolis.nmea --rate 20 --until 60 \
    --view -76.4767,38.9763,15 --png windline.png --print status
```

The plugins load in sorted file order, the `nmea0183` plugin connects to the
listener, and the log plays at twenty times real time. What the run above prints:

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

Three things to read there. The **object inventory** at the end says what is on
the chart, with the host's namespaced id (`<plugin id>/<your id>`). **`0 denied
call(s)`** means the manifest asked for everything the plugin used; any other
number is a grant you forgot. And **`windline.png`** is the chart with the
overlay on it, which is the only way to find out that your line is in the wrong
place. The exit code is 0 only if a frame rendered and no plugin trapped.

[The dev harness](dev-harness.md) has every flag, the delta streams, and how to
turn a run into a golden test.

## Run it in the app

Two environment variables are the prototype's whole install story.

```sh
export LOOKOUT_PLUGINS=/path/to/lookout-marine/zig-out/plugins
export LOOKOUT_NMEA=127.0.0.1:10110
open macos/build/LookoutMarine.app        # or Run from Xcode
```

`LOOKOUT_PLUGINS` names a directory of `<id>.wasm` + `<id>.manifest.json` pairs;
the core loads and starts them while it opens the chart. `LOOKOUT_NMEA` is the
one piece of configuration the host owns rather than the mariner: it reaches the
`nmea0183` plugin in its start config. A shell that wants control instead calls
`lookout_plugins_load(h, dir)` and leaves the variable unset.

A plugin that fails to load is logged and skipped, so the app still opens. Look
for the reason on stderr:

```
plugin org.example.windline [error] load failed: ...
plugin host [error] plugins: windline not loaded: BadManifest
```

On iOS the simulator reads host paths, so the same directory works from
`SIMCTL_CHILD_LOOKOUT_PLUGINS`. On a device there is no import path at all:
[iOS ships bundled plugins only](index.md#what-exists-today).

## Then read the rules

The four first-party plugins are the worked examples, in rising order of
difficulty: `laylines` (draws), `ownship` (draws, with the own-ship anchor),
`nmea0183` (a socket, reassembly, publishing) and `ais` (settings, alarms, pick
payloads). Before you copy one, read [the rules](rules.md): every one of them is
a mistake that costs a mariner something at sea.
