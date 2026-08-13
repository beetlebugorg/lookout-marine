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

/// A readers-writer lock over `Lock`, for state that is read by several worker
/// threads at once and replaced only rarely.
///
/// It exists for the tile compositor. Composing a tile only READS it (the
/// ownership partition is immutable and the archive readers guard their own
/// lazy state), so any number of workers may compose at once; what must be
/// excluded is the handful of operations that replace the thing being read —
/// opening charts into the list, swapping and closing a composition, trimming
/// the engine's caches, and a pick. Holding one exclusive lock across a compose
/// made four workers behave as one, and a view's worth of tiles arrived one
/// after another.
///
/// Hand-rolled, like `Lock` above and for the same reason: Zig 0.16 has no
/// std.Thread.RwLock outside an Io, and a zeroed pthread_rwlock_t is not a
/// valid initializer on Darwin (unlike pthread_mutex_t), so it would need a
/// real init call and a matching destroy.
///
/// Writers take priority: once one is waiting, no further reader may enter, so
/// a steady stream of tiles cannot starve a close. The wait is a 1 ms poll
/// rather than a condition variable, which is the same trade the tile workers
/// already make; writers here are rare and readers never wait on each other.
pub const RwLock = struct {
    mu: Lock = .{},
    readers: u32 = 0,
    writer: bool = false,
    writer_waiting: bool = false,

    pub fn lockShared(self: *RwLock) void {
        while (true) {
            self.mu.lock();
            if (!self.writer and !self.writer_waiting) {
                self.readers += 1;
                self.mu.unlock();
                return;
            }
            self.mu.unlock();
            sleepMs(1);
        }
    }

    pub fn unlockShared(self: *RwLock) void {
        self.mu.lock();
        self.readers -= 1;
        self.mu.unlock();
    }

    /// Exclusive. Named `lock`/`unlock` so an exclusive user reads exactly as
    /// it did when this was a plain Lock.
    pub fn lock(self: *RwLock) void {
        self.mu.lock();
        self.writer_waiting = true;
        self.mu.unlock();
        while (true) {
            self.mu.lock();
            if (!self.writer and self.readers == 0) {
                self.writer = true;
                self.writer_waiting = false;
                self.mu.unlock();
                return;
            }
            self.mu.unlock();
            sleepMs(1);
        }
    }

    pub fn unlock(self: *RwLock) void {
        self.mu.lock();
        self.writer = false;
        self.mu.unlock();
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
