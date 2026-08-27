//! The AIS plugin's collision alarm, driven by data rather than by drawing.
//!
//! The real ais .wasm, the real host, the real stores. The test writes own
//! ship's fix into the vessel store and one closing target into the AIS store,
//! and reads back the alert the plugin raised. What it proves, which nothing
//! else does:
//!
//!   - the alarm is decided when the values arrive, so it fires with the
//!     plugin's draw timer stood down and nothing on the chart;
//!   - the gate's edge holds one approach to one alarm, however many reports
//!     arrive between the crossing and the end of the run. Evaluating on the
//!     data path runs the gate an order of magnitude more often than the draw
//!     timer did, and only the latch keeps that from being an order of
//!     magnitude more alarms;
//!   - an acknowledgement is the mariner's and the plugin cannot take it back.
//!     The words move under a live alarm, because a target sends its name after
//!     its first position report, and the alert is keyed on the vessel so all
//!     of that stays one alert.
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

/// How long a wait-for gives up after. Generous: the values have to cross
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

/// The second vessel, on the same unallocated MID.
const other_mmsi: u32 = 899000102;

/// Far enough ahead that the approach is 4000 s away: outside the gate's time
/// limit, so the target is drawn and is not dangerous.
const opened_m: f64 = 40_000;

/// Own ship, `metres` north of where the encounter started.
fn publishOwnShip(vessels: *vstore.Store, metres: f64) !void {
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
}

/// One report from a target making south, `north_m` north of where the
/// encounter started. A null name is a target heard by position report alone,
/// which is how most of them are first heard: the static message carrying the
/// name arrives on its own schedule.
fn publishTarget(
    ais: *aisstore.AisStore,
    mmsi: u32,
    name: ?[]const u8,
    north_m: f64,
    east_m: f64,
) !void {
    _ = try ais.upsert(.{
        .mmsi = mmsi,
        .lat = latAt(north_m),
        .lon = lonAt(east_m),
        .sog = closing_mps,
        .cog = 180,
        .heading = 180,
        .name = name,
        .ts_ms = broker.wallMs(),
    }, test_source);
}

/// Own ship and the target, both `metres` along their courses from where the
/// encounter started. Publishing the pair again with a larger `metres` is one
/// more report of the same approach.
fn publishEncounter(vessels: *vstore.Store, ais: *aisstore.AisStore, metres: f64) !void {
    try publishOwnShip(vessels, metres);
    try publishTarget(ais, target_mmsi, "SPECKLED KETTLE", gap_m - metres, offset_m);
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

/// The alerts the host is holding, read back through the call the shell makes
/// and parsed. The strings point into `text`, so the two are freed together.
const Held = struct {
    alloc: std.mem.Allocator,
    text: std.ArrayList(u8),
    doc: std.json.Parsed(std.json.Value),

    fn read(alloc: std.mem.Allocator, br: *broker.Broker) !Held {
        var text: std.ArrayList(u8) = .empty;
        errdefer text.deinit(alloc);
        try br.alertsJson(&text);
        return .{
            .alloc = alloc,
            .text = text,
            .doc = try std.json.parseFromSlice(std.json.Value, alloc, text.items, .{}),
        };
    }

    fn deinit(self: *Held) void {
        self.doc.deinit();
        self.text.deinit(self.alloc);
    }

    fn list(self: *const Held) []std.json.Value {
        return self.doc.value.object.get("alerts").?.array.items;
    }

    /// One alert, in the order a shell reads them: unanswered first.
    fn at(self: *const Held, i: usize) std.json.ObjectMap {
        return self.list()[i].object;
    }
};

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

// ACKNOWLEDGEMENT IS THE MARINER'S DECISION, AND NOTHING THE PLUGIN SAYS NEXT
// TAKES IT BACK. The words move under a live alarm: a target is first heard by
// position report and sends its name later, and the closing figures move with
// every report. The key is the vessel, so all of that is one alert.
test "acknowledging the alarm holds while the words move, and the next vessel still alarms" {
    const alloc = std.testing.allocator;
    var rig = try Rig.init(alloc);
    defer rig.deinit();
    try rig.start();
    const p = rig.h.find(ais_id) orelse return error.PluginNotLoaded;

    // Heard by position report alone, so the alarm can only name the MMSI.
    try publishOwnShip(rig.vessels, 0);
    try publishTarget(rig.ais, target_mmsi, null, gap_m, offset_m);
    try waitFor(rig.log, alarmed);

    var silenced: u64 = 0;
    {
        var held = try Held.read(alloc, rig.br);
        defer held.deinit();
        try must(held.list().len == 1, "one alarm is up");
        silenced = @intCast(held.at(0).get("id").?.integer);
    }
    try must(rig.br.ackAlert(silenced), "the mariner silences it");

    // The vessel opens, which re-arms the gate. The plugin says so on the
    // status line, which is how the test knows the report was answered.
    try publishOwnShip(rig.vessels, 0);
    try publishTarget(rig.ais, target_mmsi, null, opened_m, offset_m);
    try waitFor(p, struct {
        fn ready(s: *broker.Plugin) bool {
            return std.mem.indexOf(u8, s.status(), "1 targets, 0 in CPA alarm") != null;
        }
    }.ready);

    // It closes again, nearer than before and carrying the name it has since
    // sent. New words, the same danger, and the same vessel.
    try publishOwnShip(rig.vessels, 0);
    try publishTarget(rig.ais, target_mmsi, "SPECKLED KETTLE", gap_m / 2, offset_m);
    try waitFor(rig.log, struct {
        fn ready(l: *LogSink) bool {
            return l.count("AIS CPA alarm") >= 2;
        }
    }.ready);
    {
        var held = try Held.read(alloc, rig.br);
        defer held.deinit();
        try must(held.list().len == 1, "the second raise did not stack a second alert");
        try must(held.at(0).get("acknowledged").?.bool, "the acknowledgement held");
        try must(
            std.mem.indexOf(u8, held.at(0).get("body").?.string, "SPECKLED KETTLE") != null,
            "the alert names the vessel now that the name has arrived",
        );
    }

    // A DIFFERENT VESSEL IS A DIFFERENT DANGER, and nobody has seen this one.
    try publishOwnShip(rig.vessels, 0);
    try publishTarget(rig.ais, other_mmsi, "GALLEON", gap_m / 2, -offset_m);
    try waitFor(rig.log, struct {
        fn ready(l: *LogSink) bool {
            return l.count("AIS CPA alarm") >= 3;
        }
    }.ready);
    {
        var held = try Held.read(alloc, rig.br);
        defer held.deinit();
        try must(held.list().len == 2, "the second vessel raised its own alarm");
        try must(!held.at(0).get("acknowledged").?.bool, "and nobody has answered it");
        try must(
            std.mem.indexOf(u8, held.at(0).get("body").?.string, "GALLEON") != null,
            "the unanswered alarm names the vessel nobody has seen",
        );
    }
    try must(!rig.log.has("trapped"), "nothing trapped");
}

test "the hover popup says everything the vessel reported" {
    const alloc = std.testing.allocator;
    var rig = try Rig.init(alloc);
    defer rig.deinit();
    try rig.start();

    // A vessel that has sent both halves of what AIS carries: where she is
    // and how she is moving, and then who she is and where she is bound.
    _ = try rig.ais.upsert(.{
        .mmsi = target_mmsi,
        .lat = latAt(gap_m),
        .lon = lonAt(offset_m),
        .sog = closing_mps,
        .cog = 180,
        .heading = 181,
        .name = "SPECKLED KETTLE",
        .nav_status = 1,
        .ship_type = 71,
        .class_b = false,
        .callsign = "EXAMP03",
        .destination = "ANNAPOLIS",
        .imo = 9134270,
        .draught_m = 12.5,
        .length_m = 294,
        .beam_m = 32,
        .ts_ms = broker.wallMs(),
    }, test_source);
    try publishOwnShip(rig.vessels, 0);

    // THIS IS WHAT THE MARINER READS. The rows are built in the plugin and
    // travel as the symbol's pick payload; every label below was decoded and
    // thrown away before it reached the chart, so a label that stops
    // appearing is a popup that quietly went back to saying almost nothing.
    try waitFor(rig.ov, struct {
        fn ready(ov: *overlay.Store) bool {
            const o = ov.objs.get(ais_id ++ "/t899000101") orelse return false;
            const p = o.pick;
            const wants = [_][]const u8{
                "\"SPECKLED KETTLE\"",
                "[\"MMSI\",\"899000101\"]",
                "[\"Call sign\",\"EXAMP03\"]",
                "[\"IMO\",\"9134270\"]",
                "[\"Type\",\"Cargo, hazardous A\"]",
                "[\"Status\",\"At anchor\"]",
                "[\"HDG\",\"181",
                "[\"Bound for\",\"ANNAPOLIS\"]",
                "[\"Draught\",\"12.5 m\"]",
                "[\"Class\",\"A\"]",
            };
            for (wants) |w| {
                if (std.mem.indexOf(u8, p, w) == null) return false;
            }
            // Length and beam read as one fact, not two rows.
            return std.mem.indexOf(u8, p, "294") != null and
                std.mem.indexOf(u8, p, "32 m") != null;
        }
    }.ready);
    try must(!rig.log.has("more than"), "no row was dropped for want of room");
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
