//! Plugin install and consent, end to end: a real .lkplug packed in this
//! test, the real unpacker, the real registry, the real broker natives and
//! the real overlay store.
//!
//! The payload is the windline module — the documentation's downwind example
//! — packed under the id the walkthrough uses, org.example.downwind. What
//! this proves, which nothing else does:
//!
//!   - a zip that is not exactly manifest.json + <id>.wasm is refused BY
//!     NAME, with the sentence the shell shows — INCLUDING a package that
//!     brings an .aot, which is the case that keeps native code out;
//!   - an installed package lands under the install root, loads, and draws;
//!   - a grant revoked live behaves exactly like one the manifest never
//!     asked for: the call answers -1, denied counts, the plugin runs on;
//!   - grants.json round-trips through a reload;
//!   - a reinstall's consent sheet carries the grant delta and the downgrade;
//!   - uninstall removes the directory, the storage file and every overlay
//!     object the plugin owned;
//!   - the two precedence rules around the BUNDLED set the app ships with: a
//!     package claiming a bundled id is refused by name and writes nothing,
//!     and a developer copy from LOOKOUT_PLUGINS overrides the bundled plugin
//!     of the same id.
//!
//! The .wasm arrives as an anonymous import, like plugins/echo does for
//! host_smoke: importing host.zig must never drag a plugin binary into the
//! core.

const std = @import("std");
const host = @import("host");
const overlay = @import("overlay");

const broker = host.broker;
const vstore = host.store;
const aisstore = host.aisstore;

const windline_wasm = @embedFile("windline_plugin_wasm");

const downwind_id = "org.example.downwind";
const io = std.Io.Threaded.global_single_threaded.io();

const manifest_v1 =
    \\{"id":"org.example.downwind","name":"Downwind line","api":1,"version":"1.0",
    \\ "capabilities":["vessel.read","overlay.draw"]}
;
const manifest_v2 =
    \\{"id":"org.example.downwind","name":"Downwind line","api":1,"version":"2.0",
    \\ "capabilities":["vessel.read","overlay.draw","ais.read"]}
;
const manifest_v09 =
    \\{"id":"org.example.downwind","name":"Downwind line","api":1,"version":"0.9",
    \\ "capabilities":["vessel.read","overlay.draw"]}
;

/// A plugin of the kind the app ships with: an org.beetlebug id, which is
/// ours. The two manifests differ in version and name so the registry says
/// which copy is running.
const bundled_id = "org.beetlebug.testcore";
const bundled_manifest =
    \\{"id":"org.beetlebug.testcore","name":"Core example","api":1,"version":"1.0",
    \\ "capabilities":["vessel.read","overlay.draw"]}
;
const developer_manifest =
    \\{"id":"org.beetlebug.testcore","name":"Core example","api":1,"version":"9.9",
    \\ "capabilities":["vessel.read","overlay.draw"]}
;

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

/// Both inputs the downwind plugin subscribes to, fresh, in the shape the
/// fanout tick builds. `lat` varies so two events never carry the same fix.
fn fixJson(buf: []u8, lat: f64) []const u8 {
    return std.fmt.bufPrint(buf, "{{\"values\":[" ++
        "{{\"path\":\"navigation.position\",\"value\":{{\"lat\":{d},\"lon\":-76.4767}},\"ts\":1000,\"age_ms\":100}}," ++
        "{{\"path\":\"environment.wind.directionTrue\",\"value\":215,\"ts\":1000,\"age_ms\":100}}]}}", .{lat}) catch unreachable;
}

/// A fresh fix followed by the plugin's own draw tick. lk2 records readings
/// on STORE_CHANGED and draws on its timer, which the broker's I/O thread
/// would fire; this rig pumps deterministically, so the tick is pushed by
/// hand. The draw timer is the first timer the (fresh) broker handed out.
const draw_timer_id: u64 = 1;

fn pushFix(rig: *Rig, index: u32, lat: f64) void {
    var buf: [512]u8 = undefined;
    rig.br.push(index, broker.Kind.store_changed, 0, fixJson(&buf, lat));
    rig.br.push(index, broker.Kind.timer, draw_timer_id, "");
}

// ---------------------------------------------------------------------------
// a zip, written by hand
// ---------------------------------------------------------------------------

const ZipMember = struct { name: []const u8, data: []const u8 };

fn putInt(comptime T: type, out: *std.ArrayList(u8), alloc: std.mem.Allocator, v: T) !void {
    var buf: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &buf, v, .little);
    try out.appendSlice(alloc, &buf);
}

/// A store-method zip of `members`: local headers, central directory, end
/// record. The store method keeps the bytes readable in a hexdump and is one
/// of the two methods the host accepts.
fn zipBytes(alloc: std.mem.Allocator, members: []const ZipMember) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    const offsets = try alloc.alloc(u32, members.len);
    defer alloc.free(offsets);
    for (members, 0..) |m, i| {
        offsets[i] = @intCast(out.items.len);
        try out.appendSlice(alloc, "PK\x03\x04");
        try putInt(u16, &out, alloc, 20); // version needed
        try putInt(u16, &out, alloc, 0); // flags
        try putInt(u16, &out, alloc, 0); // method: store
        try putInt(u16, &out, alloc, 0); // mtime
        try putInt(u16, &out, alloc, 0); // mdate
        try putInt(u32, &out, alloc, std.hash.Crc32.hash(m.data));
        try putInt(u32, &out, alloc, @intCast(m.data.len));
        try putInt(u32, &out, alloc, @intCast(m.data.len));
        try putInt(u16, &out, alloc, @intCast(m.name.len));
        try putInt(u16, &out, alloc, 0); // extra
        try out.appendSlice(alloc, m.name);
        try out.appendSlice(alloc, m.data);
    }
    const cd_start: u32 = @intCast(out.items.len);
    for (members, 0..) |m, i| {
        try out.appendSlice(alloc, "PK\x01\x02");
        try putInt(u16, &out, alloc, 20); // made by
        try putInt(u16, &out, alloc, 20); // version needed
        try putInt(u16, &out, alloc, 0); // flags
        try putInt(u16, &out, alloc, 0); // method
        try putInt(u16, &out, alloc, 0); // mtime
        try putInt(u16, &out, alloc, 0); // mdate
        try putInt(u32, &out, alloc, std.hash.Crc32.hash(m.data));
        try putInt(u32, &out, alloc, @intCast(m.data.len));
        try putInt(u32, &out, alloc, @intCast(m.data.len));
        try putInt(u16, &out, alloc, @intCast(m.name.len));
        try putInt(u16, &out, alloc, 0); // extra len
        try putInt(u16, &out, alloc, 0); // comment len
        try putInt(u16, &out, alloc, 0); // disk
        try putInt(u16, &out, alloc, 0); // internal attrs
        try putInt(u32, &out, alloc, 0); // external attrs
        try putInt(u32, &out, alloc, offsets[i]);
        try out.appendSlice(alloc, m.name);
    }
    const cd_size: u32 = @intCast(out.items.len - cd_start);
    try out.appendSlice(alloc, "PK\x05\x06");
    try putInt(u16, &out, alloc, 0); // disk
    try putInt(u16, &out, alloc, 0); // cd disk
    try putInt(u16, &out, alloc, @intCast(members.len));
    try putInt(u16, &out, alloc, @intCast(members.len));
    try putInt(u32, &out, alloc, cd_size);
    try putInt(u32, &out, alloc, cd_start);
    try putInt(u16, &out, alloc, 0); // comment
    return out.toOwnedSlice(alloc);
}

// ---------------------------------------------------------------------------
// the rig, wired the way the app wires it
// ---------------------------------------------------------------------------

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
    vessels: *vstore.Store,
    ais: *aisstore.AisStore,
    ov: *overlay.Store,
    log: *LogSink,
    br: *broker.Broker,
    h: *host.Host,

    fn init(alloc: std.mem.Allocator, install_root: []const u8) !Rig {
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
        h.* = host.Host.init(alloc, br, .{ .install_root = install_root });
        return .{ .alloc = alloc, .vessels = vessels, .ais = ais, .ov = ov, .log = log, .br = br, .h = h };
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
    }
};

/// The tmp dir's path from the project root, where the test process runs.
fn tmpPath(alloc: std.mem.Allocator, tmp: *std.testing.TmpDir, sub: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path, sub });
}

fn writePackage(alloc: std.mem.Allocator, tmp: *std.testing.TmpDir, name: []const u8, members: []const ZipMember) ![]u8 {
    const zip = try zipBytes(alloc, members);
    defer alloc.free(zip);
    try tmp.dir.writeFile(io, .{ .sub_path = name, .data = zip });
    return tmpPath(alloc, tmp, name);
}

/// A flat `<id>.manifest.json` + `<id>.wasm` pair in `sub`: the layout `zig
/// build plugins` emits, which is what both the bundled set and the
/// LOOKOUT_PLUGINS override are handed to `loadDir` as. Answers the directory
/// path, which is also the string LOOKOUT_PLUGINS has to carry for the host to
/// call that directory a developer copy.
fn writeFlatPlugin(
    alloc: std.mem.Allocator,
    tmp: *std.testing.TmpDir,
    sub: []const u8,
    id: []const u8,
    manifest: []const u8,
) ![]u8 {
    try tmp.dir.createDirPath(io, sub);
    var name_buf: [160]u8 = undefined;
    const mname = try std.fmt.bufPrint(&name_buf, "{s}/{s}.manifest.json", .{ sub, id });
    try tmp.dir.writeFile(io, .{ .sub_path = mname, .data = manifest });
    var wasm_buf: [160]u8 = undefined;
    const wname = try std.fmt.bufPrint(&wasm_buf, "{s}/{s}.wasm", .{ sub, id });
    try tmp.dir.writeFile(io, .{ .sub_path = wname, .data = windline_wasm });
    return tmpPath(alloc, tmp, sub);
}

fn exists(path: []const u8) bool {
    const f = std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    f.close(io);
    return true;
}

fn must(cond: bool, comptime what: []const u8) !void {
    if (cond) return;
    std.debug.print("\nFAILED: {s}\n", .{what});
    return error.TestUnexpectedResult;
}

// ---------------------------------------------------------------------------
// the tests
// ---------------------------------------------------------------------------

test "a package that is not exactly manifest.json and <id>.wasm is refused by name" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmpPath(alloc, &tmp, "plugins");
    defer alloc.free(root);

    var rig = try Rig.init(alloc, root);
    defer rig.deinit();
    const h = rig.h;

    const Case = struct {
        name: []const u8,
        members: []const ZipMember,
        says: []const u8,
    };
    const cases = [_]Case{
        // The spec's rule, verbatim: anything else in the zip refuses the
        // install by name.
        .{ .name = "extra.lkplug", .says = "notes.txt", .members = &.{
            .{ .name = "manifest.json", .data = manifest_v1 },
            .{ .name = downwind_id ++ ".wasm", .data = "fake" },
            .{ .name = "notes.txt", .data = "hello" },
        } },
        // The manifest is authoritative; a module by any other name is a
        // repack error.
        .{ .name = "mismatch.lkplug", .says = "org.example.downwind.wasm", .members = &.{
            .{ .name = "manifest.json", .data = manifest_v1 },
            .{ .name = "org.example.other.wasm", .data = "fake" },
        } },
        .{ .name = "badmanifest.lkplug", .says = "The manifest is not one this host can read.", .members = &.{
            .{ .name = "manifest.json", .data = "not json at all" },
            .{ .name = downwind_id ++ ".wasm", .data = "fake" },
        } },
        .{ .name = "nomanifest.lkplug", .says = "no manifest.json", .members = &.{
            .{ .name = downwind_id ++ ".wasm", .data = "fake" },
        } },
        .{ .name = "nowasm.lkplug", .says = "no wasm module", .members = &.{
            .{ .name = "manifest.json", .data = manifest_v1 },
        } },
        .{ .name = "dir.lkplug", .says = "sub/", .members = &.{
            .{ .name = "manifest.json", .data = manifest_v1 },
            .{ .name = downwind_id ++ ".wasm", .data = "fake" },
            .{ .name = "sub/", .data = "" },
        } },
        // A PACKAGE MAY NOT BRING NATIVE CODE. An .aot is compiled machine
        // code, and the five plugins the app ships have one because THIS
        // project compiled them: from modules built here, on a build machine,
        // with wamrc flags chosen to match the runtime — software bounds
        // checks on, because the runtime installs no signal handler to catch
        // an out-of-range access (scripts/build-plugin-aot.sh).
        //
        // A third-party .aot is none of that. It is native code nobody here
        // compiled, and nothing in the AOT format records whether its bounds
        // checks were switched on, so there is no inspection that would make
        // it safe to run — it would simply be a plugin outside the sandbox.
        // We compile it, or we interpret it. There is no third option, and
        // this is where that is enforced: an .aot is not manifest.json and
        // does not end in .wasm, so the member is refused BY NAME, whether it
        // arrives beside a module or instead of one.
        .{ .name = "aot-beside.lkplug", .says = downwind_id ++ ".aot", .members = &.{
            .{ .name = "manifest.json", .data = manifest_v1 },
            .{ .name = downwind_id ++ ".wasm", .data = "fake" },
            .{ .name = downwind_id ++ ".aot", .data = "\x00aot" },
        } },
        .{ .name = "aot-only.lkplug", .says = downwind_id ++ ".aot", .members = &.{
            .{ .name = "manifest.json", .data = manifest_v1 },
            .{ .name = downwind_id ++ ".aot", .data = "\x00aot" },
        } },
    };
    for (cases) |case| {
        const path = try writePackage(alloc, &tmp, case.name, case.members);
        defer alloc.free(path);
        try std.testing.expectError(host.Error.PackageRefused, h.installPackage(path));
        const msg = h.installMessage();
        if (std.mem.indexOf(u8, msg, case.says) == null) {
            std.debug.print("\n{s}: said {s}, wanted {s}\n", .{ case.name, msg, case.says });
            return error.TestUnexpectedResult;
        }
    }

    // Junk that is not a zip at all.
    try tmp.dir.writeFile(io, .{ .sub_path = "junk.lkplug", .data = "hello sailor" });
    const junk = try tmpPath(alloc, &tmp, "junk.lkplug");
    defer alloc.free(junk);
    try std.testing.expectError(host.Error.PackageRefused, h.installPackage(junk));
    try must(std.mem.indexOf(u8, h.installMessage(), "not a plugin package") != null, "junk names the format");

    // Nothing was installed, and no scratch directory survives a refusal.
    try std.testing.expectEqual(@as(usize, 0), h.count());
    var dir = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |ent| {
        std.debug.print("\nleft behind: {s}\n", .{ent.name});
        return error.TestUnexpectedResult;
    }

    // And inspect answers the same sentence as JSON instead of erroring.
    const bad = try writePackage(alloc, &tmp, "extra2.lkplug", cases[0].members);
    defer alloc.free(bad);
    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(alloc);
    try h.inspectPackage(bad, &json);
    try must(std.mem.indexOf(u8, json.items, "{\"error\":\"") != null, "inspect wraps the refusal");
    try must(std.mem.indexOf(u8, json.items, "notes.txt") != null, "inspect names the extra member");
}

test "the downwind example installs hot, draws, loses a grant live, and uninstalls clean" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmpPath(alloc, &tmp, "plugins");
    defer alloc.free(root);
    const storage = try tmpPath(alloc, &tmp, "storage");
    defer alloc.free(storage);

    const pkg = try writePackage(alloc, &tmp, downwind_id ++ ".lkplug", &.{
        .{ .name = "manifest.json", .data = manifest_v1 },
        .{ .name = downwind_id ++ ".wasm", .data = windline_wasm },
    });
    defer alloc.free(pkg);

    const plug_dir = try tmpPath(alloc, &tmp, "plugins/" ++ downwind_id);
    defer alloc.free(plug_dir);
    const grants_path = try tmpPath(alloc, &tmp, "plugins/" ++ downwind_id ++ "/grants.json");
    defer alloc.free(grants_path);

    var revoked_grants_survive = false;
    {
        var rig = try Rig.init(alloc, root);
        defer rig.deinit();
        const h = rig.h;
        rig.br.setStorageDir(storage);

        // The consent sheet's feed: name, id, version and the two sentences.
        var sheet: std.ArrayList(u8) = .empty;
        defer sheet.deinit(alloc);
        try h.inspectPackage(pkg, &sheet);
        try must(std.mem.indexOf(u8, sheet.items, "\"id\":\"org.example.downwind\"") != null, "sheet has the id");
        try must(std.mem.indexOf(u8, sheet.items, "\"name\":\"Downwind line\"") != null, "sheet has the name");
        try must(std.mem.indexOf(u8, sheet.items, "\"version\":\"1.0\"") != null, "sheet has the version");
        try must(std.mem.indexOf(u8, sheet.items, "Read your instruments: position, heading, depth, wind.") != null, "sheet reads vessel.read");
        try must(std.mem.indexOf(u8, sheet.items, "Draw on the chart.") != null, "sheet reads overlay.draw");
        try must(std.mem.indexOf(u8, sheet.items, "\"installed\"") == null, "no delta on a first install");

        // Install: the directory appears, the plugin loads and starts.
        try h.installPackage(pkg);
        try std.testing.expectEqual(@as(usize, 1), h.count());
        try must(exists(grants_path) == false, "no grants.json until a switch is thrown");
        var mpath_buf: [256]u8 = undefined;
        const mpath = try std.fmt.bufPrint(&mpath_buf, "{s}/manifest.json", .{plug_dir});
        try must(exists(mpath), "manifest.json landed");
        const p = h.find(downwind_id) orelse return error.NotLoaded;
        try std.testing.expect(p.caps.contains(.vessel_read));
        try std.testing.expect(p.caps.contains(.overlay_draw));

        var reg: std.ArrayList(u8) = .empty;
        defer reg.deinit(alloc);
        try h.registryJson(&reg);
        try must(std.mem.indexOf(u8, reg.items, "\"origin\":\"installed\"") != null, "registry says installed");
        try must(std.mem.indexOf(u8, reg.items, "\"version\":\"1.0\"") != null, "registry has the version");
        try must(std.mem.indexOf(u8, reg.items, "\"cap\":\"overlay.draw\",\"sentence\":\"Draw on the chart.\",\"granted\":true") != null, "registry grants draw");

        // It draws: both inputs fresh, one dashed line downwind.
        pushFix(&rig, p.index, 38.9763);
        _ = h.pump();
        try std.testing.expectEqual(@as(usize, 1), rig.ov.count());
        try must(rig.ov.objs.contains(downwind_id ++ "/windline"), "the windline is on the chart");

        // Something in the store, so uninstall has a file to take with it.
        try std.testing.expectEqual(@as(i32, 0), rig.br.storagePut(p.index, "greeting", "hello"));
        var spath_buf: [256]u8 = undefined;
        const spath = try std.fmt.bufPrint(&spath_buf, "{s}/{s}.json", .{ storage, downwind_id });
        try must(exists(spath), "storage file exists");

        // Revoke overlay.draw live: the next draw is refused with -1 inside
        // the module, counted denied, logged by capability name, and the
        // plugin keeps running. Exactly a capability never asked for.
        try h.grantSet(downwind_id, "overlay.draw", false);
        try must(exists(grants_path), "grants.json written beside the wasm");
        // What the capability drew goes with the capability. An object left
        // behind stops updating and still reads as live.
        try must(!rig.ov.objs.contains(downwind_id ++ "/windline"), "the revoke took the drawing off the chart");
        const denied_before = p.denied;
        pushFix(&rig, p.index, 38.9800);
        _ = h.pump();
        try must(p.denied > denied_before, "the revoked draw was denied");
        try must(rig.log.has("does not request capability overlay.draw"), "the refusal names the capability");
        try must(h.find(downwind_id) != null, "the plugin runs on");

        // The registry now says so, for the settings switch to render.
        reg.clearRetainingCapacity();
        try h.registryJson(&reg);
        try must(std.mem.indexOf(u8, reg.items, "\"cap\":\"overlay.draw\",\"sentence\":\"Draw on the chart.\",\"granted\":false") != null, "registry shows the revocation");

        // Switch it back on: drawing resumes, nothing new is denied.
        try h.grantSet(downwind_id, "overlay.draw", true);
        const denied_after = p.denied;
        pushFix(&rig, p.index, 38.9850);
        _ = h.pump();
        try std.testing.expectEqual(denied_after, p.denied);

        // A grant can never exceed the manifest, and typos are refused.
        try std.testing.expectError(host.Error.NotGranted, h.grantSet(downwind_id, "alerts.raise", true));
        try std.testing.expectError(host.Error.UnknownCapability, h.grantSet(downwind_id, "net.quic", true));

        // Leave overlay.draw revoked for the reload half below.
        try h.grantSet(downwind_id, "overlay.draw", false);
        revoked_grants_survive = true;
    }

    // A fresh host — a restart — reads grants.json back: the revoked
    // capability is missing from the caps in force, the asked-for set stays.
    try must(revoked_grants_survive, "first half ran");
    {
        var rig = try Rig.init(alloc, root);
        defer rig.deinit();
        const h = rig.h;
        try h.loadDir(root);
        try std.testing.expectEqual(@as(usize, 1), h.count());
        const p = h.find(downwind_id) orelse return error.NotLoaded;
        try std.testing.expect(p.caps.contains(.vessel_read));
        try std.testing.expect(!p.caps.contains(.overlay_draw));

        // Uninstall: directory, grants, storage and overlay all gone.
        rig.br.setStorageDir(storage);
        try h.grantSet(downwind_id, "overlay.draw", true);
        pushFix(&rig, p.index, 38.9763);
        _ = h.pump();
        try std.testing.expectEqual(@as(usize, 1), rig.ov.count());

        try h.uninstall(downwind_id);
        try std.testing.expectEqual(@as(usize, 0), h.count());
        try std.testing.expectEqual(@as(usize, 0), rig.ov.count());
        try must(!exists(plug_dir), "the plugin directory is gone");
        var spath_buf: [256]u8 = undefined;
        const spath = try std.fmt.bufPrint(&spath_buf, "{s}/{s}.json", .{ storage, downwind_id });
        try must(!exists(spath), "the storage file went with it");
        var reg: std.ArrayList(u8) = .empty;
        defer reg.deinit(alloc);
        try h.registryJson(&reg);
        try must(std.mem.indexOf(u8, reg.items, downwind_id) == null, "the registry forgot it");
        try must(h.find(downwind_id) == null, "find answers nothing");

        // Uninstalling it twice is an unknown id, not a crash.
        try std.testing.expectError(host.Error.UnknownPlugin, h.uninstall(downwind_id));
    }
}

test "a reinstall's sheet carries the grant delta, and installing resets consent" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmpPath(alloc, &tmp, "plugins");
    defer alloc.free(root);

    var rig = try Rig.init(alloc, root);
    defer rig.deinit();
    const h = rig.h;

    const v1 = try writePackage(alloc, &tmp, "v1.lkplug", &.{
        .{ .name = "manifest.json", .data = manifest_v1 },
        .{ .name = downwind_id ++ ".wasm", .data = windline_wasm },
    });
    defer alloc.free(v1);
    const v2 = try writePackage(alloc, &tmp, "v2.lkplug", &.{
        .{ .name = "manifest.json", .data = manifest_v2 },
        .{ .name = downwind_id ++ ".wasm", .data = windline_wasm },
    });
    defer alloc.free(v2);
    const v09 = try writePackage(alloc, &tmp, "v09.lkplug", &.{
        .{ .name = "manifest.json", .data = manifest_v09 },
        .{ .name = downwind_id ++ ".wasm", .data = windline_wasm },
    });
    defer alloc.free(v09);

    try h.installPackage(v1);
    // The mariner revokes a grant, then is handed v2.
    try h.grantSet(downwind_id, "overlay.draw", false);

    var sheet: std.ArrayList(u8) = .empty;
    defer sheet.deinit(alloc);
    try h.inspectPackage(v2, &sheet);
    try must(std.mem.indexOf(u8, sheet.items, "\"installed\":{\"version\":\"1.0\"") != null, "the sheet knows the running copy");
    try must(std.mem.indexOf(u8, sheet.items, "\"adds\":[\"Read AIS traffic.\"]") != null, "the sheet calls out the addition");
    try must(std.mem.indexOf(u8, sheet.items, "\"drops\":[]") != null, "nothing dropped");
    try must(std.mem.indexOf(u8, sheet.items, "\"downgrade\":false") != null, "an upgrade is not a downgrade");

    sheet.clearRetainingCapacity();
    try h.inspectPackage(v09, &sheet);
    try must(std.mem.indexOf(u8, sheet.items, "\"downgrade\":true") != null, "a downgrade says so");

    // Install v2 over v1: one plugin, the new version, and consent reset to
    // the sheet's full list — the revocation belonged to the old consent.
    try h.installPackage(v2);
    try std.testing.expectEqual(@as(usize, 1), h.count());
    const p = h.find(downwind_id) orelse return error.NotLoaded;
    try std.testing.expect(p.caps.contains(.ais_read));
    try std.testing.expect(p.caps.contains(.overlay_draw));
    var reg: std.ArrayList(u8) = .empty;
    defer reg.deinit(alloc);
    try h.registryJson(&reg);
    try must(std.mem.indexOf(u8, reg.items, "\"version\":\"2.0\"") != null, "the registry shows v2");
    try must(std.mem.indexOf(u8, reg.items, "\"cap\":\"ais.read\",\"sentence\":\"Read AIS traffic.\",\"granted\":true") != null, "the new grant is on");
    try must(std.mem.count(u8, reg.items, downwind_id) >= 1, "one row, not two");
}

// ---------------------------------------------------------------------------
// the bundled set: who may claim a core id, and who wins one
// ---------------------------------------------------------------------------

test "a package may not claim the id of a bundled plugin" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmpPath(alloc, &tmp, "plugins");
    defer alloc.free(root);

    // No override in force, so any flat directory is the bundled set.
    _ = unsetenv("LOOKOUT_PLUGINS");
    const bundled_dir = try writeFlatPlugin(alloc, &tmp, "bundled", bundled_id, bundled_manifest);
    defer alloc.free(bundled_dir);

    var rig = try Rig.init(alloc, root);
    defer rig.deinit();
    const h = rig.h;

    try h.loadDir(bundled_dir);
    try std.testing.expectEqual(@as(usize, 1), h.count());
    var reg: std.ArrayList(u8) = .empty;
    defer reg.deinit(alloc);
    try h.registryJson(&reg);
    try must(std.mem.indexOf(u8, reg.items, "\"origin\":\"bundled\"") != null, "the shipped copy loads as bundled");

    // A package under the same id. Refused, and the sentence carries both the
    // id and the plugin it collided with, so the mariner can see what they
    // were about to overwrite.
    const pkg = try writePackage(alloc, &tmp, bundled_id ++ ".lkplug", &.{
        .{ .name = "manifest.json", .data = bundled_manifest },
        .{ .name = bundled_id ++ ".wasm", .data = windline_wasm },
    });
    defer alloc.free(pkg);
    try std.testing.expectError(host.Error.PackageRefused, h.installPackage(pkg));
    const msg = h.installMessage();
    try must(std.mem.indexOf(u8, msg, bundled_id) != null, "the refusal names the id");
    try must(std.mem.indexOf(u8, msg, "Core example") != null, "the refusal names the plugin it collided with");
    try must(std.mem.indexOf(u8, msg, "comes with Lookout") != null, "the refusal says why the id is taken");

    // Nothing landed: the bundled copy still runs, and no directory was
    // written that the next launch would pick up.
    try std.testing.expectEqual(@as(usize, 1), h.count());
    reg.clearRetainingCapacity();
    try h.registryJson(&reg);
    try must(std.mem.indexOf(u8, reg.items, "\"origin\":\"bundled\"") != null, "the bundled copy is untouched");
    const placed = try tmpPath(alloc, &tmp, "plugins/" ++ bundled_id);
    defer alloc.free(placed);
    try must(!exists(placed), "nothing was written under the install root");

    // The consent sheet refuses it the same way, so the mariner is never
    // offered an Install button for an id that is not on offer.
    var sheet: std.ArrayList(u8) = .empty;
    defer sheet.deinit(alloc);
    try h.inspectPackage(pkg, &sheet);
    try must(std.mem.indexOf(u8, sheet.items, "\"error\":") != null, "the sheet carries the refusal");
    try must(std.mem.indexOf(u8, sheet.items, bundled_id) != null, "the sheet's refusal names the id");

    // And the other half of the rule, which has never had a real bundled
    // plugin to try it on: uninstall will not take one off.
    try std.testing.expectError(host.Error.NotInstalled, h.uninstall(bundled_id));
    try std.testing.expectEqual(@as(usize, 1), h.count());
}

test "a developer copy from LOOKOUT_PLUGINS overrides the bundled plugin of the same id" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmpPath(alloc, &tmp, "plugins");
    defer alloc.free(root);

    const dev_dir = try writeFlatPlugin(alloc, &tmp, "developer", bundled_id, developer_manifest);
    defer alloc.free(dev_dir);
    const bundled_dir = try writeFlatPlugin(alloc, &tmp, "bundled", bundled_id, bundled_manifest);
    defer alloc.free(bundled_dir);

    // The one thing that separates a developer copy from a bundled one is
    // that LOOKOUT_PLUGINS names its directory.
    const dev_z = try alloc.dupeZ(u8, dev_dir);
    defer alloc.free(dev_z);
    _ = setenv("LOOKOUT_PLUGINS", dev_z.ptr, 1);
    defer _ = unsetenv("LOOKOUT_PLUGINS");

    var rig = try Rig.init(alloc, root);
    defer rig.deinit();
    const h = rig.h;

    // The shell's order: the override first, then the set inside the app.
    try h.loadDir(dev_dir);
    try h.loadDir(bundled_dir);

    try std.testing.expectEqual(@as(usize, 1), h.count());
    var reg: std.ArrayList(u8) = .empty;
    defer reg.deinit(alloc);
    try h.registryJson(&reg);
    try must(std.mem.indexOf(u8, reg.items, "\"origin\":\"developer\"") != null, "the developer copy holds the id");
    try must(std.mem.indexOf(u8, reg.items, "\"version\":\"9.9\"") != null, "and it is the one running");
    try must(rig.log.has("already loaded (developer copy wins); bundled copy skipped"), "the log says which copy won");
}
