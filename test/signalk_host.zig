//! A Signal K server feeding the chart: the real signalk .wasm, the real host,
//! the real broker sockets, and a loopback server that streams recorded
//! deltas.
//!
//! What it proves, which nothing else does:
//!   - the plugin subscribes. The loopback server sends no delta until it has
//!     read a subscription, which is what a Signal K server does over TCP;
//!   - a delta lands in the vessel store and the AIS store, in the host's
//!     units. A heading of pi/2 radians reads 90 degrees at the other end;
//!   - switching a row off closes the stream, and switching it back on
//!     reopens it;
//!   - the store arbitrates between this plugin and the nmea0183 plugin when
//!     both hold the same path, and fails over to the second one when the
//!     first goes stale;
//!   - the SAME plugin reads the same server over a websocket, through the
//!     host's `ws_connect` import and its RFC 6455 framing, and puts the same
//!     numbers in the store.
//!
//! The plugins arrive as anonymous imports, like plugins/echo does for
//! host_smoke: importing host.zig must never drag a plugin binary into the
//! core.

const std = @import("std");
const host = @import("host");

const broker = host.broker;
const vstore = host.store;
const aisstore = host.aisstore;

const sk_wasm = @embedFile("signalk_plugin_wasm");
const sk_manifest = @embedFile("signalk_manifest");
const sk_id = "org.beetlebug.signalk";

const nmea_wasm = @embedFile("nmea_plugin_wasm");
const nmea_manifest = @embedFile("nmea_manifest");
const nmea_id = "org.beetlebug.nmea0183";

/// The recorded stream. Line one is the server's hello; the rest are deltas,
/// replayed in a loop. The file is fixed text, so two runs see the same bytes.
const recorded = @embedFile("signalk_deltas");

const io = std.Io.Threaded.global_single_threaded.io();

/// How long a wait-for gives up after. Generous: a loaded machine still has to
/// resolve a name, connect, and get a document through the interpreter.
const deadline_ms: i64 = 8_000;

/// The staleness window this test runs the navigation paths at. The default is
/// 5 s, which is right at sea and slow in a test that has to watch an elected
/// source age out.
const nav_staleness_ms: i64 = 1_000;

// ---------------------------------------------------------------------------
// a loopback Signal K server
// ---------------------------------------------------------------------------

/// One pretend Signal K server. It writes the hello on accept, waits for a
/// subscription, then replays the recorded deltas in a loop.
const Server = struct {
    /// True to speak the websocket at `/signalk/v1/stream` instead of the
    /// plain TCP stream. The recorded deltas and the hello are the same; only
    /// the framing differs.
    ws: bool = false,
    fd: std.c.fd_t = -1,
    port: u16 = 0,
    thread: ?std.Thread = null,
    stop: std.atomic.Value(bool) = .init(false),
    /// Clients accepted so far. A reconnect shows up here.
    accepted: std.atomic.Value(u32) = .init(0),
    /// Clients that sent a subscription.
    subscribed: std.atomic.Value(u32) = .init(0),
    /// The first line a client wrote, for the test to read back.
    first_request: [256]u8 = undefined,
    first_request_len: std.atomic.Value(u32) = .init(0),

    fn open(self: *Server) !void {
        const fd = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
        if (fd < 0) return error.SocketFailed;
        errdefer _ = std.c.close(fd);
        var yes: c_int = 1;
        _ = std.c.setsockopt(fd, std.c.SOL.SOCKET, std.c.SO.REUSEADDR, &yes, @sizeOf(c_int));
        var addr = std.c.sockaddr.in{ .port = 0, .addr = std.mem.nativeToBig(u32, 0x7f00_0001) };
        if (std.c.bind(fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr))) != 0) return error.BindFailed;
        if (std.c.listen(fd, 4) != 0) return error.ListenFailed;
        var len: std.c.socklen_t = @sizeOf(@TypeOf(addr));
        if (std.c.getsockname(fd, @ptrCast(&addr), &len) != 0) return error.SockNameFailed;
        self.fd = fd;
        self.port = std.mem.bigToNative(u16, addr.port);
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    fn close(self: *Server) void {
        self.stop.store(true, .release);
        if (self.thread) |th| th.join();
        self.thread = null;
        if (self.fd >= 0) _ = std.c.close(self.fd);
        self.fd = -1;
    }

    fn run(self: *Server) void {
        while (!self.stop.load(.acquire)) {
            const peer = acceptOne(self.fd) orelse continue;
            defer _ = std.c.close(peer);
            noSigPipe(peer);
            _ = self.accepted.fetchAdd(1, .monotonic);

            var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, recorded, "\n"), '\n');
            const hello = lines.next() orelse continue;
            if (lines.rest().len == 0) continue;
            if (self.ws and !self.upgrade(peer)) continue;
            if (!self.send(peer, hello)) continue;
            if (!self.awaitSubscribe(peer)) continue;
            _ = self.subscribed.fetchAdd(1, .monotonic);

            // The deltas, over and over. A real stream never ends, and an EOF
            // would send the plugin into its reconnect backoff. A write that
            // fails means this client went away: take the next one, because a
            // resumed row dials the same server again.
            stream: while (!self.stop.load(.acquire)) {
                var it = lines;
                while (it.next()) |line| {
                    if (line.len == 0) continue;
                    if (self.stop.load(.acquire)) break :stream;
                    if (!self.send(peer, line)) break :stream;
                    broker.sleepMs(40);
                }
            }
        }
    }

    /// One document, framed the way this server's transport frames it.
    fn send(self: *Server, peer: std.c.fd_t, doc: []const u8) bool {
        return if (self.ws) writeWsText(peer, doc) else writeLine(peer, doc);
    }

    /// The RFC 6455 handshake, from the server's side. The accept hash is
    /// computed with the host's own `acceptFor`, which is the thing under
    /// test on the other end of the socket.
    fn upgrade(self: *Server, peer: std.c.fd_t) bool {
        var head: [2048]u8 = undefined;
        var used: usize = 0;
        const until = broker.monoMs() + deadline_ms;
        while (std.mem.indexOf(u8, head[0..used], "\r\n\r\n") == null) {
            if (self.stop.load(.acquire) or broker.monoMs() > until or used == head.len) return false;
            var fds = [_]std.c.pollfd{.{ .fd = peer, .events = std.c.POLL.IN, .revents = 0 }};
            if ((std.posix.poll(&fds, 50) catch return false) <= 0) continue;
            const n = std.c.read(peer, head[used..].ptr, head.len - used);
            if (n <= 0) return false;
            used += @intCast(n);
        }
        const text = head[0..used];
        // The path is the spec's, and a plugin that dialled the web page
        // instead of the stream would show up here.
        if (std.mem.indexOf(u8, text, "GET /signalk/v1/stream") == null) return false;
        const at = std.ascii.indexOfIgnoreCase(text, "sec-websocket-key:") orelse return false;
        const rest = text[at + "sec-websocket-key:".len ..];
        const end = std.mem.indexOf(u8, rest, "\r\n") orelse return false;
        const key = std.mem.trim(u8, rest[0..end], " \t");
        var accept: [28]u8 = undefined;
        host.webio.acceptFor(key, &accept);

        var reply: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&reply, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n" ++
            "Connection: Upgrade\r\nSec-WebSocket-Accept: {s}\r\n\r\n", .{accept}) catch return false;
        return writeAll(peer, msg);
    }

    /// Read until the client asks for something. A Signal K stream starts with
    /// no subscription on either transport, so a plugin that never sends one
    /// gets no deltas and this test times out.
    fn awaitSubscribe(self: *Server, peer: std.c.fd_t) bool {
        const until = broker.monoMs() + deadline_ms;
        var buf: [512]u8 = undefined;
        var len: usize = 0;
        while (!self.stop.load(.acquire) and broker.monoMs() < until) {
            var fds = [_]std.c.pollfd{.{ .fd = peer, .events = std.c.POLL.IN, .revents = 0 }};
            const n = std.posix.poll(&fds, 50) catch return false;
            if (n <= 0) continue;
            const got = std.c.read(peer, buf[len..].ptr, buf.len - len);
            if (got <= 0) return false;
            len += @intCast(got);
            var frame: [512]u8 = undefined;
            const asked = if (self.ws)
                (readWsText(buf[0..len], &frame) orelse continue)
            else blk: {
                const line = std.mem.sliceTo(buf[0..len], '\n');
                if (line.len == len) continue; // no terminator yet
                break :blk std.mem.trimEnd(u8, line, "\r");
            };
            const keep = @min(asked.len, self.first_request.len);
            @memcpy(self.first_request[0..keep], asked[0..keep]);
            self.first_request_len.store(@intCast(keep), .release);
            return std.mem.indexOf(u8, asked, "\"subscribe\"") != null;
        }
        return false;
    }

    fn request(self: *Server) []const u8 {
        return self.first_request[0..self.first_request_len.load(.acquire)];
    }
};

/// One pretend NMEA gateway, so the two plugins can contend for one path.
const NmeaFeed = struct {
    fd: std.c.fd_t = -1,
    port: u16 = 0,
    /// A whole sentence with its checksum, terminated.
    line: []const u8,
    thread: ?std.Thread = null,
    stop: std.atomic.Value(bool) = .init(false),
    accepted: std.atomic.Value(u32) = .init(0),

    fn open(self: *NmeaFeed) !void {
        const fd = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
        if (fd < 0) return error.SocketFailed;
        errdefer _ = std.c.close(fd);
        var yes: c_int = 1;
        _ = std.c.setsockopt(fd, std.c.SOL.SOCKET, std.c.SO.REUSEADDR, &yes, @sizeOf(c_int));
        var addr = std.c.sockaddr.in{ .port = 0, .addr = std.mem.nativeToBig(u32, 0x7f00_0001) };
        if (std.c.bind(fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr))) != 0) return error.BindFailed;
        if (std.c.listen(fd, 4) != 0) return error.ListenFailed;
        var len: std.c.socklen_t = @sizeOf(@TypeOf(addr));
        if (std.c.getsockname(fd, @ptrCast(&addr), &len) != 0) return error.SockNameFailed;
        self.fd = fd;
        self.port = std.mem.bigToNative(u16, addr.port);
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    fn close(self: *NmeaFeed) void {
        self.stop.store(true, .release);
        if (self.thread) |th| th.join();
        self.thread = null;
        if (self.fd >= 0) _ = std.c.close(self.fd);
        self.fd = -1;
    }

    fn run(self: *NmeaFeed) void {
        while (!self.stop.load(.acquire)) {
            const peer = acceptOne(self.fd) orelse continue;
            defer _ = std.c.close(peer);
            noSigPipe(peer);
            _ = self.accepted.fetchAdd(1, .monotonic);
            while (!self.stop.load(.acquire)) {
                if (!writeAll(peer, self.line)) break;
                broker.sleepMs(40);
            }
        }
    }
};

fn acceptOne(fd: std.c.fd_t) ?std.c.fd_t {
    var fds = [_]std.c.pollfd{.{ .fd = fd, .events = std.c.POLL.IN, .revents = 0 }};
    const n = std.posix.poll(&fds, 50) catch return null;
    if (n <= 0) return null;
    const peer = std.c.accept(fd, null, null);
    return if (peer < 0) null else peer;
}

/// macOS raises SIGPIPE on a write to a socket the plugin closed; the error
/// return is enough.
fn noSigPipe(peer: std.c.fd_t) void {
    if (@hasDecl(std.c.SO, "NOSIGPIPE")) {
        var yes: c_int = 1;
        _ = std.c.setsockopt(peer, std.c.SOL.SOCKET, std.c.SO.NOSIGPIPE, &yes, @sizeOf(c_int));
    }
}

/// One unmasked server text frame. A server frame is never masked (RFC 6455
/// section 5.1), and a client that unmasked one anyway would pass this test
/// while failing against a real server.
fn writeWsText(fd: std.c.fd_t, payload: []const u8) bool {
    var head: [4]u8 = undefined;
    var n: usize = 0;
    head[0] = 0x81;
    if (payload.len < 126) {
        head[1] = @intCast(payload.len);
        n = 2;
    } else {
        head[1] = 126;
        std.mem.writeInt(u16, head[2..4], @intCast(payload.len), .big);
        n = 4;
    }
    return writeAll(fd, head[0..n]) and writeAll(fd, payload);
}

/// One MASKED client text frame out of `raw`, unmasked into `out`. Null while
/// the frame is not all there yet, and null for an unmasked frame — a client
/// must mask, and this test is the thing that says so.
fn readWsText(raw: []const u8, out: []u8) ?[]const u8 {
    if (raw.len < 2) return null;
    if (raw[0] & 0x0f != 0x1) return null;
    if (raw[1] & 0x80 == 0) return null;
    var len: usize = raw[1] & 0x7f;
    var at: usize = 2;
    if (len == 126) {
        if (raw.len < 4) return null;
        len = std.mem.readInt(u16, raw[2..4], .big);
        at = 4;
    }
    if (raw.len < at + 4 + len or len > out.len) return null;
    const mask = raw[at .. at + 4];
    const body = raw[at + 4 .. at + 4 + len];
    for (body, 0..) |c, i| out[i] = c ^ mask[i & 3];
    return out[0..len];
}

fn writeLine(fd: std.c.fd_t, line: []const u8) bool {
    // CR LF, which is the terminator the Signal K TCP stream specifies.
    return writeAll(fd, line) and writeAll(fd, "\r\n");
}

fn writeAll(fd: std.c.fd_t, data: []const u8) bool {
    var off: usize = 0;
    while (off < data.len) {
        const n = std.c.write(fd, data.ptr + off, data.len - off);
        if (n <= 0) return false;
        off += @intCast(n);
    }
    return true;
}

// ---------------------------------------------------------------------------
// waiting and reading
// ---------------------------------------------------------------------------

/// An assertion that says which one it was. `expect` alone reports
/// "TestUnexpectedResult" and nothing else, which is no use in a test with
/// this many moving parts.
fn must(cond: bool, comptime what: []const u8) !void {
    if (cond) return;
    std.debug.print("\nFAILED: {s}\n", .{what});
    return error.TestUnexpectedResult;
}

fn waitFor(comptime what: []const u8, ctx: anytype, ready: fn (@TypeOf(ctx)) bool) !void {
    const until = broker.monoMs() + deadline_ms;
    while (broker.monoMs() < until) {
        if (ready(ctx)) return;
        broker.sleepMs(20);
    }
    std.debug.print("\nTIMED OUT waiting for: {s}\n", .{what});
    return error.TimedOut;
}

fn pathValue(vessels: *vstore.Store, path: []const u8) ?vstore.PathValue {
    return vessels.readElected(path, broker.wallMs());
}

fn number(vessels: *vstore.Store, path: []const u8) ?f64 {
    const r = pathValue(vessels, path) orelse return null;
    return switch (r.value) {
        .number => |v| v,
        else => null,
    };
}

const position_path = "navigation.position";
const heading_path = "navigation.headingTrue";
const sog_path = "navigation.speedOverGround";
const depth_path = "environment.depth.belowTransducer";

/// Keeps every broker log line, so the test can prove the plugin never
/// trapped and nothing was refused a grant.
const LogSink = struct {
    text: std.ArrayList(u8) = .empty,
    alloc: std.mem.Allocator,
    mu: vstore.Lock = .{},

    fn write(ctx: ?*anyopaque, level: u32, plugin: []const u8, msg: []const u8) void {
        const self: *LogSink = @ptrCast(@alignCast(ctx.?));
        self.mu.lock();
        defer self.mu.unlock();
        self.text.print(self.alloc, "{d}|{s}|{s}\n", .{ level, plugin, msg }) catch {};
    }

    fn has(self: *LogSink, needle: []const u8) bool {
        self.mu.lock();
        defer self.mu.unlock();
        return std.mem.indexOf(u8, self.text.items, needle) != null;
    }
};

/// The store, the AIS store, the broker and the host, wired the way the app
/// wires them.
const Rig = struct {
    alloc: std.mem.Allocator,
    vessels: *vstore.Store,
    ais: *aisstore.AisStore,
    br: *broker.Broker,
    h: *host.Host,
    log: *LogSink,

    fn init(alloc: std.mem.Allocator, dir_path: []const u8) !Rig {
        const vessels = try alloc.create(vstore.Store);
        vessels.* = try vstore.Store.init(alloc);
        try vessels.setFamilyStaleness("navigation", nav_staleness_ms);

        const ais = try alloc.create(aisstore.AisStore);
        ais.* = aisstore.AisStore.init(alloc);

        const log = try alloc.create(LogSink);
        log.* = .{ .alloc = alloc };

        const br = try alloc.create(broker.Broker);
        br.* = broker.Broker.init(alloc, vessels, ais, .{});
        // The default sink prints through std.debug, which under `zig build
        // test` shares a stream with the build runner's protocol. Keep the
        // lines here instead, and assert on them at the end.
        br.setLog(log, LogSink.write);

        const h = try alloc.create(host.Host);
        // No seed address: this test owns both connection lists, and a seeded
        // row would dial whatever happens to listen on the default port.
        h.* = host.Host.init(alloc, br, .{ .nmea_host = "" });
        try h.loadDir(dir_path);
        return .{ .alloc = alloc, .vessels = vessels, .ais = ais, .br = br, .h = h, .log = log };
    }

    fn deinit(self: *Rig) void {
        self.h.stop();
        self.h.deinit();
        self.br.deinit();
        self.ais.deinit();
        self.vessels.deinit();
        self.log.text.deinit(self.alloc);
        self.alloc.destroy(self.h);
        self.alloc.destroy(self.br);
        self.alloc.destroy(self.ais);
        self.alloc.destroy(self.vessels);
        self.alloc.destroy(self.log);
    }
};

/// A plugin directory holding the named pairs.
fn plugDir(alloc: std.mem.Allocator, tmp: *std.testing.TmpDir, comptime which: enum { sk, both }) ![]u8 {
    try tmp.dir.writeFile(io, .{ .sub_path = sk_id ++ ".wasm", .data = sk_wasm });
    try tmp.dir.writeFile(io, .{ .sub_path = sk_id ++ ".manifest.json", .data = sk_manifest });
    if (which == .both) {
        try tmp.dir.writeFile(io, .{ .sub_path = nmea_id ++ ".wasm", .data = nmea_wasm });
        try tmp.dir.writeFile(io, .{ .sub_path = nmea_id ++ ".manifest.json", .data = nmea_manifest });
    }
    return std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{tmp.sub_path});
}

fn serverRow(alloc: std.mem.Allocator, out: *std.ArrayList(u8), port: u16, enabled: bool) !void {
    return serverRowKind(alloc, out, port, enabled, false);
}

fn serverRowKind(alloc: std.mem.Allocator, out: *std.ArrayList(u8), port: u16, enabled: bool, ws: bool) !void {
    out.clearRetainingCapacity();
    try out.print(
        alloc,
        "{{\"servers\":[{{\"id\":\"s-main\",\"name\":\"Boat server\",\"host\":\"127.0.0.1\"," ++
            "\"port\":{d},\"websocket\":{s},\"enabled\":{s}}}]}}",
        .{ port, if (ws) "true" else "false", if (enabled) "true" else "false" },
    );
}

// ---------------------------------------------------------------------------
// the tests
// ---------------------------------------------------------------------------

test "a Signal K server feeds the chart, and the mariner can pause it" {
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const dir_path = try plugDir(alloc, &tmp, .sk);
    defer alloc.free(dir_path);

    var sk = Server{};
    try sk.open();
    defer sk.close();

    var rig = try Rig.init(alloc, dir_path);
    defer rig.deinit();
    try std.testing.expectEqual(@as(usize, 1), rig.h.count());
    try rig.h.start();

    var cfg: std.ArrayList(u8) = .empty;
    defer cfg.deinit(alloc);
    try serverRow(alloc, &cfg, sk.port, true);
    try rig.h.configSet(sk_id, cfg.items);

    // Own ship arrives. The server sends nothing until it has read a
    // subscription, so reaching this line proves the plugin sent one.
    try waitFor("own ship in the store", rig.vessels, struct {
        fn ready(v: *vstore.Store) bool {
            return number(v, heading_path) != null and pathValue(v, position_path) != null;
        }
    }.ready);
    try must(sk.subscribed.load(.monotonic) >= 1, "the plugin subscribed");

    // The subscription is the one the spec's schema describes.
    const req = sk.request();
    try must(std.mem.indexOf(u8, req, "\"context\":\"*\"") != null, "the subscription asks for every context");
    try must(std.mem.indexOf(u8, req, "\"path\":\"*\"") != null, "the subscription asks for every path");

    // Radians in, degrees out. pi/2 is 90, and a plugin that forgot to
    // convert would have published 1.5707963267948966.
    try std.testing.expectApproxEqAbs(@as(f64, 90.0), number(rig.vessels, heading_path).?, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 2.5722), number(rig.vessels, sog_path).?, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 4.1), number(rig.vessels, depth_path).?, 1e-9);
    const pos = pathValue(rig.vessels, position_path).?;
    try must(pos.value == .position, "the position is a position");
    try std.testing.expectApproxEqAbs(@as(f64, 38.9763), pos.value.position.lat, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, -76.4767), pos.value.position.lon, 1e-9);

    // The AIS target the server heard, keyed by the MMSI in its context.
    try waitFor("the AIS target in the store", rig.ais, struct {
        fn ready(a: *aisstore.AisStore) bool {
            const g = a.get(899000505) orelse return false;
            return g.name() != null and g.cog != null;
        }
    }.ready);
    const target = rig.ais.get(899000505).?;
    try std.testing.expectApproxEqAbs(@as(f64, 38.966), target.lat.?, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, -76.434), target.lon.?, 1e-9);
    // Speed over ground is metres per second on both sides of the wire.
    try std.testing.expectApproxEqAbs(@as(f64, 2.1), target.sog.?, 1e-9);
    // Course over ground is radians on the wire and degrees in the store.
    try std.testing.expectApproxEqAbs(@as(f64, 300.0), target.cog.?, 1e-9);
    try std.testing.expectEqualStrings("TIN WHISTLE", target.name().?);
    // The vessel with a UUID context has no MMSI, so it is not a target.
    try std.testing.expectEqual(@as(usize, 1), rig.ais.count());

    // The status carries one item per row, under the id the shell chose.
    const plugin = rig.h.find(sk_id) orelse return error.PluginNotLoaded;
    try waitFor("the status item for the row", plugin, struct {
        fn ready(p: *broker.Plugin) bool {
            return std.mem.indexOf(u8, p.status(), "\"s-main\"") != null and
                std.mem.indexOf(u8, p.status(), "\"state\":\"connected\"") != null;
        }
    }.ready);
    try must(std.mem.indexOf(u8, plugin.status(), "1 of 1 connected") != null, "the row is connected");
    try must(std.mem.indexOf(u8, plugin.status(), "deltas/s") != null, "the row reports a delta rate");

    // The mariner switches the server off. The stream closes and nothing
    // publishes any more.
    try serverRow(alloc, &cfg, sk.port, false);
    try rig.h.configSet(sk_id, cfg.items);
    try waitFor("the row to read paused", plugin, struct {
        fn ready(p: *broker.Plugin) bool {
            return std.mem.indexOf(u8, p.status(), "\"state\":\"paused\"") != null;
        }
    }.ready);

    // Bytes already read into the queue are still delivered, so the baseline
    // is taken after a short drain.
    broker.sleepMs(400);
    const at_pause = pathValue(rig.vessels, heading_path).?.ts_ms;
    broker.sleepMs(700);
    try must(pathValue(rig.vessels, heading_path).?.ts_ms == at_pause, "the paused row published nothing more");

    // Switching it back on reopens the stream and the server sees a second
    // client, which subscribes again.
    try serverRow(alloc, &cfg, sk.port, true);
    try rig.h.configSet(sk_id, cfg.items);
    try waitFor("a second subscription after resume", &sk, struct {
        fn ready(s: *Server) bool {
            return s.subscribed.load(.monotonic) >= 2;
        }
    }.ready);
    try waitFor("a fresh heading after resume", rig.vessels, struct {
        fn ready(v: *vstore.Store) bool {
            return !pathValue(v, heading_path).?.stale;
        }
    }.ready);

    // Through all of that the plugin stayed up and asked for nothing it was
    // not granted.
    try must(!rig.log.has("trapped"), "nothing trapped");
    try must(!rig.log.has("denied"), "no grant was refused");
    try std.testing.expectEqual(@as(u32, 0), plugin.denied);
}

test "a Signal K server and a NMEA gateway contend for one path, and it fails over" {
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const dir_path = try plugDir(alloc, &tmp, .both);
    defer alloc.free(dir_path);

    var sk = Server{};
    try sk.open();
    defer sk.close();

    // The gateway's heading is not the server's, so the store's answer says
    // which source won. "$HEHDT,123.0,T" with its checksum.
    var nmea = NmeaFeed{ .line = "$HEHDT,123.0,T*2F\r\n" };
    try nmea.open();
    defer nmea.close();

    var rig = try Rig.init(alloc, dir_path);
    defer rig.deinit();
    try std.testing.expectEqual(@as(usize, 2), rig.h.count());
    try rig.h.start();

    const sk_plugin = rig.h.find(sk_id) orelse return error.PluginNotLoaded;
    const nmea_plugin = rig.h.find(nmea_id) orelse return error.PluginNotLoaded;
    // Load order is sorted file order and load order is source priority, so
    // the gateway registered first and outranks the server.
    try must(nmea_plugin.source < sk_plugin.source, "the gateway is the higher-priority source");

    var cfg: std.ArrayList(u8) = .empty;
    defer cfg.deinit(alloc);
    try serverRow(alloc, &cfg, sk.port, true);
    try rig.h.configSet(sk_id, cfg.items);

    cfg.clearRetainingCapacity();
    try cfg.print(
        alloc,
        "{{\"connections\":[{{\"id\":\"c-gw\",\"name\":\"Gateway\",\"host\":\"127.0.0.1\",\"port\":{d},\"enabled\":true}}]}}",
        .{nmea.port},
    );
    try rig.h.configSet(nmea_id, cfg.items);

    // Both are publishing the same path. The store elects the gateway.
    try waitFor("the gateway's heading elected", rig.vessels, struct {
        fn ready(v: *vstore.Store) bool {
            const r = pathValue(v, heading_path) orelse return false;
            return !r.stale and r.value == .number and r.value.number == 123.0;
        }
    }.ready);
    // And the server is publishing too: its own paths are in the store, and
    // its own heading is the slot the election passed over.
    try waitFor("the server's speed in the store", rig.vessels, struct {
        fn ready(v: *vstore.Store) bool {
            return number(v, sog_path) != null;
        }
    }.ready);
    const elected = pathValue(rig.vessels, heading_path).?;
    try must(elected.source == nmea_plugin.source, "the gateway holds the path");

    // The gateway goes off the air. Its value ages past the window and the
    // election falls to the Signal K server, whose heading is 90 degrees.
    nmea.close();
    try waitFor("the heading to fail over to the server", rig.vessels, struct {
        fn ready(v: *vstore.Store) bool {
            const r = pathValue(v, heading_path) orelse return false;
            return !r.stale and r.value == .number and r.value.number == 90.0;
        }
    }.ready);
    const after = pathValue(rig.vessels, heading_path).?;
    try must(after.source == sk_plugin.source, "the server took the path over");
    try must(!after.stale, "the value that took over is fresh");

    try must(!rig.log.has("trapped"), "nothing trapped");
    try must(!rig.log.has("denied"), "no grant was refused");
    try std.testing.expectEqual(@as(u32, 0), sk_plugin.denied);
}

test "the same server over its websocket feeds the same chart" {
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const dir_path = try plugDir(alloc, &tmp, .sk);
    defer alloc.free(dir_path);

    var sk = Server{ .ws = true };
    try sk.open();
    defer sk.close();

    var rig = try Rig.init(alloc, dir_path);
    defer rig.deinit();
    try rig.h.start();

    var cfg: std.ArrayList(u8) = .empty;
    defer cfg.deinit(alloc);
    try serverRowKind(alloc, &cfg, sk.port, true, true);
    try rig.h.configSet(sk_id, cfg.items);

    // Everything between the plugin and the store is the TCP path's. What is
    // different is underneath: a handshake with an accept hash, masked client
    // frames, unmasked server frames, and the host reassembling each message
    // before the plugin sees a byte.
    try waitFor("own ship in the store over the websocket", rig.vessels, struct {
        fn ready(v: *vstore.Store) bool {
            return number(v, heading_path) != null and pathValue(v, position_path) != null;
        }
    }.ready);
    try must(sk.subscribed.load(.monotonic) >= 1, "the plugin subscribed over the websocket");

    // The subscription arrived as ONE websocket message with no line
    // terminator: a message is already a document, and a CR LF inside it
    // would be two bytes of noise a server has to strip.
    const req = sk.request();
    try must(std.mem.indexOf(u8, req, "\"context\":\"*\"") != null, "the subscription asks for every context");
    try must(std.mem.indexOfAny(u8, req, "\r\n") == null, "the websocket subscription carries no terminator");

    try std.testing.expectApproxEqAbs(@as(f64, 90.0), number(rig.vessels, heading_path).?, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 2.5722), number(rig.vessels, sog_path).?, 1e-9);
    const pos = pathValue(rig.vessels, position_path).?;
    try must(pos.value == .position, "the position is a position");
    try std.testing.expectApproxEqAbs(@as(f64, 38.9763), pos.value.position.lat, 1e-9);

    try waitFor("the AIS target over the websocket", rig.ais, struct {
        fn ready(a: *aisstore.AisStore) bool {
            const g = a.get(899000505) orelse return false;
            return g.name() != null and g.cog != null;
        }
    }.ready);
    try std.testing.expectEqualStrings("TIN WHISTLE", rig.ais.get(899000505).?.name().?);

    const plugin = rig.h.find(sk_id) orelse return error.PluginNotLoaded;
    try waitFor("the row to read connected", plugin, struct {
        fn ready(p: *broker.Plugin) bool {
            return std.mem.indexOf(u8, p.status(), "\"state\":\"connected\"") != null;
        }
    }.ready);

    // Pausing closes the websocket the same way it closes a socket, and
    // resuming dials a second one.
    try serverRowKind(alloc, &cfg, sk.port, false, true);
    try rig.h.configSet(sk_id, cfg.items);
    try waitFor("the websocket row to read paused", plugin, struct {
        fn ready(p: *broker.Plugin) bool {
            return std.mem.indexOf(u8, p.status(), "\"state\":\"paused\"") != null;
        }
    }.ready);
    try serverRowKind(alloc, &cfg, sk.port, true, true);
    try rig.h.configSet(sk_id, cfg.items);
    try waitFor("a second websocket subscription after resume", &sk, struct {
        fn ready(s: *Server) bool {
            return s.subscribed.load(.monotonic) >= 2;
        }
    }.ready);

    try must(!rig.log.has("trapped"), "the plugin never trapped");
    try must(!rig.log.has("denied "), "no call was refused a grant");
}

test "a websocket to a server off this boat's network is refused by the grant" {
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const dir_path = try plugDir(alloc, &tmp, .sk);
    defer alloc.free(dir_path);

    var rig = try Rig.init(alloc, dir_path);
    defer rig.deinit();
    try rig.h.start();

    // The manifest grants `local`, which is this boat's own network. A public
    // Signal K server is outside it, and the refusal happens before a socket
    // opens rather than after the plugin has sent anything.
    var cfg: std.ArrayList(u8) = .empty;
    defer cfg.deinit(alloc);
    try cfg.appendSlice(alloc, "{\"servers\":[{\"id\":\"s-far\",\"name\":\"Demo\"," ++
        "\"host\":\"demo.signalk.org\",\"port\":80,\"websocket\":true,\"enabled\":true}]}");
    try rig.h.configSet(sk_id, cfg.items);

    const plugin = rig.h.find(sk_id) orelse return error.PluginNotLoaded;
    try waitFor("the refusal to reach the row's line", plugin, struct {
        fn ready(p: *broker.Plugin) bool {
            return std.mem.indexOf(u8, p.status(), "not on this boat's network") != null;
        }
    }.ready);
    try must(rig.log.has("is not in the manifest's net.ws host list"), "the log names the host that was refused");
}

test "a plain connection to a server off this boat's network is refused by the grant" {
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const dir_path = try plugDir(alloc, &tmp, .sk);
    defer alloc.free(dir_path);

    var rig = try Rig.init(alloc, dir_path);
    defer rig.deinit();
    try rig.h.start();

    // The same grant, the other transport. `net.tcp-client` carries the
    // addresses it may dial, and `local` is this boat's own network: a public
    // server is refused before a socket opens, and it is refused ONCE rather
    // than retried every two seconds for ever.
    var cfg: std.ArrayList(u8) = .empty;
    defer cfg.deinit(alloc);
    try cfg.appendSlice(alloc, "{\"servers\":[{\"id\":\"s-far\",\"name\":\"Demo\"," ++
        "\"host\":\"demo.signalk.org\",\"port\":8375,\"websocket\":false,\"enabled\":true}]}");
    try rig.h.configSet(sk_id, cfg.items);

    const plugin = rig.h.find(sk_id) orelse return error.PluginNotLoaded;
    try waitFor("the refusal to reach the row's line", plugin, struct {
        fn ready(p: *broker.Plugin) bool {
            return std.mem.indexOf(u8, p.status(), "outside what this plugin may dial") != null;
        }
    }.ready);
    try must(
        rig.log.has("is not in the manifest's net.tcp-client address list"),
        "the log names the address that was refused",
    );

    // One refusal, not a stream of them: the row stopped.
    const first = plugin.denied;
    broker.sleepMs(3 * 1000);
    try must(plugin.denied == first, "a refused address is not dialled again");
}
