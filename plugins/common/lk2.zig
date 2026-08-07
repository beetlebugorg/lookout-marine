//! The plugin API. Declare what you read, and draw.
//!
//!   const lk = @import("lk2");
//!
//!   comptime { lk.plugin(@This()); }
//!
//!   pub const inputs = struct {
//!       pub const boat = lk.position("navigation.position", .{});
//!       pub const twd = lk.number("environment.wind.directionTrue", .{ .label = "wind" });
//!   };
//!
//!   pub fn draw(c: *lk.Chart) void {
//!       const from = inputs.boat.get();
//!       c.line("windline", &.{ from, from.destination(twdOf() + 180, lk.nm(1)) },
//!           .{ .color = .warning, .dash = true });
//!   }
//!
//! THREE TIERS. Tier 1 is the block above: inputs and `draw`. Tier 2 adds
//! `lk.connections` — the library owns the sockets, the reconnect clock and
//! the per-row status, and the plugin writes `onData`. Tier 3 is `onEvent`,
//! the raw event union, for whatever the first two do not cover.
//!
//! WHAT THE LIBRARY OWNS, so an author never writes it:
//!
//!   * the subscription, and one recorded value per declared input, aged
//!     against the monotonic clock rather than the wall clock;
//!   * the draw timer. `draw` runs at `draw_rate_ms`, 1 Hz by default, not on
//!     every store change: the store fans out at up to 10 Hz;
//!   * the freshness gate. `draw` runs only when every required input is
//!     inside its window. Otherwise the scene is cleared and the status names
//!     every missing input at once;
//!   * the scene. `draw` describes the whole picture each call; the library
//!     compares it with the last one and sends only what changed. An object
//!     not drawn this call is deleted. There is no delete call and no buffer;
//!   * the status line, deduped. The host logs every status text it has not
//!     seen, so a repeat would be a log line a second;
//!   * the settings, parsed into a typed struct, with the manifest's schema
//!     generated from the same declaration.
//!
//! WHAT A PLUGIN MAY DECLARE at its root. All of it is optional; `plugin`
//! reads what is there and wires only that.
//!
//!   inputs           a struct of `lk.number` / `lk.position` / `lk.ais`
//!   draw(c)          the scene, on the library's timer
//!   draw_rate_ms     how often, default 1000
//!   Settings         one settings group, or a tuple of them
//!   onSettings()     after a settings change, before the redraw
//!   Connections      a tier-2 connection list
//!   onData(row, b)   the bytes off one row's socket        (tier 2)
//!   onOpen(row)      a stream came up; send a subscription (tier 2)
//!   onClose(row)     a stream ended                        (tier 2)
//!   rowNote(row)     a phrase after a connected row's rate (tier 2)
//!   endpoint(row)    where to dial, when it is not host:port (tier 2)
//!   onStart(s)       anything else at startup
//!   onEvent(e)       every event the library did not consume (tier 3)
//!   onShutdown()     the last word
//!
//! TARGET. wasm32-freestanding: no threads, no filesystem, no clock but the
//! two the host lends. Everything is single-threaded by contract, so plugin
//! state is plain globals. `lk.scratch()` is reset the moment your function
//! returns; anything that must outlive an event is a global or lives in the
//! library.
//!
//! The raw ABI is unchanged and is re-exported below as `lk.raw` for tier 3.

const std = @import("std");
const raw_lk = @import("lk.zig");
const schema = @import("schema.zig");
const conn = @import("conn.zig");

/// The raw host-call shim: the imports, the event union, the JSON builders.
/// Tier 3 uses it directly; tiers 1 and 2 never need it.
pub const raw = raw_lk;

pub const abi_version = raw_lk.abi_version;

// ---------------------------------------------------------------------------
// The numbers the library fixes
// ---------------------------------------------------------------------------

/// One 5 s window rules all vessel data. The store, and every shipped plugin,
/// use the same number. Override it per input where the data is slower.
pub const default_max_age_ms: i64 = 5_000;

/// How often `draw` runs when the plugin declares no rate.
pub const default_draw_rate_ms: i64 = 1_000;

/// Most objects one plugin's scene may hold. The host's own budget is 4096
/// across every plugin; this is the table the diff keeps.
pub const max_objects = 512;

/// Longest overlay object id the diff table keeps.
pub const max_object_id = 48;

/// The scene batch buffer, holding the objects that changed and the ids that
/// went. A 600-point track is the largest thing any shipped plugin says, at
/// about 45 bytes a point, so this has better than two to one in hand.
pub const scene_bytes = 64 * 1024;

/// Metres in a nautical mile.
pub const nm_m: f64 = 1852.0;

/// A distance in metres from a distance in nautical miles.
pub fn nm(n: f64) f64 {
    return n * nm_m;
}

/// Knots from metres per second. Everything crossing the ABI is SI; this is
/// for text a mariner reads.
pub fn knots(mps: f64) f64 {
    return mps * 1.9438444924406046;
}

const earth_radius_m: f64 = 6371008.8;

// ---------------------------------------------------------------------------
// Places
// ---------------------------------------------------------------------------

/// A place on the earth. Latitude first, always: the overlay wire format puts
/// longitude first and this type is what keeps that out of plugin code.
pub const Point = struct {
    lat: f64,
    lon: f64,

    /// Where you get to on `bearing_deg` true after `dist_m`. A sphere, not
    /// the ellipsoid the chart is drawn on: the error over 1 nm is under 4 m.
    pub fn destination(self: Point, bearing_deg: f64, dist_m: f64) Point {
        const lat1 = std.math.degreesToRadians(self.lat);
        const lon1 = std.math.degreesToRadians(self.lon);
        const brg = std.math.degreesToRadians(normalizeDeg(bearing_deg));
        const d = dist_m / earth_radius_m;

        const sin_lat1 = @sin(lat1);
        const cos_lat1 = @cos(lat1);
        const sin_d = @sin(d);
        const cos_d = @cos(d);

        const sin_lat2 = std.math.clamp(sin_lat1 * cos_d + cos_lat1 * sin_d * @cos(brg), -1.0, 1.0);
        const lat2 = std.math.asin(sin_lat2);
        const lon2 = lon1 + std.math.atan2(
            @sin(brg) * sin_d * cos_lat1,
            cos_d - sin_lat1 * sin_lat2,
        );
        return .{
            .lat = std.math.radiansToDegrees(lat2),
            // Folded, so a leg across the antimeridian does not post a
            // longitude the host would refuse.
            .lon = wrapLon(std.math.radiansToDegrees(lon2)),
        };
    }

    /// The initial great-circle bearing to `other`, degrees true.
    pub fn bearingTo(self: Point, other: Point) f64 {
        const lat1 = std.math.degreesToRadians(self.lat);
        const lat2 = std.math.degreesToRadians(other.lat);
        const dlon = std.math.degreesToRadians(wrapLon(other.lon - self.lon));
        const y = @sin(dlon) * @cos(lat2);
        const x = @cos(lat1) * @sin(lat2) - @sin(lat1) * @cos(lat2) * @cos(dlon);
        return normalizeDeg(std.math.radiansToDegrees(std.math.atan2(y, x)));
    }

    /// Metres to `other`, over the same sphere.
    pub fn distanceTo(self: Point, other: Point) f64 {
        const lat1 = std.math.degreesToRadians(self.lat);
        const lat2 = std.math.degreesToRadians(other.lat);
        const dlat = lat2 - lat1;
        const dlon = std.math.degreesToRadians(wrapLon(other.lon - self.lon));
        const s1 = @sin(dlat / 2);
        const s2 = @sin(dlon / 2);
        const h = s1 * s1 + @cos(lat1) * @cos(lat2) * s2 * s2;
        return 2 * earth_radius_m * std.math.asin(@sqrt(std.math.clamp(h, 0.0, 1.0)));
    }

    /// False for a position off the earth or carrying a NaN. The library
    /// refuses one before it records it.
    pub fn valid(self: Point) bool {
        return std.math.isFinite(self.lat) and std.math.isFinite(self.lon) and
            @abs(self.lat) <= 90.0 and @abs(self.lon) <= 180.0;
    }
};

/// A bearing folded into 0..360.
pub fn normalizeDeg(deg: f64) f64 {
    if (!std.math.isFinite(deg)) return 0;
    const r = @mod(deg, 360.0);
    return if (r < 0) r + 360.0 else r;
}

/// A longitude folded into -180..180.
pub fn wrapLon(deg: f64) f64 {
    if (!std.math.isFinite(deg)) return 0;
    return @mod(deg + 180.0, 360.0) - 180.0;
}

/// A short string kept by value. A plugin has no allocator that outlives an
/// event, so everything held between events is a fixed buffer.
pub const Str = schema.Str;

// ---------------------------------------------------------------------------
// Clocks and logging
// ---------------------------------------------------------------------------

pub const Level = raw_lk.Level;

/// Wall clock, milliseconds since the epoch.
pub fn nowMs() i64 {
    return raw_lk.nowMs();
}

/// Monotonic milliseconds. Measure intervals with this; it does not jump when
/// the boat's clock is set from a fresh GPS fix.
pub fn monoMs() i64 {
    return raw_lk.monoMs();
}

/// Log one formatted line. Truncated at 512 bytes.
pub fn log(level: Level, comptime fmt: []const u8, args: anytype) void {
    raw_lk.logf(level, fmt, args);
}

/// The per-call scratch allocator, reset the moment your handler returns.
pub fn scratch() std.mem.Allocator {
    return raw_lk.scratch();
}

// ---------------------------------------------------------------------------
// Inputs
// ---------------------------------------------------------------------------

/// How one declared input behaves.
pub const InputOpts = struct {
    /// What the status line calls this reading when it is missing: `no wind`.
    /// Defaults to the last segment of the path.
    label: []const u8 = "",
    /// How old the value may be and still count. One 5 s window rules all
    /// vessel data; raise it for a reading that arrives on a slower clock.
    max_age_ms: i64 = default_max_age_ms,
    /// An optional input never blocks `draw` and never reaches the status
    /// line. It has no `get`: read it with `fresh`, and decide yourself.
    optional: bool = false,
};

/// The value and enough to age it between events. The host stamps `age_ms` at
/// delivery; the monotonic clock carries it on from there.
fn Sample(comptime T: type) type {
    return struct {
        const Self = @This();
        value: T = undefined,
        have: bool = false,
        at_mono_ms: i64 = 0,
        age_at_ms: i64 = 0,

        fn stamp(self: *Self, v: T, age_ms: i64, mono: i64) void {
            self.value = v;
            self.have = true;
            self.at_mono_ms = mono;
            self.age_at_ms = if (age_ms > 0) age_ms else 0;
        }

        fn ageMs(self: Self, mono: i64) i64 {
            return self.age_at_ms + (mono - self.at_mono_ms);
        }

        fn fresh(self: Self, mono: i64, limit_ms: i64) bool {
            return self.have and self.ageMs(mono) <= limit_ms;
        }
    };
}

fn lastSegment(comptime path: []const u8) []const u8 {
    comptime {
        var start = 0;
        for (path, 0..) |c, i| {
            if (c == '.') start = i + 1;
        }
        return path[start..];
    }
}

fn Input(comptime T: type, comptime path_: []const u8, comptime opts: InputOpts) type {
    return struct {
        const Self = @This();

        pub const lk_input_kind: enum { number, position } = if (T == Point) .position else .number;
        pub const lk_path = path_;
        pub const lk_opts = opts;
        pub const lk_label: []const u8 = if (opts.label.len > 0) opts.label else lastSegment(path_);

        var sample: Sample(T) = .{};

        /// The value, or null when nothing has arrived or what arrived is
        /// older than the window. Safe anywhere, at any time.
        pub fn fresh() ?T {
            return if (sample.fresh(monoMs(), opts.max_age_ms)) sample.value else null;
        }

        /// The value. A required input is fresh whenever `draw` runs, so this
        /// needs no null check there. Outside `draw`, use `fresh`.
        pub fn get() T {
            if (opts.optional) @compileError(
                "'" ++ path_ ++ "' is an optional input, so it may be missing when draw runs. " ++
                    "Use fresh() and handle the null, or drop `.optional = true` to have the " ++
                    "library hold the draw until the value arrives.",
            );
            return sample.value;
        }

        /// How old the value is, or null when there is none.
        pub fn ageMs() ?i64 {
            return if (sample.have) sample.ageMs(monoMs()) else null;
        }

        fn lkFresh(mono: i64) bool {
            return sample.fresh(mono, opts.max_age_ms);
        }

        fn lkRecord(r: raw_lk.Reading, mono: i64) void {
            // A null value means the path has no source left. Treat it as
            // removal: the reading is gone, not zero.
            if (r.removed()) {
                sample.have = false;
                return;
            }
            switch (comptime lk_input_kind) {
                .position => {
                    const p = r.position() orelse return;
                    const at = Point{ .lat = p[0], .lon = p[1] };
                    if (!at.valid()) return;
                    sample.stamp(at, r.age_ms, mono);
                },
                .number => {
                    const v = r.number() orelse return;
                    if (!std.math.isFinite(v)) return;
                    sample.stamp(v, r.age_ms, mono);
                },
            }
        }
    };
}

/// A number off the vessel store: a speed, a depth, a wind direction.
pub fn number(comptime path: []const u8, comptime opts: InputOpts) type {
    return Input(f64, path, opts);
}

/// A position off the vessel store, as a `Point`.
pub fn position(comptime path: []const u8, comptime opts: InputOpts) type {
    return Input(Point, path, opts);
}

// ---------------------------------------------------------------------------
// AIS traffic
// ---------------------------------------------------------------------------

/// One vessel or aid the AIS receiver has heard. Absent fields are null:
/// "never heard" and "heard as zero" are different things at sea.
pub const Target = struct {
    mmsi: u32 = 0,
    at: ?Point = null,
    /// Metres per second.
    sog_mps: ?f64 = null,
    cog_deg: ?f64 = null,
    heading_deg: ?f64 = null,
    /// True for an aid to navigation, which has its own aging and no CPA.
    aton: bool = false,
    aton_type: ?u8 = null,
    virtual_aton: bool = false,
    off_position: ?bool = null,
    /// How old the report is, carried forward from delivery.
    age_ms: i64 = 0,
    name_str: Str(32) = .{},

    pub fn name(self: *const Target) []const u8 {
        return self.name_str.text();
    }
};

pub const AisOpts = struct {
    /// Most targets kept. A snapshot longer than this is truncated and logged.
    max: usize = 128,
};

/// The AIS target set, recorded and aged by the library. Declare it beside the
/// vessel inputs; it never holds the draw back, because an empty sea is not a
/// missing instrument.
pub fn ais(comptime opts: AisOpts) type {
    return struct {
        pub const lk_ais = true;

        var list: [opts.max]Target = @splat(.{});
        var count: usize = 0;
        var at_mono_ms: i64 = 0;

        /// Every target in the last snapshot, aged to now.
        pub fn targets() []const Target {
            const carried = monoMs() - at_mono_ms;
            for (list[0..count]) |*t| t.age_ms += carried;
            at_mono_ms += carried;
            return list[0..count];
        }

        /// The target with this MMSI, or null.
        pub fn find(mmsi: u32) ?*const Target {
            for (list[0..count]) |*t| {
                if (t.mmsi == mmsi) return t;
            }
            return null;
        }

        fn lkRecord(payload: []const u8, mono: i64) void {
            const in = raw_lk.targets(payload);
            count = @min(in.len, opts.max);
            if (in.len > opts.max) log(.warn, "ais: {d} targets, keeping {d}", .{ in.len, opts.max });
            for (in[0..count], list[0..count]) |src, *dst| {
                dst.* = .{
                    .mmsi = src.mmsi,
                    .at = if (src.lat != null and src.lon != null)
                        Point{ .lat = src.lat.?, .lon = src.lon.? }
                    else
                        null,
                    .sog_mps = src.sog,
                    .cog_deg = src.cog,
                    .heading_deg = src.heading,
                    .aton = src.aton,
                    .aton_type = src.aton_type,
                    .virtual_aton = src.virtual_aton,
                    .off_position = src.off_position,
                    .age_ms = src.age_ms,
                };
                if (src.name) |n| dst.name_str.set(n);
            }
            at_mono_ms = mono;
        }
    };
}

// ---------------------------------------------------------------------------
// Drawing
// ---------------------------------------------------------------------------

/// The palette tokens. A plugin names a token; the core resolves it per
/// day/dusk/night scheme, which is why an overlay never carries an RGB.
pub const Color = raw_lk.Color;

/// The symbol shapes the core draws.
pub const Sym = raw_lk.Sym;

/// Where an object sits. `ownship` rides own ship's display position, which
/// the core carries forward between fixes, so the object does not step once a
/// second while the chart slides smoothly.
pub const Anchor = enum { fixed, ownship };

var scene: Scene = .{};

/// The retained scene: what is on the chart, and what changed since the last
/// call to `draw`.
const Scene = struct {
    const Entry = struct {
        id: Str(max_object_id) = .{},
        hash: u64 = 0,
        live: bool = false,
        seen: bool = false,
    };

    entries: [max_objects]Entry = @splat(.{}),
    n: usize = 0,

    /// The batch, built in place: `{"set":[` while `draw` runs, then the
    /// deletes and the closing brace at commit. One buffer, no copy — the wasm
    /// stack is 64 KiB and cannot hold a second one.
    buf: [scene_bytes]u8 = undefined,
    len: usize = 0,
    sets: usize = 0,
    overflowed: bool = false,

    const prefix = "{\"set\":[";

    fn find(self: *Scene, id: []const u8) ?*Entry {
        for (self.entries[0..self.n]) |*e| {
            if (e.id.eql(id)) return e;
        }
        return null;
    }

    fn begin(self: *Scene) void {
        for (self.entries[0..self.n]) |*e| e.seen = false;
        self.len = 0;
        self.sets = 0;
        self.overflowed = false;
        self.put(prefix);
    }

    fn put(self: *Scene, text: []const u8) void {
        if (self.len + text.len > self.buf.len) {
            self.overflowed = true;
            return;
        }
        @memcpy(self.buf[self.len..][0..text.len], text);
        self.len += text.len;
    }

    /// Take one serialized object. `start` is where its separator began and
    /// `body` where the object itself did; an object that has not changed
    /// since the last call rewinds both, because it is already on the chart.
    fn take(self: *Scene, id: []const u8, start: usize, body: usize) void {
        if (self.overflowed) {
            self.len = start;
            return;
        }
        const hash = std.hash.Fnv1a_64.hash(self.buf[body..self.len]);
        if (self.find(id)) |e| {
            e.seen = true;
            if (e.live and e.hash == hash) {
                self.len = start;
                return;
            }
            e.hash = hash;
            e.live = true;
            self.sets += 1;
            return;
        }
        if (self.n == max_objects) {
            self.len = start;
            log(.warn, "overlay: more than {d} objects; \"{s}\" dropped", .{ max_objects, id });
            return;
        }
        const e = &self.entries[self.n];
        self.n += 1;
        e.id.set(id);
        e.hash = hash;
        e.live = true;
        e.seen = true;
        self.sets += 1;
    }

    /// Send what changed, and delete what this call did not draw.
    fn commit(self: *Scene) void {
        var dels: usize = 0;
        for (self.entries[0..self.n]) |*e| {
            if (e.live and !e.seen) dels += 1;
        }
        if (self.overflowed) {
            log(.warn, "overlay dropped: the scene did not fit in {d} bytes", .{self.buf.len});
            self.forget();
            return;
        }
        if (self.sets == 0 and dels == 0) return;

        self.put("],\"del\":[");
        var k: usize = 0;
        for (self.entries[0..self.n]) |*e| {
            if (!e.live or e.seen) continue;
            if (k > 0) self.put(",");
            k += 1;
            var w = Writer{};
            w.str(e.id.text());
        }
        self.put("]}");
        if (self.overflowed) {
            log(.warn, "overlay dropped: the batch did not fit in {d} bytes", .{self.buf.len});
            self.forget();
            return;
        }
        if (raw_lk.overlayJson(self.buf[0..self.len]) < 0) {
            // The host refused the batch, so what is on the chart no longer
            // matches the table. Forget it; the next call redraws in full.
            self.forget();
            return;
        }
        // An object deleted this call leaves the table.
        var w: usize = 0;
        for (self.entries[0..self.n]) |e| {
            if (e.live and e.seen) {
                self.entries[w] = e;
                w += 1;
            }
        }
        self.n = w;
    }

    /// Drop every memory of what is drawn. The next call sends the whole
    /// scene again.
    fn forget(self: *Scene) void {
        self.n = 0;
        self.len = 0;
        self.sets = 0;
    }
};

/// What a plugin draws on, handed to `draw`.
///
/// Describe the whole picture every call. The library compares it with the
/// last one: an object with the same id and the same shape is left alone, a
/// changed one is replaced, and one you did not draw is taken off the chart.
pub const Chart = struct {
    /// A line's weight, colour and whether it is dashed. `width_pt` is screen
    /// points, not metres: the core converts at the live zoom.
    pub const Line = struct {
        color: Color,
        width_pt: f64 = 1.5,
        dash: bool = false,
        anchor: Anchor = .fixed,
    };

    /// A symbol's colour, rotation and size. `rot_deg` is a true bearing,
    /// clockwise from north.
    pub const Symbol = struct {
        color: Color,
        rot_deg: f64 = 0,
        scale: f64 = 1,
        anchor: Anchor = .fixed,
        pick: ?Pick = null,
    };

    /// A filled ring. `alpha` multiplies the token's own alpha.
    pub const Area = struct {
        color: Color,
        alpha: f64 = 1,
    };

    /// What the shell shows when the mariner hovers or taps a symbol. The
    /// values are strings you have already formatted: only the plugin knows
    /// the unit. Lines and areas carry no payload — there is no single point
    /// to measure a tap against.
    pub const Pick = struct {
        title: []const u8 = "",
        rows: []const [2][]const u8 = &.{},
    };

    state: State = .running,
    detail: Str(160) = .{},
    said: bool = false,

    /// A line through `pts`, in order. Two points at least.
    pub fn line(self: *Chart, id: []const u8, pts: []const Point, style: Line) void {
        _ = self;
        if (pts.len < 2) return;
        var b = Writer.init();
        b.raw("{\"id\":");
        b.str(id);
        b.raw(",\"kind\":\"polyline\",\"pts\":[");
        b.points(pts);
        b.raw("],\"width_pt\":");
        b.num(style.width_pt);
        b.print(",\"dash\":{s},\"color\":\"{s}\"", .{
            if (style.dash) "true" else "false",
            @tagName(style.color),
        });
        b.anchor(style.anchor);
        b.raw("}");
        b.done(id);
    }

    /// A symbol at `at`.
    pub fn symbol(self: *Chart, id: []const u8, sym: Sym, at: Point, style: Symbol) void {
        _ = self;
        if (!at.valid()) return;
        var b = Writer.init();
        b.raw("{\"id\":");
        b.str(id);
        b.print(",\"kind\":\"symbol\",\"sym\":\"{s}\",\"at\":[", .{@tagName(sym)});
        b.num(at.lon);
        b.raw(",");
        b.num(at.lat);
        b.raw("],\"rot_deg\":");
        b.num(style.rot_deg);
        b.raw(",\"scale\":");
        b.num(style.scale);
        b.print(",\"color\":\"{s}\"", .{@tagName(style.color)});
        b.anchor(style.anchor);
        if (style.pick) |p| {
            b.raw(",\"pick\":{\"title\":");
            b.str(p.title);
            b.raw(",\"rows\":[");
            for (p.rows, 0..) |r, i| {
                if (i > 0) b.raw(",");
                b.raw("[");
                b.str(r[0]);
                b.raw(",");
                b.str(r[1]);
                b.raw("]");
            }
            b.raw("]}");
        }
        b.raw("}");
        b.done(id);
    }

    /// A filled area. The ring is closed for you; three points at least.
    pub fn area(self: *Chart, id: []const u8, ring: []const Point, style: Area) void {
        _ = self;
        if (ring.len < 3) return;
        var b = Writer.init();
        b.raw("{\"id\":");
        b.str(id);
        b.raw(",\"kind\":\"polygon\",\"ring\":[");
        b.points(ring);
        b.raw("],\"alpha\":");
        b.num(style.alpha);
        b.print(",\"color\":\"{s}\"}}", .{@tagName(style.color)});
        b.done(id);
    }

    /// Say the plugin is working, and what it is doing. Posted once; the
    /// library sends nothing while the text is unchanged.
    pub fn status(self: *Chart, comptime fmt: []const u8, args: anytype) void {
        self.say(.running, fmt, args);
    }

    /// Say the plugin is short of something. The library adds nothing: name
    /// the instrument, so a mariner knows which one to look at.
    pub fn degraded(self: *Chart, comptime fmt: []const u8, args: anytype) void {
        self.say(.degraded, fmt, args);
    }

    fn say(self: *Chart, s: State, comptime fmt: []const u8, args: anytype) void {
        var buf: [160]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        w.print(fmt, args) catch {};
        self.state = s;
        self.detail.set(w.buffered());
        self.said = true;
    }
};

/// Writes one overlay object straight into the scene buffer, so an unchanged
/// object costs a serialize and no allocation.
const Writer = struct {
    /// Where this object's separator went, so an unchanged object rewinds it
    /// too and leaves no comma behind.
    start: usize = 0,
    body: usize = 0,

    fn init() Writer {
        var w = Writer{ .start = scene.len };
        if (scene.sets > 0) w.raw(",");
        w.body = scene.len;
        return w;
    }

    fn raw(_: *Writer, text: []const u8) void {
        scene.put(text);
    }

    fn print(self: *Writer, comptime fmt: []const u8, args: anytype) void {
        var tmp: [256]u8 = undefined;
        var w = std.Io.Writer.fixed(&tmp);
        w.print(fmt, args) catch {
            scene.overflowed = true;
            return;
        };
        self.raw(w.buffered());
    }

    fn str(self: *Writer, s: []const u8) void {
        self.raw("\"");
        for (s) |c| switch (c) {
            '"' => self.raw("\\\""),
            '\\' => self.raw("\\\\"),
            '\n' => self.raw("\\n"),
            '\r' => self.raw("\\r"),
            '\t' => self.raw("\\t"),
            0...8, 11, 12, 14...31 => self.print("\\u{x:0>4}", .{c}),
            else => self.raw(&[_]u8{c}),
        };
        self.raw("\"");
    }

    /// A finite number, or `null`: an infinity in a payload is a bug the host
    /// would reject, so it never leaves here.
    fn num(self: *Writer, v: f64) void {
        if (std.math.isFinite(v)) self.print("{d}", .{v}) else self.raw("null");
    }

    fn points(self: *Writer, pts: []const Point) void {
        for (pts, 0..) |p, i| {
            if (i > 0) self.raw(",");
            self.raw("[");
            self.num(p.lon);
            self.raw(",");
            self.num(p.lat);
            self.raw("]");
        }
    }

    fn anchor(self: *Writer, a: Anchor) void {
        if (a == .ownship) self.raw(",\"anchor\":\"ownship\"");
    }

    /// Close the object and hand it to the diff.
    fn done(self: *Writer, id: []const u8) void {
        scene.take(id, self.start, self.body);
    }
};

// ---------------------------------------------------------------------------
// The status line
// ---------------------------------------------------------------------------

/// What the chrome says about a plugin. The host logs a status text it has not
/// seen before, so the library posts only on a change.
pub const State = enum { starting, running, degraded, stopped };

var last_state: Str(16) = .{};
var last_detail: Str(160) = .{};
var said_once = false;

/// Post one status line, deduped. Nothing is sent while the state and the
/// detail are what they already were.
pub fn say(state: State, comptime fmt: []const u8, args: anytype) void {
    var buf: [160]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    w.print(fmt, args) catch {};
    sayText(@tagName(state), w.buffered());
}

fn sayText(state: []const u8, detail: []const u8) void {
    if (said_once and last_state.eql(state) and last_detail.eql(detail)) return;
    said_once = true;
    last_state.set(state);
    last_detail.set(detail);
    raw_lk.status(state, "{s}", .{detail});
}

/// Forget the last status, so the next post goes out whatever it says. Tier 2
/// calls this: its status carries per-row items the dedupe cannot see.
fn forgetStatus() void {
    said_once = false;
}

// ---------------------------------------------------------------------------
// Alerts
// ---------------------------------------------------------------------------

pub const Severity = raw_lk.Severity;

/// Raise an alert. Needs the `alerts.raise` capability.
///
/// Raise one when the mariner must act now and would not otherwise know.
/// Everything else is a status line: an alarm that cries wolf is switched off,
/// and then the real one is not heard.
pub fn alert(severity: Severity, title: []const u8, body: []const u8) i32 {
    return raw_lk.raiseAlert(severity, title, body);
}

// ---------------------------------------------------------------------------
// Publishing
// ---------------------------------------------------------------------------

var publish_buf: [4096]u8 = undefined;

/// A batch of vessel values. The library owns the buffer and stamps every
/// value with the host's wall clock, which is what the store ages against.
///
///   var p = lk.Publish.begin();
///   p.number("navigation.speedOverGround", mps);
///   p.position("navigation.position", .{ .lat = lat, .lon = lon });
///   _ = p.send();
pub const Publish = struct {
    b: raw_lk.Publish,
    ts: i64,

    pub fn begin() Publish {
        return .{ .b = raw_lk.Publish.init(&publish_buf), .ts = nowMs() };
    }

    pub fn number(self: *Publish, path: []const u8, v: f64) void {
        self.b.number(path, v, self.ts);
    }

    pub fn position(self: *Publish, path: []const u8, at: Point) void {
        self.b.position(path, at.lat, at.lon, self.ts);
    }

    /// This source holds the path and has no reading for it right now.
    pub fn clear(self: *Publish, path: []const u8) void {
        self.b.clear(path, self.ts);
    }

    /// The number of values the host took, or -1. An empty batch is not sent
    /// and answers 0.
    pub fn send(self: *Publish) i32 {
        return self.b.send();
    }
};

var upsert_buf: [8192]u8 = undefined;

/// A batch of AIS targets. `sog_mps` is metres per second: everything crossing
/// the ABI is SI, whatever the wire format reported.
pub const Upsert = struct {
    b: raw_lk.AisUpsert,
    ts: i64,

    pub fn begin() Upsert {
        return .{ .b = raw_lk.AisUpsert.init(&upsert_buf), .ts = nowMs() };
    }

    pub fn target(self: *Upsert, t: Target) void {
        self.b.target(.{
            .mmsi = t.mmsi,
            .lat = if (t.at) |p| p.lat else null,
            .lon = if (t.at) |p| p.lon else null,
            .sog = t.sog_mps,
            .cog = t.cog_deg,
            .heading = t.heading_deg,
            .name = if (t.name_str.len > 0) t.name() else null,
            .aton = t.aton,
            .aton_type = t.aton_type,
            .virtual_aton = t.virtual_aton,
            .off_position = t.off_position,
            .ts_ms = self.ts,
        });
    }

    pub fn send(self: *Upsert) i32 {
        return self.b.send();
    }
};

// ---------------------------------------------------------------------------
// Settings
// ---------------------------------------------------------------------------

pub const Tab = schema.Tab;
pub const Num = schema.Num;
pub const Flag = schema.Flag;
pub const Text = schema.Text;

fn SettingsStore(comptime G: type) type {
    return struct {
        var values: schema.Values(G) = .{};
    };
}

/// The current value of every setting in one declared group.
///
///   const s = lk.settings(Settings);
///   if (s.cpa_alarm) …
pub fn settings(comptime G: type) schema.Values(G) {
    return SettingsStore(G).values;
}

/// The `"settings"` object the manifest must carry for these groups. A
/// plugin's own native test compares it with the manifest it ships.
pub const settingsJson = schema.settingsJson;
pub const expectManifest = schema.expectManifest;

// ---------------------------------------------------------------------------
// Connections
// ---------------------------------------------------------------------------

pub const ConnOpts = conn.Opts;
pub const Endpoint = conn.Endpoint;

/// A list of connections the mariner keeps, owned by the library: the settings
/// rows, the sockets, the reconnect clock, the per-row status and the pause
/// switch. See `conn.zig` for what a row carries.
pub fn connections(comptime opts: conn.Opts) type {
    return conn.Connections(opts);
}

// ---------------------------------------------------------------------------
// Registration
// ---------------------------------------------------------------------------

/// Emit the ABI exports and wire them to what the plugin declares. Call once,
/// at container scope:
///
///   comptime { lk.plugin(@This()); }
///
/// Everything is optional. A plugin that declares only `draw` gets a timer and
/// a scene; one that declares only `onEvent` is a raw tier-3 plugin.
pub fn plugin(comptime P: type) void {
    const D = Declared(P);
    const Impl = struct {
        var draw_timer: i64 = -1;

        pub fn start(s: raw_lk.Start) !void {
            readSettings(P, s.config);

            if (comptime D.inputs.len > 0) {
                if (raw_lk.subscribePaths(&D.paths) < 0) return error.SubscribeRefused;
            }
            if (comptime D.has_ais) {
                if (raw_lk.aisSubscribe() < 0) return error.AisSubscribeRefused;
            }
            if (comptime D.has_connections) {
                P.Connections.lkStart(P, s.config);
            }
            if (comptime D.has_draw) {
                draw_timer = raw_lk.timerSet(D.draw_rate_ms, true);
                if (draw_timer < 0) return error.TimerRefused;
                if (comptime D.required_labels.len > 0) {
                    say(.starting, "waiting for {s}", .{comptime joinLabels(D.required_labels, ", ")});
                } else say(.starting, "", .{});
            }
            if (comptime @hasDecl(P, "onStart")) try P.onStart(s);
        }

        pub fn onEvent(e: raw_lk.Event) !void {
            switch (e) {
                .store_changed => |payload| if (comptime D.inputs.len > 0) {
                    const mono = monoMs();
                    for (raw_lk.readings(payload)) |r| {
                        inline for (D.inputs) |In| {
                            if (std.mem.eql(u8, r.path, In.lk_path)) In.lkRecord(r, mono);
                        }
                    }
                    return;
                },
                .ais_changed => |payload| if (comptime D.has_ais) {
                    D.Ais.lkRecord(payload, monoMs());
                    return;
                },
                .config_changed => |payload| {
                    const cfg = std.json.parseFromSliceLeaky(std.json.Value, scratch(), payload, .{}) catch
                        return;
                    readSettings(P, cfg);
                    if (comptime D.has_connections) P.Connections.lkConfig(P, cfg);
                    if (comptime @hasDecl(P, "onSettings")) P.onSettings();
                    // A changed setting must show now, not at the next tick.
                    if (comptime D.has_draw) runDraw();
                    return;
                },
                .timer => |id| {
                    if (comptime D.has_draw) {
                        if (id == draw_timer) {
                            runDraw();
                            return;
                        }
                    }
                    if (comptime D.has_connections) {
                        if (P.Connections.lkTimer(P, id)) return;
                    }
                },
                .shutdown => {
                    if (comptime D.has_draw) {
                        if (draw_timer >= 0) raw_lk.timerCancel(draw_timer);
                    }
                    if (comptime D.has_connections) P.Connections.lkShutdown();
                    if (comptime @hasDecl(P, "onShutdown")) P.onShutdown();
                    // The host drops every overlay object a stopped plugin
                    // owns, so there is nothing to delete here.
                    sayText("stopped", "shut down");
                    return;
                },
                else => {
                    if (comptime D.has_connections) {
                        if (P.Connections.lkEvent(P, e)) return;
                    }
                },
            }
            if (comptime @hasDecl(P, "onEvent")) try P.onEvent(e);
        }

        /// One frame: gate on freshness, let the plugin describe the scene,
        /// send the difference, and post the status.
        fn runDraw() void {
            const mono = monoMs();
            var missing: [D.required_labels.len][]const u8 = undefined;
            var n: usize = 0;
            inline for (D.inputs) |In| {
                if (comptime !In.lk_opts.optional) {
                    if (!In.lkFresh(mono)) {
                        missing[n] = In.lk_label;
                        n += 1;
                    }
                }
            }
            if (n > 0) {
                // Every missing input is named: a line that says "no wind"
                // while the GPS is also out sends the mariner to the wrong
                // instrument.
                var buf: [160]u8 = undefined;
                var w = std.Io.Writer.fixed(&buf);
                for (missing[0..n], 0..) |m, i| {
                    if (i > 0) w.writeAll(", ") catch {};
                    w.print("no {s}", .{m}) catch {};
                }
                scene.begin();
                scene.commit(); // draws nothing, so everything drawn is deleted
                sayText("degraded", w.buffered());
                return;
            }

            var c = Chart{};
            scene.begin();
            P.draw(&c);
            scene.commit();
            if (c.said) sayText(@tagName(c.state), c.detail.text()) else sayText("running", "");
        }
    };
    raw_lk.registerPlugin(Impl);
}

fn readSettings(comptime P: type, config: std.json.Value) void {
    if (!@hasDecl(P, "Settings")) return;
    inline for (comptime groupList(P.Settings)) |G| {
        schema.read(G, &SettingsStore(G).values, config);
    }
}

/// `Settings` is one group struct, or a tuple of them. Resolved through a
/// container constant so the result is comptime whatever the call site.
pub fn groupList(comptime S: anytype) []const type {
    return struct {
        const list: []const type = blk: {
            if (@TypeOf(S) == type) break :blk &.{S};
            var out: [S.len]type = undefined;
            for (S, 0..) |G, i| out[i] = G;
            const frozen = out;
            break :blk &frozen;
        };
    }.list;
}

fn joinLabels(comptime labels: []const []const u8, comptime sep: []const u8) []const u8 {
    comptime {
        var out: []const u8 = "";
        for (labels, 0..) |l, i| {
            if (i > 0) out = out ++ sep;
            out = out ++ l;
        }
        return out;
    }
}

/// What the plugin's root declares, read once at comptime.
fn Declared(comptime P: type) type {
    return struct {
        const has_draw = @hasDecl(P, "draw");
        const has_connections = @hasDecl(P, "Connections");
        const draw_rate_ms: i64 = if (@hasDecl(P, "draw_rate_ms")) P.draw_rate_ms else default_draw_rate_ms;

        const inputs: []const type = blk: {
            if (!@hasDecl(P, "inputs")) break :blk &.{};
            var out: []const type = &.{};
            for (@typeInfo(P.inputs).@"struct".decls) |d| {
                const T = @field(P.inputs, d.name);
                if (@TypeOf(T) != type) continue;
                if (@hasDecl(T, "lk_path")) out = out ++ &[_]type{T};
            }
            break :blk out;
        };

        const has_ais = Ais != void;
        const Ais: type = blk: {
            if (!@hasDecl(P, "inputs")) break :blk void;
            for (@typeInfo(P.inputs).@"struct".decls) |d| {
                const T = @field(P.inputs, d.name);
                if (@TypeOf(T) != type) continue;
                if (@hasDecl(T, "lk_ais")) break :blk T;
            }
            break :blk void;
        };

        const paths: [inputs.len][]const u8 = blk: {
            var out: [inputs.len][]const u8 = undefined;
            for (inputs, 0..) |In, i| out[i] = In.lk_path;
            break :blk out;
        };

        const required_labels: []const []const u8 = blk: {
            var out: []const []const u8 = &.{};
            for (inputs) |In| {
                if (!In.lk_opts.optional) out = out ++ &[_][]const u8{In.lk_label};
            }
            break :blk out;
        };
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const expect = std.testing;

const annapolis = Point{ .lat = 38.9763, .lon = -76.4767 };

test "1 nm at 090 from Annapolis lands where the flat-earth check says" {
    const p = annapolis.destination(90, nm_m);

    // Flat approximation for the same leg: dlon = d / (R cos lat).
    const dlon_deg = std.math.radiansToDegrees(nm_m /
        (earth_radius_m * @cos(std.math.degreesToRadians(annapolis.lat))));
    try expect.expectApproxEqAbs(annapolis.lon + dlon_deg, p.lon, 1e-6);
    try expect.expectApproxEqAbs(@as(f64, -76.4552757), p.lon, 1e-7);

    // Due east is the vertex of its great circle, so the latitude falls off by
    // a fraction of a metre rather than holding exactly.
    try expect.expectApproxEqAbs(annapolis.lat, p.lat, 1e-5);
    try expect.expect(p.lat < annapolis.lat);

    try expect.expectApproxEqAbs(nm_m, annapolis.distanceTo(p), 0.01);
    try expect.expectApproxEqAbs(@as(f64, 90), annapolis.bearingTo(p), 1e-6);
}

test "the cardinal legs are one mile long and point where they were sent" {
    for ([_]f64{ 0, 45, 90, 135, 180, 225, 270, 315, 359 }) |brg| {
        const p = annapolis.destination(brg, nm_m);
        try expect.expectApproxEqAbs(nm_m, annapolis.distanceTo(p), 0.01);
        try expect.expectApproxEqAbs(brg, annapolis.bearingTo(p), 1e-6);
    }

    // Due north: the latitude change is the arc over the radius, exactly.
    const north = annapolis.destination(0, nm_m);
    const dlat_deg = std.math.radiansToDegrees(nm_m / earth_radius_m);
    try expect.expectApproxEqAbs(annapolis.lat + dlat_deg, north.lat, 1e-9);
    try expect.expectApproxEqAbs(annapolis.lon, north.lon, 1e-12);
}

test "a bearing out of range is the same leg as its folded form" {
    const a = annapolis.destination(-270, nm_m);
    const b = annapolis.destination(90, nm_m);
    try expect.expectApproxEqAbs(b.lat, a.lat, 1e-12);
    try expect.expectApproxEqAbs(b.lon, a.lon, 1e-12);
}

test "a leg across the antimeridian keeps its longitude on the chart" {
    const fiji = Point{ .lat = -17.0, .lon = 179.95 };
    const p = fiji.destination(90, nm(10));
    try expect.expect(p.lon < 0); // it crossed, and folded rather than ran on
    try expect.expect(p.lon > -180);
    try expect.expectApproxEqAbs(nm(10), fiji.distanceTo(p), 0.1);
}

test "a longitude folds into the chart's range" {
    try expect.expectApproxEqAbs(@as(f64, -179), wrapLon(181), 1e-12);
    try expect.expectApproxEqAbs(@as(f64, 179), wrapLon(-181), 1e-12);
    try expect.expectApproxEqAbs(@as(f64, -76.4767), wrapLon(-76.4767), 1e-12);
}

test "a bearing folds into the compass" {
    try expect.expectApproxEqAbs(@as(f64, 10), normalizeDeg(370), 1e-9);
    try expect.expectApproxEqAbs(@as(f64, 350), normalizeDeg(-10), 1e-9);
    try expect.expectEqual(@as(f64, 0), normalizeDeg(std.math.nan(f64)));
}

test "a position off the earth is refused" {
    try expect.expect((Point{ .lat = 38.9, .lon = -76.4 }).valid());
    try expect.expect(!(Point{ .lat = 91, .lon = 0 }).valid());
    try expect.expect(!(Point{ .lat = 0, .lon = std.math.nan(f64) }).valid());
}

test "a label defaults to the last segment of the path" {
    try expect.expectEqualStrings("position", comptime lastSegment("navigation.position"));
    try expect.expectEqualStrings("depth", comptime lastSegment("depth"));
}

test "labels join in the order they were declared" {
    try expect.expectEqualStrings("wind, position", comptime joinLabels(&.{ "wind", "position" }, ", "));
    try expect.expectEqualStrings("wind", comptime joinLabels(&.{"wind"}, ", "));
}
