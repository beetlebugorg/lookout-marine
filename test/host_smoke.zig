//! The plugin layer end to end: a real .wasm module, the real WAMR embedding,
//! the real broker natives, the real registry, and the real overlay store.
//!
//! The subject is plugins/echo — a throwaway that subscribes to a path, sets a
//! timer, draws one symbol and tries to raise an alert its manifest does not
//! ask for. Between them those four things touch every piece Phase 2 built.
//!
//! Kept out of src/plugin/ so the .wasm arrives as an anonymous import that
//! only this test root declares: importing host.zig must never drag a plugin
//! binary into the core.

const std = @import("std");
const host = @import("host");
const overlay = @import("overlay");

const broker = host.broker;
const vstore = host.store;
const aisstore = host.aisstore;

const echo_wasm = @embedFile("echo_plugin_wasm");
const echo_manifest = @embedFile("echo_manifest");

const echo_id = "org.beetlebug.echo";
const io = std.Io.Threaded.global_single_threaded.io();

/// Collects every line the broker logs, so the test can assert on the grant
/// refusal the way an operator would see it — in the log, not only in a
/// counter.
const LogSink = struct {
    text: std.ArrayList(u8) = .empty,
    alloc: std.mem.Allocator,
    mu: vstore.Lock = .{},

    fn write(ctx: ?*anyopaque, level: u32, plugin: []const u8, msg: []const u8) void {
        const self: *LogSink = @ptrCast(@alignCast(ctx.?));
        self.mu.lock();
        defer self.mu.unlock();
        self.text.print(self.alloc, "{d}|{s}|{s}\n", .{ level, plugin, msg }) catch {};
    }

    fn has(self: *LogSink, needle: []const u8) bool {
        self.mu.lock();
        defer self.mu.unlock();
        return std.mem.indexOf(u8, self.text.items, needle) != null;
    }
};

/// The overlay store behind broker.OverlaySink.
const OvSink = struct {
    fn apply(ctx: ?*anyopaque, source: []const u8, json: []const u8) anyerror!void {
        const s: *overlay.Store = @ptrCast(@alignCast(ctx.?));
        return s.applyBatch(source, json);
    }
    fn remove(ctx: ?*anyopaque, source: []const u8) void {
        const s: *overlay.Store = @ptrCast(@alignCast(ctx.?));
        s.removeSource(source);
    }
};

fn countOccurrences(sink: *LogSink, needle: []const u8) usize {
    sink.mu.lock();
    defer sink.mu.unlock();
    var n: usize = 0;
    var rest: []const u8 = sink.text.items;
    while (std.mem.indexOf(u8, rest, needle)) |i| {
        n += 1;
        rest = rest[i + needle.len ..];
    }
    return n;
}

/// One AIS_CHANGED payload of `n` targets, about 130 bytes each. `tick` shifts
/// the numbers so no two events carry identical bytes.
fn aisSnapshot(alloc: std.mem.Allocator, n: usize, tick: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"targets\":[");
    for (0..n) |i| {
        if (i > 0) try out.append(alloc, ',');
        const k: f64 = @floatFromInt((i * 7 + tick) % 500);
        try out.print(alloc,
            \\{{"mmsi":{d},"lat":{d:.5},"lon":{d:.5},"sog":{d:.2},"cog":{d:.1},"heading":{d:.1},"name":"TARGET {d:0>6}","ts":{d},"age_ms":{d}}}
        , .{
            366000000 + i,
            38.90 + k * 0.0001,
            -76.55 + k * 0.0001,
            k * 0.01,
            k * 0.7,
            k * 0.7 + 1.0,
            i,
            1_700_000_000_000 + @as(i64, @intCast(tick)) * 1000,
            tick % 900,
        });
    }
    try out.appendSlice(alloc, "]}");
    return out.toOwnedSlice(alloc);
}

/// Write the pair `zig build plugins` installs into a scratch directory, and
/// return the path the host loads from.
fn stage(alloc: std.mem.Allocator, tmp: *std.testing.TmpDir) ![]u8 {
    try tmp.dir.writeFile(io, .{ .sub_path = echo_id ++ ".wasm", .data = echo_wasm });
    try tmp.dir.writeFile(io, .{ .sub_path = echo_id ++ ".manifest.json", .data = echo_manifest });
    // A stray file with no manifest beside it must be ignored, not loaded.
    try tmp.dir.writeFile(io, .{ .sub_path = "notes.txt", .data = "ignore me" });
    return std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{tmp.sub_path});
}

test "the echo plugin loads, draws, and is refused the grant it never asked for" {
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const dir_path = try stage(alloc, &tmp);
    defer alloc.free(dir_path);

    var vessels = try vstore.Store.init(alloc);
    defer vessels.deinit();
    var ais = aisstore.AisStore.init(alloc);
    defer ais.deinit();
    var ov = overlay.Store.init(alloc);
    defer ov.deinit();
    var sink = LogSink{ .alloc = alloc };
    defer sink.text.deinit(alloc);

    var br = broker.Broker.init(alloc, &vessels, &ais, .{
        .ctx = &ov,
        .applyFn = OvSink.apply,
        .removeFn = OvSink.remove,
    });
    defer br.deinit();
    br.setLog(&sink, LogSink.write);

    var h = host.Host.init(alloc, &br, .{});
    defer h.deinit();

    try h.loadDir(dir_path);
    try std.testing.expectEqual(@as(usize, 1), h.count());
    const echo = h.find(echo_id) orelse return error.EchoNotLoaded;

    // lk_start ran: the manifest's three grants are in place, the plugin
    // subscribed, and it posted a status.
    try std.testing.expect(echo.caps.contains(.vessel_read));
    try std.testing.expect(echo.caps.contains(.overlay_draw));
    try std.testing.expect(!echo.caps.contains(.alerts_raise));
    try std.testing.expect(echo.sub != null);
    try std.testing.expect(std.mem.indexOf(u8, echo.status(), "\"running\"") != null);

    // ...and the alert it tried WITHOUT the grant was refused, counted, and
    // logged by the name of the capability it was missing.
    try std.testing.expectEqual(@as(u32, 1), echo.denied);
    try std.testing.expectEqual(@as(u32, 1), br.denied);
    try std.testing.expect(sink.has("denied alert: manifest does not request capability alerts.raise"));
    try std.testing.expectEqual(@as(usize, 0), echo.lastAlert().len);

    // A synthetic STORE_CHANGED, in the shape the fanout tick builds. The echo
    // plugin answers it by drawing its symbol at the position it was given.
    try std.testing.expectEqual(@as(usize, 0), ov.count());
    br.push(echo.index, broker.Kind.store_changed, 0,
        \\{"values":[{"path":"navigation.position","value":{"lat":38.98,"lon":-76.47},"ts":1000,"age_ms":120}]}
    );
    try std.testing.expectEqual(@as(usize, 1), h.pump());

    try std.testing.expectEqual(@as(usize, 1), ov.count());
    // The host namespaces overlay ids by plugin, so two plugins may both call
    // an object "echo".
    try std.testing.expect(ov.objs.contains(echo_id ++ "/echo"));
    const fr = try ov.buildIfNeeded(15.0, .day, null);
    try std.testing.expectEqual(@as(usize, overlay.TARGET_VERTS), fr.verts.len);
    // Drawn where the payload said, not at the plugin's fallback position.
    const at = overlay.geo(.{ -76.47, 38.98 });
    var near = false;
    for (fr.verts) |v| {
        if (@abs(@as(f64, v.x) - at.x) < 1e-4 and @abs(@as(f64, v.y) - at.y) < 1e-4) near = true;
    }
    try std.testing.expect(near);

    // An unknown event kind is ignored and answered 0, not trapped.
    br.push(echo.index, 77, 0, "{}");
    try std.testing.expectEqual(@as(usize, 1), h.pump());
    try std.testing.expect(!sink.has("trapped"));

    // SHUTDOWN is delivered and takes the plugin's overlay objects with it.
    h.stop();
    try std.testing.expect(sink.has("shutdown after"));
    try std.testing.expectEqual(@as(usize, 0), ov.count());
}

// Settings, end to end: the schema out of the manifest, the defaults into
// lk_start, a change through configSet, the CONFIG_CHANGED event that carries
// the whole config, and the plugin acting on it.
//
// The subject is echo's `draw` toggle, because a toggle a plugin obeys is
// visible in the overlay store: on it draws its symbol, off it deletes it.
// Asserting on the object rather than on a log line is the point — this is the
// path the mariner's switch travels.
test "a settings change reaches the plugin and changes what it draws" {
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const dir_path = try stage(alloc, &tmp);
    defer alloc.free(dir_path);

    var vessels = try vstore.Store.init(alloc);
    defer vessels.deinit();
    var ais = aisstore.AisStore.init(alloc);
    defer ais.deinit();
    var ov = overlay.Store.init(alloc);
    defer ov.deinit();
    var sink = LogSink{ .alloc = alloc };
    defer sink.text.deinit(alloc);

    var br = broker.Broker.init(alloc, &vessels, &ais, .{
        .ctx = &ov,
        .applyFn = OvSink.apply,
        .removeFn = OvSink.remove,
    });
    defer br.deinit();
    br.setLog(&sink, LogSink.write);

    var h = host.Host.init(alloc, &br, .{});
    defer h.deinit();
    try h.loadDir(dir_path);
    const echo = h.find(echo_id) orelse return error.EchoNotLoaded;

    // The schema arrived with the manifest, and the registry JSON carries it
    // with the defaults as the values in force.
    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(alloc);
    try h.registryJson(&json);
    try std.testing.expect(std.mem.indexOf(u8, json.items, "\"key\":\"draw\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json.items, "\"kind\":\"toggle\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json.items, "\"default\":true,\"value\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json.items, "\"min\":0.5,\"max\":3") != null);

    json.clearRetainingCapacity();
    try h.configJson(echo_id, &json);
    try std.testing.expectEqualStrings("{\"draw\":true,\"scale\":1}", json.items);

    // Draw once at the default scale.
    br.push(echo.index, broker.Kind.store_changed, 0,
        \\{"values":[{"path":"navigation.position","value":{"lat":38.98,"lon":-76.47},"ts":1000,"age_ms":10}]}
    );
    try std.testing.expectEqual(@as(usize, 1), h.pump());
    try std.testing.expect(ov.objs.contains(echo_id ++ "/echo"));
    const fr = try ov.buildIfNeeded(15.0, .day, null);
    const one_x = fr.verts[0].x;

    // A key the schema does not declare is ignored, and a number outside its
    // range is clamped rather than refused.
    try h.configSet(echo_id, "{\"scale\":9,\"nonsense\":1}");
    try std.testing.expectEqual(@as(usize, 1), h.pump());
    json.clearRetainingCapacity();
    try h.configJson(echo_id, &json);
    try std.testing.expectEqualStrings("{\"draw\":true,\"scale\":3}", json.items);
    // The plugin redrew at the new scale: the same symbol, wider.
    const bigger = try ov.buildIfNeeded(15.0, .day, null);
    try std.testing.expect(@abs(bigger.verts[0].x - one_x) > 0);

    // The toggle off: the plugin deletes its own object.
    try h.configSet(echo_id, "{\"draw\":false}");
    try std.testing.expectEqual(@as(usize, 1), h.pump());
    try std.testing.expect(!ov.objs.contains(echo_id ++ "/echo"));
    try std.testing.expect(sink.has("config draw false"));
    // The change is what the plugin was told, not what it was asked: the whole
    // config, every field, one event.
    try std.testing.expect(sink.has("config {\"draw\":false,\"scale\":3}"));

    // ...and back on, with nothing else touched.
    try h.configSet(echo_id, "{\"draw\":true}");
    try std.testing.expectEqual(@as(usize, 1), h.pump());
    try std.testing.expect(ov.objs.contains(echo_id ++ "/echo"));

    // An unknown plugin, a config that is not an object, and a toggle sent as
    // a number are all refused without touching what is in force.
    try std.testing.expectError(host.Error.UnknownPlugin, h.configSet("org.nobody", "{}"));
    try std.testing.expectError(host.Error.BadConfig, h.configSet(echo_id, "[]"));
    try std.testing.expectError(host.Error.BadConfig, h.configSet(echo_id, "{\"draw\":1}"));
    json.clearRetainingCapacity();
    try h.configJson(echo_id, &json);
    try std.testing.expectEqualStrings("{\"draw\":true,\"scale\":3}", json.items);
    try std.testing.expect(!sink.has("trapped"));
}

// The arena regression. A payload big enough that parsing it needs more
// scratch than the plugin's static buffer holds makes lk.zig grow linear
// memory INSIDE the event. The first version of that arena abandoned the
// region it grew out of and never rewound into it again, so every such event
// leaked a region: the instance ran out of memory after about forty of them,
// lk_alloc answered 0, and the host disabled the plugin for good.
//
// The subject is echo's AIS_CHANGED handler, which parses the whole snapshot
// through `lk.targets` — the same path the ais plugin's rebuild takes. What is
// asserted is not a byte count (the plugin cannot report one) but the
// behaviour that count decides: 150 identical-sized events all arrive, all
// finish, and none traps.
test "a plugin survives repeated events whose scratch outgrows its arena" {
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const dir_path = try stage(alloc, &tmp);
    defer alloc.free(dir_path);

    var vessels = try vstore.Store.init(alloc);
    defer vessels.deinit();
    var ais = aisstore.AisStore.init(alloc);
    defer ais.deinit();
    var ov = overlay.Store.init(alloc);
    defer ov.deinit();
    var sink = LogSink{ .alloc = alloc };
    defer sink.text.deinit(alloc);

    var br = broker.Broker.init(alloc, &vessels, &ais, .{
        .ctx = &ov,
        .applyFn = OvSink.apply,
        .removeFn = OvSink.remove,
    });
    defer br.deinit();
    br.setLog(&sink, LogSink.write);

    var h = host.Host.init(alloc, &br, .{});
    defer h.deinit();
    try h.loadDir(dir_path);
    const echo = h.find(echo_id) orelse return error.EchoNotLoaded;

    // 230 targets is a little over 30 kB — several times the 256 kB static
    // arena once std.json has a Value tree for it.
    const targets_per_event = 230;
    const events = 150;
    for (0..events) |tick| {
        const payload = try aisSnapshot(alloc, targets_per_event, tick);
        defer alloc.free(payload);
        try std.testing.expect(payload.len > 28 * 1024);
        br.push(echo.index, broker.Kind.ais_changed, 0, payload);
        try std.testing.expectEqual(@as(usize, 1), h.pump());
    }

    try std.testing.expect(!sink.has("trapped"));
    try std.testing.expect(!sink.has("disabled"));
    // The plugin logs one line per snapshot naming how many targets it parsed,
    // so the count is proof every event ran to the end of the handler — not
    // merely that the host stayed up.
    try std.testing.expectEqual(
        @as(usize, events),
        countOccurrences(&sink, std.fmt.comptimePrint("{d} ais targets", .{targets_per_event})),
    );
}

test "the dispatch and I/O threads deliver a periodic timer and a fanout tick" {
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const dir_path = try stage(alloc, &tmp);
    defer alloc.free(dir_path);

    var vessels = try vstore.Store.init(alloc);
    defer vessels.deinit();
    var ais = aisstore.AisStore.init(alloc);
    defer ais.deinit();
    var ov = overlay.Store.init(alloc);
    defer ov.deinit();
    var sink = LogSink{ .alloc = alloc };
    defer sink.text.deinit(alloc);

    var br = broker.Broker.init(alloc, &vessels, &ais, .{
        .ctx = &ov,
        .applyFn = OvSink.apply,
        .removeFn = OvSink.remove,
    });
    defer br.deinit();
    br.setLog(&sink, LogSink.write);

    var h = host.Host.init(alloc, &br, .{});
    defer h.deinit();
    try h.loadDir(dir_path);
    const echo = h.find(echo_id) orelse return error.EchoNotLoaded;

    try h.start();
    // A publish from another source reaches the plugin only through the
    // fanout tick, which also proves refresh/collect/JSON all run on the I/O
    // thread. 1500 ms is many tick periods; the loop leaves as soon as both
    // have happened.
    try vessels.set("navigation.position", "{\"lat\":38.9,\"lon\":-76.5}", broker.wallMs(), 9);
    var timer_fired = false;
    var drew = false;
    var waited: u32 = 0;
    while (waited < 1500) : (waited += 10) {
        // Sampled before shutdown: the plugin's own SHUTDOWN handler replaces
        // the status with "stopped", which would erase the evidence.
        if (std.mem.indexOf(u8, echo.status(), "ticks") != null) timer_fired = true;
        if (ov.count() > 0) drew = true;
        if (timer_fired and drew) break;
        broker.sleepMs(10);
    }
    h.stop();

    try std.testing.expect(timer_fired);
    try std.testing.expect(drew);
    try std.testing.expectEqual(@as(usize, 0), ov.count()); // shutdown cleared it
    try std.testing.expect(sink.has("navigation.position age"));
    try std.testing.expect(!sink.has("trapped"));
}
