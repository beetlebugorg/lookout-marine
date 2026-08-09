//! The plugin API. Declare what you read, and draw.
//!
//!   const lk = @import("lk2");
//!
//!   comptime { lk.plugin(@This()); }
//!
//!   pub const inputs = struct {
//!       pub const boat = lk.subscribePosition("navigation.position", .{});
//!       pub const twd = lk.subscribeNumber("environment.wind.directionTrue", .{ .label = "wind" });
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
//!     every store change: the store fans out at up to 10 Hz. It runs only
//!     while there is somewhere for a scene to land, so a plugin whose
//!     `overlay.draw` grant the mariner has switched off stops drawing until
//!     it comes back;
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
//! WHERE A DECISION BELONGS. `onUpdate` runs the moment a declared input has a
//! new value, with every input already current. It is the clock for work that
//! is not drawing: a plugin that only watches a condition declares `onUpdate`
//! and no `draw`, and a plugin that does both keeps the decision here and
//! renders it there. `draw_rate_ms` is a graphics rate an author picked, so a
//! decision taken in `draw` runs at whatever rate suits the picture. The host
//! coalesces, so `onUpdate` runs at most once per batch: 10 Hz for store
//! values, 2 Hz for the AIS set, and slower when the instruments are slower.
//!
//! `onUpdate` ALSO RUNS WHEN A VALUE EXPIRES. A plugin that only heard about
//! arrivals could never notice an absence. A value carries its window, so
//! the moment it stops counting is known when it lands: the library arms a
//! one-shot for the earliest such moment across the declared inputs and runs
//! the cycle there. The input reads stale in that call, and the plugin empties
//! what depended on it. Windows differ, so each input expires on its own
//! wakeup. Nothing polls: once every input has expired there is no next
//! moment, nothing is armed, and an idle plugin costs nothing at all until the
//! next value arrives. A plugin with no declared inputs has nothing that can
//! expire and hears only about arrivals.
//!
//! The declared inputs decide that, not the declarations beside them. A plugin
//! that only draws is woken the same way, because a picture held up by a
//! value that stopped counting is a confident drawing of a guess and has to
//! come off the chart.
//!
//! A TABLE IS FILLED FROM `onUpdate`. Rows are data. The library opens a table
//! cycle before `onUpdate` and closes it after, so a plugin upserts its rows
//! there and nowhere else. A plugin does not need to request a capability to
//! fill a table, so its rows keep arriving while the chart grant is off and
//! the draw timer is down.
//!
//! WHAT A PLUGIN MAY DECLARE at its root. All of it is optional; `plugin`
//! reads what is there and wires only that.
//!
//!   inputs                a struct of `lk.subscribeNumber` /
//!                         `lk.subscribePosition` / `lk.subscribeAis`
//!   draw(c)               the scene, on the library's timer
//!   draw_rate_ms          how often, default 1000
//!   onUpdate()            after an input changed: the decision, and the rows
//!   an `lk.table(.{…})`   a dialog the mariner opens, filled from `onUpdate`
//!   Settings              one settings group, or a tuple of them
//!   onSettings()          after a settings change, before the redraw
//!   Connections           a connection list
//!   onData(conn, b)       bytes from one connection's socket
//!   onOpen(conn)          a stream came up; send a subscription
//!   onClose(conn)         a stream ended
//!   connectionNote(conn)  a phrase after the connection's rate
//!   endpoint(conn)        where to dial, when it is not host:port
//!   onStart(s)            anything else at startup
//!   onEvent(e)            every event the library did not consume
//!   onShutdown()          the last word
//!
//! MIXING TIERS. A plugin may declare `inputs` and still want a path raw.
//! Ask for it with `lk.subscribeAlso`, never `lk.raw.subscribePaths`: the host
//! holds ONE subscription per plugin and a second call replaces the first, so
//! the raw form takes the declared inputs off the wire without saying so. The
//! declared values go to the inputs; the rest reach `onEvent` as a
//! `.store_changed` carrying only those.
//!
//! TARGET. wasm32-freestanding: no threads, no filesystem, no clock but the
//! two the host lends. Everything is single-threaded by contract, so plugin
//! state is plain globals. `lk.scratch()` is reset the moment your function
//! returns; anything that must outlive an event is a global or lives in the
//! library.
//!
//! The raw wire calls are unchanged and re-exported below as `lk.raw`.

const std = @import("std");
const builtin = @import("builtin");
const raw_lk = @import("lk.zig");
const schema = @import("schema.zig");
const conn = @import("conn.zig");

/// The raw host-call shim: the imports, the event union, the JSON builders.
/// `onEvent` uses it directly; the declared surface never needs it.
pub const raw = raw_lk;

pub const api_version = raw_lk.api_version;

// ---------------------------------------------------------------------------
// The numbers the library fixes
// ---------------------------------------------------------------------------

/// One 5 s window rules all vessel data. The store, and every shipped plugin,
/// use the same number. Override it per input where the data is slower.
pub const default_max_age_ms: i64 = 5_000;

/// How often `draw` runs when the plugin declares no rate.
pub const default_draw_rate_ms: i64 = 1_000;

/// How long an AIS vessel's report stays interesting when the plugin declares
/// no window, and the same for an aid to navigation. Both match the host's
/// eviction clocks: past them the target is out of the store and no snapshot
/// can carry it again.
pub const default_ais_max_age_ms: i64 = 600_000;
pub const default_aton_max_age_ms: i64 = 1_800_000;

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

/// Knots from metres per second. Everything crossing the API is SI; this is
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

/// Log one formatted line. Truncated at 512 bytes. On a native build the
/// line goes to stderr (and nowhere under the test runner, which reads a
/// step's stderr as a failure report), so a test may reach any library path
/// without linking the wasm host imports.
pub fn log(level: Level, comptime fmt: []const u8, args: anytype) void {
    if (comptime builtin.target.cpu.arch != .wasm32) {
        if (!builtin.is_test) std.debug.print("[{s}] " ++ fmt ++ "\n", .{@tagName(level)} ++ args);
        return;
    }
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
    /// What the status line calls this value when it is missing: `no wind`.
    /// Defaults to the last segment of the path.
    label: []const u8 = "",
    /// How old the value may be and still count. One 5 s window rules all
    /// vessel data; raise it for a value that arrives on a slower clock.
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

        /// The monotonic moment this value stops counting, or null when it
        /// already has. The window is known the moment the value lands, so
        /// its expiry is an appointment rather than something to poll for.
        fn staleAt(self: Self, mono: i64, limit_ms: i64) ?i64 {
            if (!self.have) return null;
            const at = self.at_mono_ms + limit_ms - self.age_at_ms;
            return if (at > mono) at else null;
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

        fn lkStaleAt(mono: i64) ?i64 {
            return sample.staleAt(mono, opts.max_age_ms);
        }

        fn lkRecord(r: raw_lk.PathValue, mono: i64) void {
            // A null value means the path has no source left. Treat it as
            // removal: the value is gone, not zero.
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
pub fn subscribeNumber(comptime path: []const u8, comptime opts: InputOpts) type {
    return Input(f64, path, opts);
}

/// A position off the vessel store, as a `Point`.
pub fn subscribePosition(comptime path: []const u8, comptime opts: InputOpts) type {
    return Input(Point, path, opts);
}

/// Paths one plugin may hold at once, its declared inputs and its raw ones
/// together. The host takes a list; this is what `subscribeAlso` will build.
pub const max_subscribe_paths = 16;

/// The paths `plugin()` subscribed to on the plugin's behalf. Read by
/// `subscribeAlso`, which has to send them again.
var declared_paths: []const []const u8 = &.{};

/// Subscribe to `extra` BESIDE the inputs the plugin declared.
///
/// THE HOST HOLDS ONE SUBSCRIPTION PER PLUGIN, and a second `subscribePaths`
/// REPLACES the first. A plugin that declares `inputs` and then calls
/// `lk.raw.subscribePaths` for a path of its own therefore takes its own
/// declared inputs off the wire, silently, and the draw goes to "no position"
/// for ever. This sends the union instead, so both keep arriving.
///
/// The declared values go to the inputs as usual; the rest reach the
/// plugin's own `onEvent` as a `.store_changed` carrying only those.
pub fn subscribeAlso(extra: []const []const u8) i32 {
    var all: [max_subscribe_paths][]const u8 = undefined;
    const n = unionPaths(&all, extra) orelse {
        log(.warn, "subscribe: more than {d} paths between the declared inputs and this call; refused", .{max_subscribe_paths});
        return -1;
    };
    if (n == 0) return -1;
    return raw_lk.subscribePaths(all[0..n]);
}

/// The declared paths followed by `extra`, duplicates dropped, written into
/// `out`. Null when the union would not fit, which refuses the subscription
/// whole rather than trimming it: a plugin missing one path it asked for is
/// worse than one told it asked for too many.
fn unionPaths(out: *[max_subscribe_paths][]const u8, extra: []const []const u8) ?usize {
    var n: usize = 0;
    for (declared_paths) |p| {
        if (n == out.len) return null;
        out[n] = p;
        n += 1;
    }
    for (extra) |p| {
        var seen = false;
        for (out[0..n]) |had| {
            if (std.mem.eql(u8, had, p)) seen = true;
        }
        if (seen) continue;
        if (n == out.len) return null;
        out[n] = p;
        n += 1;
    }
    return n;
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
    /// How long a vessel's report stays interesting. Past it the target can no
    /// longer change anything the plugin decides, so the library stops waking
    /// for it. Set it to the age at which this plugin drops a target.
    max_age_ms: i64 = default_ais_max_age_ms,
    /// The same, for an aid to navigation. An aid reports about every three
    /// minutes, so a vessel's window would age one out while it is still on
    /// station.
    aton_max_age_ms: i64 = default_aton_max_age_ms,
};

/// The AIS target set, recorded and aged by the library. Declare it beside the
/// vessel inputs; it never holds the draw back, because an empty sea is not a
/// missing instrument.
pub fn subscribeAis(comptime opts: AisOpts) type {
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

        /// When the next target in the set ages out, monotonic, or null when
        /// none can. Each target keeps its own clock, so the set produces one
        /// appointment per target rather than one for the snapshot.
        fn lkStaleAt(mono: i64) ?i64 {
            var next: ?i64 = null;
            for (list[0..count]) |*t| {
                const window = if (t.aton) opts.aton_max_age_ms else opts.max_age_ms;
                const at = at_mono_ms + window - t.age_ms;
                if (at <= mono) continue;
                if (next == null or at < next.?) next = at;
            }
            return next;
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

    /// Open a canvas object: a recorded drawing anchored like any other
    /// object and diffed like one. Record onto the
    /// returned Canvas, then call `done()` — always, even after an error.
    ///
    ///   var cv = c.canvas("dial", .{ .at = boat, .anchor = .ownship });
    ///   cv.beginPath();
    ///   cv.arc(0, 0, 60, 0, 360, false);
    ///   cv.fillStyle(.{ .rgba = .{ 0.1, 0.1, 0.1, 0.6 } });
    ///   cv.fill();
    ///   cv.done();
    ///
    /// Coordinates are canvas units around the anchor, x right and y DOWN:
    /// `points` hold their screen size across zoom, `geo` units are metres on
    /// the ground. Stroke widths and text sizes are screen points in both.
    /// Night is yours: free RGBA is not dimmed by the core, so read the
    /// scheme or use the tokens. The drawing turns with the chart under
    /// course-up; `screenAligned` holds a run of it level on screen.
    pub fn canvas(self: *Chart, id: []const u8, opts: Canvas.Opts) Canvas {
        _ = self;
        var cv = Canvas{ .w = Writer.init() };
        cv.id.set(id);
        const at_ok = if (opts.at) |p| p.valid() else false;
        if (opts.anchor == .fixed and !at_ok) {
            // Nowhere to sit: record nothing, and done() leaves no trace.
            cv.aborted = true;
            return cv;
        }
        cv.w.raw("{\"id\":");
        cv.w.str(id);
        cv.w.print(",\"kind\":\"canvas\",\"space\":\"{s}\"", .{@tagName(opts.space)});
        if (at_ok) {
            cv.w.raw(",\"at\":[");
            cv.w.num(opts.at.?.lon);
            cv.w.raw(",");
            cv.w.num(opts.at.?.lat);
            cv.w.raw("]");
        }
        cv.w.anchor(opts.anchor);
        cv.w.raw(",\"cmds\":[");
        return cv;
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

/// Most commands one canvas may record; the core refuses more (spec rule 7).
/// The encoder drops the 2049th onward with one log line, so the object that
/// does go out is still drawable.
pub const max_canvas_cmds = 2048;

/// Longest fillText run, bytes. The encoder truncates on a UTF-8 boundary.
pub const max_canvas_text = 256;

/// Most stops one gradient may carry; extra stops are dropped.
pub const max_canvas_stops = 8;

/// A recording surface for one canvas object, opened by `Chart.canvas`. The
/// command stream serializes straight into the scene buffer; the diff then
/// treats the whole canvas like any object, so re-recording an identical
/// drawing sends nothing.
pub const Canvas = struct {
    w: Writer,
    id: Str(max_object_id) = .{},
    /// Commands recorded so far.
    n: u32 = 0,
    /// Commands dropped over the budget.
    dropped: u32 = 0,
    aborted: bool = false,
    said_text_cut: bool = false,

    pub const Space = enum { geo, points };
    pub const Weight = enum { regular, bold };
    pub const Cap = enum { butt, round, square };
    pub const Join = enum { miter, round, bevel };
    pub const Align = enum { left, center, right };

    pub const Opts = struct {
        /// Where the canvas sits. Required for a fixed anchor; an own-ship
        /// canvas may omit it and ride the display position alone.
        at: ?Point = null,
        anchor: Anchor = .fixed,
        space: Space = .points,
    };

    /// A colour: free RGBA (0..1, straight alpha) or a palette token that
    /// resolves per scheme.
    pub const ColorSpec = union(enum) {
        rgba: [4]f64,
        token: Color,
    };

    pub const Stop = struct { t: f64, color: ColorSpec };

    /// What a fill or stroke paints with.
    pub const Style = union(enum) {
        rgba: [4]f64,
        token: Color,
        linear: struct { from: [2]f64, to: [2]f64, stops: []const Stop },
        radial: struct { center: [2]f64, radius: f64, stops: []const Stop },
    };

    // ---- the path ----

    pub fn beginPath(self: *Canvas) void {
        self.op0("P");
    }

    pub fn moveTo(self: *Canvas, x: f64, y: f64) void {
        self.opN("M", &.{ x, y });
    }

    pub fn lineTo(self: *Canvas, x: f64, y: f64) void {
        self.opN("L", &.{ x, y });
    }

    pub fn quadTo(self: *Canvas, cx: f64, cy: f64, x: f64, y: f64) void {
        self.opN("Q", &.{ cx, cy, x, y });
    }

    pub fn bezierTo(self: *Canvas, c1x: f64, c1y: f64, c2x: f64, c2y: f64, x: f64, y: f64) void {
        self.opN("B", &.{ c1x, c1y, c2x, c2y, x, y });
    }

    /// Angles in degrees: 0 along +x, growing toward +y (clockwise on
    /// screen). `ccw` sweeps the other way, as on the HTML canvas.
    pub fn arc(self: *Canvas, cx: f64, cy: f64, r: f64, a0_deg: f64, a1_deg: f64, ccw: bool) void {
        const b = self.begin() orelse return;
        b.raw("[\"A\",");
        b.num(cx);
        b.raw(",");
        b.num(cy);
        b.raw(",");
        b.num(r);
        b.raw(",");
        b.num(a0_deg);
        b.raw(",");
        b.num(a1_deg);
        b.raw(if (ccw) ",true]" else ",false]");
    }

    pub fn closePath(self: *Canvas) void {
        self.op0("Z");
    }

    // ---- painting ----

    pub fn fill(self: *Canvas) void {
        self.op0("F");
    }

    pub fn stroke(self: *Canvas) void {
        self.op0("S");
    }

    /// Clip everything painted after this to the current path. Convex paths
    /// clip exactly.
    pub fn clip(self: *Canvas) void {
        self.op0("C");
    }

    pub fn fillStyle(self: *Canvas, s: Style) void {
        const b = self.begin() orelse return;
        b.raw("[\"fs\",");
        writeStyle(b, s);
        b.raw("]");
    }

    pub fn strokeStyle(self: *Canvas, s: Style) void {
        const b = self.begin() orelse return;
        b.raw("[\"ss\",");
        writeStyle(b, s);
        b.raw("]");
    }

    /// Screen points, in either space.
    pub fn lineWidth(self: *Canvas, w: f64) void {
        self.opN("lw", &.{w});
    }

    pub fn lineCap(self: *Canvas, cap: Cap) void {
        self.opTag("cap", @tagName(cap));
    }

    pub fn lineJoin(self: *Canvas, join: Join) void {
        self.opTag("join", @tagName(join));
    }

    // ---- text ----

    /// The UI face at `size_pt` screen points.
    pub fn font(self: *Canvas, size_pt: f64, weight: Weight) void {
        const b = self.begin() orelse return;
        b.raw("[\"font\",");
        b.num(size_pt);
        b.print(",\"{s}\"]", .{@tagName(weight)});
    }

    pub fn textAlign(self: *Canvas, a: Align) void {
        self.opTag("ta", @tagName(a));
    }

    /// `x`,`y` is the baseline point (or its centre / right end under
    /// textAlign). Runs over 256 bytes are truncated with one log line.
    pub fn fillText(self: *Canvas, text: []const u8, x: f64, y: f64) void {
        const b = self.begin() orelse return;
        var run = text;
        if (run.len > max_canvas_text) {
            var n: usize = max_canvas_text;
            while (n > 0 and (run[n] & 0xc0) == 0x80) n -= 1;
            run = run[0..n];
            if (!self.said_text_cut) {
                self.said_text_cut = true;
                log(.warn, "canvas {s}: a text run over {d} bytes was truncated", .{ self.id.text(), max_canvas_text });
            }
        }
        b.raw("[\"T\",");
        b.num(x);
        b.raw(",");
        b.num(y);
        b.raw(",");
        b.str(run);
        b.raw("]");
    }

    // ---- transforms ----

    pub fn translate(self: *Canvas, dx: f64, dy: f64) void {
        self.opN("tr", &.{ dx, dy });
    }

    /// Degrees, clockwise on screen: rotate(90) carries north to east.
    pub fn rotate(self: *Canvas, deg: f64) void {
        self.opN("rot", &.{deg});
    }

    pub fn scale(self: *Canvas, sx: f64, sy: f64) void {
        self.opN("sc", &.{ sx, sy });
    }

    /// Hold what follows LEVEL ON SCREEN, however the mariner has turned the
    /// chart. Canvas units are chart-aligned, so under course-up a drawing
    /// turns with the chart: right for a compass card, wrong for a readout,
    /// which ends up on its side. Turn this on and the rest of the recording
    /// — text, the plate behind it, any shape — draws upright, about the point
    /// you are drawing from. It is state like a fill style, so scope it with
    /// save/restore and one canvas mixes both:
    ///
    ///   cv.save();
    ///   cv.screenAligned(true);
    ///   cv.fillText("TWD 224", 0, 84);
    ///   cv.restore();
    ///
    /// Any rotation you applied goes too, for as long as it is on: the promise
    /// is level on the display, not level relative to your own transform.
    pub fn screenAligned(self: *Canvas, on: bool) void {
        self.opN("sa", &.{if (on) 1 else 0});
    }

    pub fn save(self: *Canvas) void {
        self.op0("sv");
    }

    pub fn restore(self: *Canvas) void {
        self.op0("rs");
    }

    /// Close the canvas and hand it to the scene diff. Call exactly once.
    pub fn done(self: *Canvas) void {
        if (self.aborted) {
            scene.len = self.w.start; // no separator, no fragment
            return;
        }
        self.w.raw("]}");
        self.w.done(self.id.text());
    }

    // ---- the encoder ----

    /// Room for one more command, or null once the budget is spent. The
    /// first drop logs; the rest only count.
    fn begin(self: *Canvas) ?*Writer {
        if (self.aborted) return null;
        if (self.n >= max_canvas_cmds) {
            if (self.dropped == 0) {
                log(.warn, "canvas {s}: over {d} commands; the rest were dropped", .{ self.id.text(), max_canvas_cmds });
            }
            self.dropped += 1;
            return null;
        }
        if (self.n > 0) self.w.raw(",");
        self.n += 1;
        return &self.w;
    }

    fn op0(self: *Canvas, comptime op: []const u8) void {
        const b = self.begin() orelse return;
        b.raw("[\"" ++ op ++ "\"]");
    }

    fn opN(self: *Canvas, comptime op: []const u8, args: []const f64) void {
        const b = self.begin() orelse return;
        b.raw("[\"" ++ op ++ "\"");
        for (args) |v| {
            b.raw(",");
            b.num(v);
        }
        b.raw("]");
    }

    fn opTag(self: *Canvas, comptime op: []const u8, tag: []const u8) void {
        const b = self.begin() orelse return;
        b.print("[\"" ++ op ++ "\",\"{s}\"]", .{tag});
    }

    fn writeStyle(b: *Writer, s: Style) void {
        switch (s) {
            .rgba => |c| writeRgba(b, c),
            .token => |tok| b.print("\"{s}\"", .{@tagName(tok)}),
            .linear => |g| {
                b.raw("{\"lin\":[");
                b.num(g.from[0]);
                b.raw(",");
                b.num(g.from[1]);
                b.raw(",");
                b.num(g.to[0]);
                b.raw(",");
                b.num(g.to[1]);
                b.raw("],\"stops\":[");
                writeStops(b, g.stops);
                b.raw("]}");
            },
            .radial => |g| {
                b.raw("{\"rad\":[");
                b.num(g.center[0]);
                b.raw(",");
                b.num(g.center[1]);
                b.raw(",");
                b.num(g.radius);
                b.raw("],\"stops\":[");
                writeStops(b, g.stops);
                b.raw("]}");
            },
        }
    }

    fn writeStops(b: *Writer, stops: []const Stop) void {
        const n = @min(stops.len, max_canvas_stops);
        for (stops[0..n], 0..) |s, i| {
            if (i > 0) b.raw(",");
            b.raw("[");
            b.num(s.t);
            b.raw(",");
            switch (s.color) {
                .rgba => |c| writeRgba(b, c),
                .token => |tok| b.print("\"{s}\"", .{@tagName(tok)}),
            }
            b.raw("]");
        }
    }

    fn writeRgba(b: *Writer, c: [4]f64) void {
        b.raw("[");
        for (c, 0..) |ch, i| {
            if (i > 0) b.raw(",");
            b.num(ch);
        }
        b.raw("]");
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

/// Raise an alert under a key of your own. The host holds one alert per plugin
/// per key, so raising again under the same key updates the alert already on
/// screen and leaves the mariner's acknowledgement alone.
///
/// Key on the identity of the thing in danger, such as a vessel's MMSI, and
/// not on the words. A body carrying a figure that moves is a new alert every
/// time it moves when there is no key to hold it together.
pub fn alertKeyed(key: []const u8, severity: Severity, title: []const u8, body: []const u8) i32 {
    return raw_lk.raiseAlertKeyed(key, severity, title, body);
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

    /// This source holds the path and has no value for it right now.
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
/// the API is SI, whatever the wire format reported.
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
/// switch. See `conn.zig` for what a connection carries.
pub fn connections(comptime opts: conn.Opts) type {
    return conn.Connections(opts);
}

// ---------------------------------------------------------------------------
// Tables
// ---------------------------------------------------------------------------

/// What a column carries. THE PLUGIN SENDS SI AND THE SHELL FORMATS: metres,
/// metres per second, degrees true, seconds. That is the reverse of a pick
/// row, and it is what lets the shell sort a column numerically and show it in
/// the mariner's own units.
pub const ColumnType = enum { distance, speed, bearing, duration, number, text, flag };

/// One declared column. An empty label is a column with no heading, which is
/// what a flag column usually wants.
pub const Column = struct {
    key: []const u8,
    label: []const u8 = "",
    type: ColumnType,
};

/// The column the shell sorts by until the mariner says otherwise.
pub const TableSort = struct {
    key: []const u8,
    ascending: bool = true,
};

/// The two row keys carrying a position. A row that has them is locatable:
/// the mariner activates it and the chart centres on it. They need not be
/// columns; a position is usually not worth a column of its own.
pub const TableAt = struct {
    lat: []const u8,
    lon: []const u8,
};

pub const TableOpts = struct {
    key: []const u8,
    title: []const u8,
    /// The menu the shell opens the dialog from: "Vessels".
    menu: []const u8,
    columns: []const Column,
    sort: ?TableSort = null,
    at: ?TableAt = null,
};

/// Columns one table may declare. The host's budget, and the reason for it:
/// a table wider than this is a spreadsheet, and nobody reads a spreadsheet
/// on a moving boat.
pub const max_columns = 16;

/// Rows the library's diff table holds. The host takes 512; this is what one
/// plugin keeps between cycles, and it is the same number the AIS plugin
/// tracks targets with.
pub const max_rows = 256;

/// Longest row id the diff table keeps.
pub const max_row_id = 32;

/// The batch buffer: the rows that changed and the ids that went. Fifty AIS
/// targets of eight columns come to about 6 KB.
pub const table_bytes = 24 * 1024;

/// The shortest gap between two batches, measured from the START of one cycle
/// to the start of the next. One update per status cadence is the rule; the
/// library holds a batch back rather than have the host refuse it, and it
/// leaves itself the margin between this and the host's own 900 ms.
pub const table_min_interval_ms: i64 = 950;

/// A table the plugin declares and feeds:
///
///   pub const Targets = lk.table(.{
///       .key = "targets", .title = "AIS Targets", .menu = "Vessels",
///       .columns = &.{ .{ .key = "cpa", .label = "CPA", .type = .distance } },
///       .sort = .{ .key = "cpa", .ascending = true },
///   });
///
/// FILL IT FROM `onUpdate`. The library opens a cycle before that call and
/// sends what changed after it, so `upsert` belongs there and nowhere else.
/// Filling a table is not drawing, and there is no capability to ask for, so
/// the rows keep coming while the chart grant is off.
///
/// The library declares it at start, tells you when the mariner opens it
/// (`isOpen`), and sends what changed once a cycle. DESCRIBE THE WHOLE SET
/// EVERY CYCLE, the way `draw` describes the whole picture: a row you do not
/// upsert leaves the table. The manifest carries the same declaration, and
/// `lk.expectTables` is the test that says so.
pub fn table(comptime opts: TableOpts) type {
    comptime checkTable(opts);
    return struct {
        /// What `Declared` and `expectTables` look for.
        pub const lk_table = opts;
        /// The manifest's entry for this table, generated from the same
        /// declaration the host is given.
        pub const lk_table_json = tableJson(opts);

        var t: TableState = .{};

        /// True while the mariner has the dialog on screen. Skip the work of
        /// building rows nobody is looking at.
        pub fn isOpen() bool {
            return t.open;
        }

        /// One row. `id` names it for its whole life; `band` is the ordering
        /// policy: 0 first, and the mariner's column sort never crosses a
        /// band. Every other field is a declared column key or an `at` key,
        /// checked here at compile time.
        pub fn upsert(row: anytype) void {
            const R = @TypeOf(row);
            comptime checkRow(opts, R);
            if (!t.building) return;
            const id = rowId(row);
            if (id.len == 0 or id.len > max_row_id) return;

            var w = TableWriter.init(&t);
            w.raw("{\"id\":");
            w.str(id);
            inline for (@typeInfo(R).@"struct".fields) |f| {
                if (comptime !std.mem.eql(u8, f.name, "id")) {
                    w.raw(",\"" ++ f.name ++ "\":");
                    if (comptime std.mem.eql(u8, f.name, "band")) {
                        w.num(asFloat(@field(row, f.name)));
                    } else {
                        w.cell(comptime columnType(opts, f.name), @field(row, f.name));
                    }
                }
            }
            w.raw("}");
            t.take(id, w.start, w.body);
        }

        /// Take one row out now, without waiting for a cycle to pass it by.
        pub fn remove(id: []const u8) void {
            t.forgetRow(id);
        }

        /// Start a cycle. The library calls this before `onUpdate`.
        pub fn lkBegin() void {
            t.begin(opts.key);
        }

        /// Send what changed and take off what this cycle did not describe.
        /// The library calls this after `onUpdate`.
        pub fn lkFlush() void {
            t.commit();
        }

        /// Tell the host about the declaration. The library calls this at
        /// start.
        pub fn lkDeclare() void {
            if (tableDeclare(lk_table_json) < 0)
                log(.warn, "table {s}: the host refused the declaration", .{opts.key});
        }

        /// The batch as it stands. The library's own tests read it; a plugin
        /// has nothing to do with it.
        pub fn lkBatch() []const u8 {
            return t.buf[0..t.len];
        }

        /// Route one table_open / table_closed event. True when it was ours.
        pub fn lkOpen(key: []const u8, open: bool) bool {
            if (!std.mem.eql(u8, key, opts.key)) return false;
            t.open = open;
            if (!open) {
                // The host dropped the rows when it closed the dialog, so the
                // diff table must forget them too or the next opening sends
                // nothing.
                t.n = 0;
                t.last_ms = 0;
            }
            return true;
        }
    };
}

/// One table's retained rows and its batch buffer. The same shape the scene
/// diff has, for the same reason: an unchanged row costs a serialize and no
/// call.
const TableState = struct {
    const Entry = struct {
        id: Str(max_row_id) = .{},
        hash: u64 = 0,
        live: bool = false,
        seen: bool = false,
    };

    entries: [max_rows]Entry = @splat(.{}),
    n: usize = 0,

    buf: [table_bytes]u8 = undefined,
    len: usize = 0,
    sets: usize = 0,
    overflowed: bool = false,
    /// True between `begin` and `commit`, and only while the dialog is open
    /// and the cadence allows another batch.
    building: bool = false,
    open: bool = false,
    /// When the last batch that went out was BUILT, monotonic. Measuring the
    /// cadence from the start of a cycle rather than from the send keeps the
    /// gap the host sees a shade wider than the one measured here, so a batch
    /// this library was willing to send is one the host is willing to take.
    last_ms: i64 = 0,
    cycle_ms: i64 = 0,
    /// The key, kept for the commit's envelope.
    key: []const u8 = "",

    fn find(self: *TableState, id: []const u8) ?*Entry {
        for (self.entries[0..self.n]) |*e| {
            if (e.id.eql(id)) return e;
        }
        return null;
    }

    fn begin(self: *TableState, key: []const u8) void {
        self.key = key;
        const now = tableNow();
        self.building = self.open and (self.last_ms == 0 or now - self.last_ms >= table_min_interval_ms);
        if (!self.building) return;
        self.cycle_ms = now;
        for (self.entries[0..self.n]) |*e| e.seen = false;
        self.len = 0;
        self.sets = 0;
        self.overflowed = false;
        self.put("{\"key\":\"");
        self.put(key);
        self.put("\",\"upsert\":[");
    }

    fn put(self: *TableState, text: []const u8) void {
        if (self.len + text.len > self.buf.len) {
            self.overflowed = true;
            return;
        }
        @memcpy(self.buf[self.len..][0..text.len], text);
        self.len += text.len;
    }

    /// Take one serialized row, or rewind it when the table already holds
    /// exactly that row.
    fn take(self: *TableState, id: []const u8, start: usize, body: usize) void {
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
        if (self.n == max_rows) {
            self.len = start;
            log(.warn, "table {s}: more than {d} rows; \"{s}\" dropped", .{ self.key, max_rows, id });
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

    /// Drop one row from the diff table. It goes out as a removal at the next
    /// commit, because the commit lists everything live that this cycle did
    /// not describe.
    fn forgetRow(self: *TableState, id: []const u8) void {
        if (self.find(id)) |e| e.seen = false;
    }

    fn commit(self: *TableState) void {
        if (!self.building) return;
        self.building = false;

        var dels: usize = 0;
        for (self.entries[0..self.n]) |*e| {
            if (e.live and !e.seen) dels += 1;
        }
        if (self.sets == 0 and dels == 0) return;

        self.put("],\"remove\":[");
        var k: usize = 0;
        for (self.entries[0..self.n]) |*e| {
            if (!e.live or e.seen) continue;
            if (k > 0) self.put(",");
            k += 1;
            self.put("\"");
            self.put(e.id.text());
            self.put("\"");
        }
        self.put("]}");
        if (self.overflowed) {
            // The rows that did not fit are still unsent, so the table forgets
            // everything and describes itself again next cycle.
            log(.warn, "table {s}: the batch did not fit in {d} bytes", .{ self.key, self.buf.len });
            self.n = 0;
            self.len = 0;
            return;
        }
        if (tableUpdate(self.buf[0..self.len]) < 0) {
            self.n = 0;
            self.len = 0;
            return;
        }
        self.last_ms = self.cycle_ms;
        // A row this cycle did not describe has left the table.
        var w: usize = 0;
        for (self.entries[0..self.n]) |e| {
            if (e.live and e.seen) {
                self.entries[w] = e;
                w += 1;
            }
        }
        self.n = w;
    }
};

/// Writes one row straight into the batch buffer.
const TableWriter = struct {
    t: *TableState,
    start: usize = 0,
    body: usize = 0,

    fn init(t: *TableState) TableWriter {
        var w = TableWriter{ .t = t, .start = t.len };
        if (t.sets > 0) w.raw(",");
        w.body = t.len;
        return w;
    }

    fn raw(self: *TableWriter, text: []const u8) void {
        self.t.put(text);
    }

    fn print(self: *TableWriter, comptime fmt: []const u8, args: anytype) void {
        var tmp: [128]u8 = undefined;
        var w = std.Io.Writer.fixed(&tmp);
        w.print(fmt, args) catch {
            self.t.overflowed = true;
            return;
        };
        self.raw(w.buffered());
    }

    fn str(self: *TableWriter, s: []const u8) void {
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

    fn num(self: *TableWriter, v: f64) void {
        if (std.math.isFinite(v)) self.print("{d}", .{v}) else self.raw("null");
    }

    /// One cell. Null is null on the wire and a dash on screen: never heard
    /// and heard as zero are different values.
    fn cell(self: *TableWriter, comptime ctype: ?ColumnType, value: anytype) void {
        const V = @TypeOf(value);
        switch (@typeInfo(V)) {
            .null => self.raw("null"),
            .optional => if (value) |v| self.cell(ctype, v) else self.raw("null"),
            else => {
                if (comptime isTextColumn(ctype)) self.str(asText(value)) else self.num(asFloat(value));
            },
        }
    }
};

/// The clock behind the cadence gate. Under a test build this is the test
/// host's clock, which moves only when a test moves it, so a test that leaves
/// it alone finds the gate standing open. A native build that is not a test
/// has no clock at all.
fn tableNow() i64 {
    if (comptime builtin.target.cpu.arch != .wasm32 and !builtin.is_test) return 0;
    return monoMs();
}

fn tableDeclare(json: []const u8) i32 {
    if (comptime builtin.target.cpu.arch != .wasm32 and !builtin.is_test) return 0;
    return raw_lk.tableDeclareJson(json);
}

fn tableUpdate(json: []const u8) i32 {
    if (comptime builtin.target.cpu.arch != .wasm32 and !builtin.is_test) return 0;
    return raw_lk.tableUpdateJson(json);
}

// -- the declaration, checked and rendered at comptime ------------------------

fn checkTable(comptime opts: TableOpts) void {
    comptime {
        if (opts.key.len == 0) @compileError("a table needs a key");
        if (opts.title.len == 0) @compileError("a table needs a title: it is the dialog's own name");
        if (opts.menu.len == 0) @compileError("a table needs a menu: the shell opens the dialog from it");
        if (opts.columns.len == 0) @compileError("a table needs at least one column");
        if (opts.columns.len > max_columns) @compileError(std.fmt.comptimePrint(
            "the table declares {d} columns; the host allows {d}",
            .{ opts.columns.len, max_columns },
        ));
        for (opts.columns, 0..) |c, i| {
            if (c.key.len == 0) @compileError("every table column needs a key");
            for (opts.columns[0..i]) |other| {
                if (std.mem.eql(u8, other.key, c.key))
                    @compileError("two table columns called \"" ++ c.key ++ "\"");
            }
        }
        if (opts.sort) |s| {
            if (columnOf(opts, s.key) == null)
                @compileError("the default sort names column \"" ++ s.key ++ "\", which is not declared");
        }
    }
}

fn columnOf(comptime opts: TableOpts, comptime key: []const u8) ?Column {
    comptime {
        for (opts.columns) |c| {
            if (std.mem.eql(u8, c.key, key)) return c;
        }
        return null;
    }
}

/// The column a row field feeds, or null when the field is an `at` key: a
/// position is a number and never a column.
fn columnType(comptime opts: TableOpts, comptime name: []const u8) ?ColumnType {
    comptime {
        if (columnOf(opts, name)) |c| return c.type;
        return null;
    }
}

fn isTextColumn(comptime ctype: ?ColumnType) bool {
    const c = ctype orelse return false;
    return c == .text or c == .flag;
}

/// Every row field must be `id`, `band`, a declared column or an `at` key,
/// and must carry what that column holds. A typo in a key is a cell the shell
/// would show as a dash forever, so it is a compile error instead.
fn checkRow(comptime opts: TableOpts, comptime R: type) void {
    comptime {
        const info = switch (@typeInfo(R)) {
            .@"struct" => |s| s,
            else => @compileError("a table row is a struct literal"),
        };
        var has_id = false;
        for (info.fields) |f| {
            if (std.mem.eql(u8, f.name, "id")) {
                has_id = true;
                continue;
            }
            if (std.mem.eql(u8, f.name, "band")) continue;
            if (columnOf(opts, f.name) != null) continue;
            if (opts.at) |at| {
                if (std.mem.eql(u8, f.name, at.lat) or std.mem.eql(u8, f.name, at.lon)) continue;
            }
            @compileError("table \"" ++ opts.key ++ "\" declares no column \"" ++ f.name ++ "\"");
        }
        if (!has_id) @compileError("a table row needs an id");
    }
}

fn rowId(row: anytype) []const u8 {
    return asText(@field(row, "id"));
}

/// A string field, however the plugin holds it: a slice, a literal, or one of
/// the library's fixed `Str` buffers.
fn asText(value: anytype) []const u8 {
    if (comptime isStrBuffer(@TypeOf(value))) return value.text();
    return value;
}

fn isStrBuffer(comptime V: type) bool {
    return switch (@typeInfo(V)) {
        .@"struct" => @hasDecl(V, "text"),
        else => false,
    };
}

fn asFloat(value: anytype) f64 {
    return switch (@typeInfo(@TypeOf(value))) {
        .int, .comptime_int => @floatFromInt(value),
        .float, .comptime_float => @floatCast(value),
        .bool => if (value) 1 else 0,
        else => @compileError("a table cell in a number column takes a number"),
    };
}

/// The manifest entry for one declaration, rendered at comptime so the
/// manifest and the running host are given the same text.
pub fn tableJson(comptime opts: TableOpts) []const u8 {
    return struct {
        const text = build();

        fn build() []const u8 {
            comptime {
                var out: []const u8 = "{\"key\":" ++ jsonStr(opts.key) ++
                    ",\"title\":" ++ jsonStr(opts.title) ++
                    ",\"menu\":" ++ jsonStr(opts.menu) ++ ",\"columns\":[";
                for (opts.columns, 0..) |c, i| {
                    if (i > 0) out = out ++ ",";
                    out = out ++ "{\"key\":" ++ jsonStr(c.key) ++
                        ",\"label\":" ++ jsonStr(c.label) ++
                        ",\"type\":\"" ++ @tagName(c.type) ++ "\"}";
                }
                out = out ++ "]";
                if (opts.sort) |s| out = out ++ ",\"sort\":{\"key\":" ++ jsonStr(s.key) ++
                    ",\"ascending\":" ++ (if (s.ascending) "true" else "false") ++ "}";
                if (opts.at) |a| out = out ++ ",\"at\":{\"lat\":" ++ jsonStr(a.lat) ++
                    ",\"lon\":" ++ jsonStr(a.lon) ++ "}";
                return out ++ "}";
            }
        }
    }.text;
}

/// The `"tables"` array a manifest must carry for these declarations.
pub fn tablesJson(comptime spec_list: anytype) []const u8 {
    return struct {
        const text = build();

        fn build() []const u8 {
            comptime {
                var out: []const u8 = "[";
                for (spec_list, 0..) |T, i| {
                    if (i > 0) out = out ++ ",";
                    out = out ++ T.lk_table_json;
                }
                return out ++ "]";
            }
        }
    }.text;
}

fn jsonStr(comptime s: []const u8) []const u8 {
    comptime {
        var out: []const u8 = "\"";
        for (s) |c| out = out ++ switch (c) {
            '"' => "\\\"",
            '\\' => "\\\\",
            '\n' => "\\n",
            '\r' => "\\r",
            '\t' => "\\t",
            0...8, 11, 12, 14...31 => std.fmt.comptimePrint("\\u{x:0>4}", .{c}),
            else => &[_]u8{c},
        };
        return out ++ "\"";
    }
}

/// Fail when the manifest's `"tables"` is not what these declarations say, the
/// way `expectManifest` does for settings. A plugin's own native test:
///
///   test "the manifest carries the table this file declares" {
///       try lk.expectTables(@embedFile("manifest.json"), .{Targets});
///   }
pub fn expectTables(manifest_text: []const u8, comptime spec_list: anytype) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const want_text = comptime tablesJson(spec_list);
    const manifest = try std.json.parseFromSliceLeaky(std.json.Value, a, manifest_text, .{});
    const got = switch (manifest) {
        .object => |o| o.get("tables") orelse {
            std.debug.print("manifest declares no tables; the plugin declares:\n{s}\n", .{want_text});
            return error.NoTablesInManifest;
        },
        else => return error.ManifestIsNotAnObject,
    };
    const want = try std.json.parseFromSliceLeaky(std.json.Value, a, want_text, .{});
    if (!schema.equal(got, want)) {
        std.debug.print("manifest tables do not match the declaration.\nthe plugin declares:\n{s}\n", .{want_text});
        return error.ManifestTableMismatch;
    }
}

// ---------------------------------------------------------------------------
// Registration
// ---------------------------------------------------------------------------

/// Room for the values one batch can spill.
///
/// The worst case is a batch in which no declared input claims anything:
/// `max_subscribe_paths` of them, each a path and a value the vessel store
/// bounds at 512 bytes of JSON, with the envelope. That is a little over ten
/// kilobytes and this is the round number above it. A batch past it goes
/// through whole rather than being cut, so the number is a working set and not
/// a correctness bound.
const store_spill_bytes = 12 * 1024;

/// Where the rebuild is written. A global rather than scratch because the
/// scratch arena grows through `@wasmMemorySize`, which does not exist off
/// wasm, and this routing has to be testable natively. One plugin, one event
/// at a time, by the same contract that makes every other buffer here a
/// global.
var spill_buf: [store_spill_bytes]u8 = undefined;

/// The values in one `.store_changed` batch that no declared input claimed,
/// rebuilt as a payload of the same shape for the plugin's own `onEvent`.
///
/// A plugin that mixes tiers — declared `inputs` for what the library should
/// age and gate on, `subscribeAlso` for a path it wants raw — used to lose the
/// raw half here: the library matched the declared paths and returned. This
/// carries the rest through, and only the rest, so a handler looking for its
/// own path is not handed values it already has through an input.
///
/// A batch that overruns the buffer goes through WHOLE instead. A plugin
/// seeing a value it already has through an input is a plugin that can
/// ignore it; one that never sees its own is the bug being fixed.
const RawSpill = struct {
    src: []const u8,
    w: std.Io.Writer = .fixed(&spill_buf),
    n: usize = 0,
    over: bool = false,

    fn init(payload: []const u8) RawSpill {
        return .{ .src = payload, .w = .fixed(&spill_buf) };
    }

    fn take(self: *RawSpill, r: raw_lk.PathValue) void {
        if (self.over) return;
        if (self.n == 0) {
            self.w.writeAll("{\"values\":[") catch {
                self.over = true;
                return;
            };
        }
        self.write(r) catch {
            self.over = true;
        };
        self.n += 1;
    }

    fn write(self: *RawSpill, r: raw_lk.PathValue) !void {
        if (self.n > 0) try self.w.writeByte(',');
        try self.w.writeAll("{\"path\":");
        try std.json.Stringify.value(r.path, .{}, &self.w);
        try self.w.writeAll(",\"value\":");
        try std.json.Stringify.value(r.value, .{}, &self.w);
        try self.w.print(",\"ts\":{d},\"age_ms\":{d}}}", .{ r.ts_ms, r.age_ms });
    }

    /// The unclaimed values as a payload, or null when every value in the
    /// batch was claimed and there is nothing to pass on.
    fn rest(self: *RawSpill) ?[]const u8 {
        if (self.n == 0) return null;
        if (self.over) return self.src;
        self.w.writeAll("]}") catch return self.src;
        return self.w.buffered();
    }
};

/// What one `.store_changed` batch left behind.
const Routed = struct {
    /// The values no declared input claimed, or null when the inputs took
    /// the lot. What reaches the plugin's own `onEvent`.
    rest: ?[]const u8,
    /// How many values landed in a declared input. Zero means no input
    /// changed, so nothing depending on one has anything to recompute.
    claimed: usize,
};

/// Route one `.store_changed` batch: hand each value to the input that
/// declared its path, and give back the values nobody claimed.
///
/// The batch arrives already parsed, and the clock arrives as an argument,
/// because `values` and `monoMs` both reach the host: keeping them out is
/// what lets the routing be tested natively, the same reason `lkRecord` takes
/// a clock. `src` is the payload they came from, which is what goes through
/// unsplit if the rebuild will not fit.
fn routeValues(comptime inputs: []const type, list: []const raw_lk.PathValue, src: []const u8, mono: i64) Routed {
    var spill = RawSpill.init(src);
    var took: usize = 0;
    for (list) |r| {
        var claimed = false;
        inline for (inputs) |In| {
            if (std.mem.eql(u8, r.path, In.lk_path)) {
                In.lkRecord(r, mono);
                claimed = true;
            }
        }
        // A plugin may declare inputs AND raw-subscribe paths of its own; see
        // `subscribeAlso`. The values no input claimed are that plugin's,
        // and swallowing them here is how they used to be lost.
        if (claimed) took += 1 else spill.take(r);
    }
    return .{ .rest = spill.rest(), .claimed = took };
}

/// Emit the API exports and wire them to what the plugin declares. Call once,
/// at container scope:
///
///   comptime { lk.plugin(@This()); }
///
/// Everything is optional. A plugin that declares only `draw` gets a timer and
/// a scene; one that declares only `onEvent` is a raw plugin.
pub fn plugin(comptime P: type) void {
    raw_lk.registerPlugin(Wiring(P));
}

/// What `plugin` installs: `start` and `onEvent`, wired to the declarations.
/// Kept apart from the export so the library's own tests drive a plugin
/// without a host. A plugin calls `plugin`, never this.
fn Wiring(comptime P: type) type {
    const D = Declared(P);
    return struct {
        comptime {
            // A dialog nothing fills opens empty and stays empty, which reads
            // as a broken shell rather than a plugin that wrote no row.
            if (D.tables.len > 0 and !D.has_update) @compileError(
                "a table is filled from onUpdate, and this plugin declares a table and no onUpdate",
            );
        }

        /// What the status says while the chart grant is off.
        const no_draw_line = "not drawing: permission to draw on the chart is off";

        var draw_timer: i64 = -1;
        /// True while the mariner leaves `overlay.draw` on. The host refuses
        /// every overlay call without it, so a scene described then is work
        /// thrown away. Assumed on until the host says otherwise, which it
        /// does once the module has started.
        var may_draw: bool = true;

        /// The appointment for the next value to expire, and -1 when there
        /// is none. A plugin with nothing that can go stale never holds one.
        var update_timer: i64 = -1;
        /// The moment `update_timer` is set for. Read only while it is up.
        var update_due_ms: i64 = 0;

        /// True when an input can go stale, so an expiry is worth waiting for.
        /// The inputs decide this and the hooks do not: an expiry changes what
        /// the plugin should show whether or not it wrote an `onUpdate`.
        const wants_update_timer = D.inputs.len > 0 or D.has_ais;

        pub fn start(s: raw_lk.Start) !void {
            readSettings(P, s.config);

            if (comptime D.inputs.len > 0) {
                // Kept where `subscribeAlso` can find them: a plugin adding a
                // raw path of its own has to send these again or the host
                // replaces the whole subscription with just its own.
                declared_paths = &D.paths;
                if (raw_lk.subscribePaths(&D.paths) < 0) return error.SubscribeRefused;
            }
            if (comptime D.has_ais) {
                if (raw_lk.aisSubscribe() < 0) return error.AisSubscribeRefused;
            }
            if (comptime D.has_connections) {
                P.Connections.lkStart(P, s.config);
            }
            inline for (D.tables) |T| T.lkDeclare();
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
                    const routed = routeValues(D.inputs, raw_lk.pathValues(payload), payload, mono);
                    if (comptime @hasDecl(P, "onEvent")) {
                        if (routed.rest) |json| try P.onEvent(.{ .store_changed = json });
                    }
                    if (routed.claimed > 0) runUpdate(mono);
                    return;
                },
                .ais_changed => |payload| if (comptime D.has_ais) {
                    const mono = monoMs();
                    D.Ais.lkRecord(payload, mono);
                    runUpdate(mono);
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
                .grants_changed => |payload| {
                    if (comptime D.has_draw) setMayDraw(raw_lk.granted(payload, "overlay.draw"));
                },
                .timer => |id| {
                    if (comptime D.has_draw) {
                        if (id == draw_timer) {
                            runDraw();
                            return;
                        }
                    }
                    if (comptime wants_update_timer) {
                        if (id == update_timer) {
                            // The host drops a one-shot when it fires, so the
                            // handle is spent and the cycle makes the next.
                            update_timer = -1;
                            runUpdate(monoMs());
                            return;
                        }
                    }
                    if (comptime D.has_connections) {
                        if (P.Connections.lkTimer(P, id)) return;
                    }
                },
                // A table the mariner just opened is filled at once: the
                // dialog must not sit empty until the next batch of values.
                .table_open => |key| {
                    var mine = false;
                    inline for (D.tables) |T| {
                        if (T.lkOpen(key, true)) mine = true;
                    }
                    if (mine) {
                        runUpdate(monoMs());
                        return;
                    }
                },
                .table_closed => |key| {
                    var mine = false;
                    inline for (D.tables) |T| {
                        if (T.lkOpen(key, false)) mine = true;
                    }
                    if (mine) return;
                },
                .shutdown => {
                    if (comptime D.has_draw) {
                        if (draw_timer >= 0) raw_lk.timerCancel(draw_timer);
                    }
                    if (comptime wants_update_timer) {
                        if (update_timer >= 0) raw_lk.timerCancel(update_timer);
                        update_timer = -1;
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

        /// One pass on the data path: the plugin's decision, and the rows it
        /// upserts around it. The chart grant does not reach here. A table is
        /// data, no manifest has to ask for it, and a dialog on screen fills
        /// whether or not the plugin may draw.
        ///
        /// The cycle runs when a value arrives and when one expires. A
        /// plugin that only heard about arrivals could never notice an
        /// absence. A plugin with no hook and no table runs it for the
        /// appointment alone.
        fn runUpdate(mono: i64) void {
            inline for (D.tables) |T| T.lkBegin();
            if (comptime D.has_update) P.onUpdate();
            inline for (D.tables) |T| T.lkFlush();
            if (comptime wants_update_timer) armUpdate(mono);
        }

        /// Wake once, exactly when the next value expires.
        ///
        /// A value carries its window, so the moment it stops counting is
        /// known when it lands. The library takes the earliest such moment
        /// across the declared inputs and arms a one-shot for it; the cycle it
        /// fires reads that input as stale, and the plugin empties whatever
        /// depended on it. Windows differ, so each input expires on its own
        /// wakeup and the plugin can say which one went.
        ///
        /// When every input has already expired there is no next moment and
        /// nothing is armed. The next arrival runs a cycle, and the cycle
        /// makes the next appointment.
        ///
        /// The chart grant does not reach here. A plugin that may not draw
        /// still has a dialog to fill and a condition to watch.
        fn armUpdate(mono: i64) void {
            var next: ?i64 = null;
            inline for (D.inputs) |In| {
                if (In.lkStaleAt(mono)) |at| {
                    if (next == null or at < next.?) next = at;
                }
            }
            if (comptime D.has_ais) {
                if (D.Ais.lkStaleAt(mono)) |at| {
                    if (next == null or at < next.?) next = at;
                }
            }
            // A value is still fresh on the last millisecond of its window,
            // so the appointment is one past it. A wakeup that found the
            // value fresh would have nothing to tell the plugin.
            const due: ?i64 = if (next) |at| at + 1 else null;

            if (update_timer >= 0) {
                if (due != null and due.? == update_due_ms) return;
                raw_lk.timerCancel(update_timer);
                update_timer = -1;
            }
            const at = due orelse return;
            update_timer = raw_lk.timerSet(at - mono, false);
            if (update_timer < 0) {
                log(.err, "update timer refused; a value going stale will pass unnoticed", .{});
                return;
            }
            update_due_ms = at;
        }

        /// Run the draw timer exactly while the chart grant is on. Without it
        /// every overlay call is refused, so a scene described then is work
        /// thrown away.
        fn armTimer() void {
            const want = may_draw;
            if (want == (draw_timer >= 0)) return;
            if (want) {
                draw_timer = raw_lk.timerSet(D.draw_rate_ms, true);
                if (draw_timer < 0) log(.err, "draw timer refused; nothing will be drawn", .{});
                return;
            }
            raw_lk.timerCancel(draw_timer);
            draw_timer = -1;
        }

        /// Take the chart grant on or off.
        ///
        /// The host has already removed what this plugin drew, so the diff
        /// held here describes objects that are gone. Forget it: the next
        /// draw sends the whole scene rather than a difference against
        /// nothing.
        fn setMayDraw(on: bool) void {
            if (on == may_draw) return;
            may_draw = on;
            scene.forget();
            armTimer();
            if (on) {
                runDraw();
                return;
            }
            // The chart is empty and the mariner is the reason. Say so, or the
            // plugin looks broken.
            sayText("degraded", no_draw_line);
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
                sendScene(); // draws nothing, so everything drawn is deleted
                sayStatus("degraded", w.buffered());
                return;
            }

            var c = Chart{};
            scene.begin();
            P.draw(&c);
            sendScene();
            if (c.said) sayStatus(@tagName(c.state), c.detail.text()) else sayStatus("running", "");
        }

        /// The scene, when the chart will take it. Without the grant the
        /// batch is dropped in the module: every call in it would be refused,
        /// and a refusal costs a crossing into the host and a denied count.
        fn sendScene() void {
            if (may_draw) scene.commit() else scene.forget();
        }

        /// The status a frame produced, or the reason there is no frame.
        ///
        /// A frame runs on a settings change whatever the chart grant says, so
        /// the line it wrote has to give way to the one thing the mariner
        /// needs to read. While the grant is off nothing else calls this, so a
        /// plugin is free to post its own line from `onUpdate`.
        fn sayStatus(state: []const u8, detail: []const u8) void {
            if (may_draw) {
                sayText(state, detail);
                return;
            }
            sayText("degraded", no_draw_line);
        }
    };
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
        const has_update = @hasDecl(P, "onUpdate");
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

        /// Every table the plugin declared at its root, in declaration order.
        const tables: []const type = blk: {
            var out: []const type = &.{};
            for (@typeInfo(P).@"struct".decls) |d| {
                const T = @field(P, d.name);
                if (@TypeOf(T) != type) continue;
                if (@hasDecl(T, "lk_table")) out = out ++ &[_]type{T};
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

test "an alert carries its key, and a plugin that names none sends the payload it always did" {
    raw_lk.test_hooks.reset();

    _ = alert(.alarm, "AIS CPA alarm", "GALLEON is closing");
    try expect.expectEqualStrings(
        "{\"severity\":\"alarm\",\"title\":\"AIS CPA alarm\",\"body\":\"GALLEON is closing\"}",
        raw_lk.test_hooks.last(.alert).?.payload(),
    );

    _ = alertKeyed("cpa:899000101", .alarm, "AIS CPA alarm", "GALLEON is closing");
    try expect.expectEqualStrings(
        "{\"severity\":\"alarm\",\"key\":\"cpa:899000101\"," ++
            "\"title\":\"AIS CPA alarm\",\"body\":\"GALLEON is closing\"}",
        raw_lk.test_hooks.last(.alert).?.payload(),
    );
}

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

test "canvas encoder: a valid object lands in the scene, the 2049th command is dropped" {
    scene.begin();
    defer scene.forget();
    var c = Chart{};
    var cv = c.canvas("dial", .{ .at = annapolis, .space = .points });
    cv.beginPath();
    cv.moveTo(0, 0);
    var i: usize = 0;
    while (i < 2600) : (i += 1) cv.lineTo(1, 2);
    // The budget: 2048 commands recorded, the rest counted and dropped.
    try expect.expectEqual(@as(u32, max_canvas_cmds), cv.n);
    try expect.expectEqual(@as(u32, 2600 + 2 - max_canvas_cmds), cv.dropped);
    cv.done();

    const body = scene.buf[0..scene.len];
    try expect.expect(std.mem.indexOf(u8, body, "\"kind\":\"canvas\"") != null);
    try expect.expect(std.mem.indexOf(u8, body, "\"space\":\"points\"") != null);
    var lines: usize = 0;
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, body, at, "[\"L\"")) |p| {
        lines += 1;
        at = p + 1;
    }
    try expect.expectEqual(@as(usize, max_canvas_cmds - 2), lines);

    // What went out parses as the JSON the host's parser will see.
    var buf: [2 * scene_bytes]u8 = undefined;
    const full = try std.fmt.bufPrint(&buf, "{s}]{c}", .{ body, '}' });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), full, .{});
    const objs = parsed.object.get("set").?.array.items;
    try expect.expectEqual(@as(usize, 1), objs.len);
    try expect.expectEqual(@as(usize, max_canvas_cmds), objs[0].object.get("cmds").?.array.items.len);
}

test "canvas encoder: styles, gradients, anchors and the text budget" {
    scene.begin();
    defer scene.forget();
    var c = Chart{};
    var cv = c.canvas("g", .{ .anchor = .ownship, .space = .geo });
    cv.fillStyle(.{ .linear = .{
        .from = .{ 0, 0 },
        .to = .{ 10, 0 },
        .stops = &.{
            .{ .t = 0, .color = .{ .rgba = .{ 0, 0, 0, 1 } } },
            .{ .t = 1, .color = .{ .token = .warning } },
        },
    } });
    cv.beginPath();
    cv.arc(0, 0, 5, 0, 360, false);
    cv.fill();
    cv.strokeStyle(.{ .token = .ownship });
    cv.lineWidth(2);
    cv.lineCap(.round);
    cv.stroke();
    cv.font(12, .bold);
    cv.textAlign(.center);
    const big: [300]u8 = @splat('x');
    cv.fillText(&big, 0, 0);
    cv.done();

    const body = scene.buf[0..scene.len];
    try expect.expect(std.mem.indexOf(u8, body, "\"anchor\":\"ownship\"") != null);
    try expect.expect(std.mem.indexOf(u8, body, "\"space\":\"geo\"") != null);
    try expect.expect(std.mem.indexOf(u8, body,
        \\{"lin":[0,0,10,0],"stops":[[0,[0,0,0,1]],[1,"warning"]]}
    ) != null);
    try expect.expect(std.mem.indexOf(u8, body, "[\"font\",12,\"bold\"]") != null);
    try expect.expect(std.mem.indexOf(u8, body, "[\"cap\",\"round\"]") != null);
    // The 300-byte run went out truncated to the budget.
    try expect.expectEqual(@as(usize, max_canvas_text), std.mem.count(u8, body, "x"));
}

test "canvas encoder: a fixed canvas with no position leaves no trace" {
    scene.begin();
    defer scene.forget();
    var c = Chart{};
    const before = scene.len;
    var cv = c.canvas("ghost", .{});
    cv.beginPath();
    cv.moveTo(0, 0);
    cv.lineTo(1, 1);
    cv.fill();
    cv.done();
    try expect.expectEqual(before, scene.len);
    try expect.expectEqual(@as(usize, 0), scene.sets);
}

// -- tables -------------------------------------------------------------------

const TestTable = table(.{
    .key = "targets",
    .title = "AIS Targets",
    .menu = "Vessels",
    .columns = &.{
        .{ .key = "name", .label = "Vessel", .type = .text },
        .{ .key = "cpa", .label = "CPA", .type = .distance },
        .{ .key = "state", .label = "", .type = .flag },
    },
    .sort = .{ .key = "cpa", .ascending = true },
    .at = .{ .lat = "lat", .lon = "lon" },
});

test "a declaration renders the entry the manifest has to carry" {
    try expect.expectEqualStrings(
        "{\"key\":\"targets\",\"title\":\"AIS Targets\",\"menu\":\"Vessels\",\"columns\":[" ++
            "{\"key\":\"name\",\"label\":\"Vessel\",\"type\":\"text\"}," ++
            "{\"key\":\"cpa\",\"label\":\"CPA\",\"type\":\"distance\"}," ++
            "{\"key\":\"state\",\"label\":\"\",\"type\":\"flag\"}]," ++
            "\"sort\":{\"key\":\"cpa\",\"ascending\":true},\"at\":{\"lat\":\"lat\",\"lon\":\"lon\"}}",
        TestTable.lk_table_json,
    );
    try expect.expectEqualStrings("[" ++ TestTable.lk_table_json ++ "]", tablesJson(.{TestTable}));
}

test "no rows are built while the dialog is shut" {
    raw_lk.test_hooks.reset();
    _ = TestTable.lkOpen("targets", false);
    TestTable.lkBegin();
    try expect.expect(!TestTable.isOpen());
    TestTable.upsert(.{ .id = "1", .name = "ANNE", .cpa = 124.0 });
    TestTable.lkFlush();
    try expect.expectEqual(@as(usize, 0), TestTable.lkBatch().len);
}

test "a cycle sends the rows that changed and removes the ones it did not describe" {
    // The clock stands still, so the cadence gate stays open and every cycle
    // here builds.
    raw_lk.test_hooks.reset();
    try expect.expect(TestTable.lkOpen("targets", true));
    defer _ = TestTable.lkOpen("targets", false);

    // Everything is new, so everything goes out. A cell the plugin has no
    // value for is left off, and the host reads that as a dash.
    TestTable.lkBegin();
    TestTable.upsert(.{
        .id = "899000101",
        .band = @as(i32, 0),
        .name = "ANNE",
        .cpa = 124.0,
        .state = @as(?[]const u8, "alarm"),
        .lat = 38.97,
        .lon = -76.46,
    });
    TestTable.upsert(.{ .id = "899000707", .band = @as(i32, 1), .name = "BRAVO", .cpa = @as(?f64, null) });
    TestTable.lkFlush();
    try expect.expectEqualStrings(
        "{\"key\":\"targets\",\"upsert\":[" ++
            "{\"id\":\"899000101\",\"band\":0,\"name\":\"ANNE\",\"cpa\":124,\"state\":\"alarm\"," ++
            "\"lat\":38.97,\"lon\":-76.46}," ++
            "{\"id\":\"899000707\",\"band\":1,\"name\":\"BRAVO\",\"cpa\":null}]," ++
            "\"remove\":[]}",
        TestTable.lkBatch(),
    );

    // The same picture again: nothing changed, so nothing is sent.
    TestTable.lkBegin();
    TestTable.upsert(.{
        .id = "899000101",
        .band = @as(i32, 0),
        .name = "ANNE",
        .cpa = 124.0,
        .state = @as(?[]const u8, "alarm"),
        .lat = 38.97,
        .lon = -76.46,
    });
    TestTable.upsert(.{ .id = "899000707", .band = @as(i32, 1), .name = "BRAVO", .cpa = @as(?f64, null) });
    TestTable.lkFlush();
    // Not even an empty batch: the commit sees nothing to say and returns,
    // leaving the envelope it opened unfinished.
    try expect.expectEqualStrings("{\"key\":\"targets\",\"upsert\":[", TestTable.lkBatch());

    // One row moves and the other is not described at all: one upsert, one
    // removal, and the mariner's table follows the sea.
    TestTable.lkBegin();
    TestTable.upsert(.{
        .id = "899000101",
        .band = @as(i32, 0),
        .name = "ANNE",
        .cpa = 96.0,
        .state = @as(?[]const u8, "alarm"),
        .lat = 38.97,
        .lon = -76.46,
    });
    TestTable.lkFlush();
    try expect.expect(std.mem.indexOf(u8, TestTable.lkBatch(), "\"cpa\":96") != null);
    try expect.expect(std.mem.indexOf(u8, TestTable.lkBatch(), "\"remove\":[\"899000707\"]") != null);

    // And a row taken out by hand leaves at the next commit.
    TestTable.lkBegin();
    TestTable.upsert(.{ .id = "899000101", .band = @as(i32, 0), .name = "ANNE", .cpa = 96.0, .state = @as(?[]const u8, "alarm"), .lat = 38.97, .lon = -76.46 });
    TestTable.remove("899000101");
    TestTable.lkFlush();
    try expect.expect(std.mem.indexOf(u8, TestTable.lkBatch(), "\"remove\":[\"899000101\"]") != null);
}

test "closing the dialog forgets what was on it" {
    raw_lk.test_hooks.reset();
    try expect.expect(TestTable.lkOpen("targets", true));
    TestTable.lkBegin();
    TestTable.upsert(.{ .id = "1", .name = "ANNE", .cpa = 124.0 });
    TestTable.lkFlush();
    try expect.expect(std.mem.indexOf(u8, TestTable.lkBatch(), "\"ANNE\"") != null);

    // The host drops the rows when the dialog closes, so the library must too:
    // the next opening has to describe the whole set again.
    _ = TestTable.lkOpen("targets", false);
    try expect.expect(TestTable.lkOpen("targets", true));
    defer _ = TestTable.lkOpen("targets", false);
    TestTable.lkBegin();
    TestTable.upsert(.{ .id = "1", .name = "ANNE", .cpa = 124.0 });
    TestTable.lkFlush();
    try expect.expect(std.mem.indexOf(u8, TestTable.lkBatch(), "\"ANNE\"") != null);
}

test "the cadence gate holds a rebuild to one a second whatever the data rate" {
    // The gate is what lets the cycle ride the data path. Values land at up
    // to 10 Hz and the AIS set at 2 Hz; the batch that reaches the host is
    // still one a second.
    raw_lk.test_hooks.reset();
    defer raw_lk.test_hooks.reset();
    raw_lk.test_hooks.advance(1);
    try expect.expect(TestTable.lkOpen("targets", true));
    defer _ = TestTable.lkOpen("targets", false);

    fillOneRow(0);
    try expect.expectEqual(@as(usize, 1), raw_lk.test_hooks.count(.table_update));

    // Eleven cycles across the next 990 ms, each describing a row the last one
    // did not. Exactly one of them clears the 950 ms gate.
    for (1..12) |i| {
        raw_lk.test_hooks.advance(90);
        fillOneRow(@floatFromInt(i));
    }
    try expect.expectEqual(@as(usize, 2), raw_lk.test_hooks.count(.table_update));
    try expect.expect(std.mem.indexOf(u8, TestTable.lkBatch(), "\"cpa\":11") != null);
}

fn fillOneRow(cpa: f64) void {
    TestTable.lkBegin();
    TestTable.upsert(.{ .id = "899000101", .name = "ANNE", .cpa = cpa });
    TestTable.lkFlush();
}

// -- the table cycle rides the data path ---------------------------------------

/// A plugin that draws and keeps a dialog. `draw` upserts nothing: the rows
/// are `onUpdate`'s work.
const BothPaths = struct {
    pub const Rows = table(.{
        .key = "both",
        .title = "Both",
        .menu = "Test",
        .columns = &.{.{ .key = "cpa", .label = "CPA", .type = .distance }},
    });

    // Not pub: `Declared` reads the plugin's public declarations, and a
    // counter is not one of them.
    var updates: usize = 0;
    var draws: usize = 0;

    pub fn onUpdate() void {
        updates += 1;
        Rows.upsert(.{ .id = "899000101", .cpa = @as(f64, @floatFromInt(updates)) });
    }

    pub fn draw(c: *Chart) void {
        draws += 1;
        c.status("{d} drawn", .{draws});
    }
};

/// A plugin with a dialog and no chart at all. It has no draw timer, so under
/// a cycle that rode `draw` its table could never fill.
const TableOnly = struct {
    pub const Rows = table(.{
        .key = "only",
        .title = "Only",
        .menu = "Test",
        .columns = &.{.{ .key = "cpa", .label = "CPA", .type = .distance }},
    });

    pub fn onUpdate() void {
        Rows.upsert(.{ .id = "899000101", .cpa = 124.0 });
    }
};

test "opening a dialog fills it without drawing, and a frame leaves it alone" {
    raw_lk.test_hooks.reset();
    defer raw_lk.test_hooks.reset();
    const W = Wiring(BothPaths);
    BothPaths.updates = 0;
    BothPaths.draws = 0;

    try W.start(.{ .api = raw_lk.api_version, .config = .null });
    const draw_timer = raw_lk.test_hooks.last(.timer_set).?.id;
    try expect.expectEqual(@as(usize, 1), raw_lk.test_hooks.count(.timer_set));

    // The dialog opens. The rows go out, and nothing was drawn to produce
    // them: no second timer, no overlay batch.
    try W.onEvent(.{ .table_open = "both" });
    defer _ = BothPaths.Rows.lkOpen("both", false);
    try expect.expectEqual(@as(usize, 1), BothPaths.updates);
    try expect.expectEqual(@as(usize, 0), BothPaths.draws);
    try expect.expectEqual(@as(usize, 1), raw_lk.test_hooks.count(.timer_set));
    try expect.expectEqual(@as(usize, 1), raw_lk.test_hooks.count(.table_update));
    try expect.expect(std.mem.indexOf(u8, raw_lk.test_hooks.last(.table_update).?.payload(), "\"cpa\":1") != null);

    // A frame draws and says its line. It runs no decision and sends no rows.
    try W.onEvent(.{ .timer = draw_timer });
    try expect.expectEqual(@as(usize, 1), BothPaths.draws);
    try expect.expectEqual(@as(usize, 1), BothPaths.updates);
    try expect.expectEqual(@as(usize, 1), raw_lk.test_hooks.count(.table_update));
}

test "a plugin with no draw fills the dialog it declared" {
    raw_lk.test_hooks.reset();
    defer raw_lk.test_hooks.reset();
    const W = Wiring(TableOnly);

    try W.start(.{ .api = raw_lk.api_version, .config = .null });
    // No draw, so no timer was ever asked for.
    try expect.expectEqual(@as(usize, 0), raw_lk.test_hooks.count(.timer_set));
    try expect.expectEqual(@as(usize, 1), raw_lk.test_hooks.count(.table_declare));

    try W.onEvent(.{ .table_open = "only" });
    defer _ = TableOnly.Rows.lkOpen("only", false);
    try expect.expectEqualStrings(
        "{\"key\":\"only\",\"upsert\":[{\"id\":\"899000101\",\"cpa\":124}],\"remove\":[]}",
        raw_lk.test_hooks.last(.table_update).?.payload(),
    );

    // Shut again, and the cycle stops: nobody is looking.
    try W.onEvent(.{ .table_closed = "only" });
    const before = raw_lk.test_hooks.count(.table_update);
    try W.onEvent(.{ .table_open = "other plugin's key" });
    try expect.expectEqual(before, raw_lk.test_hooks.count(.table_update));

    // It declares no input either, so it has nothing that can go stale and
    // waits for nothing. An idle plugin holds no timer at all.
    try expect.expectEqual(@as(usize, 0), raw_lk.test_hooks.count(.timer_set));
}

// -- the cycle runs when a value expires -------------------------------------

/// One value in the shape the host sends it.
fn storeJson(comptime path: []const u8, comptime value: []const u8) []const u8 {
    return "{\"values\":[{\"path\":\"" ++ path ++ "\",\"value\":" ++ value ++ ",\"ts\":1,\"age_ms\":0}]}";
}

/// A plugin with one value and a dialog. The row exists only while the
/// value counts, so the table has to follow the feed both ways.
const FeedTable = struct {
    pub const inputs = struct {
        pub const depth = subscribeNumber("environment.depth.belowTransducer", .{});
    };

    pub const Rows = table(.{
        .key = "sounder",
        .title = "Sounder",
        .menu = "Test",
        .columns = &.{.{ .key = "depth", .label = "Depth", .type = .distance }},
    });

    var updates: usize = 0;

    pub fn onUpdate() void {
        updates += 1;
        const d = inputs.depth.fresh() orelse return;
        Rows.upsert(.{ .id = "belowTransducer", .depth = d });
    }
};

test "a table empties when its feed stops" {
    raw_lk.test_hooks.reset();
    defer raw_lk.test_hooks.reset();
    const W = Wiring(FeedTable);
    FeedTable.updates = 0;
    raw_lk.test_hooks.advance(1);

    try W.start(.{ .api = raw_lk.api_version, .config = .null });
    try W.onEvent(.{ .table_open = "sounder" });
    defer _ = FeedTable.Rows.lkOpen("sounder", false);

    // Nothing has arrived, so nothing can expire and nothing is waiting.
    try expect.expectEqual(@as(usize, 0), raw_lk.test_hooks.count(.timer_set));

    // A sounding lands. The row is on the dialog, and the cycle has taken an
    // appointment for the moment that value stops counting: one millisecond
    // past its window, because the last millisecond still counts.
    try W.onEvent(.{ .store_changed = storeJson("environment.depth.belowTransducer", "3.4") });
    try expect.expect(std.mem.indexOf(
        u8,
        raw_lk.test_hooks.last(.table_update).?.payload(),
        "\"depth\":3.4",
    ) != null);
    const appt = raw_lk.test_hooks.last(.timer_set).?;
    try expect.expectEqual(@as(usize, 1), raw_lk.test_hooks.count(.timer_set));
    try expect.expect(!appt.flag); // one-shot: an appointment, not a poll
    try expect.expectEqual(default_max_age_ms + 1, appt.num);

    // Now the feed stops. Nothing else arrives, ever. The appointment comes
    // round, the cycle runs on a value that no longer counts, and the row it
    // fed leaves the dialog instead of sitting there for good.
    raw_lk.test_hooks.advance(appt.num);
    try W.onEvent(.{ .timer = appt.id });
    // Opening the dialog, the sounding, and the expiry: three cycles.
    try expect.expectEqual(@as(usize, 3), FeedTable.updates);
    try expect.expectEqualStrings(
        "{\"key\":\"sounder\",\"upsert\":[],\"remove\":[\"belowTransducer\"]}",
        raw_lk.test_hooks.last(.table_update).?.payload(),
    );

    // The plugin has been told, and there is no later moment to tell it
    // about. Nothing is armed, so a boat whose instruments are off costs
    // nothing until a value arrives.
    try expect.expectEqual(@as(usize, 1), raw_lk.test_hooks.count(.timer_set));
}

/// Two values on different clocks: the wind is slower than the position, so
/// they stop counting at different moments.
const TwoClocks = struct {
    pub const wind_max_age_ms: i64 = 20_000;

    pub const inputs = struct {
        pub const boat = subscribePosition("navigation.position", .{ .optional = true });
        pub const twd = subscribeNumber("environment.wind.directionTrue", .{
            .optional = true,
            .max_age_ms = wind_max_age_ms,
        });
    };

    var have_boat: bool = false;
    var have_wind: bool = false;

    pub fn onUpdate() void {
        have_boat = inputs.boat.fresh() != null;
        have_wind = inputs.twd.fresh() != null;
    }
};

test "each input expires on its own wakeup" {
    raw_lk.test_hooks.reset();
    defer raw_lk.test_hooks.reset();
    const W = Wiring(TwoClocks);
    raw_lk.test_hooks.advance(1);

    try W.start(.{ .api = raw_lk.api_version, .config = .null });
    try W.onEvent(.{ .store_changed = storeJson("navigation.position", "{\"lat\":38.97,\"lon\":-76.46}") });
    try W.onEvent(.{ .store_changed = storeJson("environment.wind.directionTrue", "210") });
    try expect.expect(TwoClocks.have_boat);
    try expect.expect(TwoClocks.have_wind);

    // The earliest window rules the appointment. The wind has fifteen seconds
    // left, so waking for it now would find nothing to say.
    const first = raw_lk.test_hooks.last(.timer_set).?;
    try expect.expectEqual(default_max_age_ms + 1, first.num);

    // The position goes and the wind stays. The plugin is told which one, and
    // the next appointment is the wind's own.
    raw_lk.test_hooks.advance(first.num);
    try W.onEvent(.{ .timer = first.id });
    try expect.expect(!TwoClocks.have_boat);
    try expect.expect(TwoClocks.have_wind);
    const second = raw_lk.test_hooks.last(.timer_set).?;
    try expect.expectEqual(TwoClocks.wind_max_age_ms - default_max_age_ms, second.num);

    // The wind goes too. Both are stale, nothing further can change, and
    // nothing is armed.
    const set_before = raw_lk.test_hooks.count(.timer_set);
    raw_lk.test_hooks.advance(second.num);
    try W.onEvent(.{ .timer = second.id });
    try expect.expect(!TwoClocks.have_wind);
    try expect.expectEqual(set_before, raw_lk.test_hooks.count(.timer_set));
}

/// A plugin that draws and decides. The two run off different clocks, and the
/// mariner can switch off only one of them.
const DrawAndDecide = struct {
    pub const inputs = struct {
        pub const sog = subscribeNumber("navigation.speedOverGround", .{});
    };

    var updates: usize = 0;

    pub fn onUpdate() void {
        updates += 1;
    }

    pub fn draw(c: *Chart) void {
        c.status("drawing", .{});
    }
};

test "the appointment is kept while the chart grant is off" {
    raw_lk.test_hooks.reset();
    defer raw_lk.test_hooks.reset();
    const W = Wiring(DrawAndDecide);
    DrawAndDecide.updates = 0;
    raw_lk.test_hooks.advance(1);

    try W.start(.{ .api = raw_lk.api_version, .config = .null });
    const draw_timer = raw_lk.test_hooks.last(.timer_set).?.id;

    // The mariner switches drawing off and the draw timer goes down.
    try W.onEvent(.{ .grants_changed = "{\"granted\":[]}" });
    try expect.expectEqual(@as(usize, 1), raw_lk.test_hooks.count(.timer_cancel));
    try expect.expectEqual(draw_timer, raw_lk.test_hooks.last(.timer_cancel).?.id);

    // A value still arrives and still takes its appointment. A plugin with
    // no permission to draw has a dialog to fill and a condition to watch.
    try W.onEvent(.{ .store_changed = storeJson("navigation.speedOverGround", "3.1") });
    const appt = raw_lk.test_hooks.last(.timer_set).?;
    try expect.expect(appt.id != draw_timer);
    try expect.expect(!appt.flag);
    try expect.expectEqual(default_max_age_ms + 1, appt.num);

    // And it is delivered, without the draw timer coming back.
    raw_lk.test_hooks.advance(appt.num);
    try W.onEvent(.{ .timer = appt.id });
    // The value, and its expiry.
    try expect.expectEqual(@as(usize, 2), DrawAndDecide.updates);
    // The draw timer at start, and the appointment. Nothing else was armed.
    try expect.expectEqual(@as(usize, 2), raw_lk.test_hooks.count(.timer_set));
}

/// A plugin that draws a value and declares no hook at all. The value can
/// still stop counting, and what was drawn from it has to come off the chart.
const DrawOnly = struct {
    pub const inputs = struct {
        pub const twd = subscribeNumber("environment.wind.directionTrue", .{});
    };

    pub fn draw(c: *Chart) void {
        c.status("drawing", .{});
    }
};

test "a plugin that only draws is woken when its value expires" {
    raw_lk.test_hooks.reset();
    defer raw_lk.test_hooks.reset();
    const W = Wiring(DrawOnly);
    raw_lk.test_hooks.advance(1);

    try W.start(.{ .api = raw_lk.api_version, .config = .null });
    const draw_timer = raw_lk.test_hooks.last(.timer_set).?.id;
    try expect.expectEqual(@as(usize, 1), raw_lk.test_hooks.count(.timer_set));

    // The wind lands, and the appointment comes with it. The declared inputs
    // decide that. Which hooks the author wrote says nothing about when a
    // value stops counting.
    try W.onEvent(.{ .store_changed = storeJson("environment.wind.directionTrue", "215") });
    try expect.expect(DrawOnly.inputs.twd.fresh() != null);
    const appt = raw_lk.test_hooks.last(.timer_set).?;
    try expect.expect(appt.id != draw_timer);
    try expect.expect(!appt.flag); // one-shot: an appointment, not a poll
    try expect.expectEqual(default_max_age_ms + 1, appt.num);

    // It comes round on a value that no longer counts, and there is no later
    // moment to wait for.
    raw_lk.test_hooks.advance(appt.num);
    try W.onEvent(.{ .timer = appt.id });
    try expect.expect(DrawOnly.inputs.twd.fresh() == null);
    try expect.expectEqual(@as(usize, 2), raw_lk.test_hooks.count(.timer_set));
}

/// A plugin that draws from nothing off the boat: a scale bar, a grid.
const NoInputs = struct {
    pub fn draw(c: *Chart) void {
        c.status("drawing", .{});
    }
};

test "a plugin with no declared input holds no appointment" {
    raw_lk.test_hooks.reset();
    defer raw_lk.test_hooks.reset();
    const W = Wiring(NoInputs);
    raw_lk.test_hooks.advance(1);

    try W.start(.{ .api = raw_lk.api_version, .config = .null });
    const draw_timer = raw_lk.test_hooks.last(.timer_set).?.id;

    // Values land for the plugins that asked for them. This one asked for
    // none, so it holds nothing that can go stale and waits on no clock.
    try W.onEvent(.{ .store_changed = storeJson("environment.wind.directionTrue", "215") });
    try W.onEvent(.{ .timer = draw_timer });
    try expect.expectEqual(@as(usize, 1), raw_lk.test_hooks.count(.timer_set));
}

/// A plugin watching the traffic and nothing else.
const WatchTraffic = struct {
    pub const vessel_ms: i64 = 180_000;
    pub const aid_ms: i64 = 600_000;

    pub const inputs = struct {
        pub const traffic = subscribeAis(.{
            .max = 8,
            .max_age_ms = vessel_ms,
            .aton_max_age_ms = aid_ms,
        });
    };

    var live: usize = 0;

    pub fn onUpdate() void {
        live = 0;
        for (inputs.traffic.targets()) |*t| {
            const window = if (t.aton) aid_ms else vessel_ms;
            if (t.age_ms <= window) live += 1;
        }
    }
};

test "a target ages out on its own wakeup, without another target reporting" {
    raw_lk.test_hooks.reset();
    defer raw_lk.test_hooks.reset();
    const W = Wiring(WatchTraffic);
    raw_lk.test_hooks.advance(1);

    try W.start(.{ .api = raw_lk.api_version, .config = .null });
    // One vessel and one aid, heard at the same moment. They age on different
    // clocks, so they leave on different wakeups.
    try W.onEvent(.{ .ais_changed = "{\"targets\":[" ++
        "{\"mmsi\":899000101,\"lat\":38.97,\"lon\":-76.46,\"age_ms\":0}," ++
        "{\"mmsi\":998990101,\"lat\":38.98,\"lon\":-76.47,\"aton\":true,\"age_ms\":0}]}" });
    try expect.expectEqual(@as(usize, 2), WatchTraffic.live);

    // The receiver goes quiet. The vessel's own limit comes first.
    const first = raw_lk.test_hooks.last(.timer_set).?;
    try expect.expectEqual(WatchTraffic.vessel_ms + 1, first.num);
    raw_lk.test_hooks.advance(first.num);
    try W.onEvent(.{ .timer = first.id });
    try expect.expectEqual(@as(usize, 1), WatchTraffic.live);

    // Then the aid's, on the slower clock an aid reports to.
    const second = raw_lk.test_hooks.last(.timer_set).?;
    try expect.expectEqual(WatchTraffic.aid_ms - WatchTraffic.vessel_ms, second.num);
    const set_before = raw_lk.test_hooks.count(.timer_set);
    raw_lk.test_hooks.advance(second.num);
    try W.onEvent(.{ .timer = second.id });
    try expect.expectEqual(@as(usize, 0), WatchTraffic.live);

    // An empty sea can change no further on its own.
    try expect.expectEqual(set_before, raw_lk.test_hooks.count(.timer_set));
}

// -- retained state rides the data path ----------------------------------------

/// A plugin that keeps something across calls: a track, a filter, a count of
/// legs. The state is advanced where the fixes land, and `draw` reads it.
const Keeper = struct {
    pub const inputs = struct {
        pub const fix = subscribePosition("navigation.position", .{});
    };

    var kept: usize = 0;
    var frames: usize = 0;

    pub fn onUpdate() void {
        if (inputs.fix.fresh() == null) return;
        kept += 1;
    }

    pub fn draw(c: *Chart) void {
        frames += 1;
        c.status("{d} kept", .{kept});
    }
};

test "retained state follows the fixes, and a frame leaves it alone" {
    raw_lk.test_hooks.reset();
    defer raw_lk.test_hooks.reset();
    const W = Wiring(Keeper);
    Keeper.kept = 0;
    Keeper.frames = 0;
    raw_lk.test_hooks.advance(1);

    try W.start(.{ .api = raw_lk.api_version, .config = .null });
    const draw_timer = raw_lk.test_hooks.last(.timer_set).?.id;

    // Two fixes, both taken, and nothing drawn yet.
    try W.onEvent(.{ .store_changed = storeJson("navigation.position", "{\"lat\":38.97,\"lon\":-76.46}") });
    raw_lk.test_hooks.advance(1_000);
    try W.onEvent(.{ .store_changed = storeJson("navigation.position", "{\"lat\":38.98,\"lon\":-76.46}") });
    try expect.expectEqual(@as(usize, 2), Keeper.kept);
    try expect.expectEqual(@as(usize, 0), Keeper.frames);

    // The frame rate belongs to the picture. Only data reaching `onUpdate`
    // keeps a point, so three more frames leave the count at two.
    for (0..3) |_| try W.onEvent(.{ .timer = draw_timer });
    try expect.expectEqual(@as(usize, 3), Keeper.frames);
    try expect.expectEqual(@as(usize, 2), Keeper.kept);
}

// -- mixing declared inputs with raw subscriptions -----------------------------

/// The plugin under test: one declared input, and one path it wants raw.
const MixedSpeed = subscribeNumber("navigation.speedOverGround", .{});
const raw_path = "environment.depth.belowTransducer";

fn pathValue(path: []const u8, v: std.json.Value, ts: i64, age: i64) raw_lk.PathValue {
    return .{ .path = path, .value = v, .ts_ms = ts, .age_ms = age };
}

/// The rebuilt payload, parsed the way a plugin's own handler would parse it.
/// `raw_lk.pathValues` cannot be used here: it allocates from the scratch arena,
/// which grows through a wasm builtin this test does not have.
fn spilled(alloc: std.mem.Allocator, json: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, alloc, json, .{});
}

test "a plugin that declares one input and raw-subscribes another sees both" {
    const a = expect.allocator;

    const routed = routeValues(&.{MixedSpeed}, &.{
        pathValue("navigation.speedOverGround", .{ .float = 3.2 }, 1, 10),
        pathValue(raw_path, .{ .float = 4.5 }, 2, 20),
    }, "", 100_000);
    const rest = routed.rest;

    // One value was a declared input's. That count is what tells the library
    // an input changed, so `onUpdate` runs on a batch that touched one and not
    // on a batch that touched none.
    try expect.expectEqual(@as(usize, 1), routed.claimed);

    // THE DECLARED HALF still lands in its input, aged and gated as always.
    try expect.expectApproxEqAbs(@as(f64, 3.2), MixedSpeed.get(), 1e-9);

    // THE RAW HALF reaches the plugin instead of being swallowed. This is the
    // whole bug: the library matched the declared paths and returned.
    var parsed = try spilled(a, rest orelse return error.RawValueLost);
    defer parsed.deinit();
    const values = parsed.value.object.get("values").?.array.items;
    try expect.expectEqual(@as(usize, 1), values.len);
    try expect.expectEqualStrings(raw_path, values[0].object.get("path").?.string);
    try expect.expectApproxEqAbs(@as(f64, 4.5), values[0].object.get("value").?.float, 1e-9);
    try expect.expectEqual(@as(i64, 2), values[0].object.get("ts").?.integer);
    try expect.expectEqual(@as(i64, 20), values[0].object.get("age_ms").?.integer);

    // ...and only that half: a handler looking for its own path is not handed
    // values it already has through an input.
    try expect.expect(std.mem.indexOf(u8, rest.?, "speedOverGround") == null);
}

test "a batch the declared inputs took whole reaches no handler" {
    const routed = routeValues(&.{MixedSpeed}, &.{
        pathValue("navigation.speedOverGround", .{ .float = 6.1 }, 3, 0),
    }, "", 200_000);
    try expect.expect(routed.rest == null);
    try expect.expectEqual(@as(usize, 1), routed.claimed);
    try expect.expectApproxEqAbs(@as(f64, 6.1), MixedSpeed.get(), 1e-9);
}

test "a removal and an object value survive the rebuild" {
    const a = expect.allocator;
    // A null is "this path has no source any more", which is not the same as
    // zero and must reach the plugin as a null. A position is an object, and
    // the rebuild must not flatten it.
    var at: std.json.ObjectMap = .empty;
    defer at.deinit(a);
    try at.put(a, "lat", .{ .float = 38.9763 });
    try at.put(a, "lon", .{ .float = -76.4767 });

    const routed = routeValues(&.{MixedSpeed}, &.{
        pathValue(raw_path, .null, 4, 0),
        pathValue("navigation.position", .{ .object = at }, 5, 0),
    }, "", 300_000);
    // Neither path is the declared input's, so no input changed.
    try expect.expectEqual(@as(usize, 0), routed.claimed);

    var parsed = try spilled(a, routed.rest orelse return error.RawValueLost);
    defer parsed.deinit();
    const values = parsed.value.object.get("values").?.array.items;
    try expect.expectEqual(@as(usize, 2), values.len);
    try expect.expect(values[0].object.get("value").? == .null);
    const back = values[1].object.get("value").?.object;
    try expect.expectApproxEqAbs(@as(f64, 38.9763), back.get("lat").?.float, 1e-9);
    try expect.expectApproxEqAbs(@as(f64, -76.4767), back.get("lon").?.float, 1e-9);
}

test "a rebuild that will not fit passes the whole batch through" {
    // The fallback, which is what keeps the buffer a working set rather than a
    // correctness bound: the plugin sees everything, including values it
    // already has, rather than nothing.
    const long = "x" ** (store_spill_bytes / 8);
    var many: [16]raw_lk.PathValue = @splat(pathValue(raw_path, .{ .string = long }, 6, 0));
    const src = "{\"values\":[]}";
    const routed = routeValues(&.{MixedSpeed}, &many, src, 400_000);
    try expect.expectEqualStrings(src, routed.rest.?);
}

test "subscribeAlso sends the declared paths beside the plugin's own" {
    // The union, in declaration order and without duplicates. `subscribeAlso`
    // exists because the host holds ONE subscription per plugin: a plugin
    // calling raw.subscribePaths for a path of its own would replace the
    // declared inputs with it and never be told.
    declared_paths = &.{ "navigation.position", "navigation.speedOverGround" };
    defer declared_paths = &.{};

    var all: [max_subscribe_paths][]const u8 = undefined;
    const n = unionPaths(&all, &.{ raw_path, "navigation.position" });
    try expect.expectEqual(@as(usize, 3), n.?);
    try expect.expectEqualStrings("navigation.position", all[0]);
    try expect.expectEqualStrings("navigation.speedOverGround", all[1]);
    try expect.expectEqualStrings(raw_path, all[2]);

    // A path already declared is not sent twice: the host would take it, but
    // the value would then match an input and never spill.
    try expect.expectEqual(@as(usize, 2), unionPaths(&all, &.{"navigation.position"}).?);

    // One past the budget is refused whole rather than trimmed: a plugin
    // missing a path it asked for is worse than one told it asked for too many.
    const full = comptime blk: {
        var out: [max_subscribe_paths][]const u8 = undefined;
        for (&out, 0..) |*slot, i| slot.* = std.fmt.comptimePrint("sensors.n{d}", .{i});
        break :blk out;
    };
    declared_paths = &full;
    try expect.expect(unionPaths(&all, &.{"one.too.many"}) == null);
}
