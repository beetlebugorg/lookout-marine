//! Colours the core adds to the S-52 palette, by token and scheme.
//!
//! The S-52 tables have no ramp for the six usage bands, so the chart panels
//! read these instead of typing hex in. lookout_s52_color looks here first,
//! then in the engine's colortables.

const std = @import("std");

const Entry = struct {
    token: []const u8,
    day: u24,
    dusk: u24,
    night: u24,
};

/// The usage band ramp, BAND1 (overview) to BAND6 (berthing). In the day
/// scheme it is the S-52 depth ramp read as coarse to fine: BAND2 to BAND5 are
/// DEPDW, DEPMD, DEPMS and DEPVS, with a paler overview and a deeper berthing
/// blue at the ends. The S-52 dusk and night depth shades run to black, so
/// those schemes have their own ramp of blues, dimmest at BAND1, and night
/// dimmer than dusk.
const table = [_]Entry{
    .{ .token = "BAND1", .day = 0xE4F5FF, .dusk = 0x1A2D40, .night = 0x0A131C },
    .{ .token = "BAND2", .day = 0xC9EDFF, .dusk = 0x203D59, .night = 0x0D1A27 },
    .{ .token = "BAND3", .day = 0xA7D9FB, .dusk = 0x274F77, .night = 0x112234 },
    .{ .token = "BAND4", .day = 0x82CAFF, .dusk = 0x2F6397, .night = 0x152B43 },
    .{ .token = "BAND5", .day = 0x61B7FF, .dusk = 0x3A78B8, .night = 0x1A3552 },
    .{ .token = "BAND6", .day = 0x2F8FE0, .dusk = 0x4A90D9, .night = 0x1F3F63 },
};

/// One of the core's colours as RGBA in 0..1, or null for a token this table
/// does not hold. `scheme` is "day", "dusk" or "night".
pub fn color(token: []const u8, scheme: []const u8) ?[4]f32 {
    for (table) |e| {
        if (!std.mem.eql(u8, e.token, token)) continue;
        const rgb = if (std.mem.eql(u8, scheme, "dusk"))
            e.dusk
        else if (std.mem.eql(u8, scheme, "night"))
            e.night
        else
            e.day;
        return .{
            @as(f32, @floatFromInt((rgb >> 16) & 0xff)) / 255.0,
            @as(f32, @floatFromInt((rgb >> 8) & 0xff)) / 255.0,
            @as(f32, @floatFromInt(rgb & 0xff)) / 255.0,
            1,
        };
    }
    return null;
}

const t = std.testing;

test "every band has a colour in every scheme" {
    for ([_][]const u8{ "BAND1", "BAND2", "BAND3", "BAND4", "BAND5", "BAND6" }) |token| {
        for ([_][]const u8{ "day", "dusk", "night" }) |scheme| {
            const c = color(token, scheme) orelse return error.TestUnexpectedResult;
            try t.expectEqual(@as(f32, 1), c[3]);
        }
    }
}

test "the day ramp is the S-52 depth ramp" {
    // DEPVS in the day table is #61B7FF.
    const c = color("BAND5", "day").?;
    try t.expectApproxEqAbs(@as(f32, 0x61) / 255.0, c[0], 1e-6);
    try t.expectApproxEqAbs(@as(f32, 0xB7) / 255.0, c[1], 1e-6);
    try t.expectApproxEqAbs(@as(f32, 1), c[2], 1e-6);
}

test "each scheme has its own ramp" {
    const day = color("BAND6", "day").?;
    const dusk = color("BAND6", "dusk").?;
    const night = color("BAND6", "night").?;
    try t.expect(day[2] != dusk[2]);
    // Night is dimmer than dusk.
    try t.expect(night[2] < dusk[2]);
}

test "the finer the band, the further the colour from the page" {
    // Day paper is light, so a finer band is darker. Dusk and night paper is
    // dark, so a finer band is lighter.
    var last_day: f32 = 4;
    var last_dusk: f32 = -1;
    var last_night: f32 = -1;
    for ([_][]const u8{ "BAND1", "BAND2", "BAND3", "BAND4", "BAND5", "BAND6" }) |token| {
        const d = color(token, "day").?;
        const k = color(token, "dusk").?;
        const n = color(token, "night").?;
        try t.expect(d[0] + d[1] + d[2] < last_day);
        try t.expect(k[0] + k[1] + k[2] > last_dusk);
        try t.expect(n[0] + n[1] + n[2] > last_night);
        last_day = d[0] + d[1] + d[2];
        last_dusk = k[0] + k[1] + k[2];
        last_night = n[0] + n[1] + n[2];
    }
}

test "a token the core does not add is not here" {
    try t.expect(color("DEPVS", "day") == null);
    try t.expect(color("BAND7", "day") == null);
    try t.expect(color("", "night") == null);
}
