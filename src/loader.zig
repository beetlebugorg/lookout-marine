//! A self-contained loading overlay (spinner + "LOADING" word) drawn through the
//! textured-quad pipeline with a 1px white texture — no SDF/text machinery, so it
//! works before any of that exists. Quads are screen-anchored (world = origin, so
//! they land at screen centre; `local` is a pixel offset).
const std = @import("std");
const scene = @import("scene.zig");
const QuadVertex = scene.QuadVertex;

// 5x7 bitmaps (top row first, MSB = left column) for the glyphs "LOADING" needs.
const Glyph = [7]u8;
fn glyph(c: u8) ?Glyph {
    return switch (c) {
        'L' => .{ 0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b11111 },
        'O' => .{ 0b01110, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110 },
        'A' => .{ 0b01110, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b10001 },
        'D' => .{ 0b11110, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b11110 },
        'I' => .{ 0b11111, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b11111 },
        'N' => .{ 0b10001, 0b11001, 0b10101, 0b10011, 0b10001, 0b10001, 0b10001 },
        'G' => .{ 0b01110, 0b10001, 0b10000, 0b10111, 0b10001, 0b10001, 0b01110 },
        else => null,
    };
}

const Color = struct { r: u8 = 255, g: u8 = 255, b: u8 = 255, a: u8 };

fn quad(list: *std.ArrayList(QuadVertex), a: std.mem.Allocator, cx: f32, cy: f32, hw: f32, hh: f32, c: Color) void {
    const corners = [4][2]f32{ .{ cx - hw, cy - hh }, .{ cx + hw, cy - hh }, .{ cx + hw, cy + hh }, .{ cx - hw, cy + hh } };
    var v: [4]QuadVertex = undefined;
    for (0..4) |i| v[i] = .{ .wx = 0, .wy = 0, .lx = corners[i][0], .ly = corners[i][1], .u = 0.5, .v = 0.5, .r = c.r, .g = c.g, .b = c.b, .a = c.a };
    for ([_]usize{ 0, 1, 2, 0, 2, 3 }) |k| list.append(a, v[k]) catch {};
}

/// Rebuild the overlay quads for time `t_ms` into `list` (cleared first).
pub fn build(list: *std.ArrayList(QuadVertex), a: std.mem.Allocator, t_ms: u64) void {
    list.clearRetainingCapacity();
    const t: f32 = @as(f32, @floatFromInt(t_ms % 1000)) / 1000.0;

    // spinner: 12 fading dots in a ring, above the word
    const dots = 12;
    const radius: f32 = 30;
    const cy_ring: f32 = -34;
    for (0..dots) |i| {
        const ang = std.math.tau * @as(f32, @floatFromInt(i)) / dots;
        const phase = @mod(t - @as(f32, @floatFromInt(i)) / dots + 1.0, 1.0);
        const alpha: u8 = @intFromFloat(std.math.clamp(1.0 - phase, 0.15, 1.0) * 235.0);
        quad(list, a, radius * std.math.cos(ang), cy_ring + radius * std.math.sin(ang), 3, 3, .{ .a = alpha });
    }

    // the word "LOADING", centred, below the spinner
    const word = "LOADING";
    const px: f32 = 3; // one font-pixel = 3 screen px
    const gw: f32 = 5 * px;
    const gap: f32 = 2 * px;
    const total = @as(f32, @floatFromInt(word.len)) * (gw + gap) - gap;
    var x = -total / 2.0;
    const y0: f32 = 8;
    for (word) |ch| {
        if (glyph(ch)) |g| {
            for (0..7) |row| {
                for (0..5) |col| {
                    if ((g[row] >> @intCast(4 - col)) & 1 == 1) {
                        quad(list, a, x + @as(f32, @floatFromInt(col)) * px + px / 2, y0 + @as(f32, @floatFromInt(row)) * px + px / 2, px / 2, px / 2, .{ .a = 235 });
                    }
                }
            }
        }
        x += gw + gap;
    }
}
