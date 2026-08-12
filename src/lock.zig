//! A kernel-blocking lock, shared by the layers that take no Io.
//!
//! Zig 0.16 moved std.Thread.Mutex behind an Io, which neither the engine-entry
//! locks in root.zig nor the raster worker in raster.zig take. Lifted out of
//! root.zig so both use one definition rather than two that can drift.

const std = @import("std");
const builtin = @import("builtin");

// A kernel-blocking lock for api_mu / engine_mu (NOT a spin). On Darwin that's
// os_unfair_lock — Zig 0.16's std.Thread.Mutex spins there, and this layer takes
// no Io. Everywhere else (Android/Linux/Windows) std.Thread.Mutex is the futex
// path, which is also kernel-blocking. os_unfair_lock is Apple-only, so it must
// not reach a non-Apple link.
pub const Lock = if (@import("builtin").os.tag.isDarwin())
    struct {
        const Handle = extern struct { v: u32 = 0 };
        extern "c" fn os_unfair_lock_lock(l: *Handle) void;
        extern "c" fn os_unfair_lock_unlock(l: *Handle) void;
        h: Handle = .{},
        pub fn lock(self: *@This()) void {
            os_unfair_lock_lock(&self.h);
        }
        pub fn unlock(self: *@This()) void {
            os_unfair_lock_unlock(&self.h);
        }
    }
else if (builtin.os.tag == .windows)
    struct {
        // No pthread in the MSVC CRT. SRWLOCK is the direct analog: a single
        // pointer that zero-inits to SRWLOCK_INIT (no init call, like the zeroed
        // pthread_mutex_t below), kernel-blocking, non-recursive.
        // WINAPI convention (stdcall on x86, C on x64/aarch64) — required for a
        // correct x86 build.
        extern "kernel32" fn AcquireSRWLockExclusive(srw: *?*anyopaque) callconv(.winapi) void;
        extern "kernel32" fn ReleaseSRWLockExclusive(srw: *?*anyopaque) callconv(.winapi) void;
        m: ?*anyopaque = null, // SRWLOCK; null == SRWLOCK_INIT
        pub fn lock(self: *@This()) void {
            AcquireSRWLockExclusive(&self.m);
        }
        pub fn unlock(self: *@This()) void {
            ReleaseSRWLockExclusive(&self.m);
        }
    }
else
    struct {
        // Zig 0.16 has no std.Thread.Mutex (it moved behind an Io this layer
        // doesn't take), so use pthread directly. A zeroed pthread_mutex_t is
        // PTHREAD_MUTEX_INITIALIZER on Linux/bionic — kernel-blocking, no init call.
        extern "c" fn pthread_mutex_lock(m: *std.c.pthread_mutex_t) c_int;
        extern "c" fn pthread_mutex_unlock(m: *std.c.pthread_mutex_t) c_int;
        m: std.c.pthread_mutex_t = std.mem.zeroes(std.c.pthread_mutex_t),
        pub fn lock(self: *@This()) void {
            _ = pthread_mutex_lock(&self.m);
        }
        pub fn unlock(self: *@This()) void {
            _ = pthread_mutex_unlock(&self.m);
        }
    };

/// A signalable wake-up for a worker that owns a loop: wait with a timeout,
/// wake instantly on signal. The instantly matters — a sleep-poll adds up to
/// its whole period of latency to every wake, which on a render thread reads
/// as gesture stutter. Darwin: a GCD semaphore (pthread condvars need runtime
/// init there — zeroed pthread types are invalid). Elsewhere: a paced sleep
/// fallback until those ports land; the semantics degrade to the old poll.
pub const WakeEvent = if (builtin.os.tag.isDarwin())
    struct {
        extern "c" fn dispatch_semaphore_create(value: isize) ?*anyopaque;
        extern "c" fn dispatch_semaphore_wait(sema: *anyopaque, timeout: u64) isize;
        extern "c" fn dispatch_semaphore_signal(sema: *anyopaque) isize;
        extern "c" fn dispatch_time(when: u64, delta: i64) u64;
        sema: ?*anyopaque = null,

        /// Create the semaphore. Call once, before any signal/wait can race.
        pub fn init(self: *@This()) void {
            self.sema = dispatch_semaphore_create(0);
        }
        pub fn signal(self: *@This()) void {
            if (self.sema) |s| _ = dispatch_semaphore_signal(s);
        }
        /// Wait up to `ms`; returns early on signal.
        pub fn waitMs(self: *@This(), ms: u32) void {
            const s = self.sema orelse return sleepMs(@min(ms, 12));
            _ = dispatch_semaphore_wait(s, dispatch_time(0, @as(i64, ms) * std.time.ns_per_ms));
        }
        /// Consume any backlog of signals without waiting. A waiter that acts
        /// once per wake-up drains after acting, so a burst of signals during
        /// the action becomes ONE further wake-up, not a queue of stale ones.
        pub fn drain(self: *@This()) void {
            const s = self.sema orelse return;
            while (dispatch_semaphore_wait(s, dispatch_time(0, 0)) == 0) {}
        }
    }
else
    struct {
        pub fn init(_: *@This()) void {}
        pub fn signal(_: *@This()) void {}
        pub fn waitMs(_: *@This(), ms: u32) void {
            sleepMs(@min(ms, 12));
        }
        pub fn drain(_: *@This()) void {}
    };

/// Monotonic milliseconds, for rate limits and frame timing. Zig 0.16's
/// std.time moved behind an Io this layer does not take, so straight to the
/// platform. Monotonic on purpose: wall-clock steps would break rate limits.
/// timespec is {time_t, long} — isize matches both fields on ILP32 (armv7)
/// and LP64, unlike a hardcoded 64-bit tv_sec.
pub fn nowMs() i64 {
    if (comptime builtin.os.tag == .windows) {
        const k = struct {
            extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
        };
        return @intCast(k.GetTickCount64());
    }
    const Timespec = extern struct { sec: isize, nsec: isize };
    const c = struct {
        extern "c" fn clock_gettime(id: c_int, ts: *Timespec) c_int;
    };
    // CLOCK_MONOTONIC: 6 on Darwin, 1 everywhere else POSIX.
    const clock_id: c_int = if (comptime builtin.os.tag.isDarwin()) 6 else 1;
    var ts: Timespec = undefined;
    _ = c.clock_gettime(clock_id, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

/// Hand freed-but-cached malloc pages back to the OS. Darwin-only libmalloc
/// call; a no-op elsewhere (Linux/Windows allocators return large frees on
/// their own). Guarded here so non-Darwin ports never see the symbol.
pub fn memoryPressureRelief() void {
    if (comptime builtin.os.tag.isDarwin()) {
        const m = struct {
            extern "c" fn malloc_zone_pressure_relief(zone: ?*anyopaque, goal: usize) usize;
        };
        _ = m.malloc_zone_pressure_relief(null, 0);
    }
}

/// Pin the CALLING thread's Darwin QoS class. A no-op elsewhere. The render
/// thread runs user-interactive so tile work can never preempt a frame; the
/// compose workers run user-initiated — fast, but always below the frame.
pub const QosClass = enum(c_uint) { user_interactive = 0x21, user_initiated = 0x19, utility = 0x11 };
pub fn setThreadQos(class: QosClass) void {
    if (comptime builtin.os.tag.isDarwin()) {
        const q = struct {
            extern "c" fn pthread_set_qos_class_self_np(qos_class: c_uint, relative_priority: c_int) c_int;
        };
        _ = q.pthread_set_qos_class_self_np(@intFromEnum(class), 0);
    }
}

/// Sleep the calling thread, for a worker with nothing to do. Zig 0.16's
/// std.Thread.sleep is behind the same Io as its mutex, so this goes straight to
/// the platform: usleep on POSIX, Sleep on Windows.
pub fn sleepMs(ms: u32) void {
    if (builtin.os.tag == .windows) {
        const k = struct {
            extern "kernel32" fn Sleep(ms: u32) callconv(.winapi) void;
        };
        k.Sleep(ms);
    } else {
        const p = struct {
            extern "c" fn usleep(usec: u32) c_int;
        };
        _ = p.usleep(ms * 1000);
    }
}
