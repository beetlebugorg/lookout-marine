---
id: recipes
title: Recipes
sidebar_position: 2
---

# Recipes

Each recipe is one thing you might want a plugin to do, the permissions it
needs, and a complete short example. If a recipe runs longer than a screen, the
API is at fault and not the recipe — say so.

Every listing below is the whole plugin except the manifest. There is no setup
step, no event loop and no teardown, because the library owns all three.

```zig
const std = @import("std");
const lk = @import("lk2");

comptime {
    lk.plugin(@This());
}
```

That `comptime` block writes the five wasm exports, routes them to whatever you
declare, and is the only ceremony there is.

:::note Zig first, then Go and Rust

The Zig library is the one that is settled. The **ABI** underneath it — the
exports, the imports, the WASI floor — is settled too, and a Go or Rust module
that speaks it loads and runs today. The libraries in `sdk/go` and `sdk/rust`
are being rewritten onto the same three tiers as the Zig one, and each recipe
gains its Go and Rust listing as that lands. Read
[the ABI](abi.md) for what those libraries are written against.

:::

## Adding a setting to your plugin

**Capabilities:** none. A setting is declared in the manifest, not granted.

A settings group is a struct. Each field carries its own label, range and
default, and the manifest schema is generated from the same declaration, so a
range cannot drift from the code that reads it.

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

`lk.settings(Settings)` reads the values in force: `f64` for a `lk.Num`, `bool`
for a `lk.Flag`. A number outside its range is clamped before it reaches you,
by the host and again by the library, so `s.length_nm` is always between 0.1
and 10.

**Where it appears.** `tab` picks one of the mariner's settings tabs — display,
depths, text, charts, vessels, alarms, connections, advanced — and `group` is
the heading inside it. The mariner never learns a plugin put it there, which is
the point: a collision alarm belongs under Alarms beside every other alarm.

**Reacting to a change.** You do not have to. The library re-reads the values
and calls `draw` again the moment the mariner changes one. Declare
`pub fn onSettings() void` if something other than the drawing has to be
recomputed.

**Keeping the manifest honest.** Put the struct in its own file and check it:

```zig
test "the manifest ships the schema this file declares" {
    try lk.expectManifest(@embedFile("manifest.json"), .{Settings});
}
```

That test parses both sides and compares them, and it prints the JSON to paste
in when they differ. `plugins/signalk/config.zig` does exactly this for a
connection list.

Reference: [the settings schema](abi.md#settings-schema-v2).

## Reacting to boat data

**Capabilities:** `vessel.read`.

Declare what you read. The library subscribes, records every value, ages it
against the monotonic clock, and holds `draw` until everything is fresh.

```zig
pub const inputs = struct {
    pub const boat = lk.position("navigation.position", .{});
    pub const twd = lk.number("environment.wind.directionTrue", .{ .label = "wind" });
    pub const sog = lk.number("navigation.speedOverGround", .{ .optional = true });
};

pub fn draw(c: *lk.Chart) void {
    const from = inputs.boat.get();      // always fresh here
    const wind = inputs.twd.get();       // so is this
    if (inputs.sog.fresh()) |mps| {      // optional: may be missing
        c.status("{d:.1} kn", .{lk.knots(mps)});
    }
    _ = from;
    _ = wind;
}
```

**`get` versus `fresh`.** A required input is fresh whenever `draw` runs, so
`get()` needs no null check. An optional one has no `get` at all — the compiler
says so — and `fresh()` hands you a `?f64` to decide about.

**What happens when a reading goes stale.** The library takes everything this
plugin drew off the chart and posts `degraded`, naming every missing input at
once: `no wind, no position`. A line that says only "no wind" while the GPS is
also out sends the mariner to the wrong instrument. Name an input with `.label`
and that is the word the mariner reads.

**The window is 5 seconds**, the same one the vessel store uses. Raise it per
input with `.max_age_ms` where the reading arrives on a slower clock.

Reference: [STORE_CHANGED](abi.md#store_changed) and
[vessel data goes stale after 5 seconds](rules.md#vessel-data-goes-stale-after-5-seconds).

## Drawing on the chart

**Capabilities:** `overlay.draw`, plus `vessel.read` for anything drawn off the
boat's position.

`draw` runs on the library's timer, once a second by default. Describe the
whole picture every call: the library compares it with the last one, sends what
changed, and deletes what you did not draw. There is no delete call, no batch
and no buffer.

```zig
pub fn draw(c: *lk.Chart) void {
    const boat = inputs.boat.get();

    c.line("track-ahead", &.{ boat, boat.destination(90, lk.nm(1)) }, .{
        .color = .ownship,
        .width_pt = 2,
    });
    c.symbol("mark", .target, boat.destination(45, lk.nm(0.5)), .{
        .color = .target,
        .rot_deg = 45,
    });
}
```

**Places are `lk.Point`, latitude first.** The wire format puts longitude
first, and this type is what keeps that off your desk. `destination`,
`bearingTo` and `distanceTo` are on it; distances are metres, and `lk.nm(1)`
converts.

**Widths are screen points, not metres.** The core converts at the live zoom, so
a 1.5 pt line is 1.5 pt at every scale.

**Colours are tokens**, never RGB: `ownship`, `target`, `target_danger`,
`track`, `layline_port`, `layline_stbd`, `warning`. The core resolves each one
for the day, dusk and night schemes.

**Anchoring to the boat.** `.anchor = .ownship` rides own ship's display
position, which the core carries forward between fixes, so the object sits
still on screen instead of stepping once a second. Own ship's heading line uses
it.

### A guard ring with a sweep

The worked example for the retained model: a ring around the boat, and a line
that goes round it. Nothing here deletes anything.

```zig
/// The sweep has to move smoothly, so this plugin draws four times a second
/// instead of the usual once.
pub const draw_rate_ms: i64 = 250;

pub const inputs = struct {
    pub const boat = lk.position("navigation.position", .{});
};

pub const Settings = struct {
    pub const group = "Guard ring";
    pub const tab: lk.Tab = .vessels;

    radius_nm: lk.Num = .{
        .label = "Guard ring",
        .desc = "How far out the ring is drawn.",
        .unit = "nm",
        .min = 0.1,
        .max = 6,
        .default = 1,
    },
};

var sweep_deg: f64 = 0;

pub fn draw(c: *lk.Chart) void {
    const boat = inputs.boat.get();
    const radius = lk.nm(lk.settings(Settings).radius_nm);

    // 72 points is a ring nobody can see the corners of at harbour zoom.
    var ring: [72]lk.Point = undefined;
    for (&ring, 0..) |*p, i| {
        p.* = boat.destination(@as(f64, @floatFromInt(i)) * 5.0, radius);
    }
    c.area("ring", &ring, .{ .color = .warning, .alpha = 0.12 });

    sweep_deg = lk.normalizeDeg(sweep_deg + 6.0);
    c.line("sweep", &.{ boat, boat.destination(sweep_deg, radius) }, .{
        .color = .warning,
        .width_pt = 2,
    });
}
```

Both objects are described in full on every one of the four calls a second. The
library sends the sweep, because it moved, and while the boat holds station it
does not send the ring again. Take the ring out of `draw` — return early, or
drop the setting to nothing — and it leaves the chart on the next call without
anything being deleted by hand.

An area's ring is closed for you and wants three points at least; a line wants
two.

Reference: [the overlay payload](abi.md#overlay).

## Showing details on hover or tap

**Capabilities:** `overlay.draw`.

A symbol may carry a pick payload: a title and rows the shell shows when the
mariner hovers over it or taps it.

```zig
pub fn draw(c: *lk.Chart) void {
    for (inputs.traffic.targets()) |t| {
        const at = t.at orelse continue;

        var id: [16]u8 = undefined;
        var mmsi: [16]u8 = undefined;
        var sog: [16]u8 = undefined;

        c.symbol(std.fmt.bufPrint(&id, "t{d}", .{t.mmsi}) catch continue, .target, at, .{
            .color = .target,
            .rot_deg = t.heading_deg orelse t.cog_deg orelse 0,
            .pick = .{
                .title = t.name(),
                .rows = &.{
                    .{ "MMSI", std.fmt.bufPrint(&mmsi, "{d}", .{t.mmsi}) catch "?" },
                    .{ "SOG", std.fmt.bufPrint(&sog, "{d:.1} kn", .{lk.knots(t.sog_mps orelse 0)}) catch "?" },
                },
            },
        });
    }
}
```

**The values are strings you have already formatted.** This is the one place
units do not cross the ABI in SI: the core cannot know that a row called SOG
holds metres per second, so the plugin does the conversion and writes the unit
into the text. Up to 16 rows, 96 bytes each.

**Only symbols answer a tap.** A line and an area have no single point to
measure a touch against, so they carry no payload. The hit test measures to a
symbol's anchor, within about 14 points.

Reference: [the overlay payload](abi.md#overlay).

## Watching AIS traffic

**Capabilities:** `ais.read`.

Declare the target set like any other input. It never holds `draw` back: an
empty sea is not a missing instrument.

```zig
pub const inputs = struct {
    pub const boat = lk.position("navigation.position", .{});
    pub const traffic = lk.ais(.{});
};

/// Inside this, a target is worth colouring red.
const close_m: f64 = 926; // half a nautical mile

pub fn draw(c: *lk.Chart) void {
    const boat = inputs.boat.get();
    var near: usize = 0;

    for (inputs.traffic.targets()) |t| {
        const at = t.at orelse continue;
        if (t.aton) continue; // an aid is not traffic

        var id: [16]u8 = undefined;
        const oid = std.fmt.bufPrint(&id, "t{d}", .{t.mmsi}) catch continue;
        const close = boat.distanceTo(at) < close_m;
        if (close) near += 1;

        c.symbol(oid, .target, at, .{
            .color = if (close) .target_danger else .target,
            .rot_deg = t.heading_deg orelse t.cog_deg orelse 0,
        });
    }

    if (near > 0) c.status("{d} vessels within half a mile", .{near});
}
```

A target that stops being heard drops out of the snapshot, so it stops being
drawn, so the library takes its symbol off the chart. Nothing tracks that for
you.

**`sog_mps` is metres per second**, whatever the wire format reported.
`lk.knots` converts for text a mariner reads.

Real closest-approach maths — the passing distance and the time to it — is more
than a recipe. `plugins/ais/cpa.zig` is the worked solver, and it is a plain
file with its own tests.

Reference: [AIS_CHANGED](abi.md#ais_changed).

## Publishing from an instrument network

**Capabilities:** `net.tcp-client` or `net.udp` or `net.ws`, plus
`vessel.publish` and `ais.publish` for what you put in the chart.

Declare the connection list once. The library owns the settings rows, one
socket per row, the reconnect clock, the pause switch and each row's line in
the settings window. You write the parser.

```zig
pub const Connections = lk.connections(.{
    .key = "gateways",
    .group = "Connections",
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
    .State = struct { line: lk.Str(96) = .{} },
});

/// TCP hands you whatever arrived, so reassembling a sentence is yours. One
/// datagram off `net.udp` is already one message and needs none of this.
pub fn onData(row: *Connections.Row, bytes: []const u8) void {
    for (bytes) |ch| {
        if (ch != '\r' and ch != '\n') {
            row.state.line.append(&.{ch});
            continue;
        }
        if (row.state.line.len > 0) {
            row.count(1);
            publish(row.state.line.text());
            row.state.line.clear();
        }
    }
}

fn publish(sentence: []const u8) void {
    const fix = parse(sentence) orelse return;
    var p = lk.Publish.begin();
    p.position("navigation.position", .{ .lat = fix.lat, .lon = fix.lon });
    p.number("navigation.speedOverGround", fix.sog_mps);
    _ = p.send();
}
```

**What each hook is for.** `onData` is required. `onOpen(row)` runs when a
stream comes up — send a subscription there, if the protocol needs one.
`onClose(row)` runs when one ends. `rowNote(row)` adds a phrase after the rate
on that row's line.

**`row.count(n)`** is how the rate gets into the status: the library turns it
into "42 msg/s" on the row and sums it for the plugin's line.

**Dialling somewhere other than the row's address.** Declare `endpoint`:

```zig
pub fn endpoint(row: *Connections.Row) lk.Endpoint {
    if (!row.cols.websocket) return .{ .tcp = .{ .host = row.host.text(), .port = row.port } };
    return .{ .ws = buildUrl(row) };
}
```

Return `.refused` with a sentence and the row stops retrying and says why.

**Extra columns** go in `.Extra`, a struct shaped like a settings group; their
values arrive as `row.cols.<name>`. Rows are matched to sockets by the id the
shell minted, so editing one row never disturbs another's connection.

`plugins/signalk` is the shipped example, over both TCP and a websocket;
`plugins/nmea0183` is the other.

Reference: [lists](abi.md#lists-a-group-the-mariner-adds-rows-to) and
[reconnecting is yours](rules.md#reconnecting-is-yours) — which it no longer
is, once the library owns the row.

## Raising an alarm, and when not to

**Capabilities:** `alerts.raise`.

```zig
if (crossing and !alarmed) {
    alarmed = true;
    _ = lk.alert(.alarm, "AIS CPA alarm", "367123450: CPA 149 m in 591 s");
}
```

Severity is `alarm`, `warning`, `notice` or `caution`. The host maps them to log
levels: alarm at error, warning at warn, the other two at info.

**Raise one only when the mariner must act now and would not otherwise know.**
Everything else is a status line. An alarm that cries wolf gets switched off,
and then the real one is not heard.

**Latch it.** Raise on the edge, not every tick, and re-arm only when the
condition has genuinely cleared. Give the gate a dead band if the quantity can
sit on the limit: a target parked at exactly the alarm distance must not alarm
once a second.

**There is no alarm surface yet.** An alert is a log line and nothing more
today — no sound, no banner. Build the behaviour now; it will be heard when the
chrome for it lands.

Reference: [alert](abi.md#alert).

## Showing live status, per connection when there are rows

**Capabilities:** none. A status line needs no permission.

```zig
pub fn draw(c: *lk.Chart) void {
    c.status("TWD {d:.0} deg", .{wind});
    // or, when something is wrong that is not a missing input:
    c.degraded("the chart is out of date");
}
```

**The library posts it once.** The host logs every status text it has not seen
before, so a repeat at 1 Hz would be a log line a second — and the library
sends nothing while the text is unchanged. Say nothing at all and the plugin
reads `running`.

**You rarely need `degraded`.** A missing declared input already produces it,
naming the instrument. Use it for what the library cannot see.

**Round anything live.** A detail carrying a raw float changes every tick and is
a new line every tick. `{d:.0}` on a wind direction, or a five-degree bucket, is
the difference between a log you can read and one you cannot.

**A connection list writes its own.** The library posts one item per row —
`connected`, `paused`, `reconnecting`, `unreachable`, `no_address` — under the
row id the shell minted, and the plugin line above them counts what is up:
`2 of 3 connected, 44 msg/s`.

Reference: [chrome_status](abi.md#chrome_status),
[status items](abi.md#status-items-one-line-per-row) and
[never be silent](rules.md#never-be-silent).

## Keeping state between runs

**Capabilities:** `storage`.

**Status: raw calls only.** The v2 library has no storage helper yet. Use
`lk.raw.storageSize`, `lk.raw.storageGet`, `lk.raw.storagePut` and
`lk.raw.storageDelete`, which are the shim over the two host imports.

```zig
const size = lk.raw.storageSize("last_port") orelse return;
var buf: [64]u8 = undefined;
if (size > buf.len) return;
const value = lk.raw.storageGet("last_port", buf[0..size]) orelse return;
```

A key is at most 128 bytes, a value 64 KiB, and a plugin's whole store 1 MiB
over 256 keys. Writing an empty value deletes the key. Storage is data and not
cache: it lives where the operating system will not delete it.

Reference: [storage_get and storage_put](abi.md#storage_get-and-storage_put)
and [storage is small, and it is yours alone](rules.md#storage-is-small-and-it-is-yours-alone).

## Fetching from the internet

**Capabilities:** `{"net.http": ["nomads.ncep.noaa.gov"]}` — the hosts by name,
never a bare `net.http`.

**Status: raw calls only.** The v2 library has no fetch helper yet. Use
`lk.raw.httpGet` or `lk.raw.httpFetch`, and take the answer in a tier-3
`onEvent` on `.http_response`.

```zig
pub fn onEvent(e: lk.raw.Event) !void {
    switch (e) {
        .http_response => |r| if (r.status == 200) take(r.body),
        else => {},
    }
}
```

GET and HEAD only. A body is capped at 4 MiB — ask for a range rather than a
file, and cache what you fetched in storage, because a boat's connection is
metered and often absent. There are no wildcards in the host list, and a
redirect off the host is refused.

Reference: [http_fetch](abi.md#http_fetch),
[name every server you reach](rules.md#name-every-server-you-reach) and
[ask for a range, not a file](rules.md#ask-for-a-range-not-a-file).

## Reading a file the mariner gives you

**Capabilities:** `files`.

**Status: raw calls only, and nothing can grant a file yet.** There is no
`file_open` import and there never will be — a plugin cannot name a path. A
handle arrives as `.file_opened` because the mariner chose that file. The
picker that would ask is not built, so today only the harness and the in-tree
tests produce one.

```zig
pub fn onEvent(e: lk.raw.Event) !void {
    switch (e) {
        .file_opened => |f| {
            var buf: [4096]u8 = undefined;
            const chunk = lk.raw.fileRead(f.handle, 0, &buf) orelse return;
            take(chunk);
        },
        else => {},
    }
}
```

Reads take an absolute offset and the handle has no cursor, so a decoder can
seek freely. Eight handles per plugin, 1 MiB per read.

Reference: [file_read and file_write](abi.md#file_read-and-file_write) and
[you cannot open a file](rules.md#you-cannot-open-a-file).

## Building an instrument display

**Status: not buildable today, and worth saying plainly.**

There is no way to put a number on the screen from a plugin. The overlay draws
three things — symbols, lines and areas — and none of them carries text. A
plugin has two places words reach the mariner, and neither is an instrument:

- **a pick payload**, which shows rows of text when a symbol is hovered or
  tapped;
- **the status line**, which today goes to the log and has no home on screen.

What is coming is chrome readout blocks: a plugin declaring a readout, and the
app drawing it in its own idiom beside the other instruments, the way a settings
group is drawn today. That is not built, and no part of the ABI reserves it yet.

Until then, an instrument-shaped plugin says what it knows through
[the status line](#showing-live-status-per-connection-when-there-are-rows), and
draws the thing itself — the guard ring, the layline, the vector — rather than a
number about it.

## What to read next

- [Build your first plugin](build-your-first.md) walks one plugin start to
  finish, including the manifest, the build command and the harness.
- [The rules](rules.md) is every mistake that costs a mariner something at sea.
  Read it before you copy any of the code above.
- [The ABI](abi.md) is what the library is written against, and what a tier-3
  plugin talks to directly.
- [The dev harness](dev-harness.md) runs your plugin against a recorded log and
  renders the chart it drew.
