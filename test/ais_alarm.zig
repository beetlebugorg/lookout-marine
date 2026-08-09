//! The AIS plugin's collision alarm, driven by data rather than by drawing.
//!
//! The real ais .wasm, the real host, the real stores. The test writes own
//! ship's fix into the vessel store and one closing target into the AIS store,
//! and reads back the alert the plugin raised. What it proves, which nothing
//! else does:
//!
//!   - the alarm is decided when the readings arrive, so it fires with the
//!     plugin's draw timer stood down and nothing on the chart;
//!   - the gate's edge holds one approach to one alarm, however many reports
//!     arrive between the crossing and the end of the run. Evaluating on the
//!     data path runs the gate an order of magnitude more often than the draw
//!     timer did, and only the latch keeps that from being an order of
//!     magnitude more alarms.
//!
//! The plugin arrives as an anonymous import, like plugins/echo does for
//! host_smoke: importing host.zig must never drag a plugin binary into the
//! core.

const std = @import("std");
const host = @import("host");
const overlay = @import("overlay");

const broker = host.broker;
const vstore = host.store;
const aisstore = host.aisstore;

const ais_wasm = @embedFile("ais_plugin_wasm");
const ais_manifest = @embedFile("ais_manifest");
const ais_id = "org.beetlebug.ais";
const io = std.Io.Threaded.global_single_threaded.io();

/// How long a wait-for gives up after. Generous: the readings have to cross
/// the fanout tick and the interpreter on a loaded machine.
const deadline_ms: i64 = 8_000;

/// The source the test publishes as. The plugin holds source 1; this is
/// registered after it, so nothing about priority is in question.
const test_source: vstore.SourceId = 90;

/// The invented target, on MID 899, which is unallocated: no real vessel can
/// hold it.
const target_mmsi: u32 = 899000101;

// ---------------------------------------------------------------------------
// the encounter
// ---------------------------------------------------------------------------

/// Metres per degree of latitude, the constant cpa.zig lays its plane out
/// with. The two have to agree or the designed approach is not the one the
/// plugin solves.
const m_per_deg_lat: f64 = 111132.0;

const base_lat: f64 = 38.9763;
const base_lon: f64 = -76.4767;

/// Head-on, from the first case in cpa.zig's own tests: own ship makes north
/// at 5 m/s and the target is 2000 m ahead making south at 5 m/s, 50 m off to
/// starboard. They close at 10 m/s, so the approach is 200 s away and 50 m
/// wide: well inside the shipped gate of 926 m and 600 s.
const closing_mps: f64 = 5.0;
const offset_m: f64 = 50.0;
const gap_m: f64 = 2000.0;

fn latAt(north_m: f64) f64 {
    return base_lat + north_m / m_per_deg_lat;
}

fn lonAt(east_m: f64) f64 {
    const cos_lat = @cos(base_lat * std.math.pi / 180.0);
    return base_lon + east_m / (m_per_deg_lat * cos_lat);
}

/// Own ship and the target, both `metres` along their courses from where the
/// encounter started. Publishing the pair again with a larger `metres` is one
/// more report of the same approach.
fn publishEncounter(vessels: *vstore.Store, ais: *aisstore.AisStore, metres: f64) !void {
    const now = broker.wallMs();
    var buf: [96]u8 = undefined;
    try vessels.set(
        "navigation.position",
        try std.fmt.bufPrint(&buf, "{{\"lat\":{d:.7},\"lon\":{d:.7}}}", .{ latAt(metres), base_lon }),
        now,
        test_source,
    );
    var speed: [32]u8 = undefined;
    try vessels.set(
        "navigation.speedOverGround",
        try std.fmt.bufPrint(&speed, "{d}", .{closing_mps}),
        now,
        test_source,
    );
    try vessels.set("navigation.courseOverGroundTrue", "0", now, test_source);
    try ais.upsert(.{
        .mmsi = target_mmsi,
        .lat = latAt(gap_m - metres),
        .lon = lonAt(offset_m),
        .sog = closing_mps,
        .cog = 180,
        .heading = 180,
        .name = "SPECKLED KETTLE",
        .ts_ms = now,
    }, test_source);
}

// ---------------------------------------------------------------------------
// the rig
// ---------------------------------------------------------------------------

/// Keeps every broker log line. The alarm is counted here rather than in the
/// held-alert list because the host deduplicates a repeated alert: the list
/// would read 1 even if the plugin raised twenty, and the number of times the
/// plugin decided to raise is exactly what the latch is about.
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
        return self.count(needle) > 0;
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

const Rig = struct {
    alloc: std.mem.Allocator,
    tmp: std.testing.TmpDir,
    dir_path: []u8,
    vessels: *vstore.Store,
    ais: *aisstore.AisStore,
    ov: *overlay.Store,
    log: *LogSink,
    br: *broker.Broker,
    h: *host.Host,

    fn init(alloc: std.mem.Allocator) !Rig {
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();
        try tmp.dir.writeFile(io, .{ .sub_path = ais_id ++ ".wasm", .data = ais_wasm });
        try tmp.dir.writeFile(io, .{ .sub_path = ais_id ++ ".manifest.json", .data = ais_manifest });
        const dir_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{tmp.sub_path});
        errdefer alloc.free(dir_path);

        const vessels = try alloc.create(vstore.Store);
        vessels.* = try vstore.Store.init(alloc);
        const ais = try alloc.create(aisstore.AisStore);
        ais.* = aisstore.AisStore.init(alloc);
        const ov = try alloc.create(overlay.Store);
        ov.* = overlay.Store.init(alloc);
        const log = try alloc.create(LogSink);
        log.* = .{ .alloc = alloc };
        const br = try alloc.create(broker.Broker);
        br.* = broker.Broker.init(alloc, vessels, ais, .{
            .ctx = ov,
            .applyFn = OvSink.apply,
            .removeFn = OvSink.remove,
        });
        br.setLog(log, LogSink.write);
        const h = try alloc.create(host.Host);
        h.* = host.Host.init(alloc, br, .{});
        return .{
            .alloc = alloc,
            .tmp = tmp,
            .dir_path = dir_path,
            .vessels = vessels,
            .ais = ais,
            .ov = ov,
            .log = log,
            .br = br,
            .h = h,
        };
    }

    /// Load the plugin and give it its own dispatch thread, then register the
    /// source this test publishes as.
    fn start(self: *Rig) !void {
        try self.h.loadDir(self.dir_path);
        try std.testing.expectEqual(@as(usize, 1), self.h.count());
        try self.h.start();
        try self.vessels.registerSource(test_source);
    }

    fn deinit(self: *Rig) void {
        self.h.stop();
        self.h.deinit();
        self.br.deinit();
        self.ov.deinit();
        self.ais.deinit();
        self.vessels.deinit();
        self.log.text.deinit(self.alloc);
        self.alloc.destroy(self.h);
        self.alloc.destroy(self.br);
        self.alloc.destroy(self.ov);
        self.alloc.destroy(self.ais);
        self.alloc.destroy(self.vessels);
        self.alloc.destroy(self.log);
        self.alloc.free(self.dir_path);
        self.tmp.cleanup();
    }
};

fn must(cond: bool, comptime what: []const u8) !void {
    if (cond) return;
    std.debug.print("\nFAILED: {s}\n", .{what});
    return error.TestUnexpectedResult;
}

fn waitFor(ctx: anytype, ready: fn (@TypeOf(ctx)) bool) !void {
    const until = broker.monoMs() + deadline_ms;
    while (broker.monoMs() < until) {
        if (ready(ctx)) return;
        broker.sleepMs(20);
    }
    return error.TimedOut;
}

fn alarmed(log: *LogSink) bool {
    return log.has("AIS CPA alarm");
}

/// Every overlay object this plugin owns. The host namespaces an id by the
/// plugin that drew it, so the prefix is the ownership test.
fn drawnObjects(ov: *overlay.Store) usize {
    ov.mu.lock();
    defer ov.mu.unlock();
    var n: usize = 0;
    for (ov.objs.keys()) |k| {
        if (std.mem.startsWith(u8, k, ais_id ++ "/")) n += 1;
    }
    return n;
}

// ---------------------------------------------------------------------------
// the tests
// ---------------------------------------------------------------------------

test "the collision alarm fires with the draw timer stood down" {
    const alloc = std.testing.allocator;
    var rig = try Rig.init(alloc);
    defer rig.deinit();
    try rig.start();

    // Take the chart away first. The library stands the draw timer down, so
    // nothing this plugin decides from here on can have been decided inside a
    // draw call.
    try rig.h.grantSet(ais_id, "overlay.draw", false);
    const p = rig.h.find(ais_id) orelse return error.PluginNotLoaded;
    try waitFor(p, struct {
        fn ready(s: *broker.Plugin) bool {
            return std.mem.indexOf(u8, s.status(), "not drawing") != null;
        }
    }.ready);

    // One vessel, closing.
    try publishEncounter(rig.vessels, rig.ais, 0);
    try waitFor(rig.log, alarmed);

    // The alert is the one the mariner would hear, named by the vessel.
    var alerts: std.ArrayList(u8) = .empty;
    defer alerts.deinit(alloc);
    try rig.br.alertsJson(&alerts);
    try must(std.mem.indexOf(u8, alerts.items, "\"AIS CPA alarm\"") != null, "the host holds the alarm");
    try must(std.mem.indexOf(u8, alerts.items, "SPECKLED KETTLE") != null, "the alarm names the vessel");

    // And nothing was drawn to decide it with. The chart is empty because the
    // mariner emptied it, and the plugin says so rather than looking broken.
    try must(drawnObjects(rig.ov) == 0, "nothing reached the chart");
    try must(p.denied == 0, "no overlay call was made, so none was refused");
    try must(!rig.log.has("trapped"), "nothing trapped");
}

test "one approach is one alarm, however many reports arrive" {
    const alloc = std.testing.allocator;
    var rig = try Rig.init(alloc);
    defer rig.deinit();
    try rig.start();

    // Sixty reports of the same approach, a metre and a half apart, faster
    // than the fanout will coalesce them. The gate is crossed on the first and
    // is still crossed on the last.
    try publishEncounter(rig.vessels, rig.ais, 0);
    try waitFor(rig.log, alarmed);
    for (1..60) |i| {
        try publishEncounter(rig.vessels, rig.ais, @as(f64, @floatFromInt(i)) * 1.5);
        broker.sleepMs(20);
    }
    // Long enough for every batch to have been fanned out and answered.
    broker.sleepMs(500);

    // ONE raise, not one per report. The alarm re-arms only when the target
    // leaves the gate, and it never left.
    try std.testing.expectEqual(@as(usize, 1), rig.log.count("AIS CPA alarm"));

    // The chart agrees with the alarm: the target is drawn in the danger
    // colour, from the same ruling the alarm was raised on.
    try waitFor(rig.ov, struct {
        fn ready(ov: *overlay.Store) bool {
            const o = ov.objs.get(ais_id ++ "/t899000101") orelse return false;
            return o.token == .target_danger;
        }
    }.ready);
    try must(!rig.log.has("trapped"), "nothing trapped");
    try must(!rig.log.has("denied"), "no grant was refused");
}
