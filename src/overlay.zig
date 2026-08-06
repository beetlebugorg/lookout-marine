//! Retained chart overlays: the geometry a plugin DESCRIBES and the core DRAWS.
//!
//! A plugin never touches a pipeline. It posts JSON batches of retained
//! objects (symbol / polyline / polygon anchored to lon/lat, coloured by
//! palette TOKEN), and this store keeps them, expands them to triangles in
//! web-mercator world space, and hands the render thread one flat vertex array
//! the backend uploads verbatim. Colour is a token, never an RGB; the token
//! table below resolves it per scheme.
//!
//! THE API root.zig DRIVES
//!
//!   var ov = overlay.Store.init(alloc);      // once, at open
//!   defer ov.deinit();
//!   try ov.applyBatch("org.beetlebug.ais", json);   // broker thread, any time
//!   ov.removeSource("org.beetlebug.ais");           // plugin stopped/failed
//!   const fr = try ov.buildIfNeeded(cam.zoom, .day, null); // render thread, per frame
//!   try gpu.setOverlay(fr);                          // re-uploads iff fr.generation moved
//!
//! THREADING. `applyBatch` / `removeSource` run on the broker's worker: they
//! take the mutex and touch only the object map. `buildIfNeeded` takes the same
//! mutex, rebuilds the vertex array under it, and returns a slice of it. That
//! slice stays valid until the NEXT buildIfNeeded, and only the render thread
//! calls that — so the render thread may read the frame lock-free, and an apply
//! landing mid-frame is simply picked up by the next build.
//!
//! SCREEN SIZES. Symbol radii and line widths are screen POINTS. There is no
//! per-vertex screen-offset channel here (the chart's px_to_clip trick needs a
//! vertex format this pass does not carry), so a point size is converted to
//! world units at BUILD time from the zoom, and the build is redone when the
//! zoom has moved more than 5% in scale. Between rebuilds a symbol scales with
//! the chart, which at 5% is under half a point on an 8 pt symbol.
//!
//! COORDINATES. Vertices are ABSOLUTE web-mercator world [0,1] as f32 — the
//! same space, and the same f32 precision, as the chart vertices the engine
//! emits (root.zig builds the MVP with origin 0,0). The backend's overlay
//! shader applies the same antimeridian wrap the chart shader does.
const std = @import("std");
const camera = @import("camera.zig");
const lock = @import("lock.zig");

/// Palette scheme. Mirrors tile57's day/dusk/night; kept as a local enum so
/// this file (and its tests) need no C import.
pub const Scheme = enum(u8) { day = 0, dusk = 1, night = 2 };

/// The prototype's colour vocabulary (PROTOTYPE.md "Color tokens"). A plugin
/// names one of these; the core picks the RGBA for the active scheme.
pub const Token = enum(u8) {
    ownship,
    target,
    target_danger,
    track,
    layline_port,
    layline_stbd,
    warning,
};

pub const Kind = enum(u8) { symbol, polyline, polygon };

/// The symbol shapes the prototype draws. Expanded to vector geometry here —
/// no sprite atlas, so the overlay pass carries no texture.
pub const Sym = enum(u8) { ownship, target };

/// Straight-alpha RGBA, 0..1 (what the shader wants).
pub const Rgba = [4]f32;

fn rgb(hex: u24, a: f32) Rgba {
    return .{
        @as(f32, @floatFromInt((hex >> 16) & 0xFF)) / 255.0,
        @as(f32, @floatFromInt((hex >> 8) & 0xFF)) / 255.0,
        @as(f32, @floatFromInt(hex & 0xFF)) / 255.0,
        a,
    };
}

/// Token -> RGBA per scheme, indexed [token][scheme]. Not from a standard;
/// see PROTOTYPE-CONCERNS.md. Night values are held under 0.35 encoded
/// luminance, which the token test enforces.
const TOKENS: [7][3]Rgba = .{
    .{ rgb(0x101418, 1.0), rgb(0xC8D2D8, 1.0), rgb(0x9A4218, 1.0) }, // ownship
    .{ rgb(0x8C1EA8, 1.0), rgb(0xB478D2, 1.0), rgb(0x7A4A10, 1.0) }, // target
    .{ rgb(0xD40B1E, 1.0), rgb(0xE03A44, 1.0), rgb(0xC2301C, 1.0) }, // target_danger
    .{ rgb(0x2D4F8F, 0.85), rgb(0x7F9FD0, 0.85), rgb(0x5A2410, 0.85) }, // track
    .{ rgb(0xC8102E, 0.95), rgb(0xE0505F, 0.95), rgb(0x8E2418, 0.95) }, // layline_port
    .{ rgb(0x0F8A3C, 0.95), rgb(0x4FBD74, 0.95), rgb(0x2A5C1C, 0.95) }, // layline_stbd
    .{ rgb(0xE06A00, 1.0), rgb(0xF0A040, 1.0), rgb(0x7E5008, 1.0) }, // warning
};

/// The RGBA a token resolves to under `scheme`.
pub fn resolve(tok: Token, scheme: Scheme) Rgba {
    return TOKENS[@intFromEnum(tok)][@intFromEnum(scheme)];
}

/// One overlay vertex: world position + colour. 24 bytes, mirrored by
/// `OverlayVertex` in the backends' overlay shader.
pub const Vertex = extern struct {
    x: f32,
    y: f32,
    r: f32,
    g: f32,
    b: f32,
    a: f32,
};

/// What the render thread hands the GPU layer. `generation` only moves when the
/// vertices changed, so the backend re-uploads on a change and never per frame.
pub const Frame = struct {
    verts: []const Vertex,
    generation: u64,
};

/// One retained object, as posted. Geometry is kept in GEO and expanded per
/// build, so a zoom change re-expands without the plugin resending anything.
const Object = struct {
    kind: Kind,
    token: Token,
    // symbol
    sym: Sym = .ownship,
    at: [2]f64 = .{ 0, 0 }, // lon, lat
    rot_deg: f32 = 0, // true bearing, clockwise from north
    scale: f32 = 1,
    // polyline / polygon
    pts: [][2]f64 = &.{}, // lon, lat; owned
    width_pt: f32 = 1.5,
    dash: bool = false,
    alpha: f32 = 1, // polygon fill alpha, multiplies the token's
    /// Canonical JSON `{"title":"...","rows":[["k","v"],...]}`, or empty.
    /// Owned. Only symbols are hit-tested; see `pickAt`.
    pick: []u8 = &.{},
    /// The object rides own ship's DISPLAY position instead of the lon/lat it
    /// was posted with. Fixes arrive about once a second; the core carries the
    /// boat between them and substitutes that point here, so the symbol and
    /// its lines move smoothly. A polyline keeps its shape and travels with
    /// its first point.
    ship_anchor: bool = false,

    fn free(self: *Object, alloc: std.mem.Allocator) void {
        if (self.pts.len > 0) alloc.free(self.pts);
        self.pts = &.{};
        if (self.pick.len > 0) alloc.free(self.pick);
        self.pick = &.{};
    }
};

// ---- geometry constants (screen points) ------------------------------------
//
// S-52 sizes symbols in millimetres: a .dai vector unit is 0.01 mm (PresLib
// Part I s8) on a 0.3 mm pixel pitch. This file's unit is the point. S-52
// defines no geometry for the own-ship and AIS symbols; see
// PROTOTYPE-CONCERNS.md, "What S-52 says".

/// Points per millimetre.
const PT_PER_MM: f64 = 72.0 / 25.4;

/// Smallest own-ship length drawn. 9 mm, not the 6 mm the standard names as
/// the threshold for a scaled outline: at 6 mm long this hull is 1.9 mm in the
/// beam and reads as a line. See PROTOTYPE-CONCERNS.md.
const OWNSHIP_MIN_LEN_PT: f64 = 9.0 * PT_PER_MM; // 25.5 pt

/// Own ship's length overall, metres. No vessel configuration exists, so this
/// is a compile-time default.
const OWNSHIP_LOA_M: f64 = 12.0;

/// Beam as a fraction of length overall. Constant, so the outline keeps its
/// proportions at every size.
const OWNSHIP_BEAM_RATIO: f64 = 0.31;

/// The own-ship hull in plan: `along` in fractions of length overall, bow
/// positive; `across` in fractions of the half beam, starboard positive.
/// Origin is the reported position. Convex, so it fans.
const HULL: [7][2]f64 = .{
    .{ -0.50, -1.00 }, // port quarter
    .{ -0.50, 1.00 }, // starboard quarter
    .{ 0.20, 1.00 }, // starboard shoulder
    .{ 0.38, 0.72 },
    .{ 0.50, 0.00 }, // stem
    .{ 0.38, -0.72 },
    .{ 0.20, -1.00 }, // port shoulder
};

/// The AIS target triangle: acute isosceles, 20 pt long by 14 pt at the base.
const TARGET_TIP = 13.0; // apex ahead of the anchor
const TARGET_TAIL = 7.0; // base behind it
const TARGET_HALF = 7.0;
const DASH_ON = 7.0;
const DASH_OFF = 5.0;
/// Above this many dash cycles a segment draws solid — see emitPolyline.
const MAX_DASHES_PER_SEG = 4096;

/// Vertices one `ownship` symbol expands to: the hull, fanned.
pub const OWNSHIP_VERTS = (HULL.len - 2) * 3;
/// Vertices one `target` symbol expands to.
pub const TARGET_VERTS = 3;

/// How near a logical point must be to a symbol's anchor for `pickAt` to
/// report it.
pub const PICK_RADIUS_PT: f64 = 14.0;

/// Ceilings on a pick payload. Over either, the payload is truncated.
const MAX_PICK_ROWS = 16;
const MAX_PICK_TEXT = 96;

/// Metres round the equator: 2*pi*a for the WGS84 semi-major axis. The width
/// of the web-mercator world.
const EARTH_CIRCUMFERENCE_M: f64 = 40075016.685578488;

/// Rebuild when the scale has moved more than 5% — log2(1.05) of zoom.
const ZOOM_REBUILD_DZ = 0.070389327891398;

/// Per-store object ceiling. A plugin that leaks objects costs frame time and
/// memory; over the cap the batch is rejected rather than silently truncated.
const MAX_OBJECTS = 4096;
/// Per-object point ceiling — the prototype's longest line is a 600-point
/// track, and an unbounded ring or polyline is an unbounded vertex buffer.
const MAX_POINTS = 8192;

pub const Error = error{ BadBatch, Budget, OutOfMemory };

pub const Store = struct {
    alloc: std.mem.Allocator,
    mu: lock.Lock = .{},
    /// Keyed by "<source_id>/<object id>" — the host's namespace, so two
    /// plugins may both call their symbol "ownship". Ordered map: draw order is
    /// insertion order within a kind, which is stable frame to frame.
    objs: std.StringArrayHashMapUnmanaged(Object) = .empty,
    verts: std.ArrayList(Vertex) = .empty,
    /// The last pick payload handed out, copied under the mutex. `pickAt`
    /// returns a slice of this, not of the object: batches land on a broker
    /// thread that does not hold the C ABI lock, so a pointer into an object
    /// would dangle when the plugin redrew that target.
    pick_out: std.ArrayList(u8) = .empty,
    /// The id last handed out by a hit test, NUL-terminated. Same reason as
    /// pick_out: a plugin thread may replace the object at any moment.
    id_out: std.ArrayList(u8) = .empty,
    gen: u64 = 0,
    dirty: bool = true,
    has_build: bool = false,
    built_zoom: f64 = 0,
    built_scheme: Scheme = .day,
    /// Own ship's display position at the last build, and whether any object
    /// rides it. Without a rider the position is ignored and nothing rebuilds.
    built_ship: ?[2]f64 = null,
    has_ship_anchor: bool = false,

    pub fn init(alloc: std.mem.Allocator) Store {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Store) void {
        var it = self.objs.iterator();
        while (it.next()) |e| {
            self.alloc.free(e.key_ptr.*);
            e.value_ptr.free(self.alloc);
        }
        self.objs.deinit(self.alloc);
        self.verts.deinit(self.alloc);
        self.pick_out.deinit(self.alloc);
        self.id_out.deinit(self.alloc);
        self.* = undefined;
    }

    /// Objects currently retained (all sources).
    pub fn count(self: *Store) usize {
        self.mu.lock();
        defer self.mu.unlock();
        return self.objs.count();
    }

    // ---- the control plane ------------------------------------------------

    /// Apply one overlay batch from `source_id`:
    /// `{"set":[<obj>,...],"del":["id",...]}`. Ids are namespaced by source.
    /// A `set` replaces the whole object. Malformed OBJECTS are skipped (a
    /// plugin's bad row must not drop its good ones); malformed JSON, a missing
    /// top-level object, or exceeding the object budget fail the batch.
    pub fn applyBatch(self: *Store, source_id: []const u8, json: []const u8) Error!void {
        var parsed = std.json.parseFromSlice(std.json.Value, self.alloc, json, .{}) catch return Error.BadBatch;
        defer parsed.deinit();
        if (parsed.value != .object) return Error.BadBatch;
        const root = parsed.value.object;

        self.mu.lock();
        defer self.mu.unlock();

        if (root.get("del")) |d| {
            if (d == .array) for (d.array.items) |it| {
                const id = jstr(it) orelse continue;
                const key = self.makeKey(source_id, id) catch return Error.OutOfMemory;
                defer self.alloc.free(key);
                self.removeLocked(key);
            };
        }
        if (root.get("set")) |s| {
            if (s != .array) return Error.BadBatch;
            for (s.array.items) |it| {
                if (it != .object) continue;
                const o = it.object;
                const id = jstr(o.get("id") orelse continue) orelse continue;
                var obj = self.parseObject(o) catch |e| switch (e) {
                    error.OutOfMemory => return Error.OutOfMemory,
                    error.Skip => continue,
                };
                errdefer obj.free(self.alloc);
                const key = self.makeKey(source_id, id) catch return Error.OutOfMemory;
                const gop = self.objs.getOrPut(self.alloc, key) catch {
                    self.alloc.free(key);
                    obj.free(self.alloc);
                    return Error.OutOfMemory;
                };
                if (gop.found_existing) {
                    self.alloc.free(key); // the map already owns an equal key
                    gop.value_ptr.free(self.alloc);
                } else if (self.objs.count() > MAX_OBJECTS) {
                    _ = self.objs.orderedRemove(key);
                    self.alloc.free(key);
                    obj.free(self.alloc);
                    return Error.Budget;
                }
                gop.value_ptr.* = obj;
                self.dirty = true;
                if (obj.ship_anchor) self.has_ship_anchor = true;
            }
        }
    }

    /// Drop every object a source owns — a plugin that stopped, failed or was
    /// disabled must leave nothing on the chart.
    pub fn removeSource(self: *Store, source_id: []const u8) void {
        self.mu.lock();
        defer self.mu.unlock();
        const prefix = self.makeKey(source_id, "") catch return; // "<source>/"
        defer self.alloc.free(prefix);
        var i: usize = 0;
        while (i < self.objs.count()) {
            const k = self.objs.keys()[i];
            if (std.mem.startsWith(u8, k, prefix)) {
                self.objs.values()[i].free(self.alloc);
                self.objs.orderedRemoveAt(i);
                self.alloc.free(k);
                self.dirty = true;
            } else i += 1;
        }
        self.noteShipAnchors();
    }

    fn removeLocked(self: *Store, k: []const u8) void {
        if (self.objs.fetchOrderedRemove(k)) |kv| {
            self.alloc.free(kv.key);
            var v = kv.value;
            v.free(self.alloc);
            self.dirty = true;
            self.noteShipAnchors();
        }
    }

    /// Does anything ride own ship's display position? Recomputed on every
    /// change, so a frame with no rider never rebuilds for a moving boat.
    fn noteShipAnchors(self: *Store) void {
        self.has_ship_anchor = false;
        for (self.objs.values()) |*o| {
            if (o.ship_anchor) {
                self.has_ship_anchor = true;
                return;
            }
        }
    }

    fn makeKey(self: *Store, source_id: []const u8, id: []const u8) ![]u8 {
        return std.fmt.allocPrint(self.alloc, "{s}/{s}", .{ source_id, id });
    }

    fn parseObject(self: *Store, o: std.json.ObjectMap) (error{ OutOfMemory, Skip })!Object {
        const kind = std.meta.stringToEnum(Kind, jstr(o.get("kind") orelse return error.Skip) orelse return error.Skip) orelse return error.Skip;
        const token = std.meta.stringToEnum(Token, jstr(o.get("color") orelse return error.Skip) orelse return error.Skip) orelse return error.Skip;
        var obj = Object{ .kind = kind, .token = token };
        errdefer obj.free(self.alloc);
        if (o.get("anchor")) |a| {
            if (jstr(a)) |name| obj.ship_anchor = std.mem.eql(u8, name, "ownship");
        }
        switch (kind) {
            .symbol => {
                obj.sym = std.meta.stringToEnum(Sym, jstr(o.get("sym") orelse return error.Skip) orelse return error.Skip) orelse return error.Skip;
                obj.at = jpoint(o.get("at") orelse return error.Skip) orelse return error.Skip;
                obj.rot_deg = @floatCast(jnum(o.get("rot_deg")) orelse 0);
                obj.scale = @floatCast(jnum(o.get("scale")) orelse 1);
                if (!(obj.scale > 0.05 and obj.scale < 20)) obj.scale = 1;
                // A malformed pick costs the payload, not the symbol.
                if (o.get("pick")) |p| obj.pick = try self.parsePick(p) orelse &.{};
            },
            .polyline, .polygon => {
                const arr = o.get(if (kind == .polyline) "pts" else "ring") orelse return error.Skip;
                if (arr != .array) return error.Skip;
                const need: usize = if (kind == .polyline) 2 else 3;
                if (arr.array.items.len < need or arr.array.items.len > MAX_POINTS) return error.Skip;
                var pts = try self.alloc.alloc([2]f64, arr.array.items.len);
                errdefer self.alloc.free(pts);
                var n: usize = 0;
                for (arr.array.items) |p| {
                    pts[n] = jpoint(p) orelse return error.Skip;
                    n += 1;
                }
                obj.pts = pts;
                obj.width_pt = @floatCast(jnum(o.get("width_pt")) orelse 1.5);
                if (!(obj.width_pt > 0.1 and obj.width_pt < 64)) obj.width_pt = 1.5;
                obj.dash = jbool(o.get("dash")) orelse false;
                obj.alpha = @floatCast(jnum(o.get("alpha")) orelse 1);
                obj.alpha = std.math.clamp(obj.alpha, 0, 1);
            },
        }
        return obj;
    }

    // ---- pick payloads ----------------------------------------------------

    /// Validate a posted `pick` and re-emit it as canonical JSON:
    /// `{"title":"...","rows":[["k","v"],...]}`. Anything that is not a string
    /// is dropped; every string is escaped and capped. Null when nothing is
    /// left. Re-emitted rather than kept verbatim: the parser gives no source
    /// spans.
    fn parsePick(self: *Store, v: std.json.Value) error{OutOfMemory}!?[]u8 {
        if (v != .object) return null;
        const title = if (v.object.get("title")) |ttl| jstr(ttl) orelse "" else "";
        const rows: []std.json.Value = if (v.object.get("rows")) |r|
            (if (r == .array) r.array.items else &.{})
        else
            &.{};
        if (title.len == 0 and rows.len == 0) return null;

        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(self.alloc);
        try out.appendSlice(self.alloc, "{\"title\":");
        try self.jsonStr(&out, clip(title));
        try out.appendSlice(self.alloc, ",\"rows\":[");
        var n: usize = 0;
        for (rows) |row| {
            if (n == MAX_PICK_ROWS) break;
            if (row != .array or row.array.items.len < 2) continue;
            const k = jstr(row.array.items[0]) orelse continue;
            const val = jstr(row.array.items[1]) orelse continue;
            if (n > 0) try out.append(self.alloc, ',');
            n += 1;
            try out.append(self.alloc, '[');
            try self.jsonStr(&out, clip(k));
            try out.append(self.alloc, ',');
            try self.jsonStr(&out, clip(val));
            try out.append(self.alloc, ']');
        }
        try out.appendSlice(self.alloc, "]}");
        return try out.toOwnedSlice(self.alloc);
    }

    /// One JSON string literal, escaped. Control bytes go out as \u00xx.
    fn jsonStr(self: *Store, out: *std.ArrayList(u8), s: []const u8) error{OutOfMemory}!void {
        const hex = "0123456789abcdef";
        try out.append(self.alloc, '"');
        for (s) |c| switch (c) {
            '"' => try out.appendSlice(self.alloc, "\\\""),
            '\\' => try out.appendSlice(self.alloc, "\\\\"),
            0x08 => try out.appendSlice(self.alloc, "\\b"),
            0x0c => try out.appendSlice(self.alloc, "\\f"),
            '\n' => try out.appendSlice(self.alloc, "\\n"),
            '\r' => try out.appendSlice(self.alloc, "\\r"),
            '\t' => try out.appendSlice(self.alloc, "\\t"),
            else => if (c < 0x20) {
                try out.appendSlice(self.alloc, "\\u00");
                try out.append(self.alloc, hex[(c >> 4) & 0xf]);
                try out.append(self.alloc, hex[c & 0xf]);
            } else try out.append(self.alloc, c),
        };
        try out.append(self.alloc, '"');
    }

    /// What a hit test answers with. Borrowed: valid until the next hit test
    /// or info lookup. `id` is the host-namespaced object id, NUL-terminated
    /// so a C shell can hand it straight back to `infoFor`.
    pub const Hit = struct { id: [:0]const u8, info: []const u8, at: [2]f64 };

    /// The nearest SYMBOL carrying a pick payload whose anchor falls inside
    /// `PICK_RADIUS_PT` of a logical point, or null. Anchors are projected
    /// with the renderer's own camera, so rotation and the antimeridian hold.
    /// Symbols only: a line or an area has no single point to measure to.
    pub fn hitAt(self: *Store, cam: camera.Camera, x_pt: f32, y_pt: f32, ship: ?[2]f64) ?Hit {
        self.mu.lock();
        defer self.mu.unlock();
        var best: ?usize = null;
        var best_d2: f64 = PICK_RADIUS_PT * PICK_RADIUS_PT;
        for (self.objs.values(), 0..) |*o, i| {
            if (o.kind != .symbol or o.pick.len == 0) continue;
            const s = cam.worldToScreen(geo(effAt(o, ship)));
            const dx = s.x - @as(f64, x_pt);
            const dy = s.y - @as(f64, y_pt);
            const d2 = dx * dx + dy * dy;
            // Strictly nearer, so a tie keeps the earlier object.
            if (d2 < best_d2) {
                best_d2 = d2;
                best = i;
            }
        }
        return self.hitLocked(best orelse return null, ship);
    }

    /// The same answer for an object already known by id, or null when it is
    /// gone. A shell that pinned a target asks each frame: the payload moves
    /// with new data and the anchor moves with the target.
    pub fn infoFor(self: *Store, id: []const u8, ship: ?[2]f64) ?Hit {
        self.mu.lock();
        defer self.mu.unlock();
        return self.hitLocked(self.objs.getIndex(id) orelse return null, ship);
    }

    fn hitLocked(self: *Store, i: usize, ship: ?[2]f64) ?Hit {
        const o = &self.objs.values()[i];
        self.pick_out.clearRetainingCapacity();
        self.pick_out.appendSlice(self.alloc, o.pick) catch return null;
        self.id_out.clearRetainingCapacity();
        self.id_out.appendSlice(self.alloc, self.objs.keys()[i]) catch return null;
        self.id_out.append(self.alloc, 0) catch return null;
        const id = self.id_out.items[0 .. self.id_out.items.len - 1 :0];
        return .{ .id = id, .info = self.pick_out.items, .at = effAt(o, ship) };
    }

    /// Borrowed: valid until the next call. The payload alone, for hover.
    pub fn pickAt(self: *Store, cam: camera.Camera, x_pt: f32, y_pt: f32, ship: ?[2]f64) ?[]const u8 {
        const h = self.hitAt(cam, x_pt, y_pt, ship) orelse return null;
        return h.info;
    }

    // ---- the geometry -----------------------------------------------------

    /// Where an object actually draws: own ship's display position when it
    /// declared that anchor and the core has one, else the posted lon/lat.
    fn effAt(o: *const Object, ship: ?[2]f64) [2]f64 {
        if (o.ship_anchor) {
            if (ship) |s| return s;
        }
        return o.at;
    }

    /// True when the vertex array no longer matches (zoom, scheme, own ship's
    /// display position) or an apply has landed since the last build.
    pub fn needsRebuild(self: *Store, zoom: f64, scheme: Scheme, ship: ?[2]f64) bool {
        self.mu.lock();
        defer self.mu.unlock();
        return self.needsRebuildLocked(zoom, scheme, ship);
    }

    fn needsRebuildLocked(self: *Store, zoom: f64, scheme: Scheme, ship: ?[2]f64) bool {
        if (!self.has_build or self.dirty) return true;
        if (scheme != self.built_scheme) return true;
        if (self.has_ship_anchor and !samePoint(ship, self.built_ship)) return true;
        return @abs(zoom - self.built_zoom) > ZOOM_REBUILD_DZ;
    }

    /// Render-thread entry: rebuild if needed and return the current frame.
    /// The returned slice is valid until the next call.
    pub fn buildIfNeeded(self: *Store, zoom: f64, scheme: Scheme, ship: ?[2]f64) Error!Frame {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.needsRebuildLocked(zoom, scheme, ship)) try self.buildLocked(zoom, scheme, ship);
        return .{ .verts = self.verts.items, .generation = self.gen };
    }

    fn buildLocked(self: *Store, zoom: f64, scheme: Scheme, ship: ?[2]f64) Error!void {
        self.verts.clearRetainingCapacity();
        const wpp = worldPerPt(zoom);
        // Paint order: areas, then lines, then symbols. A track must not cover
        // the boat, and a warning area must not cover either.
        for ([3]Kind{ .polygon, .polyline, .symbol }) |pass| {
            for (self.objs.values()) |*o| {
                if (o.kind != pass) continue;
                var c = resolve(o.token, scheme);
                switch (o.kind) {
                    .polygon => {
                        c[3] *= o.alpha;
                        try self.emitPolygon(o.pts, c);
                    },
                    // A ship-anchored line keeps its shape and travels with
                    // its first point, so the heading line and the speed
                    // vector stay attached to the hull between fixes.
                    .polyline => try self.emitPolyline(o.pts, @as(f64, o.width_pt) * wpp, o.dash, wpp, c, lineShift(o, ship)),
                    .symbol => try self.emitSymbol(o, effAt(o, ship), wpp, c),
                }
            }
        }
        self.gen += 1;
        self.dirty = false;
        self.has_build = true;
        self.built_zoom = zoom;
        self.built_scheme = scheme;
        self.built_ship = ship;
    }

    /// How far a ship-anchored polyline moves: its first point to own ship's
    /// display position, in lon/lat. Zero for every other line.
    fn lineShift(o: *const Object, ship: ?[2]f64) [2]f64 {
        if (!o.ship_anchor or o.pts.len == 0) return .{ 0, 0 };
        const s = ship orelse return .{ 0, 0 };
        return .{ s[0] - o.pts[0][0], s[1] - o.pts[0][1] };
    }

    fn push(self: *Store, w: camera.Vec2, c: Rgba) Error!void {
        try self.verts.append(self.alloc, .{
            .x = @floatCast(w.x),
            .y = @floatCast(w.y),
            .r = c[0],
            .g = c[1],
            .b = c[2],
            .a = c[3],
        });
    }

    fn tri(self: *Store, a: camera.Vec2, b: camera.Vec2, d: camera.Vec2, c: Rgba) Error!void {
        try self.push(a, c);
        try self.push(b, c);
        try self.push(d, c);
    }

    /// Fan-triangulate a ring. Convex assumption (prototype): a concave ring
    /// draws its hull's wedges too.
    fn emitPolygon(self: *Store, pts: [][2]f64, c: Rgba) Error!void {
        if (pts.len < 3) return;
        const a = geo(pts[0]);
        var i: usize = 1;
        while (i + 1 < pts.len) : (i += 1) {
            try self.tri(a, geo(pts[i]), geo(pts[i + 1]), c);
        }
    }

    /// One quad per segment, `w_world` wide, mitre-less: at prototype line
    /// widths (1–3 pt) a butt join is invisible, and a mitre needs a join pass
    /// that would double the vertex count.
    fn emitPolyline(self: *Store, pts: [][2]f64, w_world: f64, dash: bool, wpp: f64, c: Rgba, shift: [2]f64) Error!void {
        if (pts.len < 2) return;
        const hw = w_world * 0.5;
        const on = DASH_ON * wpp;
        const period = (DASH_ON + DASH_OFF) * wpp;
        var phase: f64 = 0; // distance along the whole line, so dashes run through vertices
        var i: usize = 0;
        while (i + 1 < pts.len) : (i += 1) {
            const a = geo(.{ pts[i][0] + shift[0], pts[i][1] + shift[1] });
            const b = geo(.{ pts[i + 1][0] + shift[0], pts[i + 1][1] + shift[1] });
            const dx = b.x - a.x;
            const dy = b.y - a.y;
            const len = @sqrt(dx * dx + dy * dy);
            if (!(len > 0)) continue;
            // Draw solid when the pattern cannot show: a zero or absent period, or
            // a segment so long at this zoom that its dashes are sub-pixel — the
            // cut loop would otherwise emit millions of invisible quads.
            const solid = !dash or !(period > 0) or len / period > MAX_DASHES_PER_SEG;
            if (solid) {
                try self.quad(a, b, dx / len, dy / len, hw, c);
                phase += len;
                continue;
            }
            // Walk the segment, cutting at the dash boundaries. Every step must
            // ADVANCE: a run shorter than d's own ULP leaves d unchanged, and
            // the loop then never ends (seen as an out-of-memory kill, not a
            // hang, because each turn appends a quad).
            var d: f64 = 0;
            while (d < len) {
                const cyc = @mod(phase + d, period);
                const run = @min(if (cyc < on) on - cyc else period - cyc, len - d);
                if (!(run > 0)) break;
                if (cyc < on) {
                    const p0 = camera.Vec2{ .x = a.x + dx * (d / len), .y = a.y + dy * (d / len) };
                    const p1 = camera.Vec2{ .x = a.x + dx * ((d + run) / len), .y = a.y + dy * ((d + run) / len) };
                    try self.quad(p0, p1, dx / len, dy / len, hw, c);
                }
                const next = d + run;
                if (!(next > d)) break;
                d = next;
            }
            phase += len;
        }
    }

    fn quad(self: *Store, a: camera.Vec2, b: camera.Vec2, ux: f64, uy: f64, hw: f64, c: Rgba) Error!void {
        const nx = -uy * hw;
        const ny = ux * hw;
        const p0 = camera.Vec2{ .x = a.x + nx, .y = a.y + ny };
        const p1 = camera.Vec2{ .x = b.x + nx, .y = b.y + ny };
        const p2 = camera.Vec2{ .x = b.x - nx, .y = b.y - ny };
        const p3 = camera.Vec2{ .x = a.x - nx, .y = a.y - ny };
        try self.tri(p0, p1, p2, c);
        try self.tri(p0, p2, p3, c);
    }

    fn emitSymbol(self: *Store, o: *const Object, at_geo: [2]f64, wpp: f64, c: Rgba) Error!void {
        const at = geo(at_geo);
        const s = wpp * @as(f64, o.scale);
        // True bearing -> world direction: world y runs SOUTH, so north is -y.
        const th = @as(f64, o.rot_deg) * std.math.pi / 180.0;
        const fx = std.math.sin(th); // unit vector along the heading
        const fy = -std.math.cos(th);
        switch (o.sym) {
            .ownship => {
                const len = ownshipLenWorld(at_geo[1], wpp, o.scale);
                const half_beam = len * OWNSHIP_BEAM_RATIO * 0.5;
                const px = -fy; // starboard unit vector
                const py = fx;
                var pts: [HULL.len]camera.Vec2 = undefined;
                for (HULL, &pts) |h, *p| {
                    const along = h[0] * len;
                    const across = h[1] * half_beam;
                    p.* = .{
                        .x = at.x + fx * along + px * across,
                        .y = at.y + fy * along + py * across,
                    };
                }
                var i: usize = 1;
                while (i + 1 < pts.len) : (i += 1) {
                    try self.tri(pts[0], pts[i], pts[i + 1], c);
                }
            },
            .target => {
                const px = -fy;
                const py = fx;
                const tip = camera.Vec2{ .x = at.x + fx * TARGET_TIP * s, .y = at.y + fy * TARGET_TIP * s };
                const l = camera.Vec2{
                    .x = at.x - fx * TARGET_TAIL * s - px * TARGET_HALF * s,
                    .y = at.y - fy * TARGET_TAIL * s - py * TARGET_HALF * s,
                };
                const r = camera.Vec2{
                    .x = at.x - fx * TARGET_TAIL * s + px * TARGET_HALF * s,
                    .y = at.y - fy * TARGET_TAIL * s + py * TARGET_HALF * s,
                };
                try self.tri(l, tip, r, c);
            },
        }
    }
};

/// Clip a payload string to `MAX_PICK_TEXT`, on a UTF-8 boundary.
fn clip(s: []const u8) []const u8 {
    if (s.len <= MAX_PICK_TEXT) return s;
    var n: usize = MAX_PICK_TEXT;
    while (n > 0 and (s[n] & 0xc0) == 0x80) n -= 1;
    return s[0..n];
}

/// lon/lat -> web-mercator world [0,1]. The chart's own transform: overlay
/// geometry and chart geometry must land in the same space to the last bit.
/// Two optional lon/lat points, compared exactly. A display position that has
/// not changed must not force a rebuild.
fn samePoint(a: ?[2]f64, b: ?[2]f64) bool {
    if (a == null and b == null) return true;
    const x = a orelse return false;
    const y = b orelse return false;
    return x[0] == y[0] and x[1] == y[1];
}

/// Screen distance between two projected points, in logical points.
fn dist(a: camera.Vec2, b: camera.Vec2) f64 {
    return std.math.hypot(a.x - b.x, a.y - b.y);
}

pub fn geo(lonlat: [2]f64) camera.Vec2 {
    return camera.lonLatToWorld(lonlat[0], lonlat[1]);
}

/// World units per screen POINT at `zoom` — 256 px per tile, the reciprocal of
/// camera.worldToPx (whose vw/vh are logical points, so this is too).
pub fn worldPerPt(zoom: f64) f64 {
    return 1.0 / (256.0 * std.math.pow(f64, 2.0, zoom));
}

/// The own-ship symbol's length in world units: the greater of true scale and
/// the 6 mm floor, times the plugin's own `scale`. Both candidates are
/// lengths, so the shape does not change across the crossover.
pub fn ownshipLenWorld(lat_deg: f64, wpp: f64, scale: f64) f64 {
    return @max(OWNSHIP_LOA_M * worldPerMetre(lat_deg), OWNSHIP_MIN_LEN_PT * wpp) * scale;
}

/// World units per metre on the ground at `lat_deg`. Web mercator is
/// conformal, so a world unit spans the equator's circumference times
/// cos(latitude). The cosine is floored to keep a polar position finite.
pub fn worldPerMetre(lat_deg: f64) f64 {
    const c = @abs(std.math.cos(lat_deg * std.math.pi / 180.0));
    return 1.0 / (EARTH_CIRCUMFERENCE_M * @max(c, 1.0e-6));
}

// ---- JSON helpers ----------------------------------------------------------

fn jstr(v: std.json.Value) ?[]const u8 {
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn jnum(v: ?std.json.Value) ?f64 {
    const val = v orelse return null;
    return switch (val) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => null,
    };
}

fn jbool(v: ?std.json.Value) ?bool {
    const val = v orelse return null;
    return switch (val) {
        .bool => |b| b,
        else => null,
    };
}

/// `[lon, lat]`, both finite and in range.
fn jpoint(v: std.json.Value) ?[2]f64 {
    if (v != .array or v.array.items.len < 2) return null;
    const lon = jnum(v.array.items[0]) orelse return null;
    const lat = jnum(v.array.items[1]) orelse return null;
    if (!std.math.isFinite(lon) or !std.math.isFinite(lat)) return null;
    if (@abs(lon) > 360 or @abs(lat) > 85.06) return null;
    return .{ lon, lat };
}

// ---- tests -----------------------------------------------------------------

const t = std.testing;

test "geo matches camera.zig and known mercator values" {
    // Hand-computed web-mercator for Annapolis harbour and the origin.
    const a = geo(.{ -76.4767, 38.9763 });
    try t.expectApproxEqAbs(@as(f64, 0.28756472222222224), a.x, 1e-15);
    try t.expectApproxEqAbs(@as(f64, 0.38226387137161233), a.y, 1e-15);
    const o = geo(.{ 0, 0 });
    try t.expectApproxEqAbs(@as(f64, 0.5), o.x, 1e-15);
    try t.expectApproxEqAbs(@as(f64, 0.5), o.y, 1e-15);
    // ...and it IS the camera's transform, for every point the prototype uses.
    for ([_][2]f64{ .{ -76.4767, 38.9763 }, .{ -76.48, 38.98 }, .{ 179.9, -35.2 }, .{ 0, 0 } }) |p| {
        const g = geo(p);
        const cw = camera.lonLatToWorld(p[0], p[1]);
        try t.expectEqual(cw.x, g.x);
        try t.expectEqual(cw.y, g.y);
    }
}

test "apply set/del and per-source namespacing" {
    var s = Store.init(t.allocator);
    defer s.deinit();

    try s.applyBatch("plug.a",
        \\{"set":[{"id":"boat","kind":"symbol","sym":"ownship","at":[-76.48,38.98],"rot_deg":90,"color":"ownship"}]}
    );
    try s.applyBatch("plug.b",
        \\{"set":[{"id":"boat","kind":"symbol","sym":"target","at":[-76.47,38.97],"color":"target"}]}
    );
    // Same object id, different sources: two objects, not one.
    try t.expectEqual(@as(usize, 2), s.count());
    try t.expect(s.objs.contains("plug.a/boat"));
    try t.expect(s.objs.contains("plug.b/boat"));

    // A set with a known id REPLACES.
    try s.applyBatch("plug.a",
        \\{"set":[{"id":"boat","kind":"symbol","sym":"target","at":[-76.40,38.90],"color":"target_danger"}]}
    );
    try t.expectEqual(@as(usize, 2), s.count());
    try t.expectEqual(Token.target_danger, s.objs.get("plug.a/boat").?.token);

    // del is namespaced too: plug.b cannot delete plug.a's object.
    try s.applyBatch("plug.b", "{\"del\":[\"boat\"]}");
    try t.expectEqual(@as(usize, 1), s.count());
    try t.expect(s.objs.contains("plug.a/boat"));

    // removeSource takes everything that source owns.
    try s.applyBatch("plug.a",
        \\{"set":[{"id":"trk","kind":"polyline","pts":[[-76.5,38.9],[-76.4,38.95]],"width_pt":2,"color":"track"}]}
    );
    try t.expectEqual(@as(usize, 2), s.count());
    s.removeSource("plug.a");
    try t.expectEqual(@as(usize, 0), s.count());
}

test "malformed rows are skipped, malformed batches rejected" {
    var s = Store.init(t.allocator);
    defer s.deinit();
    try t.expectError(Error.BadBatch, s.applyBatch("p", "not json"));
    try t.expectError(Error.BadBatch, s.applyBatch("p", "[1,2]"));
    // Unknown colour token, unknown kind, missing geometry, bad point: all
    // dropped; the good row in the same batch survives.
    try s.applyBatch("p",
        \\{"set":[
        \\ {"id":"a","kind":"symbol","sym":"ownship","at":[-76.4,38.9],"color":"chartreuse"},
        \\ {"id":"b","kind":"hologram","color":"warning"},
        \\ {"id":"c","kind":"polyline","color":"track"},
        \\ {"id":"d","kind":"polyline","pts":[[-76.4,38.9],[-999,38.9]],"color":"track"},
        \\ {"id":"e","kind":"symbol","sym":"target","at":[-76.4,38.9],"color":"target"}]}
    );
    try t.expectEqual(@as(usize, 1), s.count());
    try t.expect(s.objs.contains("p/e"));
}

// Rule 8: the symbol and its lines ride own ship's display position, so the
// boat sits still on screen between fixes while the chart slides.
test "a ship anchor moves the symbol and its line, not the rest" {
    var s = Store.init(t.allocator);
    defer s.deinit();
    try s.applyBatch("p",
        \\{"set":[{"id":"o","kind":"symbol","sym":"ownship","at":[-76.4767,38.9763],"anchor":"ownship","rot_deg":0,"color":"ownship"},
        \\ {"id":"hdg","kind":"polyline","pts":[[-76.4767,38.9763],[-76.4767,38.9863]],"anchor":"ownship","color":"ownship"},
        \\ {"id":"t","kind":"symbol","sym":"target","at":[-76.4767,38.9763],"color":"target"}]}
    );
    try t.expect(s.has_ship_anchor);

    const base = try s.buildIfNeeded(15.0, .day, null);
    const fixed = try t.allocator.dupe(Vertex, base.verts);
    defer t.allocator.free(fixed);

    // The same frame with the boat carried 0.001 degrees north.
    const ship = [2]f64{ -76.4767, 38.9773 };
    try t.expect(s.needsRebuild(15.0, .day, ship));
    const moved = try s.buildIfNeeded(15.0, .day, ship);
    try t.expectEqual(fixed.len, moved.verts.len);
    const dy = geo(ship).y - geo(.{ -76.4767, 38.9763 }).y;

    var shifted: usize = 0;
    var still: usize = 0;
    for (fixed, moved.verts) |a, b| {
        if (@abs(b.y - (a.y + @as(f32, @floatCast(dy)))) < 1e-9 and @abs(b.x - a.x) < 1e-9) {
            shifted += 1;
        } else if (a.x == b.x and a.y == b.y) still += 1;
    }
    // Every vertex of the boat and its heading line moved by the same delta;
    // the target's triangle did not move at all.
    try t.expectEqual(@as(usize, TARGET_VERTS), still);
    try t.expectEqual(fixed.len - TARGET_VERTS, shifted);

    // The same position twice is not a rebuild.
    try t.expect(!s.needsRebuild(15.0, .day, ship));
}

// Line expansion is pure world space and the camera only rotates the MVP, so
// a dashed line must measure the same on screen at every view rotation and at
// every bearing. Angle-dependent breakage (a quadrant term in the dash or
// perpendicular math, or a per-vertex wrap decision) shows as a failing
// (bearing, rotation) pair. The sweep is 24 x 24 and pure vertex math.
test "a dashed line keeps its width and dashes at every angle" {
    // Zoom 12: overlay vertices are absolute world coordinates in f32, whose
    // step here is 0.03 pt. Deeper zooms coarsen that (0.25 pt at z15) and
    // would swamp the measurement.
    const zoom: f64 = 12;
    const width_pt: f64 = 3.0;
    const lat0: f64 = 38.9763;
    const lon0: f64 = -76.4767;
    const m_per_deg = 40075016.685578488 / 360.0;

    var deg: f64 = 0;
    while (deg < 360) : (deg += 15) {
        var s = Store.init(t.allocator);
        defer s.deinit();
        // 5 km on this bearing, which is about 170 pt and a dozen dashes.
        const th = deg * std.math.pi / 180.0;
        const lat1 = lat0 + 5000.0 * @cos(th) / m_per_deg;
        const lon1 = lon0 + 5000.0 * @sin(th) / (m_per_deg * @cos(lat0 * std.math.pi / 180.0));
        var buf: [256]u8 = undefined;
        const batch = try std.fmt.bufPrint(&buf, "{{\"set\":[{{\"id\":\"v\",\"kind\":\"polyline\",\"pts\":[[{d},{d}],[{d},{d}]]," ++
            "\"width_pt\":3.0,\"dash\":true,\"color\":\"ownship\"}}]}}", .{ lon0, lat0, lon1, lat1 });
        try s.applyBatch("p", batch);
        const fr = try s.buildIfNeeded(zoom, .day, null);
        const quads = fr.verts.len / 6;
        try t.expect(quads >= 8);

        const origin = geo(.{ lon0, lat0 });
        var rot: f64 = 0;
        while (rot < 360) : (rot += 15) {
            var cam = camera.Camera{
                .origin = origin,
                .center = origin,
                .zoom = zoom,
                .target_zoom = zoom,
                .rotation = rot * std.math.pi / 180.0,
                .vw = 1200,
                .vh = 800,
            };
            var i: usize = 0;
            while (i < quads) : (i += 1) {
                const v = fr.verts[i * 6 ..][0..6];
                const p0 = camera.Vec2{ .x = v[0].x, .y = v[0].y };
                const p1 = camera.Vec2{ .x = v[1].x, .y = v[1].y };
                const p3 = camera.Vec2{ .x = v[5].x, .y = v[5].y };
                const w = dist(cam.worldToScreen(p0), cam.worldToScreen(p3));
                const l = dist(cam.worldToScreen(p0), cam.worldToScreen(p1));
                t.expectApproxEqAbs(width_pt, w, 0.15) catch |e| {
                    std.debug.print("width failed at bearing {d} rot {d} quad {d}\n", .{ deg, rot, i });
                    return e;
                };
                if (i + 1 < quads) t.expectApproxEqAbs(DASH_ON, l, 0.2) catch |e| {
                    std.debug.print("dash failed at bearing {d} rot {d} quad {d}\n", .{ deg, rot, i });
                    return e;
                };
            }
        }
    }
}

test "symbol expansion vertex counts and orientation" {
    var s = Store.init(t.allocator);
    defer s.deinit();
    try s.applyBatch("p",
        \\{"set":[{"id":"o","kind":"symbol","sym":"ownship","at":[-76.4767,38.9763],"rot_deg":0,"color":"ownship"}]}
    );
    var fr = try s.buildIfNeeded(15.0, .day, null);
    try t.expectEqual(@as(usize, OWNSHIP_VERTS), fr.verts.len);
    try t.expectEqual(@as(usize, 15), fr.verts.len); // 7 hull points, fanned

    // The hull fans from HULL[0]: triangles (0,1,2) (0,2,3) (0,3,4) (0,4,5)
    // (0,5,6), so HULL[4], the stem, lands at vertex 8. Heading 0 puts the
    // stem north of the anchor, which in world space (y down) is a smaller y.
    const at = geo(.{ -76.4767, 38.9763 });
    const stem_n = fr.verts[8];
    try t.expect(@as(f64, stem_n.y) < at.y);
    try t.expectApproxEqAbs(@as(f32, @floatCast(at.x)), stem_n.x, 1e-9);
    // The transom corners are astern of it.
    try t.expect(@as(f64, fr.verts[0].y) > at.y);
    try t.expect(@as(f64, fr.verts[1].y) > at.y);

    // Heading 90 (east) puts the stem to the RIGHT, at the same latitude.
    try s.applyBatch("p",
        \\{"set":[{"id":"o","kind":"symbol","sym":"ownship","at":[-76.4767,38.9763],"rot_deg":90,"color":"ownship"}]}
    );
    fr = try s.buildIfNeeded(15.0, .day, null);
    const stem_e = fr.verts[8];
    try t.expect(@as(f64, stem_e.x) > at.x);
    try t.expectApproxEqAbs(@as(f32, @floatCast(at.y)), stem_e.y, 1e-9);

    // A target is one triangle; two objects add up.
    try s.applyBatch("p",
        \\{"set":[{"id":"t1","kind":"symbol","sym":"target","at":[-76.47,38.97],"rot_deg":210,"color":"target"}]}
    );
    fr = try s.buildIfNeeded(15.0, .day, null);
    try t.expectEqual(@as(usize, OWNSHIP_VERTS + TARGET_VERTS), fr.verts.len);
}

test "the own-ship hull is a ship, at true scale once that is legible" {
    var s = Store.init(t.allocator);
    defer s.deinit();
    const lat: f64 = 38.9763;
    try s.applyBatch("p",
        \\{"set":[{"id":"o","kind":"symbol","sym":"ownship","at":[-76.4767,38.9763],"rot_deg":0,"color":"ownship"}]}
    );

    // Vertex 8 is the stem and vertices 0/1 the transom corners, so length and
    // beam are measurable off the built triangles.
    const measure = struct {
        fn go(fr: Frame) struct { len: f64, beam: f64 } {
            const stem_y = @as(f64, fr.verts[8].y);
            const transom_y = @as(f64, fr.verts[0].y);
            return .{
                .len = transom_y - stem_y,
                .beam = @abs(@as(f64, fr.verts[1].x) - @as(f64, fr.verts[0].x)),
            };
        }
    }.go;

    // The rule, in f64. Below the crossover the floor governs and the symbol
    // holds its point size. Above it, true scale governs and the symbol holds
    // its size on the ground.
    const floor15 = OWNSHIP_MIN_LEN_PT * worldPerPt(15.0);
    const truth = OWNSHIP_LOA_M * worldPerMetre(lat);
    try t.expectEqual(floor15, ownshipLenWorld(lat, worldPerPt(15.0), 1));
    try t.expect(floor15 > truth); // at zoom 15 a 12 m boat is sub-millimetre
    try t.expectEqual(floor15 * 0.5, ownshipLenWorld(lat, worldPerPt(16.0), 1));
    try t.expectEqual(truth, ownshipLenWorld(lat, worldPerPt(20.0), 1));
    try t.expectEqual(truth, ownshipLenWorld(lat, worldPerPt(21.0), 1)); // ground-fixed
    // The crossover: the zoom at which 12 m first covers the floor.
    const crossover = std.math.log2(OWNSHIP_MIN_LEN_PT / (256.0 * truth));
    try t.expectApproxEqAbs(@as(f64, 18.0), crossover, 0.1);
    try t.expectEqual(truth * 2.0, ownshipLenWorld(lat, worldPerPt(20.0), 2));

    // The built triangles follow that rule. Tolerance is the f32 vertex grid,
    // not the maths: world coordinates are ~0.38 here, where one f32 step is
    // 3.0e-8, and each measurement is a difference of two of them.
    const grid = 4.0 * 2.98e-8;
    const low = measure(try s.buildIfNeeded(15.0, .day, null));
    try t.expectApproxEqAbs(floor15, low.len, grid);
    // Beam holds its fraction of length, and the stem is narrower than the
    // shoulders: a ship, not a box.
    try t.expectApproxEqAbs(low.len * OWNSHIP_BEAM_RATIO, low.beam, grid);
    try t.expect(low.beam < low.len);
}

test "worldPerMetre is the chart's own scale, and finite at the pole" {
    // Checked against the transform the overlay geometry uses, at Annapolis.
    const lat: f64 = 38.9763;
    const east = geo(.{ -76.4767 + 1.0e-4, lat });
    const home = geo(.{ -76.4767, lat });
    const world_per_deg_lon = (east.x - home.x) / 1.0e-4;
    const m_per_deg_lon = world_per_deg_lon / worldPerMetre(lat);
    // ~86.5 km per degree of longitude at 39 N.
    try t.expectApproxEqRel(@as(f64, 86545.0), m_per_deg_lon, 1e-3);
    // The cosine floor keeps a polar boat finite rather than infinite.
    try t.expect(std.math.isFinite(worldPerMetre(90.0)));
    try t.expect(worldPerMetre(90.0) > 0);
}

test "a pick payload survives the round trip, escaped and capped" {
    var s = Store.init(t.allocator);
    defer s.deinit();
    try s.applyBatch("p",
        \\{"set":[{"id":"t1","kind":"symbol","sym":"target","at":[-76.47,38.97],"color":"target",
        \\ "pick":{"title":"EVER \"GIVEN\"","rows":[["MMSI","366123456"],["SOG","9.9 kn"]]}}]}
    );
    const got = s.objs.get("p/t1").?.pick;
    try t.expectEqualStrings(
        \\{"title":"EVER \"GIVEN\"","rows":[["MMSI","366123456"],["SOG","9.9 kn"]]}
    , got);

    // A control byte cannot break the shape, and the result parses back.
    try s.applyBatch("p", "{\"set\":[{\"id\":\"t2\",\"kind\":\"symbol\",\"sym\":\"target\"," ++
        "\"at\":[-76.47,38.97],\"color\":\"target\"," ++
        "\"pick\":{\"title\":\"a\\u0007b\",\"rows\":[[\"k\",\"v\"]]}}]}");
    const raw = s.objs.get("p/t2").?.pick;
    try t.expect(std.mem.indexOf(u8, raw, "\\u0007") != null);
    var parsed = try std.json.parseFromSlice(std.json.Value, t.allocator, raw, .{});
    defer parsed.deinit();
    try t.expectEqualStrings("a\x07b", parsed.value.object.get("title").?.string);

    // Rows that are not two strings are dropped. The good ones survive.
    try s.applyBatch("p",
        \\{"set":[{"id":"t3","kind":"symbol","sym":"target","at":[-76.47,38.97],"color":"target",
        \\ "pick":{"title":"x","rows":[["ok","1"],["short"],[3,4],["ok2","2"]]}}]}
    );
    try t.expectEqualStrings(
        \\{"title":"x","rows":[["ok","1"],["ok2","2"]]}
    , s.objs.get("p/t3").?.pick);

    // No pick, or an empty one, leaves the object out of the hit test.
    try s.applyBatch("p",
        \\{"set":[{"id":"t4","kind":"symbol","sym":"target","at":[-76.47,38.97],"color":"target"},
        \\ {"id":"t5","kind":"symbol","sym":"target","at":[-76.47,38.97],"color":"target","pick":{"rows":[]}}]}
    );
    try t.expectEqual(@as(usize, 0), s.objs.get("p/t4").?.pick.len);
    try t.expectEqual(@as(usize, 0), s.objs.get("p/t5").?.pick.len);
}

test "hit test: inside the radius, nearest wins, empty answers nothing" {
    var s = Store.init(t.allocator);
    defer s.deinit();

    // A north-up camera at zoom 15 over Annapolis, 800x600 logical points.
    const centre = geo(.{ -76.4767, 38.9763 });
    var cam = camera.Camera{
        .origin = centre,
        .center = centre,
        .zoom = 15.0,
        .vw = 800,
        .vh = 600,
    };
    const mid_x: f32 = 400;
    const mid_y: f32 = 300;

    // Nothing retained: nothing to report.
    try t.expectEqual(@as(?[]const u8, null), s.pickAt(cam, mid_x, mid_y, null));

    // One target under the centre of the view.
    try s.applyBatch("p",
        \\{"set":[{"id":"t1","kind":"symbol","sym":"target","at":[-76.4767,38.9763],"color":"target",
        \\ "pick":{"title":"ONE","rows":[["MMSI","1"]]}}]}
    );
    const hit = s.pickAt(cam, mid_x, mid_y, null) orelse return error.TestExpectedHit;
    try t.expect(std.mem.indexOf(u8, hit, "\"ONE\"") != null);

    // Just inside the radius answers; just outside does not.
    try t.expect(s.pickAt(cam, mid_x + 13, mid_y, null) != null);
    try t.expect(s.pickAt(cam, mid_x + 15, mid_y, null) == null);
    try t.expect(s.pickAt(cam, mid_x, mid_y - 13, null) != null);
    try t.expect(s.pickAt(cam, mid_x + 200, mid_y, null) == null);

    // A second target 20 pt east of the first. Between them the nearer one
    // answers, on either side of the midpoint. Insertion order does not decide.
    const east_20pt = camera.Vec2{ .x = centre.x + 20.0 * worldPerPt(15.0), .y = centre.y };
    const ll = camera.worldToLonLat(east_20pt);
    var buf: [256]u8 = undefined;
    try s.applyBatch("p", try std.fmt.bufPrint(&buf,
        \\{{"set":[{{"id":"t2","kind":"symbol","sym":"target","at":[{d:.9},{d:.9}],"color":"target",
        \\ "pick":{{"title":"TWO","rows":[["MMSI","2"]]}}}}]}}
    , .{ ll.x, ll.y }));
    try t.expect(std.mem.indexOf(u8, s.pickAt(cam, mid_x + 8, mid_y, null).?, "\"ONE\"") != null);
    try t.expect(std.mem.indexOf(u8, s.pickAt(cam, mid_x + 12, mid_y, null).?, "\"TWO\"") != null);

    // A symbol without a payload is not a hit, even under the cursor.
    s.removeSource("p");
    try s.applyBatch("p",
        \\{"set":[{"id":"o","kind":"symbol","sym":"ownship","at":[-76.4767,38.9763],"color":"ownship"}]}
    );
    try t.expectEqual(@as(?[]const u8, null), s.pickAt(cam, mid_x, mid_y, null));

    // Neither is a polyline that happens to pass under the cursor.
    try s.applyBatch("p",
        \\{"set":[{"id":"l","kind":"polyline","pts":[[-76.48,38.9763],[-76.47,38.9763]],"color":"track",
        \\ "pick":{"title":"LINE","rows":[["a","b"]]}}]}
    );
    try t.expectEqual(@as(?[]const u8, null), s.pickAt(cam, mid_x, mid_y, null));

    // The camera is the renderer's: panning the view moves what answers.
    s.removeSource("p");
    try s.applyBatch("p",
        \\{"set":[{"id":"t1","kind":"symbol","sym":"target","at":[-76.4767,38.9763],"color":"target",
        \\ "pick":{"title":"ONE","rows":[["MMSI","1"]]}}]}
    );
    cam.center.x = centre.x + 100.0 * worldPerPt(15.0);
    try t.expect(s.pickAt(cam, mid_x, mid_y, null) == null);
    try t.expect(s.pickAt(cam, mid_x - 100, mid_y, null) != null);
}

test "a dashed line cannot run away" {
    // The cut loop advanced by the run length, which reaches zero at the end of
    // a segment and at a dash boundary; once a run falls below the ULP of the
    // distance walked, the walk stops advancing and appends quads forever. It
    // showed up in a real frame as the renderer being KILLED for memory rather
    // than as a hang, so it must be tested here, not found there again.
    var s = Store.init(t.allocator);
    defer s.deinit();

    // Zoom 22, a degree of longitude: ~250,000 dash cycles, every one of them
    // far under a pixel. Over the cap it draws solid — one quad, not a flood.
    try s.applyBatch("p",
        \\{"set":[{"id":"l","kind":"polyline","pts":[[-77.0,38.9],[-76.0,38.9]],"dash":true,"color":"track"}]}
    );
    try t.expectEqual(@as(usize, 6), (try s.buildIfNeeded(22.0, .day, null)).verts.len);

    // Repeated and reversed points: zero-length segments, and a walk that has
    // to survive its own boundary arithmetic.
    try s.applyBatch("p",
        \\{"set":[{"id":"l","kind":"polyline","pts":[[-76.48,38.98],[-76.48,38.98],[-76.4799,38.98],[-76.48,38.98]],"dash":true,"color":"track"}]}
    );
    const fr = try s.buildIfNeeded(17.0, .day, null);
    try t.expect(fr.verts.len > 0);
    try t.expectEqual(@as(usize, 0), fr.verts.len % 6);
}

test "polyline, dash and polygon expansion" {
    var s = Store.init(t.allocator);
    defer s.deinit();
    // 3 points = 2 segments = 2 quads = 12 vertices.
    try s.applyBatch("p",
        \\{"set":[{"id":"l","kind":"polyline","pts":[[-76.50,38.90],[-76.48,38.92],[-76.46,38.90]],"width_pt":2,"color":"track"}]}
    );
    var fr = try s.buildIfNeeded(15.0, .day, null);
    try t.expectEqual(@as(usize, 12), fr.verts.len);
    const solid = fr.verts.len;

    // The same line dashed covers the same run with MORE, shorter quads.
    try s.applyBatch("p",
        \\{"set":[{"id":"l","kind":"polyline","pts":[[-76.50,38.90],[-76.48,38.92],[-76.46,38.90]],"width_pt":2,"dash":true,"color":"track"}]}
    );
    fr = try s.buildIfNeeded(15.0, .day, null);
    try t.expect(fr.verts.len > solid);
    try t.expectEqual(@as(usize, 0), fr.verts.len % 6);

    // A 5-point ring fans to 3 triangles.
    s.removeSource("p");
    try s.applyBatch("p",
        \\{"set":[{"id":"z","kind":"polygon","ring":[[-76.5,38.9],[-76.4,38.9],[-76.4,39.0],[-76.45,39.05],[-76.5,39.0]],"alpha":0.25,"color":"warning"}]}
    );
    fr = try s.buildIfNeeded(15.0, .day, null);
    try t.expectEqual(@as(usize, 9), fr.verts.len);
    // The polygon's alpha multiplies the token's.
    try t.expectApproxEqAbs(@as(f32, 0.25), fr.verts[0].a, 1e-6);
}

test "token resolution per scheme" {
    // Every token resolves to something in range, in all three schemes, and no
    // two tokens collide within a scheme.
    for ([_]Scheme{ .day, .dusk, .night }) |sch| {
        var seen: [7]Rgba = undefined;
        for (std.enums.values(Token), 0..) |tok, i| {
            const c = resolve(tok, sch);
            for (c) |ch| try t.expect(ch >= 0 and ch <= 1);
            try t.expect(c[3] > 0);
            seen[i] = c;
            for (seen[0..i]) |prev| try t.expect(!std.mem.eql(u8, std.mem.asBytes(&prev), std.mem.asBytes(&c)));
        }
    }
    // Night must not be bright. The bound is on the sRGB-ENCODED luminance,
    // which is what a display emits before its own gamma: 0.35 encoded is ~0.09
    // of full linear output, dim enough not to reset a night-adapted eye while
    // still legible against the near-black night chart (#171e21).
    for (std.enums.values(Token)) |tok| {
        const n = resolve(tok, .night);
        const lum = 0.2126 * n[0] + 0.7152 * n[1] + 0.0722 * n[2];
        try t.expect(lum < 0.35);
    }
    // A token drives the built vertices' colour.
    var s = Store.init(t.allocator);
    defer s.deinit();
    try s.applyBatch("p",
        \\{"set":[{"id":"t","kind":"symbol","sym":"target","at":[-76.4,38.9],"color":"target_danger"}]}
    );
    const day = (try s.buildIfNeeded(15.0, .day, null)).verts[0];
    const want_day = resolve(.target_danger, .day);
    try t.expectEqual(want_day[0], day.r);
    const night = (try s.buildIfNeeded(15.0, .night, null)).verts[0];
    const want_night = resolve(.target_danger, .night);
    try t.expectEqual(want_night[0], night.r);
}

test "rebuild gating on zoom, scheme and apply" {
    var s = Store.init(t.allocator);
    defer s.deinit();
    try s.applyBatch("p",
        \\{"set":[{"id":"t","kind":"symbol","sym":"target","at":[-76.4,38.9],"color":"target"}]}
    );
    const g0 = (try s.buildIfNeeded(15.0, .day, null)).generation;
    // Same inputs: no rebuild, same generation, so the GPU never re-uploads.
    try t.expect(!s.needsRebuild(15.0, .day, null));
    try t.expectEqual(g0, (try s.buildIfNeeded(15.0, .day, null)).generation);
    // Under 5% of scale: still no rebuild.
    try t.expect(!s.needsRebuild(15.05, .day, null));
    // Over it: rebuild.
    try t.expect(s.needsRebuild(15.1, .day, null));
    const g1 = (try s.buildIfNeeded(15.1, .day, null)).generation;
    try t.expect(g1 > g0);
    // A scheme change rebuilds; so does an apply.
    try t.expect(s.needsRebuild(15.1, .night, null));
    _ = try s.buildIfNeeded(15.1, .night, null);
    try t.expect(!s.needsRebuild(15.1, .night, null));
    try s.applyBatch("p", "{\"del\":[\"t\"]}");
    try t.expect(s.needsRebuild(15.1, .night, null));
    try t.expectEqual(@as(usize, 0), (try s.buildIfNeeded(15.1, .night, null)).verts.len);
}

test "symbol size tracks the zoom" {
    var s = Store.init(t.allocator);
    defer s.deinit();
    try s.applyBatch("p",
        \\{"set":[{"id":"t","kind":"symbol","sym":"target","rot_deg":0,"at":[-76.4,38.9],"color":"target"}]}
    );
    const at = geo(.{ -76.4, 38.9 });
    const a = (try s.buildIfNeeded(10.0, .day, null)).verts[1]; // the apex
    const b = (try s.buildIfNeeded(11.0, .day, null)).verts[1];
    // One zoom level in = half the world size, so the symbol keeps its point
    // size. Tolerance is set by the f32 vertex grid, not the math: world x is
    // ~0.29 there, where an f32 step is 3e-8 — about 0.1% of a 6.5 pt offset at
    // zoom 10, and proportionally more the further in the view goes.
    const da = at.y - @as(f64, a.y);
    const db = at.y - @as(f64, b.y);
    try t.expectApproxEqRel(da, db * 2.0, 5e-3);
    try t.expectApproxEqRel(TARGET_TIP * worldPerPt(10.0), da, 5e-3);
}

test "object budget is enforced" {
    var s = Store.init(t.allocator);
    defer s.deinit();
    var buf: [256]u8 = undefined;
    var i: usize = 0;
    while (i <= MAX_OBJECTS) : (i += 1) {
        const json = try std.fmt.bufPrint(&buf,
            \\{{"set":[{{"id":"t{d}","kind":"symbol","sym":"target","at":[-76.4,38.9],"color":"target"}}]}}
        , .{i});
        s.applyBatch("p", json) catch |e| {
            try t.expectEqual(Error.Budget, e);
            try t.expectEqual(@as(usize, MAX_OBJECTS), s.count());
            return;
        };
    }
    try t.expect(false); // the cap must have fired
}
