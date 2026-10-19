//! Minimal RGBA8 PNG writer (uncompressed DEFLATE stored blocks). Enough to dump
//! offscreen GPU readbacks on a headless box — not a general encoder.
const std = @import("std");

fn adler32(data: []const u8) u32 {
    var a: u32 = 1;
    var b: u32 = 0;
    for (data) |x| {
        a = (a + x) % 65521;
        b = (b + a) % 65521;
    }
    return (b << 16) | a;
}

fn beU32(w: *std.ArrayList(u8), a: std.mem.Allocator, v: u32) !void {
    try w.append(a, @intCast((v >> 24) & 0xff));
    try w.append(a, @intCast((v >> 16) & 0xff));
    try w.append(a, @intCast((v >> 8) & 0xff));
    try w.append(a, @intCast(v & 0xff));
}

fn chunk(w: *std.ArrayList(u8), a: std.mem.Allocator, typ: []const u8, data: []const u8) !void {
    try beU32(w, a, @intCast(data.len));
    const start = w.items.len;
    try w.appendSlice(a, typ);
    try w.appendSlice(a, data);
    const crc = std.hash.Crc32.hash(w.items[start..]);
    try beU32(w, a, crc);
}

/// Write an RGBA8 image (top-to-bottom rows) as a PNG file.
pub fn write(a: std.mem.Allocator, path: []const u8, px: []const u8, width: u32, height: u32) !void {
    std.debug.assert(px.len == @as(usize, width) * height * 4);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try out.appendSlice(a, &.{ 137, 80, 78, 71, 13, 10, 26, 10 });

    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], width, .big);
    std.mem.writeInt(u32, ihdr[4..8], height, .big);
    ihdr[8] = 8; // bit depth
    ihdr[9] = 6; // color type RGBA
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = 0;
    try chunk(&out, a, "IHDR", &ihdr);

    // raw (filtered) scanlines: filter byte 0 + row
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(a);
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        try raw.append(a, 0);
        try raw.appendSlice(a, px[y * width * 4 .. (y + 1) * width * 4]);
    }
    // zlib stream: header + stored deflate blocks + adler32
    var zl: std.ArrayList(u8) = .empty;
    defer zl.deinit(a);
    try zl.appendSlice(a, &.{ 0x78, 0x01 });
    var off: usize = 0;
    while (off < raw.items.len) {
        const n: usize = @min(raw.items.len - off, 65535);
        const final: u8 = if (off + n >= raw.items.len) 1 else 0;
        try zl.append(a, final); // BTYPE=00 stored
        try zl.append(a, @intCast(n & 0xff));
        try zl.append(a, @intCast((n >> 8) & 0xff));
        try zl.append(a, @intCast((~n) & 0xff));
        try zl.append(a, @intCast(((~n) >> 8) & 0xff));
        try zl.appendSlice(a, raw.items[off .. off + n]);
        off += n;
    }
    try beU32(&zl, a, adler32(raw.items));
    try chunk(&out, a, "IDAT", zl.items);
    try chunk(&out, a, "IEND", "");

    const io = std.Io.Threaded.global_single_threaded.io();
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out.items });
}

/// Encode an RGBA8 image (top-to-bottom rows) as PNG bytes. Owned by `a`.
///
/// The deflate is `deflateRuns`, which keeps no tables. std's compressor is
/// a 230 KB struct that its init returns by value, so it is in the frame of
/// every caller it is inlined into. One of those callers is the frame step on
/// a shell's UI thread, which has 1 MB on Windows.
pub fn encode(a: std.mem.Allocator, px: []const u8, width: u32, height: u32) ![]u8 {
    std.debug.assert(px.len == @as(usize, width) * height * 4);
    const row = @as(usize, width) * 4;

    // Filter byte 0 (none), then the row.
    const raw = try a.alloc(u8, px.len + height);
    defer a.free(raw);
    var y: usize = 0;
    while (y < height) : (y += 1) {
        const at = y * (row + 1);
        raw[at] = 0;
        @memcpy(raw[at + 1 .. at + 1 + row], px[y * row .. (y + 1) * row]);
    }

    var zl: std.ArrayList(u8) = .empty;
    defer zl.deinit(a);
    try zl.appendSlice(a, &.{ 0x78, 0x01 });
    try deflateRuns(a, &zl, raw);
    try beU32(&zl, a, adler32(raw));

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, &.{ 137, 80, 78, 71, 13, 10, 26, 10 });
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], width, .big);
    std.mem.writeInt(u32, ihdr[4..8], height, .big);
    ihdr[8] = 8; // bit depth
    ihdr[9] = 6; // color type RGBA
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = 0;
    try chunk(&out, a, "IHDR", &ihdr);
    try chunk(&out, a, "IDAT", zl.items);
    try chunk(&out, a, "IEND", "");
    return out.toOwnedSlice(a);
}

/// Deflate bits, least significant first, as RFC 1951 packs them.
const Bits = struct {
    out: *std.ArrayList(u8),
    a: std.mem.Allocator,
    acc: u64 = 0,
    n: u6 = 0,

    fn put(self: *Bits, bits: u32, count: u6) !void {
        self.acc |= @as(u64, bits) << self.n;
        self.n += count;
        while (self.n >= 8) {
            try self.out.append(self.a, @truncate(self.acc));
            self.acc >>= 8;
            self.n -= 8;
        }
    }

    /// A Huffman code. These are packed most significant bit first.
    fn code(self: *Bits, c: u32, len: u6) !void {
        try self.put(@bitReverse(c) >> @intCast(32 - @as(u32, len)), len);
    }

    /// A literal byte, a length symbol or the end of block, in the fixed
    /// code of RFC 1951 3.2.6.
    fn sym(self: *Bits, s: u16) !void {
        if (s < 144) return self.code(0x30 + @as(u32, s), 8);
        if (s < 256) return self.code(0x190 + @as(u32, s - 144), 9);
        if (s < 280) return self.code(s - 256, 7);
        return self.code(0xC0 + @as(u32, s - 280), 8);
    }

    fn flush(self: *Bits) !void {
        if (self.n > 0) try self.out.append(self.a, @truncate(self.acc));
        self.acc = 0;
        self.n = 0;
    }
};

const len_base = [29]u16{ 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 };
const len_extra = [29]u6{ 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 };

/// One fixed-code block of `raw`. The only match is a repeat of the 4 bytes
/// before, a run of one color in an RGBA row.
fn deflateRuns(a: std.mem.Allocator, out: *std.ArrayList(u8), raw: []const u8) !void {
    var b: Bits = .{ .out = out, .a = a };
    try b.put(1, 1); // BFINAL
    try b.put(1, 2); // BTYPE 01: fixed codes
    var i: usize = 0;
    while (i < raw.len) {
        var n: usize = 0;
        if (i >= 4) {
            while (n < 258 and i + n < raw.len and raw[i + n] == raw[i + n - 4]) n += 1;
        }
        if (n < 3) {
            try b.sym(raw[i]);
            i += 1;
            continue;
        }
        var k: usize = len_base.len - 1;
        while (len_base[k] > n) k -= 1;
        try b.sym(@intCast(257 + k));
        try b.put(@intCast(n - len_base[k]), len_extra[k]);
        try b.code(3, 5); // distance 4
        i += n;
    }
    try b.sym(256);
    try b.flush();
}

const t = std.testing;

fn inflated(a: std.mem.Allocator, zlib: []const u8) ![]u8 {
    var in: std.Io.Reader = .fixed(zlib);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var d: std.compress.flate.Decompress = .init(&in, .zlib, &window);
    return d.reader.allocRemaining(a, .unlimited);
}

/// The IDAT payload of a PNG `encode` wrote. It writes one IDAT.
fn idat(png: []const u8) []const u8 {
    const len = std.mem.readInt(u32, png[33..37], .big);
    return png[41 .. 41 + len];
}

test "an encoded image inflates to its rows" {
    const a = t.allocator;
    const w = 37;
    const h = 5;
    var px: [w * h * 4]u8 = undefined;
    // Runs of one color, a stripe that changes every pixel, and runs longer
    // than one match.
    for (0..h) |y| for (0..w) |x| {
        const at = (y * w + x) * 4;
        const c: [4]u8 = if (y == 2) .{ @intCast(x), @intCast(x * 7), 3, 255 } else if (x < 20) .{ 10, 20, 30, 255 } else .{ 200, 100, 50, 128 };
        @memcpy(px[at .. at + 4], &c);
    };
    const png = try encode(a, &px, w, h);
    defer a.free(png);

    const raw = try inflated(a, idat(png));
    defer a.free(raw);
    try t.expectEqual(@as(usize, (w * 4 + 1) * h), raw.len);
    for (0..h) |y| {
        const r = raw[y * (w * 4 + 1) ..][0 .. w * 4 + 1];
        try t.expectEqual(@as(u8, 0), r[0]);
        try t.expectEqualSlices(u8, px[y * w * 4 .. (y + 1) * w * 4], r[1..]);
    }
}

test "a flat image deflates to a small fraction of its size" {
    const a = t.allocator;
    const w = 256;
    const h = 256;
    const px = try a.alloc(u8, w * h * 4);
    defer a.free(px);
    for (0..w * h) |i| @memcpy(px[i * 4 ..][0..4], &[4]u8{ 90, 140, 200, 255 });
    const png = try encode(a, px, w, h);
    defer a.free(png);
    try t.expect(png.len < px.len / 50);
    const raw = try inflated(a, idat(png));
    defer a.free(raw);
    try t.expectEqual(@as(usize, (w * 4 + 1) * h), raw.len);
}
