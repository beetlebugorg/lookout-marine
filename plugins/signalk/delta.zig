//! One Signal K delta document, mapped onto the wire shapes the host takes.
//!
//! A delta names a CONTEXT and carries updates for it. The context says whose
//! data it is: own ship, or another vessel the server heard on AIS. The plugin
//! publishes own ship into the vessel store and upserts every other vessel
//! into the AIS store.
//!
//! UNITS. Signal K is SI and its angles are RADIANS. The host's angles are
//! DEGREES. Every angle therefore converts here, once, and nothing downstream
//! has to ask. Speeds, depths and positions pass through: both sides use
//! metres, metres per second and decimal degrees.
//!
//! TIMESTAMPS. A Signal K update carries the instrument's own ISO-8601 time.
//! It is not read. The store measures staleness against the host clock, and a
//! server replaying a log would otherwise publish values that are already
//! stale.
//!
//! Nothing here talks to the host, so `zig test delta.zig` runs it natively.
//! The only import is `std`.

const std = @import("std");

/// The vessel paths the host reads. Same names as the API's table.
pub const Path = enum {
    position,
    heading_true,
    cog_true,
    sog,
    depth,
    wind_speed_apparent,
    wind_angle_apparent,
    wind_direction_true,

    pub fn text(self: Path) []const u8 {
        return switch (self) {
            .position => "navigation.position",
            .heading_true => "navigation.headingTrue",
            .cog_true => "navigation.courseOverGroundTrue",
            .sog => "navigation.speedOverGround",
            .depth => "environment.depth.belowTransducer",
            .wind_speed_apparent => "environment.wind.speedApparent",
            .wind_angle_apparent => "environment.wind.angleApparent",
            .wind_direction_true => "environment.wind.directionTrue",
        };
    }
};

/// How a Signal K value becomes a host value.
const Conv = enum {
    /// Both sides hold the same SI quantity in the same unit.
    same,
    /// Radians to degrees, wrapped into 0..360. A compass direction.
    compass,
    /// Radians to degrees, wrapped into -180..180. An angle off the bow,
    /// positive to starboard.
    signed,
    /// `{"longitude":..,"latitude":..}` to `{"lat":..,"lon":..}`.
    position,
};

const Mapping = struct {
    /// The Signal K path, which is the same string on both sides for every
    /// path in this table. The units behind it are not.
    sk: []const u8,
    to: Path,
    conv: Conv,
};

/// Every Signal K path this plugin reads. A path outside this table is ignored
/// and counted: a Signal K server offers hundreds, and the host holds eight.
pub const vocabulary = [_]Mapping{
    .{ .sk = "navigation.position", .to = .position, .conv = .position },
    .{ .sk = "navigation.headingTrue", .to = .heading_true, .conv = .compass },
    .{ .sk = "navigation.courseOverGroundTrue", .to = .cog_true, .conv = .compass },
    .{ .sk = "navigation.speedOverGround", .to = .sog, .conv = .same },
    .{ .sk = "environment.depth.belowTransducer", .to = .depth, .conv = .same },
    .{ .sk = "environment.wind.speedApparent", .to = .wind_speed_apparent, .conv = .same },
    .{ .sk = "environment.wind.angleApparent", .to = .wind_angle_apparent, .conv = .signed },
    .{ .sk = "environment.wind.directionTrue", .to = .wind_direction_true, .conv = .compass },
};

fn lookup(sk_path: []const u8) ?Mapping {
    for (vocabulary) |m| {
        if (std.mem.eql(u8, m.sk, sk_path)) return m;
    }
    return null;
}

pub const Position = struct { lat: f64, lon: f64 };

pub const Value = union(enum) {
    number: f64,
    position: Position,
    /// The server sent an explicit null: it holds the path and has no value
    /// for it now. The host takes the same meaning.
    none,
};

pub const Update = struct {
    path: Path,
    value: Value,
};

/// One delta may carry every path in the vocabulary at once.
pub const max_updates = vocabulary.len;

pub const Updates = struct {
    buf: [max_updates]Update = undefined,
    n: usize = 0,

    pub fn slice(self: *const Updates) []const Update {
        return self.buf[0..self.n];
    }

    /// The newest value for a path replaces an earlier one in the same
    /// document. A delta with two sources for one path is the server's
    /// arbitration to make, not this plugin's.
    fn put(self: *Updates, u: Update) void {
        for (self.buf[0..self.n]) |*old| {
            if (old.path == u.path) {
                old.* = u;
                return;
            }
        }
        if (self.n == self.buf.len) return;
        self.buf[self.n] = u;
        self.n += 1;
    }
};

/// One AIS target, in the units `ais_upsert` takes.
pub const TargetFields = struct {
    mmsi: u32,
    lat: ?f64 = null,
    lon: ?f64 = null,
    /// Metres per second, which is what Signal K sends and what the host
    /// takes. No conversion, unlike the AIS wire format.
    sog: ?f64 = null,
    cog: ?f64 = null,
    heading: ?f64 = null,
    /// Points into the document text that was parsed.
    name: ?[]const u8 = null,

    /// True when the delta carried nothing but the MMSI. Refreshing the
    /// timestamp of a target that is still transmitting is worth an upsert;
    /// a delta that named a vessel and said nothing about it is not.
    pub fn empty(self: TargetFields) bool {
        return self.lat == null and self.lon == null and self.sog == null and
            self.cog == null and self.heading == null and self.name == null;
    }
};

/// What one document turned out to be.
pub const Outcome = union(enum) {
    /// The server's first message. The payload is its `self` identity, which
    /// says which context is own ship, and is empty when the hello left it
    /// out. It points into the document text.
    hello: []const u8,
    /// Values for own ship.
    own: Updates,
    /// Values for another vessel.
    target: TargetFields,
    /// Nothing this plugin publishes.
    ignored,
};

/// What was thrown away, so a status line can say so.
pub const Counts = struct {
    /// Paths that are not in the vocabulary.
    unmapped: u64 = 0,
    /// Vessel contexts with no MMSI to derive.
    no_mmsi: u64 = 0,
    /// Documents that are not JSON, or are JSON that is not a delta.
    unreadable: u64 = 0,
    /// Deltas the plugin mapped to at least one value.
    used: u64 = 0,
};

/// The MRN prefix an AIS MMSI arrives under.
const mmsi_prefix = "urn:mrn:imo:mmsi:";
const vessels_prefix = "vessels.";

/// Strip the `vessels.` a context carries, so two identities compare.
fn bare(context: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, context, vessels_prefix))
        context[vessels_prefix.len..]
    else
        context;
}

/// The MMSI inside a vessel context, or null.
///
/// Only the MRN form is read: `urn:mrn:imo:mmsi:` and nine digits, which is
/// what the spec's vessel key pattern allows. A server that names a vessel by
/// UUID has no MMSI to give, and a target with no MMSI has no key in the AIS
/// store. A bare number is refused too — it is the shape of the spec's own
/// legacy sample files, which also carry degrees where the current spec has
/// radians, and reading one would put a target on the wrong heading.
pub fn mmsiOf(context: []const u8) ?u32 {
    const id = bare(context);
    if (!std.mem.startsWith(u8, id, mmsi_prefix)) return null;
    const digits = id[mmsi_prefix.len..];
    if (digits.len != 9 or digits[0] == '0') return null;
    for (digits) |c| {
        if (c < '0' or c > '9') return null;
    }
    return std.fmt.parseInt(u32, digits, 10) catch null;
}

/// True when this context is own ship.
///
/// A delta with no context at all is own ship, and so is the literal
/// `vessels.self`. A server whose own vessel has an MMSI sends own ship under
/// that MMSI, which is why the hello's `self` is matched too: without it the
/// plugin would draw its own boat a second time as an AIS target.
pub fn isSelf(context: []const u8, self_id: []const u8) bool {
    if (context.len == 0) return true;
    const id = bare(context);
    if (std.mem.eql(u8, id, "self")) return true;
    if (self_id.len == 0) return false;
    return std.mem.eql(u8, id, bare(self_id));
}

/// Radians to degrees, wrapped into 0..360.
pub fn compassDeg(rad: f64) f64 {
    const d = @mod(std.math.radiansToDegrees(rad), 360.0);
    return if (d < 0) d + 360.0 else d;
}

/// Radians to degrees, wrapped into -180..180. Dead astern reads +180, the
/// same side of the range the nmea0183 plugin puts it on.
pub fn signedDeg(rad: f64) f64 {
    const d = compassDeg(rad);
    return if (d > 180.0) d - 360.0 else d;
}

/// Read one document. `self_id` is what the last hello said own ship is, or
/// empty before one arrived. `counts` accumulates what was thrown away.
///
/// `alloc` is scratch. The `hello` and `name` payloads point into memory it
/// owns, so a caller that keeps either must copy it.
pub fn parse(
    alloc: std.mem.Allocator,
    text: []const u8,
    self_id: []const u8,
    counts: *Counts,
) Outcome {
    const root = std.json.parseFromSliceLeaky(std.json.Value, alloc, text, .{}) catch {
        counts.unreadable += 1;
        return .ignored;
    };
    if (root != .object) {
        counts.unreadable += 1;
        return .ignored;
    }
    const o = root.object;

    // The hello is the one message with no updates. `version` and `roles` are
    // the two fields the spec requires of it. `self` is optional, so a hello
    // without one leaves the plugin unable to tell own ship from traffic.
    const updates = o.get("updates") orelse {
        if (o.get("version") != null and o.get("roles") != null)
            return .{ .hello = jstr(o.get("self")) orelse "" };
        counts.unreadable += 1;
        return .ignored;
    };
    if (updates != .array) {
        counts.unreadable += 1;
        return .ignored;
    }

    const context = jstr(o.get("context")) orelse "";
    if (isSelf(context, self_id)) return own(updates.array.items, counts);

    // Anything that is not a vessel — an aircraft, a shore station, the
    // server's own metadata — has no place in either store.
    if (!std.mem.startsWith(u8, context, vessels_prefix)) return .ignored;

    const mmsi = mmsiOf(context) orelse {
        counts.no_mmsi += 1;
        return .ignored;
    };
    return target(mmsi, updates.array.items, counts);
}

fn own(updates: []const std.json.Value, counts: *Counts) Outcome {
    var out = Updates{};
    for (updates) |u| {
        for (valuesOf(u)) |v| {
            const item = switch (v) {
                .object => |x| x,
                else => continue,
            };
            const sk_path = jstr(item.get("path")) orelse continue;
            const raw = item.get("value") orelse continue;
            const m = lookup(sk_path) orelse {
                counts.unmapped += 1;
                continue;
            };
            const value = convert(m.conv, raw) orelse continue;
            out.put(.{ .path = m.to, .value = value });
        }
    }
    if (out.n == 0) return .ignored;
    counts.used += 1;
    return .{ .own = out };
}

fn target(mmsi: u32, updates: []const std.json.Value, counts: *Counts) Outcome {
    var g = TargetFields{ .mmsi = mmsi };
    for (updates) |u| {
        for (valuesOf(u)) |v| {
            const item = switch (v) {
                .object => |x| x,
                else => continue,
            };
            const sk_path = jstr(item.get("path")) orelse continue;
            const raw = item.get("value") orelse continue;

            // A vessel's name is not a navigation path, so it is read here and
            // not through the vocabulary. Signal K sends it either as its own
            // path or inside the object at the empty path.
            if (std.mem.eql(u8, sk_path, "name")) {
                if (jstr(raw)) |n| g.name = n;
                continue;
            }
            if (sk_path.len == 0) {
                if (raw == .object) {
                    if (jstr(raw.object.get("name"))) |n| g.name = n;
                }
                continue;
            }

            const m = lookup(sk_path) orelse {
                counts.unmapped += 1;
                continue;
            };
            const value = convert(m.conv, raw) orelse continue;
            switch (m.to) {
                .position => if (value == .position) {
                    g.lat = value.position.lat;
                    g.lon = value.position.lon;
                },
                .sog => if (value == .number) {
                    g.sog = value.number;
                },
                .cog_true => if (value == .number) {
                    g.cog = value.number;
                },
                .heading_true => if (value == .number) {
                    g.heading = value.number;
                },
                // Depth and wind belong to the boat carrying the instrument.
                // Another vessel's are not this chart's business.
                else => counts.unmapped += 1,
            }
        }
    }
    if (g.empty()) return .ignored;
    counts.used += 1;
    return .{ .target = g };
}

/// The `values` array of one update, or nothing.
fn valuesOf(update: std.json.Value) []const std.json.Value {
    if (update != .object) return &.{};
    const v = update.object.get("values") orelse return &.{};
    if (v != .array) return &.{};
    return v.array.items;
}

/// One Signal K value in the host's unit, or null when the value is not the
/// shape the path calls for. A number where a position belongs is a fault in
/// the server, and guessing at it would put the boat somewhere.
fn convert(conv: Conv, raw: std.json.Value) ?Value {
    if (raw == .null) return .none;
    switch (conv) {
        .position => {
            if (raw != .object) return null;
            const lat = jnum(raw.object.get("latitude")) orelse return null;
            const lon = jnum(raw.object.get("longitude")) orelse return null;
            if (!std.math.isFinite(lat) or !std.math.isFinite(lon)) return null;
            if (@abs(lat) > 90.0 or @abs(lon) > 180.0) return null;
            return .{ .position = .{ .lat = lat, .lon = lon } };
        },
        .same, .compass, .signed => {
            const n = jnum(raw) orelse return null;
            if (!std.math.isFinite(n)) return null;
            return .{ .number = switch (conv) {
                .compass => compassDeg(n),
                .signed => signedDeg(n),
                else => n,
            } };
        },
    }
}

fn jstr(v: ?std.json.Value) ?[]const u8 {
    return switch (v orelse return null) {
        .string => |s| s,
        else => null,
    };
}

fn jnum(v: ?std.json.Value) ?f64 {
    return switch (v orelse return null) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const fx = @import("fixtures.zig");
const t = std.testing;

const Harness = struct {
    arena: std.heap.ArenaAllocator,
    counts: Counts = .{},
    self_id: []const u8 = "",

    fn init() Harness {
        return .{ .arena = std.heap.ArenaAllocator.init(t.allocator) };
    }

    fn deinit(self: *Harness) void {
        self.arena.deinit();
    }

    fn read(self: *Harness, text: []const u8) Outcome {
        return parse(self.arena.allocator(), text, self.self_id, &self.counts);
    }
};

fn find(u: Updates, path: Path) ?Value {
    for (u.slice()) |x| {
        if (x.path == path) return x.value;
    }
    return null;
}

fn expectNumber(u: Updates, path: Path, expected: f64, eps: f64) !void {
    const v = find(u, path) orelse return error.PathMissing;
    try t.expect(v == .number);
    try t.expectApproxEqAbs(expected, v.number, eps);
}

test "path text matches the host's vocabulary" {
    try t.expectEqualStrings("navigation.position", Path.position.text());
    try t.expectEqualStrings("navigation.headingTrue", Path.heading_true.text());
    try t.expectEqualStrings("navigation.courseOverGroundTrue", Path.cog_true.text());
    try t.expectEqualStrings("navigation.speedOverGround", Path.sog.text());
    try t.expectEqualStrings("environment.depth.belowTransducer", Path.depth.text());
    try t.expectEqualStrings("environment.wind.speedApparent", Path.wind_speed_apparent.text());
    try t.expectEqualStrings("environment.wind.angleApparent", Path.wind_angle_apparent.text());
    try t.expectEqualStrings("environment.wind.directionTrue", Path.wind_direction_true.text());
}

test "the spec's own delta becomes an AIS target, and its name comes from the empty path" {
    var h = Harness.init();
    defer h.deinit();
    const out = h.read(fx.spec_data_model);
    try t.expect(out == .target);
    const g = out.target;
    try t.expectEqual(fx.spec_data_model_expect.mmsi, g.mmsi);
    // Speed over ground is metres per second on both sides. An AIS wire
    // format would need a conversion here and Signal K does not.
    try t.expectApproxEqAbs(fx.spec_data_model_expect.sog_mps, g.sog.?, 1e-12);
    // Course over ground is radians in Signal K and degrees in the host.
    try t.expectApproxEqAbs(fx.spec_data_model_expect.cog_deg, g.cog.?, 1e-12);
    try t.expectEqualStrings(fx.spec_data_model_expect.name, g.name.?);
    try t.expect(g.lat == null);
    try t.expectEqual(fx.spec_data_model_expect.unmapped, h.counts.unmapped);
    try t.expectEqual(@as(u64, 1), h.counts.used);
}

test "the same delta is own ship once the hello has named that MMSI" {
    var h = Harness.init();
    defer h.deinit();
    // A server whose own vessel has an MMSI sends own ship under it. Without
    // the hello the plugin would draw its own boat again as an AIS target.
    h.self_id = fx.spec_data_model_identity;
    const out = h.read(fx.spec_data_model);
    try t.expect(out == .own);
    try expectNumber(out.own, .sog, fx.spec_data_model_expect.sog_mps, 1e-12);
    try expectNumber(out.own, .cog_true, fx.spec_data_model_expect.cog_deg, 1e-12);
}

test "two sources for one path in one delta: the last one is published" {
    var h = Harness.init();
    defer h.deinit();
    h.self_id = fx.spec_multiple_values_identity;
    const out = h.read(fx.spec_multiple_values);
    try t.expect(out == .own);
    try t.expectEqual(@as(usize, 1), out.own.slice().len);
    try expectNumber(out.own, .cog_true, fx.spec_multiple_values_expect_cog_deg, 1e-12);
}

test "a vessel named by UUID has no MMSI and is counted" {
    var h = Harness.init();
    defer h.deinit();
    try t.expect(h.read(fx.spec_multiple_values) == .ignored);
    try t.expectEqual(@as(u64, 1), h.counts.no_mmsi);
    try t.expectEqual(@as(u64, 0), h.counts.unreadable);
}

test "the context may be the last key, and a target with nothing mapped is not upserted" {
    var h = Harness.init();
    defer h.deinit();
    try t.expect(h.read(fx.spec_sources) == .ignored);
    // The context was read: the rate of turn was counted as unmapped, which
    // only happens after the MMSI came out of the context.
    try t.expectEqual(@as(u64, 1), h.counts.unmapped);
    try t.expectEqual(@as(u64, 0), h.counts.no_mmsi);
    try t.expectEqual(@as(u64, 0), h.counts.used);
}

test "an object value and a null value outside the vocabulary are counted, not misread" {
    var h = Harness.init();
    defer h.deinit();
    h.self_id = fx.spec_multiple_values_identity;
    try t.expect(h.read(fx.spec_notifications) == .ignored);
    try t.expectEqual(@as(u64, 2), h.counts.unmapped);
    try t.expectEqual(@as(u64, 0), h.counts.unreadable);
}

test "the hello names own ship" {
    var h = Harness.init();
    defer h.deinit();
    const out = h.read(fx.hello);
    try t.expect(out == .hello);
    try t.expectEqualStrings(fx.hello_expect_self, out.hello);
    try t.expectEqual(@as(u64, 0), h.counts.unreadable);
}

test "a hello with no self is legal and leaves own ship unnamed" {
    var h = Harness.init();
    defer h.deinit();
    const out = h.read(fx.hello_minimal);
    try t.expect(out == .hello);
    try t.expectEqual(@as(usize, 0), out.hello.len);
    try t.expectEqual(@as(u64, 0), h.counts.unreadable);
}

test "a position keeps its degrees and takes the host's field names" {
    var h = Harness.init();
    defer h.deinit();
    const out = h.read(fx.position_delta);
    try t.expect(out == .own);
    const v = find(out.own, .position) orelse return error.PathMissing;
    try t.expect(v == .position);
    try t.expectApproxEqAbs(fx.position_expect.lat, v.position.lat, 1e-12);
    try t.expectApproxEqAbs(fx.position_expect.lon, v.position.lon, 1e-12);
}

test "an angle arrives in radians and publishes in degrees" {
    var h = Harness.init();
    defer h.deinit();
    const out = h.read(fx.heading_delta);
    try t.expect(out == .own);
    // A plugin that passed the number through would put the boat on a
    // heading of 1.57 degrees.
    try expectNumber(out.own, .heading_true, 90.0, 1e-12);
}

test "a compass direction wraps into 0..360 and never reads negative" {
    try t.expectApproxEqAbs(@as(f64, 0.0), compassDeg(0.0), 1e-12);
    try t.expectApproxEqAbs(@as(f64, 180.0), compassDeg(std.math.pi), 1e-12);
    try t.expectApproxEqAbs(@as(f64, 270.0), compassDeg(-std.math.pi / 2.0), 1e-9);
    try t.expectApproxEqAbs(@as(f64, 10.0), compassDeg(std.math.degreesToRadians(370.0)), 1e-9);
    try t.expectApproxEqAbs(@as(f64, 0.0), compassDeg(2.0 * std.math.pi), 1e-9);
}

test "an angle off the bow keeps its sign, positive to starboard" {
    try t.expectApproxEqAbs(@as(f64, 45.0), signedDeg(std.math.pi / 4.0), 1e-9);
    try t.expectApproxEqAbs(@as(f64, -45.0), signedDeg(-std.math.pi / 4.0), 1e-9);
    try t.expectApproxEqAbs(@as(f64, 180.0), signedDeg(std.math.pi), 1e-9);
    // 315 degrees off the bow is 45 degrees to port.
    try t.expectApproxEqAbs(@as(f64, -45.0), signedDeg(std.math.degreesToRadians(315.0)), 1e-9);
}

test "wind crosses as three values and two of them convert" {
    var h = Harness.init();
    defer h.deinit();
    const out = h.read(fx.wind_delta);
    try t.expect(out == .own);
    try t.expectEqual(@as(usize, 3), out.own.slice().len);
    try expectNumber(out.own, .wind_speed_apparent, fx.wind_expect_speed_mps, 1e-12);
    try expectNumber(out.own, .wind_angle_apparent, fx.wind_expect_angle_deg, 1e-12);
    try expectNumber(out.own, .wind_direction_true, fx.wind_expect_direction_deg, 1e-12);
}

test "own ship is the empty context and the literal vessels.self" {
    var h = Harness.init();
    defer h.deinit();
    try t.expect(h.read(fx.no_context_delta) == .own);
    try t.expect(h.read(fx.null_delta) == .own);
    try t.expect(isSelf("", ""));
    try t.expect(isSelf("vessels.self", ""));
    try t.expect(isSelf("self", ""));
    // The hello's identity matches with or without the branch prefix, which
    // the spec's own samples write both ways.
    try t.expect(isSelf("vessels.urn:mrn:signalk:uuid:abc", "urn:mrn:signalk:uuid:abc"));
    try t.expect(isSelf("urn:mrn:signalk:uuid:abc", "vessels.urn:mrn:signalk:uuid:abc"));
    try t.expect(!isSelf("vessels.urn:mrn:imo:mmsi:899000606", "urn:mrn:signalk:uuid:abc"));
}

test "an explicit null is a value the source no longer has" {
    var h = Harness.init();
    defer h.deinit();
    const out = h.read(fx.null_delta);
    try t.expect(out == .own);
    const v = find(out.own, .depth) orelse return error.PathMissing;
    try t.expect(v == .none);
}

test "a path outside the vocabulary is ignored quietly and counted" {
    var h = Harness.init();
    defer h.deinit();
    const out = h.read(fx.mixed_delta);
    // The one mapped path in the document still publishes.
    try t.expect(out == .own);
    try t.expectEqual(@as(usize, 1), out.own.slice().len);
    try expectNumber(out.own, .sog, fx.mixed_expect_sog_mps, 1e-12);
    try t.expectEqual(@as(u64, fx.mixed_expect_unmapped), h.counts.unmapped);
    try t.expectEqual(@as(u64, 0), h.counts.unreadable);
}

test "a delta with nothing this plugin maps yields nothing at all" {
    var h = Harness.init();
    defer h.deinit();
    try t.expect(h.read(fx.only_unmapped_delta) == .ignored);
    try t.expectEqual(@as(u64, 2), h.counts.unmapped);
    try t.expectEqual(@as(u64, 0), h.counts.used);
}

test "a vessel name arrives as its own path too" {
    var h = Harness.init();
    defer h.deinit();
    const out = h.read(fx.name_path_delta);
    try t.expect(out == .target);
    try t.expectEqual(@as(u32, 899000505), out.target.mmsi);
    try t.expectEqualStrings("COPPER KETTLE", out.target.name.?);
    try t.expectApproxEqAbs(@as(f64, 4.1), out.target.sog.?, 1e-12);
}

test "a context that is not a vessel is ignored and is not a fault" {
    var h = Harness.init();
    defer h.deinit();
    try t.expect(h.read(fx.aton_context_delta) == .ignored);
    try t.expectEqual(@as(u64, 0), h.counts.no_mmsi);
    try t.expectEqual(@as(u64, 0), h.counts.unreadable);
}

test "a value of the wrong shape is dropped, not guessed at" {
    var h = Harness.init();
    defer h.deinit();
    try t.expect(h.read(fx.bad_position_delta) == .ignored);
    try t.expect(h.read(fx.out_of_range_position_delta) == .ignored);
    try t.expectEqual(@as(u64, 0), h.counts.used);
}

test "a malformed document is counted, not published" {
    var h = Harness.init();
    defer h.deinit();
    try t.expect(h.read("not json") == .ignored);
    try t.expect(h.read("[1,2,3]") == .ignored);
    try t.expect(h.read("{\"updates\":\"nope\"}") == .ignored);
    try t.expect(h.read("{}") == .ignored);
    try t.expectEqual(@as(u64, 4), h.counts.unreadable);
}

test "an MMSI comes out of the context URN" {
    try t.expectEqual(@as(u32, 899000505), mmsiOf("vessels.urn:mrn:imo:mmsi:899000505").?);
    try t.expectEqual(@as(u32, 899000909), mmsiOf("urn:mrn:imo:mmsi:899000909").?);
    // A UUID identity holds no MMSI.
    try t.expect(mmsiOf("vessels.urn:mrn:signalk:uuid:705f5f1a-efaf-44aa-9cb8-a0fd6305567c") == null);
    // Neither does a truncated URN, a non-digit, or a count of digits that is
    // not nine.
    try t.expect(mmsiOf("vessels.urn:mrn:imo:mmsi:") == null);
    try t.expect(mmsiOf("vessels.urn:mrn:imo:mmsi:89900050x") == null);
    try t.expect(mmsiOf("vessels.urn:mrn:imo:mmsi:8990005050") == null);
    try t.expect(mmsiOf("vessels.urn:mrn:imo:mmsi:89900050") == null);
    try t.expect(mmsiOf("vessels.urn:mrn:imo:mmsi:089900050") == null);
    // The bare-number context of the spec's legacy sample files.
    try t.expect(mmsiOf("vessels.899000505") == null);
}

test "every fixture in the file reads without a fault" {
    var h = Harness.init();
    defer h.deinit();
    for (fx.all) |doc| {
        _ = h.read(doc);
    }
    try t.expectEqual(@as(u64, 0), h.counts.unreadable);
}
