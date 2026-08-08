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
const nmea_manifest = @embedFile("nmea_manifest");
const ais_manifest = @embedFile("ais_manifest");

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
    const fr = try ov.buildIfNeeded(15.0, 0, .day, null);
    try std.testing.expectEqual(@as(usize, overlay.TARGET_VERTS), fr.verts.len);
    // Drawn where the payload said, not at the plugin's fallback position.
    // Vertices are measured from the frame's origin, so put them back first.
    const at = overlay.geo(.{ -76.47, 38.98 });
    var near = false;
    for (fr.verts) |v| {
        if (@abs(@as(f64, v.x) + fr.origin.x - at.x) < 1e-4 and
            @abs(@as(f64, v.y) + fr.origin.y - at.y) < 1e-4) near = true;
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
    try std.testing.expect(std.mem.indexOf(u8, json.items, "\"default\":true,\"tab\":\"advanced\",\"value\":true") != null);
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
    const fr = try ov.buildIfNeeded(15.0, 0, .day, null);
    const one_x = fr.verts[0].x;

    // A key the schema does not declare is ignored, and a number outside its
    // range is clamped rather than refused.
    try h.configSet(echo_id, "{\"scale\":9,\"nonsense\":1}");
    try std.testing.expectEqual(@as(usize, 1), h.pump());
    json.clearRetainingCapacity();
    try h.configJson(echo_id, &json);
    try std.testing.expectEqualStrings("{\"draw\":true,\"scale\":3}", json.items);
    // The plugin redrew at the new scale: the same symbol, wider.
    const bigger = try ov.buildIfNeeded(15.0, 0, .day, null);
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
    // The proof below is a count of the fixture's own log lines, one per
    // snapshot, pushed as fast as `pump` will take them. That is far over the
    // shipped log budget, which would drop most of them and read here as
    // events that never ran, so this test lifts the ceiling. The budget is
    // proved where it belongs, in broker.zig's own tests.
    br.budgets.log_lines_per_s = 1_000_000;

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

// ---------------------------------------------------------------------------
// files the mariner opens
// ---------------------------------------------------------------------------

/// Stage the echo module under another id, with a manifest of the caller's
/// making. The routing tests need plugins that CLAIM FILE TYPES, and what the
/// module does with the file is beside the point — the subject is the path from
/// the mariner's open panel to a handle the plugin can read.
fn stageAs(tmp: *std.testing.TmpDir, id: []const u8, manifest: []const u8) !void {
    var buf: [128]u8 = undefined;
    try tmp.dir.writeFile(io, .{
        .sub_path = try std.fmt.bufPrint(&buf, "{s}.wasm", .{id}),
        .data = echo_wasm,
    });
    var buf2: [128]u8 = undefined;
    try tmp.dir.writeFile(io, .{
        .sub_path = try std.fmt.bufPrint(&buf2, "{s}.manifest.json", .{id}),
        .data = manifest,
    });
}

/// `vessel.read` and `overlay.draw` are what the echo module needs to start at
/// all; `files` is what the claim rests on.
const grib_id = "org.beetlebug.grib";
const grib_manifest =
    \\{"id":"org.beetlebug.grib","name":"Weather files","api":1,
    \\ "capabilities":["vessel.read","overlay.draw","files"],
    \\ "file_types":[".grib2",".grb",".pmtiles"]}
;

const fixture_bytes = "GRIB\x02not really a weather file";

test "a file the mariner opens reaches the plugin that claims its type" {
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const dir_path = try stage(alloc, &tmp);
    defer alloc.free(dir_path);
    try stageAs(&tmp, grib_id, grib_manifest);
    // Two fixtures: one named the way a download arrives, one SHOUTED, so the
    // case the mariner's disk holds cannot decide whether the file routes.
    try tmp.dir.writeFile(io, .{ .sub_path = "gfs.grib2", .data = fixture_bytes });
    try tmp.dir.writeFile(io, .{ .sub_path = "WIND.GRB", .data = fixture_bytes });

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
    try std.testing.expectEqual(@as(usize, 2), h.count());
    const grib = h.find(grib_id) orelse return error.GribNotLoaded;

    // The registry a shell reads carries the claim, so an open panel can say
    // what it now accepts without knowing what a plugin is.
    var reg: std.ArrayList(u8) = .empty;
    defer reg.deinit(alloc);
    try h.registryJson(&reg);
    try std.testing.expect(std.mem.indexOf(u8, reg.items, "\"file_types\":[\".grib2\",\".grb\",\".pmtiles\"]") != null);
    // A plugin that claims none writes no key at all.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, reg.items, "\"file_types\""));

    // A type NOBODY claims is not the plugin layer's business: the shell does
    // with it whatever it did before there were plugins.
    const notes = try std.fmt.allocPrint(alloc, "{s}/notes.txt", .{dir_path});
    defer alloc.free(notes);
    try std.testing.expect(!try h.openFile(notes));

    // A CHART keeps the path it always took, even though this manifest claims
    // .pmtiles. Nothing is granted and nothing is queued.
    const chart = try std.fmt.allocPrint(alloc, "{s}/US5MD1MC.pmtiles", .{dir_path});
    defer alloc.free(chart);
    try std.testing.expect(!try h.openFile(chart));
    try std.testing.expect(br.popFor(grib.index) == null);

    // The claimed one routes, and FILE_OPENED carries the handle, the name the
    // mariner would recognise, the size and the access.
    const grib_path = try std.fmt.allocPrint(alloc, "{s}/gfs.grib2", .{dir_path});
    defer alloc.free(grib_path);
    try std.testing.expect(try h.openFile(grib_path));

    const ev = br.popFor(grib.index) orelse return error.NoFileOpened;
    defer br.freeEvent(ev);
    try std.testing.expectEqual(broker.Kind.file_opened, ev.kind);
    try std.testing.expect(ev.handle != 0);
    var expected: [96]u8 = undefined;
    try std.testing.expectEqualStrings(
        try std.fmt.bufPrint(&expected, "{{\"name\":\"gfs.grib2\",\"size\":{d},\"mode\":\"read\"}}", .{fixture_bytes.len}),
        ev.payload,
    );

    // The handle the event carries is one `file_read` answers, which is the
    // whole point of the grant.
    var got: [64]u8 = undefined;
    const n = br.fileRead(grib.index, @bitCast(ev.handle), 0, &got);
    try std.testing.expectEqual(@as(i32, fixture_bytes.len), n);
    try std.testing.expectEqualStrings(fixture_bytes, got[0..@intCast(n)]);

    // The name on disk is SHOUTED and the manifest is not: the same plugin
    // still gets it.
    const shouted = try std.fmt.allocPrint(alloc, "{s}/WIND.GRB", .{dir_path});
    defer alloc.free(shouted);
    try std.testing.expect(try h.openFile(shouted));
    const ev2 = br.popFor(grib.index) orelse return error.NoFileOpened;
    defer br.freeEvent(ev2);
    try std.testing.expectEqual(broker.Kind.file_opened, ev2.kind);
    try std.testing.expect(std.mem.indexOf(u8, ev2.payload, "\"name\":\"WIND.GRB\"") != null);

    // The plugin is entered with the event and does not trap on a kind it does
    // not handle.
    br.push(grib.index, broker.Kind.file_opened, ev2.handle, ev2.payload);
    try std.testing.expectEqual(@as(usize, 1), h.pump());
    try std.testing.expect(!sink.has("trapped"));

    // A file that is not there is a refusal, not a silent nothing.
    const missing = try std.fmt.allocPrint(alloc, "{s}/nowhere.grib2", .{dir_path});
    defer alloc.free(missing);
    try std.testing.expectError(error.FileNotFound, h.openFile(missing));
}

test "two plugins claiming one file type both lose it, and the log names them" {
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const dir_path = try stage(alloc, &tmp);
    defer alloc.free(dir_path);
    try stageAs(&tmp, grib_id, grib_manifest);
    try stageAs(&tmp, "org.beetlebug.weather",
        \\{"id":"org.beetlebug.weather","name":"Weather too","api":1,
        \\ "capabilities":["vessel.read","overlay.draw","files"],
        \\ "file_types":[".grib2"]}
    );
    // A claim with no `files` behind it: the manifest is refused, so the plugin
    // never loads and never competes for the type either.
    try stageAs(&tmp, "org.beetlebug.ungranted",
        \\{"id":"org.beetlebug.ungranted","name":"No grant","api":1,
        \\ "capabilities":["vessel.read","overlay.draw"],
        \\ "file_types":[".grib2"]}
    );
    try tmp.dir.writeFile(io, .{ .sub_path = "gfs.grib2", .data = fixture_bytes });

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
    try std.testing.expectEqual(@as(usize, 3), h.count()); // echo + the two granted
    try std.testing.expect(h.find("org.beetlebug.ungranted") == null);
    try std.testing.expect(sink.has("org.beetlebug.ungranted not loaded: BadManifest"));

    const grib_path = try std.fmt.allocPrint(alloc, "{s}/gfs.grib2", .{dir_path});
    defer alloc.free(grib_path);
    try std.testing.expectError(host.Error.FileTypeConflict, h.openFile(grib_path));

    // One line, both names: load order must not decide who reads the mariner's
    // weather.
    try std.testing.expect(sink.has(
        ".grib2 is claimed by both org.beetlebug.grib and org.beetlebug.weather",
    ));
    // Neither was given anything.
    try std.testing.expect(br.popFor(h.find(grib_id).?.index) == null);
    try std.testing.expect(br.popFor(h.find("org.beetlebug.weather").?.index) == null);
}

test "every manifest the app ships parses under the real parser" {
    const a = std.testing.allocator;
    // A schema this parser refuses is a plugin that silently does not load,
    // and the harness then waits forever for a connection nobody makes.
    inline for (.{ nmea_manifest, ais_manifest, echo_manifest }) |text| {
        var m = try host.parseManifest(a, text);
        defer m.deinit(a);
        try std.testing.expect(m.id.len > 0);
    }

    // The AIS targets dialog only opens because the manifest carries its key:
    // the host refuses a runtime declaration the manifest does not account
    // for, so a manifest edited apart from the module loses the dialog.
    var ais = try host.parseManifest(a, ais_manifest);
    defer ais.deinit(a);
    try std.testing.expect(ais.declaresTable("targets"));

    // The gateway plugin dials the boat's own network and asks for no more
    // than that. A shipped manifest that lost its address list would be a
    // plugin refused at its first connection, on the water.
    var nmea = try host.parseManifest(a, nmea_manifest);
    defer nmea.deinit(a);
    try std.testing.expect(nmea.caps.contains(.net_tcp_client));
    try std.testing.expectEqual(@as(usize, 1), nmea.tcp_addrs.len);
    try std.testing.expectEqualStrings("local", nmea.tcp_addrs[0]);
    try std.testing.expect(!nmea.caps.contains(.net_http));
    try std.testing.expect(!nmea.caps.contains(.net_udp));

    // ...and the sentence the mariner reads says which network that is.
    var sentence: std.ArrayList(u8) = .empty;
    defer sentence.deinit(a);
    try host.writeSentence(&sentence, a, .net_tcp_client, &nmea);
    try std.testing.expectEqualStrings("Connect to instruments on: your own network.", sentence.items);
}
