//! lookout-core: a chart-rendering widget. Open a baked tile57 chart, drive the
//! view (pan/zoom/rotate), set the full S-52 mariner state, and render — to a
//! window or offscreen. Tiles, tessellation and the GPU belong to charttable,
//! which this drives through src/ct/: you set state and render, and it rebuilds
//! only what it must.
//!
//! The API is deliberately small and orthogonal so a chartplotter (boat marker,
//! routes, tap-to-identify) can be built on top:
//!   open/close · fitChart/setView/view/resize · pan/zoom/screen<->geo ·
//!   getMariner/setMariner (ALL S-52 settings) · render/snapshot · pick.
//!
//! WHAT LIVES WHERE. Everything the mariner reads out of the chart — the
//! library, picks, aux files, the marks, the plugin layer — is here. Everything
//! that reaches the screen is charttable's: the style decides the portrayal,
//! the tile sources feed it, and its camera is the one camera. This file holds
//! no scene and no GPU handle.
const std = @import("std");
const builtin = @import("builtin");
const cc = @import("c.zig").c;
const cthost = @import("ct/host.zig"); // the renderer, behind one struct
const cstyle = @import("ct/style.zig");
const ctprovided = @import("ct/provided.zig");
const camera = @import("charttable").camera; // charttable's camera IS the camera
const pick_rules = @import("pick.zig"); // what a cursor pick reports, and in what order
pub const library = @import("library.zig"); // what a folder of charts holds
const png = @import("png.zig");
const ctpng = @import("charttable").png; // the renderer's decoder, for the glyph sheet
const ctglyphs = @import("charttable").glyphs;
const ctscene = @import("charttable").scene;
const ov = @import("overlay.zig");
const marks = @import("markers.zig"); // the mariner's own marks on the water

pub const Mariner = cc.tile57_mariner;
pub const Scheme = cc.tile57_scheme;

/// The wasm plugin host. Off unless build.zig turned it on (macOS with the
/// WAMR archive present), and the import itself is behind the flag: without
/// `-Dplugins` there are no WAMR headers for src/plugin/wasm.zig's @cImport to
/// find, so the file must not be analysed at all.
const plugins_on = @import("build_options").plugins;
const phost = if (plugins_on) @import("plugin/host.zig") else struct {};
const clock = @import("clock.zig");

const MAX_SCHEMES = 3; // day / dusk / night

/// The palette's name in tile57's colortables JSON, and in the sprite-atlas
/// cache key.
fn schemeName(s: Scheme) []const u8 {
    return switch (s) {
        cc.TILE57_SCHEME_DUSK => "dusk",
        cc.TILE57_SCHEME_NIGHT => "night",
        else => "day",
    };
}

/// A camera pose. rotation_deg is course-up rotation (0 = north-up).
pub const View = struct { lon: f64, lat: f64, zoom: f64, rotation_deg: f64 = 0 };

/// What an overlay hit test answers with: the object's id, its pick payload
/// and the point it draws at. Borrowed until the next overlay query.
pub const OverlayHit = ov.Store.Hit;

/// Base mariner for a build: the user's state, but with the live-gated axes
/// forced permissive so EVERY feature reaches the surface tagged, then gated
/// per-frame in the shader. Geometry-affecting fields (contours,
/// units, dates, groups…) pass through unchanged.
fn buildMarinerFrom(base: cc.tile57_mariner, sch: cc.tile57_scheme) cc.tile57_mariner {
    var m = base;
    m.scheme = sch;
    m.display_base = true;
    m.display_standard = true;
    m.display_other = true;
    m.text_names = true;
    m.show_light_descriptions = true;
    m.text_other = true;
    m.soundings = 1;
    m.size_scale = 1.0; // runtime size lives in the shader uniform
    return m;
}

/// A cache root the host handed us. Android exports neither HOME nor
/// XDG_CACHE_HOME, so there this is the ONLY way to a writable cache — the path
/// exists solely as Context.getCacheDir(). Owned here; set before opening.
var cache_root: ?[]u8 = null;

/// Adopt `path` as the cache root, replacing any previous one.
pub fn setCacheRoot(path: []const u8) void {
    const a = std.heap.c_allocator;
    const dup = a.dupe(u8, path) catch return;
    if (cache_root) |old| a.free(old);
    cache_root = dup;
}

/// `<root>/lookout/v<version>`: the host's root if it gave one, else
/// XDG_CACHE_HOME, else the platform default under HOME.
fn cacheDirPath(alloc: std.mem.Allocator, ver: []const u8) ?[]u8 {
    if (cache_root) |root| return std.fmt.allocPrint(alloc, "{s}/lookout/v{s}", .{ root, ver }) catch null;
    if (std.c.getenv("XDG_CACHE_HOME")) |x| {
        const s = std.mem.span(x);
        if (s.len > 0) return std.fmt.allocPrint(alloc, "{s}/lookout/v{s}", .{ s, ver }) catch null;
    }
    const home = std.mem.span(std.c.getenv("HOME") orelse return null);
    if (home.len == 0) return null;
    return switch (builtin.os.tag) {
        .macos, .ios => std.fmt.allocPrint(alloc, "{s}/Library/Caches/lookout/v{s}", .{ home, ver }) catch null,
        else => std.fmt.allocPrint(alloc, "{s}/.cache/lookout/v{s}", .{ home, ver }) catch null,
    };
}

/// The app's atlas cache directory — purgeable by the OS (it's a rebuildable
/// cache). Created here; owned by `alloc`. Null if no root can be resolved.
/// Keyed by tile57 version so a catalogue/engine change invalidates old atlases.
pub fn atlasCacheDir(alloc: std.mem.Allocator) ?[]u8 {
    const ver = std.mem.span(cc.tile57_version());
    const dir = cacheDirPath(alloc, ver) orelse return null;
    const io = std.Io.Threaded.global_single_threaded.io();
    std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    return dir;
}

/// True when the atlas cache is already populated (the density-independent glyph
/// atlas is present) — i.e. the next open will NOT need the one-time bake. The
/// host queries this to show a "preparing symbols" message only on first run.
pub fn atlasCacheReady(alloc: std.mem.Allocator) bool {
    const dir = atlasCacheDir(alloc) orelse return false;
    defer alloc.free(dir);
    const path = std.fmt.allocPrint(alloc, "{s}/glyph.png", .{dir}) catch return false;
    defer alloc.free(path);
    const io = std.Io.Threaded.global_single_threaded.io();
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn fileExists(path: []const u8) bool {
    const io = std.Io.Threaded.global_single_threaded.io();
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

pub const OpenOptions = struct {
    width: u32 = 1280,
    height: u32 = 960,
    want_window: bool = false,
    want_msaa: bool = true,
    /// palettes captured at build so scheme changes are instant. All three by
    /// default (day/dusk/night); index order defines the scheme<->buffer map.
    schemes: []const Scheme = &.{ cc.TILE57_SCHEME_DAY, cc.TILE57_SCHEME_DUSK, cc.TILE57_SCHEME_NIGHT },
    /// here for next time. Point this somewhere per chart-library.
    /// EMBED into a host view: hand over its CAMetalLayer (kind .metal_layer)
    /// and lookout renders/presents straight into it — the host keeps its own
    /// toolkit and event loop. Then just call render() each frame and feed
    /// input via pan/zoom/setView/resize.
    native_handle: ?*anyopaque = null,
    native_kind: cthost.NativeKind = .none,
};

pub const NativeKind = cthost.NativeKind;

const Lock = @import("lock.zig").Lock;

/// Everything the plugin layer needs from the core, in one heap allocation:
/// the vessel store, the AIS store, the broker that implements the ABI over
/// them, and the registry that runs the modules.
///
/// The OVERLAY store is not in here. The core draws into it too: the
/// mariner's markers are core-owned and outlive any plugin, so it belongs to
/// the handle and this layer only borrows it.
///
/// Heap-allocated and built in place because the broker holds pointers to the
/// stores beside it — moving this struct would dangle them.
const PluginSystem = if (plugins_on) struct {
    alloc: std.mem.Allocator,
    vessels: phost.store.Store,
    ais: phost.aisstore.AisStore,
    br: phost.broker.Broker,
    host: phost.Host,
    /// Scratch for the registry and config JSON the C ABI hands out. Borrowed
    /// by the caller until the next such call, like every other query here.
    json: std.ArrayList(u8) = .empty,

    fn create(alloc: std.mem.Allocator, overlay: *ov.Store) !*@This() {
        const self = try alloc.create(@This());
        errdefer alloc.destroy(self);
        self.* = .{
            .alloc = alloc,
            .vessels = try phost.store.Store.init(alloc),
            .ais = phost.aisstore.AisStore.init(alloc),
            .br = undefined,
            .host = undefined,
        };
        self.br = phost.broker.Broker.init(alloc, &self.vessels, &self.ais, .{
            .ctx = overlay,
            .applyFn = applyOverlay,
            .removeFn = removeOverlay,
        });
        self.host = phost.Host.init(alloc, &self.br, optionsFromEnv());
        return self;
    }

    /// Order matters: the registry stops the dispatch thread (delivering
    /// SHUTDOWN, which can still draw and publish) before the broker stops the
    /// I/O thread, and both are down before the stores they write to go. The
    /// overlay store is the handle's and outlives this.
    fn destroy(self: *@This()) void {
        const gpa = self.alloc;
        self.host.deinit();
        self.br.deinit();
        self.ais.deinit();
        self.vessels.deinit();
        self.json.deinit(gpa);
        gpa.destroy(self);
    }

    /// `LOOKOUT_NMEA=host:port` is the one piece of plugin configuration the
    /// prototype carries; it reaches nmea0183 through its lk_start payload.
    fn optionsFromEnv() phost.Options {
        var opts = phost.Options{};
        const raw = std.c.getenv("LOOKOUT_NMEA") orelse return opts;
        const text = std.mem.span(raw);
        const colon = std.mem.lastIndexOfScalar(u8, text, ':') orelse return opts;
        if (colon == 0 or colon + 1 >= text.len) return opts;
        opts.nmea_host = text[0..colon];
        opts.nmea_port = std.fmt.parseInt(u16, text[colon + 1 ..], 10) catch return .{};
        return opts;
    }

    fn applyOverlay(ctx: ?*anyopaque, source: []const u8, json: []const u8) anyerror!void {
        const s: *ov.Store = @ptrCast(@alignCast(ctx.?));
        return s.applyBatch(source, json);
    }

    fn removeOverlay(ctx: ?*anyopaque, source: []const u8) void {
        const s: *ov.Store = @ptrCast(@alignCast(ctx.?));
        s.removeSource(source);
    }

    /// Everything own ship's display position and course-up need, elected and
    /// checked for staleness in one pass.
    fn readShip(vessels: *phost.store.Store, now_ms: i64) ShipRead {
        var out = ShipRead{};
        if (vessels.readElected("navigation.position", now_ms)) |r| {
            if (!r.stale and r.value == .position)
                out.fix = .{ .lon = r.value.position.lon, .lat = r.value.position.lat, .ts_ms = r.ts_ms };
        }
        out.cog_deg = number(vessels, "navigation.courseOverGroundTrue", now_ms);
        out.sog_ms = number(vessels, "navigation.speedOverGround", now_ms);
        out.heading_deg = number(vessels, "navigation.headingTrue", now_ms);
        return out;
    }

    /// A fresh elected number, or null when the path is empty or stale.
    fn number(vessels: *phost.store.Store, path: []const u8, now_ms: i64) ?f64 {
        const r = vessels.readElected(path, now_ms) orelse return null;
        if (r.stale or r.value != .number) return null;
        return r.value.number;
    }
} else struct {};

/// One position from the store, with the time it was published.
const ShipFix = struct { lon: f64, lat: f64, ts_ms: i64 };

/// The own-ship values a frame needs. A null field is missing or stale.
const ShipRead = struct {
    fix: ?ShipFix = null,
    cog_deg: ?f64 = null,
    sog_ms: ?f64 = null,
    heading_deg: ?f64 = null,
};

/// Metres per degree of latitude. The display position moves metres between
/// fixes, so a spherical step is exact enough and costs one multiply.
const M_PER_DEG: f64 = 40075016.685578488 / 360.0;

/// Own ship as the screen shows it. Fixes land about once a second and a chart
/// that only moved then would step, so the newest fix is carried forward along
/// COG at SOG. The carry stops at the staleness window: a lost GPS must not
/// keep the boat sailing.
const ShipDisplay = struct {
    /// The store's staleness window. Past it there is no display position.
    const CARRY_MS: i64 = 5_000;
    /// Below this the course a GPS reports is noise, not a heading: 0.4 kn in
    /// metres per second. Course up freezes on the last good course there.
    const COURSE_FLOOR_MS: f64 = 0.4 * 1852.0 / 3600.0;
    /// Weight of a new course in the smoothed one. About a three second lag at
    /// the 1 Hz fixes this carries, which is what stops the chart hunting.
    const COURSE_ALPHA: f64 = 0.25;

    last: ?ShipFix = null,
    prev: ?ShipFix = null,
    cog_deg: ?f64 = null,
    sog_ms: ?f64 = null,
    heading_deg: ?f64 = null,
    /// The course the display position is travelling, low-passed. Course up
    /// turns the chart to this, not to the raw value.
    course_deg: ?f64 = null,

    /// Take this frame's values. A fix already held is not a new fix.
    fn observe(self: *ShipDisplay, r: ShipRead) void {
        var fresh = false;
        if (r.fix) |f| {
            const same = if (self.last) |l| l.ts_ms == f.ts_ms and l.lon == f.lon and l.lat == f.lat else false;
            if (!same) {
                self.prev = self.last;
                self.last = f;
                fresh = true;
            }
        } else {
            self.last = null;
            self.prev = null;
        }
        self.cog_deg = r.cog_deg;
        self.sog_ms = r.sog_ms;
        self.heading_deg = r.heading_deg;
        // Once per fix, not once per frame: the smoothing constant below is in
        // fixes, and this runs on every tick.
        if (fresh) self.trackCourse();
    }

    /// Fold this frame's course into the smoothed one. A boat under the
    /// speed floor keeps the course it had: a drifting GPS would otherwise
    /// spin the chart while the boat sits still.
    fn trackCourse(self: *ShipDisplay) void {
        const v = self.velocity() orelse return;
        const speed = @sqrt(v[0] * v[0] + v[1] * v[1]);
        if (speed < COURSE_FLOOR_MS) return;
        const raw = std.math.atan2(v[0], v[1]) * 180.0 / std.math.pi;
        const prev = self.course_deg orelse {
            self.course_deg = wrap360(raw);
            return;
        };
        // Smooth the SHORT way round: 350 and 10 degrees are 20 apart.
        var d = raw - prev;
        d -= 360.0 * @round(d / 360.0);
        self.course_deg = wrap360(prev + COURSE_ALPHA * d);
    }

    /// Where to draw own ship at `now_ms`: the newest fix carried forward.
    /// Null with no fix, or when the carry has run past the window.
    fn at(self: ShipDisplay, now_ms: i64) ?[2]f64 {
        const l = self.last orelse return null;
        const dt_ms = now_ms - l.ts_ms;
        if (dt_ms > CARRY_MS) return null;
        if (dt_ms <= 0) return .{ l.lon, l.lat };
        const v = self.velocity() orelse return .{ l.lon, l.lat };
        const dt = @as(f64, @floatFromInt(dt_ms)) / 1000.0;
        const lat = l.lat + v[1] * dt / M_PER_DEG;
        const coslat = @max(0.01, @cos(l.lat * std.math.pi / 180.0));
        return .{ l.lon + v[0] * dt / (M_PER_DEG * coslat), lat };
    }

    /// Metres per second east and north: COG and SOG when the instruments
    /// give them, else the run between the last two fixes.
    fn velocity(self: ShipDisplay) ?[2]f64 {
        if (self.cog_deg) |c| {
            if (self.sog_ms) |sp| {
                const th = c * std.math.pi / 180.0;
                return .{ sp * @sin(th), sp * @cos(th) };
            }
        }
        const l = self.last orelse return null;
        const p = self.prev orelse return null;
        const dt = @as(f64, @floatFromInt(l.ts_ms - p.ts_ms)) / 1000.0;
        if (!(dt > 0.05)) return null;
        const coslat = @max(0.01, @cos(l.lat * std.math.pi / 180.0));
        return .{ (l.lon - p.lon) * M_PER_DEG * coslat / dt, (l.lat - p.lat) * M_PER_DEG / dt };
    }

    /// What course up turns the chart to: the smoothed display course. Null
    /// before the boat has moved, and frozen while it is stopped.
    fn upDeg(self: ShipDisplay) ?f64 {
        if (self.last == null) return null; // no fix: nothing to turn to
        return self.course_deg;
    }
};

/// One overlay batch describing every mark. A free function so the tests can
/// feed the same text to a bare overlay store: a canvas the store refuses
/// draws nothing and says so only in a log line.
fn markerBatch(a: std.mem.Allocator, json: *std.ArrayList(u8), list: []const marks.Marker, c: [4]f64) !void {
    try json.appendSlice(a, "{\"set\":[");
    for (list, 0..) |m, i| {
        if (i > 0) try json.append(a, ',');
        // `sa` first: the mark and its name hold their screen orientation
        // while the chart turns under course up. A ring with a white halo
        // under it, so the mark reads on a dark chart as well as a light
        // one, and a dot at the position itself: the ring says "about
        // here", the dot says where.
        try json.print(a, "{{\"id\":\"{d}\",\"kind\":\"canvas\",\"space\":\"points\"," ++
            "\"at\":[{d},{d}],\"cmds\":[[\"sa\"]," ++
            "[\"ss\",[1,1,1,0.85]],[\"lw\",3.5],[\"P\"],[\"A\",0,0,6.5,0,360],[\"S\"]," ++
            "[\"ss\",[{d},{d},{d},{d}]],[\"lw\",2],[\"P\"],[\"A\",0,0,6.5,0,360],[\"S\"]," ++
            "[\"fs\",[{d},{d},{d},{d}]],[\"P\"],[\"A\",0,0,2.2,0,360],[\"F\"]," ++
            "[\"font\",12,\"bold\"],[\"ta\",\"left\"],", .{
            m.id, m.lon, m.lat, c[0], c[1], c[2], c[3], c[0], c[1], c[2], c[3],
        });
        // The name, in white four ways round and then in magenta over it.
        // Canvas text has no outline of its own, and a chart is as likely
        // to be dark under the label as light.
        try json.appendSlice(a, "[\"fs\",[1,1,1,0.9]],");
        for ([4][2]f64{ .{ 11, 3 }, .{ 13, 3 }, .{ 11, 5 }, .{ 13, 5 } }) |o| {
            try json.print(a, "[\"T\",{d},{d},", .{ o[0], o[1] });
            try marks.jsonString(a, json, m.name);
            try json.appendSlice(a, "],");
        }
        try json.print(a, "[\"fs\",[{d},{d},{d},{d}]],[\"T\",12,4,", .{ c[0], c[1], c[2], c[3] });
        try marks.jsonString(a, json, m.name);
        try json.appendSlice(a, "]]}");
    }
    try json.appendSlice(a, "]}");
}

/// A bearing folded into [0, 360).
fn wrap360(deg: f64) f64 {
    const d = @mod(deg, 360.0);
    return if (d < 0) d + 360.0 else d;
}

/// What follow mode is doing, for the shell's lock control. Anything but `off`
/// means follow is on: `waiting` is armed with no usable fix.
pub const FollowState = enum(c_int) { off = 0, following = 1, waiting = 2 };

/// Follow mode: own ship held at a fixed point on screen while the chart
/// slides under it. The core owns the behaviour; a shell only draws the button
/// and calls setFollow. Camera moves go through here so every entry point
/// (frame tick, pan, zoom) obeys the same rules.
const Follow = struct {
    /// The anchor, as a fraction of the view: horizontal centre, three quarters
    /// down, so the water ahead fills the screen.
    const anchor_x = 0.5;
    const anchor_y = 0.75;

    /// Below this the chart is not re-turned. Course-up follows a heading that
    /// wanders a tenth of a degree at a time, and every turn is a repaint.
    const ROT_DEADBAND = 0.2 * std.math.pi / 180.0;

    on: bool = false,
    /// Course-up: the chart turns so own ship's heading points up the screen.
    /// Independent of follow — the mariner can have either alone.
    course_up: bool = false,
    /// The fix and the camera pose the last move produced. A tick that finds
    /// both unchanged does nothing, so a placement the mercator clamp could not
    /// finish does not re-fire every frame.
    applied: ?Applied = null,

    const Applied = struct {
        fix: camera.Vec2,
        center: camera.Vec2,
        zoom: f64,
        rotation: f64,
        vw: f32,
        vh: f32,
    };

    /// The anchor in the camera's own unit (logical px).
    fn anchor(cam: camera.Camera) [2]f32 {
        return .{ cam.vw * anchor_x, cam.vh * anchor_y };
    }

    fn clear(self: *Follow) void {
        self.on = false;
        self.applied = null;
    }

    /// The view rotation that puts a true bearing at the top of the screen.
    /// A world bearing draws at screen bearing (bearing + rotation).
    fn rotationFor(up_deg: f64) f64 {
        const r = -up_deg * std.math.pi / 180.0;
        return r - 2.0 * std.math.pi * @round(r / (2.0 * std.math.pi));
    }

    /// True when course-up would turn the chart: it is on, a heading is fresh,
    /// and the chart is more than the deadband away from it.
    fn rotatePending(self: Follow, cam: camera.Camera, up_deg: ?f64) bool {
        if (!self.course_up) return false;
        const want = rotationFor(up_deg orelse return false);
        var d = want - cam.rotation;
        d -= 2.0 * std.math.pi * @round(d / (2.0 * std.math.pi));
        return @abs(d) > ROT_DEADBAND;
    }

    /// Turn the chart to the heading. True when it moved.
    fn rotate(self: Follow, cam: *camera.Camera, up_deg: ?f64) bool {
        if (!self.rotatePending(cam.*, up_deg)) return false;
        cam.rotation = rotationFor(up_deg.?);
        return true;
    }

    /// True when a tick would move the camera. needsRedraw asks, so a
    /// render-on-demand shell wakes for a new fix.
    fn pending(self: Follow, cam: camera.Camera, fix: ?camera.Vec2) bool {
        if (!self.on) return false;
        const w = fix orelse return false; // no fix, or stale: armed and waiting
        const p = self.applied orelse return true;
        return !(p.fix.x == w.x and p.fix.y == w.y and
            p.center.x == cam.center.x and p.center.y == cam.center.y and
            p.zoom == cam.zoom and p.rotation == cam.rotation and
            p.vw == cam.vw and p.vh == cam.vh);
    }

    /// Put the fix back on the anchor. A null fix (none yet, or stale) leaves
    /// the camera alone. True when the camera moved.
    fn apply(self: *Follow, cam: *camera.Camera, fix: ?camera.Vec2) bool {
        if (!self.pending(cam.*, fix)) return false;
        const w = fix.?;
        const a = anchor(cam.*);
        cam.placeAt(w, a[0], a[1]);
        self.applied = .{
            .fix = w,
            .center = cam.center,
            .zoom = cam.zoom,
            .rotation = cam.rotation,
            .vw = cam.vw,
            .vh = cam.vh,
        };
        return true;
    }

    /// A pan hands the chart back to the mariner: the pan happens and follow
    /// goes off.
    fn pan(self: *Follow, cam: *camera.Camera, dx: f32, dy: f32) void {
        self.clear();
        cam.panPx(dx, dy);
    }

    /// Where a zoom pivots: the anchor while following, whatever point the
    /// caller passed, so own ship does not drift off it.
    fn zoomFocus(self: Follow, cam: camera.Camera, x: f32, y: f32) [2]f32 {
        return if (self.on) anchor(cam) else .{ x, y };
    }

    fn zoomAbout(self: Follow, cam: *camera.Camera, dz: f64, x: f32, y: f32) void {
        const f = self.zoomFocus(cam.*, x, y);
        cam.zoomAbout(dz, f[0], f[1]);
    }

    fn zoomToward(self: Follow, cam: *camera.Camera, dz: f64, x: f32, y: f32) void {
        const f = self.zoomFocus(cam.*, x, y);
        cam.zoomToward(dz, f[0], f[1]);
    }
};

/// Per-frame phase timings for $LOOKOUT_PHASE_PROF. Rows accumulate in a fixed
/// buffer and the whole file is rewritten every `flush_every` frames, because
/// nothing tells a renderer when the run has ended — an .app has no stderr to
/// stream to and no natural place to close a file.
pub const FrameProf = struct {
    pub const Row = struct {
        prepare_us: i64,
        style_us: i64,
        trim_us: i64,
        overlay_us: i64,
        ct_us: i64,
        /// ct_us split three ways (ct/host.zig render): the map/tile pump, the
        /// GPU upload of a changed scene, and the encode+present that blocks on
        /// the swapchain's drawable.
        ct_update_us: i64,
        ct_upload_us: i64,
        ct_present_us: i64,
    };
    const cap = 4096;
    const flush_every = 60;

    path: []const u8,
    rows: [cap]Row = undefined,
    n: usize = 0,
    since_flush: usize = 0,

    pub fn record(self: *FrameProf, row: Row) void {
        if (self.n < cap) {
            self.rows[self.n] = row;
            self.n += 1;
        }
        self.since_flush += 1;
        if (self.since_flush >= flush_every) {
            self.since_flush = 0;
            self.write();
        }
    }

    pub fn write(self: *FrameProf) void {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(std.heap.c_allocator);
        buf.appendSlice(std.heap.c_allocator, "prepare_us,style_us,trim_us,overlay_us,ct_us,ct_update_us,ct_upload_us,ct_present_us\n") catch return;
        var line: [192]u8 = undefined;
        for (self.rows[0..self.n]) |r| {
            const s = std.fmt.bufPrint(&line, "{d},{d},{d},{d},{d},{d},{d},{d}\n", .{
                r.prepare_us,   r.style_us,     r.trim_us,       r.overlay_us, r.ct_us,
                r.ct_update_us, r.ct_upload_us, r.ct_present_us,
            }) catch continue;
            buf.appendSlice(std.heap.c_allocator, s) catch return;
        }
        const io = std.Io.Threaded.global_single_threaded.io();
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = self.path, .data = buf.items }) catch {};
    }
};

pub const Lookout = struct {
    alloc: std.mem.Allocator,
    charts: std.ArrayList(*cc.tile57_chart) = .empty, // 1 (single) or many (composed)
    /// Cell name -> the directory the archive sits in. A cell's referenced text
    /// and pictures live there (see tile57_aux_*), and a pick report names the
    /// cell, so this is what turns that name into files.
    chart_dirs: std.StringHashMapUnmanaged([]u8) = .empty,
    /// Every opened archive's path, in the order the charts were opened.
    chart_paths: std.ArrayList([:0]u8) = .empty,
    /// The aux handles already opened, by cell name. Opened on first ask.
    aux: std.StringHashMapUnmanaged(?*cc.tile57_aux) = .empty,
    compose: ?*cc.tile57_compose = null, // set when >1 chart (ENC_ROOT / library)
    /// The renderer: charttable's map, surface, style, atlases and sources.
    ct: cthost.Host,
    /// charttable's camera, borrowed. There is only ever one camera, and it is
    /// the one the renderer projects with — a copy here would drift within a
    /// frame. Its zoom is in charttable's convention; the ABI's is converted in
    /// ct/host.zig, and nothing between the two touches it.
    cam: *camera.Camera = undefined,

    // The ownership-partition build (compose_open over the whole library) is slow
    // — run it on a worker thread and show a loader so the window isn't frozen.
    loading: bool = false,
    compose_thread: ?std.Thread = null,
    compose_done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    compose_result: ?*cc.tile57_compose = null,
    /// Open with no vector chart: the raster layer is the whole display.
    /// Nothing tessellates, and every path that reads a cell steps aside.
    raster_only: bool = false,
    /// The composition the last one replaced. Closed once the new one is
    /// adopted: the render thread may still be drawing from it until then.
    compose_prev: ?*cc.tile57_compose = null,
    /// A composition is being rebuilt over a library that is already drawing.
    /// Unlike `loading` this leaves the chart on screen.
    recomposing: bool = false,

    view_dirty: bool = true, // camera/state changed since the last render (on-demand)
    last_change_ms: i64 = 0, // when the view last moved
    /// When a frame last went out for own ship's own motion (see SHIP_FRAME_MS).
    last_ship_frame_ms: i64 = 0,
    /// A style the host supplied, drawn instead of the engine's portrayal.
    /// Null means the chart is lookout's own. While one is set, the mariner's
    /// display settings do not shape the chart: it is the publisher's.
    alt_style: ?[]u8 = null,

    // API-entry lock (see capi.locked): serializes the C ABI between the
    // host's input thread and its render thread. Distinct from engine_mu,
    // which serializes ENGINE access between API calls and the build worker;
    // api_mu is always the OUTER lock of the two.
    api_mu: Lock = .{},
    // Serializes ENGINE entry from other threads against the build worker: the
    // engine mutates shared state on any access (reader directory caches decode
    // lazily, the geometry cache inserts/evicts), so a main-thread pick during
    // an in-flight worker build is a data race without this. Held for the whole
    // engine call; a tap during a slow build waits rather than corrupting.
    // os_unfair_lock (kernel-blocking, not a spin) because Zig 0.16 puts
    // std's mutex behind an Io, which this layer does not take.
    engine_mu: Lock = .{},
    // viewMaxZoom cache (see there).
    zl_valid: bool = false,
    zl_center: camera.Vec2 = .{ .x = 0, .y = 0 },
    zl_zoom: f64 = 0,
    zl_max: f64 = 22,
    /// Set by the host on an OS memory warning; served at the next safe point.
    trim_requested: bool = false,
    /// True while a host surface is attached and frames can run. False between
    /// detachSurface and attachSurface, when the core stands with no view.
    surface_attached: bool = false,
    /// The host's declared logical viewport, and authoritative over anything
    /// derived from the surface: across a rotation a swapchain keeps reporting
    /// the OLD extent, which inverts the aspect and skews every rotated frame.
    host_pt_w: f32 = 0,
    host_pt_h: f32 = 0,
    schemes: [MAX_SCHEMES]Scheme = undefined,
    n_schemes: usize = 0,

    /// The authoritative S-52 display state. Edit via get/setMariner.
    mariner: Mariner = undefined,
    /// The style is stale and has to be rebuilt before the next frame. Set by
    /// any mariner change: in charttable the mariner lives in the STYLE, not in
    /// a uniform, so applying one means building the style again and setting
    /// it. That is a relayout of the resident tiles and no more — the tiles
    /// themselves carry tokens and raw depths and never change.
    style_dirty: bool = true,
    /// The palette the sprite sheet was baked FOR. A symbol carries its colours
    /// in its artwork, so the sheet is what decides whether symbols and complex
    /// line styles are day-bright or night-dim, and a scheme change has to load
    /// the sheet for the new palette.
    sprite_scheme: ?Scheme = null,
    /// The density the sprite sheet was baked at, and the one runtime symbol
    /// runs are rendered at so they match it.
    sprite_density: f32 = 0,
    /// The app's atlas cache dir ($HOME/Library/Caches/lookout/...), or null.
    assets_root: ?[]u8 = null,
    atlases_ready: bool = false, // see ensureAtlases: loaded at first use, not at open
    engine_max_zoom: f64 = 24, // deepest zoom the chart/compositor serves
    /// The distinct SCAMIN denominators the open library carries, ascending.
    /// The style splits its `_scamin` layers into one bucket per value, each
    /// with a native fractional minzoom, so a feature appears at its exact
    /// display scale with no per-frame work. Collected once per composition.
    scamin: []i32 = &.{},
    /// The glyph face handed to the overlay store, and the em size its pixel
    /// metrics are measured at (tile57 writes it into the sheet's index).
    glyph_face: GlyphFace = undefined,
    glyph_em_px: f32 = 24,

    /// The wasm plugin layer, once something has asked for it (LOOKOUT_PLUGINS
    /// at open, or lookout_plugins_load). Null costs nothing: no threads, no
    /// stores, no runtime.
    plugins: ?*PluginSystem = null,

    /// The retained chart overlay: what plugins post and what the core draws
    /// over the chart. The handle owns it, because the marks below go into it
    /// and they exist with no plugin layer at all.
    overlay: ov.Store = undefined,
    /// The mariner's markers, read at open and written on every change.
    markers: marks.Store = undefined,
    /// The palette the marker geometry was posted for. The marks carry their
    /// colour as RGBA rather than a plugin palette token, so a scheme change
    /// has to re-post them; comparing here is what notices.
    markers_scheme: ov.Scheme = .day,

    /// Follow mode and course-up, off until a shell turns them on.
    follow: Follow = .{},
    /// Own ship between fixes, and where this frame draws it (lon, lat).
    ship: ShipDisplay = .{},
    ship_at: ?[2]f64 = null,

    /// Hide the chart WHERE A PICTURE COVERS IT, and keep it everywhere else.
    /// The underlay moves in front of the whole chart instead of only its area
    /// fills, so this needs no rebuild and no second scene. Flip it over a
    /// feature: anything that moves is a real disagreement between the chart and
    /// the picture.
    chart_hidden: bool = false,

    /// The physical size multiplier for symbols and text (S-52 sizes are in
    /// millimetres). Uniform-only in charttable, so it never rebuilds a style.
    render_size_scale: f32 = 1.0,

    /// $LOOKOUT_PHASE_PROF=<path>: per-frame phase timings, written as CSV.
    /// Null unless asked for, and every probe is behind `if (prof)`.
    frame_prof: ?FrameProf = null,
    prof_checked: bool = false,
    /// The SCAMIN latitude the current style was built at. See STYLE_LAT_DRIFT.
    style_lat: f64 = 0,
    /// ensureStyle's own microseconds, handed up from prepareFrame.
    prof_style_us: i64 = 0,

    // ---- lifecycle ----------------------------------------------------------
    /// Open ONE baked chart (.pmtiles).
    pub fn open(alloc: std.mem.Allocator, chart_path: [:0]const u8, opts: OpenOptions) !*Lookout {
        return openCharts(alloc, &.{chart_path}, opts);
    }

    /// Open MANY baked charts and compose them (a chart library). Bad charts are
    /// skipped; composing kicks in automatically when more than one loads.
    pub fn openCharts(alloc: std.mem.Allocator, paths: []const [:0]const u8, opts: OpenOptions) !*Lookout {
        const self = try create(alloc, opts);
        errdefer self.close();
        const t0 = clock.ticksMs();
        self.openChartPaths(paths);
        const t1 = clock.ticksMs();
        try self.finishOpen();
        const t2 = clock.ticksMs();
        std.debug.print("open: {d} charts opened in {d} ms, compose+partition in {d} ms\n", .{ self.charts.items.len, t1 - t0, t2 - t1 });
        return self;
    }

    fn create(alloc: std.mem.Allocator, opts: OpenOptions) !*Lookout {
        const dbg = std.c.getenv("LOOKOUT_TIMING") != null;
        var t = clock.ticksMs();
        cc.tile57_warmup();
        if (dbg) {
            std.debug.print("  warmup {d} ms\n", .{clock.ticksMs() - t});
            t = clock.ticksMs();
        }
        const self = try alloc.create(Lookout);
        self.* = .{
            .alloc = alloc,
            .ct = undefined,
            .surface_attached = opts.want_window or opts.native_handle != null,
            .overlay = ov.Store.init(alloc),
            .markers = if (marks.defaultPathAlloc(alloc)) |p| blk: {
                defer alloc.free(p);
                break :blk marks.Store.open(alloc, p);
            } else marks.Store.init(alloc),
        };
        // After the struct is in place: the tile workers take a pointer to the
        // engine lock that lives in it, so the Host cannot be built before its
        // home address exists. Nothing owns anything yet if it fails, except
        // the two stores just built, so they go back by hand — close() cannot
        // run against a handle whose renderer was never created.
        self.ct = cthost.Host.init(alloc, &self.engine_mu, .{
            .width = opts.width,
            .height = opts.height,
            .want_window = opts.want_window,
            .want_msaa = opts.want_msaa,
            .native_handle = opts.native_handle,
            .native_kind = opts.native_kind,
        }) catch |e| {
            self.overlay.deinit();
            self.markers.deinit();
            alloc.destroy(self);
            return e;
        };
        self.cam = self.ct.camera();
        if (dbg) {
            std.debug.print("  charttable init (Metal device+shaders+pipelines) {d} ms\n", .{clock.ticksMs() - t});
            t = clock.ticksMs();
        }
        self.n_schemes = @min(opts.schemes.len, MAX_SCHEMES);
        for (0..self.n_schemes) |i| self.schemes[i] = opts.schemes[i];
        cc.tile57_mariner_defaults(&self.mariner);
        // Default to the look of a traditional paper chart, using only mariner
        // settings. tile57's defaults are already half-way there (day scheme,
        // four-shade graduated-blue water, symbolized boundaries, full point
        // symbols — none of the "simplified" ECDIS symbology). What's left is
        // the *content*: a paper chart has no display categories and no ECDIS
        // overscale indicator, so —
        self.mariner.display_other = true; // show seabed, cables, contour labels — the OTHER content paper always carries
        self.mariner.soundings = 1; // paper is covered in spot soundings; show them regardless of category
        self.mariner.show_overscale = false; // AP(OVERSC01) hatch is an ECDIS-only artifact, never on paper
        // The ECDIS-only OTHER overlays (info callouts, meta boundaries, data
        // quality) stay off in tile57's defaults, so display_other brings the
        // paper content without the ECDIS clutter. finishOpen -> applyZoomAndView
        // derives the live gates (cat_mask/sound_on/clear) from this before the
        // first render.
        // The marks the mariner already had, on the chart before the first
        // frame: they belong to the boat, not to the cell being opened. AFTER
        // the mariner state above, because the marks are posted in the colours
        // of the palette it names.
        self.postMarkers();
        self.assets_root = atlasCacheDir(self.alloc);
        // NOT the atlases: they bake at the display density, and nothing has
        // told us what that is yet — the host cannot call resize() or
        // setPixelDensity() until this returns a handle. Baking here pinned
        // every symbol and glyph at 1.00x and then sampled it upscaled. See
        // ensureAtlases, which runs once the density is known.
        return self;
    }

    /// Load the symbol + glyph atlases, once, at the first build or draw — by
    /// which point the host has declared its density. Both are keyed on that
    /// density, so loading any earlier bakes the wrong sheet.
    ///
    /// The symbol atlas loads again whenever the mariner changes scheme, because
    /// its palette is in its pixels. The glyph atlas does not: SDF coverage is
    /// palette-independent and the scene tints each text range.
    fn ensureAtlases(self: *Lookout) void {
        const dbg = std.c.getenv("LOOKOUT_TIMING") != null;
        var t = clock.ticksMs();
        const density = self.ct.pixelDensity();
        if (self.sprite_scheme == null or self.sprite_scheme.? != self.mariner.scheme or
            self.sprite_density != density)
        {
            self.loadSpriteSheet(density);
            if (dbg) {
                std.debug.print("  loadSpriteSheet {d} ms\n", .{clock.ticksMs() - t});
                t = clock.ticksMs();
            }
        }
        if (self.atlases_ready) return;
        self.atlases_ready = true;
        self.loadGlyphSheet();
        if (dbg) std.debug.print("  loadGlyphSheet {d} ms\n", .{clock.ticksMs() - t});
    }

    /// Read `<cache>/<name>` (the app's own atlas cache), or null on any miss.
    fn readCache(self: *Lookout, name: []const u8) ?[]u8 {
        const root = self.assets_root orelse return null;
        const path = std.fmt.allocPrint(self.alloc, "{s}/{s}", .{ root, name }) catch return null;
        defer self.alloc.free(path);
        const io = std.Io.Threaded.global_single_threaded.io();
        return std.Io.Dir.cwd().readFileAlloc(io, path, self.alloc, .limited(256 * 1024 * 1024)) catch null;
    }

    /// Write `<cache>/<name>`. Best-effort: the atlas is already uploaded, so a
    /// failure just means the next open re-bakes.
    fn writeCache(self: *Lookout, name: []const u8, bytes: []const u8) void {
        const root = self.assets_root orelse return;
        const path = std.fmt.allocPrint(self.alloc, "{s}/{s}", .{ root, name }) catch return;
        defer self.alloc.free(path);
        const io = std.Io.Threaded.global_single_threaded.io();
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes }) catch {};
    }

    // The SDF label-glyph sheet: from the app cache if present, else baked
    // once from the embedded catalogue and cached. charttable takes the sheet
    // as pixels plus tile57's own index JSON — the two agree on the format
    // already (em_px, pad, per-glyph UVs and EM-unit metrics), so nothing is
    // converted here and no fontnik PBFs exist anywhere in this stack.
    //
    // ONE FACE. lookout baked three (regular, bold, italic) and the backend
    // held a texture for each. charttable's assets carry one atlas, so bold
    // and italic labels draw in the regular face until it grows them. See
    // specs/charttable/concerns.md C4.
    fn loadGlyphSheet(self: *Lookout) void {
        if (self.readCache("glyph.png")) |png_b| {
            defer self.alloc.free(png_b);
            if (self.readCache("glyph.json")) |json| {
                defer self.alloc.free(json);
                if (self.giveGlyphSheet(png_b, json)) return;
            }
        }
        var assets: cc.tile57_assets = std.mem.zeroes(cc.tile57_assets);
        var err: cc.tile57_error = undefined;
        if (cc.tile57_bake_glyph_sdf(&assets, &err) != cc.TILE57_OK) return;
        defer cc.tile57_assets_free(&assets);
        if (assets.sprite_png == null or assets.sprite_json == null) return;
        const png_b = assets.sprite_png[0..assets.sprite_png_len];
        const json = assets.sprite_json[0..assets.sprite_json_len];
        if (self.giveGlyphSheet(png_b, json)) {
            self.writeCache("glyph.png", png_b);
            self.writeCache("glyph.json", json);
        }
    }

    /// Decode the sheet and hand it over. The decode is ours because
    /// charttable's glyph door takes pixels, not a PNG. It is one sheet at
    /// startup, so the cost is paid once.
    fn giveGlyphSheet(self: *Lookout, png_bytes: []const u8, json: []const u8) bool {
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const img = ctpng.read(arena.allocator(), png_bytes) catch |e| {
            std.debug.print("glyph sheet: {s}\n", .{@errorName(e)});
            return false;
        };
        if (!self.ct.setGlyphSheet(json, img.rgba, img.w, img.h)) return false;
        // The em size the sheet's metrics are measured at. The overlay store
        // lays canvas text out in EM units and the atlas answers in pixels, so
        // without this every plugin label would be the wrong size.
        if (std.json.parseFromSlice(std.json.Value, self.alloc, json, .{})) |parsed| {
            defer parsed.deinit();
            if (parsed.value == .object) {
                if (parsed.value.object.get("em_px")) |v| switch (v) {
                    .integer => |i| self.glyph_em_px = @floatFromInt(i),
                    .float => |f| self.glyph_em_px = @floatCast(f),
                    else => {},
                };
            }
        } else |_| {}
        std.debug.print("glyph sheet: {d}x{d}, em {d:.0}\n", .{ img.w, img.h, self.glyph_em_px });
        return true;
    }

    /// The largest sprite-sheet texture dimension this platform can hold as ONE
    /// texture. Real iOS devices report 16384, but a 3x symbol atlas is ~10.9k px
    /// tall (~268 MB RGBA) and such a texture UPLOADS ONLY PARTIALLY on device —
    /// the un-populated rows sample black, so symbols and line-style patterns
    /// packed low in the sheet render as solid-black blobs. Cap iOS (device AND
    /// simulator) at 8192 so the bake reduces its scale to fit; macOS is fine.
    fn spriteMaxDim() u32 {
        const bi = @import("builtin");
        if (std.c.getenv("LOOKOUT_MAXDIM")) |m| {
            if (std.fmt.parseInt(u32, std.mem.sliceTo(m, 0), 10) catch null) |v| return v;
        }
        return if (bi.os.tag == .ios or bi.os.tag == .tvos) 8192 else 16384;
    }

    /// A PNG's declared size, straight out of the IHDR. The whole sheet does
    /// not have to be decoded to find out whether the device will take it —
    /// charttable decodes it if we accept it.
    fn pngSize(bytes: []const u8) ?[2]u32 {
        if (bytes.len < 24) return null;
        const w = std.mem.readInt(u32, bytes[16..20], .big);
        const h = std.mem.readInt(u32, bytes[20..24], .big);
        if (w == 0 or h == 0) return null;
        return .{ w, h };
    }

    // The S-52 sprite sheet for the mariner's scheme: from the app cache if
    // present, else baked at the display density and cached. The cache key
    // carries the density (a Retina 2x bake differs from 1x) AND the palette
    // (the artwork is coloured), so each scheme keeps its own sheet and a
    // scheme change re-reads rather than re-bakes.
    fn loadSpriteSheet(self: *Lookout, density: f32) void {
        const scheme = self.mariner.scheme;
        // Claimed before the work, not after it: a bake that fails must not be
        // retried on every frame that follows.
        self.sprite_scheme = scheme;
        self.sprite_density = density;
        // "sprite-mln-", not "sprite-": the GPU-path atlas cached under
        // `sprite-<scheme>@<density>` is baked at 8 px/mm, this sheet at 2.83.
        // Sharing the key draws every symbol 2.8x too large.
        var keybuf: [40]u8 = undefined;
        const key = std.fmt.bufPrint(&keybuf, "sprite-mln-{s}@{d:.2}", .{ schemeName(scheme), density }) catch "sprite-mln-day@x";
        var pn: [40]u8 = undefined;
        var jn: [40]u8 = undefined;
        var sn: [40]u8 = undefined;
        const png_name = std.fmt.bufPrint(&pn, "{s}.png", .{key}) catch return;
        const json_name = std.fmt.bufPrint(&jn, "{s}.json", .{key}) catch return;
        const scale_name = std.fmt.bufPrint(&sn, "{s}.scale", .{key}) catch return;

        if (self.readCache(png_name)) |png_b| {
            defer self.alloc.free(png_b);
            if (self.readCache(json_name)) |json| {
                defer self.alloc.free(json);
                var scale: f32 = density;
                if (self.readCache(scale_name)) |sb| {
                    defer self.alloc.free(sb);
                    scale = std.fmt.parseFloat(f32, std.mem.trim(u8, sb, " \n\r\t")) catch scale;
                }
                const size = pngSize(png_b) orelse [2]u32{ 0, 0 };
                if (@max(size[0], size[1]) <= spriteMaxDim() and
                    self.ct.setSprite(json, png_b, scale, scheme))
                {
                    self.sprite_density = scale;
                    std.debug.print("sprite sheet {s} @ {d:.2}x (cache)\n", .{ schemeName(scheme), scale });
                    return;
                }
            }
        }
        self.bakeAndCacheSprite(scheme, density, png_name, json_name, scale_name);
    }

    // Bake the sheet at the display density, hand it over, and write it to the
    // app cache so later opens skip the (slow) rasterize. iOS cannot take the
    // full-density result as one texture, so shrink the bake scale until it
    // fits spriteMaxDim() and remember which scale that was.
    fn bakeAndCacheSprite(self: *Lookout, scheme: Scheme, density: f32, png_name: []const u8, json_name: []const u8, scale_name: []const u8) void {
        const max_dim: u32 = spriteMaxDim();
        var scale: f32 = density;
        var attempts: u8 = 0;
        while (attempts < 4) : (attempts += 1) {
            var assets: cc.tile57_assets = std.mem.zeroes(cc.tile57_assets);
            var err: cc.tile57_error = undefined;
            if (cc.tile57_bake_sprite_mln(null, @floatCast(scale), scheme, &assets, &err) != cc.TILE57_OK) return;
            defer cc.tile57_assets_free(&assets);
            if (assets.sprite_png == null or assets.sprite_json == null) return;
            const png_bytes = assets.sprite_png[0..assets.sprite_png_len];
            const json = assets.sprite_json[0..assets.sprite_json_len];
            const size = pngSize(png_bytes) orelse return;
            const largest = @max(size[0], size[1]);
            if (largest > max_dim) {
                const fit = @as(f32, @floatFromInt(max_dim)) / @as(f32, @floatFromInt(largest));
                scale = @max(1.0, scale * fit * 0.98); // 2% slack for packer variance
                std.debug.print("sprite sheet {d}x{d} exceeds max texture {d}; rebaking at {d:.2}x\n", .{ size[0], size[1], max_dim, scale });
                continue;
            }
            if (!self.ct.setSprite(json, png_bytes, scale, scheme)) return;
            self.sprite_density = scale;
            std.debug.print("sprite sheet: {s} {d}x{d} @ {d:.2}x (baked)\n", .{ schemeName(scheme), size[0], size[1], scale });
            self.writeCache(png_name, png_bytes);
            self.writeCache(json_name, json);
            var sbuf: [16]u8 = undefined;
            if (std.fmt.bufPrint(&sbuf, "{d:.4}", .{scale})) |s| self.writeCache(scale_name, s) else |_| {}
            return;
        }
    }

    /// Open every path, in parallel. A real library is thousands of cells and
    /// each open is an openat + stat + mmap and a metadata/coverage decode —
    /// mostly waiting on the filesystem (charts usually sit on Android's
    /// FUSE-backed storage), so serially this dominates the whole open.
    /// Charts land in their path's slot, so the composed order is the caller's
    /// regardless of which worker got there first.
    fn openChartPaths(self: *Lookout, paths: []const [:0]const u8) void {
        if (paths.len <= 1) {
            for (paths) |p| self.addChartPath(p);
            return;
        }
        const slots = self.alloc.alloc(?*cc.tile57_chart, paths.len) catch {
            for (paths) |p| self.addChartPath(p); // no room for the slots: serial
            return;
        };
        defer self.alloc.free(slots);
        @memset(slots, null);

        const W = struct {
            fn run(ps: []const [:0]const u8, out: []?*cc.tile57_chart, next: *std.atomic.Value(usize)) void {
                while (true) {
                    const i = next.fetchAdd(1, .monotonic); // claim, don't partition: cells vary in size
                    if (i >= ps.len) return;
                    var err: cc.tile57_error = undefined;
                    var chart: ?*cc.tile57_chart = null;
                    if (cc.tile57_chart_open(ps[i].ptr, &chart, &err) == cc.TILE57_OK) out[i] = chart;
                }
            }
        };

        var next = std.atomic.Value(usize).init(0);
        const cpus = std.Thread.getCpuCount() catch 1;
        var threads: [8]std.Thread = undefined;
        const want = @min(@max(cpus, 1), threads.len + 1) - 1; // this thread works too
        var spawned: usize = 0;
        while (spawned < want) : (spawned += 1) {
            threads[spawned] = std.Thread.spawn(.{}, W.run, .{ paths, slots, &next }) catch break;
        }
        W.run(paths, slots, &next);
        for (threads[0..spawned]) |t| t.join();

        for (slots, paths) |c, p| {
            if (c) |ch| {
                self.charts.append(self.alloc, ch) catch {};
                self.noteChartDir(p);
            } else std.debug.print("skip '{s}'\n", .{p});
        }
    }

    /// Add baked charts to the open library and compose again.
    ///
    /// Answers how many opened. A chart that does not open is skipped, as at
    /// open. The composition is rebuilt on a worker, so the chart on screen
    /// keeps drawing from the old one until the new one lands: charts arriving
    /// must never blank the display of the charts already there.
    pub fn chartsAdd(self: *Lookout, paths: []const [:0]const u8) usize {
        if (paths.len == 0) return 0;
        // A build already running was started without these charts. Take it
        // first, then start one that has them.
        self.pollCompose(true);
        // Under the engine lock: a build worker reads `charts` on its own
        // thread, and appending can reallocate the list out from under it.
        self.engine_mu.lock();
        const before = self.charts.items.len;
        self.openChartPaths(paths);
        const added = self.charts.items.len - before;
        self.engine_mu.unlock();
        if (added == 0) return 0;

        // NOT `loading`. That flag means there is nothing to draw yet, and it
        // frees the scene and paints the loader pulse over the window. The
        // charts already open are still drawable, and a mariner adding charts
        // must not lose the chart under the boat while the rest arrive.
        self.compose_prev = self.compose;
        self.recomposing = true;
        self.compose_done.store(false, .release);
        self.compose_result = null;
        self.compose_thread = std.Thread.spawn(.{}, composeWorker, .{self}) catch blk: {
            self.composeWorker();
            break :blk null;
        };
        self.pollCompose(self.compose_thread == null);
        return added;
    }

    fn addChartPath(self: *Lookout, path: [:0]const u8) void {
        var err: cc.tile57_error = undefined;
        var chart: ?*cc.tile57_chart = null;
        if (cc.tile57_chart_open(path.ptr, &chart, &err) != cc.TILE57_OK or chart == null) {
            std.debug.print("skip '{s}': {s}\n", .{ path, @as([*:0]const u8, @ptrCast(&err.message)) });
            return;
        }
        self.charts.append(self.alloc, chart.?) catch {};
        self.noteChartDir(path);
    }

    /// The archive path of the chart at `i`, as it was opened.
    fn chartPath(self: *Lookout, i: usize) ?[:0]const u8 {
        if (i >= self.chart_paths.items.len) return null;
        return self.chart_paths.items[i];
    }

    /// Record cell name -> directory for one opened archive, and keep the path
    /// itself: a single-chart open binds that archive to the renderer.
    fn noteChartDir(self: *Lookout, path: []const u8) void {
        if (self.alloc.dupeZ(u8, path)) |owned| {
            self.chart_paths.append(self.alloc, owned) catch self.alloc.free(owned);
        } else |_| {}
        const base = std.fs.path.basename(path);
        const stem = std.fs.path.stem(base);
        const dir = std.fs.path.dirname(path) orelse ".";
        if (self.chart_dirs.contains(stem)) return;
        const k = self.alloc.dupe(u8, stem) catch return;
        const v = self.alloc.dupe(u8, dir) catch {
            self.alloc.free(k);
            return;
        };
        self.chart_dirs.put(self.alloc, k, v) catch {
            self.alloc.free(k);
            self.alloc.free(v);
        };
    }

    /// The bytes and MIME type of a file a feature of `cell` references, or null
    /// when the chart carries no such file. The bytes belong to the aux handle
    /// and stay valid until close.
    pub fn auxFile(self: *Lookout, cell: []const u8, name: []const u8) ?struct { bytes: []const u8, mime: [*:0]const u8 } {
        const handle = self.auxHandle(cell) orelse return null;
        var buf: [512]u8 = undefined;
        if (name.len >= buf.len) return null;
        @memcpy(buf[0..name.len], name);
        buf[name.len] = 0;
        var bytes: [*c]const u8 = null;
        var len: usize = 0;
        var mime: [*c]const u8 = null;
        var err: cc.tile57_error = undefined;
        if (cc.tile57_aux_get(handle, @ptrCast(&buf), &bytes, &len, &mime, &err) != cc.TILE57_OK) return null;
        if (bytes == null or len == 0) return null;
        return .{
            .bytes = bytes[0..len],
            .mime = if (mime != null) @ptrCast(mime) else "application/octet-stream",
        };
    }

    /// The aux handle for a cell, opened on the first ask. A cell with no files
    /// caches a null so the miss costs one lookup.
    fn auxHandle(self: *Lookout, cell: []const u8) ?*cc.tile57_aux {
        if (self.aux.get(cell)) |cached| return cached;
        const dir = self.chart_dirs.get(cell) orelse return null;
        var buf: [1024]u8 = undefined;
        if (dir.len >= buf.len) return null;
        @memcpy(buf[0..dir.len], dir);
        buf[dir.len] = 0;
        var handle: ?*cc.tile57_aux = null;
        var err: cc.tile57_error = undefined;
        _ = cc.tile57_aux_open(@ptrCast(&buf), &handle, &err);
        const k = self.alloc.dupe(u8, cell) catch return handle;
        self.aux.put(self.alloc, k, handle) catch self.alloc.free(k);
        return handle;
    }
    fn finishOpen(self: *Lookout) !void {
        // A library of raster charts alone is a library. A mariner whose water
        // the ENC covers badly may carry only photographs of it, and the app
        // has to open for them. There is no vector scene in that state: the
        // raster layer draws and the chart layer has nothing to say. The host
        // adds the pictures after the open, so an empty set is not an error.
        if (self.charts.items.len == 0) {
            self.raster_only = true;
            return;
        }
        // Set an immediate view + zoom clamps from the FIRST cell — no compositor
        // needed — so the window can render right away.
        self.applyZoomAndView();
        // What the renderer draws from. ONE chart binds straight to its archive
        // and never touches the compositor: charttable reads pmtiles itself, so
        // the whole tile path for a single cell is inside it. A library goes
        // through tile57's compositor below, once the partition is built.
        self.refreshScamin();
        if (self.charts.items.len == 1) {
            if (self.chartPath(0)) |p| {
                self.ct.bindChart(p) catch |e| {
                    std.debug.print("chart source: {s}\n", .{@errorName(e)});
                };
            }
        }
        // Compose over the whole library (the slow ownership-partition build) on a
        // worker thread; the window shows a loader until it lands (see tick).
        if (self.charts.items.len > 1) {
            self.loading = true;
            self.compose_done.store(false, .release);
            self.compose_thread = std.Thread.spawn(.{}, composeWorker, .{self}) catch blk: {
                self.composeWorker(); // fallback: synchronous
                break :blk null;
            };
            self.pollCompose(self.compose_thread == null); // apply immediately if it ran sync
        }
        // LOOKOUT_PLUGINS is the prototype's whole install story: point it at a
        // directory of modules and they run. A shell that wants control calls
        // lookout_plugins_load instead and leaves the variable unset.
        if (plugins_on) {
            if (std.c.getenv("LOOKOUT_PLUGINS")) |dir| {
                const path = std.mem.span(dir);
                self.loadPlugins(path) catch |e| {
                    std.debug.print("plugins: LOOKOUT_PLUGINS={s} not loaded: {s}\n", .{ path, @errorName(e) });
                };
            }
        }
    }

    // ---- plugins ------------------------------------------------------------

    /// Load and start the wasm plugins in `dir` — every `<id>.manifest.json`
    /// with an `<id>.wasm` beside it, which is what `zig build plugins`
    /// installs. The plugin layer is created on the first call.
    pub fn loadPlugins(self: *Lookout, dir: []const u8) !void {
        if (plugins_on) {
            const ps = self.plugins orelse blk: {
                const created = try PluginSystem.create(self.alloc, &self.overlay);
                self.plugins = created;
                break :blk created;
            };
            try ps.host.loadDir(dir);
            try ps.host.start();
            self.markDirty();
        } else return error.PluginsUnavailable;
    }

    /// The overlay store's view of the renderer's glyph atlas: one metrics
    /// lookup, in the EM units the store lays out in. charttable keeps the
    /// same metrics in PIXELS at the sheet's em size, so the conversion is one
    /// divide — and `top` is y-up there against the store's y-down.
    const GlyphFace = struct {
        atlas: *const ctglyphs.GlyphAtlas,
        em_px: f32,
    };

    fn overlayGlyphLookup(ctx: *const anyopaque, cp: u21) ?ov.Glyph {
        const face: *const GlyphFace = @ptrCast(@alignCast(ctx));
        const g = face.atlas.get(cp) orelse return null;
        const s: f32 = if (face.em_px > 0) 1.0 / face.em_px else 0;
        return .{
            .u0 = g.u0,
            .v0 = g.v0,
            .u1 = g.u1,
            .v1 = g.v1,
            .off_x = g.left * s,
            .off_y = -g.top * s,
            .w = g.w * s,
            .h = g.h * s,
            .advance = g.advance * s,
        };
    }

    /// The overlay palette scheme that matches the chart's.
    fn overlayScheme(self: *Lookout) ov.Scheme {
        return switch (self.mariner.scheme) {
            cc.TILE57_SCHEME_NIGHT => .night,
            cc.TILE57_SCHEME_DUSK => .dusk,
            else => .day,
        };
    }

    /// Rebuild the chart overlay for this frame's zoom and scheme and hand it
    /// to the GPU layer. Cheap when nothing changed: the store returns the same
    /// generation and the backend skips the upload.
    fn updateOverlay(self: *Lookout) void {
        // Own ship's display position, the camera lock and the overlay all
        // ride this tick: the stores are current here and the frame's MVP is
        // built after it, so a move shows in this frame.
        self.tickShip();
        self.followTick();
        // The marks carry RGBA, so a scheme change re-posts them. Comparing
        // here rather than hooking every route into setMariner: there are
        // several, and one that forgot would leave a day-bright magenta on a
        // night chart.
        if (self.markers_scheme != self.overlayScheme()) self.postMarkers();
        // Hand the store the glyph face, so canvas text lays out against the
        // same atlas the labels draw with. Idempotent: only a change marks the
        // store dirty. One face for both slots — the renderer holds a single
        // atlas, so bold canvas text draws in the regular face (concerns C4).
        if (self.ct.glyph_atlas != null) {
            self.glyph_face = .{ .atlas = &self.ct.glyph_atlas.?, .em_px = self.glyph_em_px };
            const src = ov.Font{ .ctx = @ptrCast(&self.glyph_face), .lookup = overlayGlyphLookup };
            self.overlay.setFonts(src, src);
        }
        // The view rotation goes in because a canvas may hold a readout level
        // on screen; the store ignores it unless one does.
        const frame = self.overlay.buildIfNeeded(self.cam.zoom, self.cam.rotation, self.overlayScheme(), self.ship_at) catch |e| {
            std.debug.print("overlay build failed: {s}\n", .{@errorName(e)});
            return;
        };
        // The overlay pass draws from the frame's OWN origin. Its vertices are
        // relative to it, so the MVP and the antimeridian wrap must be too.
        // The camera does not move between here and this frame's draw.
        var u = self.ct.m.uniforms();
        u.mvp = self.cam.mvpOrigin(frame.origin);
        u.wrap_x = @floatCast(camera.wrapDx(self.cam.center.x, frame.origin.x));
        // The store's vertex and the renderer's overlay vertex are the same
        // 24 bytes in the same order — asserted, because a silent skew here
        // would draw the mariner's marks as noise rather than fail.
        comptime std.debug.assert(@sizeOf(ov.Vertex) == @sizeOf(ctscene.OverlayVertex));
        const verts: []const ctscene.OverlayVertex = @ptrCast(frame.verts);
        self.ct.setOverlay(verts, frame.generation, u) catch |e| {
            std.debug.print("overlay upload failed: {s}\n", .{@errorName(e)});
        };
    }

    /// True when something has posted geometry the current frame does not
    /// show. The app renders ON DEMAND, so without this a symbol drawn while
    /// the chart sat idle would not appear until the mariner touched the
    /// screen. The same reason raster.wantsFrame exists.
    fn overlayWantsFrame(self: *Lookout) bool {
        if (self.markers_scheme != self.overlayScheme()) return true;
        return self.overlay.needsRebuild(self.cam.zoom, self.cam.rotation, self.overlayScheme(), self.ship_at);
    }

    /// True once a plugin layer is up. A shell asks so it can keep polling
    /// `needsRedraw` while it would otherwise sleep: plugin geometry arrives
    /// with no gesture behind it, and a render-on-demand loop that only wakes
    /// on input never shows it.
    pub fn pluginsActive(self: *Lookout) bool {
        if (!plugins_on) return false;
        return self.plugins != null;
    }

    /// What the overlay symbol nearest `x_pt`,`y_pt` says about itself, or
    /// null. Logical points, the same unit as every other pointer entry point.
    /// Borrowed: valid until the next call.
    pub fn overlayAt(self: *Lookout, x_pt: f32, y_pt: f32) ?[]const u8 {
        return self.overlay.pickAt(self.cam.*, x_pt, y_pt, self.ship_at);
    }

    /// The overlay symbol nearest a logical point, with its id and the anchor
    /// it draws at. A shell pins a bubble to the id and asks `overlayInfo` for
    /// it every frame. Borrowed until the next overlay query.
    pub fn overlayHit(self: *Lookout, x_pt: f32, y_pt: f32) ?ov.Store.Hit {
        return self.overlay.hitAt(self.cam.*, x_pt, y_pt, self.ship_at);
    }

    /// What that object says now, or null once it is gone.
    pub fn overlayInfo(self: *Lookout, id: []const u8) ?ov.Store.Hit {
        return self.overlay.infoFor(id, self.ship_at);
    }

    /// Every loaded plugin with its settings schema and current values, as
    /// JSON. This is what a shell renders a settings pane from. Borrowed until
    /// the next call; null when no plugin layer is up.
    pub fn pluginsJson(self: *Lookout) ?[]const u8 {
        if (!plugins_on) return null;
        const ps = self.plugins orelse return null;
        ps.json.clearRetainingCapacity();
        ps.host.registryJson(&ps.json) catch return null;
        return ps.json.items;
    }

    /// One plugin's settings, as JSON. Borrowed until the next call.
    pub fn pluginConfig(self: *Lookout, id: []const u8) ?[]const u8 {
        if (!plugins_on) return null;
        const ps = self.plugins orelse return null;
        ps.json.clearRetainingCapacity();
        ps.host.configJson(id, &ps.json) catch return null;
        return ps.json.items;
    }

    /// Change one plugin's settings. Keys the schema does not declare are
    /// ignored; the plugin hears the whole config at once and applies it.
    pub fn setPluginConfig(self: *Lookout, id: []const u8, json: []const u8) !void {
        if (!plugins_on) return error.PluginsUnavailable;
        const ps = self.plugins orelse return error.PluginsUnavailable;
        try ps.host.configSet(id, json);
    }

    /// Offer a file the mariner opened to the plugins. True when one claimed
    /// the file type and now has read access to it.
    ///
    /// False means no plugin wants it, and the shell should do what it did
    /// before there were plugins — which is also what a build with no plugin
    /// layer answers, so a shell needs no second code path for one.
    pub fn openFileForPlugins(self: *Lookout, path: []const u8) !bool {
        if (!plugins_on) return false;
        const ps = self.plugins orelse return false;
        return ps.host.openFile(path);
    }

    // ---- markers ------------------------------------------------------------
    //
    // The core owns them so every shell shows the same marks and they survive
    // a restart. They draw through the overlay store, as canvases: the store
    // already carries geometry over the chart, keeps it across zoom and scheme
    // changes, and holds a canvas level on the display when the mariner turns
    // the chart. Nothing new reaches the GPU layer for this.
    //
    // The colour is S-52's mariner magenta, the colour reserved for the
    // mariner's own additions and the one the pick mark already uses. Posted
    // as RGBA rather than a palette token because the token list is the
    // PLUGIN vocabulary; a core drawing has no business growing it.

    /// The overlay source the marks are posted under. Namespaced like a plugin
    /// id, in a namespace no plugin can claim.
    const marker_source = "lookout.markers";

    /// How near a logical point must be to a mark for `markerAt` to answer it.
    /// The same reach the overlay gives a plugin symbol.
    const marker_pick_radius_pt: f64 = 14.0;

    /// Mariner magenta per palette. Day is the pick mark's own #DB198C; night
    /// is held dim, like every other night colour, so a mark does not undo a
    /// night-adapted eye.
    fn markerRgba(scheme: ov.Scheme) [4]f64 {
        return switch (scheme) {
            .day => .{ 0.858, 0.098, 0.549, 1.0 },
            .dusk => .{ 0.910, 0.435, 0.706, 1.0 },
            .night => .{ 0.557, 0.102, 0.314, 1.0 },
        };
    }

    /// Re-post every mark as an overlay canvas. Called on any change and on a
    /// scheme change; a handful of objects, so the whole set goes at once
    /// rather than tracking deltas.
    fn postMarkers(self: *Lookout) void {
        const scheme = self.overlayScheme();
        self.markers_scheme = scheme;
        self.overlay.removeSource(marker_source);
        const list = self.markers.items();
        if (list.len == 0) return;

        const c = markerRgba(scheme);
        var json = std.ArrayList(u8).empty;
        defer json.deinit(self.alloc);
        markerBatch(self.alloc, &json, list, c) catch |e| {
            std.debug.print("markers: batch not built: {s}\n", .{@errorName(e)});
            return;
        };
        self.overlay.applyBatch(marker_source, json.items) catch |e| {
            std.debug.print("markers: batch refused: {s}\n", .{@errorName(e)});
        };
    }

    /// Drop a marker at a geographic point and name it at once. Returns its
    /// id, or 0 when nothing could be stored.
    pub fn markerAdd(self: *Lookout, lon: f64, lat: f64) u64 {
        const now: i64 = clock.wallMs();
        const id = self.markers.add(lon, lat, now);
        if (id != 0) self.postMarkers();
        return id;
    }

    /// Rename one marker. An empty name keeps the old one.
    pub fn markerRename(self: *Lookout, id: u64, name: []const u8) bool {
        if (!self.markers.rename(id, name)) return false;
        self.postMarkers();
        return true;
    }

    pub fn markerRemove(self: *Lookout, id: u64) bool {
        if (!self.markers.remove(id)) return false;
        self.postMarkers();
        return true;
    }

    pub fn markerCount(self: *const Lookout) usize {
        return self.markers.items().len;
    }

    pub fn markerAtIndex(self: *const Lookout, i: usize) ?*const marks.Marker {
        const list = self.markers.items();
        if (i >= list.len) return null;
        return &list[i];
    }

    pub fn markerById(self: *const Lookout, id: u64) ?*const marks.Marker {
        return self.markers.find(id);
    }

    /// The marker nearest a LOGICAL point, or null when none is within reach.
    /// Projected with the renderer's own camera, so rotation and the
    /// antimeridian hold. The nearest wins, and a tie keeps the older mark.
    pub fn markerAt(self: *Lookout, x_pt: f32, y_pt: f32) ?*const marks.Marker {
        var best: ?*const marks.Marker = null;
        var best_d2: f64 = marker_pick_radius_pt * marker_pick_radius_pt;
        for (self.markers.items()) |*m| {
            const s = self.cam.worldToScreen(camera.lonLatToWorld(m.lon, m.lat));
            const dx = s.x - @as(f64, x_pt);
            const dy = s.y - @as(f64, y_pt);
            const d2 = dx * dx + dy * dy;
            if (d2 < best_d2) {
                best_d2 = d2;
                best = m;
            }
        }
        return best;
    }

    // ---- own ship's position ------------------------------------------------

    /// What the position readout may say. A stale fix is never presented as a
    /// live one, which is why `lost` exists: "the fix dropped" and "you never
    /// set one up" are different problems and want different answers from the
    /// mariner.
    pub const FixState = enum(c_int) { none = 0, lost = 1, live = 2 };

    /// Own ship's REPORTED position, and how much to believe it. `out` is
    /// written only for `live`.
    ///
    /// The reported fix, not the display position: the display position is
    /// carried forward along COG between fixes so the boat symbol moves
    /// smoothly, and a dead-reckoned number must never be shown as a reported value.
    /// The vessel store's own staleness is what decides; nothing here keeps a
    /// second clock.
    pub fn ownShip(self: *Lookout, out: *[2]f64) FixState {
        if (!plugins_on) return .none;
        const ps = self.plugins orelse return .none;
        const r = ps.vessels.readElected("navigation.position", phost.broker.wallMs()) orelse return .none;
        if (r.stale or r.value != .position) return .lost;
        out.* = .{ r.value.position.lon, r.value.position.lat };
        return .live;
    }

    // ---- follow mode --------------------------------------------------------

    /// Read the vessel store and recompute own ship's display position. Called
    /// on the frame tick and by the queries a shell polls, so an answer between
    /// frames is still current.
    fn tickShip(self: *Lookout) void {
        if (plugins_on) {
            const ps = self.plugins orelse return;
            const now = phost.broker.wallMs();
            self.ship.observe(PluginSystem.readShip(&ps.vessels, now));
            self.ship_at = self.ship.at(now);
        }
    }

    /// The display position as a world point, for the camera.
    fn shipWorld(self: *Lookout) ?camera.Vec2 {
        const p = self.ship_at orelse return null;
        return camera.lonLatToWorld(p[0], p[1]);
    }

    /// Turn follow mode on or off. Turning it on moves the chart at once when
    /// a fresh fix exists; with none, follow waits armed and the camera holds.
    pub fn setFollow(self: *Lookout, on: bool) void {
        if (!on) return self.follow.clear();
        self.follow.on = true;
        self.follow.applied = null;
        self.tickShip();
        self.followTick();
    }

    /// Turn course-up on or off. On, the chart turns so own ship's heading
    /// points up the screen and keeps turning with it.
    pub fn setCourseUp(self: *Lookout, on: bool) void {
        self.follow.course_up = on;
        if (on) {
            self.tickShip();
            self.followTick();
        }
    }

    /// What the shell's lock control shows: off, following a fresh fix, or on
    /// and waiting for one.
    pub fn followState(self: *Lookout) FollowState {
        if (!self.follow.on) return .off;
        self.tickShip();
        return if (self.ship_at != null) .following else .waiting;
    }

    /// The same three states for the course-up control.
    pub fn courseUpState(self: *Lookout) FollowState {
        if (!self.follow.course_up) return .off;
        self.tickShip();
        return if (self.ship.upDeg() != null) .following else .waiting;
    }

    /// Hold own ship on the anchor and, with course-up on, the chart on its
    /// heading. The display position moves every frame, so this runs every
    /// frame; when nothing moved it costs one comparison.
    fn followTick(self: *Lookout) void {
        var moved = self.follow.rotate(self.cam, self.ship.upDeg());
        if (self.follow.apply(self.cam, self.shipWorld())) moved = true;
        if (moved) self.markDirty();
    }

    /// True when the camera has a move to make from the boat rather than from
    /// a gesture: a display position that has walked on, or a new heading
    /// under course-up.
    fn followWantsFrame(self: *Lookout) bool {
        if (!self.follow.on and !self.follow.course_up) return false;
        self.tickShip();
        if (self.follow.rotatePending(self.cam.*, self.ship.upDeg())) return true;
        return self.follow.pending(self.cam.*, self.shipWorld());
    }

    fn composeWorker(self: *Lookout) void {
        var err: cc.tile57_error = undefined;
        var c: ?*cc.tile57_compose = null;
        // No partition path: the engine finds the sidecar its own bake wrote next
        // to the archives, and builds one in memory if there is none. Where that
        // file lives, and whether it is reusable, is the engine's business.
        if (cc.tile57_compose_open(self.charts.items.ptr, self.charts.items.len, &c, &err) == cc.TILE57_OK and c != null) {
            // charttable follows the style spec's 512 px world tile, while
            // S-101 lays its linestyle figures out in 256-px-per-tile space.
            // The composed tiles' linestyle rhythms are restated in ours. The
            // same seam ct/host.zig's toCt converts.
            cc.tile57_compose_set_px_per_tile(c, 512);
            self.compose_result = c;
        } else {
            std.debug.print("compose_open failed: {s}\n", .{@as([*:0]const u8, @ptrCast(&err.message))});
        }
        self.compose_done.store(true, .release);
    }

    // Adopt the composed set once its partition build finishes. `block` waits.
    fn pollCompose(self: *Lookout, block: bool) void {
        if (!self.loading and !self.recomposing) return;
        if (!block and !self.compose_done.load(.acquire)) return;
        if (self.compose_thread) |t| {
            t.join();
            self.compose_thread = null;
        }
        self.loading = false;
        self.recomposing = false;
        if (self.compose_result) |c| {
            // The engine lock, not the API lock. A build worker reads
            // `compose` on its own thread and holds this lock while tile57
            // walks it, so the swap and the close of the old one belong
            // inside it. Closing outside it frees a composition a worker is
            // in the middle of reading.
            self.engine_mu.lock();
            self.compose = c;
            const replaced = self.compose_prev;
            self.compose_prev = null;
            if (replaced) |old| cc.tile57_compose_close(old);
            self.engine_mu.unlock();

            self.zl_valid = false; // new partition — the cached per-view max is stale
            self.updateZoomLimits(); // refresh the zoom band; DON'T touch the view
            std.debug.print("composed {d} charts\n", .{self.charts.items.len});
            // The tiles on screen came from the old composition, so they hold
            // none of the charts just added. Point the tile workers at the new
            // one: the charts that were already there re-compose identically,
            // and the new ones fill in as their tiles land.
            //
            // The compositor serves RAW MLT, whatever the archives underneath
            // it hold, so the source's encoding is fixed at the seam.
            self.ct.bindComposed(c, .mlt) catch |e| {
                std.debug.print("chart source: {s}\n", .{@errorName(e)});
            };
            self.refreshScamin();
            if (replaced != null) self.style_dirty = true;
        }
        // The loader animated self.g.clear to a dark pulse (see render()); now that
        // we're drawing the chart again, re-derive the live state so the clear goes
        // back to the scheme's NODATA. Without this the composed view keeps the last
        // dark pulse colour as its background.
        self.deriveLive();
    }

    // Zoom-out floor: never coarser than z4 (nor below the coarsest band's data).
    // Zoom-in cap: the deepest SERVED zoom (compose_meta.max_zoom) — already native
    // + one fill-up overscale level. buildZoom clamps the scene to this, so letting
    // cam.zoom run past it only MVP-magnifies that scene into nodata-ish blur; cap
    // exactly there so cam.zoom == buildZoom at the limit and the chart stays crisp.
    /// All of these are in the RENDERER's zoom convention, because that is what
    /// they are compared against: a chart's declared min/max are tile levels,
    /// and a tile level is a charttable zoom.
    const MIN_ZOOM_FLOOR = 4.0;
    fn updateZoomLimits(self: *Lookout) void {
        const zr = self.zoomRange();
        self.engine_max_zoom = zr[1];
        self.cam.min_zoom = @max(MIN_ZOOM_FLOOR, zr[0]);
        // Per-view cap: the deepest zoom the chart UNDER THE VIEW CENTRE can serve.
        // Over a coarse-only area every covering cell's reach is low, so the
        // library-wide max (zr[1], set by a distant deep chart) would zoom straight
        // into nodata; this caps at what's actually there.
        // Allow zooming PAST the deepest data by a bounded margin: the scene
        // stays built at the data's max zoom and the MVP magnifies it (same
        // path as a pinch between rebuilds), with the HUD showing an overscale
        // badge (lookout_overscale). S-52 permits overscale WITH indication.
        const cap = self.viewMaxZoom();
        self.cam.max_zoom = cap + OVERSCALE_ALLOW;
        // ZOOMING is capped at the data plus the overscale allowance, above.
        // PANNING is not, up to a far looser ceiling.
        //
        // This ran unconditionally, so crossing into a coarser area changed the
        // zoom under a mariner who had not asked for it: throw the chart and
        // the scale moves. The point of the cap is to stop them ending up
        // magnifying nothing, and the overscale badge already says when they
        // are past the survey, so panning may leave the scale alone until the
        // magnification is genuinely useless.
        self.cam.target_zoom = std.math.clamp(
            self.cam.target_zoom,
            self.cam.min_zoom,
            @max(self.cam.max_zoom, cap + PAN_OVERSCALE_ALLOW),
        );
    }

    /// Deepest servable zoom at the current view centre (tile57_compose_max_zoom_at),
    /// falling back to the library max for a single chart or an off-coverage point.
    /// CACHED by view position: updateZoomLimits runs every frame, and the
    /// engine query walks the partition — it measured 14% of active CPU in a
    /// gesture profile. Recomputed after ~32 screen px of pan or half a zoom
    /// level; compose adoption invalidates (zl_valid).
    fn viewMaxZoom(self: *Lookout) f64 {
        const c = self.compose orelse return self.zoomRange()[1];
        const thresh = 32.0 / (std.math.exp2(self.cam.zoom) * 512.0);
        if (self.zl_valid and
            @abs(self.cam.center.x - self.zl_center.x) <= thresh and
            @abs(self.cam.center.y - self.zl_center.y) <= thresh and
            @abs(self.cam.zoom - self.zl_zoom) <= 0.5)
            return self.zl_max;
        const ll = camera.worldToLonLat(self.cam.center);
        const mz = cc.tile57_compose_max_zoom_at(c, ll.x, ll.y);
        self.zl_max = if (mz > 0) @floatFromInt(mz) else self.zoomRange()[1];
        self.zl_center = self.cam.center;
        self.zl_zoom = self.cam.zoom;
        self.zl_valid = true;
        return self.zl_max;
    }

    fn applyZoomAndView(self: *Lookout) void {
        const v = self.fitChart();
        const lw, const lh = self.logicalSize();
        self.ct.m.setViewport(lw, lh);
        // The band before the pose: setView clamps into it, and a view fitted
        // to a cell outside the old band would be pulled back otherwise.
        self.updateZoomLimits();
        self.setView(v);
        self.deriveLive();
    }

    /// Re-read the library's SCAMIN denominators and rebuild the style with
    /// them. The manifest decides how the style's `_scamin` layers are split,
    /// so charts arriving with new denominators need a fresh style, not just a
    /// fresh composition.
    fn refreshScamin(self: *Lookout) void {
        if (self.scamin.len != 0) self.alloc.free(self.scamin);
        self.scamin = cstyle.collectScamin(self.alloc, self.charts.items);
        self.style_dirty = true;
    }

    fn zoomRange(self: *Lookout) [2]f64 {
        // The pictures decide the range when there is no survey to ask.
        if (self.charts.items.len == 0) return .{ 2, 19 };
        if (self.compose) |c| {
            var m: cc.tile57_compose_meta = undefined;
            cc.tile57_compose_get_meta(c, &m);
            return .{ @floatFromInt(m.min_zoom), @floatFromInt(m.max_zoom) };
        }
        var info: cc.tile57_info = undefined;
        cc.tile57_chart_get_info(self.charts.items[0], &info);
        return .{ @floatFromInt(info.min_zoom), @floatFromInt(info.max_zoom) };
    }

    pub fn close(self: *Lookout) void {
        // FIRST: the plugin threads draw into the overlay store and read the
        // GPU layer's frame through it, so they have to be stopped before
        // anything below them is torn down.
        if (plugins_on) {
            if (self.plugins) |ps| {
                ps.destroy();
                self.plugins = null;
            }
        }
        // Now that nothing else can post into them.
        self.overlay.deinit();
        self.markers.deinit();
        self.pollCompose(true); // finish any in-flight partition build first
        // BEFORE the composition and the charts: the renderer's tile workers
        // read the compositor, and its deinit is what stops them.
        self.ct.deinit();
        if (self.assets_root) |r| self.alloc.free(r);
        if (self.alt_style) |s| self.alloc.free(s);
        if (self.scamin.len != 0) self.alloc.free(self.scamin);
        if (self.compose) |c| cc.tile57_compose_close(c); // BEFORE the charts
        for (self.charts.items) |ch| cc.tile57_chart_close(ch);
        self.charts.deinit(self.alloc);
        var aux_it = self.aux.iterator();
        while (aux_it.next()) |kv| {
            if (kv.value_ptr.*) |h| cc.tile57_aux_close(h);
            self.alloc.free(kv.key_ptr.*);
        }
        self.aux.deinit(self.alloc);
        var dir_it = self.chart_dirs.iterator();
        while (dir_it.next()) |kv| {
            self.alloc.free(kv.key_ptr.*);
            self.alloc.free(kv.value_ptr.*);
        }
        self.chart_dirs.deinit(self.alloc);
        for (self.chart_paths.items) |p| self.alloc.free(p);
        self.chart_paths.deinit(self.alloc);
        self.alloc.destroy(self);
    }

    // ---- view ---------------------------------------------------------------
    fn viewToCamera(v: View, w: f32, h: f32) camera.Camera {
        const o = camera.lonLatToWorld(v.lon, v.lat);
        return .{ .origin = o, .center = o, .zoom = v.zoom, .target_zoom = v.zoom, .rotation = v.rotation_deg * std.math.pi / 180.0, .vw = w, .vh = h };
    }

    /// A BOUNDED opening view. Deliberately ONE cell's own bounds, NOT the union
    /// of a whole library — fitting a big composite would tessellate the entire
    /// library into one gigantic scene. Pan/zoom reaches the rest.
    ///
    /// For a library we fit the MOST DETAILED cell (smallest bounds area), not
    /// the first alphabetically: a US ENC's first cell is usually a tiny-scale
    /// EEZ overview (e.g. US1EEZ1M) that opens as an empty ocean rectangle. A
    /// harbor/approach cell lands the user on actual chart content instead.
    /// The pose a host should open with when it has nothing saved. fitChart
    /// alone lands on the smallest bounded CELL, which in a 2500-cell library
    /// is an arbitrary harbor; keep that centre but pull back to an overview.
    /// Hosts persist the pose themselves (each has its own store) — this is
    /// the one piece of the policy worth having in a single place.
    const DEFAULT_VIEW_ZOOM = 5.0;
    pub fn defaultView(self: *Lookout) View {
        var v = self.fitChart();
        v.zoom = std.math.clamp(DEFAULT_VIEW_ZOOM, self.cam.min_zoom, self.cam.max_zoom);
        v.rotation_deg = 0;
        return v;
    }

    pub fn fitChart(self: *Lookout) View {
        var west: f64 = 0;
        var south: f64 = 0;
        var east: f64 = 0;
        var north: f64 = 0;
        var has_bounds = false;
        var min_zoom: u8 = 0;
        var max_zoom: u8 = 22;
        if (self.charts.items.len == 0) {
            // No survey to frame from, so the pictures decide where to look.
            // Without this a raster-only library opens wherever the camera
            // happened to start, which is nowhere near the charts.
            // No survey and no pictures to frame from (the underlay is not
            // wired to the renderer on this branch — concerns C5), so the
            // opening view is the whole world.
            return .{ .lon = 0, .lat = 0, .zoom = 2 };
        } else {
            // Pick the smallest-area bounded cell as the opening view. Falls back
            // to the first cell's anchor (or the first cell) when none is bounded.
            var best_area: f64 = std.math.floatMax(f64);
            var anchor: ?View = null;
            for (self.charts.items) |ch| {
                var info: cc.tile57_info = undefined;
                cc.tile57_chart_get_info(ch, &info);
                if (info.has_bounds) {
                    const area = @abs(info.east - info.west) * @abs(info.north - info.south);
                    if (area < best_area) {
                        best_area = area;
                        west = info.west;
                        south = info.south;
                        east = info.east;
                        north = info.north;
                        min_zoom = info.min_zoom;
                        max_zoom = info.max_zoom;
                        has_bounds = true;
                    }
                } else if (anchor == null and info.has_anchor) {
                    anchor = .{ .lon = info.anchor_lon, .lat = info.anchor_lat, .zoom = info.anchor_zoom };
                }
            }
            if (!has_bounds) {
                if (anchor) |a| return a;
            }
        }
        if (!has_bounds) return .{ .lon = 0, .lat = 0, .zoom = 2 };
        const wl = camera.lonLatToWorld(west, north);
        const wr = camera.lonLatToWorld(east, south);
        const lw, const lh = self.logicalSize();
        const vw: f64 = lw;
        const vh: f64 = lh;
        // Fitted in the RENDERER's convention (a 512 px world tile), because
        // the bounds it is clamped against are tile levels. The result crosses
        // back to the ABI's convention on the way out, once.
        const zx = std.math.log2(vw / (512.0 * @max(@abs(wr.x - wl.x), 1e-12)));
        const zy = std.math.log2(vh / (512.0 * @max(@abs(wr.y - wl.y), 1e-12)));
        var z = @min(zx, zy) - 0.15;
        z = std.math.clamp(z, @as(f64, @floatFromInt(min_zoom)), @as(f64, @floatFromInt(max_zoom)) + 1.0);
        return .{ .lon = (west + east) * 0.5, .lat = (south + north) * 0.5, .zoom = cthost.fromCt(z) };
    }

    /// Move the camera. Pan/zoom/rotate never re-tessellate; a big jump to new
    /// ground may want build() for fresh detail.
    pub fn setView(self: *Lookout, v: View) void {
        self.cam.center = camera.lonLatToWorld(v.lon, v.lat);
        self.cam.zoom = cthost.toCt(v.zoom);
        self.cam.rotation = v.rotation_deg * std.math.pi / 180.0;
        // Pin the animation target to the new pose: otherwise the zoom easer
        // still aims at the PREVIOUS target and drags the view back (about a
        // stale cursor pivot) on the next frames.
        self.cam.setTarget();
        self.cam.clampY();
        self.markDirty();
    }
    pub fn view(self: *Lookout) View {
        const ll = camera.worldToLonLat(self.cam.center);
        return .{ .lon = ll.x, .lat = ll.y, .zoom = cthost.fromCt(self.cam.zoom), .rotation_deg = self.cam.rotation * 180.0 / std.math.pi };
    }

    /// Resize the render surface (points; HiDPI density is applied internally).
    pub fn resize(self: *Lookout, width: u32, height: u32) !void {
        self.host_pt_w = @floatFromInt(width);
        self.host_pt_h = @floatFromInt(height);
        self.ct.resize(width, height);
        const lw, const lh = self.logicalSize();
        self.ct.m.setViewport(lw, lh);
        self.markDirty();
    }

    /// Give up the host's surface without closing the chart, for a shell whose
    /// window can go away while the app lives on. What goes is the GPU surface
    /// and its swapchain. What stays is everything expensive: the opened cells,
    /// the composition, the atlas bake, the CPU scene copy and the plugin layer
    /// with its alerts, so attachSurface brings the view back in milliseconds
    /// where a reopen takes seconds.
    ///
    /// Externally serialized like close: the host must have no other call in
    /// flight, and must not render again until attachSurface returns.
    pub fn detachSurface(self: *Lookout) void {
        if (!self.surface_attached) return;
        self.ct.detachSurface();
        self.surface_attached = false;
        // The next attach presents a frame even if nothing else moved.
        self.view_dirty = true;
        // Detached there is no frame to serve a trim at, and a warning that
        // frees nothing is exactly why the process gets killed next.
        self.serviceTrim();
    }

    /// Present on a new host surface after a detach. `kind` and `handle` are
    /// the pair lookout_open_in_window took; width and height are LOGICAL
    /// points, as everywhere else.
    ///
    /// Errors leave the engine detached rather than half-attached, so a host
    /// that cannot show a chart without a view can fall back to a reopen.
    pub fn attachSurface(self: *Lookout, kind: NativeKind, handle: *anyopaque, width: u32, height: u32) !void {
        if (self.surface_attached) return error.SurfaceAlreadyAttached;
        try self.ct.attachSurface(.{
            .width = width,
            .height = height,
            .want_window = false,
            .want_msaa = true,
            .native_handle = handle,
            .native_kind = kind,
        });
        self.surface_attached = true;
        // A fresh device holds no sheets: they go up again with the next frame.
        self.atlases_ready = false;
        self.sprite_scheme = null;
        // The new window is rarely the old one's size (a rotation while the app
        // was away), and the camera has to hear about it before the first frame.
        try self.resize(width, height);
    }

    /// The viewport in LOGICAL (device-independent) px — the single unit the
    /// camera, the portrayal and every mark size are expressed in. The
    /// framebuffer may be 2x that on a HiDPI display; pxToClip maps logical px
    /// across the whole framebuffer, so density is handled ONCE, in the
    /// projection, and never multiplied into a size again.
    fn logicalSize(self: *const Lookout) struct { f32, f32 } {
        if (self.host_pt_w > 0 and self.host_pt_h > 0) return .{ self.host_pt_w, self.host_pt_h };
        const d = if (self.ct.pixelDensity() > 0) self.ct.pixelDensity() else 1.0;
        return .{ @as(f32, @floatFromInt(self.ct.width())) / d, @as(f32, @floatFromInt(self.ct.height())) / d };
    }
    pub fn pixelDensity(self: *Lookout) f32 {
        return self.ct.pixelDensity();
    }

    /// Declare the host's scale factor instead of letting the backend infer it
    /// from the surface. Set before the first build.
    pub fn setPixelDensity(self: *Lookout, d: f32) void {
        // The density-baked sprite sheet must rebake on a late density change,
        // or every symbol samples upscaled. ensureAtlases notices by itself
        // (it compares the baked density), so nothing is forced here.
        self.ct.setPixelDensity(d);
    }

    // ---- interaction --------------------------------------------------------
    // Pan and zoom go through the follow controller: a pan turns follow off, a
    // zoom keeps it on and pivots on own ship.
    pub fn panPixels(self: *Lookout, dx: f32, dy: f32) void {
        self.follow.pan(self.cam, dx, dy);
        self.markDirty();
    }
    pub fn zoomAt(self: *Lookout, dzoom: f64, x_px: f32, y_px: f32) void {
        self.follow.zoomAbout(self.cam, dzoom, x_px, y_px);
        self.markDirty();
    }
    pub fn screenToGeo(self: *Lookout, x_px: f32, y_px: f32) View {
        const ll = camera.worldToLonLat(self.cam.screenToWorld(x_px, y_px));
        return .{ .lon = ll.x, .lat = ll.y, .zoom = cthost.fromCt(self.cam.zoom) };
    }
    pub fn geoToScreen(self: *Lookout, lon: f64, lat: f64) [2]f32 {
        const s = self.cam.worldToScreen(camera.lonLatToWorld(lon, lat));
        return .{ @floatCast(s.x), @floatCast(s.y) };
    }
    // Mouse coords from a HiDPI window arrive in logical points — which is the
    // camera's own unit now, so they pass straight through.
    pub fn panLogical(self: *Lookout, dx_pt: f32, dy_pt: f32) void {
        self.follow.pan(self.cam, dx_pt, dy_pt);
        self.markDirty();
    }
    pub fn zoomAtLogical(self: *Lookout, dzoom: f64, x_pt: f32, y_pt: f32) void {
        self.follow.zoomToward(self.cam, dzoom, x_pt, y_pt); // eases in tickAnim, not an instant snap
        self.markDirty();
    }

    /// Rotate the view about its centre by the angle the cursor swept from
    /// (prev) to (cur), both logical points — a grab-and-spin (course-up)
    /// gesture. Rotation is a shader uniform, so this only redraws: markDirty
    /// sets view_dirty, and needsRebuild ignores rotation, so no scene rebuild.
    /// The plugin overlay is the one exception, and only when a canvas holds
    /// content level on screen: that geometry is turned back at build time.
    pub fn rotateDragLogical(self: *Lookout, prev_x: f32, prev_y: f32, cur_x: f32, cur_y: f32) void {
        const sz = self.logicalSize();
        const cx = sz[0] * 0.5;
        const cy = sz[1] * 0.5;
        const a0 = std.math.atan2(@as(f64, prev_y - cy), @as(f64, prev_x - cx));
        const a1 = std.math.atan2(@as(f64, cur_y - cy), @as(f64, cur_x - cx));
        self.follow.course_up = false; // the mariner turned the chart by hand
        self.cam.rotation += a1 - a0;
        self.markDirty();
    }

    /// Snap the view back to north-up.
    pub fn resetRotation(self: *Lookout) void {
        self.follow.course_up = false; // north-up is the opposite of course-up
        if (self.cam.rotation == 0) return;
        self.cam.rotation = 0;
        self.markDirty();
    }

    /// Start a fling (momentum pan) with a logical-px/sec velocity.
    pub fn flingStart(self: *Lookout, vx: f64, vy: f64) void {
        self.cam.flingStart(vx, vy);
    }

    /// True while the camera is easing a zoom or coasting a fling.
    pub fn animating(self: *Lookout) bool {
        return self.cam.animating();
    }

    /// Advance camera animations by `dt` seconds; call each frame while animating.
    ///
    /// This does NOT touch the style. It used to call deriveLive() "to refresh
    /// the SCAMIN / display-scale gates", which sets `style_dirty` — so an
    /// eased zoom or a coasting fling rebuilt the whole style and re-laid-out
    /// every resident tile, sixty times a second. Measured on the app over a
    /// six-level zoom sweep, that was 17.3 ms of a 20 ms frame, against 2.5 ms
    /// for the render itself.
    ///
    /// The premise was wrong: nothing in the style depends on the camera's
    /// ZOOM. SCAMIN is carried as one bucket layer per denominator with a
    /// native fractional minzoom, which the layout bakes into each vertex's
    /// zoom window and the shader gates against a uniform — which is exactly
    /// why buckets were chosen over a filter gate that WOULD have needed a
    /// rebuild at each crossing. The one camera-dependent style input is
    /// scaminLat, and `styleLatMoved` handles that.
    pub fn tickAnim(self: *Lookout, dt: f64) void {
        self.cam.tick(dt);
        self.markDirty();
    }

    /// The current view's S-52 display-scale denominator (the N in 1:N), from the
    /// authoritative camera math (center latitude + zoom). For the HUD readout.
    pub fn scaleDenominator(self: *Lookout) f64 {
        return self.cam.displayScale();
    }

    // ---- mariner (ALL S-52 settings) ---------------------------------------
    pub fn getMariner(self: *Lookout) Mariner {
        return self.mariner;
    }
    /// Apply the full S-52 state.
    ///
    /// Every setting lands in the STYLE here — display categories and text
    /// groups as filters, the palette as colours, the safety contour and the
    /// depth units as the values the shading and the labels are built from. So
    /// there is one path for all of them and no "live" shortcut: the style is
    /// rebuilt before the next frame and the resident tiles are laid out again.
    /// The tiles are untouched, which is what keeps this affordable.
    pub fn setMariner(self: *Lookout, m: Mariner) void {
        const scheme_changed = self.mariner.scheme != m.scheme;
        self.mariner = m;
        // The symbol artwork carries its own colours, so a palette change is a
        // different sheet, not a different uniform.
        if (scheme_changed) self.sprite_scheme = null;
        self.deriveLive();
    }

    fn deriveLive(self: *Lookout) void {
        self.render_size_scale = if (self.mariner.size_scale == 0) 1.0 else @floatCast(self.mariner.size_scale);
        self.style_dirty = true;
        self.markDirty();
    }

    // ---- the frame ----------------------------------------------------------
    // charttable owns tiles, tessellation and coverage: it decides when the
    // scene has to be rebuilt and does it on its own worker. What is left here
    // is the state ABOVE the renderer — the mariner's style, the zoom band, the
    // overlay, the loader — and the order those are applied in around a draw.

    /// Zoom levels the camera may run past the deepest servable data.
    const OVERSCALE_ALLOW = 2.0;
    /// How far past the data a PAN may leave the view before it eases in. Four
    /// doublings is 16x magnification: past that the display is a smear and
    /// easing in is a kindness, short of that it is the mariner's business.
    const PAN_OVERSCALE_ALLOW = 4.0;

    // The zoom the chart is drawn at, clamped to the deepest band the library
    // serves. Zooming past it magnifies the deepest data (overscale) rather
    // than showing nothing.
    fn buildZoom(self: *Lookout) f64 {
        return @min(self.cam.zoom, self.engine_max_zoom);
    }

    fn markDirty(self: *Lookout) void {
        self.view_dirty = true;
        self.last_change_ms = clock.ticksMs();
    }

    pub fn apiLock(self: *Lookout) void {
        self.api_mu.lock();
    }
    pub fn apiUnlock(self: *Lookout) void {
        self.api_mu.unlock();
    }

    /// Draw a host-supplied style instead of the engine's portrayal, or null
    /// for lookout's own chart. The bytes are copied.
    pub fn setAltStyle(self: *Lookout, json: ?[]const u8) !void {
        if (self.alt_style) |old| self.alloc.free(old);
        self.alt_style = null;
        if (json) |j| self.alt_style = try self.alloc.dupe(u8, j);
        self.style_dirty = true;
        self.markDirty();
    }

    pub fn altStyleActive(self: *const Lookout) bool {
        return self.alt_style != null;
    }

    pub const TileRequestFn = ctprovided.RequestFn;
    pub const TileStatus = ctprovided.Status;

    /// Where an alt style's tiles are asked for. The host resolves the url
    /// from the style it fetched and answers with `respondTile`. See
    /// ct/provided.zig for why the fetching lives up there.
    pub fn setTileProvider(self: *Lookout, cb: ?TileRequestFn, user: ?*anyopaque) void {
        self.ct.setTileProvider(cb, user);
    }

    /// The host's answer to one ask, from any thread.
    ///
    /// No markDirty: the tile is still WANTED by the map until it decodes, so
    /// the frame loop is already running and will pick the bytes up on its
    /// next pass. Reaching for the dirty flag from a network thread would be
    /// touching render state without the lock for no gain.
    pub fn respondTile(self: *Lookout, req_id: u64, bytes: []const u8, status: TileStatus) void {
        self.ct.respondTile(req_id, bytes, status);
    }

    /// Rebuild the style and hand it to charttable, if the mariner moved.
    ///
    /// This is the whole cost of a mariner change on this renderer: the tiles
    /// carry tokens and raw depths and never change, so a scheme flip or a
    /// safety-contour nudge is a style swap and a relayout of the resident
    /// tiles. Nothing is refetched and nothing is re-composed.
    fn ensureStyle(self: *Lookout) void {
        if (!self.style_dirty) return;
        self.style_dirty = false;
        // Stamped for BOTH paths, before the alt-style return: it is what stops
        // styleLatMoved re-dirtying the style every frame, and an alt style is
        // pushed through the same flag.
        self.style_lat = self.scaminLat();
        if (self.alt_style) |j| {
            self.ct.setStyleJson(j) catch |e| {
                std.debug.print("alt style: {s}\n", .{@errorName(e)});
            };
            return;
        }
        var m = buildMarinerFrom(self.mariner, self.mariner.scheme);
        // size_scale is the style's physical calibration and ct/style.zig owns
        // it. The mariner's own multiplier goes to the renderer's uniform
        // below, so changing it never rebuilds the style.
        m.device_scale = 1.0; // the camera is in LOGICAL px; density lives in the projection
        self.ct.setStyle(.{
            .mariner = m,
            .tile_encoding = self.tileEncoding(),
            .scamin = self.scamin,
            .scamin_lat = self.scaminLat(),
        }) catch |e| {
            std.debug.print("style: {s}\n", .{@errorName(e)});
            return;
        };
        self.ct.setSizeScale(self.render_size_scale);
    }

    /// What the bound source serves. A composed set hands back raw MLT; a
    /// single archive says so in its own header, which charttable reads.
    fn tileEncoding(self: *Lookout) u8 {
        return if (self.compose != null) cc.TILE57_TILE_TYPE_MLT else cc.TILE57_TILE_TYPE_MVT;
    }

    /// A representative latitude for the SCAMIN denominators, which are
    /// latitude-dependent. The library centre, or the view when there is none.
    fn scaminLat(self: *Lookout) f64 {
        if (self.compose) |c| {
            var m: cc.tile57_compose_meta = std.mem.zeroes(cc.tile57_compose_meta);
            cc.tile57_compose_get_meta(c, &m);
            if (m.north != 0 or m.south != 0) return (m.north + m.south) * 0.5;
        }
        return camera.worldToLonLat(self.cam.center).y;
    }

    /// OS memory warning: drop what can be rebuilt.
    pub fn memoryWarning(self: *Lookout) void {
        self.trim_requested = true;
        if (self.surface_attached) return;
        self.serviceTrim();
    }

    /// Hand back the engine's reclaimable caches, if a warning asked for them.
    fn serviceTrim(self: *Lookout) void {
        if (!self.trim_requested) return;
        self.trim_requested = false;
        self.engine_mu.lock();
        cc.tile57_trim_caches();
        self.engine_mu.unlock();
    }

    /// Build whatever the current view needs, and wait for it. The frame loop
    /// never calls this — charttable rebuilds on its own worker — but a
    /// snapshot has to have the picture before it reads the pixels.
    /// How long `build` will wait for the renderer to go idle, in 2 ms polls.
    /// A ceiling, not a budget: reaching it means something never settled, and
    /// the frame goes out with whatever HAS landed rather than hanging.
    const BUILD_SPIN_MAX: u32 = 5000;

    pub fn build(self: *Lookout) !void {
        self.ensureAtlases();
        self.ensureStyle();
        self.ct.update();
        const t0 = clock.ticksMs();
        var spins: u32 = 0;
        while (!self.ct.idle() and spins < BUILD_SPIN_MAX) : (spins += 1) {
            self.ct.update();
            @import("lock.zig").sleepMs(2);
        }
        // $LOOKOUT_TIMING=1: say how long that took and, crucially, WHICH WAY
        // it ended. Hitting the ceiling is a stall, not slow work, and the two
        // are indistinguishable from the outside — both just show the mariner
        // a spinner (concerns C17).
        if (std.c.getenv("LOOKOUT_TIMING") != null) {
            std.debug.print("timing: build {d} ms, {d} spins{s}\n", .{
                clock.ticksMs() - t0,
                spins,
                if (spins >= BUILD_SPIN_MAX) " — HIT THE CEILING, never went idle" else "",
            });
            // WHICH condition held it open. "Not idle" is six different bugs
            // and they are not distinguishable from the outside.
            if (spins >= BUILD_SPIN_MAX) {
                const m = &self.ct.m;
                std.debug.print(
                    "timing:   building={} dirty={} partial={} animating={} needsRebuild={} pendingWanted={d} tilesBusy={}\n",
                    .{
                        m.building,           m.dirty,
                        m.partial,            m.cam.animating(),
                        m.needsRebuild(),     m.pendingWanted(),
                        self.ct.tiles.busy(),
                    },
                );
                std.debug.print("timing:   camZoom={d:.3} buildZoom={d:.3} covZoom={d:.3}\n", .{
                    m.cam.zoom, m.buildZoom(), m.cov_zoom,
                });
            }
        }
    }

    /// The pulse drawn while a chart library is opening; true means still loading.
    fn loadingPulse(self: *Lookout) bool {
        if (!self.loading) return false;
        self.pollCompose(false);
        return self.loading;
    }

    /// Per-frame setup before the draw: follow the drawable, refresh the zoom
    /// clamps, and make sure the style and atlases the scene needs are current.
    fn prepareFrame(self: *Lookout) void {
        // charttable adopts the real drawable size at acquire (a wrapped native
        // view can be laid out or rescaled behind our back) — follow it here so
        // the camera's logical viewport always matches what is on screen.
        const lw, const lh = self.logicalSize();
        if (self.cam.vw != lw or self.cam.vh != lh) {
            self.ct.m.setViewport(lw, lh);
            self.markDirty();
        }
        // Refresh the zoom clamps for the current view centre each frame (cheap):
        // panning into a coarser area lowers the per-view max and eases the zoom in.
        self.updateZoomLimits();
        self.ensureAtlases();
        if (self.styleLatMoved()) self.style_dirty = true;
        const ts = if (self.frame_prof != null) clock.ticksUs() else 0;
        self.ensureStyle();
        self.prof_style_us = if (self.frame_prof != null) clock.ticksUs() - ts else 0;
    }

    /// How far the SCAMIN latitude may drift before the style is stale.
    ///
    /// SCAMIN cutoffs are latitude-dependent, so the built style is only right
    /// for the latitude it was built at. Over a COMPOSED library that is the
    /// library centre and never moves; with a single chart open it follows the
    /// view, which is why this exists at all. A degree changes cos(lat) by well
    /// under a percent at any working latitude — far less than the gap between
    /// adjacent SCAMIN denominators — so this fires when a mariner has genuinely
    /// travelled, not while they pan around a harbor.
    const STYLE_LAT_DRIFT = 1.0;

    fn styleLatMoved(self: *Lookout) bool {
        return @abs(self.scaminLat() - self.style_lat) > STYLE_LAT_DRIFT;
    }

    pub fn render(self: *Lookout) !bool {
        if (self.loadingPulse()) return false;
        // $LOOKOUT_PHASE_PROF splits the frame into its four phases. The
        // offscreen harnesses measure a settled camera and report 5.68 ms; the
        // app under a moving camera measures 18 ms median, and this says which
        // phase the difference is in. Read once, here, because a host creates
        // the handle through several entry points and this is the one they all
        // reach.
        if (!self.prof_checked) {
            self.prof_checked = true;
            if (std.c.getenv("LOOKOUT_PHASE_PROF")) |p| {
                self.frame_prof = .{ .path = std.mem.span(p) };
            }
        }
        const prof = self.frame_prof != null;
        const t0 = if (prof) clock.ticksUs() else 0;
        self.prepareFrame();
        const t1 = if (prof) clock.ticksUs() else 0;
        self.serviceTrim();
        const t2 = if (prof) clock.ticksUs() else 0;
        self.updateOverlay();
        const t3 = if (prof) clock.ticksUs() else 0;
        const ok = self.ct.render();
        if (self.frame_prof) |*p| p.record(.{
            .prepare_us = t1 - t0,
            .style_us = self.prof_style_us,
            .trim_us = t2 - t1,
            .overlay_us = t3 - t2,
            .ct_us = clock.ticksUs() - t3,
            .ct_update_us = self.ct.prof_update_us,
            .ct_upload_us = self.ct.prof_upload_us,
            .ct_present_us = self.ct.prof_present_us,
        });
        // A SKIPPED frame (swapchain saturated) must not clear the flag: the
        // pending content still needs a successful present.
        if (ok) {
            self.view_dirty = false;
            // Own ship is drawn in EVERY frame, whatever raised it, so any
            // frame that lands restarts the ship clock (see SHIP_FRAME_MS).
            // Stamping only the ship's own frames would let a panning gesture
            // and the boat interleave into double the frames.
            self.last_ship_frame_ms = clock.ticksMs();
        }
        return ok;
    }

    /// How often own ship's own motion is allowed to raise a frame. 10 Hz is
    /// what a chartplotter shows and is far more than the mariner can see: at
    /// 6 knots the boat covers 0.3 m in 100 ms, which is under a pixel at any
    /// harbor scale. Drawing it at display rate instead cost 11% of a core
    /// for motion nobody could perceive.
    ///
    /// This gates the BOAT only. A gesture, a landing tile, a style change and
    /// a resize are all still immediate — those are the mariner's own actions
    /// and any delay in them is felt at once.
    const SHIP_FRAME_MS: i64 = 100;

    /// True while the view needs another frame (state changed, building, loading).
    pub fn needsRedraw(self: *Lookout) bool {
        // The camera lagging the (just-adopted) drawable size counts as dirty:
        // the adopt lands mid-render, AFTER that frame's camera sync, and the
        // host loop may go idle before the next one — without this the resync
        // (and the rebuild it forces) would never run.
        const lw, const lh = self.logicalSize();
        if (self.cam.vw != lw or self.cam.vh != lh) return true;
        // Everything the mariner did, and everything the renderer owes: no gate.
        if (self.loading or self.recomposing or self.view_dirty or self.style_dirty) return true;
        if (self.ct.needsRedraw()) return true;
        // What the BOAT did. Own ship's display position walks between fixes,
        // a plugin can post geometry from its own thread, and under follow the
        // chart slides beneath the boat — none of it with a gesture behind it,
        // and all of it paced rather than drawn as fast as the display allows.
        self.tickShip();
        if (self.overlayWantsFrame() or self.followWantsFrame()) {
            return clock.ticksMs() - self.last_ship_frame_ms >= SHIP_FRAME_MS;
        }
        return false;
    }

    pub fn isBuilding(self: *Lookout) bool {
        return self.loading or !self.ct.idle();
    }

    /// Render offscreen and write a PNG.
    pub fn snapshotPng(self: *Lookout, path: []const u8) !void {
        self.pollCompose(true);
        try self.build();
        self.updateOverlay();
        const px = try self.ct.snapshotRgba();
        defer self.alloc.free(px);
        try png.write(self.alloc, path, px, self.ct.width(), self.ct.height());
    }

    /// Render offscreen into a caller RGBA8 buffer (len must be width*height*4).
    pub fn snapshotRgba(self: *Lookout, dst: []u8) !void {
        self.pollCompose(true);
        try self.build();
        self.updateOverlay();
        const px = try self.ct.snapshotRgba();
        defer self.alloc.free(px);
        if (dst.len < px.len) return error.BufferTooSmall;
        @memcpy(dst[0..px.len], px);
    }

    // ---- pick (tap-to-identify) --------------------------------------------
    /// S-52 §10.8 cursor pick at a geographic point: `cb.feature` fires once per
    /// feature under it (class acronym + full S-57 attribute JSON + source cell).
    /// Live overscale factor: 2^(zoom - deepest servable zoom at the centre),
    /// clamped to >= 1. 1.0 = at or under the data's scale.
    pub fn overscale(self: *Lookout) f64 {
        const over = self.cam.zoom - self.viewMaxZoom();
        return if (over <= 0) 1.0 else std.math.exp2(over);
    }

    pub fn pick(self: *Lookout, lon: f64, lat: f64, cb: *const cc.tile57_query_cb) void {
        self.engine_mu.lock();
        defer self.engine_mu.unlock();
        var err: cc.tile57_error = undefined;
        if (self.compose) |c| {
            _ = cc.tile57_compose_query(c, lon, lat, self.cam.zoom, cb, &err);
        } else {
            if (self.charts.items.len == 0) return;
            _ = cc.tile57_chart_query(self.charts.items[0], lon, lat, self.cam.zoom, cb, &err);
        }
    }

    /// The pick a shell should show: the objects worth reporting, best first,
    /// with their depths in the mariner's unit (see pick.zig). Collected,
    /// ranked, converted, then replayed through `cb` in order, so a host reads
    /// the same callback it already has.
    pub fn pickRanked(self: *Lookout, lon: f64, lat: f64, cb: *const cc.tile57_query_cb) void {
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const a = arena.allocator();

        var collected = std.ArrayList(pick_rules.Feature).empty;
        const Collect = struct {
            list: *std.ArrayList(pick_rules.Feature),
            alloc: std.mem.Allocator,

            fn feature(ctx: ?*anyopaque, cls: [*c]const u8, cls_len: usize, s57: [*c]const u8, s57_len: usize, chart: [*c]const u8, chart_len: usize) callconv(.c) void {
                const self_: *@This() = @ptrCast(@alignCast(ctx orelse return));
                const dup = struct {
                    fn go(al: std.mem.Allocator, p: [*c]const u8, n: usize) []const u8 {
                        if (p == null or n == 0) return "";
                        return al.dupe(u8, p[0..n]) catch "";
                    }
                }.go;
                self_.list.append(self_.alloc, .{
                    .cls = dup(self_.alloc, cls, cls_len),
                    .s57 = dup(self_.alloc, s57, s57_len),
                    .chart = dup(self_.alloc, chart, chart_len),
                }) catch {};
            }
        };
        var collector = Collect{ .list = &collected, .alloc = a };
        var collect_cb = cc.tile57_query_cb{ .ctx = &collector, .feature = Collect.feature };
        self.pick(lon, lat, &collect_cb);

        // Drop what a pick should not report and what it reports twice, then
        // order what is left.
        var kept = std.ArrayList(pick_rules.Feature).empty;
        for (collected.items) |f| {
            if (!pick_rules.keep(f)) continue;
            var seen = false;
            for (kept.items) |k| {
                if (pick_rules.same(k, f)) seen = true;
            }
            if (!seen) kept.append(a, f) catch {};
        }
        pick_rules.order(kept.items);

        // The engine composes each feature's page. The page and the raw
        // payload travel together as {"report":...,"s57":...}: the report
        // for the shell to render, the raw payload for the source fold and
        // the clipboard. Depths convert before the compose, so the report
        // reads in the mariner's unit and the source keeps the cell's
        // metres. When the compose fails, the core emits the raw payload
        // alone and the shell still shows the fold.
        const feet = self.mariner.depth_unit == cc.TILE57_DEPTH_FEET;
        if (cb.feature) |emit| {
            for (kept.items) |f| {
                const converted = pick_rules.depthsInUnit(a, f.s57, feet);
                const raw: []const u8 = if (f.s57.len > 0) f.s57 else "{}";
                var rep: ?[*]u8 = null;
                var rep_len: usize = 0;
                var terr: cc.tile57_error = undefined;
                const payload: []const u8 = blk: {
                    if (cc.tile57_s57_report(f.cls.ptr, f.cls.len, f.chart.ptr, f.chart.len, converted.ptr, converted.len, &rep, &rep_len, &terr) == cc.TILE57_OK and rep != null and rep_len > 0) {
                        defer cc.tile57_free(rep);
                        break :blk std.fmt.allocPrint(a, "{{\"report\":{s},\"s57\":{s}}}", .{ rep.?[0..rep_len], raw }) catch f.s57;
                    }
                    break :blk f.s57;
                };
                emit(cb.ctx, f.cls.ptr, f.cls.len, payload.ptr, payload.len, f.chart.ptr, f.chart.len);
            }
        }
    }

    // ---- the raster underlay --------------------------------------------------
    //
    // NOT WIRED TO THE RENDERER YET. The mariner's picture charts (satellite
    // imagery, baked RNCs) were drawn by src/raster.zig, which owned its own
    // tile cache, worker pool and textures and put quads in front of the
    // chart's area fills using the depth buffer. None of that survives the
    // move: charttable owns the GPU, and it already has raster sources and
    // raster layers of its own.
    //
    // The port is designed and small, and it is written up as C5 in
    // specs/charttable/concerns.md: one host-provided raster source per set,
    // answered from tile57_raster_chart_tile off-thread exactly as ct/tiles.zig
    // answers vector tiles, plus one raster layer inserted into the style above
    // the area fills and below every line, symbol and label — which is the same
    // ordering the depth trick expressed, and reads identically per pixel.
    //
    // Until then these answer honestly: there are no sets, nothing is drawn,
    // and a shell's picture-chart UI shows an empty list rather than lying
    // about imagery it cannot display.

    /// Open a raster chart the mariner supplied and add it to its set.
    pub fn addRaster(self: *Lookout, path: [:0]const u8) bool {
        _ = self;
        _ = path;
        return false;
    }

    pub fn cycleRaster(self: *Lookout) void {
        _ = self;
    }

    /// The name of the set drawn over this view, or "" for no picture.
    pub fn rasterName(self: *Lookout) [:0]const u8 {
        _ = self;
        return "";
    }

    /// Is the chart actually drawing WITHOUT its opaque fills right now?
    pub fn rasterOverChart(self: *Lookout) bool {
        _ = self;
        return false;
    }

    /// Show or hide the vector chart. The picture beneath it stays.
    pub fn setChartHidden(self: *Lookout, hidden: bool) void {
        if (self.chart_hidden == hidden) return;
        self.chart_hidden = hidden;
        // Every chart layer off, in one call, with the tiles left alone: the
        // style stays loaded and turning it back on is a visibility diff.
        self.ct.setChartVisible(!hidden);
        self.view_dirty = true;
    }

    pub fn toggleChart(self: *Lookout) void {
        self.setChartHidden(!self.chart_hidden);
    }

    pub fn chartHidden(self: *Lookout) bool {
        return self.chart_hidden;
    }

    /// The set that covers this view, drawn or not.
    pub fn rasterAvailableName(self: *Lookout) [:0]const u8 {
        _ = self;
        return "";
    }

    pub fn setRasterEnabled(self: *Lookout, path: []const u8, on: bool) bool {
        _ = self;
        _ = path;
        _ = on;
        return false;
    }

    pub fn rasterEnabled(self: *Lookout, path: []const u8) bool {
        _ = self;
        _ = path;
        return false;
    }

    pub fn rasterSetName(self: *Lookout, i: usize) [:0]const u8 {
        _ = self;
        _ = i;
        return "";
    }

    pub fn rasterSetInView(self: *Lookout, i: usize) bool {
        _ = self;
        _ = i;
        return false;
    }

    pub fn rasterActiveIndex(self: *Lookout) ?usize {
        _ = self;
        return null;
    }

    pub fn rasterSelect(self: *Lookout, i: ?usize) void {
        _ = self;
        _ = i;
    }

    pub fn rasterShown(self: *Lookout, i: usize) bool {
        _ = self;
        _ = i;
        return false;
    }

    pub fn rasterSetShown(self: *Lookout, i: usize, on: bool) void {
        _ = self;
        _ = i;
        _ = on;
    }

    pub fn rasterSetCount(self: *Lookout) usize {
        _ = self;
        return 0;
    }

    pub fn cycleScheme(self: *Lookout) void {
        const order = [_]Scheme{ cc.TILE57_SCHEME_DAY, cc.TILE57_SCHEME_DUSK, cc.TILE57_SCHEME_NIGHT };
        var idx: usize = 0;
        for (order, 0..) |s, i| if (s == self.mariner.scheme) {
            idx = i;
        };
        self.mariner.scheme = order[(idx + 1) % order.len];
        // The symbol artwork carries its own colours, so a palette change is a
        // different sheet as well as a different style.
        self.sprite_scheme = null;
        self.deriveLive();
    }
    pub fn toggleText(self: *Lookout) void {
        const on = self.mariner.text_names or self.mariner.show_light_descriptions or self.mariner.text_other;
        self.mariner.text_names = !on;
        self.mariner.show_light_descriptions = !on;
        self.mariner.text_other = !on;
        self.deriveLive();
    }
    pub fn toggleSoundings(self: *Lookout) void {
        // 1 = always shown, 2 = never; 0 follows the OTHER category. Anything
        // that is currently drawing soundings turns them off.
        const on = self.mariner.soundings == 1 or
            (self.mariner.soundings == 0 and self.mariner.display_other);
        self.mariner.soundings = if (on) 2 else 1;
        self.deriveLive();
    }
    pub fn toggleOtherCategory(self: *Lookout) void {
        self.mariner.display_other = !self.mariner.display_other;
        self.deriveLive();
    }
    /// Flip depth labels/soundings between metres and feet. Portrayal-affecting
    /// (the engine swaps the sounding glyph + SAFCON01 unit), so it re-portrays.
    pub fn toggleDepthUnit(self: *Lookout) void {
        self.mariner.depth_unit = if (self.mariner.depth_unit == cc.TILE57_DEPTH_FEET)
            cc.TILE57_DEPTH_METERS
        else
            cc.TILE57_DEPTH_FEET;
        self.deriveLive();
    }
    pub fn nudgeSafetyContour(self: *Lookout, delta: f64) void {
        self.mariner.safety_contour = std.math.clamp(self.mariner.safety_contour + delta, 0, 200);
        self.deriveLive();
    }
    pub fn adjustSize(self: *Lookout, factor: f32) void {
        self.render_size_scale *= factor;
        // Symbol placement is measured in DRAWN px, so a size change decides
        // which labels win a collision: charttable lays out again for it.
        self.ct.setSizeScale(self.render_size_scale);
        self.markDirty();
    }
};

/// True if changing from `a` to `b` alters what the engine emits (needs a
/// rebuild). Visibility-only fields (scheme, categories, text, soundings, size)
/// are excluded — those apply live.
fn marinerNeedsRebuild(a: Mariner, b: Mariner) bool {
    return a.shallow_contour != b.shallow_contour or a.safety_contour != b.safety_contour or
        a.deep_contour != b.deep_contour or a.safety_depth != b.safety_depth or
        a.four_shade_water != b.four_shade_water or a.depth_unit != b.depth_unit or
        a.data_quality != b.data_quality or a.show_inform_callouts != b.show_inform_callouts or
        a.show_meta_bounds != b.show_meta_bounds or a.show_isolated_dangers_shallow != b.show_isolated_dangers_shallow or
        a.boundary_style != b.boundary_style or a.simplified_points != b.simplified_points or
        a.show_full_sector_lines != b.show_full_sector_lines or a.date_dependent != b.date_dependent or
        a.highlight_date_dependent != b.highlight_date_dependent or
        !std.mem.eql(u8, &a.date_view, &b.date_view) or a.ignore_scamin != b.ignore_scamin or
        a.viewing_groups_off != b.viewing_groups_off or a.viewing_groups_off_len != b.viewing_groups_off_len or
        a.scamin_filter_gate != b.scamin_filter_gate or a.show_overscale != b.show_overscale or
        a.text_size_scale != b.text_size_scale or a.sounding_size_scale != b.sounding_size_scale;
}

// ---- the chart library ------------------------------------------------------

/// tile57's verdict on one baked archive. A picture archive and a foreign
/// archive both open, so the answer needs the archive's own metadata.
fn verifyArchive(_: ?*anyopaque, path: [:0]const u8, out: *library.Facts) library.Verdict {
    var chart: ?*cc.tile57_chart = null;
    var err: cc.tile57_error = undefined;
    if (cc.tile57_chart_open(path.ptr, &chart, &err) != cc.TILE57_OK) return .no;
    defer cc.tile57_chart_close(chart);
    var info: cc.tile57_info = undefined;
    cc.tile57_chart_get_info(chart, &info);
    if (info.is_raster) return .raster;
    // A bake embeds the compilation scale and the bands it wrote. An archive
    // with neither is not one of ours.
    if (info.bands == 0 and info.native_scale == 0) return .no;
    out.* = .{
        .scale = info.native_scale,
        .bounds = if (info.has_bounds)
            .{ info.west, info.south, info.east, info.north }
        else
            null,
    };
    return .chart;
}

/// Look through `path` for charts this build draws. The caller owns the Scan.
pub fn scanCharts(alloc: std.mem.Allocator, io: std.Io, path: []const u8) !library.Scan {
    return library.scan(alloc, io, path, verifyArchive, null);
}

/// The same, for a chart set that arrives as one .zip. The archive is listed
/// (its central directory, nothing inflated) and the names are classified by
/// the same rules a folder's files are, so a host sees one kind of answer
/// whichever the mariner picked.
///
/// Each chart's `path` is its ENTRY NAME. That is what the engine's zip bake
/// takes back, and it is deliberately not a filesystem path: there is no file
/// to open until something asks for one.
pub fn scanZip(alloc: std.mem.Allocator, path: []const u8) !library.Scan {
    const pz = try alloc.dupeZ(u8, path);
    defer alloc.free(pz);

    var out: ?[*]u8 = null;
    var len: usize = 0;
    var err: cc.tile57_error = undefined;
    if (cc.tile57_zip_list(pz, &out, &len, &err) != cc.TILE57_OK) return error.NotAnArchive;
    const listing = out orelse return error.NotAnArchive;
    defer cc.tile57_free(listing);

    const parsed = std.json.parseFromSlice(std.json.Value, alloc, listing[0..len], .{}) catch
        return error.NotAnArchive;
    defer parsed.deinit();

    var entries: std.ArrayList(library.Entry) = .empty;
    defer entries.deinit(alloc);
    for (parsed.value.array.items) |item| {
        const o = item.object;
        const name = (o.get("name") orelse continue).string;
        const bytes: u64 = switch (o.get("size") orelse std.json.Value{ .integer = 0 }) {
            .integer => |i| if (i > 0) @intCast(i) else 0,
            else => 0,
        };
        try entries.append(alloc, .{ .name = name, .bytes = bytes });
    }
    return library.scanEntries(alloc, path, entries.items);
}

test {
    // Collect the pick rules' own tests. Only pickRanked reaches pick.zig, and a
    // test build never analyzes it, so without this the file's tests never run.
    _ = pick_rules;
    // The renderer's own layers, so a test build analyses them: the style
    // builder and the composed-tile provider carry their tests.
    _ = cstyle;
    _ = @import("ct/tiles.zig");
    _ = ctprovided;
    _ = cthost;
}

test "camera roundtrip" {
    const w = camera.lonLatToWorld(-76.48, 38.98);
    const ll = camera.worldToLonLat(w);
    try std.testing.expectApproxEqAbs(@as(f64, -76.48), ll.x, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 38.98), ll.y, 1e-9);
}

// ---- follow mode ------------------------------------------------------------
// The camera a follow test starts from: an Annapolis view the size of the Mac
// window the mode was measured in.
fn followTestCamera() camera.Camera {
    const origin = camera.lonLatToWorld(-76.4767, 38.9763);
    return .{
        .origin = origin,
        .center = origin,
        .zoom = 15,
        .target_zoom = 15,
        .vw = 1264,
        .vh = 730,
        .min_zoom = 4,
        .max_zoom = 22,
    };
}

test "follow puts the fix at the centre, three quarters down" {
    const t = std.testing;
    var cam = followTestCamera();
    var f = Follow{ .on = true };
    const fix = camera.lonLatToWorld(-76.4720, 38.9800); // north-east of the centre
    try t.expect(f.apply(&cam, fix));
    const s = cam.worldToScreen(fix);
    try t.expectApproxEqAbs(@as(f64, 1264.0 * 0.5), s.x, 1e-6);
    try t.expectApproxEqAbs(@as(f64, 730.0 * 0.75), s.y, 1e-6);
    // The same fix on the same pose is already anchored: no move, no frame.
    try t.expect(!f.pending(cam, fix));
    try t.expect(!f.apply(&cam, fix));
}

test "a pan turns follow off and still pans" {
    const t = std.testing;
    var cam = followTestCamera();
    var f = Follow{ .on = true };
    _ = f.apply(&cam, camera.lonLatToWorld(-76.4720, 38.9800));
    const before = cam.center;
    f.pan(&cam, 120, -40);
    try t.expect(!f.on);
    try t.expect(f.applied == null);
    try t.expect(cam.center.x != before.x and cam.center.y != before.y);
    // Own ship walks across the screen from here: a new fix moves nothing.
    const held = cam.center;
    try t.expect(!f.apply(&cam, camera.lonLatToWorld(-76.4700, 38.9820)));
    try t.expectEqual(held.x, cam.center.x);
    try t.expectEqual(held.y, cam.center.y);
}

test "a zoom while following pivots on the anchor" {
    const t = std.testing;
    const ax: f32 = 1264.0 * 0.5;
    const ay: f32 = 730.0 * 0.75;
    var cam = followTestCamera();
    var f = Follow{ .on = true };
    const fix = camera.lonLatToWorld(-76.4720, 38.9800);
    _ = f.apply(&cam, fix);
    // The caller passes a corner; own ship must stay where it is anyway.
    f.zoomAbout(&cam, 2.0, 30, 30);
    try t.expectApproxEqAbs(@as(f64, 17), cam.zoom, 1e-12);
    const s = cam.worldToScreen(fix);
    try t.expectApproxEqAbs(@as(f64, ax), s.x, 1e-6);
    try t.expectApproxEqAbs(@as(f64, ay), s.y, 1e-6);
    // With follow off the same call honours the point it was given.
    var cam2 = followTestCamera();
    const off = Follow{};
    const under = cam2.screenToWorld(30, 30);
    off.zoomAbout(&cam2, 2.0, 30, 30);
    const after = cam2.screenToWorld(30, 30);
    try t.expectApproxEqAbs(under.x, after.x, 1e-9);
    try t.expectApproxEqAbs(under.y, after.y, 1e-9);
}

test "a fix older than the staleness window leaves the camera alone" {
    if (plugins_on) {
        const t = std.testing;
        var vessels = try phost.store.Store.init(t.allocator);
        defer vessels.deinit();
        try vessels.set("navigation.position", "{\"lat\":38.98,\"lon\":-76.472}", 1_000, 1);

        // 4 s after the fix: inside the 5 s window, so follow moves the chart.
        var ship = ShipDisplay{};
        ship.observe(PluginSystem.readShip(&vessels, 5_000));
        const fresh = ship.at(5_000);
        try t.expect(fresh != null);
        var cam = followTestCamera();
        var f = Follow{ .on = true };
        try t.expect(f.apply(&cam, camera.lonLatToWorld(fresh.?[0], fresh.?[1])));

        // 9 s after it: past the window. Follow stays on, armed and waiting.
        var stale_cam = followTestCamera();
        var g = Follow{ .on = true };
        ship.observe(PluginSystem.readShip(&vessels, 10_000));
        const stale = ship.at(10_000);
        try t.expect(stale == null);
        try t.expect(!g.pending(stale_cam, null));
        try t.expect(!g.apply(&stale_cam, null));
        try t.expect(g.on);
        try t.expectEqual(followTestCamera().center.x, stale_cam.center.x);
        try t.expectEqual(followTestCamera().center.y, stale_cam.center.y);
    }
}

// Rule 8: the ship must not step once a second. The display position carries
// the newest fix forward along COG at SOG, and stops at the window.
test "the display position carries own ship between fixes" {
    const t = std.testing;
    var ship = ShipDisplay{};
    ship.observe(.{
        .fix = .{ .lon = -76.4767, .lat = 38.9763, .ts_ms = 1_000 },
        .cog_deg = 90.0, // due east
        .sog_ms = 10.0,
        .heading_deg = 95.0,
    });
    const at0 = ship.at(1_000).?;
    try t.expectApproxEqAbs(@as(f64, -76.4767), at0[0], 1e-12);
    // Half a second east at 10 m/s is 5 m of longitude and no latitude.
    const at1 = ship.at(1_500).?;
    const east_m = (at1[0] - at0[0]) * M_PER_DEG * @cos(38.9763 * std.math.pi / 180.0);
    try t.expectApproxEqAbs(@as(f64, 5.0), east_m, 0.01);
    try t.expectApproxEqAbs(at0[1], at1[1], 1e-12);
    // The carry is monotonic up to the window and gone after it.
    try t.expect(ship.at(5_900) != null);
    try t.expect(ship.at(6_100) == null);
}

// A fix with no instruments behind it still carries, on the run between the
// last two fixes.
test "the display position falls back to the run between fixes" {
    const t = std.testing;
    var ship = ShipDisplay{};
    ship.observe(.{ .fix = .{ .lon = -76.5000, .lat = 38.9763, .ts_ms = 1_000 } });
    ship.observe(.{ .fix = .{ .lon = -76.4990, .lat = 38.9763, .ts_ms = 2_000 } });
    const at = ship.at(2_500).?;
    // Half the last second's run again: 0.0005 degrees of longitude.
    try t.expectApproxEqAbs(@as(f64, -76.4985), at[0], 1e-6);
}

// Rule 5: course up turns to the SMOOTHED display course, and a boat that is
// stopped keeps the course it had rather than spinning the chart on GPS noise.
test "the display course is smoothed and freezes when the boat stops" {
    const t = std.testing;
    var ship = ShipDisplay{};
    var ts: i64 = 1_000;
    while (ts <= 5_000) : (ts += 1_000) {
        ship.observe(.{ .fix = .{ .lon = -76.5, .lat = 38.9, .ts_ms = ts }, .cog_deg = 90, .sog_ms = 5 });
    }
    try t.expectApproxEqAbs(@as(f64, 90.0), ship.upDeg().?, 1e-9);

    // A turn to 120 moves the chart part of the way, not all at once.
    ship.observe(.{ .fix = .{ .lon = -76.5, .lat = 38.9, .ts_ms = 6_000 }, .cog_deg = 120, .sog_ms = 5 });
    const turning = ship.upDeg().?;
    try t.expect(turning > 90.0 and turning < 120.0);

    // Under the speed floor the course holds, whatever the GPS says.
    ship.observe(.{ .fix = .{ .lon = -76.5, .lat = 38.9, .ts_ms = 7_000 }, .cog_deg = 300, .sog_ms = 0.1 });
    try t.expectEqual(turning, ship.upDeg().?);

    // A lost fix leaves nothing to turn to.
    ship.observe(.{});
    try t.expect(ship.upDeg() == null);
}

// Course-up turns the chart so the heading points up the screen, and holds
// still inside the deadband.
test "course up turns the chart to own ship's heading" {
    const t = std.testing;
    var cam = followTestCamera();
    var f = Follow{ .course_up = true };
    try t.expect(f.rotate(&cam, 75.0));
    try t.expectApproxEqAbs(-75.0 * std.math.pi / 180.0, cam.rotation, 1e-12);
    // A world bearing of 75 degrees now draws straight up the screen.
    const c = camera.worldToLonLat(cam.center);
    const north = camera.lonLatToWorld(c.x, c.y + 0.01);
    const p0 = cam.worldToScreen(cam.center);
    const pn = cam.worldToScreen(north);
    const screen_bearing = std.math.atan2(pn.x - p0.x, p0.y - pn.y) * 180.0 / std.math.pi;
    try t.expectApproxEqAbs(@as(f64, -75.0), screen_bearing, 0.05); // north is 75 to the left
    // Inside the deadband nothing turns; outside it does.
    try t.expect(!f.rotate(&cam, 75.1));
    try t.expect(f.rotate(&cam, 78.0));
    // No heading: the chart stays where it is.
    try t.expect(!f.rotate(&cam, null));
    // Off: nothing turns at all.
    const off = Follow{};
    try t.expect(!off.rotate(&cam, 10.0));
}

// Rule: a marker draws itself. The batch the core posts is the only thing
// between a dropped mark and pixels, and a canvas the store refuses draws
// nothing while saying so only in a log line, so assert the store takes it.
test "a marker posts a canvas the overlay store draws" {
    const t = std.testing;
    const a = t.allocator;
    var one = "Mark 1".*;
    var two = "the \"rock\"".*;
    const list = [_]marks.Marker{
        .{ .id = 1, .lon = -76.4767, .lat = 38.9763, .name = &one, .dropped_ms = 1 },
        .{ .id = 2, .lon = -76.4700, .lat = 38.9800, .name = &two, .dropped_ms = 2 },
    };

    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(a);
    try markerBatch(a, &json, &list, Lookout.markerRgba(.day));

    var store = ov.Store.init(a);
    defer store.deinit();
    try store.applyBatch("lookout.markers", json.items);
    try t.expectEqual(@as(usize, 2), store.count());

    // Geometry, in the magenta asked for, near where the mark was dropped.
    const fr = try store.buildIfNeeded(15.0, 0, .day, null);
    try t.expect(fr.verts.len > 0);
    const c = Lookout.markerRgba(.day);
    var magenta = false;
    for (fr.verts) |v| {
        if (@abs(v.r - @as(f32, @floatCast(c[0]))) < 1e-6 and
            @abs(v.b - @as(f32, @floatCast(c[2]))) < 1e-6) magenta = true;
    }
    try t.expect(magenta);

    // A name with a quote in it is escaped, not a broken batch.
    try t.expect(std.mem.indexOf(u8, json.items, "\\\"rock\\\"") != null);
}

// The night palette rule the overlay's own tokens keep: a mark must not undo a
// night-adapted eye.
test "the marker magenta is dim at night and differs by scheme" {
    const t = std.testing;
    const day = Lookout.markerRgba(.day);
    const night = Lookout.markerRgba(.night);
    try t.expect(!std.mem.eql(u8, std.mem.asBytes(&day), std.mem.asBytes(&night)));
    const lum = 0.2126 * night[0] + 0.7152 * night[1] + 0.0722 * night[2];
    try t.expect(lum < 0.35);
    for (day) |ch| try t.expect(ch >= 0 and ch <= 1);
    for (night) |ch| try t.expect(ch >= 0 and ch <= 1);
}
