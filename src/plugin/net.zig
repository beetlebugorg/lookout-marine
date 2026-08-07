//! The platform socket layer the plugin I/O uses. TCP, UDP, poll, name
//! resolution and the two kernel32 clocks, stated once for POSIX and once for
//! Winsock.
//!
//! WHY THIS IS ITS OWN FILE. broker.zig owns the poll loop and webio.zig owns
//! HTTP and WebSocket framing, and both need the same sockets. Everything
//! platform-specific about a plugin socket is here and nowhere else.
//!
//! POSIX and Winsock disagree on four things that reach the caller. A handle is
//! a small signed fd on POSIX and an opaque unsigned SOCKET on Windows, so -1 is
//! not the sentinel and `>= 0` is not the test — hence `invalid` and `valid`. An
//! error is in errno on POSIX and in WSAGetLastError on Windows. read/write
//! serve any POSIX fd but no Windows socket, which needs recv/send. And a socket
//! timeout is a timeval on POSIX and a millisecond DWORD on Windows. Two flags
//! say where the two poll calls differ; the broker reads them, so the difference
//! is stated once.

const std = @import("std");
const builtin = @import("builtin");

/// One resolved candidate address, copied out of the resolver's own list so
/// that list is freed before the connect. 128 bytes is a sockaddr_storage.
pub const Addr = struct {
    family: i32,
    socktype: i32,
    protocol: i32,
    len: u32,
    raw: [128]u8 align(8),
};

/// Candidates kept per name. A name with more records than this keeps the
/// first eight; the rest are not tried.
pub const max_addrs = 8;

const impl = if (builtin.os.tag == .windows) @import("net_windows.zig") else @import("net_posix.zig");

pub const Socket = impl.Socket;
pub const invalid = impl.invalid;
pub const pollfd = impl.pollfd;
pub const POLL = impl.POLL;
pub const poll_misses_connect_error = impl.poll_misses_connect_error;
pub const poll_needs_events = impl.poll_needs_events;

pub const valid = impl.valid;
pub const poll = impl.poll;
pub const close = impl.close;
pub const setNonBlocking = impl.setNonBlocking;
pub const setBlocking = impl.setBlocking;
pub const setTimeouts = impl.setTimeouts;
pub const recv = impl.recv;
pub const send = impl.send;
pub const retryable = impl.retryable;
pub const soError = impl.soError;
pub const shutdownWrite = impl.shutdownWrite;
pub const shutdownBoth = impl.shutdownBoth;
pub const resolve = impl.resolve;
pub const resolveNumeric = impl.resolveNumeric;
pub const socket = impl.socket;
pub const connect = impl.connect;
pub const wakePair = impl.wakePair;
pub const drainWake = impl.drainWake;
pub const listen4 = impl.listen4;
pub const accept = impl.accept;
pub const udpBind = impl.udpBind;
pub const udpSendTo = impl.udpSendTo;
pub const udpRecv = impl.udpRecv;
pub const udpPort = impl.udpPort;

/// Resolve `host` and start a NON-BLOCKING connect. The socket comes back
/// mid-handshake; the caller's poll loop completes it on POLLOUT.
pub fn dial(host: []const u8, port: u16) !Socket {
    var addrs: [max_addrs]Addr = undefined;
    const n = try resolve(host, port, &addrs);
    for (addrs[0..n]) |*a| {
        const s = socket(a);
        if (!valid(s)) continue;
        setNonBlocking(s);
        if (connect(s, a)) return s;
        close(s);
    }
    return error.ConnectFailed;
}

/// Resolve `host`, connect, and hand back a BLOCKING socket with `timeout_ms`
/// on every later read and write. For a thread that owns one socket and nothing
/// else: an HTTP fetch or a WebSocket. The poll loop uses `dial` instead.
///
/// The connect itself is made non-blocking and waited for with a poll, because
/// the kernel's own connect timeout is over a minute on macOS and a fetch that
/// hangs for a minute holds the application's shutdown for a minute.
pub fn dialBlocking(host: []const u8, port: u16, timeout_ms: u32) !Socket {
    var addrs: [max_addrs]Addr = undefined;
    const n = try resolve(host, port, &addrs);
    for (addrs[0..n]) |*a| {
        const s = socket(a);
        if (!valid(s)) continue;
        setNonBlocking(s);
        if (!connect(s, a)) {
            close(s);
            continue;
        }
        var fds = [_]pollfd{.{ .fd = s, .events = POLL.OUT, .revents = 0 }};
        if (poll(&fds, @intCast(timeout_ms)) == 0 or soError(s) != 0) {
            close(s);
            continue;
        }
        setBlocking(s);
        setTimeouts(s, timeout_ms);
        return s;
    }
    return error.ConnectFailed;
}

/// kernel32 entry points. Declared here rather than taken from std: Zig 0.16's
/// std.os.windows.kernel32 carries none of them, and the WINAPI convention is
/// required for a correct x86 build (src/lock.zig takes the same posture).
pub const win = struct {
    pub extern "kernel32" fn Sleep(ms: u32) callconv(.winapi) void;
    pub extern "kernel32" fn QueryPerformanceCounter(v: *i64) callconv(.winapi) i32;
    pub extern "kernel32" fn QueryPerformanceFrequency(v: *i64) callconv(.winapi) i32;
    pub extern "kernel32" fn GetSystemTimeAsFileTime(ft: *[2]u32) callconv(.winapi) void;
};
