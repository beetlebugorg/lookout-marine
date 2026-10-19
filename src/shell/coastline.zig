//! The coastline a coverage picker draws, and the Mercator window it draws in.
//!
//! coastline.bin is baked from vendor/gshhg/coastline.geojson.gz, the GSHHG
//! data the basemap is baked from, clipped to the waters the NOAA picker shows
//! and simplified to 0.02 degrees. Layout, little-endian: a u32 ring count,
//! then per ring a u8 level, a u32 point count, and that many pairs of f32
//! longitude and latitude. Exported through lookout-shell.h.
//!
//! A picker draws this array instead of a picture of the chart. A picture has
//! to be taken at a view the camera has visited, and tiles load on the frame
//! loop, so it is not there on the first frame.

const std = @import("std");

pub const data: []const u8 = @embedFile("coastline.bin");

/// GSHHG levels. A lake is its own ring, drawn over the land it sits in.
pub const land: u8 = 1;
pub const lake: u8 = 2;

/// A lon/lat window in degrees, and the rectangle it is drawn into, in pixels.
/// Longitude maps straight through: wrapping it moves every point west of the
/// window to the far east.
pub const Window = struct {
    west: f64,
    east: f64,
    south: f64,
    north: f64,
    px_w: f64,
    px_h: f64,

    fn usable(w: Window) bool {
        return w.east > w.west and w.north > w.south and w.px_w > 0 and w.px_h > 0;
    }

    /// Pixel x and y of one point.
    pub fn point(w: Window, lon: f64, lat: f64) [2]f64 {
        if (!w.usable()) return .{ 0, 0 };
        const top = mercator(w.north);
        const h = top - mercator(w.south);
        const dy = if (h == 0) 0 else (top - mercator(lat)) / h;
        return .{ (lon - w.west) / (w.east - w.west) * w.px_w, dy * w.px_h };
    }

    fn touches(w: Window, b: Box) bool {
        return b.east >= w.west and b.west <= w.east and b.north >= w.south and b.south <= w.north;
    }
};

/// Width over height of a window drawn in Mercator. 1 for an empty window.
pub fn aspect(west: f64, east: f64, south: f64, north: f64) f64 {
    const h = mercator(north) - mercator(south);
    if (!(h > 0) or !(east > west)) return 1;
    return (east - west) * std.math.pi / 180 / h;
}

/// Mercator y, clamped clear of the poles.
pub fn mercator(lat: f64) f64 {
    const phi = std.math.clamp(lat, -85.05, 85.05) * std.math.pi / 180;
    return @log(@tan(std.math.pi / 4.0 + phi / 2.0));
}

const Box = struct { west: f64, east: f64, south: f64, north: f64 };

/// One ring of the file, still in its bytes.
const Ring = struct {
    level: u8,
    points: []const u8, // 8 bytes a point

    fn lonLat(r: Ring, i: usize) [2]f64 {
        const at = r.points[i * 8 ..][0..8];
        const x: f32 = @bitCast(std.mem.readInt(u32, at[0..4], .little));
        const y: f32 = @bitCast(std.mem.readInt(u32, at[4..8], .little));
        return .{ x, y };
    }

    fn count(r: Ring) usize {
        return r.points.len / 8;
    }

    fn box(r: Ring) Box {
        var b = Box{ .west = 180, .east = -180, .south = 90, .north = -90 };
        for (0..r.count()) |i| {
            const p = r.lonLat(i);
            b.west = @min(b.west, p[0]);
            b.east = @max(b.east, p[0]);
            b.south = @min(b.south, p[1]);
            b.north = @max(b.north, p[1]);
        }
        return b;
    }
};

const Iter = struct {
    at: usize = 4,
    left: u32,

    fn init() Iter {
        if (data.len < 4) return .{ .left = 0 };
        return .{ .left = std.mem.readInt(u32, data[0..4], .little) };
    }

    /// The next ring, or null at the end or at a truncated ring.
    fn next(it: *Iter) ?Ring {
        if (it.left == 0 or it.at + 5 > data.len) return null;
        const level = data[it.at];
        const n = std.mem.readInt(u32, data[it.at + 1 ..][0..4], .little);
        const start = it.at + 5;
        const bytes = @as(usize, n) * 8;
        if (start + bytes > data.len) return null;
        it.at = start + bytes;
        it.left -= 1;
        return .{ .level = level, .points = data[start .. start + bytes] };
    }
};

/// Whether a ring of `level` is drawn in this window. A ring spanning more
/// than 180 degrees of longitude crosses the antimeridian, such as an Aleutian
/// island with points at +172 and -179. Drawn straight through, it is a band
/// across the whole map, so it is left out.
fn drawn(r: Ring, level: u8, w: Window) bool {
    if (r.level != level or r.count() == 0) return false;
    const b = r.box();
    if (b.east - b.west > 180) return false;
    return w.touches(b);
}

/// The rings of one level that reach into the window, projected to pixels.
/// `xy` has room for xy.len / 2 points. `ends[i]` is the point index one past
/// ring i, so the last ring ends at the returned count. Writes only when both
/// buffers hold the whole result. Returns the number of points.
pub fn rings(level: u8, w: Window, xy: []f32, ends: []u32) usize {
    if (!w.usable()) return 0;
    var points: usize = 0;
    var count: usize = 0;
    var it = Iter.init();
    while (it.next()) |r| {
        if (!drawn(r, level, w)) continue;
        points += r.count();
        count += 1;
    }
    if (xy.len / 2 < points or ends.len < count) return points;

    var p: usize = 0;
    var k: usize = 0;
    it = Iter.init();
    while (it.next()) |r| {
        if (!drawn(r, level, w)) continue;
        for (0..r.count()) |i| {
            const ll = r.lonLat(i);
            const px = w.point(ll[0], ll[1]);
            xy[p * 2] = @floatCast(px[0]);
            xy[p * 2 + 1] = @floatCast(px[1]);
            p += 1;
        }
        ends[k] = @intCast(p);
        k += 1;
    }
    return points;
}

const testing = std.testing;

/// The lower 48 panel the pickers draw.
const lower48 = Window{ .west = -132, .east = -64, .south = 20, .north = 52, .px_w = 680, .px_h = 400 };

test "the embedded file reads to its end" {
    var it = Iter.init();
    var n: usize = 0;
    var levels = [_]usize{ 0, 0, 0 };
    var min_points: usize = std.math.maxInt(usize);
    while (it.next()) |r| {
        n += 1;
        try testing.expect(r.level == land or r.level == lake);
        levels[r.level] += 1;
        min_points = @min(min_points, r.count());
    }
    try testing.expectEqual(@as(usize, std.mem.readInt(u32, data[0..4], .little)), n);
    try testing.expectEqual(data.len, it.at);
    try testing.expect(levels[land] > 0 and levels[lake] > 0);
    // A ring has at least four points, so `ends` never needs more entries
    // than a quarter of the points. lookout-shell.h states this.
    try testing.expect(min_points >= 4);
}

test "a call with no room returns the size and leaves the buffers alone" {
    const n = rings(land, lower48, &.{}, &.{});
    try testing.expect(n > 1000);
    var xy: [8]f32 = .{ -1, -1, -1, -1, -1, -1, -1, -1 };
    var ends: [2]u32 = .{ 7, 7 };
    try testing.expectEqual(n, rings(land, lower48, &xy, &ends));
    try testing.expectEqual(@as(f32, -1), xy[0]);
    try testing.expectEqual(@as(u32, 7), ends[0]);
}

test "rings fill both buffers and the last one ends at the count" {
    const n = rings(land, lower48, &.{}, &.{});
    const xy = try testing.allocator.alloc(f32, n * 2);
    defer testing.allocator.free(xy);
    const ends = try testing.allocator.alloc(u32, n / 4);
    defer testing.allocator.free(ends);
    @memset(ends, 0);
    try testing.expectEqual(n, rings(land, lower48, xy, ends));
    var last: u32 = 0;
    var count: usize = 0;
    for (ends) |e| {
        if (e == 0) break;
        try testing.expect(e >= last + 4);
        last = e;
        count += 1;
    }
    try testing.expectEqual(@as(u32, @intCast(n)), last);
    try testing.expect(count > 10);
    // The rings that reach the frame also run north into Canada, so a little
    // under half their points are inside it.
    var inside: usize = 0;
    for (0..n) |i| {
        if (xy[i * 2] >= 0 and xy[i * 2] <= 680 and xy[i * 2 + 1] >= 0 and xy[i * 2 + 1] <= 400) inside += 1;
    }
    try testing.expect(inside * 3 > n);
}

test "lakes are their own level" {
    // The Great Lakes are in the lower 48 panel.
    try testing.expect(rings(lake, lower48, &.{}, &.{}) > 0);
    try testing.expectEqual(@as(usize, 0), rings(3, lower48, &.{}, &.{}));
}

test "an empty window or rectangle draws no ring" {
    var w = lower48;
    w.east = w.west;
    try testing.expectEqual(@as(usize, 0), rings(land, w, &.{}, &.{}));
    w = lower48;
    w.px_h = 0;
    try testing.expectEqual(@as(usize, 0), rings(land, w, &.{}, &.{}));
}

test "a ring across the antimeridian is left out" {
    // Alaska's panel reaches the Aleutians, where three rings cross 180.
    const alaska = Window{ .west = -172, .east = -128, .south = 50.5, .north = 72, .px_w = 440, .px_h = 400 };
    const n = rings(land, alaska, &.{}, &.{});
    const xy = try testing.allocator.alloc(f32, n * 2);
    defer testing.allocator.free(xy);
    const ends = try testing.allocator.alloc(u32, n / 4);
    defer testing.allocator.free(ends);
    _ = rings(land, alaska, xy, ends);
    // A ring drawn straight across 180 has points hundreds of degrees east of
    // the window, thousands of pixels past its right edge.
    for (0..n) |i| try testing.expect(xy[i * 2] < 440 * 3);
}

test "the window maps its corners to the rectangle's corners" {
    const nw = lower48.point(-132, 52);
    const se = lower48.point(-64, 20);
    try testing.expectApproxEqAbs(@as(f64, 0), nw[0], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0), nw[1], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 680), se[0], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 400), se[1], 1e-9);
    // Mercator stretches the north: 36 N is below the middle of 20 to 52.
    try testing.expect(lower48.point(-100, 36)[1] > 200);
}

test "aspect is width over height in Mercator" {
    // A window one degree square on the equator is very nearly square.
    try testing.expectApproxEqAbs(@as(f64, 1), aspect(0, 1, -0.5, 0.5), 1e-4);
    // At 60 N a degree of latitude draws about twice as tall as one of longitude.
    try testing.expectApproxEqAbs(@as(f64, 0.5), aspect(0, 1, 59.5, 60.5), 1e-3);
    try testing.expectEqual(@as(f64, 1), aspect(0, 1, 5, 5));
}
