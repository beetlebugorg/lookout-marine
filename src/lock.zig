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
