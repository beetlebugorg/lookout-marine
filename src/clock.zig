//! The wall clock, in milliseconds since the Unix epoch.
//!
//! Zig 0.16 has no `std.time.milliTimestamp`, so this reads the platform clock
//! directly. It lives here rather than in the plugin host because a build with
//! `-Dplugins=false` still stamps markers and still needs the time.

const std = @import("std");
const builtin = @import("builtin");

const win = struct {
    pub extern "kernel32" fn GetSystemTimeAsFileTime(ft: *[2]u32) callconv(.winapi) void;
};

/// Milliseconds since 1970-01-01 UTC, or 0 when the platform clock cannot be
/// read. A `ts` on the plugin wire means this, and so does a marker's stamp.
pub fn wallMs() i64 {
    if (comptime builtin.os.tag == .windows) {
        // FILETIME counts 100 ns ticks from 1601-01-01. 11644473600 seconds
        // separate that epoch from the Unix one.
        var ft: [2]u32 = .{ 0, 0 };
        win.GetSystemTimeAsFileTime(&ft);
        const ticks = (@as(u64, ft[1]) << 32) | ft[0];
        return @intCast(@divTrunc(ticks, 10_000) -% 11_644_473_600_000);
    } else {
        var ts: std.c.timespec = undefined;
        if (std.c.clock_gettime(.REALTIME, &ts) != 0) return 0;
        return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
    }
}
