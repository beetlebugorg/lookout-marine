//! The Winsock half of the plugin socket layer. `net.zig` selects between this
//! and `net_posix.zig`; nothing else imports it.

const std = @import("std");
const net = @import("net.zig");

const Addr = net.Addr;
const max_addrs = net.max_addrs;
const win = net.win;

// ws2_32, declared here for the same reason as `win` above: Zig 0.16's
// std.os.windows.ws2_32 was cut back to types when sockets moved behind
// std.Io, and std.c's Windows socket declarations point at the members it
// no longer has.
const SOCKET = usize;
const socklen = i32;

const AF_INET: i32 = 2;
const AF_UNSPEC: i32 = 0;
const SOCK_STREAM: i32 = 1;
const SOCK_DGRAM: i32 = 2;
const SOL_SOCKET: i32 = 0xFFFF;
const SO_ERROR: i32 = 0x1007;
const SO_REUSEADDR: i32 = 0x0004;
const SO_BROADCAST: i32 = 0x0020;
const SO_RCVTIMEO: i32 = 0x1006;
const SO_SNDTIMEO: i32 = 0x1005;
const IPPROTO_TCP: i32 = 6;
const TCP_NODELAY: i32 = 0x0001;
const SD_SEND: i32 = 1;
/// AI_NUMERICHOST on Windows.
const AI_NUMERICHOST: i32 = 0x00000004;
/// FIONBIO. The high bits are the IOC_IN|sizeof(u_long) encoding.
const FIONBIO: i32 = @bitCast(@as(u32, 0x8004667E));
const WSAEWOULDBLOCK: i32 = 10035;
const WSAEINPROGRESS: i32 = 10036;
const WSAEALREADY: i32 = 10037;
const WSAEINTR: i32 = 10004;

/// WSADATA as opaque bytes. Its field order differs between _WIN64 and
/// x86 and nothing here reads it, so the size is all that matters. The
/// real thing is about 400 bytes.
const WSADATA = extern struct { raw: [512]u8 align(8) = @splat(0) };

const sockaddr = extern struct { family: u16, data: [14]u8 };
const sockaddr_in = extern struct {
    family: u16 = @intCast(AF_INET),
    port: u16,
    addr: u32,
    zero: [8]u8 = @splat(0),
};

/// Windows orders ai_canonname before ai_addr (as Darwin does) and makes
/// ai_addrlen a size_t, so this cannot be std.c.addrinfo.
const addrinfo = extern struct {
    flags: i32,
    family: i32,
    socktype: i32,
    protocol: i32,
    addrlen: usize,
    canonname: ?[*:0]u8,
    addr: ?*sockaddr,
    next: ?*addrinfo,
};

/// A namespace so the exported names stay the real ws2_32 ones while this
/// module also has a `socket`, a `recv` and a `send` of its own.
const ws = struct {
    extern "ws2_32" fn WSAStartup(version: u16, data: *WSADATA) callconv(.winapi) i32;
    extern "ws2_32" fn WSAGetLastError() callconv(.winapi) i32;
    extern "ws2_32" fn WSAPoll(fds: [*]pollfd, count: u32, timeout: i32) callconv(.winapi) i32;
    extern "ws2_32" fn socket(af: i32, kind: i32, protocol: i32) callconv(.winapi) SOCKET;
    extern "ws2_32" fn closesocket(s: SOCKET) callconv(.winapi) i32;
    extern "ws2_32" fn ioctlsocket(s: SOCKET, cmd: i32, arg: *u32) callconv(.winapi) i32;
    extern "ws2_32" fn recv(s: SOCKET, buf: [*]u8, len: i32, flags: i32) callconv(.winapi) i32;
    extern "ws2_32" fn send(s: SOCKET, buf: [*]const u8, len: i32, flags: i32) callconv(.winapi) i32;
    extern "ws2_32" fn recvfrom(s: SOCKET, buf: [*]u8, len: i32, flags: i32, from: ?*sockaddr, from_len: ?*socklen) callconv(.winapi) i32;
    extern "ws2_32" fn sendto(s: SOCKET, buf: [*]const u8, len: i32, flags: i32, to: *const sockaddr, to_len: socklen) callconv(.winapi) i32;
    extern "ws2_32" fn connect(s: SOCKET, addr: *const sockaddr, len: socklen) callconv(.winapi) i32;
    extern "ws2_32" fn bind(s: SOCKET, addr: *const sockaddr, len: socklen) callconv(.winapi) i32;
    extern "ws2_32" fn listen(s: SOCKET, backlog: i32) callconv(.winapi) i32;
    extern "ws2_32" fn accept(s: SOCKET, addr: ?*sockaddr, len: ?*socklen) callconv(.winapi) SOCKET;
    extern "ws2_32" fn getsockname(s: SOCKET, addr: *sockaddr, len: *socklen) callconv(.winapi) i32;
    extern "ws2_32" fn getsockopt(s: SOCKET, lvl: i32, opt: i32, val: [*]u8, len: *socklen) callconv(.winapi) i32;
    extern "ws2_32" fn setsockopt(s: SOCKET, lvl: i32, opt: i32, val: [*]const u8, len: socklen) callconv(.winapi) i32;
    extern "ws2_32" fn shutdown(s: SOCKET, how: i32) callconv(.winapi) i32;
    extern "ws2_32" fn getaddrinfo(node: [*:0]const u8, service: [*:0]const u8, hints: *const addrinfo, res: *?*addrinfo) callconv(.winapi) i32;
    extern "ws2_32" fn freeaddrinfo(ai: *addrinfo) callconv(.winapi) void;
};

pub const Socket = SOCKET;
/// INVALID_SOCKET. An unsigned handle, so this is not -1 and a valid
/// socket is not "greater than zero".
pub const invalid: Socket = ~@as(SOCKET, 0);

pub const pollfd = extern struct { fd: SOCKET, events: i16, revents: i16 };

pub const POLL = struct {
    pub const RDNORM: i16 = 0x0100;
    pub const RDBAND: i16 = 0x0200;
    pub const IN: i16 = RDNORM | RDBAND;
    pub const WRNORM: i16 = 0x0010;
    pub const OUT: i16 = WRNORM;
    pub const ERR: i16 = 0x0001;
    pub const HUP: i16 = 0x0002;
    pub const NVAL: i16 = 0x0004;
};

/// WSAPoll does not report a failed non-blocking connect, and it rejects
/// an entry whose events are zero. The broker works around both.
pub const poll_misses_connect_error = true;
pub const poll_needs_events = true;

pub fn valid(s: Socket) bool {
    return s != invalid;
}

/// WSAStartup runs once per process, before any other ws2_32 call. It is
/// reference counted, so the flag keeps one count rather than making the
/// call safe. Nothing calls WSACleanup: Winsock goes down with the
/// process, and the host may start and stop many times inside one.
var started = std.atomic.Value(u32).init(0);

fn startup() void {
    if (started.load(.acquire) == 2) return;
    if (started.cmpxchgStrong(0, 1, .acq_rel, .acquire) == null) {
        var data: WSADATA = .{};
        _ = ws.WSAStartup(0x0202, &data); // 2.2
        started.store(2, .release);
        return;
    }
    while (started.load(.acquire) != 2) win.Sleep(0);
}

pub fn poll(fds: []pollfd, timeout_ms: i32) usize {
    const n = ws.WSAPoll(fds.ptr, @intCast(fds.len), timeout_ms);
    return if (n > 0) @intCast(n) else 0;
}

pub fn close(s: Socket) void {
    _ = ws.closesocket(s);
}

pub fn setNonBlocking(s: Socket) void {
    var on: u32 = 1;
    _ = ws.ioctlsocket(s, FIONBIO, &on);
}

pub fn setBlocking(s: Socket) void {
    var off: u32 = 0;
    _ = ws.ioctlsocket(s, FIONBIO, &off);
}

/// Winsock takes a millisecond DWORD where POSIX takes a timeval.
pub fn setTimeouts(s: Socket, timeout_ms: u32) void {
    var ms: u32 = timeout_ms;
    _ = ws.setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, @ptrCast(&ms), @sizeOf(u32));
    _ = ws.setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, @ptrCast(&ms), @sizeOf(u32));
}

pub fn recv(s: Socket, buf: []u8) isize {
    const len: i32 = @intCast(@min(buf.len, std.math.maxInt(i32)));
    return ws.recv(s, buf.ptr, len, 0);
}

pub fn send(s: Socket, buf: []const u8) isize {
    const len: i32 = @intCast(@min(buf.len, std.math.maxInt(i32)));
    return ws.send(s, buf.ptr, len, 0);
}

pub fn retryable() bool {
    const e = ws.WSAGetLastError();
    return e == WSAEWOULDBLOCK or e == WSAEINTR;
}

pub fn soError(s: Socket) i32 {
    var err: i32 = 0;
    var len: socklen = @sizeOf(i32);
    _ = ws.getsockopt(s, SOL_SOCKET, SO_ERROR, @ptrCast(&err), &len);
    return err;
}

pub fn shutdownWrite(s: Socket) void {
    _ = ws.shutdown(s, SD_SEND);
}

/// SD_BOTH. Breaks a socket in both directions without closing it, so a thread
/// blocked in recv returns at once.
pub fn shutdownBoth(s: Socket) void {
    _ = ws.shutdown(s, 2);
}

fn lookup(host: []const u8, port: u16, out: *[max_addrs]Addr, socktype: i32, numeric: bool) !usize {
    startup();
    var host_z: [256]u8 = undefined;
    if (host.len >= host_z.len) return error.HostTooLong;
    @memcpy(host_z[0..host.len], host);
    host_z[host.len] = 0;
    var port_z: [8]u8 = undefined;
    const ps = try std.fmt.bufPrintZ(&port_z, "{d}", .{port});

    var hints: addrinfo = std.mem.zeroes(addrinfo);
    hints.family = AF_UNSPEC;
    hints.socktype = socktype;
    if (numeric) hints.flags = AI_NUMERICHOST;
    var res: ?*addrinfo = null;
    if (ws.getaddrinfo(@ptrCast(&host_z), ps.ptr, &hints, &res) != 0) return error.ResolveFailed;
    const list = res orelse return error.ResolveFailed;
    defer ws.freeaddrinfo(list);

    var n: usize = 0;
    var it: ?*addrinfo = list;
    while (it) |ai| : (it = ai.next) {
        if (n == out.len) break;
        const addr = ai.addr orelse continue;
        if (ai.addrlen > out[n].raw.len) continue;
        out[n] = .{
            .family = ai.family,
            .socktype = ai.socktype,
            .protocol = ai.protocol,
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
    return lookup(host, port, out, SOCK_STREAM, false);
}

pub fn resolveNumeric(host: []const u8, port: u16, out: *[max_addrs]Addr) !usize {
    return lookup(host, port, out, SOCK_DGRAM, true);
}

pub fn socket(a: *const Addr) Socket {
    startup();
    return ws.socket(a.family, a.socktype, a.protocol);
}

pub fn connect(s: Socket, a: *const Addr) bool {
    if (ws.connect(s, @ptrCast(&a.raw), @intCast(a.len)) == 0) return true;
    const e = ws.WSAGetLastError();
    return e == WSAEWOULDBLOCK or e == WSAEINPROGRESS or e == WSAEALREADY;
}

/// A loopback socket pair, because Windows has no pipe a socket poll can
/// watch. The listener is on this thread's own loopback, so the blocking
/// connect completes into the accept backlog without waiting on anything.
/// The write end turns Nagle off: a one-byte wake must not wait for an ack.
pub fn wakePair(out: *[2]Socket) !void {
    startup();
    const lst = ws.socket(AF_INET, SOCK_STREAM, 0);
    if (!valid(lst)) return error.PipeFailed;
    defer close(lst);
    var addr = sockaddr_in{ .port = 0, .addr = std.mem.nativeToBig(u32, 0x7f00_0001) };
    if (ws.bind(lst, @ptrCast(&addr), @sizeOf(sockaddr_in)) != 0) return error.PipeFailed;
    if (ws.listen(lst, 1) != 0) return error.PipeFailed;
    var len: socklen = @sizeOf(sockaddr_in);
    if (ws.getsockname(lst, @ptrCast(&addr), &len) != 0) return error.PipeFailed;

    const wr = ws.socket(AF_INET, SOCK_STREAM, 0);
    if (!valid(wr)) return error.PipeFailed;
    errdefer close(wr);
    if (ws.connect(wr, @ptrCast(&addr), @sizeOf(sockaddr_in)) != 0) return error.PipeFailed;
    const rd = ws.accept(lst, null, null);
    if (!valid(rd)) return error.PipeFailed;

    var yes: i32 = 1;
    _ = ws.setsockopt(wr, IPPROTO_TCP, TCP_NODELAY, @ptrCast(&yes), @sizeOf(i32));
    setNonBlocking(rd);
    setNonBlocking(wr);
    out.* = .{ rd, wr };
}

pub fn drainWake(s: Socket) void {
    var buf: [64]u8 = undefined;
    while (recv(s, &buf) > 0) {}
}

pub fn udpBind(port: u16) !Socket {
    startup();
    const s = ws.socket(AF_INET, SOCK_DGRAM, 0);
    if (!valid(s)) return error.SocketFailed;
    errdefer close(s);
    var yes: i32 = 1;
    _ = ws.setsockopt(s, SOL_SOCKET, SO_REUSEADDR, @ptrCast(&yes), @sizeOf(i32));
    _ = ws.setsockopt(s, SOL_SOCKET, SO_BROADCAST, @ptrCast(&yes), @sizeOf(i32));
    var addr = sockaddr_in{ .port = std.mem.nativeToBig(u16, port), .addr = 0 };
    if (ws.bind(s, @ptrCast(&addr), @sizeOf(sockaddr_in)) != 0) return error.BindFailed;
    setNonBlocking(s);
    return s;
}

pub fn udpPort(s: Socket) u16 {
    var addr = sockaddr_in{ .port = 0, .addr = 0 };
    var len: socklen = @sizeOf(sockaddr_in);
    if (ws.getsockname(s, @ptrCast(&addr), &len) != 0) return 0;
    return std.mem.bigToNative(u16, addr.port);
}

pub fn udpSendTo(s: Socket, buf: []const u8, a: *const Addr) isize {
    const len: i32 = @intCast(@min(buf.len, std.math.maxInt(i32)));
    return ws.sendto(s, buf.ptr, len, 0, @ptrCast(&a.raw), @intCast(a.len));
}

pub fn udpRecv(s: Socket, buf: []u8) isize {
    const len: i32 = @intCast(@min(buf.len, std.math.maxInt(i32)));
    return ws.recvfrom(s, buf.ptr, len, 0, null, null);
}

pub fn listen4(port_out: *u16) !Socket {
    startup();
    const s = ws.socket(AF_INET, SOCK_STREAM, 0);
    if (!valid(s)) return error.SocketFailed;
    errdefer close(s);
    var addr = sockaddr_in{ .port = 0, .addr = std.mem.nativeToBig(u32, 0x7f00_0001) };
    if (ws.bind(s, @ptrCast(&addr), @sizeOf(sockaddr_in)) != 0) return error.BindFailed;
    if (ws.listen(s, 4) != 0) return error.ListenFailed;
    var len: socklen = @sizeOf(sockaddr_in);
    if (ws.getsockname(s, @ptrCast(&addr), &len) != 0) return error.SockNameFailed;
    port_out.* = std.mem.bigToNative(u16, addr.port);
    return s;
}

pub fn accept(s: Socket) !Socket {
    const peer = ws.accept(s, null, null);
    if (!valid(peer)) return error.AcceptFailed;
    return peer;
}
