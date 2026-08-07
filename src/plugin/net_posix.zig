//! The POSIX half of the plugin socket layer. `net.zig` selects between this
//! and `net_windows.zig`; nothing else imports it.

const std = @import("std");
const net = @import("net.zig");

const Addr = net.Addr;
const max_addrs = net.max_addrs;

pub const Socket = std.c.fd_t;
pub const invalid: Socket = -1;
pub const pollfd = std.c.pollfd;
pub const POLL = std.c.POLL;
/// poll reports a failed connect as POLLERR/POLLHUP, and accepts an entry
/// that asks for nothing.
pub const poll_misses_connect_error = false;
pub const poll_needs_events = false;

pub fn valid(s: Socket) bool {
    return s >= 0;
}

pub fn poll(fds: []pollfd, timeout_ms: i32) usize {
    return std.posix.poll(fds, timeout_ms) catch 0;
}

pub fn close(s: Socket) void {
    _ = std.c.close(s);
}

pub fn setNonBlocking(s: Socket) void {
    const flags = std.c.fcntl(s, std.c.F.GETFL, @as(c_int, 0));
    if (flags < 0) return;
    const nonblock: c_int = @bitCast(@as(u32, @bitCast(std.c.O{ .NONBLOCK = true })));
    _ = std.c.fcntl(s, std.c.F.SETFL, flags | nonblock);
}

pub fn setBlocking(s: Socket) void {
    const flags = std.c.fcntl(s, std.c.F.GETFL, @as(c_int, 0));
    if (flags < 0) return;
    const nonblock: c_int = @bitCast(@as(u32, @bitCast(std.c.O{ .NONBLOCK = true })));
    _ = std.c.fcntl(s, std.c.F.SETFL, flags & ~nonblock);
}

/// A read and a write deadline, so a thread that owns one socket cannot be
/// held by a peer that stops talking.
pub fn setTimeouts(s: Socket, timeout_ms: u32) void {
    var tv = std.c.timeval{
        .sec = @intCast(timeout_ms / 1000),
        .usec = @intCast((timeout_ms % 1000) * 1000),
    };
    _ = std.c.setsockopt(s, std.c.SOL.SOCKET, std.c.SO.RCVTIMEO, &tv, @sizeOf(@TypeOf(tv)));
    _ = std.c.setsockopt(s, std.c.SOL.SOCKET, std.c.SO.SNDTIMEO, &tv, @sizeOf(@TypeOf(tv)));
}

/// Bytes read, 0 for the peer's EOF, -1 for an error.
pub fn recv(s: Socket, buf: []u8) isize {
    return std.c.read(s, buf.ptr, buf.len);
}

/// Bytes written, or -1.
pub fn send(s: Socket, buf: []const u8) isize {
    return std.c.write(s, buf.ptr, buf.len);
}

/// Whether the last recv/send failed only because it would have blocked.
pub fn retryable() bool {
    const e = std.c.errno(@as(c_int, -1));
    return e == .AGAIN or e == .INTR;
}

pub fn soError(s: Socket) i32 {
    var err: i32 = 0;
    var len: std.c.socklen_t = @sizeOf(i32);
    _ = std.c.getsockopt(s, std.c.SOL.SOCKET, std.c.SO.ERROR, &err, &len);
    return err;
}

pub fn shutdownWrite(s: Socket) void {
    _ = std.c.shutdown(s, 1);
}

/// Break a socket in both directions WITHOUT closing it. A thread blocked in
/// recv returns at once, and the descriptor stays valid for the thread that
/// owns it to close in its own time.
pub fn shutdownBoth(s: Socket) void {
    _ = std.c.shutdown(s, 2);
}

fn lookup(host: []const u8, port: u16, out: *[max_addrs]Addr, socktype: i32, numeric: bool) !usize {
    var host_z: [256]u8 = undefined;
    if (host.len >= host_z.len) return error.HostTooLong;
    @memcpy(host_z[0..host.len], host);
    host_z[host.len] = 0;
    var port_z: [8]u8 = undefined;
    const ps = try std.fmt.bufPrintZ(&port_z, "{d}", .{port});

    var hints: std.c.addrinfo = std.mem.zeroes(std.c.addrinfo);
    hints.family = std.c.AF.UNSPEC;
    hints.socktype = socktype;
    // AI_NUMERICHOST. The value is 4 on Darwin, the BSDs and glibc.
    if (numeric) hints.flags = @bitCast(@as(u32, 4));
    var res: ?*std.c.addrinfo = null;
    if (std.c.getaddrinfo(@ptrCast(&host_z), ps.ptr, &hints, &res) != @as(std.c.EAI, @enumFromInt(0)))
        return error.ResolveFailed;
    const list = res orelse return error.ResolveFailed;
    defer std.c.freeaddrinfo(list);

    var n: usize = 0;
    var it: ?*std.c.addrinfo = list;
    while (it) |ai| : (it = ai.next) {
        if (n == out.len) break;
        const addr = ai.addr orelse continue;
        if (ai.addrlen > out[n].raw.len) continue;
        out[n] = .{
            .family = @intCast(ai.family),
            .socktype = @intCast(ai.socktype),
            .protocol = @intCast(ai.protocol),
            .len = @intCast(ai.addrlen),
            .raw = undefined,
        };
        @memcpy(out[n].raw[0..ai.addrlen], @as([*]const u8, @ptrCast(addr))[0..ai.addrlen]);
        n += 1;
    }
    if (n == 0) return error.ResolveFailed;
    return n;
}

pub fn resolve(host: []const u8, port: u16, out: *[max_addrs]Addr) !usize {
    return lookup(host, port, out, std.c.SOCK.STREAM, false);
}

/// An IP LITERAL only. Never touches a nameserver, so it is safe on a
/// thread that must not block — which is why udp_send takes a literal.
pub fn resolveNumeric(host: []const u8, port: u16, out: *[max_addrs]Addr) !usize {
    return lookup(host, port, out, std.c.SOCK.DGRAM, true);
}

pub fn socket(a: *const Addr) Socket {
    return std.c.socket(@bitCast(a.family), @bitCast(a.socktype), @bitCast(a.protocol));
}

/// True when the socket is connected or the handshake is under way.
pub fn connect(s: Socket, a: *const Addr) bool {
    if (std.c.connect(s, @ptrCast(&a.raw), a.len) == 0) return true;
    const e = std.c.errno(@as(c_int, -1));
    return e == .INPROGRESS or e == .INTR or e == .ALREADY;
}

pub fn wakePair(out: *[2]Socket) !void {
    if (std.c.pipe(out) != 0) return error.PipeFailed;
    setNonBlocking(out[0]);
    setNonBlocking(out[1]);
}

pub fn drainWake(s: Socket) void {
    var buf: [64]u8 = undefined;
    while (recv(s, &buf) > 0) {}
}

/// A UDP socket bound to `port` on every interface, ready to receive
/// broadcasts. Port 0 takes an ephemeral one; `udpPort` reads it back.
pub fn udpBind(port: u16) !Socket {
    const s = std.c.socket(std.c.AF.INET, std.c.SOCK.DGRAM, 0);
    if (!valid(s)) return error.SocketFailed;
    errdefer close(s);
    var yes: c_int = 1;
    _ = std.c.setsockopt(s, std.c.SOL.SOCKET, std.c.SO.REUSEADDR, &yes, @sizeOf(c_int));
    // SO_BROADCAST is needed to SEND to 255.255.255.255; receiving one does
    // not need it. A plugin that binds a port to listen usually also
    // answers, so it is set once here rather than on a later call.
    _ = std.c.setsockopt(s, std.c.SOL.SOCKET, std.c.SO.BROADCAST, &yes, @sizeOf(c_int));
    var addr = std.c.sockaddr.in{ .port = std.mem.nativeToBig(u16, port), .addr = 0 };
    if (std.c.bind(s, @ptrCast(&addr), @sizeOf(@TypeOf(addr))) != 0) return error.BindFailed;
    setNonBlocking(s);
    return s;
}

pub fn udpPort(s: Socket) u16 {
    var addr = std.c.sockaddr.in{ .port = 0, .addr = 0 };
    var len: std.c.socklen_t = @sizeOf(@TypeOf(addr));
    if (std.c.getsockname(s, @ptrCast(&addr), &len) != 0) return 0;
    return std.mem.bigToNative(u16, addr.port);
}

pub fn udpSendTo(s: Socket, buf: []const u8, a: *const Addr) isize {
    return std.c.sendto(s, buf.ptr, buf.len, 0, @ptrCast(&a.raw), a.len);
}

/// One datagram. The sender is not reported: a UDP_DATA event carries the
/// bytes and nothing else.
pub fn udpRecv(s: Socket, buf: []u8) isize {
    return std.c.recvfrom(s, buf.ptr, buf.len, 0, null, null);
}

/// A loopback listener on an ephemeral port. Test support only.
pub fn listen4(port_out: *u16) !Socket {
    const s = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
    if (!valid(s)) return error.SocketFailed;
    errdefer close(s);
    var yes: c_int = 1;
    _ = std.c.setsockopt(s, std.c.SOL.SOCKET, std.c.SO.REUSEADDR, &yes, @sizeOf(c_int));
    var addr = std.c.sockaddr.in{ .port = 0, .addr = std.mem.nativeToBig(u32, 0x7f00_0001) };
    if (std.c.bind(s, @ptrCast(&addr), @sizeOf(@TypeOf(addr))) != 0) return error.BindFailed;
    if (std.c.listen(s, 4) != 0) return error.ListenFailed;
    var len: std.c.socklen_t = @sizeOf(@TypeOf(addr));
    if (std.c.getsockname(s, @ptrCast(&addr), &len) != 0) return error.SockNameFailed;
    port_out.* = std.mem.bigToNative(u16, addr.port);
    return s;
}

pub fn accept(s: Socket) !Socket {
    const peer = std.c.accept(s, null, null);
    if (!valid(peer)) return error.AcceptFailed;
    return peer;
}
