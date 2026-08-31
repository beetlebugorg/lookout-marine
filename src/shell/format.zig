//! The strings a mariner reads, and the text a mariner types.
//!
//! Positions, scales and scale bands, formatted and parsed. Exported through
//! lookout-shell.h.

const std = @import("std");

/// The longest string `fmtCoordDM` writes.
pub const coord_max = 24;
/// The longest string `fmtPosition` writes: two coordinates and a space.
pub const position_max = coord_max * 2 + 1;
/// The longest string `fmtScale` writes.
pub const scale_max = 24;

/// Degrees and decimal minutes with a hemisphere: `38°58.580'N`. The longitude
/// has three degree digits, so a pair keeps its column width.
///
/// Decimal minutes is the unit a mariner works in. A GPS and a chartplotter
/// show it, the deck log records it, and it goes over the radio. One minute of
/// latitude is one nautical mile, so a decimal minute reads as a distance.
/// Three decimals is about 1.9 m, finer than any chart's own accuracy.
pub fn fmtCoordDM(buf: []u8, value: f64, is_lat: bool) []const u8 {
    // A value that is not finite has no position to print. The result is
    // empty, the same as a readout with no fix.
    if (!std.math.isFinite(value) or @abs(value) > 1_000_000) return buf[0..0];

    const hemi: []const u8 = if (is_lat)
        (if (value >= 0) "N" else "S")
    else
        (if (value >= 0) "E" else "W");
    const a = @abs(value);
    var deg: u64 = @intFromFloat(a);
    var mins = (a - @as(f64, @floatFromInt(deg))) * 60;
    // Carry the rounding. 59.9996' prints as 60.000', which is the next degree.
    if (@round(mins * 1000) >= 60_000) {
        mins = 0;
        deg += 1;
    }
    const out = if (is_lat)
        std.fmt.bufPrint(buf, "{d:0>2}°{d:0>6.3}'{s}", .{ deg, mins, hemi })
    else
        std.fmt.bufPrint(buf, "{d:0>3}°{d:0>6.3}'{s}", .{ deg, mins, hemi });
    return out catch buf[0..0];
}

/// A full position: `38°58.580'N 076°28.920'W`. Latitude first, as every
/// chartplotter writes it.
pub fn fmtPosition(buf: []u8, lat: f64, lon: f64) []const u8 {
    var lat_buf: [coord_max]u8 = undefined;
    var lon_buf: [coord_max]u8 = undefined;
    const la = fmtCoordDM(&lat_buf, lat, true);
    const lo = fmtCoordDM(&lon_buf, lon, false);
    if (la.len == 0 or lo.len == 0) return buf[0..0];
    return std.fmt.bufPrint(buf, "{s} {s}", .{ la, lo }) catch buf[0..0];
}

/// The full scale with group separators: `1:13,267`. A denominator of zero or
/// less prints `1:—`.
///
/// The separator is a comma, independent of locale.
pub fn fmtScale(buf: []u8, denominator: f64) []const u8 {
    if (!(denominator > 0) or !(denominator < 1e15))
        return std.fmt.bufPrint(buf, "1:—", .{}) catch buf[0..0];

    var plain: [24]u8 = undefined;
    const digits = std.fmt.bufPrint(&plain, "{d}", .{@as(u64, @intFromFloat(@round(denominator)))}) catch return buf[0..0];
    if (buf.len < 2 + digits.len + digits.len / 3) return buf[0..0];
    var n: usize = 0;
    buf[n] = '1';
    n += 1;
    buf[n] = ':';
    n += 1;
    for (digits, 0..) |c, i| {
        if (i > 0 and (digits.len - i) % 3 == 0) {
            buf[n] = ',';
            n += 1;
        }
        buf[n] = c;
        n += 1;
    }
    return buf[0..n];
}

/// The usage bands S-57 numbers 1 to 6, in the words the readouts use.
pub fn bandName(band: u8) [:0]const u8 {
    return switch (band) {
        1 => "Overview",
        2 => "General",
        3 => "Coastal",
        4 => "Approach",
        5 => "Harbor",
        6 => "Berthing",
        else => "Unknown",
    };
}

/// The S-52 navigational purpose band for a display scale. A band is named from
/// the denominator BELOW its ceiling.
pub fn bandForDenominator(denominator: f64) [:0]const u8 {
    if (!(denominator >= 0.001)) return "—";
    if (denominator < 5_000) return "Berthing";
    if (denominator < 25_000) return "Harbor";
    if (denominator < 75_000) return "Approach";
    if (denominator < 300_000) return "Coastal";
    if (denominator < 1_500_000) return "General";
    return "Overview";
}

/// A scale as a zoom delta. At one latitude the denominator is
/// C·cos(lat)/2^zoom, so the engine's own zoom does the work and keeps its
/// limits and its easing. Returns 0 when either denominator is zero or less.
pub fn zoomDeltaForScale(current: f64, wanted: f64) f64 {
    if (!(current > 0) or !(wanted > 0)) return 0;
    return std.math.log2(current / wanted);
}

/// A position the mariner typed.
pub const Position = struct { lat: f64, lon: f64 };

/// Tolerant lat/lon parser: decimal pairs ("38.98, -76.48") and degrees with
/// hemispheres ("38°58.8'N 076°29.0'W", "38 58 30 N, 76 29 W").
pub fn parsePosition(raw: []const u8) ?Position {
    const s = std.mem.trim(u8, raw, &std.ascii.whitespace);
    if (s.len == 0) return null;
    for (s) |c| {
        switch (std.ascii.toUpper(c)) {
            'N', 'S', 'E', 'W' => return parseHemispheres(s),
            else => {},
        }
    }
    return parseDecimalPair(s);
}

/// Latitude first, comma- or space-separated, and in range.
fn parseDecimalPair(s: []const u8) ?Position {
    var fields = std.mem.tokenizeAny(u8, s, ", ");
    const first = fields.next() orelse return null;
    const second = fields.next() orelse return null;
    const lat = std.fmt.parseFloat(f64, first) catch return null;
    const lon = std.fmt.parseFloat(f64, second) catch return null;
    if (!(lat >= -90 and lat <= 90)) return null;
    if (!(lon >= -180 and lon <= 180)) return null;
    return .{ .lat = lat, .lon = lon };
}

// The marks that end each part of a hemisphere position. Whitespace also ends
// a part, so "38 58 30 N" parses.
const degree_marks = [_][]const u8{"°"};
const minute_marks = [_][]const u8{ "'", "′" };
const second_marks = [_][]const u8{ "\"", "″" };

/// Every "deg [min [sec]] hemisphere" in the text. Either half may lead, since
/// a mariner writes what is in front of them, and both halves must be there.
fn parseHemispheres(s: []const u8) ?Position {
    var lat: ?f64 = null;
    var lon: ?f64 = null;
    var i: usize = 0;
    while (i < s.len) {
        const m = matchPart(s, i) orelse {
            i += 1;
            continue;
        };
        var value = m.deg + m.min / 60 + m.sec / 3600;
        if (m.hemi == 'S' or m.hemi == 'W') value = -value;
        if (m.hemi == 'N' or m.hemi == 'S') lat = value else lon = value;
        i = m.end;
    }
    if (lat != null and lon != null) return .{ .lat = lat.?, .lon = lon.? };
    return null;
}

const Part = struct { deg: f64, min: f64, sec: f64, hemi: u8, end: usize };

/// One part, anchored at `start`. The minutes and the seconds are each optional
/// and each are tried present before absent, so "1 2 3 4 N" reads 3 and 4.
fn matchPart(s: []const u8, start: usize) ?Part {
    const deg = number(s, start) orelse return null;
    var deg_ends: [2]usize = undefined;
    for (separators(s, deg.end, &degree_marks, &deg_ends)) |after_deg| {
        var min_opts: [3]OptionalPart = undefined;
        for (optionalPart(s, after_deg, &minute_marks, &min_opts)) |min| {
            var sec_opts: [3]OptionalPart = undefined;
            for (optionalPart(s, min.end, &second_marks, &sec_opts)) |sec| {
                if (sec.end >= s.len) continue;
                const hemi = std.ascii.toUpper(s[sec.end]);
                switch (hemi) {
                    'N', 'S', 'E', 'W' => return .{
                        .deg = deg.value,
                        .min = min.value,
                        .sec = sec.value,
                        .hemi = hemi,
                        .end = sec.end + 1,
                    },
                    else => {},
                }
            }
        }
    }
    return null;
}

const Number = struct { value: f64, end: usize };

/// Digits, with an optional fractional part. Longest wins. A shorter match
/// leaves a digit or a dot at the separator position, and neither is a
/// separator mark, whitespace or a hemisphere letter.
fn number(s: []const u8, start: usize) ?Number {
    var i = start;
    while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
    if (i == start) return null;
    if (i + 1 < s.len and s[i] == '.' and std.ascii.isDigit(s[i + 1])) {
        i += 1;
        while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
    }
    const value = std.fmt.parseFloat(f64, s[start..i]) catch return null;
    return .{ .value = value, .end = i };
}

/// The end positions a separator may have. A separator is a run of whitespace
/// with at most one of `marks` inside it. Longest first, so "38° 58" ends past
/// the space and "38 58" ends on the 5.
fn separators(s: []const u8, i: usize, marks: []const []const u8, out: *[2]usize) []const usize {
    const j = skipSpace(s, i);
    var n: usize = 0;
    for (marks) |mark| {
        if (std.mem.startsWith(u8, s[j..], mark)) {
            out[n] = skipSpace(s, j + mark.len);
            n += 1;
            break;
        }
    }
    if (j > i) {
        out[n] = j;
        n += 1;
    }
    return out[0..n];
}

const OptionalPart = struct { value: f64, end: usize };

/// A number and its separator, present then absent. When absent the value is 0
/// and the position does not advance.
fn optionalPart(s: []const u8, i: usize, marks: []const []const u8, out: *[3]OptionalPart) []const OptionalPart {
    var n: usize = 0;
    if (number(s, i)) |num| {
        var ends: [2]usize = undefined;
        for (separators(s, num.end, marks, &ends)) |end| {
            out[n] = .{ .value = num.value, .end = end };
            n += 1;
        }
    }
    out[n] = .{ .value = 0, .end = i };
    n += 1;
    return out[0..n];
}

fn skipSpace(s: []const u8, i: usize) usize {
    var j = i;
    while (j < s.len and std.ascii.isWhitespace(s[j])) j += 1;
    return j;
}

/// The scale parser. It accepts "25000", "25,000", "1:25000", "25k" and
/// "1:2.5M".
pub fn parseScale(raw: []const u8) ?f64 {
    var s = std.mem.trim(u8, raw, " \t");
    // In "1:25k", the text before the colon is the 1.
    if (std.mem.lastIndexOfScalar(u8, s, ':')) |colon| s = s[colon + 1 ..];

    var lowered: [64]u8 = undefined;
    var n: usize = 0;
    for (s) |c| {
        if (c == ',' or std.ascii.isWhitespace(c)) continue;
        if (n == lowered.len) return null;
        lowered[n] = std.ascii.toLower(c);
        n += 1;
    }
    var body = lowered[0..n];

    var multiplier: f64 = 1;
    if (body.len > 0 and body[body.len - 1] == 'k') {
        multiplier = 1_000;
        body = body[0 .. body.len - 1];
    } else if (body.len > 0 and body[body.len - 1] == 'm') {
        multiplier = 1_000_000;
        body = body[0 .. body.len - 1];
    }

    const value = std.fmt.parseFloat(f64, body) catch return null;
    if (!std.math.isFinite(value)) return null;
    const denominator = value * multiplier;
    // A value outside this range is not a chart scale.
    if (!(denominator >= 100) or !(denominator <= 100_000_000)) return null;
    return denominator;
}

// ---- tests ------------------------------------------------------------------

const t = std.testing;

fn dm(buf: []u8, value: f64, is_lat: bool) []const u8 {
    return fmtCoordDM(buf, value, is_lat);
}

test "a latitude shows its hemisphere" {
    var b: [coord_max]u8 = undefined;
    try t.expectEqualStrings("38°58.578'N", dm(&b, 38.9763, true));
    try t.expectEqualStrings("38°58.578'S", dm(&b, -38.9763, true));
}

test "a longitude shows its hemisphere" {
    var b: [coord_max]u8 = undefined;
    try t.expectEqualStrings("076°28.920'W", dm(&b, -76.482, false));
    try t.expectEqualStrings("076°28.920'E", dm(&b, 76.482, false));
}

test "zero is north and east" {
    // A boat on the equator or the prime meridian reads as north and east.
    var b: [coord_max]u8 = undefined;
    try t.expectEqualStrings("00°00.000'N", dm(&b, 0, true));
    try t.expectEqualStrings("000°00.000'E", dm(&b, 0, false));
}

test "a longitude keeps three degree digits" {
    var b: [coord_max]u8 = undefined;
    try t.expectEqualStrings("009°30.000'E", dm(&b, 9.5, false));
    try t.expectEqualStrings("179°30.000'E", dm(&b, 179.5, false));
}

test "a latitude keeps two degree digits" {
    var b: [coord_max]u8 = undefined;
    try t.expectEqualStrings("09°30.000'N", dm(&b, 9.5, true));
}

test "the rounding carries into the degree" {
    // 59.9996' rounds to 60.000', which is the next degree. Printed as
    // 38°60.000'N it is a position no chart has.
    var b: [coord_max]u8 = undefined;
    try t.expectEqualStrings("39°00.000'N", dm(&b, 38 + 59.9996 / 60.0, true));
    try t.expectEqualStrings("077°00.000'W", dm(&b, -(76 + 59.9996 / 60.0), false));
}

test "just under the carry stays in the degree" {
    var b: [coord_max]u8 = undefined;
    try t.expectEqualStrings("38°59.999'N", dm(&b, 38 + 59.9994 / 60.0, true));
}

test "minutes keep three decimals" {
    var b: [coord_max]u8 = undefined;
    try t.expectEqualStrings("38°30.000'N", dm(&b, 38.5, true));
}

test "a position is latitude then longitude" {
    var b: [position_max]u8 = undefined;
    try t.expectEqualStrings("38°58.578'N 076°28.920'W", fmtPosition(&b, 38.9763, -76.482));
}

test "a position with no fix has no string" {
    var b: [position_max]u8 = undefined;
    try t.expectEqualStrings("", fmtPosition(&b, std.math.nan(f64), -76.482));
    try t.expectEqualStrings("", fmtPosition(&b, 38.9763, std.math.inf(f64)));
}

test "an absent scale is a dash" {
    var b: [scale_max]u8 = undefined;
    try t.expectEqualStrings("1:—", fmtScale(&b, 0));
    try t.expectEqualStrings("1:—", fmtScale(&b, -1));
}

test "the scale is grouped" {
    var b: [scale_max]u8 = undefined;
    try t.expectEqualStrings("1:13,267", fmtScale(&b, 13267.4));
    try t.expectEqualStrings("1:1,500,000", fmtScale(&b, 1_500_000));
}

test "a short scale has no separator" {
    var b: [scale_max]u8 = undefined;
    try t.expectEqualStrings("1:500", fmtScale(&b, 500));
}

test "the scale rounds rather than truncating" {
    var b: [scale_max]u8 = undefined;
    try t.expectEqualStrings("1:500", fmtScale(&b, 499.6));
}

test "every band boundary" {
    // The S-52 navigational purpose bands, at each boundary.
    try t.expectEqualStrings("—", bandForDenominator(0));
    try t.expectEqualStrings("—", bandForDenominator(0.0009));
    try t.expectEqualStrings("Berthing", bandForDenominator(0.001));
    try t.expectEqualStrings("Berthing", bandForDenominator(4_999));
    try t.expectEqualStrings("Harbor", bandForDenominator(5_000));
    try t.expectEqualStrings("Harbor", bandForDenominator(24_999));
    try t.expectEqualStrings("Approach", bandForDenominator(25_000));
    try t.expectEqualStrings("Approach", bandForDenominator(74_999));
    try t.expectEqualStrings("Coastal", bandForDenominator(75_000));
    try t.expectEqualStrings("Coastal", bandForDenominator(299_999));
    try t.expectEqualStrings("General", bandForDenominator(300_000));
    try t.expectEqualStrings("General", bandForDenominator(1_499_999));
    try t.expectEqualStrings("Overview", bandForDenominator(1_500_000));
    try t.expectEqualStrings("Overview", bandForDenominator(50_000_000));
}

test "the usage bands are numbered from the overview" {
    try t.expectEqualStrings("Overview", bandName(1));
    try t.expectEqualStrings("General", bandName(2));
    try t.expectEqualStrings("Coastal", bandName(3));
    try t.expectEqualStrings("Approach", bandName(4));
    try t.expectEqualStrings("Harbor", bandName(5));
    try t.expectEqualStrings("Berthing", bandName(6));
    try t.expectEqualStrings("Unknown", bandName(0));
    try t.expectEqualStrings("Unknown", bandName(7));
}

fn expectPosition(raw: []const u8, lat: f64, lon: f64) !void {
    const got = parsePosition(raw) orelse return error.DidNotParse;
    try t.expectApproxEqAbs(lat, got.lat, 1e-9);
    try t.expectApproxEqAbs(lon, got.lon, 1e-9);
}

test "a decimal pair" {
    try expectPosition("38.98, -76.48", 38.98, -76.48);
    try expectPosition("38.98 -76.48", 38.98, -76.48);
    try expectPosition("  38.98 ,  -76.48  ", 38.98, -76.48);
}

test "the decimal pair is latitude first" {
    try expectPosition("0, 90", 0, 90);
}

test "degrees and decimal minutes with hemispheres" {
    try expectPosition("38°58.8'N 076°29.0'W", 38 + 58.8 / 60.0, -(76 + 29.0 / 60.0));
}

test "degrees, minutes and seconds" {
    try expectPosition("38 58 30 N, 76 29 W", 38 + 58.0 / 60.0 + 30.0 / 3600.0, -(76 + 29.0 / 60.0));
}

test "the hemisphere form may lead with longitude" {
    // A mariner writes what is in front of them.
    try expectPosition("076°29.0'W 38°58.8'N", 38 + 58.8 / 60.0, -(76 + 29.0 / 60.0));
}

test "one half of a position is not a position" {
    try t.expect(parsePosition("38°58.8'N") == null);
    try t.expect(parsePosition("38.98") == null);
}

test "an out of range pair is refused" {
    try t.expect(parsePosition("91, 0") == null);
    try t.expect(parsePosition("-91, 0") == null);
    try t.expect(parsePosition("0, 181") == null);
    try t.expect(parsePosition("0, -181") == null);
}

test "what is not a position" {
    try t.expect(parsePosition("") == null);
    try t.expect(parsePosition("   ") == null);
    try t.expect(parsePosition("Annapolis") == null);
}

test "a plain scale" {
    try t.expectEqual(@as(?f64, 25_000), parseScale("25000"));
}

test "group separators and spaces are ignored" {
    try t.expectEqual(@as(?f64, 25_000), parseScale("25,000"));
    try t.expectEqual(@as(?f64, 25_000), parseScale(" 25 000 "));
}

test "the ratio form" {
    // In "1:25000" the text before the colon is the 1.
    try t.expectEqual(@as(?f64, 25_000), parseScale("1:25000"));
    try t.expectEqual(@as(?f64, 25_000), parseScale("1:25k"));
}

test "the thousand and million suffixes" {
    try t.expectEqual(@as(?f64, 25_000), parseScale("25k"));
    try t.expectEqual(@as(?f64, 25_000), parseScale("25K"));
    try t.expectEqual(@as(?f64, 2_500_000), parseScale("1:2.5M"));
    try t.expectEqual(@as(?f64, 2_500_000), parseScale("2.5m"));
}

test "the scale sanity range" {
    // 1:5 is a floor plan.
    try t.expect(parseScale("1:5") == null);
    try t.expect(parseScale("99") == null);
    try t.expectEqual(@as(?f64, 100), parseScale("100"));
    try t.expectEqual(@as(?f64, 100_000_000), parseScale("100000000"));
    try t.expect(parseScale("100000001") == null);
}

test "what is not a scale" {
    try t.expect(parseScale("") == null);
    try t.expect(parseScale("harbour") == null);
    try t.expect(parseScale("1:") == null);
    try t.expect(parseScale("k") == null);
}

test "a scale is a zoom delta" {
    try t.expectApproxEqAbs(@as(f64, 1), zoomDeltaForScale(50_000, 25_000), 1e-12);
    try t.expectApproxEqAbs(@as(f64, -1), zoomDeltaForScale(25_000, 50_000), 1e-12);
    try t.expectApproxEqAbs(@as(f64, 0), zoomDeltaForScale(25_000, 25_000), 1e-12);
    try t.expectApproxEqAbs(@as(f64, 2), zoomDeltaForScale(100_000, 25_000), 1e-12);
    try t.expectApproxEqAbs(@log2(13_267.0 / 5_000.0), zoomDeltaForScale(13_267, 5_000), 1e-12);
}

test "a zoom delta with no scale to move from" {
    try t.expectEqual(@as(f64, 0), zoomDeltaForScale(0, 25_000));
    try t.expectEqual(@as(f64, 0), zoomDeltaForScale(25_000, 0));
}
