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
