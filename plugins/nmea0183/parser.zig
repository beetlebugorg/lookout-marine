//! NMEA 0183 sentences and AIVDM/AIVDO messages, parsed without an allocator.
//!
//! The only import is `std`, and nothing here reaches the filesystem, the
//! network or the clock, so the file compiles unchanged for
//! wasm32-freestanding inside the plugin and natively for the tests below.
//! Every buffer belongs to the caller: the line reassembly buffer, the
//! multipart AIS buffers inside `Assembler`, and the scratch space AIS
//! strings decode into.
//!
//! Units leave this file in SI: speeds in m/s, depths in metres, angles in
//! degrees. Wind angle is signed with starboard positive. A field the
//! sentence left empty, or a value the standard reserves for "not
//! available", arrives as `null` rather than a sentinel number.

const std = @import("std");

pub const Error = error{
    /// The `*hh` suffix is missing or does not match the body.
    BadChecksum,
    /// The line is not a sentence, or a required field is unreadable.
    Malformed,
    /// A well-formed sentence or AIS message this parser does not decode.
    Unsupported,
    /// An armored payload contains a character outside the 6-bit alphabet.
    BadPayload,
    /// The payload ended before a field the message type requires.
    Truncated,
    /// The caller's scratch buffer is too small for the decoded strings.
    NoSpace,
};

const knot_mps = 1852.0 / 3600.0;
const kmh_mps = 1000.0 / 3600.0;
const mph_mps = 1609.344 / 3600.0;
const foot_m = 0.3048;
const fathom_m = 1.8288;

// ---------------------------------------------------------------------------
// Checksums and line framing
// ---------------------------------------------------------------------------

/// XOR of every byte in a sentence body — what follows `$`/`!` and precedes `*`.
pub fn checksum(body: []const u8) u8 {
    var x: u8 = 0;
    for (body) |c| x ^= c;
    return x;
}

fn hexDigit(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'A'...'F' => c - 'A' + 10,
        'a'...'f' => c - 'a' + 10,
        else => null,
    };
}

/// True when the line starts with `$` or `!` and carries a matching `*hh`.
/// A sentence without a checksum is rejected: the stream is a safety input
/// and an unverified line is indistinguishable from a corrupted one.
pub fn verify(line: []const u8) bool {
    if (line.len < 4) return false;
    if (line[0] != '$' and line[0] != '!') return false;
    const star = line.len - 3;
    if (line[star] != '*') return false;
    const hi = hexDigit(line[star + 1]) orelse return false;
    const lo = hexDigit(line[star + 2]) orelse return false;
    // A second '*' inside the body means the framing is wrong, not the sum.
    if (std.mem.indexOfScalar(u8, line[1..star], '*') != null) return false;
    return checksum(line[1..star]) == hi * 16 + lo;
}

/// Reassembles sentences from arbitrary byte chunks.
///
/// The caller owns the line buffer, which bounds the longest sentence the
/// feeder will emit; a longer line is discarded up to its terminator rather
/// than truncated, because a truncated sentence would fail the checksum
/// anyway and could split into two plausible-looking halves. Bytes before
/// the first `$`/`!` of a line are skipped, so a mid-sentence connect
/// resynchronises on the next line.
pub const Feeder = struct {
    buf: []u8,
    len: usize = 0,
    /// Set while the current line is over-long: bytes are dropped until the
    /// next terminator.
    dropping: bool = false,
    /// Set while `buf` holds a line already handed to the caller.
    ready: bool = false,
    stats: Stats = .{},

    pub const Stats = struct {
        /// Lines returned to the caller.
        lines: u64 = 0,
        bad_checksum: u64 = 0,
        no_checksum: u64 = 0,
        oversize: u64 = 0,
    };

    pub fn init(buf: []u8) Feeder {
        return .{ .buf = buf };
    }

    /// Iterates the complete, checksum-verified lines contained in `chunk`.
    /// A trailing partial line stays in the buffer for the next chunk.
    pub fn feed(self: *Feeder, chunk: []const u8) LineIter {
        return .{ .f = self, .rest = chunk };
    }

    pub const LineIter = struct {
        f: *Feeder,
        rest: []const u8,

        /// The returned slice points into the feeder's buffer and stays
        /// valid until the next call.
        pub fn next(it: *LineIter) ?[]const u8 {
            const f = it.f;
            if (f.ready) {
                f.ready = false;
                f.len = 0;
            }
            while (it.rest.len > 0) {
                const c = it.rest[0];
                it.rest = it.rest[1..];
                if (c == '\r' or c == '\n') {
                    const n = f.len;
                    const was_dropping = f.dropping;
                    f.dropping = false;
                    f.len = 0;
                    if (was_dropping or n == 0) continue;
                    const line = f.buf[0..n];
                    if (line.len < 4 or line[line.len - 3] != '*') {
                        f.stats.no_checksum += 1;
                        continue;
                    }
                    if (!verify(line)) {
                        f.stats.bad_checksum += 1;
                        continue;
                    }
                    f.stats.lines += 1;
                    f.ready = true;
                    f.len = n;
                    return line;
                }
                if (f.dropping) continue;
                // Resync: a line begins at its sentinel, never mid-field.
                if (f.len == 0 and c != '$' and c != '!') continue;
                if (f.len == f.buf.len) {
                    f.dropping = true;
                    f.len = 0;
                    f.stats.oversize += 1;
                    continue;
                }
                f.buf[f.len] = c;
                f.len += 1;
            }
            return null;
        }
    };
};

// ---------------------------------------------------------------------------
// Field access
// ---------------------------------------------------------------------------

const max_fields = 24;

const Split = struct {
    parts: [max_fields][]const u8 = undefined,
    n: usize = 0,

    fn init(body: []const u8) Split {
        var s = Split{};
        var start: usize = 0;
        var i: usize = 0;
        while (i <= body.len) : (i += 1) {
            if (i == body.len or body[i] == ',') {
                if (s.n == max_fields) break;
                s.parts[s.n] = body[start..i];
                s.n += 1;
                start = i + 1;
            }
        }
        return s;
    }

    /// An absent field reads as empty, which every accessor treats as null.
    fn get(s: Split, i: usize) []const u8 {
        return if (i < s.n) s.parts[i] else "";
    }
};

fn num(s: []const u8) ?f64 {
    if (s.len == 0) return null;
    return std.fmt.parseFloat(f64, s) catch null;
}

fn uint(comptime T: type, s: []const u8) ?T {
    if (s.len == 0) return null;
    return std.fmt.parseInt(T, s, 10) catch null;
}

/// `ddmm.mmmm` plus a hemisphere letter, in signed degrees.
fn latlon(v: []const u8, hemi: []const u8) ?f64 {
    if (v.len == 0 or hemi.len != 1) return null;
    const dot = std.mem.indexOfScalar(u8, v, '.') orelse v.len;
    if (dot < 3) return null;
    const deg = std.fmt.parseFloat(f64, v[0 .. dot - 2]) catch return null;
    const min = std.fmt.parseFloat(f64, v[dot - 2 ..]) catch return null;
    if (min < 0 or min >= 60) return null;
    const mag = deg + min / 60.0;
    return switch (hemi[0]) {
        'N', 'E' => mag,
        'S', 'W' => -mag,
        else => null,
    };
}

/// A signed magnitude from a value field and its E/W or L/R direction field.
/// East and right are positive.
fn signed(v: []const u8, dir: []const u8) ?f64 {
    const mag = num(v) orelse return null;
    if (dir.len != 1) return null;
    return switch (dir[0]) {
        'E', 'R' => mag,
        'W', 'L' => -mag,
        else => null,
    };
}

fn speedIn(v: []const u8, unit: []const u8) ?f64 {
    const s = num(v) orelse return null;
    if (unit.len != 1) return null;
    return switch (unit[0]) {
        'N' => s * knot_mps,
        'K' => s * kmh_mps,
        'M' => s,
        'S' => s * mph_mps,
        else => null,
    };
}

/// `hhmmss.ss`, optionally dated by an `RMC`-style `ddmmyy`.
pub const Utc = struct {
    hour: u8,
    minute: u8,
    second: f64,
    year: ?u16 = null,
    month: ?u8 = null,
    day: ?u8 = null,

    /// Milliseconds since the Unix epoch, or null when the sentence carried
    /// no date. Computed here rather than read from a clock so the parser
    /// stays free of the host.
    pub fn epochMs(u: Utc) ?i64 {
        const y = u.year orelse return null;
        const mo = u.month orelse return null;
        const d = u.day orelse return null;
        const days = daysFromCivil(y, mo, d);
        const secs = days * 86400 + @as(i64, u.hour) * 3600 + @as(i64, u.minute) * 60;
        return secs * 1000 + @as(i64, @intFromFloat(u.second * 1000.0));
    }
};

/// Days between 1970-01-01 and the given civil date (Howard Hinnant's
/// algorithm), valid for any proleptic Gregorian date.
fn daysFromCivil(year: u16, month: u8, day: u8) i64 {
    const y: i64 = @as(i64, year) - @intFromBool(month <= 2);
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const m: i64 = month;
    const mp = if (m > 2) m - 3 else m + 9;
    const doy = @divTrunc(153 * mp + 2, 5) + @as(i64, day) - 1;
    const doe = yoe * 365 + @divTrunc(yoe, 4) - @divTrunc(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

fn timeOfDay(s: []const u8) ?Utc {
    if (s.len < 6) return null;
    const h = uint(u8, s[0..2]) orelse return null;
    const mi = uint(u8, s[2..4]) orelse return null;
    const sec = std.fmt.parseFloat(f64, s[4..]) catch return null;
    if (h > 23 or mi > 59 or sec < 0 or sec >= 61) return null;
    return .{ .hour = h, .minute = mi, .second = sec };
}

/// `ddmmyy`; two-digit years below 80 are this century, the rest the last.
fn dated(t: ?Utc, s: []const u8) ?Utc {
    var u = t orelse return null;
    if (s.len != 6) return u;
    const d = uint(u8, s[0..2]) orelse return u;
    const mo = uint(u8, s[2..4]) orelse return u;
    const yy = uint(u8, s[4..6]) orelse return u;
    if (d < 1 or d > 31 or mo < 1 or mo > 12) return u;
    u.day = d;
    u.month = mo;
    u.year = if (yy < 80) 2000 + @as(u16, yy) else 1900 + @as(u16, yy);
    return u;
}

// ---------------------------------------------------------------------------
// Sentences
// ---------------------------------------------------------------------------

pub const Rmc = struct {
    /// `A` — the receiver reports the fix as valid.
    valid: bool,
    utc: ?Utc,
    lat: ?f64,
    lon: ?f64,
    sog_mps: ?f64,
    cog_true: ?f64,
    /// Magnetic variation, east positive.
    variation: ?f64,
};

pub const Gga = struct {
    utc: ?Utc,
    lat: ?f64,
    lon: ?f64,
    /// 0 no fix, 1 GPS, 2 differential, 4/5 RTK, 6 dead reckoning.
    quality: u8,
    satellites: ?u8,
    hdop: ?f64,
    /// Antenna height above mean sea level.
    altitude_m: ?f64,
    geoid_sep_m: ?f64,
};

pub const Vtg = struct {
    cog_true: ?f64,
    cog_mag: ?f64,
    sog_mps: ?f64,
};

pub const Hdt = struct {
    heading_true: ?f64,
};

pub const Hdg = struct {
    /// The compass reading before deviation and variation are applied.
    sensor_mag: ?f64,
    /// Deviation, east positive.
    deviation: ?f64,
    /// Variation, east positive.
    variation: ?f64,
    /// Sensor plus deviation.
    heading_mag: ?f64,
    /// Sensor plus deviation plus variation; null when variation is absent.
    heading_true: ?f64,
};

pub const Dpt = struct {
    /// Depth below the transducer.
    depth_m: ?f64,
    /// Transducer offset: positive to the waterline, negative to the keel.
    offset_m: ?f64,
    range_m: ?f64,
};

pub const Dbt = struct {
    /// Depth below the transducer, from whichever unit the sentence carried.
    depth_m: ?f64,
};

pub const WindRef = enum { apparent, true_wind };

pub const Mwv = struct {
    /// Signed against the bow: starboard positive, port negative.
    angle_deg: ?f64,
    reference: WindRef,
    speed_mps: ?f64,
    /// `A` — the sensor reports the reading as valid.
    valid: bool,
};

pub const Mwd = struct {
    /// The direction the wind blows FROM, true.
    direction_true: ?f64,
    direction_mag: ?f64,
    speed_mps: ?f64,
};

pub const Vhw = struct {
    heading_true: ?f64,
    heading_mag: ?f64,
    /// Speed through the water.
    stw_mps: ?f64,
};

/// One AIVDM/AIVDO sentence: still armored, possibly one fragment of many.
pub const Vdm = struct {
    fragments: u8,
    index: u8,
    /// The sequential message id that ties fragments together; absent on
    /// single-fragment messages.
    msg_id: ?u8,
    /// `A`, `B`, or 0 when the sentence left the channel empty.
    channel: u8,
    /// Armored 6-bit payload, pointing into the caller's line.
    payload: []const u8,
    /// Bits to ignore at the end of the payload.
    fill: u3,
    /// True for AIVDO — the receiver's own transmission.
    own: bool,
};

pub const Sentence = union(enum) {
    rmc: Rmc,
    gga: Gga,
    vtg: Vtg,
    hdt: Hdt,
    hdg: Hdg,
    dpt: Dpt,
    dbt: Dbt,
    mwv: Mwv,
    mwd: Mwd,
    vhw: Vhw,
    vdm: Vdm,
};

/// Parses one complete line, including its `*hh`. Slices in the result point
/// into `line`. The checksum is re-verified here so `parse` is safe on lines
/// that did not come from `Feeder`.
pub fn parse(line: []const u8) Error!Sentence {
    if (line.len < 6) return error.Malformed;
    if (line[0] != '$' and line[0] != '!') return error.Malformed;
    if (!verify(line)) return error.BadChecksum;
    const body = line[1 .. line.len - 3];
    const f = Split.init(body);
    const addr = f.get(0);
    // A talker sentence addresses as two talker letters plus three type
    // letters; anything else (a proprietary `$P...`, a query) is not ours.
    if (addr.len != 5) return error.Unsupported;
    const kind = addr[2..5];

    if (eq(kind, "RMC")) return .{ .rmc = .{
        .valid = eq(f.get(2), "A"),
        .utc = dated(timeOfDay(f.get(1)), f.get(9)),
        .lat = latlon(f.get(3), f.get(4)),
        .lon = latlon(f.get(5), f.get(6)),
        .sog_mps = if (num(f.get(7))) |k| k * knot_mps else null,
        .cog_true = num(f.get(8)),
        .variation = signed(f.get(10), f.get(11)),
    } };

    if (eq(kind, "GGA")) return .{ .gga = .{
        .utc = timeOfDay(f.get(1)),
        .lat = latlon(f.get(2), f.get(3)),
        .lon = latlon(f.get(4), f.get(5)),
        .quality = uint(u8, f.get(6)) orelse 0,
        .satellites = uint(u8, f.get(7)),
        .hdop = num(f.get(8)),
        .altitude_m = if (eq(f.get(10), "M")) num(f.get(9)) else null,
        .geoid_sep_m = if (eq(f.get(12), "M")) num(f.get(11)) else null,
    } };

    if (eq(kind, "VTG")) return .{ .vtg = .{
        .cog_true = if (eq(f.get(2), "T")) num(f.get(1)) else null,
        .cog_mag = if (eq(f.get(4), "M")) num(f.get(3)) else null,
        .sog_mps = speedIn(f.get(5), f.get(6)) orelse speedIn(f.get(7), f.get(8)),
    } };

    if (eq(kind, "HDT")) return .{ .hdt = .{
        .heading_true = if (eq(f.get(2), "T")) num(f.get(1)) else null,
    } };

    if (eq(kind, "HDG")) {
        const sensor = num(f.get(1));
        const dev = signed(f.get(2), f.get(3));
        const vari = signed(f.get(4), f.get(5));
        const mag = if (sensor) |s| s + (dev orelse 0) else null;
        return .{ .hdg = .{
            .sensor_mag = sensor,
            .deviation = dev,
            .variation = vari,
            .heading_mag = mag,
            .heading_true = if (mag != null and vari != null) norm360(mag.? + vari.?) else null,
        } };
    }

    if (eq(kind, "DPT")) return .{ .dpt = .{
        .depth_m = num(f.get(1)),
        .offset_m = num(f.get(2)),
        .range_m = num(f.get(3)),
    } };

    if (eq(kind, "DBT")) {
        var depth = if (eq(f.get(4), "M")) num(f.get(3)) else null;
        if (depth == null and eq(f.get(2), "f")) {
            if (num(f.get(1))) |ft| depth = ft * foot_m;
        }
        if (depth == null and eq(f.get(6), "F")) {
            if (num(f.get(5))) |fa| depth = fa * fathom_m;
        }
        return .{ .dbt = .{ .depth_m = depth } };
    }

    if (eq(kind, "MWV")) {
        const raw = num(f.get(1));
        return .{ .mwv = .{
            .angle_deg = if (raw) |a| signedAngle(a) else null,
            .reference = if (eq(f.get(2), "T")) .true_wind else .apparent,
            .speed_mps = speedIn(f.get(3), f.get(4)),
            .valid = eq(f.get(5), "A"),
        } };
    }

    if (eq(kind, "MWD")) return .{ .mwd = .{
        .direction_true = if (eq(f.get(2), "T")) num(f.get(1)) else null,
        .direction_mag = if (eq(f.get(4), "M")) num(f.get(3)) else null,
        .speed_mps = speedIn(f.get(5), f.get(6)) orelse speedIn(f.get(7), f.get(8)),
    } };

    if (eq(kind, "VHW")) return .{ .vhw = .{
        .heading_true = if (eq(f.get(2), "T")) num(f.get(1)) else null,
        .heading_mag = if (eq(f.get(4), "M")) num(f.get(3)) else null,
        .stw_mps = speedIn(f.get(5), f.get(6)) orelse speedIn(f.get(7), f.get(8)),
    } };

    if (eq(kind, "VDM") or eq(kind, "VDO")) {
        if (f.n < 7) return error.Malformed;
        const frags = uint(u8, f.get(1)) orelse return error.Malformed;
        const index = uint(u8, f.get(2)) orelse return error.Malformed;
        const fill_raw = uint(u8, f.get(6)) orelse return error.Malformed;
        if (frags == 0 or index == 0 or index > frags or fill_raw > 5) return error.Malformed;
        const payload = f.get(5);
        if (payload.len == 0) return error.Malformed;
        const chan = f.get(4);
        return .{ .vdm = .{
            .fragments = frags,
            .index = index,
            .msg_id = uint(u8, f.get(3)),
            .channel = if (chan.len == 1) chan[0] else 0,
            .payload = payload,
            .fill = @intCast(fill_raw),
            .own = eq(kind, "VDO"),
        } };
    }

    return error.Unsupported;
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn norm360(d: f64) f64 {
    var v = @mod(d, 360.0);
    if (v < 0) v += 360.0;
    return v;
}

/// 0..360 relative to the bow becomes -180..180 with starboard positive.
fn signedAngle(d: f64) f64 {
    const v = norm360(d);
    return if (v > 180.0) v - 360.0 else v;
}

// ---------------------------------------------------------------------------
// AIS: armoring, reassembly, payload decode
// ---------------------------------------------------------------------------

/// One armored character back to its 6 bits, or null when the character is
/// outside the alphabet ITU-R M.1371 permits.
pub fn sixbit(c: u8) ?u6 {
    if (c < 48 or c > 119) return null;
    if (c > 87 and c < 96) return null;
    const v: u8 = if (c > 87) c - 56 else c - 48;
    return @intCast(v);
}

/// 6 bits back to the armored character an AIVDM payload carries.
pub fn armor(v: u6) u8 {
    const n: u8 = v;
    return if (n > 39) n + 56 else n + 48;
}

/// The 6-bit text alphabet: index is the code, value the ASCII character.
pub const text_alphabet: [64]u8 = "@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_ !\"#$%&'()*+,-./0123456789:;<=>?".*;

/// An ASCII character as its 6-bit text code; anything unrepresentable
/// becomes `@`, which readers treat as padding.
pub fn textCode(c: u8) u6 {
    const up = if (c >= 'a' and c <= 'z') c - 32 else c;
    for (text_alphabet, 0..) |t, i| {
        if (t == up) return @intCast(i);
    }
    return 0;
}

/// Bit-addressable view of an armored payload.
const Bits = struct {
    payload: []const u8,
    /// Bits the message actually occupies, fill excluded.
    total: usize,

    fn init(payload: []const u8, fill: u3) Error!Bits {
        for (payload) |c| {
            if (sixbit(c) == null) return error.BadPayload;
        }
        const raw = payload.len * 6;
        if (raw < fill) return error.Truncated;
        return .{ .payload = payload, .total = raw - fill };
    }

    fn u(b: Bits, start: usize, len: usize) Error!u64 {
        if (len == 0 or len > 63) return error.Malformed;
        if (start + len > b.total) return error.Truncated;
        var v: u64 = 0;
        var n: usize = 0;
        while (n < len) : (n += 1) {
            const at = start + n;
            const six: u6 = sixbit(b.payload[at / 6]) orelse return error.BadPayload;
            const shift: u3 = @intCast(5 - (at % 6));
            v = (v << 1) | @as(u64, (six >> shift) & 1);
        }
        return v;
    }

    fn sint(b: Bits, start: usize, len: usize) Error!i64 {
        const raw = try b.u(start, len);
        const sign: u64 = @as(u64, 1) << @intCast(len - 1);
        if (raw & sign != 0) {
            const mask = ~((sign << 1) -% 1);
            return @bitCast(raw | mask);
        }
        return @intCast(raw);
    }

    /// `chars` six-bit characters as text, trimmed at the `@` padding and of
    /// trailing spaces. The result lives in `tb`.
    fn text(b: Bits, start: usize, chars: usize, tb: *TextBuf) Error![]const u8 {
        const out = try tb.take(chars);
        var n: usize = 0;
        var k: usize = 0;
        while (k < chars) : (k += 1) {
            const code = try b.u(start + k * 6, 6);
            const ch = text_alphabet[@intCast(code)];
            if (ch == '@') break;
            out[n] = ch;
            n += 1;
        }
        return std.mem.trimEnd(u8, out[0..n], " ");
    }
};

/// Bump allocator over the caller's scratch space for decoded AIS strings.
const TextBuf = struct {
    buf: []u8,
    used: usize = 0,

    fn take(t: *TextBuf, n: usize) Error![]u8 {
        if (t.used + n > t.buf.len) return error.NoSpace;
        const s = t.buf[t.used..][0..n];
        t.used += n;
        return s;
    }
};

/// Scratch bytes `decode` needs for the longest static message (a type 5
/// carries a 7-character callsign, a 20-character name and a 20-character
/// destination).
pub const text_scratch_bytes = 64;

/// The longest armored payload `Assembler` will hold: nine fragments of the
/// 82-character sentence limit.
pub const max_assembly = 640;

/// A reassembled AIS message, ready for `decode`.
pub const Assembly = struct {
    payload: []const u8,
    fill: u3,
    channel: u8,
    own: bool,
};

/// Joins multi-fragment AIVDM/AIVDO messages.
///
/// Fragments interleave across channels, so a slot is keyed by channel and
/// sequential message id. Anything unexpected — a fragment out of order, a
/// second message id on the same channel, an over-long assembly — drops the
/// partial message and returns null. The stream is untrusted input; losing a
/// target report is correct, failing is not.
pub const Assembler = struct {
    slots: [4]Slot = @splat(.{}),
    /// Partial messages abandoned because a fragment did not fit the slot.
    dropped: u64 = 0,
    /// Counts pushes so the least recently touched slot is the one reused.
    tick: u64 = 0,

    const Slot = struct {
        active: bool = false,
        channel: u8 = 0,
        msg_id: ?u8 = null,
        fragments: u8 = 0,
        /// The index the next fragment must carry.
        expect: u8 = 0,
        len: usize = 0,
        buf: [max_assembly]u8 = undefined,
        seq: u64 = 0,

        fn append(s: *Slot, payload: []const u8) bool {
            if (s.len + payload.len > s.buf.len) return false;
            @memcpy(s.buf[s.len..][0..payload.len], payload);
            s.len += payload.len;
            return true;
        }
    };

    /// Returns the finished message when this fragment completes one. The
    /// payload of a single-fragment message points into the caller's line;
    /// a reassembled one points into this struct. Either stays valid until
    /// the next `push`.
    pub fn push(a: *Assembler, v: Vdm) ?Assembly {
        if (v.fragments == 0 or v.index == 0 or v.index > v.fragments) return null;
        if (v.fragments == 1) return .{
            .payload = v.payload,
            .fill = v.fill,
            .channel = v.channel,
            .own = v.own,
        };
        a.tick += 1;
        if (v.index == 1) {
            const s = a.claim();
            s.* = .{
                .active = true,
                .channel = v.channel,
                .msg_id = v.msg_id,
                .fragments = v.fragments,
                .expect = 2,
                .len = 0,
                .seq = a.tick,
            };
            if (!s.append(v.payload)) {
                a.dropped += 1;
                s.active = false;
            }
            return null;
        }
        const s = a.find(v) orelse return null;
        s.seq = a.tick;
        if (!s.append(v.payload)) {
            a.dropped += 1;
            s.active = false;
            return null;
        }
        if (v.index == s.fragments) {
            s.active = false;
            return .{
                .payload = s.buf[0..s.len],
                .fill = v.fill,
                .channel = s.channel,
                .own = v.own,
            };
        }
        s.expect = v.index + 1;
        return null;
    }

    fn find(a: *Assembler, v: Vdm) ?*Slot {
        for (&a.slots) |*s| {
            if (!s.active) continue;
            if (s.channel != v.channel) continue;
            if (!idEq(s.msg_id, v.msg_id)) continue;
            if (s.fragments != v.fragments or s.expect != v.index) continue;
            return s;
        }
        return null;
    }

    /// A free slot, or the least recently touched one.
    fn claim(a: *Assembler) *Slot {
        var oldest: *Slot = &a.slots[0];
        for (&a.slots) |*s| {
            if (!s.active) return s;
            if (s.seq < oldest.seq) oldest = s;
        }
        a.dropped += 1;
        return oldest;
    }

    fn idEq(x: ?u8, y: ?u8) bool {
        if (x == null and y == null) return true;
        if (x == null or y == null) return false;
        return x.? == y.?;
    }
};

/// A position report: types 1, 2 and 3 (class A) and 18 (class B).
pub const AisPosition = struct {
    msg_type: u8,
    mmsi: u32,
    /// Types 1-3 only; 15 ("undefined") reads as null.
    nav_status: ?u8,
    /// Null on the 91°/181° "not available" sentinels.
    lat: ?f64,
    lon: ?f64,
    /// Null on the 1023 sentinel.
    sog_kn: ?f64,
    /// Null on the 3600 sentinel.
    cog_deg: ?f64,
    /// True heading; null on the 511 sentinel.
    heading_deg: ?f64,
    class_b: bool,
};

/// Ship data: type 5 (class A) and both parts of type 24 (class B).
pub const AisStatic = struct {
    msg_type: u8,
    /// 0 or 1 for type 24, null for type 5 which carries everything at once.
    part: ?u8,
    mmsi: u32,
    imo: ?u32,
    /// Slices into the caller's scratch buffer; empty when the field was
    /// entirely `@` padding.
    name: []const u8,
    callsign: []const u8,
    destination: []const u8,
    ship_type: ?u8,
    draught_m: ?f64,
    to_bow_m: ?u16,
    to_stern_m: ?u16,
    to_port_m: ?u16,
    to_starboard_m: ?u16,
};

pub const AisMessage = union(enum) {
    position: AisPosition,
    static: AisStatic,
};

/// Decodes a reassembled payload. `text` holds the decoded strings and must
/// be at least `text_scratch_bytes` long; it must outlive the result.
pub fn decode(payload: []const u8, fill: u3, text: []u8) Error!AisMessage {
    const b = try Bits.init(payload, fill);
    var tb = TextBuf{ .buf = text };
    const msg_type: u8 = @intCast(try b.u(0, 6));
    const mmsi: u32 = @intCast(try b.u(8, 30));
    switch (msg_type) {
        1, 2, 3 => {
            const status: u8 = @intCast(try b.u(38, 4));
            return .{ .position = .{
                .msg_type = msg_type,
                .mmsi = mmsi,
                .nav_status = if (status == 15) null else status,
                .lon = coord(try b.sint(61, 28), 181.0),
                .lat = coord(try b.sint(89, 27), 91.0),
                .sog_kn = tenths(try b.u(50, 10), 1023),
                .cog_deg = tenths(try b.u(116, 12), 3600),
                .heading_deg = heading(try b.u(128, 9)),
                .class_b = false,
            } };
        },
        18 => return .{ .position = .{
            .msg_type = msg_type,
            .mmsi = mmsi,
            .nav_status = null,
            .lon = coord(try b.sint(57, 28), 181.0),
            .lat = coord(try b.sint(85, 27), 91.0),
            .sog_kn = tenths(try b.u(46, 10), 1023),
            .cog_deg = tenths(try b.u(112, 12), 3600),
            .heading_deg = heading(try b.u(124, 9)),
            .class_b = true,
        } },
        5 => {
            const draught = try b.u(294, 8);
            return .{ .static = .{
                .msg_type = 5,
                .part = null,
                .mmsi = mmsi,
                .imo = @intCast(try b.u(40, 30)),
                .callsign = try b.text(70, 7, &tb),
                .name = try b.text(112, 20, &tb),
                .destination = try b.text(302, 20, &tb),
                .ship_type = @intCast(try b.u(232, 8)),
                .draught_m = if (draught == 0) null else @as(f64, @floatFromInt(draught)) * 0.1,
                .to_bow_m = @intCast(try b.u(240, 9)),
                .to_stern_m = @intCast(try b.u(249, 9)),
                .to_port_m = @intCast(try b.u(258, 6)),
                .to_starboard_m = @intCast(try b.u(264, 6)),
            } };
        },
        24 => {
            const part: u8 = @intCast(try b.u(38, 2));
            if (part == 0) return .{ .static = .{
                .msg_type = 24,
                .part = 0,
                .mmsi = mmsi,
                .imo = null,
                .name = try b.text(40, 20, &tb),
                .callsign = "",
                .destination = "",
                .ship_type = null,
                .draught_m = null,
                .to_bow_m = null,
                .to_stern_m = null,
                .to_port_m = null,
                .to_starboard_m = null,
            } };
            if (part == 1) return .{ .static = .{
                .msg_type = 24,
                .part = 1,
                .mmsi = mmsi,
                .imo = null,
                .name = "",
                .callsign = try b.text(90, 7, &tb),
                .destination = "",
                .ship_type = @intCast(try b.u(40, 8)),
                .draught_m = null,
                .to_bow_m = @intCast(try b.u(132, 9)),
                .to_stern_m = @intCast(try b.u(141, 9)),
                .to_port_m = @intCast(try b.u(150, 6)),
                .to_starboard_m = @intCast(try b.u(156, 6)),
            } };
            return error.Unsupported;
        },
        else => return error.Unsupported,
    }
}

/// 1/10000 minute units to degrees, with the "not available" sentinel — and
/// anything beyond the valid range — reported as null.
fn coord(raw: i64, limit: f64) ?f64 {
    const v = @as(f64, @floatFromInt(raw)) / 600000.0;
    if (@abs(v) >= limit) return null;
    return v;
}

fn tenths(raw: u64, sentinel: u64) ?f64 {
    if (raw >= sentinel) return null;
    return @as(f64, @floatFromInt(raw)) * 0.1;
}

fn heading(raw: u64) ?f64 {
    if (raw >= 360) return null;
    return @floatFromInt(raw);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const fx = @import("fixtures.zig");
const testing = std.testing;
const tol = 1e-6;

fn expectNear(expected: f64, actual: ?f64, eps: f64) !void {
    try testing.expect(actual != null);
    try testing.expectApproxEqAbs(expected, actual.?, eps);
}

test "every fixture line carries a valid checksum" {
    for (fx.all) |line| {
        try testing.expect(verify(line));
    }
    try testing.expect(!verify(fx.bad_checksum));
    try testing.expect(!verify(fx.no_checksum));
}

test "RMC gives position, speed in m/s, course and a dated time" {
    const s = try parse(fx.rmc);
    const r = s.rmc;
    try testing.expect(r.valid);
    try expectNear(fx.rmc_expect.lat, r.lat, 1e-9);
    try expectNear(fx.rmc_expect.lon, r.lon, 1e-9);
    try expectNear(fx.rmc_expect.sog_mps, r.sog_mps, 1e-4);
    try expectNear(fx.rmc_expect.cog_true, r.cog_true, tol);
    try expectNear(fx.rmc_expect.variation, r.variation, tol);
    const u = r.utc.?;
    try testing.expectEqual(@as(u16, 1994), u.year.?);
    try testing.expectEqual(@as(u8, 3), u.month.?);
    try testing.expectEqual(@as(u8, 23), u.day.?);
    try testing.expectEqual(@as(u8, 12), u.hour);
    try testing.expectEqual(@as(u8, 35), u.minute);
    try testing.expectEqual(fx.rmc_expect.epoch_ms, u.epochMs().?);
}

test "RMC with no fix reports invalid and null fields" {
    const r = (try parse(fx.rmc_void)).rmc;
    try testing.expect(!r.valid);
    try testing.expect(r.lat == null);
    try testing.expect(r.lon == null);
    try testing.expect(r.sog_mps == null);
}

test "GGA gives position, quality and altitude" {
    const g = (try parse(fx.gga)).gga;
    try expectNear(fx.gga_expect.lat, g.lat, 1e-9);
    try expectNear(fx.gga_expect.lon, g.lon, 1e-9);
    try testing.expectEqual(@as(u8, 1), g.quality);
    try testing.expectEqual(@as(u8, 8), g.satellites.?);
    try expectNear(545.4, g.altitude_m, 1e-6);
    try expectNear(46.9, g.geoid_sep_m, 1e-6);
}

test "GGA without a fix keeps quality 0 and no position" {
    const g = (try parse(fx.gga_nofix)).gga;
    try testing.expectEqual(@as(u8, 0), g.quality);
    try testing.expect(g.lat == null);
    try testing.expect(g.lon == null);
}

test "VTG converts knots to m/s" {
    const v = (try parse(fx.vtg)).vtg;
    try expectNear(54.7, v.cog_true, tol);
    try expectNear(34.4, v.cog_mag, tol);
    try expectNear(fx.vtg_expect_sog_mps, v.sog_mps, 1e-4);
}

test "HDT is true heading" {
    const h = (try parse(fx.hdt)).hdt;
    try expectNear(274.07, h.heading_true, tol);
}

test "HDG applies deviation and variation to reach true" {
    const h = (try parse(fx.hdg)).hdg;
    try expectNear(101.1, h.sensor_mag, tol);
    try expectNear(-7.1, h.variation, tol);
    try expectNear(94.0, h.heading_true, 1e-9);
    const h2 = (try parse(fx.hdg_novar)).hdg;
    try testing.expect(h2.heading_true == null);
    try expectNear(101.1, h2.heading_mag, tol);
}

test "DPT and DBT report metres below the transducer" {
    const d = (try parse(fx.dpt)).dpt;
    try expectNear(4.1, d.depth_m, tol);
    try expectNear(0.5, d.offset_m, tol);
    const b = (try parse(fx.dbt)).dbt;
    try expectNear(5.3, b.depth_m, tol);
}

test "MWV signs the wind angle with starboard positive" {
    const a = (try parse(fx.mwv_apparent)).mwv;
    try testing.expectEqual(WindRef.apparent, a.reference);
    try expectNear(-145.2, a.angle_deg, 1e-9);
    try expectNear(0.1 * kmh_mps, a.speed_mps, 1e-9);
    try testing.expect(a.valid);
    const t = (try parse(fx.mwv_true)).mwv;
    try testing.expectEqual(WindRef.true_wind, t.reference);
    try expectNear(45.0, t.angle_deg, tol);
    try expectNear(10.5 * knot_mps, t.speed_mps, 1e-9);
}

test "MWD is the true wind direction and speed" {
    const m = (try parse(fx.mwd)).mwd;
    try expectNear(220.0, m.direction_true, tol);
    try expectNear(209.0, m.direction_mag, tol);
    try expectNear(12.0 * knot_mps, m.speed_mps, 1e-9);
}

test "VHW is heading and speed through the water" {
    const v = (try parse(fx.vhw)).vhw;
    try expectNear(274.0, v.heading_true, tol);
    try expectNear(262.0, v.heading_mag, tol);
    try expectNear(5.5 * knot_mps, v.stw_mps, 1e-9);
}

test "a bad checksum is rejected, never parsed" {
    try testing.expectError(error.BadChecksum, parse(fx.bad_checksum));
    try testing.expectError(error.BadChecksum, parse(fx.no_checksum));
}

test "unknown talker sentences are Unsupported, not errors in disguise" {
    try testing.expectError(error.Unsupported, parse(fx.gsv));
}

test "the feeder yields whole lines from arbitrary chunk boundaries" {
    var line_buf: [128]u8 = undefined;
    var f = Feeder.init(&line_buf);
    var stream_buf: [512]u8 = undefined;
    // Three good lines and one corrupted one, CRLF terminated.
    const stream_bytes = try std.fmt.bufPrint(
        &stream_buf,
        "{s}\r\n{s}\r\n{s}\r\n{s}\r\n",
        .{ fx.rmc, fx.bad_checksum, fx.hdt, fx.dpt },
    );

    var got: usize = 0;
    var at: usize = 0;
    // Feed in 7-byte chunks so every line splits mid-field at least once.
    while (at < stream_bytes.len) {
        const end = @min(at + 7, stream_bytes.len);
        var it = f.feed(stream_bytes[at..end]);
        while (it.next()) |line| {
            switch (got) {
                0 => try testing.expectEqualStrings(fx.rmc, line),
                1 => try testing.expectEqualStrings(fx.hdt, line),
                2 => try testing.expectEqualStrings(fx.dpt, line),
                else => try testing.expect(false),
            }
            got += 1;
        }
        at = end;
    }
    try testing.expectEqual(@as(usize, 3), got);
    try testing.expectEqual(@as(u64, 1), f.stats.bad_checksum);
    try testing.expectEqual(@as(u64, 3), f.stats.lines);
}

test "the feeder resyncs past leading junk and bare LF" {
    var line_buf: [128]u8 = undefined;
    var f = Feeder.init(&line_buf);
    var it = f.feed("garbage,,,*ZZ\n");
    try testing.expect(it.next() == null);
    var buf: [256]u8 = undefined;
    const two = try std.fmt.bufPrint(&buf, "\xff\xfe{s}\n{s}\n", .{ fx.hdt, fx.mwd });
    var it2 = f.feed(two);
    try testing.expectEqualStrings(fx.hdt, it2.next().?);
    try testing.expectEqualStrings(fx.mwd, it2.next().?);
    try testing.expect(it2.next() == null);
}

test "an over-long line is dropped, and the next line still arrives" {
    var line_buf: [32]u8 = undefined;
    var f = Feeder.init(&line_buf);
    var it = f.feed("$GPRMC,this line is far too long for the buffer,x*00\r\n");
    try testing.expect(it.next() == null);
    try testing.expectEqual(@as(u64, 1), f.stats.oversize);
    var tail: [64]u8 = undefined;
    var it2 = f.feed(try std.fmt.bufPrint(&tail, "{s}\r\n", .{fx.hdt}));
    try testing.expectEqualStrings(fx.hdt, it2.next().?);
}

test "AIVDM type 1 decodes position, speed and heading" {
    const v = (try parse(fx.aivdm_type1)).vdm;
    try testing.expectEqual(@as(u8, 1), v.fragments);
    var asm_state = Assembler{};
    const done = asm_state.push(v).?;
    var text: [text_scratch_bytes]u8 = undefined;
    const m = try decode(done.payload, done.fill, &text);
    const p = m.position;
    try testing.expectEqual(@as(u8, 1), p.msg_type);
    try testing.expectEqual(fx.aivdm_type1_expect.mmsi, p.mmsi);
    try expectNear(fx.aivdm_type1_expect.lat, p.lat, 1e-5);
    try expectNear(fx.aivdm_type1_expect.lon, p.lon, 1e-5);
    try expectNear(fx.aivdm_type1_expect.sog_kn, p.sog_kn, 1e-6);
    try expectNear(fx.aivdm_type1_expect.cog_deg, p.cog_deg, 1e-6);
    try expectNear(fx.aivdm_type1_expect.heading_deg, p.heading_deg, 1e-6);
    try testing.expect(!p.class_b);
}

test "AIVDM type 18 decodes a class B position" {
    const v = (try parse(fx.aivdm_type18)).vdm;
    var asm_state = Assembler{};
    const done = asm_state.push(v).?;
    var text: [text_scratch_bytes]u8 = undefined;
    const p = (try decode(done.payload, done.fill, &text)).position;
    try testing.expectEqual(@as(u8, 18), p.msg_type);
    try testing.expectEqual(fx.aivdm_type18_expect.mmsi, p.mmsi);
    try expectNear(fx.aivdm_type18_expect.lat, p.lat, 1e-5);
    try expectNear(fx.aivdm_type18_expect.lon, p.lon, 1e-5);
    try expectNear(fx.aivdm_type18_expect.sog_kn, p.sog_kn, 1e-6);
    try testing.expect(p.class_b);
}

test "the not-available sentinels decode as null, not as numbers" {
    const v = (try parse(fx.aivdm_sentinels)).vdm;
    var asm_state = Assembler{};
    const done = asm_state.push(v).?;
    var text: [text_scratch_bytes]u8 = undefined;
    const p = (try decode(done.payload, done.fill, &text)).position;
    try testing.expectEqual(@as(u32, 366999999), p.mmsi);
    try testing.expect(p.lat == null); // 91°
    try testing.expect(p.lon == null); // 181°
    try testing.expect(p.sog_kn == null); // 1023
    try testing.expect(p.cog_deg == null); // 3600
    try testing.expect(p.heading_deg == null); // 511
}

test "a two-part type 5 reassembles and trims the @ padding off the name" {
    var asm_state = Assembler{};
    var text: [text_scratch_bytes]u8 = undefined;
    const first = (try parse(fx.aivdm_type5_a)).vdm;
    try testing.expect(asm_state.push(first) == null);
    const second = (try parse(fx.aivdm_type5_b)).vdm;
    const done = asm_state.push(second).?;
    const s = (try decode(done.payload, done.fill, &text)).static;
    try testing.expectEqual(@as(u8, 5), s.msg_type);
    try testing.expectEqual(fx.aivdm_type5_expect.mmsi, s.mmsi);
    try testing.expectEqual(fx.aivdm_type5_expect.imo, s.imo.?);
    try testing.expectEqualStrings(fx.aivdm_type5_expect.name, s.name);
    try testing.expectEqualStrings(fx.aivdm_type5_expect.callsign, s.callsign);
    try testing.expectEqualStrings(fx.aivdm_type5_expect.destination, s.destination);
}

test "type 24 part A carries the name and part B the callsign" {
    var text: [text_scratch_bytes]u8 = undefined;
    var asm_state = Assembler{};
    const a = asm_state.push((try parse(fx.aivdm_type24a)).vdm).?;
    const sa = (try decode(a.payload, a.fill, &text)).static;
    try testing.expectEqual(@as(u8, 0), sa.part.?);
    try testing.expectEqualStrings(fx.aivdm_type24_expect.name, sa.name);
    var text_b: [text_scratch_bytes]u8 = undefined;
    const b = asm_state.push((try parse(fx.aivdm_type24b)).vdm).?;
    const sb = (try decode(b.payload, b.fill, &text_b)).static;
    try testing.expectEqual(@as(u8, 1), sb.part.?);
    try testing.expectEqualStrings(fx.aivdm_type24_expect.callsign, sb.callsign);
    try testing.expectEqual(fx.aivdm_type24_expect.mmsi, sb.mmsi);
}

test "out-of-order and orphaned AIS fragments drop without crashing" {
    const head = (try parse(fx.aivdm_type5_a)).vdm;
    const tail = (try parse(fx.aivdm_type5_b)).vdm;

    // A tail with no head has nothing to join.
    var orphan = Assembler{};
    try testing.expect(orphan.push(tail) == null);

    // In order the pair completes, and the slot closes behind it: a
    // duplicated tail finds nothing to finish.
    var ordered = Assembler{};
    try testing.expect(ordered.push(head) == null);
    try testing.expect(ordered.push(tail) != null);
    try testing.expect(ordered.push(tail) == null);

    // A tail carrying another message id belongs to a different message.
    var mixed = Assembler{};
    try testing.expect(mixed.push(head) == null);
    var wrong_id = tail;
    wrong_id.msg_id = 7;
    try testing.expect(mixed.push(wrong_id) == null);
    var wrong_channel = tail;
    wrong_channel.channel = 'B';
    try testing.expect(mixed.push(wrong_channel) == null);
    // The open slot survives both and still completes with its own tail.
    try testing.expect(mixed.push(tail) != null);

    // Fragment 3 of 3 arriving before fragment 2 is discarded; the slot
    // goes on waiting for 2, and 2 on its own completes nothing.
    var jumbled = Assembler{};
    var f1 = head;
    f1.fragments = 3;
    var f2 = tail;
    f2.fragments = 3;
    f2.index = 2;
    var f3 = tail;
    f3.fragments = 3;
    f3.index = 3;
    try testing.expect(jumbled.push(f1) == null);
    try testing.expect(jumbled.push(f3) == null);
    try testing.expect(jumbled.push(f2) == null);
}

test "a fragment whose index or count is impossible is rejected" {
    try testing.expectError(error.Malformed, parse(fx.aivdm_bad_index));
    var asm_state = Assembler{};
    const v = Vdm{
        .fragments = 3,
        .index = 4,
        .msg_id = 1,
        .channel = 'A',
        .payload = "1",
        .fill = 0,
        .own = false,
    };
    try testing.expect(asm_state.push(v) == null);
}

test "truncated and illegal payloads return errors" {
    var text: [text_scratch_bytes]u8 = undefined;
    // A single armored character cannot hold a 168-bit position report.
    try testing.expectError(error.Truncated, decode("1", 0, &text));
    // Characters outside the alphabet.
    try testing.expectError(error.BadPayload, decode("15M67FC000G?ufbE\x00Fep", 0, &text));
    // A type this parser does not decode.
    try testing.expectError(error.Unsupported, decode(">0286nJ0000", 0, &text));
    // Scratch space too small for the 20-character name of a type 24.
    var tiny: [4]u8 = undefined;
    var asm_state = Assembler{};
    const a = asm_state.push((try parse(fx.aivdm_type24a)).vdm).?;
    try testing.expectError(error.NoSpace, decode(a.payload, a.fill, &tiny));
}

test "fuzz-shaped garbage never panics" {
    var text: [text_scratch_bytes]u8 = undefined;
    var line_buf: [96]u8 = undefined;
    var f = Feeder.init(&line_buf);
    var asm_state = Assembler{};
    // A deterministic byte soup: every printable value, every framing
    // character, sliced at prime boundaries.
    var soup: [4096]u8 = undefined;
    var x: u32 = 12345;
    for (&soup) |*c| {
        x = x *% 1103515245 +% 12345;
        const pick = (x >> 16) % 8;
        c.* = switch (pick) {
            0 => '$',
            1 => '!',
            2 => ',',
            3 => '*',
            4 => '\r',
            5 => '\n',
            else => @intCast(32 + (x >> 8) % 95),
        };
    }
    var at: usize = 0;
    while (at < soup.len) {
        const end = @min(at + 13, soup.len);
        var it = f.feed(soup[at..end]);
        while (it.next()) |line| {
            const s = parse(line) catch continue;
            switch (s) {
                .vdm => |v| {
                    if (asm_state.push(v)) |done| {
                        _ = decode(done.payload, done.fill, &text) catch {};
                    }
                },
                else => {},
            }
        }
        at = end;
    }
    // Reaching here without a panic is the assertion; the counters only
    // prove the soup exercised the paths.
    try testing.expect(f.stats.bad_checksum + f.stats.no_checksum > 0);
}

test "epochMs matches a known instant" {
    const u = Utc{ .hour = 0, .minute = 0, .second = 0, .year = 2026, .month = 8, .day = 5 };
    try testing.expectEqual(@as(i64, 1785888000000), u.epochMs().?);
    const none = Utc{ .hour = 1, .minute = 2, .second = 3 };
    try testing.expect(none.epochMs() == null);
}

test "armoring round-trips every 6-bit value" {
    var v: u7 = 0;
    while (v < 64) : (v += 1) {
        const c = armor(@intCast(v));
        try testing.expectEqual(@as(u6, @intCast(v)), sixbit(c).?);
    }
    // The gap the alphabet skips.
    try testing.expect(sixbit('X') == null);
    try testing.expect(sixbit('x') == null);
    try testing.expect(sixbit(' ') == null);
}

test "textCode is the inverse of the text alphabet" {
    for (text_alphabet, 0..) |ch, i| {
        try testing.expectEqual(@as(u6, @intCast(i)), textCode(ch));
    }
    try testing.expectEqual(textCode('A'), textCode('a'));
}
