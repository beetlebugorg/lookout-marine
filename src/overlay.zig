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
//!   const fr = try ov.buildIfNeeded(cam.zoom, cam.rotation, .day, null); // render thread
//!   try gpu.setOverlay(fr, u);   // re-uploads iff fr.generation moved; `u` is
//!                                // the frame uniform with the MVP and wrap
//!                                // rebuilt for fr.origin
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
//! COORDINATES. Vertices are web-mercator world, RELATIVE to the build origin
//! the frame carries, as f32. Relative on purpose: an f32 holding an absolute
//! world coordinate spends its whole mantissa on the distance from the prime
//! meridian, so its step grows with the scale — a quarter point at zoom 15 but
//! four points at zoom 19 — and each corner of a line quad then snaps to that
//! grid on its own, drawing a 2 pt line as anything from nothing to a fat
//! wedge. Measured from a point near the geometry the same f32 is exact to
//! nanometres at every zoom. The caller draws the frame with the MVP built for
//! `origin` (camera.mvpOrigin), which is the trick the chart's per-tile origins
//! already use. The backend's overlay shader applies the same antimeridian wrap
//! the chart shader does, and it works unchanged in the relative frame: a whole
//! world width is 1.0 in both.
const std = @import("std");
const camera = @import("camera.zig");
const lock = @import("lock.zig");

/// The canvas budget refusals' one log line (spec rule 7). Quiet under the
/// test runner, which reads a step's stderr as a failure report; the tests
/// assert the refusal itself.
fn sayRefused(comptime fmt: []const u8, args: anytype) void {
    if (@import("builtin").is_test) return;
    std.debug.print(fmt, args);
}

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

pub const Kind = enum(u8) { symbol, polyline, polygon, canvas };

/// The symbol shapes the prototype draws. Expanded to vector geometry here —
/// no sprite atlas, so the overlay pass carries no texture.
pub const Sym = enum(u8) { ownship, target, aton, aton_virtual };

/// Straight-alpha RGBA, 0..1 (what the shader wants).
pub const Rgba = [4]f32;

// ---- the canvas object (specs/plugins/canvas.md) ---------------------------
//
// A canvas is a RECORDED command list, not pixels: the plugin posts the
// commands once, and this store replays them into triangles (and SDF glyph
// quads) at build time, so the drawing survives zoom and scheme changes
// without the plugin in the frame path. Coordinates are canvas units around
// the anchor: x right (east), y down (south). `points` units hold their
// screen size across zoom (converted at build, like symbol radii); `geo`
// units are METRES on the ground at the anchor, so a 1852-unit arc is a
// range ring. Stroke widths and text sizes are always screen points, in
// either space.
//
// SCREEN-ALIGNED CONTENT. Canvas units are chart-aligned: x is east and y is
// south on the ground, so under a turned view (course-up) a canvas turns with
// the chart. That is right for a compass card and wrong for a text readout,
// which turns onto its side and stops reading. The `screen_aligned` command
// turns the frame back: while it is on, the build puts the view's rotation
// into the transform in reverse, about the point the pen is at, so the camera
// undoes it and everything recorded under it — paths, text, gradients, clips
// — lands level on the display. It is graphics state like a fill style, so
// save/restore scopes it and one canvas mixes both kinds of content. The
// build therefore depends on the view rotation, but only for a canvas that
// asks: `has_screen_aligned` gates the rebuild so a plain scene costs nothing
// as the mariner turns the chart.

/// Which unit a canvas's coordinates carry. See above.
pub const CanvasSpace = enum(u8) { geo, points };

pub const LineCap = enum(u8) { butt, round, square };
pub const LineJoin = enum(u8) { miter, round, bevel };
pub const TextAlign = enum(u8) { left, center, right };

/// A posted colour: free RGBA, or a palette token resolved per scheme.
const CColor = union(enum) {
    rgba: Rgba,
    token: Token,

    fn resolveTo(self: CColor, scheme: Scheme) Rgba {
        return switch (self) {
            .rgba => |c| c,
            .token => |tok| resolve(tok, scheme),
        };
    }
};

const CStop = struct { t: f32, c: CColor };

/// Gradient geometry in canvas units. Linear runs `a`->`b`; radial is centred
/// on `a` with radius `r`. Stops are owned by the command list.
const CGrad = struct { a: [2]f32, b: [2]f32 = .{ 0, 0 }, r: f32 = 0, stops: []CStop };

const CPaint = union(enum) {
    flat: CColor,
    linear: CGrad,
    radial: CGrad,

    fn freeStops(self: *CPaint, alloc: std.mem.Allocator) void {
        switch (self.*) {
            .linear, .radial => |*g| alloc.free(g.stops),
            .flat => {},
        }
    }
};

/// One recorded canvas command. Angles are radians here (degrees on the
/// wire); `rotate` is clockwise on screen, matching y-down coordinates.
const CanvasCmd = union(enum) {
    begin_path,
    move_to: [2]f32,
    line_to: [2]f32,
    quad_to: [2][2]f32, // control, end
    bezier_to: [3][2]f32, // control1, control2, end
    arc: struct { c: [2]f32, r: f32, a0: f32, a1: f32, ccw: bool },
    close_path,
    fill,
    stroke,
    clip,
    fill_style: CPaint,
    stroke_style: CPaint,
    line_width: f32,
    line_cap: LineCap,
    line_join: LineJoin,
    font: struct { size: f32, bold: bool },
    text_align: TextAlign,
    fill_text: struct { at: [2]f32, text: []u8 }, // text owned
    translate: [2]f32,
    rotate: f32,
    scale: [2]f32,
    /// On: hold what follows level on the display, whatever the view rotation
    /// and whatever rotation the transform already carries. Off: give the
    /// transform its own rotation back. Scoped by save/restore.
    screen_aligned: bool,
    save,
    restore,

    fn free(self: *CanvasCmd, alloc: std.mem.Allocator) void {
        switch (self.*) {
            .fill_text => |ft| alloc.free(ft.text),
            .fill_style, .stroke_style => |*p| @constCast(p).freeStops(alloc),
            else => {},
        }
    }
};

/// One SDF glyph-quad vertex the overlay text pass draws. Byte-identical to
/// tile57_gpu_quad (the backend static-asserts it), so the existing SDF
/// pipeline draws canvas text with no new shader. `x`,`y` are origin-relative
/// world like Vertex; `ox`,`oy` stay zero (the glyph box is baked into world
/// space at build, the same discipline as every other overlay size); `depth`
/// is 0 so the near-plane contract of the overlay pass holds.
pub const TextVertex = extern struct {
    x: f32,
    y: f32,
    ox: f32 = 0,
    oy: f32 = 0,
    u: f32,
    v: f32,
    color: [4]u8,
    weight: f32 = 0,
    scamin: f32 = 0, // <= 0: never scale-gated
    flags: u32 = 0, // disp_cat 0, no map_align, no flip
    depth: f32 = 0,
};

/// One glyph's metrics, EM units, y down, relative to the pen on the
/// baseline. The same numbers atlas.zig decodes from the tile57 bake.
pub const Glyph = struct {
    u0: f32,
    v0: f32,
    u1: f32,
    v1: f32,
    off_x: f32,
    off_y: f32,
    w: f32,
    h: f32,
    advance: f32,
};

/// A glyph source the core wires in (root.zig adapts the loaded SDF atlas).
/// Behind a function pointer so this file stays free of C imports and its
/// tests can supply a fake face.
pub const Font = struct {
    ctx: *const anyopaque,
    lookup: *const fn (ctx: *const anyopaque, cp: u21) ?Glyph,
};

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
    /// The world point the vertices are measured FROM. Draw them with the MVP
    /// built for it, and wrap about (camera centre - origin). See COORDINATES.
    origin: camera.Vec2,
    /// Canvas text as SDF glyph quads (6 TextVertex each), one stream per
    /// atlas face. Same origin and uniform as `verts`; drawn by the backend
    /// with the glyph atlas texture after the triangle stream.
    text: []const TextVertex = &.{},
    text_bold: []const TextVertex = &.{},
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
    // canvas
    space: CanvasSpace = .points,
    cmds: []CanvasCmd = &.{}, // owned
    /// The command list turns the screen-aligned frame on somewhere, so this
    /// object's geometry depends on the view rotation and must be rebuilt when
    /// the mariner turns the chart.
    screen_aligned: bool = false,
    /// The tessellation budget refused this object and said so once. Reset by
    /// a re-post (the object is replaced whole).
    over_said: bool = false,

    fn free(self: *Object, alloc: std.mem.Allocator) void {
        if (self.pts.len > 0) alloc.free(self.pts);
        self.pts = &.{};
        if (self.pick.len > 0) alloc.free(self.pick);
        self.pick = &.{};
        for (self.cmds) |*c| c.free(alloc);
        if (self.cmds.len > 0) alloc.free(self.cmds);
        self.cmds = &.{};
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
/// The aid-to-navigation mark: a diamond, half its diagonal. 14 pt across,
/// the same visual weight as the target triangle.
const ATON_HALF = 7.0;
/// The virtual aid's broken outline: stroke half-width, and the fraction of
/// each edge one of its two strokes covers. IALA draws a virtual aid as a
/// broken version of the same mark; the shape follows that convention, not a
/// published drawing. See PROTOTYPE-CONCERNS.md.
const ATON_STROKE_HALF = 1.15;
const ATON_DASH = 0.36;

const DASH_ON = 7.0;
const DASH_OFF = 5.0;
/// Above this many dash cycles a segment draws solid — see emitPolyline.
const MAX_DASHES_PER_SEG = 4096;

/// Vertices one `ownship` symbol expands to: the hull, fanned.
pub const OWNSHIP_VERTS = (HULL.len - 2) * 3;
/// Vertices one `target` symbol expands to.
pub const TARGET_VERTS = 3;
/// Vertices one physical `aton` symbol expands to: the diamond, two triangles.
pub const ATON_VERTS = 6;
/// Vertices one `aton_virtual` symbol expands to: eight strokes, two triangles
/// each.
pub const ATON_VIRTUAL_VERTS = 8 * 6;

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

/// Rebuild when the view has turned more than this, radians (0.1 degrees).
/// Only a scene holding screen-aligned content is gated on it at all; the
/// tolerance is there so float noise in the camera does not rebuild, and it
/// leaves a 100 pt run under a fifth of a point off level.
const ROT_REBUILD_DRAD = 0.0017453292519943296;

/// Per-store object ceiling. A plugin that leaks objects costs frame time and
/// memory; over the cap the batch is rejected rather than silently truncated.
const MAX_OBJECTS = 4096;
/// Per-object point ceiling — the prototype's longest line is a 600-point
/// track, and an unbounded ring or polyline is an unbounded vertex buffer.
const MAX_POINTS = 8192;

// ---- canvas budgets (spec rule 7: over budget refuses the whole object) ----

/// Commands one canvas may carry.
pub const MAX_CANVAS_CMDS = 2048;
/// Bytes one fillText run may carry.
pub const MAX_CANVAS_TEXT = 256;
/// Stops one gradient may carry.
const MAX_CANVAS_STOPS = 8;
/// Triangle vertices one canvas may tessellate to.
const MAX_CANVAS_VERTS = 32768;
/// Glyphs one canvas may lay out.
const MAX_CANVAS_GLYPHS = 512;
/// Points one flattened path may hold.
const MAX_CANVAS_PATH_PTS = 4096;
/// save/restore depth (the base state plus this many saves).
const CANVAS_STATE_DEPTH = 8;
/// Points a clip polygon may hold after flattening.
const CLIP_MAX_PTS = 64;
/// Segments a full circle flattens to. Chord error at a 100 pt radius is
/// under a quarter point.
const ARC_SEGS_FULL = 64;
/// Segments a quadratic / cubic bezier flattens to.
const QUAD_SEGS = 16;
const CUBIC_SEGS = 24;
/// A miter longer than this many half-widths draws as a bevel.
const MITER_LIMIT = 10.0;

pub const Error = error{ BadBatch, Budget, OutOfMemory };

pub const Store = struct {
    alloc: std.mem.Allocator,
    mu: lock.Lock = .{},
    /// Keyed by "<source_id>/<object id>" — the host's namespace, so two
    /// plugins may both call their symbol "ownship". Ordered map: draw order is
    /// insertion order within a kind, which is stable frame to frame.
    objs: std.StringArrayHashMapUnmanaged(Object) = .empty,
    verts: std.ArrayList(Vertex) = .empty,
    /// Canvas text, rebuilt with the vertices: one glyph-quad stream per
    /// atlas face the backend can bind.
    tverts: std.ArrayList(TextVertex) = .empty,
    tverts_bold: std.ArrayList(TextVertex) = .empty,
    /// The glyph faces the core wired in (setFonts), or null before the atlas
    /// loads. A canvas fillText with no face is skipped and re-tessellated
    /// when the face arrives.
    font_reg: ?Font = null,
    font_bold: ?Font = null,
    /// Scratch for the canvas tessellator, reused across objects and builds.
    cpath: std.ArrayList([2]f64) = .empty,
    csubs: std.ArrayList(CSub) = .empty,
    cidx: std.ArrayList(u32) = .empty,
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
    /// The world point this build's vertices are measured from.
    built_origin: camera.Vec2 = .{ .x = 0, .y = 0 },
    /// Own ship's display position at the last build, and whether any object
    /// rides it. Without a rider the position is ignored and nothing rebuilds.
    built_ship: ?[2]f64 = null,
    has_ship_anchor: bool = false,
    /// The view rotation this build compensated for, radians, and whether any
    /// canvas asked for that. Without one the rotation is ignored and turning
    /// the chart never rebuilds the overlay.
    built_rot: f64 = 0,
    has_screen_aligned: bool = false,

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
        self.tverts.deinit(self.alloc);
        self.tverts_bold.deinit(self.alloc);
        self.cpath.deinit(self.alloc);
        self.csubs.deinit(self.alloc);
        self.cidx.deinit(self.alloc);
        self.pick_out.deinit(self.alloc);
        self.id_out.deinit(self.alloc);
        self.* = undefined;
    }

    /// Wire the SDF glyph faces in (or out). Idempotent and cheap: only a
    /// changed face marks the store dirty, so the render thread may call this
    /// every frame with whatever the atlas cache currently holds.
    pub fn setFonts(self: *Store, reg: ?Font, bold: ?Font) void {
        self.mu.lock();
        defer self.mu.unlock();
        if (sameFont(self.font_reg, reg) and sameFont(self.font_bold, bold)) return;
        self.font_reg = reg;
        self.font_bold = bold;
        self.dirty = true;
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
        // Under the lock (defers run last in, first out), and on every exit
        // path: a batch that fails halfway must not leave the build's
        // dependencies describing objects it no longer holds.
        defer self.noteRiders();

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
        self.noteRiders();
    }

    fn removeLocked(self: *Store, k: []const u8) void {
        if (self.objs.fetchOrderedRemove(k)) |kv| {
            self.alloc.free(kv.key);
            var v = kv.value;
            v.free(self.alloc);
            self.dirty = true;
            self.noteRiders();
        }
    }

    /// What the retained scene makes the build depend on: anything riding own
    /// ship's display position, and any canvas holding content level on
    /// screen. Recomputed on every change, so a scene with neither never
    /// rebuilds for a moving boat or a turning view.
    fn noteRiders(self: *Store) void {
        self.has_ship_anchor = false;
        self.has_screen_aligned = false;
        for (self.objs.values()) |*o| {
            if (o.ship_anchor) self.has_ship_anchor = true;
            if (o.screen_aligned) self.has_screen_aligned = true;
            if (self.has_ship_anchor and self.has_screen_aligned) return;
        }
    }

    fn makeKey(self: *Store, source_id: []const u8, id: []const u8) ![]u8 {
        return std.fmt.allocPrint(self.alloc, "{s}/{s}", .{ source_id, id });
    }

    fn parseObject(self: *Store, o: std.json.ObjectMap) (error{ OutOfMemory, Skip })!Object {
        const kind = std.meta.stringToEnum(Kind, jstr(o.get("kind") orelse return error.Skip) orelse return error.Skip) orelse return error.Skip;
        // A canvas carries colour per command, not per object; every other
        // kind still requires its token.
        const token = if (kind == .canvas)
            Token.ownship
        else
            std.meta.stringToEnum(Token, jstr(o.get("color") orelse return error.Skip) orelse return error.Skip) orelse return error.Skip;
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
            .canvas => {
                if (o.get("space")) |sp| {
                    obj.space = std.meta.stringToEnum(CanvasSpace, jstr(sp) orelse return error.Skip) orelse return error.Skip;
                }
                // The anchor. An own-ship canvas may omit it (the display
                // position substitutes); a fixed one must say where it sits.
                if (o.get("at")) |at| {
                    obj.at = jpoint(at) orelse return error.Skip;
                } else if (!obj.ship_anchor) return error.Skip;
                obj.cmds = try self.parseCanvasCmds(o, jstr(o.get("id") orelse .null) orelse "?");
                for (obj.cmds) |c| {
                    if (c == .screen_aligned and c.screen_aligned) {
                        obj.screen_aligned = true;
                        break;
                    }
                }
            },
        }
        return obj;
    }

    // ---- canvas decode ----------------------------------------------------

    /// The command list, or error.Skip. Budget violations (spec rule 7) refuse
    /// the whole object with one log line; a malformed command refuses it
    /// silently like any other malformed object.
    fn parseCanvasCmds(self: *Store, o: std.json.ObjectMap, id: []const u8) (error{ OutOfMemory, Skip })![]CanvasCmd {
        const arr = o.get("cmds") orelse return error.Skip;
        if (arr != .array) return error.Skip;
        const items = arr.array.items;
        if (items.len > MAX_CANVAS_CMDS) {
            sayRefused("overlay: canvas \"{s}\" refused: {d} commands, the budget is {d}\n", .{ id, items.len, MAX_CANVAS_CMDS });
            return error.Skip;
        }
        var cmds = std.ArrayList(CanvasCmd).empty;
        errdefer {
            for (cmds.items) |*c| c.free(self.alloc);
            cmds.deinit(self.alloc);
        }
        for (items) |it| {
            if (it != .array or it.array.items.len == 0) return error.Skip;
            const a = it.array.items;
            const op = jstr(a[0]) orelse return error.Skip;
            const cmd: CanvasCmd = blk: {
                if (std.mem.eql(u8, op, "P")) break :blk .begin_path;
                if (std.mem.eql(u8, op, "M")) break :blk .{ .move_to = try argPt(a, 1) };
                if (std.mem.eql(u8, op, "L")) break :blk .{ .line_to = try argPt(a, 1) };
                if (std.mem.eql(u8, op, "Q")) break :blk .{ .quad_to = .{ try argPt(a, 1), try argPt(a, 3) } };
                if (std.mem.eql(u8, op, "B")) break :blk .{ .bezier_to = .{ try argPt(a, 1), try argPt(a, 3), try argPt(a, 5) } };
                if (std.mem.eql(u8, op, "A")) break :blk .{ .arc = .{
                    .c = try argPt(a, 1),
                    .r = try argNum(a, 3),
                    .a0 = std.math.degreesToRadians(try argNum(a, 4)),
                    .a1 = std.math.degreesToRadians(try argNum(a, 5)),
                    .ccw = if (a.len > 6) (jbool(a[6]) orelse ((jnum(a[6]) orelse 0) != 0)) else false,
                } };
                if (std.mem.eql(u8, op, "Z")) break :blk .close_path;
                if (std.mem.eql(u8, op, "F")) break :blk .fill;
                if (std.mem.eql(u8, op, "S")) break :blk .stroke;
                if (std.mem.eql(u8, op, "C")) break :blk .clip;
                if (std.mem.eql(u8, op, "fs")) break :blk .{ .fill_style = try self.parsePaint(a) };
                if (std.mem.eql(u8, op, "ss")) break :blk .{ .stroke_style = try self.parsePaint(a) };
                if (std.mem.eql(u8, op, "lw")) {
                    var w = try argNum(a, 1);
                    if (!(w > 0.05 and w < 64)) w = 1.5;
                    break :blk .{ .line_width = w };
                }
                if (std.mem.eql(u8, op, "cap")) break :blk .{ .line_cap = argEnum(LineCap, a, 1) orelse return error.Skip };
                if (std.mem.eql(u8, op, "join")) break :blk .{ .line_join = argEnum(LineJoin, a, 1) orelse return error.Skip };
                if (std.mem.eql(u8, op, "font")) {
                    var size = try argNum(a, 1);
                    if (!(size > 2 and size < 128)) size = 12;
                    const bold = if (a.len > 2)
                        std.mem.eql(u8, jstr(a[2]) orelse return error.Skip, "bold")
                    else
                        false;
                    break :blk .{ .font = .{ .size = size, .bold = bold } };
                }
                if (std.mem.eql(u8, op, "ta")) break :blk .{ .text_align = argEnum(TextAlign, a, 1) orelse return error.Skip };
                if (std.mem.eql(u8, op, "T")) {
                    const at = try argPt(a, 1);
                    if (a.len < 4) return error.Skip;
                    const text = jstr(a[3]) orelse return error.Skip;
                    if (text.len > MAX_CANVAS_TEXT) {
                        sayRefused("overlay: canvas \"{s}\" refused: a {d}-byte text run, the budget is {d}\n", .{ id, text.len, MAX_CANVAS_TEXT });
                        return error.Skip;
                    }
                    break :blk .{ .fill_text = .{ .at = at, .text = try self.alloc.dupe(u8, text) } };
                }
                if (std.mem.eql(u8, op, "tr")) break :blk .{ .translate = try argPt(a, 1) };
                if (std.mem.eql(u8, op, "rot")) break :blk .{ .rotate = std.math.degreesToRadians(try argNum(a, 1)) };
                if (std.mem.eql(u8, op, "sc")) break :blk .{ .scale = try argPt(a, 1) };
                if (std.mem.eql(u8, op, "sa")) break :blk .{
                    // Bare `["sa"]` turns it on; the flag may arrive as a bool
                    // or a number, like `ccw` on an arc.
                    .screen_aligned = if (a.len > 1) (jbool(a[1]) orelse ((jnum(a[1]) orelse 0) != 0)) else true,
                };
                if (std.mem.eql(u8, op, "sv")) break :blk .save;
                if (std.mem.eql(u8, op, "rs")) break :blk .restore;
                return error.Skip;
            };
            cmds.append(self.alloc, cmd) catch |e| {
                var c = cmd;
                c.free(self.alloc);
                return e;
            };
        }
        return try cmds.toOwnedSlice(self.alloc);
    }

    /// A paint: `[r,g,b,a]`, `"token"`, or `{"lin":[x0,y0,x1,y1],"stops":[...]}` /
    /// `{"rad":[cx,cy,r],"stops":[...]}` with stops `[[t, color], ...]`.
    fn parsePaint(self: *Store, a: []std.json.Value) (error{ OutOfMemory, Skip })!CPaint {
        if (a.len < 2) return error.Skip;
        const v = a[1];
        if (v == .array or v == .string) return .{ .flat = parseColor(v) orelse return error.Skip };
        if (v != .object) return error.Skip;
        const stops_v = v.object.get("stops") orelse return error.Skip;
        if (stops_v != .array) return error.Skip;
        const raw_stops = stops_v.array.items;
        if (raw_stops.len < 2 or raw_stops.len > MAX_CANVAS_STOPS) return error.Skip;
        const stops = try self.alloc.alloc(CStop, raw_stops.len);
        errdefer self.alloc.free(stops);
        for (raw_stops, stops) |rv, *s| {
            if (rv != .array or rv.array.items.len < 2) return error.Skip;
            const tv = jnum(rv.array.items[0]) orelse return error.Skip;
            if (!std.math.isFinite(tv)) return error.Skip;
            s.* = .{
                .t = @floatCast(std.math.clamp(tv, 0, 1)),
                .c = parseColor(rv.array.items[1]) orelse return error.Skip,
            };
        }
        if (v.object.get("lin")) |g| {
            const q = try quadNums(g);
            return .{ .linear = .{ .a = .{ q[0], q[1] }, .b = .{ q[2], q[3] }, .stops = stops } };
        }
        if (v.object.get("rad")) |g| {
            if (g != .array or g.array.items.len < 3) return error.Skip;
            const cx = finiteF32(jnum(g.array.items[0])) orelse return error.Skip;
            const cy = finiteF32(jnum(g.array.items[1])) orelse return error.Skip;
            const r = finiteF32(jnum(g.array.items[2])) orelse return error.Skip;
            if (!(r > 0)) return error.Skip;
            return .{ .radial = .{ .a = .{ cx, cy }, .r = r, .stops = stops } };
        }
        return error.Skip;
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

    /// True when the vertex array no longer matches (zoom, view rotation,
    /// scheme, own ship's display position) or an apply has landed since the
    /// last build. `rot` is the camera's view rotation in radians; it only
    /// counts while a canvas holds content level on screen.
    pub fn needsRebuild(self: *Store, zoom: f64, rot: f64, scheme: Scheme, ship: ?[2]f64) bool {
        self.mu.lock();
        defer self.mu.unlock();
        return self.needsRebuildLocked(zoom, rot, scheme, ship);
    }

    fn needsRebuildLocked(self: *Store, zoom: f64, rot: f64, scheme: Scheme, ship: ?[2]f64) bool {
        if (!self.has_build or self.dirty) return true;
        if (scheme != self.built_scheme) return true;
        if (self.has_ship_anchor and !samePoint(ship, self.built_ship)) return true;
        if (self.has_screen_aligned and @abs(rot - self.built_rot) > ROT_REBUILD_DRAD) return true;
        return @abs(zoom - self.built_zoom) > ZOOM_REBUILD_DZ;
    }

    /// Render-thread entry: rebuild if needed and return the current frame.
    /// The returned slice is valid until the next call.
    pub fn buildIfNeeded(self: *Store, zoom: f64, rot: f64, scheme: Scheme, ship: ?[2]f64) Error!Frame {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.needsRebuildLocked(zoom, rot, scheme, ship)) try self.buildLocked(zoom, rot, scheme, ship);
        return .{
            .verts = self.verts.items,
            .generation = self.gen,
            .origin = self.built_origin,
            .text = self.tverts.items,
            .text_bold = self.tverts_bold.items,
        };
    }

    /// The point this build measures its vertices from: the first object's own
    /// POSTED position. Any point near the geometry serves — what matters is
    /// that it is not own ship's carried position, which walks between fixes
    /// and would move every vertex in the frame with it.
    fn originLocked(self: *Store) camera.Vec2 {
        for (self.objs.values()) |*o| {
            if (o.kind == .symbol or o.kind == .canvas) return geo(o.at);
            if (o.pts.len > 0) return geo(o.pts[0]);
        }
        return .{ .x = 0, .y = 0 };
    }

    fn buildLocked(self: *Store, zoom: f64, rot: f64, scheme: Scheme, ship: ?[2]f64) Error!void {
        self.verts.clearRetainingCapacity();
        self.tverts.clearRetainingCapacity();
        self.tverts_bold.clearRetainingCapacity();
        self.built_origin = self.originLocked();
        const wpp = worldPerPt(zoom);
        // Paint order: areas, then lines, then symbols, then canvases. A track
        // must not cover the boat, a warning area must not cover either, and
        // an instrument drawing sits over all three.
        for ([4]Kind{ .polygon, .polyline, .symbol, .canvas }) |pass| {
            for (self.objs.keys(), self.objs.values()) |key, *o| {
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
                    .canvas => try self.emitCanvas(key, o, effAt(o, ship), wpp, rot, scheme),
                }
            }
        }
        self.gen += 1;
        self.dirty = false;
        self.has_build = true;
        self.built_zoom = zoom;
        self.built_rot = rot;
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
            // Measured from the build origin, x the SHORT way round the world:
            // f32 holds a small delta exactly, an absolute world coordinate
            // only to the nearest few metres. See COORDINATES.
            .x = @floatCast(camera.wrapDx(w.x, self.built_origin.x)),
            .y = @floatCast(w.y - self.built_origin.y),
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
        // Where the next segment starts WITHIN the dash cycle, so the pattern
        // runs through a vertex instead of restarting at it. Kept reduced to
        // [0, period).
        var phase: f64 = 0;
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
                phase = if (period > 0) @mod(phase + len, period) else 0;
                continue;
            }
            // Cut the segment against the dash cycles, INDEXED off the phase
            // rather than walked one run at a time.
            //
            // The walk was the bug. It advanced `d` by the length of each run
            // and re-derived the phase as @mod(phase + d, period). Only at an
            // INTEGER zoom is `period` a power of two and every boundary
            // exact; at any other zoom `d` drifts a few ULP, and once it lands
            // a hair BELOW a cycle boundary @mod reads the phase as a whole
            // period instead of none. The run then comes out as that hair —
            // orders of magnitude under the ULP of `d` — and the guard that
            // stops a runaway (a run too small to advance) took it for the end
            // of the line. Every dashed line at a fractional zoom stopped
            // after three to eleven dashes: at zoom 15.2 own ship's 926 m
            // speed vector drew 100 m of itself, shorter than the 185 m
            // heading line beside it.
            //
            // An index cannot drift and cannot fail to advance: cycle k covers
            // [k*period, k*period + on) measured from the line's own start.
            var k: f64 = 0;
            while (true) : (k += 1) {
                const c0 = k * period - phase; // cycle start, measured from `a`
                if (!(c0 < len)) break;
                const s0 = @max(c0, 0);
                const s1 = @min(c0 + on, len);
                if (s1 > s0) {
                    const p0 = camera.Vec2{ .x = a.x + dx * (s0 / len), .y = a.y + dy * (s0 / len) };
                    const p1 = camera.Vec2{ .x = a.x + dx * (s1 / len), .y = a.y + dy * (s1 / len) };
                    try self.quad(p0, p1, dx / len, dy / len, hw, c);
                }
            }
            // Carry the phase to the next segment REDUCED: the pattern only
            // depends on the phase within a cycle, and a raw running total
            // over a long track would swamp `period` in the k*period - phase
            // above.
            phase = @mod(phase + len, period);
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
            // An aid to navigation is a diamond: filled when there is
            // something in the water, and drawn as a broken outline when a
            // station is broadcasting a mark that is not there.
            .aton, .aton_virtual => {
                const h = ATON_HALF * s;
                const d = [4]camera.Vec2{
                    .{ .x = at.x, .y = at.y - h },
                    .{ .x = at.x + h, .y = at.y },
                    .{ .x = at.x, .y = at.y + h },
                    .{ .x = at.x - h, .y = at.y },
                };
                if (o.sym == .aton) {
                    try self.tri(d[0], d[1], d[2], c);
                    try self.tri(d[0], d[2], d[3], c);
                    return;
                }
                const hw = ATON_STROKE_HALF * s;
                for (0..4) |i| {
                    const a = d[i];
                    const b = d[(i + 1) % 4];
                    const dx = b.x - a.x;
                    const dy = b.y - a.y;
                    const len = std.math.hypot(dx, dy);
                    if (!(len > 0)) continue;
                    const ux = dx / len;
                    const uy = dy / len;
                    // One stroke in from each corner, leaving the middle open.
                    try self.quad(a, .{ .x = a.x + dx * ATON_DASH, .y = a.y + dy * ATON_DASH }, ux, uy, hw, c);
                    try self.quad(.{ .x = b.x - dx * ATON_DASH, .y = b.y - dy * ATON_DASH }, b, ux, uy, hw, c);
                }
            },
        }
    }

    // ---- the canvas ---------------------------------------------------------

    /// Replay one canvas's command list into triangles and glyph quads. On a
    /// blown tessellation budget the WHOLE object is rewound and refused with
    /// one log line (spec rule 7), so a runaway drawing costs nothing but its
    /// log line.
    fn emitCanvas(self: *Store, key: []const u8, o: *Object, at_geo: [2]f64, wpp: f64, rot: f64, scheme: Scheme) Error!void {
        if (o.cmds.len == 0) return;
        const at = geo(at_geo);
        var vm = CanvasVM{
            .s = self,
            .ax = at.x,
            .ay = at.y,
            .unit = switch (o.space) {
                .points => wpp,
                .geo => worldPerMetre(at_geo[1]),
            },
            .wpp = wpp,
            .view_rot = rot,
            .scheme = scheme,
            .vmark = self.verts.items.len,
            .tmark = self.tverts.items.len,
            .tbmark = self.tverts_bold.items.len,
        };
        self.cpath.clearRetainingCapacity();
        self.csubs.clearRetainingCapacity();
        for (o.cmds) |*cmd| {
            if (vm.over) break;
            try vm.exec(cmd);
        }
        if (vm.over) {
            self.verts.shrinkRetainingCapacity(vm.vmark);
            self.tverts.shrinkRetainingCapacity(vm.tmark);
            self.tverts_bold.shrinkRetainingCapacity(vm.tbmark);
            if (!o.over_said) {
                o.over_said = true;
                sayRefused("overlay: canvas \"{s}\" refused: over the tessellation budget\n", .{key});
            }
        }
    }

    /// One glyph-quad vertex, measured from the build origin like push().
    fn pushText(self: *Store, list: *std.ArrayList(TextVertex), w: camera.Vec2, u: f32, v: f32, c: [4]u8) Error!void {
        try list.append(self.alloc, .{
            .x = @floatCast(camera.wrapDx(w.x, self.built_origin.x)),
            .y = @floatCast(w.y - self.built_origin.y),
            .u = u,
            .v = v,
            .color = c,
        });
    }
};

// ---- the canvas tessellator -------------------------------------------------
//
// A tiny canvas machine, run at BUILD time only: paths flatten in user space
// (each appended point carries the transform current at its append, which is
// how the HTML canvas behaves), fills ear-clip, strokes expand with caps and
// joins, gradients evaluate per emitted vertex, and text lays out as SDF
// glyph quads off the wired atlas face. Clipping is Sutherland-Hodgman
// against the clip path, which therefore must be CONVEX; a concave clip
// keeps its hull's wedges, the same caveat emitPolygon carries.

/// One graphics state. Paints here hold gradient geometry ALREADY transformed
/// (resolvePaint), so evaluation runs against the transformed path points.
const CState = struct {
    /// Row-major affine: x' = a x + b y + tx ; y' = c x + d y + ty.
    tf: [6]f64 = .{ 1, 0, 0, 0, 1, 0 },
    fill: CPaint = .{ .flat = .{ .rgba = .{ 0, 0, 0, 1 } } },
    stroke: CPaint = .{ .flat = .{ .rgba = .{ 0, 0, 0, 1 } } },
    width: f64 = 1.5,
    cap: LineCap = .butt,
    join: LineJoin = .miter,
    fsize: f64 = 12,
    fbold: bool = false,
    talign: TextAlign = .left,
    clip_len: usize = 0,
    /// The screen-aligned frame is on, and the angle `screenAligned` turned
    /// the transform by to get there — turning it off turns that back, so the
    /// author's own frame returns exactly.
    screen: bool = false,
    screen_turn: f64 = 0,
};

const CanvasVM = struct {
    s: *Store,
    /// The anchor in world units, and world units per canvas unit / per point.
    ax: f64,
    ay: f64,
    unit: f64,
    wpp: f64,
    /// The camera's view rotation, radians clockwise on screen. Canvas units
    /// are chart-aligned, so this is what `screenAligned` cancels.
    view_rot: f64,
    scheme: Scheme,
    st: [CANVAS_STATE_DEPTH + 1]CState = @splat(.{}),
    clips: [CANVAS_STATE_DEPTH + 1][CLIP_MAX_PTS][2]f64 = undefined,
    sp: usize = 0,
    /// Rewind marks for the whole-object refusal.
    vmark: usize,
    tmark: usize,
    tbmark: usize,
    glyphs: usize = 0,
    over: bool = false,

    fn state(vm: *CanvasVM) *CState {
        return &vm.st[vm.sp];
    }

    fn exec(vm: *CanvasVM, cmd: *const CanvasCmd) Error!void {
        switch (cmd.*) {
            .begin_path => {
                vm.s.cpath.clearRetainingCapacity();
                vm.s.csubs.clearRetainingCapacity();
            },
            .move_to => |p| try vm.newSub(vm.xf(p)),
            .line_to => |p| try vm.vertex(vm.xf(p)),
            .quad_to => |q| try vm.flattenQuad(vm.xf(q[0]), vm.xf(q[1])),
            .bezier_to => |q| try vm.flattenCubic(vm.xf(q[0]), vm.xf(q[1]), vm.xf(q[2])),
            .arc => |a| try vm.flattenArc(a),
            .close_path => try vm.closeSub(),
            .fill => try vm.fillPath(),
            .stroke => try vm.strokePath(),
            .clip => vm.clipPath(),
            .fill_style => |p| vm.state().fill = vm.resolvePaint(p),
            .stroke_style => |p| vm.state().stroke = vm.resolvePaint(p),
            .line_width => |w| vm.state().width = w,
            .line_cap => |c| vm.state().cap = c,
            .line_join => |j| vm.state().join = j,
            .font => |f| {
                vm.state().fsize = f.size;
                vm.state().fbold = f.bold;
            },
            .text_align => |a| vm.state().talign = a,
            .fill_text => |ft| try vm.text(ft.at, ft.text),
            .translate => |d| vm.apply(.{ 1, 0, d[0], 0, 1, d[1] }),
            .rotate => |r| vm.turn(r),
            .scale => |k| vm.apply(.{ k[0], 0, 0, 0, k[1], 0 }),
            .screen_aligned => |on| vm.screenAligned(on),
            .save => vm.saveState(),
            .restore => {
                if (vm.sp > 0) vm.sp -= 1;
            },
        }
    }

    // ---- transform ---------------------------------------------------------

    /// tf := tf o m — the command applies in the local coordinates the author
    /// is drawing in, HTML-canvas style.
    fn apply(vm: *CanvasVM, m: [6]f64) void {
        const f = vm.state().tf;
        vm.state().tf = .{
            f[0] * m[0] + f[1] * m[3],
            f[0] * m[1] + f[1] * m[4],
            f[0] * m[2] + f[1] * m[5] + f[2],
            f[3] * m[0] + f[4] * m[3],
            f[3] * m[1] + f[4] * m[4],
            f[3] * m[2] + f[4] * m[5] + f[5],
        };
    }

    /// Turn the local frame by `r` radians, clockwise on screen.
    fn turn(vm: *CanvasVM, r: f64) void {
        const cs = @cos(r);
        const sn = @sin(r);
        vm.apply(.{ cs, -sn, 0, sn, cs, 0 });
    }

    /// Hold what follows level on the display, or stop holding it.
    ///
    /// Canvas units are chart-aligned, so a turned view turns the drawing with
    /// the chart. Turning this ON turns the local frame until its rotation is
    /// exactly minus the view's, so the camera's own rotation cancels it and
    /// the content lands upright. The turn is about the point the pen is at,
    /// which is the anchor until the author translates away from it. Any
    /// rotation the author already applied goes with it: the promise is level
    /// on screen, not level relative to whatever the transform was doing.
    /// Turning it OFF turns the frame back by the same angle. A non-uniform
    /// scale or a mirror carries no single rotation; the angle of the
    /// transformed x axis is what gets cancelled.
    fn screenAligned(vm: *CanvasVM, on: bool) void {
        const st = vm.state();
        if (on == st.screen) return;
        if (on) {
            const f = st.tf;
            st.screen_turn = -vm.view_rot - std.math.atan2(f[3], f[0]);
            st.screen = true;
            vm.turn(st.screen_turn);
        } else {
            st.screen = false;
            vm.turn(-st.screen_turn);
            st.screen_turn = 0;
        }
    }

    fn xf(vm: *CanvasVM, p: [2]f32) [2]f64 {
        return vm.xfRaw(.{ p[0], p[1] });
    }

    fn avgScale(vm: *CanvasVM) f64 {
        const f = vm.state().tf;
        return @sqrt(@abs(f[0] * f[4] - f[1] * f[3]));
    }

    fn saveState(vm: *CanvasVM) void {
        if (vm.sp == CANVAS_STATE_DEPTH) return; // over depth: the save is ignored
        vm.st[vm.sp + 1] = vm.st[vm.sp];
        const n = vm.st[vm.sp].clip_len;
        if (n > 0) @memcpy(vm.clips[vm.sp + 1][0..n], vm.clips[vm.sp][0..n]);
        vm.sp += 1;
    }

    // ---- the path -----------------------------------------------------------

    fn newSub(vm: *CanvasVM, p: [2]f64) Error!void {
        try vm.s.csubs.append(vm.s.alloc, .{ .start = @intCast(vm.s.cpath.items.len), .len = 0, .closed = false });
        try vm.rawPush(p);
    }

    fn rawPush(vm: *CanvasVM, p: [2]f64) Error!void {
        if (vm.s.cpath.items.len >= MAX_CANVAS_PATH_PTS) {
            vm.over = true;
            return;
        }
        try vm.s.cpath.append(vm.s.alloc, p);
        vm.s.csubs.items[vm.s.csubs.items.len - 1].len += 1;
    }

    /// The pen: the last point of the open subpath, or null.
    fn pen(vm: *CanvasVM) ?[2]f64 {
        const subs = vm.s.csubs.items;
        if (subs.len == 0) return null;
        const last = subs[subs.len - 1];
        if (last.len == 0) return null;
        return vm.s.cpath.items[last.start + last.len - 1];
    }

    /// Add a point, drawing from the pen. With no pen this opens a subpath,
    /// as the HTML canvas does for a lineTo on an empty path.
    fn vertex(vm: *CanvasVM, p: [2]f64) Error!void {
        const q = vm.pen() orelse return vm.newSub(p);
        if (q[0] == p[0] and q[1] == p[1]) return; // exact repeats draw nothing
        try vm.rawPush(p);
    }

    fn closeSub(vm: *CanvasVM) Error!void {
        const subs = vm.s.csubs.items;
        if (subs.len == 0) return;
        const last = &subs[subs.len - 1];
        if (last.len < 2) return;
        last.closed = true;
        // The pen moves to the subpath's start; drawing continues in a fresh
        // subpath from there.
        try vm.newSub(vm.s.cpath.items[last.start]);
    }

    fn flattenQuad(vm: *CanvasVM, c: [2]f64, e: [2]f64) Error!void {
        const p0 = vm.pen() orelse return vm.newSub(e);
        var i: usize = 1;
        while (i <= QUAD_SEGS) : (i += 1) {
            const k = @as(f64, @floatFromInt(i)) / QUAD_SEGS;
            const u = 1 - k;
            try vm.vertex(.{
                u * u * p0[0] + 2 * u * k * c[0] + k * k * e[0],
                u * u * p0[1] + 2 * u * k * c[1] + k * k * e[1],
            });
        }
    }

    fn flattenCubic(vm: *CanvasVM, c1: [2]f64, c2: [2]f64, e: [2]f64) Error!void {
        const p0 = vm.pen() orelse return vm.newSub(e);
        var i: usize = 1;
        while (i <= CUBIC_SEGS) : (i += 1) {
            const k = @as(f64, @floatFromInt(i)) / CUBIC_SEGS;
            const u = 1 - k;
            try vm.vertex(.{
                u * u * u * p0[0] + 3 * u * u * k * c1[0] + 3 * u * k * k * c2[0] + k * k * k * e[0],
                u * u * u * p0[1] + 3 * u * u * k * c1[1] + 3 * u * k * k * c2[1] + k * k * k * e[1],
            });
        }
    }

    /// Sampled in USER space and transformed per sample, so a non-uniform
    /// scale draws the ellipse it implies. Angle 0 is +x, positive sweeps
    /// toward +y (clockwise on screen), the HTML convention.
    fn flattenArc(vm: *CanvasVM, a: @FieldType(CanvasCmd, "arc")) Error!void {
        if (!(a.r > 0)) return;
        var sweep: f64 = @as(f64, a.a1) - @as(f64, a.a0);
        const tau = 2.0 * std.math.pi;
        if (!a.ccw) {
            while (sweep < 0) sweep += tau;
            if (sweep > tau) sweep = tau;
        } else {
            while (sweep > 0) sweep -= tau;
            if (sweep < -tau) sweep = -tau;
        }
        const n: usize = @intFromFloat(@max(2.0, @ceil(@abs(sweep) / tau * ARC_SEGS_FULL)));
        var i: usize = 0;
        while (i <= n) : (i += 1) {
            const ang = @as(f64, a.a0) + sweep * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n));
            const p = vm.xf(.{
                a.c[0] + a.r * @as(f32, @floatCast(@cos(ang))),
                a.c[1] + a.r * @as(f32, @floatCast(@sin(ang))),
            });
            if (i == 0 and vm.pen() == null) try vm.newSub(p) else try vm.vertex(p);
        }
    }

    // ---- paints -------------------------------------------------------------

    /// A style command's paint with its gradient geometry moved into the
    /// transformed space the path points live in, so evaluation needs no
    /// inverse transform.
    fn resolvePaint(vm: *CanvasVM, p: CPaint) CPaint {
        switch (p) {
            .flat => return p,
            .linear => |g| {
                const a = vm.xf(g.a);
                const b = vm.xf(g.b);
                return .{ .linear = .{
                    .a = .{ @floatCast(a[0]), @floatCast(a[1]) },
                    .b = .{ @floatCast(b[0]), @floatCast(b[1]) },
                    .stops = g.stops,
                } };
            },
            .radial => |g| {
                const a = vm.xf(g.a);
                return .{ .radial = .{
                    .a = .{ @floatCast(a[0]), @floatCast(a[1]) },
                    .r = @floatCast(@as(f64, g.r) * vm.avgScale()),
                    .stops = g.stops,
                } };
            },
        }
    }

    fn evalPaint(vm: *CanvasVM, paint: *const CPaint, p: [2]f64) Rgba {
        switch (paint.*) {
            .flat => |c| return c.resolveTo(vm.scheme),
            .linear => |g| {
                const dx = @as(f64, g.b[0]) - g.a[0];
                const dy = @as(f64, g.b[1]) - g.a[1];
                const d2 = dx * dx + dy * dy;
                const tv: f64 = if (d2 > 0)
                    std.math.clamp(((p[0] - g.a[0]) * dx + (p[1] - g.a[1]) * dy) / d2, 0, 1)
                else
                    0;
                return vm.stopColor(g.stops, @floatCast(tv));
            },
            .radial => |g| {
                const tv = std.math.clamp(std.math.hypot(p[0] - g.a[0], p[1] - g.a[1]) / @as(f64, g.r), 0, 1);
                return vm.stopColor(g.stops, @floatCast(tv));
            },
        }
    }

    fn stopColor(vm: *CanvasVM, stops: []const CStop, tv: f32) Rgba {
        if (tv <= stops[0].t) return stops[0].c.resolveTo(vm.scheme);
        var i: usize = 1;
        while (i < stops.len) : (i += 1) {
            if (tv <= stops[i].t) {
                const a = stops[i - 1].c.resolveTo(vm.scheme);
                const b = stops[i].c.resolveTo(vm.scheme);
                const span = stops[i].t - stops[i - 1].t;
                const k: f32 = if (span > 0) (tv - stops[i - 1].t) / span else 1;
                var out: Rgba = undefined;
                for (a, b, &out) |x, y, *o| o.* = x + (y - x) * k;
                return out;
            }
        }
        return stops[stops.len - 1].c.resolveTo(vm.scheme);
    }

    // ---- emitting -----------------------------------------------------------

    fn worldOf(vm: *CanvasVM, p: [2]f64) camera.Vec2 {
        return .{ .x = vm.ax + p[0] * vm.unit, .y = vm.ay + p[1] * vm.unit };
    }

    fn emitTriRaw(vm: *CanvasVM, a: [2]f64, b: [2]f64, c: [2]f64, paint: *const CPaint) Error!void {
        if (vm.over) return;
        if (vm.s.verts.items.len - vm.vmark + 3 > MAX_CANVAS_VERTS) {
            vm.over = true;
            return;
        }
        try vm.s.push(vm.worldOf(a), vm.evalPaint(paint, a));
        try vm.s.push(vm.worldOf(b), vm.evalPaint(paint, b));
        try vm.s.push(vm.worldOf(c), vm.evalPaint(paint, c));
    }

    /// One triangle through the clip (when set), then out.
    fn paintTri(vm: *CanvasVM, a: [2]f64, b: [2]f64, c: [2]f64, paint: *const CPaint) Error!void {
        const n_clip = vm.state().clip_len;
        if (n_clip < 3) return vm.emitTriRaw(a, b, c, paint);
        const clip_pts = vm.clips[vm.sp][0..n_clip];
        var buf_a: [CLIP_MAX_PTS + 8][2]f64 = undefined;
        var buf_b: [CLIP_MAX_PTS + 8][2]f64 = undefined;
        buf_a[0] = a;
        buf_a[1] = b;
        buf_a[2] = c;
        var cur: *[CLIP_MAX_PTS + 8][2]f64 = &buf_a;
        var nxt: *[CLIP_MAX_PTS + 8][2]f64 = &buf_b;
        var n: usize = 3;
        // Which side of a clip edge is inside follows the polygon's winding.
        var area: f64 = 0;
        for (clip_pts, 0..) |p, i| {
            const q = clip_pts[(i + 1) % n_clip];
            area += p[0] * q[1] - q[0] * p[1];
        }
        const inner: f64 = if (area >= 0) 1 else -1;
        for (clip_pts, 0..) |e0, i| {
            const e1 = clip_pts[(i + 1) % n_clip];
            const ex = e1[0] - e0[0];
            const ey = e1[1] - e0[1];
            var m: usize = 0;
            var j: usize = 0;
            while (j < n) : (j += 1) {
                const p = cur[j];
                const q = cur[(j + 1) % n];
                const dp = (ex * (p[1] - e0[1]) - ey * (p[0] - e0[0])) * inner;
                const dq = (ex * (q[1] - e0[1]) - ey * (q[0] - e0[0])) * inner;
                if (dp >= 0) {
                    if (m < nxt.len) {
                        nxt[m] = p;
                        m += 1;
                    }
                }
                if ((dp >= 0) != (dq >= 0)) {
                    const k = dp / (dp - dq);
                    if (m < nxt.len) {
                        nxt[m] = .{ p[0] + (q[0] - p[0]) * k, p[1] + (q[1] - p[1]) * k };
                        m += 1;
                    }
                }
            }
            const swap = cur;
            cur = nxt;
            nxt = swap;
            n = m;
            if (n < 3) return;
        }
        var k: usize = 1;
        while (k + 1 < n) : (k += 1) {
            try vm.emitTriRaw(cur[0], cur[k], cur[k + 1], paint);
        }
    }

    // ---- fill ---------------------------------------------------------------

    fn fillPath(vm: *CanvasVM) Error!void {
        // Copied out of the state so the pointer handed down cannot alias a
        // state slot a later command mutates.
        const paint = vm.state().fill;
        for (vm.s.csubs.items) |sub| {
            if (sub.len < 3) continue;
            try vm.earClip(vm.s.cpath.items[sub.start..][0..sub.len], &paint);
        }
    }

    /// Ear-clip one ring (implicitly closed). Degenerate or oversized rings
    /// fall back to a fan, which is exact for convex input.
    fn earClip(vm: *CanvasVM, pts: []const [2]f64, paint: *const CPaint) Error!void {
        const idx = &vm.s.cidx;
        idx.clearRetainingCapacity();
        for (pts, 0..) |p, i| {
            // Skip exact repeats, including a closing point equal to the first.
            const prev = if (idx.items.len > 0) pts[idx.items[idx.items.len - 1]] else pts[pts.len - 1];
            if (p[0] == prev[0] and p[1] == prev[1] and idx.items.len > 0) continue;
            try idx.append(vm.s.alloc, @intCast(i));
        }
        if (idx.items.len >= 2) {
            const f = pts[idx.items[0]];
            const l = pts[idx.items[idx.items.len - 1]];
            if (f[0] == l[0] and f[1] == l[1]) _ = idx.pop();
        }
        var m = idx.items.len;
        if (m < 3) return;
        if (m > 512) return vm.fanRing(pts, idx.items, paint);
        var area: f64 = 0;
        for (idx.items, 0..) |ia, i| {
            const ib = idx.items[(i + 1) % m];
            area += pts[ia][0] * pts[ib][1] - pts[ib][0] * pts[ia][1];
        }
        if (area == 0) return;
        const orient: f64 = if (area > 0) 1 else -1;

        while (m > 3) {
            var clipped = false;
            var k: usize = 0;
            ear: while (k < m) : (k += 1) {
                const a = pts[idx.items[(k + m - 1) % m]];
                const b = pts[idx.items[k]];
                const c = pts[idx.items[(k + 1) % m]];
                const cr = cross2(a, b, c) * orient;
                if (cr <= 0) continue; // reflex or flat corner
                var j: usize = 0;
                while (j < m) : (j += 1) {
                    if (j == k or j == (k + m - 1) % m or j == (k + 1) % m) continue;
                    if (pointInTri(pts[idx.items[j]], a, b, c, orient)) continue :ear;
                }
                try vm.paintTri(a, b, c, paint);
                _ = idx.orderedRemove(k);
                m -= 1;
                clipped = true;
                break;
            }
            // No ear found: numerically degenerate ring. Fan what is left —
            // wrong only for what was already unfillable.
            if (!clipped) return vm.fanRing(pts, idx.items, paint);
        }
        try vm.paintTri(pts[idx.items[0]], pts[idx.items[1]], pts[idx.items[2]], paint);
    }

    fn fanRing(vm: *CanvasVM, pts: []const [2]f64, idx: []const u32, paint: *const CPaint) Error!void {
        var i: usize = 1;
        while (i + 1 < idx.len) : (i += 1) {
            try vm.paintTri(pts[idx[0]], pts[idx[i]], pts[idx[i + 1]], paint);
        }
    }

    // ---- stroke -------------------------------------------------------------

    fn strokePath(vm: *CanvasVM) Error!void {
        const st = vm.state();
        // Width is SCREEN POINTS in either space (spec rule 2); the transform's
        // scale applies like it does to everything else drawn under it.
        const hw = 0.5 * st.width * (vm.wpp / vm.unit) * vm.avgScale();
        if (!(hw > 0)) return;
        const paint = st.stroke;
        for (vm.s.csubs.items) |sub| {
            if (sub.len < 2) continue;
            try vm.strokeSub(vm.s.cpath.items[sub.start..][0..sub.len], sub.closed, hw, st.cap, st.join, &paint);
        }
    }

    fn strokeSub(vm: *CanvasVM, pts_in: []const [2]f64, closed: bool, hw: f64, cap: LineCap, join: LineJoin, paint: *const CPaint) Error!void {
        var pts = pts_in;
        // A closed ring whose last point is the first again within rounding
        // (a full-circle arc lands ~1e-14 off) would otherwise contribute a
        // noise-length wrap segment whose direction is pure rounding error,
        // and the join built on that direction is a wedge pointing anywhere.
        while (closed and pts.len > 1 and nearPt(pts[0], pts[pts.len - 1])) pts = pts[0 .. pts.len - 1];
        const n = pts.len;
        if (n < 2) return;
        // The closing segment, unless the author already drew back to the start.
        const wrap = closed and (pts[0][0] != pts[n - 1][0] or pts[0][1] != pts[n - 1][1]);
        const segs = if (wrap) n else n - 1;
        var prev_dir: ?[2]f64 = null;
        var first_dir: ?[2]f64 = null;
        var i: usize = 0;
        while (i < segs) : (i += 1) {
            const a = pts[i];
            const b = pts[(i + 1) % n];
            const dx = b[0] - a[0];
            const dy = b[1] - a[1];
            const len = std.math.hypot(dx, dy);
            // A segment shorter than any drawable length is a repeat point;
            // its quad is invisible and its direction is noise, so neither
            // may reach the join machinery.
            if (!(len > SEG_EPS)) continue;
            const d = [2]f64{ dx / len, dy / len };
            const nx = -d[1] * hw;
            const ny = d[0] * hw;
            try vm.paintTri(.{ a[0] + nx, a[1] + ny }, .{ b[0] + nx, b[1] + ny }, .{ b[0] - nx, b[1] - ny }, paint);
            try vm.paintTri(.{ a[0] + nx, a[1] + ny }, .{ b[0] - nx, b[1] - ny }, .{ a[0] - nx, a[1] - ny }, paint);
            if (prev_dir) |pd| try vm.joinAt(a, pd, d, hw, join, paint);
            if (first_dir == null) first_dir = d;
            prev_dir = d;
        }
        if (closed) {
            // Close the ring's last corner too.
            if (prev_dir != null and first_dir != null)
                try vm.joinAt(pts[0], prev_dir.?, first_dir.?, hw, join, paint);
            return;
        }
        if (cap == .butt) return;
        if (first_dir) |fd| try vm.capAt(pts[0], .{ -fd[0], -fd[1] }, hw, cap, paint);
        if (prev_dir) |ld| try vm.capAt(pts[n - 1], ld, hw, cap, paint);
    }

    /// Fill the wedge a turn opens on the outside of the joint at `p`.
    fn joinAt(vm: *CanvasVM, p: [2]f64, d1: [2]f64, d2: [2]f64, hw: f64, join: LineJoin, paint: *const CPaint) Error!void {
        const cr = d1[0] * d2[1] - d1[1] * d2[0];
        const dot = d1[0] * d2[0] + d1[1] * d2[1];
        if (@abs(cr) < 1e-12 and dot > 0) return; // straight through
        const s: f64 = if (cr > 0) -1 else 1; // the outer side of the turn
        const o1 = [2]f64{ -d1[1] * s, d1[0] * s };
        const o2 = [2]f64{ -d2[1] * s, d2[0] * s };
        const a = [2]f64{ p[0] + o1[0] * hw, p[1] + o1[1] * hw };
        const b = [2]f64{ p[0] + o2[0] * hw, p[1] + o2[1] * hw };
        switch (join) {
            .bevel => try vm.paintTri(p, a, b, paint),
            .round => try vm.fanBetween(p, o1, o2, hw, paint),
            .miter => {
                // cos of the half angle between the outer normals.
                const ch = @sqrt(@max(0.0, (1.0 + (o1[0] * o2[0] + o1[1] * o2[1])) * 0.5));
                if (!(ch > 1.0 / MITER_LIMIT)) return vm.paintTri(p, a, b, paint);
                var mx = o1[0] + o2[0];
                var my = o1[1] + o2[1];
                const ml = std.math.hypot(mx, my);
                if (!(ml > 0)) return vm.paintTri(p, a, b, paint);
                mx = p[0] + mx / ml * (hw / ch);
                my = p[1] + my / ml * (hw / ch);
                try vm.paintTri(p, a, .{ mx, my }, paint);
                try vm.paintTri(p, .{ mx, my }, b, paint);
            },
        }
    }

    /// A cap at `p` for a segment leaving along `d` (pointing OUT of the line).
    fn capAt(vm: *CanvasVM, p: [2]f64, d: [2]f64, hw: f64, cap: LineCap, paint: *const CPaint) Error!void {
        const nx = -d[1] * hw;
        const ny = d[0] * hw;
        switch (cap) {
            .butt => {},
            .square => {
                const q = [2]f64{ p[0] + d[0] * hw, p[1] + d[1] * hw };
                try vm.paintTri(.{ p[0] + nx, p[1] + ny }, .{ q[0] + nx, q[1] + ny }, .{ q[0] - nx, q[1] - ny }, paint);
                try vm.paintTri(.{ p[0] + nx, p[1] + ny }, .{ q[0] - nx, q[1] - ny }, .{ p[0] - nx, p[1] - ny }, paint);
            },
            .round => try vm.fanBetween(p, .{ -d[1], d[0] }, .{ d[1], -d[0] }, hw, paint),
        }
    }

    /// Fan from unit direction `o1` to `o2` about `p`, the short way round.
    /// A join's wedge is always under pi, so the short way IS the wedge; a
    /// round cap's is exactly pi and either way round draws the same half
    /// circle.
    fn fanBetween(vm: *CanvasVM, p: [2]f64, o1: [2]f64, o2: [2]f64, hw: f64, paint: *const CPaint) Error!void {
        const a0 = std.math.atan2(o1[1], o1[0]);
        var da = std.math.atan2(o2[1], o2[0]) - a0;
        while (da > std.math.pi) da -= 2 * std.math.pi;
        while (da < -std.math.pi) da += 2 * std.math.pi;
        if (da == 0) da = std.math.pi; // a full half circle (round cap)
        const steps: usize = @intFromFloat(@max(1.0, @ceil(@abs(da) / 0.4)));
        var i: usize = 0;
        while (i < steps) : (i += 1) {
            const b0 = a0 + da * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(steps));
            const b1 = a0 + da * @as(f64, @floatFromInt(i + 1)) / @as(f64, @floatFromInt(steps));
            try vm.paintTri(
                p,
                .{ p[0] + @cos(b0) * hw, p[1] + @sin(b0) * hw },
                .{ p[0] + @cos(b1) * hw, p[1] + @sin(b1) * hw },
                paint,
            );
        }
    }

    // ---- clip ---------------------------------------------------------------

    /// Adopt the current path's first usable subpath as the clip region.
    /// Convex regions clip exactly; see the file comment for concave ones.
    fn clipPath(vm: *CanvasVM) void {
        for (vm.s.csubs.items) |sub| {
            if (sub.len < 3) continue;
            if (sub.len > CLIP_MAX_PTS) {
                vm.over = true; // over the clip budget refuses the object
                return;
            }
            const pts = vm.s.cpath.items[sub.start..][0..sub.len];
            @memcpy(vm.clips[vm.sp][0..pts.len], pts);
            vm.state().clip_len = pts.len;
            return;
        }
    }

    // ---- text ---------------------------------------------------------------

    fn text(vm: *CanvasVM, at: [2]f32, run: []const u8) Error!void {
        const st = vm.state();
        // Which face draws this run. Asking for bold without a wired bold
        // face falls back to the regular one, metrics and texture together.
        const use_bold = st.fbold and vm.s.font_bold != null;
        const font = (if (use_bold) vm.s.font_bold else vm.s.font_reg) orelse return;
        const list = if (use_bold) &vm.s.tverts_bold else &vm.s.tverts;
        // Point size -> canvas units, so geo-space text holds its screen size
        // like a stroke width does. The transform then applies to the glyph
        // boxes like it does to everything else drawn under it.
        const size = st.fsize * (vm.wpp / vm.unit);
        // Advance-based width for the alignment shift; no shaping, which the
        // instrument strings this serves do not need.
        var width: f64 = 0;
        var it = std.unicode.Utf8Iterator{ .bytes = run, .i = 0 };
        while (nextCp(&it)) |cp| {
            width += glyphAdvance(font, cp) * size;
        }
        var px: f64 = @as(f64, at[0]) - switch (st.talign) {
            .left => 0,
            .center => width / 2,
            .right => width,
        };
        const py: f64 = at[1];
        it = .{ .bytes = run, .i = 0 };
        while (nextCp(&it)) |cp| {
            const g = font.lookup(font.ctx, cp) orelse {
                px += 0.5 * size;
                continue;
            };
            const adv = @as(f64, g.advance) * size;
            if (g.w > 0 and g.h > 0) {
                if (vm.glyphs >= MAX_CANVAS_GLYPHS) {
                    vm.over = true;
                    return;
                }
                vm.glyphs += 1;
                const gx = px + @as(f64, g.off_x) * size;
                const gy = py + @as(f64, g.off_y) * size;
                const gw = @as(f64, g.w) * size;
                const gh = @as(f64, g.h) * size;
                const color = rgbaBytes(vm.evalPaint(&st.fill, vm.xfRaw(.{ px, py })));
                const c00 = vm.worldOf(vm.xfRaw(.{ gx, gy }));
                const c10 = vm.worldOf(vm.xfRaw(.{ gx + gw, gy }));
                const c11 = vm.worldOf(vm.xfRaw(.{ gx + gw, gy + gh }));
                const c01 = vm.worldOf(vm.xfRaw(.{ gx, gy + gh }));
                try vm.s.pushText(list, c00, g.u0, g.v0, color);
                try vm.s.pushText(list, c10, g.u1, g.v0, color);
                try vm.s.pushText(list, c11, g.u1, g.v1, color);
                try vm.s.pushText(list, c00, g.u0, g.v0, color);
                try vm.s.pushText(list, c11, g.u1, g.v1, color);
                try vm.s.pushText(list, c01, g.u0, g.v1, color);
            }
            px += adv;
        }
    }

    /// xf for a point already in f64 canvas units.
    fn xfRaw(vm: *CanvasVM, p: [2]f64) [2]f64 {
        const f = vm.state().tf;
        return .{ f[0] * p[0] + f[1] * p[1] + f[2], f[3] * p[0] + f[4] * p[1] + f[5] };
    }
};

/// Shader colour (0..1) -> the u8 straight-alpha quad vertices carry.
fn rgbaBytes(c: Rgba) [4]u8 {
    var out: [4]u8 = undefined;
    for (c, &out) |ch, *o| o.* = @intFromFloat(std.math.clamp(ch, 0, 1) * 255.0 + 0.5);
    return out;
}

fn nextCp(it: *std.unicode.Utf8Iterator) ?u21 {
    if (it.i >= it.bytes.len) return null;
    const len = std.unicode.utf8ByteSequenceLength(it.bytes[it.i]) catch {
        it.i += 1; // an invalid byte is skipped, not fatal
        return nextCp(it);
    };
    if (it.i + len > it.bytes.len) {
        it.i = it.bytes.len;
        return null;
    }
    const cp = std.unicode.utf8Decode(it.bytes[it.i..][0..len]) catch {
        it.i += 1;
        return nextCp(it);
    };
    it.i += len;
    return cp;
}

fn glyphAdvance(font: Font, cp: u21) f64 {
    const g = font.lookup(font.ctx, cp) orelse return 0.5;
    return g.advance;
}

fn cross2(a: [2]f64, b: [2]f64, c: [2]f64) f64 {
    return (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0]);
}

/// Strictly inside, matching `orient`'s winding. Boundary points count as
/// outside, so shared edges do not block an ear.
fn pointInTri(p: [2]f64, a: [2]f64, b: [2]f64, c: [2]f64, orient: f64) bool {
    return cross2(a, b, p) * orient > 0 and
        cross2(b, c, p) * orient > 0 and
        cross2(c, a, p) * orient > 0;
}

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

// ---- canvas helpers --------------------------------------------------------

/// One flattened subpath: `start`..`start+len` into the shared point list.
const CSub = struct { start: u32, len: u32, closed: bool };

/// Shortest stroke segment worth drawing, canvas units. Anything under it is
/// a repeated point within rounding, in either space.
const SEG_EPS = 1e-9;

fn nearPt(a: [2]f64, b: [2]f64) bool {
    return @abs(a[0] - b[0]) <= SEG_EPS and @abs(a[1] - b[1]) <= SEG_EPS;
}

fn sameFont(a: ?Font, b: ?Font) bool {
    const x = a orelse return b == null;
    const y = b orelse return false;
    return x.ctx == y.ctx and x.lookup == y.lookup;
}

fn finiteF32(v: ?f64) ?f32 {
    const n = v orelse return null;
    if (!std.math.isFinite(n)) return null;
    return @floatCast(n);
}

/// Command argument `i`, a finite number. error.Skip refuses the object.
fn argNum(a: []std.json.Value, i: usize) error{Skip}!f32 {
    if (i >= a.len) return error.Skip;
    return finiteF32(jnum(a[i])) orelse error.Skip;
}

/// Command arguments `i`, `i+1` as a point.
fn argPt(a: []std.json.Value, i: usize) error{Skip}![2]f32 {
    return .{ try argNum(a, i), try argNum(a, i + 1) };
}

fn argEnum(comptime E: type, a: []std.json.Value, i: usize) ?E {
    if (i >= a.len) return null;
    return std.meta.stringToEnum(E, jstr(a[i]) orelse return null);
}

/// `[r,g,b,a]` (0..1, clamped) or a token name.
fn parseColor(v: std.json.Value) ?CColor {
    switch (v) {
        .string => |s| return .{ .token = std.meta.stringToEnum(Token, s) orelse return null },
        .array => |arr| {
            if (arr.items.len < 4) return null;
            var c: Rgba = undefined;
            for (arr.items[0..4], &c) |it, *ch| {
                const n = finiteF32(jnum(it)) orelse return null;
                ch.* = std.math.clamp(n, 0, 1);
            }
            return .{ .rgba = c };
        },
        else => return null,
    }
}

/// Four finite numbers out of a JSON array.
fn quadNums(v: std.json.Value) error{Skip}![4]f32 {
    if (v != .array or v.array.items.len < 4) return error.Skip;
    var out: [4]f32 = undefined;
    for (v.array.items[0..4], &out) |it, *o| {
        o.* = finiteF32(jnum(it)) orelse return error.Skip;
    }
    return out;
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

/// Vertex `i` of a frame back in ABSOLUTE world coordinates — what the shader
/// reconstructs from the origin the frame carries. The tests measure geometry,
/// so they work in the space the geometry was posted in.
fn absAt(fr: Frame, i: usize) camera.Vec2 {
    return .{ .x = @as(f64, fr.verts[i].x) + fr.origin.x, .y = @as(f64, fr.verts[i].y) + fr.origin.y };
}

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

    const base = try s.buildIfNeeded(15.0, 0, .day, null);
    const fixed = try t.allocator.dupe(Vertex, base.verts);
    defer t.allocator.free(fixed);

    // The same frame with the boat carried 0.001 degrees north.
    const ship = [2]f64{ -76.4767, 38.9773 };
    try t.expect(s.needsRebuild(15.0, 0, .day, ship));
    const moved = try s.buildIfNeeded(15.0, 0, .day, ship);
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
    try t.expect(!s.needsRebuild(15.0, 0, .day, ship));
}

// Line expansion is pure world space and the camera only rotates the MVP, so
// a dashed line must measure the same on screen at every view rotation and at
// every bearing. Angle-dependent breakage (a quadrant term in the dash or
// perpendicular math, or a per-vertex wrap decision) shows as a failing
// (bearing, rotation) pair. The sweep is 24 x 24 and pure vertex math.
//
// It runs DEEP, and at a HiDPI density. The vertex array was absolute world in
// f32, whose step is a quarter point at zoom 15 and four points at zoom 19, so
// each corner of a quad snapped to its own grid cell and a 3 pt line drew as
// anything from nothing to a wedge three times too wide, worst on the diagonal
// bearings. Nothing caught it: this test only ran at zoom 12, and every harness
// render frames the standard scene at zoom 15. A mariner works at zoom 18-21.
test "a dashed line keeps its width and dashes at every angle, zoom and density" {
    const width_pt: f64 = 3.0;
    const lat0: f64 = 38.9763;
    const lon0: f64 = -76.4767;
    const m_per_deg = 40075016.685578488 / 360.0;

    // (zoom, pixel density). The viewport is the app's own 2528 x 1460 drawable
    // expressed in POINTS, so a size is a size at either density: the camera
    // works in logical points and density lives in the projection alone.
    for ([_][2]f64{ .{ 12, 1 }, .{ 15, 2 }, .{ 19, 1 }, .{ 19, 2 }, .{ 21, 2 } }) |cfg| {
        const zoom = cfg[0];
        const density = cfg[1];
        const vw: f32 = @floatCast(2528.0 / density);
        const vh: f32 = @floatCast(1460.0 / density);
        // A line 170 pt long at whatever the zoom is: about a dozen dashes.
        const metres = 170.0 * worldPerPt(zoom) / worldPerMetre(lat0);

        var deg: f64 = 0;
        while (deg < 360) : (deg += 15) {
            var s = Store.init(t.allocator);
            defer s.deinit();
            const th = deg * std.math.pi / 180.0;
            const lat1 = lat0 + metres * @cos(th) / m_per_deg;
            const lon1 = lon0 + metres * @sin(th) / (m_per_deg * @cos(lat0 * std.math.pi / 180.0));
            var buf: [256]u8 = undefined;
            const batch = try std.fmt.bufPrint(&buf, "{{\"set\":[{{\"id\":\"v\",\"kind\":\"polyline\",\"pts\":[[{d},{d}],[{d},{d}]]," ++
                "\"width_pt\":3.0,\"dash\":true,\"color\":\"ownship\"}}]}}", .{ lon0, lat0, lon1, lat1 });
            try s.applyBatch("p", batch);
            const fr = try s.buildIfNeeded(zoom, 0, .day, null);
            const quads = fr.verts.len / 6;
            try t.expect(quads >= 8);
            // The vertices are SMALL: a harbour-sized overlay measured from its
            // own origin, not the prime meridian. This is what buys the
            // precision the widths below depend on.
            for (fr.verts) |v| try t.expect(@abs(v.x) < 0.01 and @abs(v.y) < 0.01);

            const origin = geo(.{ lon0, lat0 });
            var rot: f64 = 0;
            while (rot < 360) : (rot += 15) {
                var cam = camera.Camera{
                    .origin = origin,
                    .center = origin,
                    .zoom = zoom,
                    .target_zoom = zoom,
                    .rotation = rot * std.math.pi / 180.0,
                    .vw = vw,
                    .vh = vh,
                };
                var i: usize = 0;
                while (i < quads) : (i += 1) {
                    const p0 = absAt(fr, i * 6 + 0);
                    const p1 = absAt(fr, i * 6 + 1);
                    const p3 = absAt(fr, i * 6 + 5);
                    const w = dist(cam.worldToScreen(p0), cam.worldToScreen(p3));
                    const l = dist(cam.worldToScreen(p0), cam.worldToScreen(p1));
                    t.expectApproxEqAbs(width_pt, w, 0.05) catch |e| {
                        std.debug.print("width failed at z{d} density {d} bearing {d} rot {d} quad {d}: {d:.3} pt\n", .{ zoom, density, deg, rot, i, w });
                        return e;
                    };
                    // ...and the same width in DEVICE pixels: 3 pt is 6 px at 2x.
                    t.expectApproxEqAbs(width_pt * density, w * density, 0.1) catch |e| {
                        std.debug.print("device width failed at z{d} density {d} bearing {d} rot {d}\n", .{ zoom, density, deg, rot });
                        return e;
                    };
                    if (i + 1 < quads) t.expectApproxEqAbs(DASH_ON, l, 0.1) catch |e| {
                        std.debug.print("dash failed at z{d} density {d} bearing {d} rot {d} quad {d}: {d:.3} pt\n", .{ zoom, density, deg, rot, i, l });
                        return e;
                    };
                }
            }
        }
    }
}

/// Where you get to on `bearing_deg` true after `dist_m`, over the same sphere
/// the plugin SDK's `Point.destination` uses. The test needs the plugin's own
/// answer, not the host's, because that is what a plugin posts.
fn destination(lon_deg: f64, lat_deg: f64, bearing_deg: f64, dist_m: f64) [2]f64 {
    const R: f64 = 6371008.8;
    const lat1 = lat_deg * std.math.pi / 180.0;
    const lon1 = lon_deg * std.math.pi / 180.0;
    const brg = bearing_deg * std.math.pi / 180.0;
    const d = dist_m / R;
    const sin_lat2 = std.math.clamp(@sin(lat1) * @cos(d) + @cos(lat1) * @sin(d) * @cos(brg), -1.0, 1.0);
    const lat2 = std.math.asin(sin_lat2);
    const lon2 = lon1 + std.math.atan2(@sin(brg) * @sin(d) * @cos(lat1), @cos(d) - @sin(lat1) * sin_lat2);
    return .{ lon2 * 180.0 / std.math.pi, lat2 * 180.0 / std.math.pi };
}

// A line must REACH where the geodesy puts its far end. A plugin says "six
// minutes of travel"; the mariner reads that reach off the chart and decides
// whether there is sea room. A line that stops short is a lie about distance,
// and a quiet one — it still looks like a speed vector.
//
// The dash cut used to WALK the segment, advancing by one run at a time and
// taking the phase from @mod of the running total. That is exact only where the
// dash period is a power of two, which means an INTEGER zoom — and every dash
// test in this file ran at one. At any other zoom the total drifted a few ULP
// under a cycle boundary, @mod read the phase as a whole period instead of
// none, the next run came out below the ULP of the distance walked, and the
// guard that stops a runaway (see "a dashed line cannot run away") took that
// for the end of the line. Measured in the app at zoom 15.2: own ship's 926 m
// speed vector drew 100 m of itself, next to a 185 m heading line that was
// right because a solid line never enters the cut loop at all.
//
// So this sweeps the lengths own ship actually posts, at the fractional zooms a
// pinch leaves behind, dashed and solid, on the ownship anchor and off it.
test "a line reaches its geodesic far end at every zoom, anchored or not" {
    const lon0: f64 = -76.47494;
    const lat0: f64 = 38.97655;
    const brg: f64 = 85.0;
    const width_pt: f64 = 1.5;

    // Integer zooms, and the fractional ones a pinch or a zoom ease sits on.
    for ([_]f64{ 12.0, 15.0, 15.2, 15.73, 17.0, 18.45, 21.0 }) |zoom| {
        const wpp = worldPerPt(zoom);
        const wpm = worldPerMetre(lat0);
        // The heading line (0.1 nm), and six minutes of travel at 5 and 10 kn.
        for ([_]f64{ 185.2, 926.0, 1852.0 }) |metres| {
            for ([_]bool{ false, true }) |dashed| {
                // Off the anchor, and on it with the boat carried away from
                // the posted fix as the display position does between fixes.
                for ([_]?[2]f64{ null, .{ lon0 + 0.00003, lat0 + 0.00001 } }) |ship| {
                    var s = Store.init(t.allocator);
                    defer s.deinit();
                    const far = destination(lon0, lat0, brg, metres);
                    var buf: [512]u8 = undefined;
                    const batch = try std.fmt.bufPrint(&buf, "{{\"set\":[{{\"id\":\"v\",\"kind\":\"polyline\"," ++
                        "\"pts\":[[{d},{d}],[{d},{d}]],\"width_pt\":{d},\"dash\":{s}," ++
                        "\"color\":\"ownship\",\"anchor\":\"ownship\"}}]}}", .{ lon0, lat0, far[0], far[1], width_pt, if (dashed) "true" else "false" });
                    try s.applyBatch("p", batch);
                    const fr = try s.buildIfNeeded(zoom, 0, .day, ship);

                    // Both ends ride the anchor, so the line keeps its shape
                    // and travels with own ship's display position.
                    const sh = if (ship) |sp| [2]f64{ sp[0] - lon0, sp[1] - lat0 } else [2]f64{ 0, 0 };
                    const near_w = geo(.{ lon0 + sh[0], lat0 + sh[1] });
                    const far_w = geo(.{ far[0] + sh[0], far[1] + sh[1] });

                    var reach: f64 = 0;
                    var tip = near_w;
                    var hug: f64 = std.math.inf(f64);
                    for (0..fr.verts.len) |i| {
                        const v = absAt(fr, i);
                        const r = dist(v, near_w);
                        if (r > reach) {
                            reach = r;
                            tip = v;
                        }
                        hug = @min(hug, r);
                    }

                    // A dashed line may end inside a gap, so its last cut can
                    // sit up to one gap short of the true end; either way the
                    // corners stand half a width off the centreline.
                    const slack = (if (dashed) @as(f64, DASH_OFF) else 0.0) * wpp + width_pt * wpp;
                    const off_m = dist(tip, far_w) / wpm;
                    t.expect(dist(tip, far_w) <= slack) catch |e| {
                        std.debug.print("z{d} {d:.0} m dash={} anchored={}: far end {d:.1} m adrift, reach {d:.1} m of {d:.1}\n", .{ zoom, metres, dashed, ship != null, off_m, reach / wpm, dist(near_w, far_w) / wpm });
                        return e;
                    };
                    // ...and the near end is ON the anchor, not somewhere along it.
                    try t.expect(hug <= width_pt * wpp);

                    // The pattern itself: one quad per cycle the line covers,
                    // not the three the drifting walk stopped at.
                    const len_w = dist(near_w, far_w);
                    const cycles = @ceil(len_w / ((DASH_ON + DASH_OFF) * wpp));
                    const want: usize = if (!dashed) 1 else @intFromFloat(cycles);
                    if (dashed and cycles > MAX_DASHES_PER_SEG) continue; // draws solid by design
                    t.expectEqual(want, fr.verts.len / 6) catch |e| {
                        std.debug.print("z{d} {d:.0} m dash={}: {d} quads, wanted {d}\n", .{ zoom, metres, dashed, fr.verts.len / 6, want });
                        return e;
                    };
                }
            }
        }
    }
}

test "an aid to navigation is a diamond, and a virtual one is broken open" {
    var s = Store.init(t.allocator);
    defer s.deinit();
    // Zoom 8: the symbol spans thousands of f32 steps of world space, so the
    // measurements below are the geometry and not the vertex grid.
    const zoom = 8.0;
    const at = geo(.{ -76.4767, 38.9763 });
    const wpp = worldPerPt(zoom);
    const grid = 1e-7;

    try s.applyBatch("p",
        \\{"set":[{"id":"a","kind":"symbol","sym":"aton","at":[-76.4767,38.9763],"color":"target"}]}
    );
    var fr = try s.buildIfNeeded(zoom, 0, .day, null);
    try t.expectEqual(@as(usize, ATON_VERTS), fr.verts.len);
    // Four corners on the axes, ATON_HALF points from the anchor.
    for (0..fr.verts.len) |i| {
        const p = absAt(fr, i);
        const dx = @abs(p.x - at.x);
        const dy = @abs(p.y - at.y);
        try t.expect(dx < grid or dy < grid);
        try t.expectApproxEqAbs(ATON_HALF * wpp, @max(dx, dy), grid);
    }

    // The virtual mark is the same diamond drawn as eight strokes, so it
    // covers the same extent with far more geometry and an open middle to
    // each edge.
    try s.applyBatch("p",
        \\{"set":[{"id":"v","kind":"symbol","sym":"aton_virtual","at":[-76.4767,38.9763],"color":"target"}]}
    );
    fr = try s.buildIfNeeded(zoom, 0, .day, null);
    try t.expectEqual(@as(usize, ATON_VERTS + ATON_VIRTUAL_VERTS), fr.verts.len);
    var far: f64 = 0;
    for (ATON_VERTS..fr.verts.len) |i| {
        const p = absAt(fr, i);
        far = @max(far, @max(@abs(p.x - at.x), @abs(p.y - at.y)));
    }
    try t.expectApproxEqAbs(ATON_HALF * wpp, far, ATON_STROKE_HALF * wpp);
    // No stroke reaches the middle of an edge: the midpoint of the top-right
    // edge is bare, which is what tells a mariner nothing is in the water.
    const mid = camera.Vec2{ .x = at.x + ATON_HALF * wpp * 0.5, .y = at.y - ATON_HALF * wpp * 0.5 };
    for (ATON_VERTS..fr.verts.len) |i| {
        try t.expect(dist(absAt(fr, i), mid) > ATON_STROKE_HALF * wpp);
    }
}

test "symbol expansion vertex counts and orientation" {
    var s = Store.init(t.allocator);
    defer s.deinit();
    try s.applyBatch("p",
        \\{"set":[{"id":"o","kind":"symbol","sym":"ownship","at":[-76.4767,38.9763],"rot_deg":0,"color":"ownship"}]}
    );
    var fr = try s.buildIfNeeded(15.0, 0, .day, null);
    try t.expectEqual(@as(usize, OWNSHIP_VERTS), fr.verts.len);
    try t.expectEqual(@as(usize, 15), fr.verts.len); // 7 hull points, fanned

    // The hull fans from HULL[0]: triangles (0,1,2) (0,2,3) (0,3,4) (0,4,5)
    // (0,5,6), so HULL[4], the stem, lands at vertex 8. Heading 0 puts the
    // stem north of the anchor, which in world space (y down) is a smaller y.
    const at = geo(.{ -76.4767, 38.9763 });
    const stem_n = absAt(fr, 8);
    try t.expect(stem_n.y < at.y);
    try t.expectApproxEqAbs(at.x, stem_n.x, 1e-9);
    // The transom corners are astern of it.
    try t.expect(absAt(fr, 0).y > at.y);
    try t.expect(absAt(fr, 1).y > at.y);

    // Heading 90 (east) puts the stem to the RIGHT, at the same latitude.
    try s.applyBatch("p",
        \\{"set":[{"id":"o","kind":"symbol","sym":"ownship","at":[-76.4767,38.9763],"rot_deg":90,"color":"ownship"}]}
    );
    fr = try s.buildIfNeeded(15.0, 0, .day, null);
    const stem_e = absAt(fr, 8);
    try t.expect(stem_e.x > at.x);
    try t.expectApproxEqAbs(at.y, stem_e.y, 1e-9);

    // A target is one triangle; two objects add up.
    try s.applyBatch("p",
        \\{"set":[{"id":"t1","kind":"symbol","sym":"target","at":[-76.47,38.97],"rot_deg":210,"color":"target"}]}
    );
    fr = try s.buildIfNeeded(15.0, 0, .day, null);
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

    // The built triangles follow that rule, to the f32 vertex grid. Vertices
    // are measured from the build origin, which for one symbol is the symbol
    // itself, so a step here is a step of the OFFSET (~1e-6 world) and not of
    // an absolute coordinate — five orders finer than it used to be.
    const grid = 4.0 * 2.98e-8 * 1e-3;
    const low = measure(try s.buildIfNeeded(15.0, 0, .day, null));
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
    try t.expectEqual(@as(usize, 6), (try s.buildIfNeeded(22.0, 0, .day, null)).verts.len);

    // Repeated and reversed points: zero-length segments, and a walk that has
    // to survive its own boundary arithmetic.
    try s.applyBatch("p",
        \\{"set":[{"id":"l","kind":"polyline","pts":[[-76.48,38.98],[-76.48,38.98],[-76.4799,38.98],[-76.48,38.98]],"dash":true,"color":"track"}]}
    );
    const fr = try s.buildIfNeeded(17.0, 0, .day, null);
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
    var fr = try s.buildIfNeeded(15.0, 0, .day, null);
    try t.expectEqual(@as(usize, 12), fr.verts.len);
    const solid = fr.verts.len;

    // The same line dashed covers the same run with MORE, shorter quads.
    try s.applyBatch("p",
        \\{"set":[{"id":"l","kind":"polyline","pts":[[-76.50,38.90],[-76.48,38.92],[-76.46,38.90]],"width_pt":2,"dash":true,"color":"track"}]}
    );
    fr = try s.buildIfNeeded(15.0, 0, .day, null);
    try t.expect(fr.verts.len > solid);
    try t.expectEqual(@as(usize, 0), fr.verts.len % 6);

    // A 5-point ring fans to 3 triangles.
    s.removeSource("p");
    try s.applyBatch("p",
        \\{"set":[{"id":"z","kind":"polygon","ring":[[-76.5,38.9],[-76.4,38.9],[-76.4,39.0],[-76.45,39.05],[-76.5,39.0]],"alpha":0.25,"color":"warning"}]}
    );
    fr = try s.buildIfNeeded(15.0, 0, .day, null);
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
    const day = (try s.buildIfNeeded(15.0, 0, .day, null)).verts[0];
    const want_day = resolve(.target_danger, .day);
    try t.expectEqual(want_day[0], day.r);
    const night = (try s.buildIfNeeded(15.0, 0, .night, null)).verts[0];
    const want_night = resolve(.target_danger, .night);
    try t.expectEqual(want_night[0], night.r);
}

test "rebuild gating on zoom, scheme and apply" {
    var s = Store.init(t.allocator);
    defer s.deinit();
    try s.applyBatch("p",
        \\{"set":[{"id":"t","kind":"symbol","sym":"target","at":[-76.4,38.9],"color":"target"}]}
    );
    const g0 = (try s.buildIfNeeded(15.0, 0, .day, null)).generation;
    // Same inputs: no rebuild, same generation, so the GPU never re-uploads.
    try t.expect(!s.needsRebuild(15.0, 0, .day, null));
    try t.expectEqual(g0, (try s.buildIfNeeded(15.0, 0, .day, null)).generation);
    // Under 5% of scale: still no rebuild.
    try t.expect(!s.needsRebuild(15.05, 0, .day, null));
    // Over it: rebuild.
    try t.expect(s.needsRebuild(15.1, 0, .day, null));
    const g1 = (try s.buildIfNeeded(15.1, 0, .day, null)).generation;
    try t.expect(g1 > g0);
    // A scheme change rebuilds; so does an apply.
    try t.expect(s.needsRebuild(15.1, 0, .night, null));
    _ = try s.buildIfNeeded(15.1, 0, .night, null);
    try t.expect(!s.needsRebuild(15.1, 0, .night, null));
    try s.applyBatch("p", "{\"del\":[\"t\"]}");
    try t.expect(s.needsRebuild(15.1, 0, .night, null));
    try t.expectEqual(@as(usize, 0), (try s.buildIfNeeded(15.1, 0, .night, null)).verts.len);
}

test "symbol size tracks the zoom" {
    var s = Store.init(t.allocator);
    defer s.deinit();
    try s.applyBatch("p",
        \\{"set":[{"id":"t","kind":"symbol","sym":"target","rot_deg":0,"at":[-76.4,38.9],"color":"target"}]}
    );
    const at = geo(.{ -76.4, 38.9 });
    const fa = try s.buildIfNeeded(10.0, 0, .day, null);
    const da = at.y - absAt(fa, 1).y; // the apex
    const fb = try s.buildIfNeeded(11.0, 0, .day, null);
    const db = at.y - absAt(fb, 1).y;
    // One zoom level in = half the world size, so the symbol keeps its point
    // size. The f32 vertex grid is no longer in the way — the offsets are
    // measured from the symbol's own anchor — so the tolerance is the math's.
    try t.expectApproxEqRel(da, db * 2.0, 1e-6);
    try t.expectApproxEqRel(TARGET_TIP * worldPerPt(10.0), da, 1e-6);
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

// ---- canvas tests -----------------------------------------------------------

/// A one-glyph face for the tests: every codepoint but the space is a 0.6 x
/// 0.72 em box hung 0.7 em above the baseline, advancing 0.65 em.
const test_font_ctx: u8 = 0;
fn testGlyph(_: *const anyopaque, cp: u21) ?Glyph {
    if (cp == ' ') return .{ .u0 = 0, .v0 = 0, .u1 = 0, .v1 = 0, .off_x = 0, .off_y = 0, .w = 0, .h = 0, .advance = 0.3 };
    return .{ .u0 = 0.1, .v0 = 0.1, .u1 = 0.2, .v1 = 0.2, .off_x = 0.05, .off_y = -0.7, .w = 0.6, .h = 0.72, .advance = 0.65 };
}
fn testFont() Font {
    return .{ .ctx = &test_font_ctx, .lookup = testGlyph };
}

test "a canvas records, fills, strokes and draws text" {
    var s = Store.init(t.allocator);
    defer s.deinit();
    s.setFonts(testFont(), null);
    try s.applyBatch("p",
        \\{"set":[{"id":"g","kind":"canvas","space":"points","at":[-76.4767,38.9763],"cmds":[
        \\ ["fs",[1,0,0,1]],["P"],["M",-10,-10],["L",10,-10],["L",10,10],["L",-10,10],["Z"],["F"],
        \\ ["ss","warning"],["lw",2],["P"],["M",-20,0],["L",20,0],["S"],
        \\ ["font",12,"regular"],["ta","left"],["T",0,30,"AB"]]}]}
    );
    try t.expectEqual(@as(usize, 1), s.count());
    const fr = try s.buildIfNeeded(15.0, 0, .day, null);

    // The square ear-clips to two triangles, the one-segment stroke to two
    // more: 12 triangle vertices, fill first.
    try t.expectEqual(@as(usize, 12), fr.verts.len);
    try t.expectApproxEqAbs(@as(f32, 1), fr.verts[0].r, 1e-6);
    try t.expectApproxEqAbs(@as(f32, 0), fr.verts[0].g, 1e-6);
    const wc = resolve(.warning, .day);
    try t.expectEqual(wc[0], fr.verts[6].r);
    try t.expectEqual(wc[1], fr.verts[6].g);

    // The fill spans 20 points either way, centred on the anchor.
    const at = geo(.{ -76.4767, 38.9763 });
    const wpp = worldPerPt(15.0);
    var min_x: f64 = 1e9;
    var max_x: f64 = -1e9;
    for (fr.verts[0..6]) |v| {
        const x = @as(f64, v.x) + fr.origin.x;
        min_x = @min(min_x, x);
        max_x = @max(max_x, x);
    }
    try t.expectApproxEqRel(20.0 * wpp, max_x - min_x, 1e-4);
    try t.expectApproxEqAbs(at.x, (min_x + max_x) / 2, 1e-9);

    // Two glyphs, six quad vertices each, in the regular stream, red.
    try t.expectEqual(@as(usize, 12), fr.text.len);
    try t.expectEqual(@as(usize, 0), fr.text_bold.len);
    try t.expectEqual(@as(u8, 255), fr.text[0].color[0]);
    try t.expectEqual(@as(u8, 0), fr.text[0].color[1]);
    // The glyph boxes sit below the anchor (y = +30 pt) and above their own
    // baseline, 12 pt tall at 0.72 em.
    var min_y: f64 = 1e9;
    var max_y: f64 = -1e9;
    for (fr.text) |v| {
        const y = @as(f64, v.y) + fr.origin.y;
        min_y = @min(min_y, y);
        max_y = @max(max_y, y);
    }
    try t.expectApproxEqRel(0.72 * 12.0 * wpp, max_y - min_y, 1e-3);
    try t.expect(min_y > at.y); // below the anchor in world space (south)

    // No face wired: the text is skipped, the geometry stays, and wiring the
    // face back marks the store dirty so the text returns.
    s.setFonts(null, null);
    const bare = try s.buildIfNeeded(15.0, 0, .day, null);
    try t.expectEqual(@as(usize, 0), bare.text.len);
    try t.expectEqual(@as(usize, 12), bare.verts.len);
    s.setFonts(testFont(), null);
    try t.expect(s.needsRebuild(15.0, 0, .day, null));
    try t.expectEqual(@as(usize, 12), (try s.buildIfNeeded(15.0, 0, .day, null)).text.len);
}

test "canvas budgets refuse the whole object and spare its siblings" {
    var s = Store.init(t.allocator);
    defer s.deinit();

    // 2049 commands: refused. The good sibling in the same batch survives.
    var json = std.ArrayList(u8).empty;
    defer json.deinit(t.allocator);
    try json.appendSlice(t.allocator, "{\"set\":[{\"id\":\"big\",\"kind\":\"canvas\",\"at\":[-76.4,38.9],\"cmds\":[[\"P\"]");
    for (0..MAX_CANVAS_CMDS) |_| try json.appendSlice(t.allocator, ",[\"L\",1,2]");
    try json.appendSlice(t.allocator, "]},{\"id\":\"ok\",\"kind\":\"symbol\",\"sym\":\"target\",\"at\":[-76.4,38.9],\"color\":\"target\"}]}");
    try s.applyBatch("p", json.items);
    try t.expectEqual(@as(usize, 1), s.count());
    try t.expect(s.objs.contains("p/ok"));

    // Exactly 2048 is inside the budget.
    json.clearRetainingCapacity();
    try json.appendSlice(t.allocator, "{\"set\":[{\"id\":\"fits\",\"kind\":\"canvas\",\"at\":[-76.4,38.9],\"cmds\":[[\"P\"]");
    for (0..MAX_CANVAS_CMDS - 1) |_| try json.appendSlice(t.allocator, ",[\"L\",1,2]");
    try json.appendSlice(t.allocator, "]}]}");
    try s.applyBatch("p", json.items);
    try t.expect(s.objs.contains("p/fits"));
    try t.expectEqual(@as(usize, MAX_CANVAS_CMDS), s.objs.get("p/fits").?.cmds.len);

    // A text run over 256 bytes refuses its object.
    json.clearRetainingCapacity();
    try json.appendSlice(t.allocator, "{\"set\":[{\"id\":\"txt\",\"kind\":\"canvas\",\"at\":[-76.4,38.9],\"cmds\":[[\"T\",0,0,\"");
    for (0..MAX_CANVAS_TEXT + 1) |_| try json.append(t.allocator, 'a');
    try json.appendSlice(t.allocator, "\"]]}]}");
    try s.applyBatch("p", json.items);
    try t.expect(!s.objs.contains("p/txt"));

    // An unknown command refuses its object like any malformed row.
    try s.applyBatch("p",
        \\{"set":[{"id":"odd","kind":"canvas","at":[-76.4,38.9],"cmds":[["hologram",1]]}]}
    );
    try t.expect(!s.objs.contains("p/odd"));
}

test "canvas spaces: points hold their screen size, geo scales with the chart" {
    var s = Store.init(t.allocator);
    defer s.deinit();
    const lat = 38.9763;
    try s.applyBatch("p",
        \\{"set":[{"id":"pt","kind":"canvas","space":"points","at":[-76.4767,38.9763],"cmds":[
        \\ ["P"],["M",-10,0],["L",10,0],["L",0,5],["Z"],["F"]]},
        \\ {"id":"m","kind":"canvas","space":"geo","at":[-76.4767,38.9763],"cmds":[
        \\ ["P"],["M",-50,0],["L",50,0],["L",0,25],["Z"],["F"]]}]}
    );
    for ([_]f64{ 12.0, 15.0 }) |zoom| {
        const fr = try s.buildIfNeeded(zoom, 0, .day, null);
        try t.expectEqual(@as(usize, 6), fr.verts.len);
        var pt_span: f64 = 0;
        var m_span: f64 = 0;
        var min_x = [2]f64{ 1e9, 1e9 };
        var max_x = [2]f64{ -1e9, -1e9 };
        for (fr.verts, 0..) |v, i| {
            const which = i / 3;
            const x = @as(f64, v.x) + fr.origin.x;
            min_x[which] = @min(min_x[which], x);
            max_x[which] = @max(max_x[which], x);
        }
        pt_span = max_x[0] - min_x[0];
        m_span = max_x[1] - min_x[1];
        // 20 points at this zoom; 100 metres at this latitude, any zoom.
        try t.expectApproxEqRel(20.0 * worldPerPt(zoom), pt_span, 1e-4);
        try t.expectApproxEqRel(100.0 * worldPerMetre(lat), m_span, 1e-4);
    }
}

test "canvas gradients colour per vertex and tokens resolve per scheme" {
    var s = Store.init(t.allocator);
    defer s.deinit();
    try s.applyBatch("p",
        \\{"set":[{"id":"g","kind":"canvas","at":[-76.4767,38.9763],"cmds":[
        \\ ["fs",{"lin":[-10,0,10,0],"stops":[[0,[0,0,0,1]],[1,[1,1,1,1]]]}],
        \\ ["P"],["M",-10,-10],["L",10,-10],["L",10,10],["L",-10,10],["Z"],["F"]]}]}
    );
    var fr = try s.buildIfNeeded(15.0, 0, .day, null);
    const at = geo(.{ -76.4767, 38.9763 });
    const wpp = worldPerPt(15.0);
    try t.expectEqual(@as(usize, 6), fr.verts.len);
    for (fr.verts) |v| {
        const cx = ((@as(f64, v.x) + fr.origin.x) - at.x) / wpp; // canvas x, points
        const want = std.math.clamp((cx + 10.0) / 20.0, 0, 1);
        try t.expectApproxEqAbs(want, @as(f64, v.r), 1e-3);
        try t.expectApproxEqAbs(want, @as(f64, v.g), 1e-3);
        try t.expectApproxEqAbs(@as(f64, 1), @as(f64, v.a), 1e-6);
    }

    // A token in a canvas resolves per scheme, so the seven names still read
    // as part of the chart.
    try s.applyBatch("p",
        \\{"set":[{"id":"g","kind":"canvas","at":[-76.4767,38.9763],"cmds":[
        \\ ["fs","ownship"],["P"],["M",0,0],["L",10,0],["L",0,10],["Z"],["F"]]}]}
    );
    fr = try s.buildIfNeeded(15.0, 0, .day, null);
    const day = resolve(.ownship, .day);
    try t.expectEqual(day[0], fr.verts[0].r);
    fr = try s.buildIfNeeded(15.0, 0, .night, null);
    const night = resolve(.ownship, .night);
    try t.expectEqual(night[0], fr.verts[0].r);
}

test "canvas transforms, save/restore and the ship anchor" {
    var s = Store.init(t.allocator);
    defer s.deinit();
    // rotate(90) carries a point drawn at north round to east; the saved
    // state must come back untouched.
    try s.applyBatch("p",
        \\{"set":[{"id":"g","kind":"canvas","at":[-76.4767,38.9763],"anchor":"ownship","cmds":[
        \\ ["sv"],["rot",90],["P"],["M",0,-10],["L",1,-10],["L",0,-9],["Z"],["F"],["rs"],
        \\ ["tr",5,0],["P"],["M",0,0],["L",1,0],["L",0,1],["Z"],["F"]]}]}
    );
    const fr = try s.buildIfNeeded(15.0, 0, .day, null);
    // Two three-point fills: one triangle each.
    try t.expectEqual(@as(usize, 6), fr.verts.len);
    const at = geo(.{ -76.4767, 38.9763 });
    const wpp = worldPerPt(15.0);
    // First triangle: (0,-10) rotated 90 clockwise lands 10 pt EAST.
    try t.expectApproxEqAbs(at.x + 10.0 * wpp, @as(f64, fr.verts[0].x) + fr.origin.x, wpp * 0.01);
    try t.expectApproxEqAbs(at.y, @as(f64, fr.verts[0].y) + fr.origin.y, wpp * 0.01);
    // Second triangle: the restore dropped the rotation, so the translate
    // moves it 5 pt east and nothing else.
    try t.expectApproxEqAbs(at.x + 5.0 * wpp, @as(f64, fr.verts[3].x) + fr.origin.x, wpp * 0.01);
    try t.expectApproxEqAbs(at.y, @as(f64, fr.verts[3].y) + fr.origin.y, wpp * 0.01);

    // The whole canvas rides own ship's display position.
    const ship = [2]f64{ -76.4767, 38.9773 };
    try t.expect(s.needsRebuild(15.0, 0, .day, ship));
    const moved = try s.buildIfNeeded(15.0, 0, .day, ship);
    const dy = geo(ship).y - at.y;
    try t.expectApproxEqAbs(at.y + dy, @as(f64, moved.verts[0].y) + moved.origin.y, wpp * 0.01);
}

// The screen-aligned frame: one recording mixes content that turns with the
// chart (a compass card) and content that stays upright (a readout and the
// plate behind it). The proof is on SCREEN, so these measure through the
// camera the renderer uses.
test "a screen-aligned run keeps its screen geometry as the view turns" {
    var s = Store.init(t.allocator);
    defer s.deinit();
    s.setFonts(testFont(), null);
    // A chart-aligned triangle at north, then a screen-aligned triangle at the
    // same place with a text run under it.
    try s.applyBatch("p",
        \\{"set":[{"id":"g","kind":"canvas","space":"points","at":[-76.4767,38.9763],"cmds":[
        \\ ["P"],["M",0,-20],["L",4,-20],["L",0,-16],["Z"],["F"],
        \\ ["sv"],["sa",1],
        \\ ["P"],["M",0,-20],["L",4,-20],["L",0,-16],["Z"],["F"],
        \\ ["font",12,"regular"],["ta","left"],["T",0,30,"A"],["rs"]]}]}
    );
    try t.expect(s.objs.get("p/g").?.screen_aligned);
    try t.expect(s.has_screen_aligned);

    const at = geo(.{ -76.4767, 38.9763 });
    const wpp = worldPerPt(15.0);
    // Screen offsets from the anchor, in points, through the renderer's camera.
    const S = struct {
        fn off(rot: f64, at_w: camera.Vec2, w: camera.Vec2) [2]f64 {
            const cam = camera.Camera{ .origin = at_w, .center = at_w, .zoom = 15.0, .rotation = rot, .vw = 800, .vh = 600 };
            const a = cam.worldToScreen(at_w);
            const b = cam.worldToScreen(w);
            return .{ b.x - a.x, b.y - a.y };
        }
    };

    for ([_]f64{ 0, 30, 90, -135, 180 }) |deg| {
        const rot = std.math.degreesToRadians(deg);
        const fr = try s.buildIfNeeded(15.0, rot, .day, null);
        try t.expectEqual(@as(usize, 6), fr.verts.len);
        try t.expectEqual(@as(usize, 6), fr.text.len);

        // The chart-aligned corner turns with the chart: (0,-20) points at
        // true north, which the turned camera carries round to (20 sin, -20 cos).
        const chart = S.off(rot, at, absAt(fr, 0));
        try t.expectApproxEqAbs(20.0 * @sin(rot), chart[0], 0.01);
        try t.expectApproxEqAbs(-20.0 * @cos(rot), chart[1], 0.01);

        // The screen-aligned corner does not: it lands 20 points above the
        // anchor on the display at every rotation.
        const level = S.off(rot, at, absAt(fr, 3));
        try t.expectApproxEqAbs(@as(f64, 0), level[0], 0.01);
        try t.expectApproxEqAbs(@as(f64, -20), level[1], 0.01);
        // Its WORLD geometry did turn, by minus the view, which is what the
        // camera then undoes.
        try t.expectApproxEqAbs(at.x - 20.0 * @sin(rot) * wpp, absAt(fr, 3).x, wpp * 0.01);

        // The text with it: the glyph box sits 30 points below the anchor and
        // its top edge is horizontal on the display, so the run reads level.
        const g0 = S.off(rot, at, .{ .x = @as(f64, fr.text[0].x) + fr.origin.x, .y = @as(f64, fr.text[0].y) + fr.origin.y });
        const g1 = S.off(rot, at, .{ .x = @as(f64, fr.text[1].x) + fr.origin.x, .y = @as(f64, fr.text[1].y) + fr.origin.y });
        try t.expectApproxEqAbs(g0[1], g1[1], 0.01); // level
        try t.expect(g1[0] > g0[0]); // and running left to right
        try t.expectApproxEqAbs(30.0 - 0.7 * 12.0, g0[1], 0.05); // 0.7 em above its baseline
    }

    // Turning the view rebuilds the scene only because something in it is
    // screen-aligned, and only past the tolerance.
    _ = try s.buildIfNeeded(15.0, 0, .day, null);
    try t.expect(!s.needsRebuild(15.0, 0, .day, null));
    try t.expect(!s.needsRebuild(15.0, ROT_REBUILD_DRAD * 0.5, .day, null));
    try t.expect(s.needsRebuild(15.0, 0.2, .day, null));

    // A canvas that never asks is not rebuilt for a turning view at all.
    var plain = Store.init(t.allocator);
    defer plain.deinit();
    try plain.applyBatch("p",
        \\{"set":[{"id":"g","kind":"canvas","at":[-76.4767,38.9763],"cmds":[
        \\ ["P"],["M",0,-20],["L",4,-20],["L",0,-16],["Z"],["F"]]}]}
    );
    _ = try plain.buildIfNeeded(15.0, 0, .day, null);
    try t.expect(!plain.has_screen_aligned);
    try t.expect(!plain.needsRebuild(15.0, 1.5, .day, null));
}

test "screenAligned is scoped and reversible, and cancels a local rotation" {
    var s = Store.init(t.allocator);
    defer s.deinit();
    const rot = std.math.degreesToRadians(90.0);
    // Inside a rotate(90) of the author's own: the flag holds the corner level
    // on screen anyway, and turning it off hands the author's frame back.
    try s.applyBatch("p",
        \\{"set":[{"id":"g","kind":"canvas","at":[-76.4767,38.9763],"cmds":[
        \\ ["rot",90],
        \\ ["sa",1],["P"],["M",0,-20],["L",4,-20],["L",0,-16],["Z"],["F"],
        \\ ["sa",0],["P"],["M",0,-20],["L",4,-20],["L",0,-16],["Z"],["F"]]}]}
    );
    const fr = try s.buildIfNeeded(15.0, rot, .day, null);
    const at = geo(.{ -76.4767, 38.9763 });
    const wpp = worldPerPt(15.0);
    // Screen-aligned under the view's 90 and the author's 90: the world point
    // is 20 points WEST, which the camera carries back to straight up.
    try t.expectApproxEqAbs(at.x - 20.0 * wpp, absAt(fr, 0).x, wpp * 0.01);
    try t.expectApproxEqAbs(at.y, absAt(fr, 0).y, wpp * 0.01);
    // Turned off, the author's rotate(90) is back: north goes to chart east.
    try t.expectApproxEqAbs(at.x + 20.0 * wpp, absAt(fr, 3).x, wpp * 0.01);
    try t.expectApproxEqAbs(at.y, absAt(fr, 3).y, wpp * 0.01);
}

test "canvas clip confines a fill to the clip path" {
    var s = Store.init(t.allocator);
    defer s.deinit();
    try s.applyBatch("p",
        \\{"set":[{"id":"g","kind":"canvas","at":[-76.4767,38.9763],"cmds":[
        \\ ["P"],["M",-5,-5],["L",5,-5],["L",5,5],["L",-5,5],["Z"],["C"],
        \\ ["P"],["M",-20,-20],["L",20,-20],["L",20,20],["L",-20,20],["Z"],["F"]]}]}
    );
    const fr = try s.buildIfNeeded(15.0, 0, .day, null);
    try t.expect(fr.verts.len >= 6);
    const at = geo(.{ -76.4767, 38.9763 });
    const wpp = worldPerPt(15.0);
    for (fr.verts) |v| {
        const cx = ((@as(f64, v.x) + fr.origin.x) - at.x) / wpp;
        const cy = ((@as(f64, v.y) + fr.origin.y) - at.y) / wpp;
        try t.expect(@abs(cx) <= 5.001 and @abs(cy) <= 5.001);
    }
}

test "a canvas arc closes into a ring the fill can take" {
    var s = Store.init(t.allocator);
    defer s.deinit();
    // A full circle, filled: ARC_SEGS_FULL segments fan into a disc that
    // stays inside its radius and covers most of its area.
    try s.applyBatch("p",
        \\{"set":[{"id":"g","kind":"canvas","at":[-76.4767,38.9763],"cmds":[
        \\ ["P"],["A",0,0,10,0,360,false],["Z"],["F"]]}]}
    );
    const fr = try s.buildIfNeeded(15.0, 0, .day, null);
    try t.expect(fr.verts.len >= 3 * (ARC_SEGS_FULL - 2));
    const at = geo(.{ -76.4767, 38.9763 });
    const wpp = worldPerPt(15.0);
    for (fr.verts) |v| {
        const cx = ((@as(f64, v.x) + fr.origin.x) - at.x) / wpp;
        const cy = ((@as(f64, v.y) + fr.origin.y) - at.y) / wpp;
        try t.expect(std.math.hypot(cx, cy) <= 10.001);
    }
}

test "a thick stroked circle is an annulus: nothing reaches the middle" {
    var s = Store.init(t.allocator);
    defer s.deinit();
    // The demo's bezel: radius 55, width 26. Everything the stroke emits
    // must stay inside the band; the window in the middle stays open. Both
    // the open full circle and the closePath'd one, whose closing point
    // lands a rounding error away from the start and once fed the joins a
    // noise-direction segment, and with every join and cap in play.
    try s.applyBatch("p",
        \\{"set":[{"id":"g","kind":"canvas","at":[-76.4767,38.9763],"cmds":[
        \\ ["lw",26],["P"],["A",0,0,55,0,360,false],["S"]]},
        \\ {"id":"gz","kind":"canvas","at":[-76.4767,38.9763],"cmds":[
        \\ ["lw",26],["join","round"],["cap","round"],["P"],["A",0,0,55,0,360,false],["Z"],["S"]]},
        \\ {"id":"gm","kind":"canvas","at":[-76.4767,38.9763],"cmds":[
        \\ ["lw",26],["join","bevel"],["P"],["A",0,0,55,0,360,false],["Z"],["S"]]}]}
    );
    const fr = try s.buildIfNeeded(15.0, 0, .day, null);
    try t.expect(fr.verts.len >= 3 * 6 * 60);
    const at = geo(.{ -76.4767, 38.9763 });
    const wpp = worldPerPt(15.0);
    var i: usize = 0;
    while (i + 2 < fr.verts.len) : (i += 3) {
        var tri: [3][2]f64 = undefined;
        for (0..3) |k| {
            const v = fr.verts[i + k];
            tri[k] = .{
                ((@as(f64, v.x) + fr.origin.x) - at.x) / wpp,
                ((@as(f64, v.y) + fr.origin.y) - at.y) / wpp,
            };
            const rr = std.math.hypot(tri[k][0], tri[k][1]);
            // Inside the band: never nearer the centre than the inner edge,
            // never further out than the outer edge plus the miter's reach.
            t.expect(rr > 55.0 - 13.0 - 0.01 and rr < 55.0 + 13.0 + 0.5) catch |e| {
                std.debug.print("stroke vertex at radius {d:.2} (tri {d})\n", .{ rr, i / 3 });
                return e;
            };
        }
        // And no triangle may cover the centre point.
        const o = [2]f64{ 0, 0 };
        const inside = pointInTri(o, tri[0], tri[1], tri[2], 1) or pointInTri(o, tri[0], tri[1], tri[2], -1);
        t.expect(!inside) catch |e| {
            std.debug.print("triangle {d} covers the centre\n", .{i / 3});
            return e;
        };
    }
}
