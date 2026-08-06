//! The synthetic Annapolis NMEA 0183 log the plugin harness replays.
//!
//!   zig run tools/nmea_gen.zig -- test/annapolis.nmea
//!
//! 600 seconds at 1 Hz. Own ship sails a gentle S curve at 5 kn out of
//! Annapolis harbour, reporting RMC, HDT, MWD and DPT every second. Three
//! AIS targets share the water, and between them they exercise all three
//! sides of the ais plugin's alarm gate (CPA < 926 m, 0 < TCPA < 600 s):
//!
//!   A  closes on a 300° track at 8 kn toward a CPA near 300 m that falls at
//!      t = 655 s — BEYOND the end of the log. Its TCPA therefore starts
//!      above the gate's 600 s limit and crosses under it at t ≈ 45 s, so the
//!      alarm fires mid-replay rather than on the first fix, and the target
//!      stays inside the gate from the t = 50 s report to the end.
//!   B  lies anchored 1.4 km NNW of the start, well over a kilometre abeam of
//!      own ship's track: it never comes within 1249 m of any course own ship
//!      steers, so it never gates. Names itself with a two-part type 5.
//!   C  is a class B (type 18 with a type 24 A/B pair) leaving to the
//!      south-east from a position already astern: its TCPA is negative from
//!      t = 0, the "closest approach already happened" case.
//!
//! Two aids to navigation report type 21 every three minutes: a real starboard
//! hand buoy whose name runs into the name extension, and a virtual isolated
//! danger with nothing in the water behind it.
//!
//! Everything here is deterministic — no clock, no randomness — so two runs
//! produce identical bytes and a golden test can diff them.
//!
//! `tools/nmea0183` and `tools/ais` are symlinks to the plugin directories:
//! `zig run` refuses an `@import` that escapes the root file's directory, and
//! this file has to share the parser's armoring and 6-bit text tables, and the
//! ais plugin's CPA solver, or the scene could be verified against different
//! arithmetic from the one the alarm runs on.

const std = @import("std");
const p = @import("nmea0183/parser.zig");
const cpa = @import("ais/cpa.zig");

// ---------------------------------------------------------------------------
// The scene
// ---------------------------------------------------------------------------

pub const origin_lon = -76.4767;
pub const origin_lat = 38.9763;
pub const duration_s = 600;

/// 2026-08-05 14:00:00 UTC, the instant the log starts.
const start_hour = 14;
const date_ddmmyy = "050826";
/// Magnetic variation off Annapolis, west negative.
const variation_deg = -11.0;

const knot_mps = 1852.0 / 3600.0;
const deg = std.math.pi / 180.0;

/// A local east/north plane anchored at the origin. The chart work happens
/// in degrees, but a straight line and a constant speed are only simple in
/// metres, so the scene is built here and converted once.
const m_per_deg_lat = 111132.0;
const m_per_deg_lon = m_per_deg_lat * @cos(origin_lat * deg);

const Vec = struct {
    x: f64 = 0,
    y: f64 = 0,

    fn add(a: Vec, b: Vec) Vec {
        return .{ .x = a.x + b.x, .y = a.y + b.y };
    }

    fn sub(a: Vec, b: Vec) Vec {
        return .{ .x = a.x - b.x, .y = a.y - b.y };
    }

    fn scale(a: Vec, k: f64) Vec {
        return .{ .x = a.x * k, .y = a.y * k };
    }

    fn len(a: Vec) f64 {
        return @sqrt(a.x * a.x + a.y * a.y);
    }

    fn lon(a: Vec) f64 {
        return origin_lon + a.x / m_per_deg_lon;
    }

    fn lat(a: Vec) f64 {
        return origin_lat + a.y / m_per_deg_lat;
    }
};

/// A course in degrees and a speed in knots as an east/north velocity.
fn velocity(course_deg: f64, speed_kn: f64) Vec {
    const s = speed_kn * knot_mps;
    return .{ .x = s * @sin(course_deg * deg), .y = s * @cos(course_deg * deg) };
}

const own_speed_kn = 5.0;

/// The S curve: the course made good swings 20° either side of 075° once over
/// the run, which turns the track without ever losing steerage. 075 takes her
/// out of the harbour and into open water, where the symbols the harness draws
/// are not competing with the chart's own labels.
///
/// The period is longer than the log because own ship's course is one half of
/// every CPA the plugin computes. A course that swings quickly makes the
/// solver's answer swing with it — CPA and TCPA are extrapolations of the
/// course held right now — and the scene's designed numbers stop meaning
/// anything. At this rate the TCPA of a target 650 s away falls by about 1.2 s
/// per second, close enough to the straight-line 1 s that the gate crossing
/// lands where it was designed to.
fn ownCourse(t: f64) f64 {
    return 75.0 + 20.0 * @sin(2.0 * std.math.pi * t / 750.0);
}

/// How far own ship's head lies to the LEFT of the course she makes good: the
/// tide sets her to starboard and she carries a crab angle to hold the track.
///
/// Ten degrees is a normal set in this water, and it is also what makes HDT and
/// RMC's track made good two different numbers — without it the ownship
/// plugin's heading line and its COG vector are the same line drawn twice, and
/// a snapshot cannot show that both were drawn.
const own_crab_deg = 10.0;

/// What the compass reads: the course made good, less the crab angle.
fn ownHeading(t: f64) f64 {
    return ownCourse(t) - own_crab_deg;
}

/// True wind, backing slowly through the run.
fn windDirection(t: f64) f64 {
    return 220.0 + 5.0 * @sin(2.0 * std.math.pi * t / 600.0);
}

const wind_speed_kn = 12.0;

/// Depth under the transducer over a shoaling then deepening bottom.
fn depth(t: f64) f64 {
    return 9.0 + 4.0 * @sin(2.0 * std.math.pi * t / 240.0);
}

const transducer_offset_m = 0.30;

/// How far the own-ship track is integrated. Past the end of the log, because
/// target A's closest approach is laid out against a position own ship only
/// reaches after the log has stopped.
const track_s = 700;

/// Own ship's position at each whole second, integrated from the heading.
fn ownTrack() [track_s + 1]Vec {
    var track: [track_s + 1]Vec = undefined;
    track[0] = .{};
    var t: usize = 0;
    while (t < track_s) : (t += 1) {
        const v = velocity(ownCourse(@floatFromInt(t)), own_speed_kn);
        track[t + 1] = track[t].add(v);
    }
    return track;
}

const Target = struct {
    mmsi: u32,
    /// Position at t = 0.
    start: Vec,
    velocity: Vec,
    course_deg: f64,
    speed_kn: f64,
    heading_deg: ?f64,
    nav_status: u8,

    fn at(tg: Target, t: f64) Vec {
        return tg.start.add(tg.velocity.scale(t));
    }
};

/// When target A's closest approach falls. PAST THE END OF THE LOG on
/// purpose: a CPA inside the log puts the target under the gate's 600 s TCPA
/// limit from the very first fix, and the alarm the harness has to watch fire
/// would already have fired before the replay began. At 655 s the TCPA starts
/// at about 653 s, crosses 600 s at t ≈ 45 s, and the alarm lands on the
/// t = 50 s AIS report.
const cpa_time_s = 655.0;
const cpa_range_m = 300.0;

/// Target A closes on own ship's track from the north-east. Its line is placed
/// so that at `cpa_time_s` the range is `cpa_range_m` and the relative
/// velocity is perpendicular to it — that instant is the CPA of the
/// straight-line approximation, and own ship's slow turn moves the true
/// minimum only a little.
///
/// The offset is taken to the LEFT of the relative track (`perp` rotated the
/// other way from the obvious one): both sides give the same designed CPA, but
/// on this side own ship's turn and the target's approach bend the computed
/// CPA the same way, and it stays inside the 926 m gate for the whole run
/// instead of wandering out of it and re-arming the alarm.
fn targetA(track: []const Vec) Target {
    const course = 300.0;
    const speed = 8.0;
    const v = velocity(course, speed);
    const own_v = velocity(ownCourse(cpa_time_s), own_speed_kn);
    const rel = v.sub(own_v);
    const perp = Vec{ .x = -rel.y, .y = rel.x };
    const offset = perp.scale(cpa_range_m / perp.len());
    const at_cpa = track[@intFromFloat(cpa_time_s)].add(offset);
    return .{
        .mmsi = 367123450,
        .start = at_cpa.sub(v.scale(cpa_time_s)),
        .velocity = v,
        .course_deg = course,
        .speed_kn = speed,
        .heading_deg = course,
        .nav_status = 0,
    };
}

/// Target B: anchored 1.4 km north-north-west of the start, up the Severn,
/// swinging on her chain. Laid abeam of own ship's track rather than near it:
/// the closest any course own ship steers brings her is 1249 m, so she never
/// enters the gate however long the replay runs.
const target_b = Target{
    .mmsi = 366987650,
    .start = .{ .x = -400.0, .y = 1350.0 },
    .velocity = .{},
    .course_deg = 0.0,
    .speed_kn = 0.0,
    .heading_deg = 15.0,
    .nav_status = 1,
};

/// The two aids to navigation, in the open water own ship sails into. One is a
/// real buoy; the other is broadcast by a shore station and has nothing in the
/// water at all. Both report every `aton_period_s`, which is the rate a real
/// AtoN keeps.
///
/// The buoy's name runs past the 20-character field, so the round trip covers
/// the name extension. Both report ON position: an off-position aid raises a
/// warning alert, and the replay's alert count is what the phase gate reads.
const aton_physical = Aton{
    .mmsi = 993672315,
    .aid_type = 25, // starboard hand mark
    .name = "ANNAPOLIS CHANNEL BUOY 2",
    .at = .{ .x = 900.0, .y = -450.0 },
};

const aton_virtual = Aton{
    .mmsi = 993672099,
    .aid_type = 28, // isolated danger
    .name = "VIRTUAL WRECK MARK",
    // Abeam of the buoy, 250 m away, so one crop of the render holds both and
    // the difference between the two marks is a comparison, not a memory.
    .at = .{ .x = 1150.0, .y = -450.0 },
    .virtual_aid = true,
};

/// How often an aid to navigation transmits. Three minutes is the rate the
/// station keeps; the store evicts an AtoN at thirty.
const aton_period_s = 180;

/// Target C: a class B leaving to the south-east from a position already
/// astern of own ship. She opens from the first second, so her TCPA is
/// negative throughout — the case the gate must refuse however small the CPA
/// she passed at.
const target_c = Target{
    .mmsi = 338111222,
    .start = .{ .x = 500.0, .y = -600.0 },
    .velocity = velocity(135.0, 6.0),
    .course_deg = 135.0,
    .speed_kn = 6.0,
    .heading_deg = 135.0,
    .nav_status = 0,
};

// ---------------------------------------------------------------------------
// AIS encoding
// ---------------------------------------------------------------------------

/// Builds an AIS payload as 6-bit symbols, MSB first, using the parser's
/// armoring table so encode and decode cannot drift apart.
pub const Payload = struct {
    codes: [128]u6 = @splat(0),
    nbits: usize = 0,

    pub fn put(w: *Payload, value: u64, bits: usize) void {
        var k = bits;
        while (k > 0) {
            k -= 1;
            const bit: u64 = (value >> @intCast(k)) & 1;
            if (bit == 1) {
                const shift: u3 = @intCast(5 - (w.nbits % 6));
                w.codes[w.nbits / 6] |= @as(u6, 1) << shift;
            }
            w.nbits += 1;
        }
    }

    pub fn putSigned(w: *Payload, value: i64, bits: usize) void {
        const mask: u64 = (@as(u64, 1) << @intCast(bits)) - 1;
        w.put(@as(u64, @bitCast(value)) & mask, bits);
    }

    /// `chars` six-bit characters, `@`-padded to the fixed field width AIS
    /// text fields use.
    pub fn putText(w: *Payload, s: []const u8, chars: usize) void {
        var i: usize = 0;
        while (i < chars) : (i += 1) {
            const code: u6 = if (i < s.len) p.textCode(s[i]) else 0;
            w.put(code, 6);
        }
    }

    /// Coordinates travel in 1/10000 minute units.
    pub fn putLon(w: *Payload, v: f64) void {
        w.putSigned(@intFromFloat(@round(v * 600000.0)), 28);
    }

    pub fn putLat(w: *Payload, v: f64) void {
        w.putSigned(@intFromFloat(@round(v * 600000.0)), 27);
    }

    /// Bits the last armored character carries beyond the message.
    pub fn fill(w: Payload) u3 {
        return @intCast((6 - w.nbits % 6) % 6);
    }

    pub fn armored(w: Payload, out: []u8) []const u8 {
        const n = (w.nbits + 5) / 6;
        for (0..n) |i| out[i] = p.armor(w.codes[i]);
        return out[0..n];
    }
};

pub fn encodePosition(t: Target, pos: Vec, second: u8, class_b: bool) Payload {
    var w = Payload{};
    const sog: u64 = @intFromFloat(@round(t.speed_kn * 10.0));
    const cog: u64 = @intFromFloat(@round(t.course_deg * 10.0));
    const hdg: u64 = if (t.heading_deg) |h| @intFromFloat(@round(h)) else 511;
    if (class_b) {
        w.put(18, 6);
        w.put(0, 2); // repeat indicator
        w.put(t.mmsi, 30);
        w.put(0, 8); // regional reserved
        w.put(sog, 10);
        w.put(0, 1); // position accuracy
        w.putLon(pos.lon());
        w.putLat(pos.lat());
        w.put(cog, 12);
        w.put(hdg, 9);
        w.put(second, 6);
        w.put(0, 2); // regional reserved
        w.put(1, 1); // CS unit
        w.put(0, 1); // display
        w.put(0, 1); // DSC
        w.put(1, 1); // whole band
        w.put(1, 1); // accepts message 22
        w.put(0, 1); // assigned
        w.put(0, 1); // RAIM
        w.put(0, 20); // radio status
    } else {
        w.put(1, 6);
        w.put(0, 2); // repeat indicator
        w.put(t.mmsi, 30);
        w.put(t.nav_status, 4);
        w.put(128, 8); // rate of turn: not available
        w.put(sog, 10);
        w.put(0, 1); // position accuracy
        w.putLon(pos.lon());
        w.putLat(pos.lat());
        w.put(cog, 12);
        w.put(hdg, 9);
        w.put(second, 6);
        w.put(0, 2); // manoeuvre indicator
        w.put(0, 3); // spare
        w.put(0, 1); // RAIM
        w.put(0, 19); // radio status
    }
    return w;
}

pub const Ship = struct {
    imo: u32 = 0,
    callsign: []const u8 = "",
    name: []const u8 = "",
    ship_type: u8 = 0,
    to_bow: u16 = 0,
    to_stern: u16 = 0,
    to_port: u16 = 0,
    to_starboard: u16 = 0,
    draught_dm: u8 = 0,
    destination: []const u8 = "",
};

pub fn encodeStatic5(mmsi: u32, s: Ship) Payload {
    var w = Payload{};
    w.put(5, 6);
    w.put(0, 2); // repeat indicator
    w.put(mmsi, 30);
    w.put(0, 2); // AIS version
    w.put(s.imo, 30);
    w.putText(s.callsign, 7);
    w.putText(s.name, 20);
    w.put(s.ship_type, 8);
    w.put(s.to_bow, 9);
    w.put(s.to_stern, 9);
    w.put(s.to_port, 6);
    w.put(s.to_starboard, 6);
    w.put(1, 4); // EPFD: GPS
    w.put(8, 4); // ETA month
    w.put(6, 5); // ETA day
    w.put(18, 5); // ETA hour
    w.put(30, 6); // ETA minute
    w.put(s.draught_dm, 8);
    w.putText(s.destination, 20);
    w.put(0, 1); // DTE ready
    w.put(0, 1); // spare
    return w;
}

/// One aid to navigation, as type 21 carries it.
pub const Aton = struct {
    mmsi: u32,
    /// The navaid type code: 25 is a starboard hand mark, 28 an isolated
    /// danger.
    aid_type: u8,
    name: []const u8,
    /// Where it sits at t = 0. An AtoN does not move.
    at: Vec,
    virtual_aid: bool = false,
    off_position: bool = false,
    /// Metres from the reference point to bow, stern, port and starboard —
    /// the extent of the mark itself.
    size_m: u16 = 2,
};

/// A type 21 report. The fixed part is 272 bits; a name over 20 characters
/// puts the rest in the extension, padded with zero bits to an 8-bit boundary,
/// which is how the receiver deduces its length.
pub fn encodeAton(a: Aton, second: u8) Payload {
    var w = Payload{};
    w.put(21, 6);
    w.put(0, 2); // repeat indicator
    w.put(a.mmsi, 30);
    w.put(a.aid_type, 5);
    w.putText(a.name, 20);
    w.put(0, 1); // position accuracy
    w.putLon(a.at.lon());
    w.putLat(a.at.lat());
    w.put(a.size_m, 9); // to bow
    w.put(a.size_m, 9); // to stern
    w.put(a.size_m, 6); // to port
    w.put(a.size_m, 6); // to starboard
    w.put(1, 4); // EPFD: GPS
    w.put(second, 6);
    w.put(@intFromBool(a.off_position), 1);
    w.put(0, 8); // regional reserved
    w.put(0, 1); // RAIM
    w.put(@intFromBool(a.virtual_aid), 1);
    w.put(0, 1); // assigned mode
    w.put(0, 1); // spare
    if (a.name.len > 20) {
        var i: usize = 20;
        while (i < a.name.len) : (i += 1) w.put(p.textCode(a.name[i]), 6);
        while (w.nbits % 8 != 0) w.put(0, 1);
    }
    return w;
}

pub fn encodeStatic24A(mmsi: u32, name: []const u8) Payload {
    var w = Payload{};
    w.put(24, 6);
    w.put(0, 2);
    w.put(mmsi, 30);
    w.put(0, 2); // part A
    w.putText(name, 20);
    w.put(0, 8); // spare
    return w;
}

pub fn encodeStatic24B(mmsi: u32, s: Ship) Payload {
    var w = Payload{};
    w.put(24, 6);
    w.put(0, 2);
    w.put(mmsi, 30);
    w.put(1, 2); // part B
    w.put(s.ship_type, 8);
    w.putText("LKO", 3); // vendor id
    w.put(1, 4); // unit model code
    w.put(1234, 20); // serial number
    w.putText(s.callsign, 7);
    w.put(s.to_bow, 9);
    w.put(s.to_stern, 9);
    w.put(s.to_port, 6);
    w.put(s.to_starboard, 6);
    w.put(0, 6); // spare
    return w;
}

// ---------------------------------------------------------------------------
// Sentence emission
// ---------------------------------------------------------------------------

const Out = struct {
    alloc: std.mem.Allocator,
    buf: *std.ArrayList(u8),

    /// Appends one sentence: sentinel, body, `*hh`, CRLF.
    fn line(o: Out, sentinel: u8, comptime fmt: []const u8, args: anytype) !void {
        var body_buf: [256]u8 = undefined;
        const body = try std.fmt.bufPrint(&body_buf, fmt, args);
        try o.buf.print(o.alloc, "{c}{s}*{X:0>2}\r\n", .{ sentinel, body, p.checksum(body) });
    }
};

/// The `ddmm.mmmm` half of a position field.
const Coord = struct {
    deg: u32,
    min: f64,
    hemi: u8,

    fn latOf(v: f64) Coord {
        return of(v, 'N', 'S');
    }

    fn lonOf(v: f64) Coord {
        return of(v, 'E', 'W');
    }

    fn of(v: f64, pos: u8, neg: u8) Coord {
        const mag = @abs(v);
        const d: u32 = @intFromFloat(@floor(mag));
        return .{
            .deg = d,
            .min = (mag - @as(f64, @floatFromInt(d))) * 60.0,
            .hemi = if (v < 0) neg else pos,
        };
    }
};

/// Fragments a payload across AIVDM sentences. A sentence stays inside the
/// 82-character NMEA limit, so a payload is cut every 60 characters; only
/// the final fragment carries fill bits.
fn emitVdm(o: Out, w: Payload, channel: u8, msg_id: u8) !void {
    var armor_buf: [128]u8 = undefined;
    const armored = w.armored(&armor_buf);
    const per = 60;
    const frags: u8 = @intCast((armored.len + per - 1) / per);
    var i: u8 = 0;
    while (i < frags) : (i += 1) {
        const start = @as(usize, i) * per;
        const end = @min(start + per, armored.len);
        const last = i + 1 == frags;
        const fill: u3 = if (last) w.fill() else 0;
        if (frags == 1) {
            try o.line('!', "AIVDM,1,1,,{c},{s},{d}", .{ channel, armored[start..end], fill });
        } else {
            try o.line('!', "AIVDM,{d},{d},{d},{c},{s},{d}", .{
                frags,
                i + 1,
                msg_id,
                channel,
                armored[start..end],
                fill,
            });
        }
    }
}

/// Writes the whole log into `out`.
pub fn generate(alloc: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
    const o = Out{ .alloc = alloc, .buf = out };
    const track = ownTrack();
    const a = targetA(&track);
    const ship_b = Ship{
        .imo = 9271234,
        .callsign = "WDF2871",
        .name = "CHESAPEAKE BELLE",
        .ship_type = 37,
        .to_bow = 12,
        .to_stern = 6,
        .to_port = 3,
        .to_starboard = 3,
        .draught_dm = 21,
        .destination = "ANNAPOLIS",
    };
    const ship_c = Ship{
        .callsign = "WDG5512",
        .name = "SEA SPRITE",
        .ship_type = 37,
        .to_bow = 8,
        .to_stern = 4,
        .to_port = 2,
        .to_starboard = 2,
    };

    var msg_id: u8 = 0;
    var t: usize = 0;
    while (t <= duration_s) : (t += 1) {
        const tf: f64 = @floatFromInt(t);
        const pos = track[t];
        const cog = @mod(ownCourse(tf), 360.0);
        const hdg = @mod(ownHeading(tf), 360.0);
        const secs = start_hour * 3600 + t;
        const hh: u32 = @intCast((secs / 3600) % 24);
        const mm: u32 = @intCast((secs / 60) % 60);
        const ss: u32 = @intCast(secs % 60);
        const lat = Coord.latOf(pos.lat());
        const lon = Coord.lonOf(pos.lon());

        try o.line('$', "GPRMC,{d:0>2}{d:0>2}{d:0>2},A,{d:0>2}{d:0>7.4},{c},{d:0>3}{d:0>7.4},{c},{d:.1},{d:.1},{s},{d:.1},{c},A", .{
            hh,                  mm,                                           ss,
            lat.deg,             lat.min,                                      lat.hemi,
            lon.deg,             lon.min,                                      lon.hemi,
            own_speed_kn,        cog,                                          date_ddmmyy,
            @abs(variation_deg), @as(u8, if (variation_deg < 0) 'W' else 'E'),
        });
        try o.line('$', "HEHDT,{d:.1},T", .{hdg});
        const twd = windDirection(tf);
        try o.line('$', "WIMWD,{d:.1},T,{d:.1},M,{d:.1},N,{d:.1},M", .{
            twd,
            @mod(twd - variation_deg, 360.0),
            wind_speed_kn,
            wind_speed_kn * knot_mps,
        });
        try o.line('$', "SDDPT,{d:.1},{d:.2},", .{ depth(tf), transducer_offset_m });

        if (t % 10 == 0 and t < duration_s) {
            const second: u8 = @intCast(ss);
            try emitVdm(o, encodePosition(a, a.at(tf), second, false), 'A', 0);
            try emitVdm(o, encodePosition(target_b, target_b.at(tf), second, false), 'A', 0);
            try emitVdm(o, encodePosition(target_c, target_c.at(tf), second, true), 'B', 0);
        }
        if (t % aton_period_s == 0 and t < duration_s) {
            const second: u8 = @intCast(ss);
            try emitVdm(o, encodeAton(aton_physical, second), 'B', msg_id);
            msg_id = (msg_id + 1) % 10;
            try emitVdm(o, encodeAton(aton_virtual, second), 'B', 0);
        }
        if (t % 60 == 0 and t < duration_s) {
            try emitVdm(o, encodeStatic5(target_b.mmsi, ship_b), 'A', msg_id);
            msg_id = (msg_id + 1) % 10;
            try emitVdm(o, encodeStatic24A(target_c.mmsi, ship_c.name), 'B', 0);
            try emitVdm(o, encodeStatic24B(target_c.mmsi, ship_c), 'B', 0);
        }
    }
}

// ---------------------------------------------------------------------------
// What the alarm gate makes of the scene
// ---------------------------------------------------------------------------

/// How often each target transmits a position, and so how often the ais plugin
/// recomputes. Only these instants can raise or clear an alarm.
const ais_period_s = 10;

/// The ais plugin's danger gate, repeated here so the generator can say what
/// the log will do to it. The plugin owns the real numbers.
const gate_cpa_m: f64 = 926.0;
const gate_tcpa_s: f64 = 600.0;

/// Own ship as the plugin sees her at whole second `t`: the position it
/// integrated, the speed RMC reports, and the course RMC reports as track made
/// good, which for this scene is the heading.
fn ownState(track: []const Vec, t: usize) cpa.State {
    const pos = track[t];
    return .{
        .lat = pos.lat(),
        .lon = pos.lon(),
        .sog_mps = own_speed_kn * knot_mps,
        .cog_deg = @mod(ownCourse(@floatFromInt(t)), 360.0),
    };
}

fn targetState(tg: Target, t: usize) cpa.State {
    const pos = tg.at(@floatFromInt(t));
    return .{
        .lat = pos.lat(),
        .lon = pos.lon(),
        .sog_mps = tg.speed_kn * knot_mps,
        .cog_deg = tg.course_deg,
    };
}

/// What the gate does to one target across every report in the log.
const GateScan = struct {
    /// First and last report inside the gate, and whether every report between
    /// them was too — a gap would re-arm the alarm and raise a second one.
    first_s: ?usize = null,
    last_s: ?usize = null,
    contiguous: bool = true,
    min_cpa_m: f64 = std.math.inf(f64),
    max_cpa_m: f64 = 0,
    max_tcpa_s: f64 = -std.math.inf(f64),
    min_range_m: f64 = std.math.inf(f64),
};

fn scanGate(track: []const Vec, tg: Target) GateScan {
    var s = GateScan{};
    var gap_after_gate = false;
    var t: usize = 0;
    while (t <= duration_s) : (t += ais_period_s) {
        const sol = cpa.solve(ownState(track, t), targetState(tg, t));
        s.min_cpa_m = @min(s.min_cpa_m, sol.cpa_m);
        s.max_cpa_m = @max(s.max_cpa_m, sol.cpa_m);
        s.min_range_m = @min(s.min_range_m, sol.range_m);
        if (sol.tcpa_s) |tc| s.max_tcpa_s = @max(s.max_tcpa_s, tc);
        if (sol.dangerous(gate_cpa_m, gate_tcpa_s)) {
            if (s.first_s == null) s.first_s = t;
            if (gap_after_gate) s.contiguous = false;
            s.last_s = t;
        } else if (s.first_s != null) gap_after_gate = true;
    }
    return s;
}

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const path = if (args.len > 1) args[1] else "test/annapolis.nmea";

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    try generate(alloc, &out);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = path, .data = out.items });

    const track = ownTrack();
    var lines: usize = 0;
    for (out.items) |c| {
        if (c == '\n') lines += 1;
    }

    var buf: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buf);
    const w = &stdout.interface;
    try w.print("{s}: {d} lines, {d} bytes, {d} s at 1 Hz\n", .{ path, lines, out.items.len, duration_s });
    for ([_]struct { name: u8, tg: Target }{
        .{ .name = 'A', .tg = targetA(&track) },
        .{ .name = 'B', .tg = target_b },
        .{ .name = 'C', .tg = target_c },
    }) |e| {
        const s = scanGate(&track, e.tg);
        try w.print("  {c} {d}: ", .{ e.name, e.tg.mmsi });
        if (s.first_s) |first| {
            try w.print("in the alarm gate from t={d} s to t={d} s{s}", .{
                first,
                s.last_s.?,
                if (s.contiguous) "" else " WITH A GAP — the alarm would raise twice",
            });
        } else {
            try w.print("never in the alarm gate (max TCPA {d:.0} s)", .{s.max_tcpa_s});
        }
        try w.print("; CPA {d:.0}-{d:.0} m, closest range {d:.0} m\n", .{ s.min_cpa_m, s.max_cpa_m, s.min_range_m });
    }
    try w.flush();
}

// ---------------------------------------------------------------------------
// Round trip: what the generator wrote is what the parser reads back
// ---------------------------------------------------------------------------

const testing = std.testing;

test "the generated log parses back to the scene it was built from" {
    const alloc = testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    try generate(alloc, &out);

    var line_buf: [128]u8 = undefined;
    var feeder = p.Feeder.init(&line_buf);
    var assembler = p.Assembler{};
    var text: [p.text_scratch_bytes]u8 = undefined;

    const track = ownTrack();
    const a = targetA(&track);

    var rmc_count: usize = 0;
    var hdt_count: usize = 0;
    var mwd_count: usize = 0;
    var dpt_count: usize = 0;
    var last_own: ?p.Rmc = null;
    var seen_a: usize = 0;
    var seen_b: usize = 0;
    var seen_c: usize = 0;
    var seen_aton_physical: usize = 0;
    var seen_aton_virtual: usize = 0;
    var name_b: [32]u8 = undefined;
    var name_b_len: usize = 0;
    var name_c: [32]u8 = undefined;
    var name_c_len: usize = 0;
    var call_c: [16]u8 = undefined;
    var call_c_len: usize = 0;

    // The gate, recomputed from the DECODED log with the ais plugin's own
    // solver: what the alarm will do, not what the scene was designed to do.
    // `t` is the second the last RMC named, and every AIS sentence in the log
    // follows the RMC of its own second.
    var t_now: usize = 0;
    var own: ?cpa.State = null;
    var a_gate_first: ?usize = null;
    var a_gate_last: ?usize = null;
    var a_gate_count: usize = 0;
    var a_gate_gap = false;
    var checked_a100 = false;
    var checked_a410 = false;
    var checked_c0 = false;

    // Feed in 23-byte chunks: no line boundary lines up with a chunk edge.
    var at: usize = 0;
    while (at < out.items.len) {
        const end = @min(at + 23, out.items.len);
        var it = feeder.feed(out.items[at..end]);
        while (it.next()) |line| {
            const s = try p.parse(line);
            switch (s) {
                .rmc => |r| {
                    t_now = rmc_count;
                    rmc_count += 1;
                    last_own = r;
                    try testing.expect(r.valid);
                    own = .{
                        .lat = r.lat.?,
                        .lon = r.lon.?,
                        .sog_mps = r.sog_mps.?,
                        .cog_deg = r.cog_true.?,
                    };
                },
                .hdt => |h| {
                    hdt_count += 1;
                    try testing.expect(h.heading_true != null);
                },
                .mwd => |m| {
                    mwd_count += 1;
                    try testing.expectApproxEqAbs(
                        wind_speed_kn * knot_mps,
                        m.speed_mps.?,
                        0.06,
                    );
                },
                .dpt => |d| {
                    dpt_count += 1;
                    try testing.expect(d.depth_m.? > 4.0 and d.depth_m.? < 14.0);
                },
                .vdm => |v| {
                    const done = assembler.push(v) orelse continue;
                    switch (try p.decode(done.payload, done.fill, &text)) {
                        .position => |q| {
                            const sol = cpa.solve(own.?, .{
                                .lat = q.lat.?,
                                .lon = q.lon.?,
                                .sog_mps = q.sog_kn.? * knot_mps,
                                .cog_deg = q.cog_deg.?,
                            });
                            if (q.mmsi == a.mmsi) {
                                seen_a += 1;
                                try testing.expectApproxEqAbs(a.speed_kn, q.sog_kn.?, 0.05);
                                try testing.expectApproxEqAbs(a.course_deg, q.cog_deg.?, 0.05);

                                // The alarm edge: A must be OUTSIDE the gate on
                                // the first fix — its closest approach falls
                                // past the end of the log, so its TCPA starts
                                // over the 600 s limit — and inside it from
                                // t = 50 s on, without a gap that would raise a
                                // second alarm.
                                if (t_now == 0) {
                                    try testing.expect(sol.tcpa_s.? > gate_tcpa_s);
                                    try testing.expect(!sol.dangerous(gate_cpa_m, gate_tcpa_s));
                                }
                                if (sol.dangerous(gate_cpa_m, gate_tcpa_s)) {
                                    if (a_gate_first == null) a_gate_first = t_now;
                                    if (a_gate_last != null and t_now > a_gate_last.? + ais_period_s) a_gate_gap = true;
                                    a_gate_last = t_now;
                                    a_gate_count += 1;
                                } else if (a_gate_first != null) a_gate_gap = true;
                                if (t_now == 100 or t_now == 410) {
                                    try testing.expect(sol.cpa_m < gate_cpa_m);
                                    try testing.expect(sol.tcpa_s.? > 0 and sol.tcpa_s.? < gate_tcpa_s);
                                    if (t_now == 100) checked_a100 = true else checked_a410 = true;
                                }
                            } else if (q.mmsi == target_b.mmsi) {
                                seen_b += 1;
                                try testing.expectApproxEqAbs(0.0, q.sog_kn.?, 0.05);
                                try testing.expectEqual(@as(u8, 1), q.nav_status.?);
                                // Anchored a kilometre and more off the track:
                                // never inside the gate on distance alone.
                                try testing.expect(sol.cpa_m > gate_cpa_m);
                                try testing.expect(!sol.dangerous(gate_cpa_m, gate_tcpa_s));
                            } else if (q.mmsi == target_c.mmsi) {
                                seen_c += 1;
                                try testing.expect(q.class_b);
                                try testing.expectApproxEqAbs(target_c.speed_kn, q.sog_kn.?, 0.05);
                                // Diverging from the first second: the closest
                                // approach is always in the past.
                                try testing.expect(sol.tcpa_s.? < 0);
                                try testing.expect(!sol.dangerous(gate_cpa_m, gate_tcpa_s));
                                if (t_now == 0) checked_c0 = true;
                            } else {
                                try testing.expect(false);
                            }
                        },
                        .aton => |an| {
                            if (an.mmsi == aton_physical.mmsi) {
                                seen_aton_physical += 1;
                                try testing.expectEqualStrings(aton_physical.name, an.name);
                                try testing.expectEqual(aton_physical.aid_type, an.aid_type);
                                try testing.expect(!an.virtual_aid);
                                try testing.expect(!an.off_position.?);
                                try testing.expectApproxEqAbs(aton_physical.at.lat(), an.lat.?, 1e-5);
                                try testing.expectApproxEqAbs(aton_physical.at.lon(), an.lon.?, 1e-5);
                            } else if (an.mmsi == aton_virtual.mmsi) {
                                seen_aton_virtual += 1;
                                try testing.expectEqualStrings(aton_virtual.name, an.name);
                                try testing.expectEqual(aton_virtual.aid_type, an.aid_type);
                                try testing.expect(an.virtual_aid);
                                try testing.expect(!an.off_position.?);
                                try testing.expectApproxEqAbs(aton_virtual.at.lat(), an.lat.?, 1e-5);
                                try testing.expectApproxEqAbs(aton_virtual.at.lon(), an.lon.?, 1e-5);
                            } else {
                                try testing.expect(false);
                            }
                        },
                        .static => |st| {
                            if (st.msg_type == 5) {
                                try testing.expectEqual(target_b.mmsi, st.mmsi);
                                name_b_len = st.name.len;
                                @memcpy(name_b[0..name_b_len], st.name);
                                try testing.expectEqualStrings("ANNAPOLIS", st.destination);
                                try testing.expectEqual(@as(u32, 9271234), st.imo.?);
                            } else if (st.part.? == 0) {
                                name_c_len = st.name.len;
                                @memcpy(name_c[0..name_c_len], st.name);
                            } else {
                                call_c_len = st.callsign.len;
                                @memcpy(call_c[0..call_c_len], st.callsign);
                            }
                        },
                    }
                },
                else => {},
            }
        }
        at = end;
    }

    try testing.expectEqual(@as(usize, duration_s + 1), rmc_count);
    try testing.expectEqual(rmc_count, hdt_count);
    try testing.expectEqual(rmc_count, mwd_count);
    try testing.expectEqual(rmc_count, dpt_count);
    try testing.expectEqual(@as(usize, duration_s / 10), seen_a);
    try testing.expectEqual(@as(usize, duration_s / 10), seen_b);
    try testing.expectEqual(@as(usize, duration_s / 10), seen_c);
    // Every third minute, up to but not including the end of the log.
    const aton_reports = (duration_s + aton_period_s - 1) / aton_period_s;
    try testing.expectEqual(aton_reports, seen_aton_physical);
    try testing.expectEqual(aton_reports, seen_aton_virtual);
    try testing.expectEqual(@as(u64, 0), feeder.stats.bad_checksum);
    try testing.expectEqual(@as(u64, 0), feeder.stats.no_checksum);
    try testing.expectEqual(@as(u64, 0), feeder.stats.oversize);

    try testing.expectEqualStrings("CHESAPEAKE BELLE", name_b[0..name_b_len]);
    try testing.expectEqualStrings("SEA SPRITE", name_c[0..name_c_len]);
    try testing.expectEqualStrings("WDG5512", call_c[0..call_c_len]);

    // Own ship ends where the integrated track says, within the rounding
    // the 1/10000-minute position fields impose.
    const last = last_own.?;
    try testing.expectApproxEqAbs(track[duration_s].lat(), last.lat.?, 1e-4);
    try testing.expectApproxEqAbs(track[duration_s].lon(), last.lon.?, 1e-4);
    try testing.expectApproxEqAbs(own_speed_kn * knot_mps, last.sog_mps.?, 0.03);

    // The alarm the harness watches for: one, on target A, at the report where
    // its TCPA first falls under the gate's 600 s limit — and it holds from
    // there to the last report, so nothing re-arms it.
    try testing.expect(checked_a100 and checked_a410 and checked_c0);
    try testing.expectEqual(@as(?usize, 50), a_gate_first);
    try testing.expectEqual(@as(?usize, duration_s - ais_period_s), a_gate_last);
    try testing.expect(!a_gate_gap);
    try testing.expectEqual((duration_s - 50) / ais_period_s, a_gate_count);
}
