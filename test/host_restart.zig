//! WHAT A TRAP COSTS, end to end: real .wasm plugins, the real WAMR embedding,
//! the real broker and the real registry, one of which breaks on cue.
//!
//! What is proved here, each of it a promise the core keeps whatever a plugin
//! does (specs/plugins/hardening.md):
//!
//!   1. A plugin that traps inside `lk_start` is absent from the registry and
//!      takes nothing with it. Every OTHER plugin keeps its settings schema, so
//!      the mariner's window keeps Vessels, Alarms and Connections.
//!   2. A plugin that traps while running comes BACK: after a second, with its
//!      settings and its connection rows as they stand, an empty scene, and no
//!      globals.
//!   3. A plugin that cannot start comes back three times and then stops, and
//!      its status line says so in as many words.
//!   4. A plugin that traps on its way out is not brought back.
//!   5. A row past what a list holds is dropped out loud, and the schema says
//!      how many rows that is.
//!   6. An id two directories both offer goes to the higher origin, whichever
//!      directory was scanned first.
//!
//! Kept out of src/plugin/ for the same reason test/host_isolation.zig is: the
//! .wasm modules arrive as anonymous imports only a test root declares.

const std = @import("std");
const host = @import("host");
const overlay = @import("overlay");

const broker = host.broker;
const vstore = host.store;
const aisstore = host.aisstore;

const echo_wasm = @embedFile("echo_plugin_wasm");
const echo_manifest = @embedFile("echo_manifest");
const trap_wasm = @embedFile("trap_plugin_wasm");

const echo_id = "org.beetlebug.echo";
const trap_id = "org.beetlebug.trap";
/// The copy that traps inside `lk_start`. Named to sort FIRST, so it is loaded
/// before the plugins whose schemas have to survive it.
const broken_id = "org.beetlebug.aabroken";

/// The timer id test/trap_plugin.zig treats as "trap now".
const trap_timer_id: u64 = 515151;

/// The fixture's manifest: two scalar settings and one list, which is every
/// shape a settings window has to keep. `trap_at_start` is the switch that
/// makes `lk_start` trap, so a test can turn it on while the plugin runs and
/// watch every restart fail.
fn fixtureManifest(comptime id: []const u8, comptime trap_at_start: []const u8) []const u8 {
    return "{\"id\":\"" ++ id ++ "\",\"name\":\"Trap fixture\",\"api\":1," ++
        "\"capabilities\":[\"overlay.draw\"]," ++
        "\"settings\":{\"groups\":[" ++
        "{\"label\":\"Fixture\",\"tab\":\"advanced\",\"fields\":[" ++
        "{\"key\":\"mark\",\"label\":\"Mark\",\"kind\":\"number\",\"min\":0,\"max\":1000,\"default\":0}," ++
        "{\"key\":\"trap_at_start\",\"label\":\"Trap at start\",\"kind\":\"toggle\",\"default\":" ++ trap_at_start ++ "}," ++
        "{\"key\":\"trap_at_shutdown\",\"label\":\"Trap at shutdown\",\"kind\":\"toggle\",\"default\":false}]}," ++
        "{\"label\":\"Connections\",\"tab\":\"connections\",\"list\":{\"key\":\"connections\"," ++
        "\"add_label\":\"Add Gateway\",\"item_fields\":[" ++
        "{\"key\":\"host\",\"label\":\"Address\",\"kind\":\"text\",\"default\":\"\"}," ++
        "{\"key\":\"port\",\"label\":\"Port\",\"kind\":\"number\",\"min\":1,\"max\":65535,\"default\":10110}," ++
        "{\"key\":\"enabled\",\"label\":\"On\",\"kind\":\"toggle\",\"default\":true}]}}]}}";
}

const trap_manifest = fixtureManifest(trap_id, "false");
const broken_manifest = fixtureManifest(broken_id, "true");

const io = std.Io.Threaded.global_single_threaded.io();

/// LOOKOUT_PLUGINS is what tells the host a flat directory is the DEVELOPER
/// override rather than the bundled set, and the precedence test needs both.
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

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

    fn count(self: *LogSink, needle: []const u8) usize {
        self.mu.lock();
        defer self.mu.unlock();
        var n: usize = 0;
        var rest: []const u8 = self.text.items;
        while (std.mem.indexOf(u8, rest, needle)) |i| {
            n += 1;
            rest = rest[i + needle.len ..];
        }
        return n;
    }
};

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

fn hasObject(ov: *overlay.Store, id: []const u8) bool {
    ov.mu.lock();
    defer ov.mu.unlock();
    return ov.objs.contains(id);
}

/// Everything one test needs in one place: the stores, the broker, the log and
/// the host, wired the way the application wires them.
const Rig = struct {
    alloc: std.mem.Allocator,
    tmp: std.testing.TmpDir,
    dir_path: []u8,
    vessels: *vstore.Store,
    ais: *aisstore.AisStore,
    ov: *overlay.Store,
    sink: *LogSink,
    br: *broker.Broker,
    h: *host.Host,

    fn init(alloc: std.mem.Allocator, opts: host.Options) !Rig {
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();
        const dir_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{tmp.sub_path});

        const vessels = try alloc.create(vstore.Store);
        vessels.* = try vstore.Store.init(alloc);
        const ais = try alloc.create(aisstore.AisStore);
        ais.* = aisstore.AisStore.init(alloc);
        const ov = try alloc.create(overlay.Store);
        ov.* = overlay.Store.init(alloc);
        const sink = try alloc.create(LogSink);
        sink.* = .{ .alloc = alloc };
        const br = try alloc.create(broker.Broker);
        br.* = broker.Broker.init(alloc, vessels, ais, .{
            .ctx = ov,
            .applyFn = OvSink.apply,
            .removeFn = OvSink.remove,
        });
        br.setLog(sink, LogSink.write);
        const h = try alloc.create(host.Host);
        h.* = host.Host.init(alloc, br, opts);
        return .{
            .alloc = alloc,
            .tmp = tmp,
            .dir_path = dir_path,
            .vessels = vessels,
            .ais = ais,
            .ov = ov,
            .sink = sink,
            .br = br,
            .h = h,
        };
    }

    /// Torn down in the order root.zig tears the real one down: the host before
    /// the broker, both before the stores they write to.
    fn deinit(self: *Rig) void {
        self.h.deinit();
        self.br.deinit();
        self.ov.deinit();
        self.ais.deinit();
        self.vessels.deinit();
        self.sink.text.deinit(self.alloc);
        self.alloc.destroy(self.h);
        self.alloc.destroy(self.br);
        self.alloc.destroy(self.sink);
        self.alloc.destroy(self.ov);
        self.alloc.destroy(self.ais);
        self.alloc.destroy(self.vessels);
        self.alloc.free(self.dir_path);
        self.tmp.cleanup();
    }

    /// The pairs `zig build plugins` installs, written into this rig's own
    /// directory. Load order is sorted file order.
    fn stage(self: *Rig, with_broken: bool) !void {
        try self.tmp.dir.writeFile(io, .{ .sub_path = echo_id ++ ".wasm", .data = echo_wasm });
        try self.tmp.dir.writeFile(io, .{ .sub_path = echo_id ++ ".manifest.json", .data = echo_manifest });
        try self.tmp.dir.writeFile(io, .{ .sub_path = trap_id ++ ".wasm", .data = trap_wasm });
        try self.tmp.dir.writeFile(io, .{ .sub_path = trap_id ++ ".manifest.json", .data = trap_manifest });
        if (!with_broken) return;
        try self.tmp.dir.writeFile(io, .{ .sub_path = broken_id ++ ".wasm", .data = trap_wasm });
        try self.tmp.dir.writeFile(io, .{ .sub_path = broken_id ++ ".manifest.json", .data = broken_manifest });
    }

    fn registry(self: *Rig, out: *std.ArrayList(u8)) !void {
        out.clearRetainingCapacity();
        try self.h.registryJson(out);
    }
};

/// Wait for `pred` up to `timeout_ms`, polling every 5 ms. Returns how long it
/// took, or an error if it never came true.
fn waitFor(timeout_ms: u32, ctx: anytype, comptime pred: fn (@TypeOf(ctx)) bool) !u32 {
    var waited: u32 = 0;
    while (waited < timeout_ms) : (waited += 5) {
        if (pred(ctx)) return waited;
        broker.sleepMs(5);
    }
    return error.TimedOut;
}

fn isDown(p: *broker.Plugin) bool {
    return !p.enabled;
}

fn isUp(p: *broker.Plugin) bool {
    return p.enabled;
}

// THE REGRESSION. A plugin that trapped on the way up must be absent from the
// settings schema, and nothing else about that schema may change. The window
// losing Vessels, Alarms and Connections because one third-party plugin could
// not start is the failure this test exists to catch.
test "a plugin that traps inside lk_start leaves every other schema whole" {
    const alloc = std.testing.allocator;
    var rig = try Rig.init(alloc, .{});
    defer rig.deinit();
    try rig.stage(true);

    try rig.h.loadDir(rig.dir_path);

    // The broken one is gone and said why; the other two are up.
    try std.testing.expectEqual(@as(usize, 2), rig.h.count());
    try std.testing.expect(rig.sink.has("lk_start trapped: "));
    try std.testing.expect(rig.sink.has("unreachable"));
    try std.testing.expect(rig.sink.has("plugins: " ++ broken_id ++ " not loaded"));
    try std.testing.expect(rig.h.find(broken_id) == null);
    try std.testing.expect(rig.h.find(echo_id) != null);
    try std.testing.expect(rig.h.find(trap_id) != null);

    var reg: std.ArrayList(u8) = .empty;
    defer reg.deinit(alloc);
    try rig.registry(&reg);
    const s = reg.items;

    // Every other plugin's schema, whole: the scalar fields, the list, the
    // columns of one row and the tab each asked for.
    try std.testing.expect(std.mem.indexOf(u8, s, "\"id\":\"" ++ echo_id ++ "\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"key\":\"draw\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"key\":\"scale\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"id\":\"" ++ trap_id ++ "\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"key\":\"mark\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"key\":\"trap_at_start\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"key\":\"connections\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"tab\":\"connections\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"key\":\"port\"") != null);
    // The plugin that never started is simply absent.
    try std.testing.expect(std.mem.indexOf(u8, s, broken_id) == null);

    // HOW MANY ROWS THE LIST HOLDS travels with the schema, so a shell can stop
    // offering Add at the cap instead of letting the mariner add a row the host
    // will drop.
    try std.testing.expect(std.mem.indexOf(u8, s, "\"max_rows\":8") != null);

    // And the two that did start still work: settings go in, the plugin hears
    // them, and the schema reads back the same.
    try rig.h.start();
    try rig.h.configSet(echo_id, "{\"scale\":2}");
    try rig.registry(&reg);
    try std.testing.expect(std.mem.indexOf(u8, reg.items, "\"key\":\"scale\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, reg.items, "\"value\":2") != null);

    // The same again HOT, which is the path an install takes: the dispatch
    // threads are running, the other plugins are mid-flight, and the plugin
    // that cannot start arrives anyway.
    var hot = std.testing.tmpDir(.{ .iterate = true });
    defer hot.cleanup();
    try hot.dir.writeFile(io, .{ .sub_path = broken_id ++ ".wasm", .data = trap_wasm });
    try hot.dir.writeFile(io, .{ .sub_path = broken_id ++ ".manifest.json", .data = broken_manifest });
    const hot_dir = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{hot.sub_path});
    defer alloc.free(hot_dir);
    try rig.h.loadDir(hot_dir);

    try std.testing.expectEqual(@as(usize, 2), rig.h.count());
    try std.testing.expect(rig.h.find(broken_id) == null);
    try rig.registry(&reg);
    try std.testing.expect(std.mem.indexOf(u8, reg.items, broken_id) == null);
    try std.testing.expect(std.mem.indexOf(u8, reg.items, "\"key\":\"draw\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, reg.items, "\"key\":\"scale\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, reg.items, "\"key\":\"mark\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, reg.items, "\"key\":\"connections\"") != null);

    // Both survivors are still answering events, not merely still listed.
    const echo = rig.h.find(echo_id) orelse return error.EchoNotLoaded;
    const trap = rig.h.find(trap_id) orelse return error.TrapNotLoaded;
    rig.br.push(trap.index, broker.Kind.timer, 1, "");
    _ = try waitFor(2_000, rig.sink, struct {
        fn f(log: *LogSink) bool {
            return log.has("\"detail\":\"1 events\"");
        }
    }.f);
    try std.testing.expect(echo.enabled);
    try std.testing.expect(trap.enabled);
    rig.h.stop();
}

// A row past the cap is dropped by the host before the plugin ever sees it,
// which used to happen in silence. The mariner filled that row in and would
// otherwise wait for a connection nobody is making.
test "a row past the list cap is dropped out loud" {
    const alloc = std.testing.allocator;
    var rig = try Rig.init(alloc, .{});
    defer rig.deinit();
    try rig.stage(false);
    try rig.h.loadDir(rig.dir_path);
    try rig.h.start();

    var rows: std.ArrayList(u8) = .empty;
    defer rows.deinit(alloc);
    try rows.appendSlice(alloc, "{\"connections\":[");
    for (0..9) |i| {
        if (i > 0) try rows.append(alloc, ',');
        try rows.print(alloc, "{{\"id\":\"c{d}\",\"host\":\"10.0.0.{d}\",\"port\":10110,\"enabled\":true}}", .{ i, i });
    }
    try rows.appendSlice(alloc, "]}");
    try rig.h.configSet(trap_id, rows.items);

    try std.testing.expect(rig.sink.has("1 row past the 8 a list holds was dropped"));
    var reg: std.ArrayList(u8) = .empty;
    defer reg.deinit(alloc);
    try rig.registry(&reg);
    try std.testing.expectEqual(@as(usize, 8), std.mem.count(u8, reg.items, "\"port\":10110"));
    rig.h.stop();
}

// THE RESTART. One malformed sentence is one trap, and the mariner's
// instruments must come back without a relaunch.
test "a trapped plugin comes back after a second, with its settings and connections" {
    const alloc = std.testing.allocator;
    var rig = try Rig.init(alloc, .{});
    defer rig.deinit();
    try rig.stage(false);

    // The shipped schedule, not a shortened one: what this proves is what the
    // host does by default.
    try std.testing.expectEqual(@as(usize, 3), rig.h.opts.restart_backoff_ms.len);
    try std.testing.expectEqual(@as(i64, 1_000), rig.h.opts.restart_backoff_ms[0]);

    try rig.h.loadDir(rig.dir_path);
    const echo = rig.h.find(echo_id) orelse return error.EchoNotLoaded;
    const trap = rig.h.find(trap_id) orelse return error.TrapNotLoaded;
    try rig.h.start();

    // The mariner's settings and one connection row, in force before the trap.
    try rig.h.configSet(trap_id, "{\"mark\":42,\"connections\":[" ++
        "{\"id\":\"c1\",\"host\":\"10.0.0.9\",\"port\":10110,\"enabled\":true}]}");
    _ = try waitFor(2_000, rig.sink, struct {
        fn f(s: *LogSink) bool {
            return s.has("events, new settings");
        }
    }.f);
    try std.testing.expect(hasObject(rig.ov, trap_id ++ "/trap"));

    const pushed = broker.monoMs();
    rig.br.push(trap.index, broker.Kind.timer, trap_timer_id, "");
    _ = try waitFor(2_000, trap, isDown);

    // Down, and everything it drew went with it — the existing fault path, not
    // a second one.
    try std.testing.expect(!hasObject(rig.ov, trap_id ++ "/trap"));
    try std.testing.expect(rig.sink.has("lk_event trapped: "));
    try std.testing.expect(rig.sink.has("restarting in 1000 ms (attempt 1 of 3)"));
    try std.testing.expect(std.mem.indexOf(u8, trap.status(), "restarting (attempt 1 of 3)") != null);

    // The other plugin is untouched, and so is its settings schema: this is the
    // regression in the runtime path, where the entry is still in the registry.
    var reg: std.ArrayList(u8) = .empty;
    defer reg.deinit(alloc);
    try rig.registry(&reg);
    try std.testing.expect(std.mem.indexOf(u8, reg.items, "\"key\":\"draw\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, reg.items, "\"key\":\"scale\"") != null);
    try std.testing.expect(echo.enabled);

    // A plugin gets its whole backoff before anybody touches it.
    while (broker.monoMs() - pushed < 600) broker.sleepMs(5);
    try std.testing.expect(!trap.enabled);

    _ = try waitFor(4_000, trap, isUp);
    const back_after = broker.monoMs() - pushed;
    try std.testing.expect(back_after >= 1_000);
    try std.testing.expect(back_after < 3_000);

    // WHAT IT CAME BACK WITH. Its settings and its connection row, exactly as
    // the mariner left them — and no globals: the event counter the last
    // instance had is gone, because the instance is gone.
    try std.testing.expect(rig.sink.has("trap fixture start: mark 42, 1 connection(s), 0 event(s) remembered"));
    try std.testing.expect(rig.sink.has("restarted (attempt 1 of 3)"));
    // ...and a scene it drew again itself, rather than one that was left behind.
    try std.testing.expect(hasObject(rig.ov, trap_id ++ "/trap"));

    // It is a working plugin again: events reach it and it answers them.
    rig.br.push(trap.index, broker.Kind.timer, 1, "");
    _ = try waitFor(2_000, rig.sink, struct {
        fn f(s: *LogSink) bool {
            return s.count("\"detail\":\"1 events\"") >= 1;
        }
    }.f);
    rig.h.stop();
}

// THE END OF THE LINE. A plugin that cannot start is not restarted for ever:
// three attempts, then it stops and the status line says so.
//
// The schedule is compressed so the test is not thirty-six seconds long. The
// test above holds the shipped one to its first second.
test "three failed restarts stop the plugin, and the status line says so" {
    const alloc = std.testing.allocator;
    var rig = try Rig.init(alloc, .{ .restart_backoff_ms = &.{ 30, 60, 90 } });
    defer rig.deinit();
    try rig.stage(false);

    try rig.h.loadDir(rig.dir_path);
    const echo = rig.h.find(echo_id) orelse return error.EchoNotLoaded;
    const trap = rig.h.find(trap_id) orelse return error.TrapNotLoaded;
    try rig.h.start();

    // Switch on the setting that makes lk_start trap, so every restart fails
    // the way a plugin whose trouble is not one sentence fails.
    try rig.h.configSet(trap_id, "{\"trap_at_start\":true}");
    _ = try waitFor(2_000, rig.sink, struct {
        fn f(s: *LogSink) bool {
            return s.has("events, new settings");
        }
    }.f);

    rig.br.push(trap.index, broker.Kind.timer, trap_timer_id, "");
    _ = try waitFor(4_000, rig.sink, struct {
        fn f(s: *LogSink) bool {
            return s.has("stopped after 3 failed restarts");
        }
    }.f);

    // Three attempts, no more, and each one really did enter the module.
    try std.testing.expectEqual(@as(usize, 3), rig.sink.count("trapping on purpose inside lk_start"));
    try std.testing.expect(rig.sink.has("restarting in 30 ms (attempt 1 of 3)"));
    try std.testing.expect(rig.sink.has("restarting in 60 ms (attempt 2 of 3)"));
    try std.testing.expect(rig.sink.has("restarting in 90 ms (attempt 3 of 3)"));
    try std.testing.expect(!trap.enabled);
    try std.testing.expect(!hasObject(rig.ov, trap_id ++ "/trap"));

    // THE STATUS LINE SAYS IT STOPPED. A shell shows this text; "disabled" with
    // no more words would leave the mariner waiting for a fourth restart.
    try std.testing.expect(std.mem.indexOf(u8, trap.status(), "stopped after 3 failed restarts") != null);
    try std.testing.expect(std.mem.indexOf(u8, trap.status(), "unreachable") != null);

    // Nothing else happens after that: no fourth attempt, ever.
    broker.sleepMs(400);
    try std.testing.expectEqual(@as(usize, 3), rig.sink.count("trapping on purpose inside lk_start"));

    // And the plugin beside it never noticed. Its schema is whole and it is
    // still answering events.
    var reg: std.ArrayList(u8) = .empty;
    defer reg.deinit(alloc);
    try rig.registry(&reg);
    try std.testing.expect(std.mem.indexOf(u8, reg.items, "\"key\":\"draw\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, reg.items, "\"key\":\"scale\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, reg.items, "\"key\":\"mark\"") != null);
    try std.testing.expect(echo.enabled);
    rig.br.push(echo.index, broker.Kind.timer, 1, "");
    try std.testing.expect(echo.enabled);
    rig.h.stop();
}

// A plugin that traps on its way out is on its way out. Restarting one that
// trapped handling SHUTDOWN would bring a plugin back into an application that
// is closing, and `stop` would then have to shut it down twice.
test "a plugin that traps handling SHUTDOWN is not brought back" {
    const alloc = std.testing.allocator;
    var rig = try Rig.init(alloc, .{});
    defer rig.deinit();
    try rig.stage(false);

    try rig.h.loadDir(rig.dir_path);
    const trap = rig.h.find(trap_id) orelse return error.TrapNotLoaded;
    try rig.h.start();

    try rig.h.configSet(trap_id, "{\"trap_at_shutdown\":true}");
    _ = try waitFor(2_000, rig.sink, struct {
        fn f(log: *LogSink) bool {
            return log.has("events, new settings");
        }
    }.f);

    const stopping_at = broker.monoMs();
    rig.h.stop();
    try std.testing.expect(rig.sink.has("trapping on purpose inside SHUTDOWN"));
    try std.testing.expect(rig.sink.has("lk_event trapped: "));
    // No restart was promised, and none happened.
    try std.testing.expect(!rig.sink.has("restarting in"));
    try std.testing.expect(!rig.sink.has("restarted (attempt"));
    try std.testing.expect(!trap.enabled);
    // ...and the close was not held up waiting for one.
    try std.testing.expect(broker.monoMs() - stopping_at < 2_000);
}

// THE PRECEDENCE RULE, end to end. It used to be first-loaded-wins, which gave
// the same answer only because the shell happened to scan the directories in
// the order it does.
test "an id two directories offer goes to the higher origin, whatever the scan order" {
    const alloc = std.testing.allocator;

    // The installed layout: <root>/<id>/manifest.json beside its module.
    var inst_tmp = std.testing.tmpDir(.{ .iterate = true });
    defer inst_tmp.cleanup();
    try inst_tmp.dir.createDirPath(io, trap_id);
    var inst_sub = try inst_tmp.dir.openDir(io, trap_id, .{});
    defer inst_sub.close(io);
    try inst_sub.writeFile(io, .{ .sub_path = "manifest.json", .data = trap_manifest });
    try inst_sub.writeFile(io, .{ .sub_path = trap_id ++ ".wasm", .data = trap_wasm });
    const installed_dir = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{inst_tmp.sub_path});
    defer alloc.free(installed_dir);

    // INSTALLED FIRST, THEN BUNDLED. Under first-loaded-wins the stale
    // installed copy would keep the id; by rule the bundled one takes it.
    {
        var rig = try Rig.init(alloc, .{});
        defer rig.deinit();
        try rig.stage(false);

        try rig.h.loadDir(installed_dir);
        var reg: std.ArrayList(u8) = .empty;
        defer reg.deinit(alloc);
        try rig.registry(&reg);
        try std.testing.expect(std.mem.indexOf(u8, reg.items, "\"origin\":\"installed\"") != null);

        try rig.h.loadDir(rig.dir_path);
        try rig.registry(&reg);
        try std.testing.expect(std.mem.indexOf(u8, reg.items, "\"origin\":\"installed\"") == null);
        try std.testing.expect(std.mem.indexOf(u8, reg.items, "\"origin\":\"bundled\"") != null);
        try std.testing.expect(rig.sink.has("bundled copy takes the id from the installed copy"));
        // One live copy of the id, not two.
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, reg.items, "\"id\":\"" ++ trap_id ++ "\""));
    }

    // BUNDLED FIRST, THEN DEVELOPER: the override overrides.
    {
        var rig = try Rig.init(alloc, .{});
        defer rig.deinit();
        try rig.stage(false);

        var dev_tmp = std.testing.tmpDir(.{ .iterate = true });
        defer dev_tmp.cleanup();
        try dev_tmp.dir.writeFile(io, .{ .sub_path = trap_id ++ ".wasm", .data = trap_wasm });
        try dev_tmp.dir.writeFile(io, .{ .sub_path = trap_id ++ ".manifest.json", .data = trap_manifest });
        const dev_dir = try std.fmt.allocPrintSentinel(alloc, ".zig-cache/tmp/{s}", .{dev_tmp.sub_path}, 0);
        defer alloc.free(dev_dir);
        _ = setenv("LOOKOUT_PLUGINS", dev_dir.ptr, 1);
        defer _ = unsetenv("LOOKOUT_PLUGINS");

        try rig.h.loadDir(rig.dir_path);
        try rig.h.loadDir(dev_dir);
        var reg: std.ArrayList(u8) = .empty;
        defer reg.deinit(alloc);
        try rig.registry(&reg);
        try std.testing.expect(std.mem.indexOf(u8, reg.items, "\"origin\":\"developer\"") != null);
        try std.testing.expect(rig.sink.has("developer copy takes the id from the bundled copy"));

        // ...and the other way round the developer copy simply keeps it, with
        // no unload and no reload.
        try rig.h.loadDir(rig.dir_path);
        try rig.registry(&reg);
        try std.testing.expect(std.mem.indexOf(u8, reg.items, "\"origin\":\"developer\"") != null);
        try std.testing.expect(rig.sink.has("already loaded (developer copy wins); bundled copy skipped"));

        // Loading one directory twice is a no-op, which is what
        // lookout_plugins_load_installed leans on.
        const before = rig.h.count();
        try rig.h.loadDir(dev_dir);
        try std.testing.expectEqual(before, rig.h.count());
        try std.testing.expect(rig.sink.has("already loaded (developer copy wins); developer copy skipped"));
    }

    // A HIGHER ORIGIN THAT IS NOT A PLUGIN TAKES NOTHING. A developer directory
    // holding a manifest and no module beside it is a mistake anybody makes,
    // and it must not take the bundled plugin off the chart.
    {
        var rig = try Rig.init(alloc, .{});
        defer rig.deinit();
        try rig.stage(false);

        var dev_tmp = std.testing.tmpDir(.{ .iterate = true });
        defer dev_tmp.cleanup();
        try dev_tmp.dir.writeFile(io, .{ .sub_path = trap_id ++ ".manifest.json", .data = trap_manifest });
        const dev_dir = try std.fmt.allocPrintSentinel(alloc, ".zig-cache/tmp/{s}", .{dev_tmp.sub_path}, 0);
        defer alloc.free(dev_dir);
        _ = setenv("LOOKOUT_PLUGINS", dev_dir.ptr, 1);
        defer _ = unsetenv("LOOKOUT_PLUGINS");

        try rig.h.loadDir(rig.dir_path);
        const before = rig.h.count();
        try rig.h.loadDir(dev_dir);
        try std.testing.expectEqual(before, rig.h.count());
        try std.testing.expect(rig.sink.has("plugins: " ++ trap_id ++ " not loaded"));
        try std.testing.expect(!rig.sink.has("takes the id from"));

        var reg: std.ArrayList(u8) = .empty;
        defer reg.deinit(alloc);
        try rig.registry(&reg);
        try std.testing.expect(std.mem.indexOf(u8, reg.items, "\"origin\":\"bundled\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, reg.items, "\"key\":\"mark\"") != null);
    }
}
