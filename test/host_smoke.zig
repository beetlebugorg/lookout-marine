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
    const fr = try ov.buildIfNeeded(15.0, .day);
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
