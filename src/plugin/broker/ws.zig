//! One WebSocket in flight: the thread that owns it, the frames `ws_send`
//! queues for that thread, and the one WS_CLOSED every connection ends with.
//!
//! `webio.zig` speaks RFC 6455; this file is the part that belongs to a plugin.

const std = @import("std");

const broker = @import("../broker.zig");
const caps = @import("caps.zig");
const registry_json = @import("registry_json.zig");
const testing = @import("testing.zig");

const net = @import("../net.zig");
const webio = @import("../webio.zig");

const Broker = broker.Broker;
const Kind = caps.Kind;
const level_warn = caps.level_warn;
const sleepMs = broker.sleepMs;
const writeJsonStringTo = registry_json.writeJsonStringTo;

/// WebSocket frames `ws_send` will hold for one connection's own thread, and
/// the bytes they may total. Over either, `ws_send` refuses: a plugin writing
/// faster than the socket drains is told so rather than growing the heap.
pub const ws_max_queued_frames = 64;
pub const ws_max_queued_bytes = 256 * 1024;

/// One WebSocket, owned by its own thread. Everything here except `br`, `id`,
/// `plugin`, `url` and `protocols` is guarded by the broker's `mu`.
///
/// The thread reads; `ws_send` only QUEUES. One thread produces every outgoing
/// frame, which is what keeps two TLS records from being encrypted at once, and
/// it means a plugin's `ws_send` returns in microseconds however slow the peer
/// is.
pub const Ws = struct {
    br: *Broker,
    id: i64,
    plugin: u32,
    url: []u8,
    protocols: []u8,
    fd: net.Socket = net.invalid,
    /// Wakes the connection's thread out of poll when there is something to
    /// write or the connection must close.
    wake: [2]net.Socket = .{ net.invalid, net.invalid },
    out: std.ArrayList([]u8) = .empty,
    out_bytes: usize = 0,
    closing: bool = false,
    cancelled: bool = false,

    pub fn cancelLocked(self: *Ws) void {
        self.cancelled = true;
        self.closing = true;
        self.wakeLocked();
        if (net.valid(self.fd)) net.shutdownBoth(self.fd);
    }

    pub fn wakeLocked(self: *Ws) void {
        if (!net.valid(self.wake[1])) return;
        const one = [_]u8{0};
        _ = net.send(self.wake[1], &one);
    }

    pub fn free(self: *Ws, alloc: std.mem.Allocator) void {
        for (self.out.items) |m| alloc.free(m);
        self.out.deinit(alloc);
        alloc.free(self.url);
        alloc.free(self.protocols);
        for (self.wake) |fd| {
            if (net.valid(fd)) net.close(fd);
        }
        alloc.destroy(self);
    }
};

/// How long the connection's thread waits in poll before looking at its own
/// flags again. A wake byte cuts it short, so this only bounds the case where
/// the wake pair could not be made.
const ws_poll_ms: i32 = 200;

pub fn wsMain(w: *Ws) void {
    const br = w.br;
    defer {
        br.retireWs(w);
        _ = br.workers.fetchSub(1, .acq_rel);
    }

    const url = webio.Url.parse(w.url) catch |e| {
        wsClosed(w, 0, @errorName(e));
        return;
    };
    const stream = webio.Stream.open(br.alloc, url) catch |e| {
        wsClosed(w, 0, @errorName(e));
        return;
    };
    {
        br.mu.lock();
        defer br.mu.unlock();
        w.fd = stream.fd;
    }
    defer {
        {
            br.mu.lock();
            defer br.mu.unlock();
            w.fd = net.invalid;
        }
        stream.close();
    }

    var hs: webio.Handshake = .{};
    webio.wsHandshake(stream, url, w.protocols, &hs) catch |e| {
        wsClosed(w, 0, @errorName(e));
        return;
    };
    {
        var open_json: [128]u8 = undefined;
        var ow = std.Io.Writer.fixed(&open_json);
        ow.writeAll("{\"protocol\":") catch {};
        writeJsonStringTo(&ow, hs.chosen());
        ow.writeAll("}") catch {};
        if (!wsCancelled(w)) br.push(w.plugin, Kind.ws_open, @bitCast(w.id), ow.buffered());
    }

    var msg: std.ArrayList(u8) = .empty;
    defer msg.deinit(br.alloc);
    var msg_op: webio.Opcode = .continuation;
    var code: u16 = 1006;
    var reason: []const u8 = "";
    var reason_buf: [125]u8 = undefined;

    loop: while (true) {
        if (!wsDrainOut(w, stream)) break;
        {
            br.mu.lock();
            const want_close = w.closing;
            const cancelled = w.cancelled;
            br.mu.unlock();
            if (cancelled) return;
            if (want_close) {
                webio.writeFrame(stream, .close, &[_]u8{ 0x03, 0xe8 }) catch {};
                code = 1000;
                break;
            }
        }

        // Decrypted bytes can be waiting inside the TLS reader while the socket
        // itself has nothing new, so ask the stream before asking the kernel.
        if (!stream.hasBuffered()) {
            var fds = [_]net.pollfd{
                .{ .fd = stream.fd, .events = net.POLL.IN, .revents = 0 },
                .{ .fd = w.wake[0], .events = net.POLL.IN, .revents = 0 },
            };
            const n = if (net.valid(w.wake[0])) net.poll(&fds, ws_poll_ms) else net.poll(fds[0..1], ws_poll_ms);
            if (n == 0) continue;
            if (net.valid(w.wake[0]) and fds[1].revents != 0) net.drainWake(w.wake[0]);
            if (fds[0].revents == 0) continue;
        }

        const r = stream.reader();
        const head = webio.readFrameHead(r) catch |e| {
            reason = @errorName(e);
            break;
        };
        switch (head.opcode) {
            .ping, .pong, .close => {
                const payload = r.take(@intCast(head.len)) catch break;
                switch (head.opcode) {
                    .ping => webio.writeFrame(stream, .pong, payload) catch break :loop,
                    .close => {
                        const c = webio.closePayload(payload);
                        code = c.code;
                        const n = @min(c.reason.len, reason_buf.len);
                        @memcpy(reason_buf[0..n], c.reason[0..n]);
                        reason = reason_buf[0..n];
                        webio.writeFrame(stream, .close, payload) catch {};
                        break :loop;
                    },
                    else => {},
                }
            },
            .text, .binary => {
                // A new data frame while a fragment is still open is the one
                // interleaving RFC 6455 forbids.
                if (msg.items.len > 0) {
                    reason = "ProtocolError";
                    break;
                }
                msg_op = head.opcode;
                webio.readPayloadInto(br.alloc, r, &msg, @intCast(head.len)) catch |e| {
                    reason = @errorName(e);
                    break;
                };
                if (head.fin) wsMessage(w, msg_op, msg.items) else continue;
                msg.clearRetainingCapacity();
            },
            .continuation => {
                webio.readPayloadInto(br.alloc, r, &msg, @intCast(head.len)) catch |e| {
                    reason = @errorName(e);
                    break;
                };
                if (msg.items.len > webio.max_message) {
                    reason = "MessageTooLarge";
                    break;
                }
                if (!head.fin) continue;
                wsMessage(w, msg_op, msg.items);
                msg.clearRetainingCapacity();
            },
            else => {
                reason = "ProtocolError";
                break;
            },
        }
    }
    wsClosed(w, code, reason);
}

/// Write whatever `ws_send` queued. False when the socket would not take it,
/// which ends the connection.
fn wsDrainOut(w: *Ws, stream: *webio.Stream) bool {
    while (true) {
        var next: ?[]u8 = null;
        {
            w.br.mu.lock();
            defer w.br.mu.unlock();
            if (w.out.items.len > 0) {
                const frame = w.out.orderedRemove(0);
                w.out_bytes -= frame.len;
                next = frame;
            }
        }
        const frame = next orelse return true;
        defer w.br.alloc.free(frame);
        webio.writeFrame(stream, .text, frame) catch return false;
    }
}

/// One reassembled message. A binary message is dropped with a line: the API
/// carries WS_DATA as text, and a plugin handed bytes it cannot tell from text
/// would parse them as JSON.
fn wsMessage(w: *Ws, opcode: webio.Opcode, payload: []const u8) void {
    if (opcode != .text) {
        w.br.say(level_warn, w.br.idOf(w.plugin), "ws: dropped a {d}-byte binary message", .{payload.len});
        return;
    }
    if (wsCancelled(w)) return;
    w.br.push(w.plugin, Kind.ws_data, @bitCast(w.id), payload);
}

fn wsCancelled(w: *Ws) bool {
    w.br.mu.lock();
    defer w.br.mu.unlock();
    return w.cancelled;
}

/// The one event every WebSocket ends with, whether it failed to connect, was
/// closed by the peer or was closed by the plugin. `code` 0 means it never
/// opened and `reason` names what stopped it.
fn wsClosed(w: *Ws, code: u16, reason: []const u8) void {
    if (wsCancelled(w)) return;
    var buf: [256]u8 = undefined;
    var out = std.Io.Writer.fixed(&buf);
    out.print("{{\"code\":{d},\"reason\":", .{code}) catch return;
    writeJsonStringTo(&out, reason);
    out.writeAll("}") catch return;
    w.br.push(w.plugin, Kind.ws_closed, @bitCast(w.id), out.buffered());
}

const t = std.testing;
const Fixture = testing.Fixture;
const nextEvent = testing.nextEvent;

// -- the scratch WebSocket server -------------------------------------------------

/// A loopback RFC 6455 server for the WebSocket tests. It performs the real
/// handshake — accept hash included — then runs one script: a fragmented text
/// message, a ping, an echo of whatever the client sends, and a close.
const TestWs = struct {
    alloc: std.mem.Allocator,
    fd: net.Socket,
    port: u16,
    th: ?std.Thread = null,
    stopping: std.atomic.Value(bool) = .init(false),
    /// Set when the client answered the ping with a matching pong.
    got_pong: std.atomic.Value(bool) = .init(false),
    /// What the client sent, so a test can prove ws_send masked it correctly.
    echoed: [128]u8 = @splat(0),
    echoed_len: std.atomic.Value(usize) = .init(0),

    fn open(alloc: std.mem.Allocator) !*TestWs {
        const self = try alloc.create(TestWs);
        var port: u16 = 0;
        const fd = try net.listen4(&port);
        net.setNonBlocking(fd);
        self.* = .{ .alloc = alloc, .fd = fd, .port = port };
        self.th = try std.Thread.spawn(.{ .stack_size = 512 * 1024 }, run, .{self});
        return self;
    }

    fn close(self: *TestWs) void {
        self.stopping.store(true, .release);
        if (self.th) |th| th.join();
        net.close(self.fd);
        self.alloc.destroy(self);
    }

    fn run(self: *TestWs) void {
        while (!self.stopping.load(.acquire)) {
            var fds = [_]net.pollfd{.{ .fd = self.fd, .events = net.POLL.IN, .revents = 0 }};
            if (net.poll(&fds, 20) == 0) continue;
            const peer = net.accept(self.fd) catch continue;
            defer net.close(peer);
            self.serve(peer) catch {};
            return;
        }
    }

    fn serve(self: *TestWs, peer: net.Socket) !void {
        // Blocking for the handshake, for the reason TestHttp.serve gives.
        net.setBlocking(peer);
        net.setTimeouts(peer, 3_000);
        var head: [2048]u8 = undefined;
        var used: usize = 0;
        while (std.mem.indexOf(u8, head[0..used], "\r\n\r\n") == null) {
            if (used == head.len) return error.HeadTooLong;
            const n = net.recv(peer, head[used..]);
            if (n <= 0) return error.Closed;
            used += @intCast(n);
        }
        const text = head[0..used];
        const at = std.ascii.indexOfIgnoreCase(text, "sec-websocket-key:") orelse return error.NoKey;
        const rest = text[at + "sec-websocket-key:".len ..];
        const end = std.mem.indexOf(u8, rest, "\r\n") orelse return error.NoKey;
        const key = std.mem.trim(u8, rest[0..end], " \t");
        var accept: [28]u8 = undefined;
        webio.acceptFor(key, &accept);

        var reply: [256]u8 = undefined;
        const msg = try std.fmt.bufPrint(&reply, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n" ++
            "Connection: Upgrade\r\nSec-WebSocket-Accept: {s}\r\nSec-WebSocket-Protocol: v1.signalk\r\n\r\n", .{accept});
        _ = net.send(peer, msg);

        // One message in two fragments: a text frame that is not final, then a
        // continuation that is. A client that treats each frame as a message
        // would report two halves of a JSON object.
        _ = net.send(peer, &[_]u8{ 0x01, 0x07 } ++ "{\"upda".* ++ [_]u8{'t'});
        _ = net.send(peer, &[_]u8{ 0x80, 0x08 } ++ "es\":[1]}".*);
        // A ping the client must answer with the same payload.
        _ = net.send(peer, &[_]u8{ 0x89, 0x04 } ++ "ping".*);

        // Non-blocking again for the script: the loop below polls for the
        // client's pong and its message rather than waiting for either.
        net.setNonBlocking(peer);
        // Read whatever the client sends: its pong, then its text message.
        var buf: [512]u8 = undefined;
        var deadline: u32 = 0;
        while (deadline < 4_000) : (deadline += 5) {
            const n = net.recv(peer, &buf);
            if (n <= 0) {
                if (n == 0) break;
                sleepMs(5);
                continue;
            }
            var i: usize = 0;
            while (i + 2 <= @as(usize, @intCast(n))) {
                const opcode = buf[i] & 0x0f;
                const masked = (buf[i + 1] & 0x80) != 0;
                const len: usize = buf[i + 1] & 0x7f;
                var at2 = i + 2;
                var mask: [4]u8 = .{ 0, 0, 0, 0 };
                if (masked) {
                    @memcpy(&mask, buf[at2 .. at2 + 4]);
                    at2 += 4;
                }
                var payload: [128]u8 = undefined;
                const keep = @min(len, payload.len);
                for (0..keep) |k| payload[k] = buf[at2 + k] ^ mask[k & 3];
                // A client frame is always masked. An unmasked one would be a
                // protocol error, and this asserts the client got it right.
                if (!masked) return error.UnmaskedClientFrame;
                if (opcode == 0xa and std.mem.eql(u8, payload[0..keep], "ping")) {
                    self.got_pong.store(true, .release);
                } else if (opcode == 0x1) {
                    @memcpy(self.echoed[0..keep], payload[0..keep]);
                    self.echoed_len.store(keep, .release);
                    // Echo it back so the plugin side sees a round trip.
                    var frame: [136]u8 = undefined;
                    frame[0] = 0x81;
                    frame[1] = @intCast(keep);
                    @memcpy(frame[2 .. 2 + keep], payload[0..keep]);
                    _ = net.send(peer, frame[0 .. 2 + keep]);
                } else if (opcode == 0x8) {
                    _ = net.send(peer, &[_]u8{ 0x88, 0x02, 0x03, 0xe8 });
                    return;
                }
                i = at2 + len;
            }
        }
    }
};

test "a WebSocket opens, reassembles a fragmented message, answers a ping and closes" {
    const a = t.allocator;
    const fx = try Fixture.init(a);
    defer fx.deinit(a);
    const b = &fx.br;
    try b.start();
    const srv = try TestWs.open(a);
    defer srv.close();

    var url: [64]u8 = undefined;
    const text = try std.fmt.bufPrint(&url, "ws://127.0.0.1:{d}/signalk/v1/stream", .{srv.port});
    const id = b.openWs(0, try a.dupe(u8, text), try a.dupe(u8, "v1.signalk"));
    try t.expect(id > 0);

    const opened = try nextEvent(b, 0, 5_000);
    defer b.freeEvent(opened);
    try t.expectEqual(Kind.ws_open, opened.kind);
    try t.expectEqual(@as(u64, @bitCast(id)), opened.handle);
    // The server chose a subprotocol and the host reports which.
    try t.expectEqualStrings("{\"protocol\":\"v1.signalk\"}", opened.payload);

    // Two frames, one message: the plugin never learns it was fragmented.
    const data = try nextEvent(b, 0, 5_000);
    defer b.freeEvent(data);
    try t.expectEqual(Kind.ws_data, data.kind);
    try t.expectEqualStrings("{\"updates\":[1]}", data.payload);

    // The ping was answered by the connection's own thread, with no plugin
    // involved and no event raised.
    var waited: u32 = 0;
    while (!srv.got_pong.load(.acquire) and waited < 3_000) : (waited += 5) sleepMs(5);
    try t.expect(srv.got_pong.load(.acquire));

    // ws_send masks its frame, the server unmasks it and echoes it back.
    try t.expectEqual(@as(i32, 6), b.sendWs(0, id, "hello!"));
    const echo = try nextEvent(b, 0, 5_000);
    defer b.freeEvent(echo);
    try t.expectEqual(Kind.ws_data, echo.kind);
    try t.expectEqualStrings("hello!", echo.payload);

    // The plugin closing gets the same WS_CLOSED any other ending gets.
    b.closeWs(0, id);
    const closed = try nextEvent(b, 0, 5_000);
    defer b.freeEvent(closed);
    try t.expectEqual(Kind.ws_closed, closed.kind);
    try t.expect(std.mem.indexOf(u8, closed.payload, "\"code\":1000") != null);

    // Another plugin's socket is not this plugin's to write to or close.
    try t.expectEqual(@as(i32, -1), b.sendWs(1, id, "no"));
}

test "a WebSocket that cannot connect answers WS_CLOSED with code 0 and a reason" {
    const a = t.allocator;
    const fx = try Fixture.init(a);
    defer fx.deinit(a);
    const b = &fx.br;
    try b.start();

    const id = b.openWs(0, try a.dupe(u8, "ws://127.0.0.1:9/none"), try a.dupe(u8, ""));
    try t.expect(id > 0);
    const closed = try nextEvent(b, 0, 10_000);
    defer b.freeEvent(closed);
    try t.expectEqual(Kind.ws_closed, closed.kind);
    try t.expect(std.mem.indexOf(u8, closed.payload, "\"code\":0") != null);
}
