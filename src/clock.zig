//! The clocks: the wall clock in milliseconds since the Unix epoch, and the
//! monotonic tick the frame loop measures itself against.
//!
//! Zig 0.16 has no `std.time.milliTimestamp`, so this reads the platform clock
//! directly. It lives here rather than in the plugin host because a build with
//! `-Dplugins=false` still stamps markers and still needs the time.

const std = @import("std");
const builtin = @import("builtin");

const win = struct {
    pub extern "kernel32" fn GetSystemTimeAsFileTime(ft: *[2]u32) callconv(.winapi) void;
    pub extern "kernel32" fn QueryPerformanceCounter(count: *i64) callconv(.winapi) c_int;
    pub extern "kernel32" fn QueryPerformanceFrequency(freq: *i64) callconv(.winapi) c_int;

    /// The monotonic tick, in microseconds. Windows has no clock_gettime —
    /// the MSVC CRT never declared one — so this is the performance counter.
    pub fn monotonicUs() i64 {
        var ctr: i64 = 0;
        var freq: i64 = 0;
        _ = QueryPerformanceCounter(&ctr);
        _ = QueryPerformanceFrequency(&freq);
        if (freq == 0) return 0;
        // Split the divide so a large counter x 1e6 cannot overflow i64.
        return @divTrunc(ctr, freq) * 1_000_000 + @divTrunc(@rem(ctr, freq) * 1_000_000, freq);
    }
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

/// Monotonic milliseconds from an arbitrary epoch. What every timer in the
/// core counts against: an animation, a fade, a backoff. Never the wall clock,
/// which steps when the system clock is set.
pub fn ticksMs() i64 {
    if (comptime builtin.os.tag == .windows) return @divTrunc(win.monotonicUs(), 1000);
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

/// Monotonic microseconds — frame-cost timing needs sub-ms resolution.
pub fn ticksUs() i64 {
    if (comptime builtin.os.tag == .windows) return win.monotonicUs();
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(i64, ts.sec) * 1_000_000 + @divTrunc(@as(i64, ts.nsec), 1_000);
}
