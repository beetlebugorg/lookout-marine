//! How deep a stack went: for the tests that hold the frame path to the stack
//! a shell's UI thread has left.
//!
//! `paint` fills `len` bytes below its caller's frame with a fixed byte and
//! returns where they start. Code run after it, from the same frame, writes
//! over the bytes it uses. `depth` then finds the deepest byte that changed.
//! The count includes every frame under the caller, a GPU driver's as well
//! as Lookout's.
//!
//! A thread's size cannot stand in for this. glibc places the thread's static
//! TLS inside the stack it allocates, and a GPU driver's libraries can hold
//! more static TLS than a small stack has, so pthread_create refuses it.

const std = @import("std");

pub const fill: u8 = 0xA5;

/// Fill `len` bytes of stack below the caller's frame. Returns the lowest
/// address filled.
pub noinline fn paint(comptime len: usize) usize {
    var buf: [len]u8 = undefined;
    @memset(&buf, fill);
    std.mem.doNotOptimizeAway(&buf);
    return @intFromPtr(&buf);
}

/// How many bytes below the top of the painted region have been written since
/// `paint` returned `lo`.
pub fn depth(lo: usize, len: usize) usize {
    const p: [*]const volatile u8 = @ptrFromInt(lo);
    var i: usize = 0;
    while (i < len and p[i] == fill) i += 1;
    return len - i;
}
