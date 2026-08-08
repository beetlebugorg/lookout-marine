//! Parsed sentences and AIS messages mapped onto the wire shapes the host
//! takes: the frozen `navigation.*` / `environment.*` paths, and the fields of
//! one `ais_upsert` target.
//!
//! Nothing here talks to the host, so `zig test paths.zig` runs it natively
//! against the same fixtures the parser is tested with. The only imports are
//! `std` and the sibling parser.
//!
//! Units are SI on both sides but not in between: the parser already returns
//! sentence speeds in m/s, while an AIS position report carries speed over
//! ground in knots. The conversion happens here, once, so `fromAis` hands back
//! metres per second like everything else crossing the API.

const std = @import("std");
const parser = @import("parser.zig");

const knot_mps = 1852.0 / 3600.0;

/// The vessel paths PROTOTYPE.md freezes for the prototype, and the ones the
/// XDR, MTW and VLW sentences add under the same Signal K naming.
///
/// UNITS. Angles are DEGREES, which is the store's rule and a deliberate
/// departure from Signal K's radians. Everything else is the SI unit Signal K
/// uses, so temperature is KELVIN and distance is METRES.
pub const Path = enum {
    position,
    heading_true,
    cog_true,
    sog,
    depth,
    wind_speed_apparent,
    wind_angle_apparent,
    wind_direction_true,
    rudder_angle,
    attitude_roll,
    attitude_pitch,
    water_temperature,
    log_total,
    log_trip,

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
            .rudder_angle => "steering.rudderAngle",
            .attitude_roll => "navigation.attitude.roll",
            .attitude_pitch => "navigation.attitude.pitch",
            .water_temperature => "environment.water.temperature",
            .log_total => "navigation.log",
            .log_trip => "navigation.trip.log",
        };
    }
};

pub const Value = union(enum) {
    number: f64,
    position: struct { lat: f64, lon: f64 },
};

pub const Update = struct {
    path: Path,
    value: Value,
};

/// The most any one sentence yields: RMC gives position, speed and course, and
/// an XDR gives heel, trim and rudder angle.
pub const max_updates = 3;

pub const Updates = struct {
    buf: [max_updates]Update = undefined,
    n: usize = 0,

    fn number(self: *Updates, path: Path, v: ?f64) void {
        const x = v orelse return;
        if (!std.math.isFinite(x)) return;
        self.push(.{ .path = path, .value = .{ .number = x } });
    }

    fn position(self: *Updates, lat: ?f64, lon: ?f64) void {
        const la = lat orelse return;
        const lo = lon orelse return;
        if (!std.math.isFinite(la) or !std.math.isFinite(lo)) return;
        self.push(.{ .path = .position, .value = .{ .position = .{ .lat = la, .lon = lo } } });
    }

    fn push(self: *Updates, u: Update) void {
        if (self.n == self.buf.len) return;
        self.buf[self.n] = u;
        self.n += 1;
    }

    pub fn slice(self: *const Updates) []const Update {
        return self.buf[0..self.n];
    }
};

/// The publishes one sentence carries. A sentence whose fields are all empty,
/// or whose validity flag says the reading is not usable, yields none: an
/// absent value is left to age out of the store rather than overwritten with a
/// guess.
///
/// Judgement calls, all one line to change:
///   * a `VHW` true heading publishes as `navigation.headingTrue` — the same
///     quantity `HDT` carries. Speed through the water has no frozen path and
///     is dropped.
///   * `MWV` with the true reference is dropped: its angle is relative to the
///     bow, and the only frozen true-wind path is a compass direction.
///   * `MWD` wind speed is dropped for the same reason — the frozen speed path
///     is the apparent one.
///   * an AIVDM sentence yields nothing here; it goes through the assembler
///     and `fromAis`.
///   * `XDR` is a list of transducers a boat's own instruments name. The three
///     read here are the ones a sailing plotter has a path for; the rest of the
///     list is left alone. The names are in `xdr_heel` and the two beside it.
pub fn fromSentence(s: parser.Sentence) Updates {
    var out = Updates{};
    switch (s) {
        .rmc => |r| {
            if (!r.valid) return out;
            out.position(r.lat, r.lon);
            out.number(.sog, r.sog_mps);
            out.number(.cog_true, r.cog_true);
        },
        .gga => |g| {
            if (g.quality == 0) return out;
            out.position(g.lat, g.lon);
        },
        .vtg => |v| {
            out.number(.sog, v.sog_mps);
            out.number(.cog_true, v.cog_true);
        },
        .hdt => |h| out.number(.heading_true, h.heading_true),
        .hdg => |h| out.number(.heading_true, h.heading_true),
        .dpt => |d| out.number(.depth, d.depth_m),
        .dbt => |d| out.number(.depth, d.depth_m),
        .mwv => |w| {
            if (!w.valid or w.reference != .apparent) return out;
            out.number(.wind_speed_apparent, w.speed_mps);
            out.number(.wind_angle_apparent, w.angle_deg);
        },
        .mwd => |w| out.number(.wind_direction_true, w.direction_true),
        .vhw => |v| out.number(.heading_true, v.heading_true),
        .mtw => |m| out.number(.water_temperature, m.temp_k),
        .vlw => |v| {
            out.number(.log_total, v.total_m);
            out.number(.log_trip, v.trip_m);
        },
        .xdr => |x| {
            out.number(.attitude_roll, x.degrees(xdr_heel));
            out.number(.attitude_pitch, x.degrees(xdr_trim));
            out.number(.rudder_angle, x.degrees(xdr_rudder));
        },
        .vdm => {},
    }
    return out;
}

/// The XDR transducer names read here. The standard fixes the type and unit
/// letters and leaves the name to the device, so these are the spellings the
/// instruments seen so far use, matched exactly and never by position in the
/// list.
const xdr_heel = "HEEL";
const xdr_trim = "TRIM";
const xdr_rudder = "RUDDER";

/// One AIS target, in the units `ais_upsert` takes. A null field is one the
/// message did not carry; the host merges, so it is not overwritten.
pub const TargetFields = struct {
    mmsi: u32,
    lat: ?f64 = null,
    lon: ?f64 = null,
    /// Metres per second, converted from the knots the wire format carries.
    sog_mps: ?f64 = null,
    cog: ?f64 = null,
    heading: ?f64 = null,
    /// Points into the scratch buffer `parser.decode` was given.
    name: ?[]const u8 = null,
    /// Set by a type 21 report: this station is an aid to navigation.
    aton: bool = false,
    aton_type: ?u8 = null,
    virtual_aton: bool = false,
    off_position: ?bool = null,
};

/// The target a decoded AIS message updates, or null when it carries nothing
/// worth an upsert — a type 24 part B, which holds only a callsign and
/// dimensions, or a message from MMSI 0.
///
/// A position report with every field on its "not available" sentinel still
/// returns a target: the MMSI was heard, and refreshing its timestamp is what
/// keeps a station that is transmitting from ageing out of the store.
pub fn fromAis(msg: parser.AisMessage) ?TargetFields {
    switch (msg) {
        .position => |p| {
            if (p.mmsi == 0) return null;
            return .{
                .mmsi = p.mmsi,
                .lat = p.lat,
                .lon = p.lon,
                .sog_mps = if (p.sog_kn) |kn| kn * knot_mps else null,
                .cog = p.cog_deg,
                .heading = p.heading_deg,
            };
        },
        .static => |st| {
            if (st.mmsi == 0 or st.name.len == 0) return null;
            return .{ .mmsi = st.mmsi, .name = st.name };
        },
        .aton => |a| {
            if (a.mmsi == 0) return null;
            return .{
                .mmsi = a.mmsi,
                .lat = a.lat,
                .lon = a.lon,
                .name = if (a.name.len == 0) null else a.name,
                .aton = true,
                .aton_type = a.aid_type,
                .virtual_aton = a.virtual_aid,
                .off_position = a.off_position,
            };
        },
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const fx = @import("fixtures.zig");
const testing = std.testing;

fn only(s: parser.Sentence) Updates {
    return fromSentence(s);
}

fn find(u: Updates, path: Path) ?Value {
    for (u.slice()) |x| {
        if (x.path == path) return x.value;
    }
    return null;
}

fn expectNumber(u: Updates, path: Path, expected: f64, eps: f64) !void {
    const v = find(u, path) orelse return error.PathMissing;
    try testing.expect(v == .number);
    try testing.expectApproxEqAbs(expected, v.number, eps);
}

test "path text matches the frozen names" {
    try testing.expectEqualStrings("navigation.position", Path.position.text());
    try testing.expectEqualStrings("navigation.headingTrue", Path.heading_true.text());
    try testing.expectEqualStrings("navigation.courseOverGroundTrue", Path.cog_true.text());
    try testing.expectEqualStrings("navigation.speedOverGround", Path.sog.text());
    try testing.expectEqualStrings("environment.depth.belowTransducer", Path.depth.text());
    try testing.expectEqualStrings("environment.wind.speedApparent", Path.wind_speed_apparent.text());
    try testing.expectEqualStrings("environment.wind.angleApparent", Path.wind_angle_apparent.text());
    try testing.expectEqualStrings("environment.wind.directionTrue", Path.wind_direction_true.text());
    try testing.expectEqualStrings("steering.rudderAngle", Path.rudder_angle.text());
    try testing.expectEqualStrings("navigation.attitude.roll", Path.attitude_roll.text());
    try testing.expectEqualStrings("navigation.attitude.pitch", Path.attitude_pitch.text());
    try testing.expectEqualStrings("environment.water.temperature", Path.water_temperature.text());
    try testing.expectEqualStrings("navigation.log", Path.log_total.text());
    try testing.expectEqualStrings("navigation.trip.log", Path.log_trip.text());
}

test "RMC yields position, speed over ground and course" {
    const u = only(try parser.parse(fx.rmc));
    try testing.expectEqual(@as(usize, 3), u.slice().len);
    const p = find(u, .position) orelse return error.PathMissing;
    try testing.expect(p == .position);
    try testing.expectApproxEqAbs(fx.rmc_expect.lat, p.position.lat, 1e-9);
    try testing.expectApproxEqAbs(fx.rmc_expect.lon, p.position.lon, 1e-9);
    try expectNumber(u, .sog, fx.rmc_expect.sog_mps, 1e-6);
    try expectNumber(u, .cog_true, fx.rmc_expect.cog_true, 1e-9);
}

test "an RMC with no fix publishes nothing" {
    const u = only(try parser.parse(fx.rmc_void));
    try testing.expectEqual(@as(usize, 0), u.slice().len);
}

test "GGA yields a position only while it has a fix" {
    const u = only(try parser.parse(fx.gga));
    try testing.expectEqual(@as(usize, 1), u.slice().len);
    const p = find(u, .position) orelse return error.PathMissing;
    try testing.expectApproxEqAbs(fx.gga_expect.lat, p.position.lat, 1e-9);
    try testing.expectApproxEqAbs(fx.gga_expect.lon, p.position.lon, 1e-9);

    const nofix = only(try parser.parse(fx.gga_nofix));
    try testing.expectEqual(@as(usize, 0), nofix.slice().len);
}

test "VTG yields speed and course, in m/s" {
    const u = only(try parser.parse(fx.vtg));
    try testing.expectEqual(@as(usize, 2), u.slice().len);
    try expectNumber(u, .sog, fx.vtg_expect_sog_mps, 1e-6);
    try expectNumber(u, .cog_true, 54.7, 1e-9);
}

test "HDT and HDG yield a true heading, HDG only with a variation" {
    try expectNumber(only(try parser.parse(fx.hdt)), .heading_true, 274.07, 1e-9);
    try expectNumber(only(try parser.parse(fx.hdg)), .heading_true, 94.0, 1e-9);
    try testing.expectEqual(@as(usize, 0), only(try parser.parse(fx.hdg_novar)).slice().len);
}

test "DPT and DBT yield depth below the transducer" {
    try expectNumber(only(try parser.parse(fx.dpt)), .depth, 4.1, 1e-9);
    try expectNumber(only(try parser.parse(fx.dbt)), .depth, 5.3, 1e-9);
}

test "MWV yields apparent wind, signed to starboard; true reference is dropped" {
    const u = only(try parser.parse(fx.mwv_apparent));
    try testing.expectEqual(@as(usize, 2), u.slice().len);
    try expectNumber(u, .wind_speed_apparent, 0.1 * 1000.0 / 3600.0, 1e-9);
    try expectNumber(u, .wind_angle_apparent, -145.2, 1e-9);
    try testing.expectEqual(@as(usize, 0), only(try parser.parse(fx.mwv_true)).slice().len);
}

test "MWD yields the true wind direction" {
    const u = only(try parser.parse(fx.mwd));
    try testing.expectEqual(@as(usize, 1), u.slice().len);
    try expectNumber(u, .wind_direction_true, 220.0, 1e-9);
}

test "VHW yields a true heading" {
    try expectNumber(only(try parser.parse(fx.vhw)), .heading_true, 274.0, 1e-9);
}

test "XDR yields heel and trim as attitude, and the rudder angle, in degrees" {
    const u = only(try parser.parse(fx.xdr));
    try testing.expectEqual(@as(usize, 3), u.slice().len);
    try expectNumber(u, .attitude_roll, fx.xdr_expect.heel_deg, 1e-9);
    try expectNumber(u, .attitude_pitch, fx.xdr_expect.trim_deg, 1e-9);
    try expectNumber(u, .rudder_angle, fx.xdr_expect.rudder_deg, 1e-9);

    // The same names in another order publish the same paths, and a
    // transducer with no path of its own publishes nothing.
    const r = only(try parser.parse(fx.xdr_reordered));
    try testing.expectEqual(@as(usize, 2), r.slice().len);
    try expectNumber(r, .attitude_roll, 12.0, 1e-9);
    try expectNumber(r, .rudder_angle, -4.2, 1e-9);

    // A reading in radians is not published as degrees.
    try testing.expectEqual(@as(usize, 0), only(try parser.parse(fx.xdr_wrong_unit)).slice().len);
}

test "MTW yields water temperature in kelvin" {
    const u = only(try parser.parse(fx.mtw));
    try testing.expectEqual(@as(usize, 1), u.slice().len);
    try expectNumber(u, .water_temperature, fx.mtw_expect_k, 1e-9);
}

test "VLW yields the log and the trip in metres" {
    const u = only(try parser.parse(fx.vlw));
    try testing.expectEqual(@as(usize, 2), u.slice().len);
    try expectNumber(u, .log_total, fx.vlw_expect.total_m, 1e-6);
    try expectNumber(u, .log_trip, fx.vlw_expect.trip_m, 1e-6);
}

test "an AIVDM sentence yields no vessel paths" {
    try testing.expectEqual(@as(usize, 0), only(try parser.parse(fx.aivdm_type1)).slice().len);
}

fn decodeOne(line: []const u8, text: []u8) !parser.AisMessage {
    const v = (try parser.parse(line)).vdm;
    var a = parser.Assembler{};
    const assembled = a.push(v) orelse return error.Incomplete;
    return parser.decode(assembled.payload, assembled.fill, text);
}

test "an AIS position report becomes a target with speed in m/s" {
    var text: [parser.text_scratch_bytes]u8 = undefined;
    const t = fromAis(try decodeOne(fx.aivdm_type1, &text)) orelse return error.NoTarget;
    try testing.expectEqual(fx.aivdm_type1_expect.mmsi, t.mmsi);
    try testing.expectApproxEqAbs(fx.aivdm_type1_expect.lat, t.lat.?, 1e-6);
    try testing.expectApproxEqAbs(fx.aivdm_type1_expect.lon, t.lon.?, 1e-6);
    try testing.expectApproxEqAbs(0.0, t.sog_mps.?, 1e-9);
    try testing.expectApproxEqAbs(fx.aivdm_type1_expect.cog_deg, t.cog.?, 1e-9);
    try testing.expectApproxEqAbs(fx.aivdm_type1_expect.heading_deg, t.heading.?, 1e-9);
    try testing.expect(t.name == null);

    const b = fromAis(try decodeOne(fx.aivdm_type18, &text)) orelse return error.NoTarget;
    try testing.expectEqual(fx.aivdm_type18_expect.mmsi, b.mmsi);
    try testing.expectApproxEqAbs(fx.aivdm_type18_expect.sog_kn * knot_mps, b.sog_mps.?, 1e-9);
    try testing.expectApproxEqAbs(fx.aivdm_type18_expect.cog_deg, b.cog.?, 1e-9);
}

test "a position report of pure sentinels still refreshes its MMSI" {
    var text: [parser.text_scratch_bytes]u8 = undefined;
    const t = fromAis(try decodeOne(fx.aivdm_sentinels, &text)) orelse return error.NoTarget;
    try testing.expect(t.lat == null);
    try testing.expect(t.lon == null);
    try testing.expect(t.sog_mps == null);
    try testing.expect(t.cog == null);
    try testing.expect(t.heading == null);
}

test "a two-fragment type 5 becomes a name" {
    var a = parser.Assembler{};
    try testing.expect(a.push((try parser.parse(fx.aivdm_type5_a)).vdm) == null);
    const done = a.push((try parser.parse(fx.aivdm_type5_b)).vdm) orelse return error.Incomplete;
    var text: [parser.text_scratch_bytes]u8 = undefined;
    const t = fromAis(try parser.decode(done.payload, done.fill, &text)) orelse return error.NoTarget;
    try testing.expectEqual(fx.aivdm_type5_expect.mmsi, t.mmsi);
    try testing.expectEqualStrings(fx.aivdm_type5_expect.name, t.name.?);
    try testing.expect(t.lat == null);
}

test "a type 5 whose fragments disagree about the message id becomes a name" {
    var a = parser.Assembler{};
    try testing.expect(a.push((try parser.parse(fx.zeus_type5_a)).vdm) == null);
    const done = a.push((try parser.parse(fx.zeus_type5_b)).vdm) orelse return error.Incomplete;
    var text: [parser.text_scratch_bytes]u8 = undefined;
    const t = fromAis(try parser.decode(done.payload, done.fill, &text)) orelse return error.NoTarget;
    try testing.expectEqual(fx.zeus_type5_expect.mmsi, t.mmsi);
    try testing.expectEqualStrings(fx.zeus_type5_expect.name, t.name.?);
}

test "a type 21 becomes an AtoN target with its flags" {
    var text: [parser.text_scratch_bytes]u8 = undefined;
    const v = fromAis(try decodeOne(fx.aivdm_type21_virtual, &text)) orelse return error.NoTarget;
    try testing.expectEqual(fx.aivdm_type21_virtual_expect.mmsi, v.mmsi);
    try testing.expectEqualStrings(fx.aivdm_type21_virtual_expect.name, v.name.?);
    try testing.expectApproxEqAbs(fx.aivdm_type21_virtual_expect.lat, v.lat.?, 1e-7);
    try testing.expect(v.aton);
    try testing.expect(v.virtual_aton);
    try testing.expectEqual(@as(u8, 28), v.aton_type.?);
    try testing.expect(!v.off_position.?);
    // An aid has no way of moving, so it publishes no speed or course.
    try testing.expect(v.sog_mps == null);
    try testing.expect(v.cog == null);
    try testing.expect(v.heading == null);

    const o = fromAis(try decodeOne(fx.aivdm_type21_offpos, &text)) orelse return error.NoTarget;
    try testing.expect(o.aton);
    try testing.expect(!o.virtual_aton);
    try testing.expect(o.off_position.?);
}

test "type 24 part A is a name, part B nothing to upsert" {
    var text: [parser.text_scratch_bytes]u8 = undefined;
    const t = fromAis(try decodeOne(fx.aivdm_type24a, &text)) orelse return error.NoTarget;
    try testing.expectEqual(fx.aivdm_type24_expect.mmsi, t.mmsi);
    try testing.expectEqualStrings(fx.aivdm_type24_expect.name, t.name.?);
    try testing.expect(fromAis(try decodeOne(fx.aivdm_type24b, &text)) == null);
}
