---
id: recipes
title: Recipes
sidebar_position: 2
---

# Recipes

Each recipe is one thing you might want a plugin to do, the permissions it
needs, and a complete short example. If a recipe runs longer than a screen,
that is a problem with the API rather than the recipe. Report it.

Every listing below is the whole plugin except the manifest. There is no setup
step, no event loop and no teardown; Lookout runs all three for every plugin.
The imports, the manifest and the compile command are the ones
[Build your first plugin](build-your-first.md) walks through; a recipe drops
into that setup unchanged.

```zig
const std = @import("std");
const lk = @import("lk2");

comptime {
    lk.plugin(@This());
}
```

That `comptime` block registers your plugin. Nothing else has to be wired up.

:::note Zig first, then Go and Rust

Only the Zig SDK is settled. The wire protocol underneath it is also
settled: the imports, the events, the WASI floor. A Go or Rust module that
speaks it loads and runs today. The SDKs in `sdk/go` and `sdk/rust`
implement the same API as the Zig one, and each recipe gains its Go and Rust
listing as that lands. Read [the wire protocol](wire.md) for what those SDKs
are written against.

:::

## Adding a setting to your plugin

**Capabilities:** none. A setting is declared in the manifest, not granted.

A settings group is a struct. Each field carries its own label, range and
default, and the manifest schema is generated from the same declaration, so a
range cannot drift from the code that reads it.

```zig
pub const inputs = struct {
    pub const boat = lk.subscribePosition("navigation.position", .{});
};

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
by Lookout and again by the SDK, so `s.length_nm` is always between 0.1
and 10.

**Where it appears.** `tab` picks one of the mariner's settings tabs (display,
depths, text, charts, vessels, alarms, connections, advanced), and `group` is
the heading inside it. Lookout shows a collision alarm limit under Alarms like
any other alarm setting. It does not say which plugin added it.

**Reacting to a change.** You do not have to. The SDK re-reads the values
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

Reference: [the settings schema](wire.md#settings-schema-v2).

## Reacting to boat data

**Capabilities:** `vessel.read`.

Declare what you read. Lookout delivers every value with its age, measured
on the monotonic clock, and does not call your `draw` function until
everything is fresh.

```zig
pub const inputs = struct {
    pub const boat = lk.subscribePosition("navigation.position", .{});
    pub const twd = lk.subscribeNumber("environment.wind.directionTrue", .{ .label = "wind" });
    pub const sog = lk.subscribeNumber("navigation.speedOverGround", .{ .optional = true });
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
`get()` needs no null check. An optional one has no `get` at all, so calling it
is a compile error; `fresh()` returns a `?f64` for you to check.

**What happens when a reading goes stale.** The SDK takes everything this
plugin drew off the chart and posts `degraded`, naming every missing input at
once: `no wind, no position`. A line that says only "no wind" while the GPS is
also out sends the mariner to the wrong instrument. The `.label` you give an
input is the word that appears in that list.

**The window is 5 seconds**, the same one the vessel store uses. Raise it per
input with `.max_age_ms` for a reading that arrives less often.

**Deciding something is not drawing it.** `draw` runs on a timer you set for
the picture. Declare `pub fn onUpdate() void` and Lookout calls it as soon as
an input has a new value, which is where a decision belongs; a plugin that
only watches a condition declares it and no `draw` at all. Read inputs with
`fresh()` there: the freshness gate has not run.

**A reading that stops arriving still reaches you.** Lookout calls `onUpdate`
when an input expires as well, so clear the condition there rather than
assuming the next reading will come.

Reference: [STORE_CHANGED](wire.md#store_changed) and
[vessel data goes stale after 5 seconds](rules.md#vessel-data-goes-stale-after-5-seconds).

## Drawing on the chart

**Capabilities:** `overlay.draw`, plus `vessel.read` for anything drawn off the
boat's position.

`draw` runs on the SDK's timer, once a second by default. Describe the
whole picture every call: the SDK compares it with the last one, sends what
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
first, and this type does that conversion for you. `destination`,
`bearingTo` and `distanceTo` are on it; distances are metres, and `lk.nm(1)`
converts.

**Widths are screen points, not metres.** The core converts at the live zoom, so
a 1.5 pt line is 1.5 pt at every scale.

**Colours are tokens**, never RGB: `ownship`, `target`, `target_danger`,
`track`, `layline_port`, `layline_stbd`, `warning`. The core resolves each one
for the day, dusk and night schemes.

**Anchoring to the boat.** An object with `.anchor = .ownship` follows own
ship's display position, which the core carries forward between fixes, so the
object stays still on screen instead of stepping once a second. Own ship's
heading line uses it.

### A guard ring with a sweep

The worked example for the retained model: a ring around the boat, and a line
that goes round it. Nothing here deletes anything.

```zig
/// The sweep has to move smoothly, so this plugin draws four times a second
/// instead of the usual once.
pub const draw_rate_ms: i64 = 250;

pub const inputs = struct {
    pub const boat = lk.subscribePosition("navigation.position", .{});
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

Both objects are described in full on all four calls each second. The SDK
sends the sweep because it moved; while the boat holds station it does not send
the ring again. Take the ring out of `draw` (return early, or drop the setting
to nothing) and it leaves the chart on the next call, with no delete call from
you.

An area's ring is closed for you and needs at least three points; a line needs
two.

Reference: [the overlay payload](wire.md#overlay).

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
units do not cross the wire in SI: Lookout cannot know that a row called SOG
holds metres per second, so the plugin does the conversion and writes the unit
into the text. Up to 16 rows, 96 bytes each.

**Only symbols respond to a tap.** A line and an area have no single point to
measure a touch against, so they carry no payload. The hit test measures to a
symbol's anchor, within about 14 points.

Reference: [the overlay payload](wire.md#overlay).

## Watching AIS traffic

**Capabilities:** `ais.read`.

Declare the target set like any other input. It never holds `draw` back,
because no targets in range is a normal condition rather than a missing reading.

```zig
pub const inputs = struct {
    pub const boat = lk.subscribePosition("navigation.position", .{});
    pub const traffic = lk.subscribeAis(.{});
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

A target that stops being heard drops out of the snapshot. It is then not
drawn, and the SDK takes its symbol off the chart. You do not have to track
expiry yourself.

**`sog_mps` is metres per second**, whatever the wire format reported.
`lk.knots` converts it for display.

Closest-approach maths (the passing distance and the time to it) is too long
for a recipe. `plugins/ais/cpa.zig` is the worked solver, a plain file with its
own tests.

Reference: [AIS_CHANGED](wire.md#ais_changed).

## Publishing from an instrument network

**Capabilities:** `net.tcp-client` or `net.udp` or `net.ws`, plus
`vessel.publish` and `ais.publish` for what you put in the chart.

Declare the connection list once. Lookout owns the settings rows, one
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
pub fn onData(conn: *Connections.Connection, bytes: []const u8) void {
    for (bytes) |ch| {
        if (ch != '\r' and ch != '\n') {
            conn.state.line.append(&.{ch});
            continue;
        }
        if (conn.state.line.len > 0) {
            conn.count(1);
            publish(conn.state.line.text());
            conn.state.line.clear();
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

**What each hook is for.** `onData` is required. `onOpen(conn)` runs when a
stream comes up: send a subscription there, if the protocol needs one.
`onClose(conn)` runs when one ends. `connectionNote(conn)` adds a phrase after the rate
on that row's line.

**`conn.count(n)`** is how the rate gets into the status: the SDK turns it
into "42 msg/s" on the row and sums it for the plugin's line.

**Dialling somewhere other than the row's address.** Declare `endpoint`:

```zig
pub fn endpoint(conn: *Connections.Connection) lk.Endpoint {
    if (!conn.cols.websocket) return .{ .tcp = .{ .host = conn.host.text(), .port = conn.port } };
    return .{ .ws = buildUrl(conn) };
}
```

Return `.refused` with a sentence: the row stops retrying and shows that
sentence as its status.

**Extra columns** go in `.Extra`, a struct shaped like a settings group; their
values arrive as `conn.cols.<name>`. Rows are matched to sockets by the id the
shell assigned, so editing one row never disturbs another's connection.

`plugins/signalk` is the worked example, over both TCP and a websocket, and
`plugins/nmea0183` is a second one.

Reference: [lists](wire.md#lists-a-group-the-mariner-adds-rows-to) and
[reconnecting is yours](rules.md#reconnecting-is-yours), which the SDK does
for you once it owns the row.

## Raising an alarm, and when not to

**Capabilities:** `alerts.raise`.

```zig
if (crossing and !alarmed) {
    alarmed = true;
    _ = lk.alert(.alarm, "AIS CPA alarm", "899000101: CPA 149 m in 591 s");
}
```

Severity is `alarm`, `warning`, `notice` or `caution`. An `alarm` is sounded and
keeps sounding until the mariner acknowledges it; the rest are shown and never
sounded. The host maps the same four to log levels: alarm at error, warning at
warn, the other two at info.

**Raise one only when the mariner must act now and would not otherwise know.**
Everything else is a status line. An alarm that fires when nothing is wrong gets
switched off, and then the real one is not heard.

**Decide it in `onUpdate`, not in `draw`.** The readings are what the alarm
answers to, so put the test where they land. An alarm decided in `draw` fires
at whatever rate suits the picture, and stops altogether for a plugin whose
drawing the mariner has switched off.

**Latch it.** Raise on the edge, not every tick, and re-arm only when the
condition has genuinely cleared. The latch matters more on the data path than
it did on the draw timer, because `onUpdate` runs an order of magnitude more
often. Give the gate a dead band if the quantity can sit on the limit: a
target parked at exactly the alarm distance must not alarm once a second.

**Put the target in the body.** The host tells one alert from another by your
plugin, the title and the body, so a title naming the condition and a body
naming the vessel gives one alarm per vessel. A title alone would collapse two
close passes into one.

Reference: [alert](wire.md#alert).

## Showing live status, per connection when there are rows

**Capabilities:** none. A status line needs no permission.

```zig
pub fn draw(c: *lk.Chart) void {
    c.status("TWD {d:.0} deg", .{wind});
    // or, when something is wrong that is not a missing input:
    c.degraded("the chart is out of date", .{});
}
```

**The SDK posts it once.** The host logs every status text it has not seen
before, so a repeat at 1 Hz would be a log line a second. The SDK sends
nothing while the text is unchanged. Say nothing at all and the plugin reads
`running`.

**You rarely need `degraded`.** A missing declared input already produces it,
naming the instrument. Use it for what the SDK cannot see.

**Round anything live.** A detail carrying a raw float changes every tick and is
a new line every tick. Round it, with `{d:.0}` on a wind direction or a
five-degree bucket, and the log stays readable.

**A connection list writes its own.** The SDK posts one item per row, under the
row id the shell assigned: `connected`, `paused`, `reconnecting`, `unreachable`
or `no_address`. The plugin line above them counts what is up:
`2 of 3 connected, 44 msg/s`.

Reference: [chrome_status](wire.md#chrome_status),
[status items](wire.md#status-items-one-line-per-row) and
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

Reference: [storage_get and storage_put](wire.md#storage_get-and-storage_put)
and [storage is small, and it is yours alone](rules.md#storage-is-small-and-it-is-yours-alone).

## Fetching from the internet

**Capabilities:** `{"net.http": ["nomads.ncep.noaa.gov"]}`. Name each host, and
never write a bare `net.http`.

**Status: raw calls only.** The SDK has no fetch helper yet. Use
`lk.raw.httpGet` or `lk.raw.httpFetch`, and take the answer in `onEvent`
as `.http_response`.

```zig
pub fn onEvent(e: lk.raw.Event) !void {
    switch (e) {
        .http_response => |r| if (r.status == 200) take(r.body),
        else => {},
    }
}
```

GET and HEAD only. A body is capped at 4 MiB, so ask for a range rather than a
file, and cache what you fetched in storage, because a boat's connection is
metered and often absent. There are no wildcards in the host list, and a
redirect off the host is refused.

Reference: [http_fetch](wire.md#http_fetch),
[name every server you reach](rules.md#name-every-server-you-reach) and
[ask for a range, not a file](rules.md#ask-for-a-range-not-a-file).

## Reading a file the mariner gives you

**Capabilities:** `files`.

**Status: raw calls only, and nothing can grant a file yet.** There is no
`file_open` import and there never will be, because a plugin cannot name a path.
A handle arrives as `.file_opened` because the mariner chose that file. The
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

Reference: [file_read and file_write](wire.md#file_read-and-file_write) and
[you cannot open a file](rules.md#you-cannot-open-a-file).

## Building an instrument display

**Status: not buildable today.**

There is no way to put a number on the screen from a plugin. The overlay draws
three things: symbols, lines and areas. None of them carries text. A plugin has
two places where words reach the mariner, and neither works as an instrument:

- **a pick payload**, which shows rows of text when a symbol is hovered or
  tapped;
- **the status line**, which today goes to the log and is not shown on screen.

What is coming is chrome readout blocks: a plugin declaring a readout, and the
app drawing it in its own idiom beside the other instruments, the way a settings
group is drawn today. That is not built, and no part of the ABI reserves it yet.

Until then, an instrument-shaped plugin reports through
[the status line](#showing-live-status-per-connection-when-there-are-rows) and
draws the thing itself (the guard ring, the layline, the vector) rather than a
number about it.

## What to read next

- [Build your first plugin](build-your-first.md) walks one plugin start to
  finish, including the manifest, the build command and the harness.
- [The rules](rules.md) collects the mistakes that cost a mariner something at
  sea. Read it before you copy any of the code above.
- [The wire protocol](wire.md) is what the SDK is written against, and what a raw
  plugin talks to directly.
- [The dev harness](dev-harness.md) runs your plugin against a recorded log and
  renders the chart it drew.
