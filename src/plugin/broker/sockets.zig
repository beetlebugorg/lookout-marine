//! What the I/O thread keeps for one plugin's sockets and timers, and the
//! pacing the fanout tick runs at. The thread itself is the Broker's.

const std = @import("std");

const broker = @import("../broker.zig");
const caps = @import("caps.zig");
const queue = @import("queue.zig");
const testing = @import("testing.zig");

const net = @import("../net.zig");
const vstore = @import("../store.zig");
const ais_store = @import("../aisstore.zig");

const Addr = net.Addr;
const max_addrs = net.max_addrs;
const Broker = broker.Broker;
const Kind = caps.Kind;
const sleepMs = broker.sleepMs;
const pause_reads_at = queue.pause_reads_at;

pub const ConnState = enum { resolving, connecting, open };

pub const Conn = struct {
    id: i64,
    plugin: u32,
    state: ConnState,
    fd: net.Socket = net.invalid,
    /// Kept until the socket is connected: a resolver thread reads it, so the
    /// plugin's tcp_connect never blocks on DNS and neither does the I/O
    /// thread.
    host: []u8,
    port: u16,
    /// Bytes tcp_send handed over, not yet written.
    out: std.ArrayList(u8) = .empty,
    /// Set by tcp_close; the I/O thread reaps it without an event.
    closing: bool = false,
};

/// One bound UDP port. There is no connection and no state: a datagram in is
/// an event, a datagram out is one call.
pub const Udp = struct {
    id: i64,
    plugin: u32,
    fd: net.Socket,
    /// The port actually bound, which is not the one asked for when the plugin
    /// asked for 0.
    port: u16,
    closing: bool = false,
};

pub const Timer = struct {
    id: i64,
    plugin: u32,
    /// Monotonic ms.
    due: i64,
    /// 0 for a one-shot.
    period: i64,
};

/// How often the fanout tick runs. STORE_CHANGED is specified at <=10 Hz, so
/// the tick sets the rate and the store's dirty set does the coalescing.
pub const tick_ms: i64 = 100;
/// AIS_CHANGED is specified at <=2 Hz.
pub const ais_min_interval_ms: i64 = 500;

/// Read chunk for a plugin socket. One TCP_DATA event per read; the plugin
/// reassembles lines itself.
pub const read_chunk = 8192;

/// Longest datagram delivered as a UDP_DATA event.
///
/// One datagram is one event. A 9 KB datagram is dropped, not split.
pub const udp_max_datagram = 8192;

/// Native stack for a resolver thread. It runs getaddrinfo and connect and
/// nothing else — it never enters wasm — so it needs far less than the
/// 16 MiB Zig would otherwise reserve per attempt.
pub const resolver_stack_bytes: usize = 512 * 1024;

/// Which socket a poll slot belongs to. A UDP port and a TCP connection share
/// one id space, so the flag says which list to look in rather than which id
/// range to compare against.
pub const Owner = struct { id: i64, udp: bool };

const t = std.testing;
const Fixture = testing.Fixture;
const nextEvent = testing.nextEvent;
const silentLog = testing.silentLog;

test "a plugin socket connects, carries bytes both ways, and reports the close" {
    var vessels = try vstore.Store.init(t.allocator);
    defer vessels.deinit();
    var ais = ais_store.AisStore.init(t.allocator);
    defer ais.deinit();
    var b = Broker.init(t.allocator, &vessels, &ais, .{});
    defer b.deinit();

    var srv = try Listener.open();
    defer srv.close();

    try b.start();
    const id = b.openConn(0, "127.0.0.1", srv.port);
    try t.expect(id > 0);

    // accept() blocks here until the I/O thread's connect lands.
    const peer = try srv.accept();
    defer net.close(peer);
    try t.expectEqual(Kind.tcp_connected, try expectEvent(&b, 2_000));

    _ = net.send(peer, "$GPRMC,\r\n");
    try t.expectEqual(Kind.tcp_data, try expectEvent(&b, 2_000));

    // ...and the other direction: what the plugin sends reaches the peer.
    try t.expectEqual(@as(i32, 4), b.sendConn(0, id, "ping"));
    var got: [16]u8 = undefined;
    var n: isize = 0;
    var waited: u32 = 0;
    while (n <= 0 and waited < 2_000) : (waited += 5) {
        n = net.recv(peer, &got);
        if (n <= 0) sleepMs(5);
    }
    try t.expectEqualStrings("ping", got[0..@intCast(n)]);

    // The peer hanging up is a TCP_CLOSED, and the connection is gone.
    net.shutdownWrite(peer); // our side then reads EOF
    try t.expectEqual(Kind.tcp_closed, try expectEvent(&b, 2_000));
    b.mu.lock();
    const remaining = b.conns.items.len;
    b.mu.unlock();
    try t.expectEqual(@as(usize, 0), remaining);
}

test "a backed-up plugin stops being read from, and its neighbour does not" {
    var vessels = try vstore.Store.init(t.allocator);
    defer vessels.deinit();
    var ais = ais_store.AisStore.init(t.allocator);
    defer ais.deinit();
    var b = Broker.init(t.allocator, &vessels, &ais, .{});
    defer b.deinit();
    b.setLog(null, silentLog);

    var srv = try Listener.open();
    defer srv.close();
    try b.start();

    // One socket each for two plugins.
    try t.expect(b.openConn(0, "127.0.0.1", srv.port) > 0);
    const peer0 = try srv.accept();
    defer net.close(peer0);
    try t.expectEqual(Kind.tcp_connected, try expectEvent(&b, 2_000));

    try t.expect(b.openConn(1, "127.0.0.1", srv.port) > 0);
    const peer1 = try srv.accept();
    defer net.close(peer1);
    var waited: u32 = 0;
    while (b.queuedFor(1) == 0 and waited < 2_000) : (waited += 5) sleepMs(5);
    const connected1 = b.popFor(1) orelse return error.NoEvent;
    b.freeEvent(connected1);

    // Plugin 0 stops consuming: fill its queue to the watermark, then let the
    // I/O thread rebuild its poll set before anything is written.
    for (0..pause_reads_at) |i| b.push(0, Kind.timer, i, "");
    b.wakeIo();
    sleepMs(150);

    _ = net.send(peer0, "$GPRMC,\r\n");
    _ = net.send(peer1, "$GPRMC,\r\n");
    sleepMs(400);

    // Nothing was read for plugin 0 — its depth is exactly what was pushed —
    // while plugin 1's data came through on the same I/O thread.
    try t.expectEqual(@as(usize, pause_reads_at), b.queuedFor(0));
    try t.expectEqual(@as(u64, 0), b.droppedFor(0));
    try t.expectEqual(@as(usize, 1), b.queuedFor(1));
    const data1 = b.popFor(1) orelse return error.NoEvent;
    defer b.freeEvent(data1);
    try t.expectEqual(Kind.tcp_data, data1.kind);

    // Once plugin 0 catches up, reading resumes and the bytes are still there:
    // the pause held them in the kernel rather than throwing them away.
    while (b.popFor(0)) |e| b.freeEvent(e);
    b.wakeIo();
    try t.expectEqual(Kind.tcp_data, try expectEvent(&b, 2_000));
}

test "a connection to nothing comes back as a close, not a hang" {
    var vessels = try vstore.Store.init(t.allocator);
    defer vessels.deinit();
    var ais = ais_store.AisStore.init(t.allocator);
    defer ais.deinit();
    var b = Broker.init(t.allocator, &vessels, &ais, .{});
    defer b.deinit();
    b.setLog(null, silentLog);

    try b.start();
    // A name no resolver answers, and a port nothing listens on.
    try t.expect(b.openConn(0, "no-such-host.invalid", 10110) > 0);
    try t.expectEqual(Kind.tcp_closed, try expectEvent(&b, 5_000));
}

/// The next event's kind for plugin 0, waiting up to `timeout_ms`.
fn expectEvent(b: *Broker, timeout_ms: u32) !u32 {
    var waited: u32 = 0;
    while (waited < timeout_ms) : (waited += 5) {
        if (b.popFor(0)) |e| {
            defer b.freeEvent(e);
            return e.kind;
        }
        sleepMs(5);
    }
    return error.NoEvent;
}

/// A loopback listener on an ephemeral port, for the socket tests.
const Listener = struct {
    fd: net.Socket,
    port: u16,

    fn open() !Listener {
        var port: u16 = 0;
        const fd = try net.listen4(&port);
        return .{ .fd = fd, .port = port };
    }

    fn accept(self: *Listener) !net.Socket {
        return net.accept(self.fd);
    }

    fn close(self: *Listener) void {
        net.close(self.fd);
    }
};

test "a bound UDP port turns each datagram into one event, and drops an oversize one" {
    const a = t.allocator;
    const fx = try Fixture.init(a);
    defer fx.deinit(a);
    const b = &fx.br;
    try b.start();

    const id = b.openUdp(0, 0);
    try t.expect(id > 0);
    b.mu.lock();
    const port = b.udps.items[0].port;
    b.mu.unlock();
    try t.expect(port != 0);

    // A second port stands in for the instrument on the network.
    const sender = try net.udpBind(0);
    defer net.close(sender);
    var addrs: [max_addrs]Addr = undefined;
    _ = try net.resolveNumeric("127.0.0.1", port, &addrs);

    _ = net.udpSendTo(sender, "$GPRMC,123519,A\r\n", &addrs[0]);
    const e = try nextEvent(b, 0, 2_000);
    defer b.freeEvent(e);
    try t.expectEqual(Kind.udp_data, e.kind);
    try t.expectEqual(@as(u64, @bitCast(id)), e.handle);
    try t.expectEqualStrings("$GPRMC,123519,A\r\n", e.payload);

    // One datagram is one event. A datagram over the cap is dropped whole
    // rather than delivered truncated, which would look like a valid short
    // sentence to a parser.
    var big: [udp_max_datagram + 100]u8 = undefined;
    @memset(&big, 'x');
    _ = net.udpSendTo(sender, &big, &addrs[0]);
    _ = net.udpSendTo(sender, "after", &addrs[0]);
    const after = try nextEvent(b, 0, 2_000);
    defer b.freeEvent(after);
    try t.expectEqualStrings("after", after.payload);

    // A datagram exactly at the cap still goes through.
    _ = net.udpSendTo(sender, big[0..udp_max_datagram], &addrs[0]);
    const at_cap = try nextEvent(b, 0, 2_000);
    defer b.freeEvent(at_cap);
    try t.expectEqual(@as(usize, udp_max_datagram), at_cap.payload.len);
}

test "udp_send reaches a port, and refuses a name it would have to resolve" {
    const a = t.allocator;
    const fx = try Fixture.init(a);
    defer fx.deinit(a);
    const b = &fx.br;
    try b.start();

    const id = b.openUdp(0, 0);
    try t.expect(id > 0);

    const peer = try net.udpBind(0);
    defer net.close(peer);
    const peer_port = net.udpPort(peer);

    try t.expectEqual(@as(i32, 5), b.sendUdp(0, id, "hello", "127.0.0.1", peer_port));
    var buf: [64]u8 = undefined;
    var got: isize = -1;
    var waited: u32 = 0;
    while (got <= 0 and waited < 2_000) : (waited += 5) {
        got = net.udpRecv(peer, &buf);
        if (got <= 0) sleepMs(5);
    }
    try t.expectEqualStrings("hello", buf[0..@intCast(got)]);

    // A name would need a resolver, and this runs on the plugin's own thread
    // under the watchdog's budget. Literals only.
    try t.expectEqual(@as(i32, -1), b.sendUdp(0, id, "hello", "localhost", peer_port));
    // Another plugin's port is not this plugin's to send from.
    try t.expectEqual(@as(i32, -1), b.sendUdp(1, id, "hello", "127.0.0.1", peer_port));
    // A datagram over the cap never leaves.
    var big: [udp_max_datagram + 1]u8 = undefined;
    try t.expectEqual(@as(i32, -1), b.sendUdp(0, id, &big, "127.0.0.1", peer_port));

    b.closeUdp(0, id);
    b.mu.lock();
    const left = b.udps.items.len;
    b.mu.unlock();
    try t.expectEqual(@as(usize, 0), left);
}
