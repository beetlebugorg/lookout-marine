//! An AISCast relay feeding the chart: the real aiscast .wasm, the
//! real host, the real broker sockets, and a loopback websocket server that
//! speaks the relay's tiny v1 protocol.
//!
//! What it proves, which nothing else does:
//!   - the view crosses the plugin boundary: the chart camera's box, pushed
//!     through `Broker.setView`, comes out the other side as a subscribe
//!     frame whose box contains the view;
//!   - the subscription follows the view with hysteresis: a big move
//!     resubscribes on the same socket, a nudge does not;
//!   - a relay event lands in the AIS store marked `net`, with knots
//!     converted to metres per second, the heading sentinel dropped and the
//!     name trimmed;
//!   - freshest wins: a relayed event carrying an old `time` never overwrites
//!     a fresher target another source holds;
//!   - an error frame is logged and skipped, not crashed on.
//!
//! The plugin arrives as an anonymous import, like plugins/echo does for
//! host_smoke: importing host.zig must never drag a plugin binary into the
//! core.

const std = @import("std");
const host = @import("host");

const broker = host.broker;
const vstore = host.store;
const aisstore = host.aisstore;

const ac_wasm = @embedFile("aiscast_plugin_wasm");
const ac_manifest = @embedFile("aiscast_manifest");
const ac_id = "org.beetlebug.aiscast";

const nmea_wasm = @embedFile("nmea_plugin_wasm");
const nmea_manifest = @embedFile("nmea_manifest");
const nmea_id = "org.beetlebug.nmea0183";

const io = std.Io.Threaded.global_single_threaded.io();

const deadline_ms: i64 = 8_000;

/// A token the length the real relay issues. A short stand-in would fit any
/// buffer and prove nothing: the live relay's personal token is a little over
/// 300 bytes, and one that does not fit is silently discarded.
const loopback_token = "ak1." ++ "L" ** 310 ++ ".sig";

/// What the loopback relay streams once subscribed, over and over. One frame
/// per line. The `time`-less events take the receipt stamp; the OLD-timed one
/// for MMSI 111 must always lose to the fresher target the test planted.
const events =
    \\{"type":"error","error":"loopback says hello"}
    \\{"type":"event","mmsi":899000404,"msg_type":"PositionReport","lat":59.44,"lon":10.51,"message":{"UserID":899000404,"Sog":5.1,"Cog":210.5,"TrueHeading":511}}
    \\{"type":"event","mmsi":899000404,"msg_type":"ShipStaticData","lat":59.44,"lon":10.51,"message":{"Name":"TANGERINE OTTER   "}}
    \\{"type":"event","mmsi":111000111,"msg_type":"PositionReport","lat":40.0,"lon":-70.0,"time":"2020-01-01T00:00:00Z","message":{"Sog":1.0,"Cog":1.0}}
    \\{"type":"event","mmsi":998990002,"msg_type":"AidsToNavigationReport","lat":59.5,"lon":10.6,"message":{"Name":"WRECK MARK@@","Type":28,"VirtualAtoN":true,"OffPosition":false}}
;

// ---------------------------------------------------------------------------
// a loopback relay
// ---------------------------------------------------------------------------

/// One pretend aiscast relay: upgrade, wait for a subscribe frame, stream the
/// canned events, and keep counting subscribe frames as they come.
const Relay = struct {
    fd: std.c.fd_t = -1,
    port: u16 = 0,
    thread: ?std.Thread = null,
    stop: std.atomic.Value(bool) = .init(false),
    accepted: std.atomic.Value(u32) = .init(0),
    /// Subscribe frames read so far, across the connection's whole life —
    /// a resubscribe on the same socket counts here.
    subscribed: std.atomic.Value(u32) = .init(0),
    /// The latest subscribe frame, for the test to read back.
    last_request: [256]u8 = undefined,
    last_request_len: std.atomic.Value(u32) = .init(0),
    /// Register frames answered with a key, and publish frames acked.
    registers: std.atomic.Value(u32) = .init(0),
    publishes: std.atomic.Value(u32) = .init(0),
    /// The latest publish frame, verbatim JSON — and a sticky flag for the
    /// boat's own report, which VDM-only frames would otherwise overwrite
    /// before the test looks.
    last_publish: [2048]u8 = undefined,
    last_publish_len: std.atomic.Value(u32) = .init(0),
    saw_vdo: std.atomic.Value(bool) = .init(false),
    /// The connection's read buffer; frames can arrive split. Publish frames
    /// carry a couple of KB of sentences.
    buf: [4096]u8 = undefined,
    buf_len: usize = 0,

    fn open(self: *Relay) !void {
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

    fn close(self: *Relay) void {
        self.stop.store(true, .release);
        if (self.thread) |th| th.join();
        self.thread = null;
        if (self.fd >= 0) _ = std.c.close(self.fd);
        self.fd = -1;
    }

    fn run(self: *Relay) void {
        while (!self.stop.load(.acquire)) {
            const peer = acceptOne(self.fd) orelse continue;
            defer _ = std.c.close(peer);
            noSigPipe(peer);
            _ = self.accepted.fetchAdd(1, .monotonic);
            self.buf_len = 0;
            if (!self.upgrade(peer)) continue;
            // The first frame on every accepted socket is the anonymous
            // tier's welcome, which is what the real relay sends.
            if (!writeWsText(peer, "{\"type\":\"welcome\",\"limits\":{\"conns\":2,\"rate\":20,\"area\":100,\"mmsis\":10,\"connects_per_min\":20}}")) continue;

            // Nothing until the first subscribe, which is the relay's rule.
            const before = self.subscribed.load(.monotonic);
            const until = broker.monoMs() + deadline_ms;
            while (self.subscribed.load(.monotonic) == before) {
                if (self.stop.load(.acquire) or broker.monoMs() > until) break;
                if (!self.pump(peer, 50)) break;
            }
            if (self.subscribed.load(.monotonic) == before) continue;

            stream: while (!self.stop.load(.acquire)) {
                var it = std.mem.splitScalar(u8, events, '\n');
                while (it.next()) |line| {
                    if (line.len == 0) continue;
                    if (self.stop.load(.acquire)) break :stream;
                    if (!writeWsText(peer, line)) break :stream;
                    // A resubscribe can arrive at any point in the stream.
                    if (!self.pump(peer, 0)) break :stream;
                    broker.sleepMs(40);
                }
            }
        }
    }

    /// Poll the peer for up to `wait_ms`, read what is there, and account
    /// every complete subscribe frame. False when the peer went away.
    fn pump(self: *Relay, peer: std.c.fd_t, wait_ms: i32) bool {
        var fds = [_]std.c.pollfd{.{ .fd = peer, .events = std.c.POLL.IN, .revents = 0 }};
        const n = std.posix.poll(&fds, wait_ms) catch return false;
        if (n > 0) {
            const got = std.c.read(peer, self.buf[self.buf_len..].ptr, self.buf.len - self.buf_len);
            if (got <= 0) return false;
            self.buf_len += @intCast(got);
        }
        var frame: [2048]u8 = undefined;
        while (readWsText(self.buf[0..self.buf_len], &frame)) |r| {
            std.mem.copyForwards(u8, self.buf[0 .. self.buf_len - r.used], self.buf[r.used..self.buf_len]);
            self.buf_len -= r.used;
            if (std.mem.indexOf(u8, r.text, "\"subscribe\"") != null) {
                const keep = @min(r.text.len, self.last_request.len);
                @memcpy(self.last_request[0..keep], r.text[0..keep]);
                self.last_request_len.store(@intCast(keep), .release);
                _ = self.subscribed.fetchAdd(1, .monotonic);
            } else if (std.mem.indexOf(u8, r.text, "\"register\"") != null) {
                // The in-band register: answer a key frame and confirm the
                // in-place upgrade with a fresh welcome carrying the personal
                // tier's limits, which is what the real relay does.
                _ = self.registers.fetchAdd(1, .monotonic);
                _ = writeWsText(peer, "{\"type\":\"key\",\"token\":\"" ++ loopback_token ++ "\",\"claims\":{\"role\":\"personal\"}}");
                _ = writeWsText(peer, "{\"type\":\"welcome\",\"sub\":\"ed25519:loopback\",\"role\":\"personal\",\"feeder\":false," ++
                    "\"limits\":{\"conns\":2,\"rate\":50,\"area\":400,\"mmsis\":50,\"publish\":true,\"publish_per_min\":6000,\"publish_frame\":1000,\"connects_per_min\":20}}");
            } else if (std.mem.indexOf(u8, r.text, "\"publish\"") != null) {
                const keep = @min(r.text.len, self.last_publish.len);
                @memcpy(self.last_publish[0..keep], r.text[0..keep]);
                self.last_publish_len.store(@intCast(keep), .release);
                if (std.mem.indexOf(u8, r.text, "!AIVDO,1,1,,A,") != null) self.saw_vdo.store(true, .release);
                _ = self.publishes.fetchAdd(1, .monotonic);
                _ = writeWsText(peer, "{\"type\":\"ack\",\"n\":1}");
            }
        }
        return true;
    }

    fn upgrade(self: *Relay, peer: std.c.fd_t) bool {
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
        // A plugin that dialled anything but the v1 stream shows up here.
        if (std.mem.indexOf(u8, text, "GET /v1/stream") == null) return false;
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

    fn request(self: *Relay) []const u8 {
        return self.last_request[0..self.last_request_len.load(.acquire)];
    }

    fn publishFrame(self: *Relay) []const u8 {
        return self.last_publish[0..self.last_publish_len.load(.acquire)];
    }
};

/// One pretend NMEA gateway, streaming canned AIVDM/AIVDO lines.
const NmeaFeed = struct {
    fd: std.c.fd_t = -1,
    port: u16 = 0,
    /// Whole sentences with checksums, CRLF-terminated.
    lines: []const u8,
    thread: ?std.Thread = null,
    stop: std.atomic.Value(bool) = .init(false),

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
            while (!self.stop.load(.acquire)) {
                if (!writeAll(peer, self.lines)) break;
                broker.sleepMs(50);
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

fn noSigPipe(peer: std.c.fd_t) void {
    if (@hasDecl(std.c.SO, "NOSIGPIPE")) {
        var yes: c_int = 1;
        _ = std.c.setsockopt(peer, std.c.SOL.SOCKET, std.c.SO.NOSIGPIPE, &yes, @sizeOf(c_int));
    }
}

/// One unmasked server text frame (a server frame is never masked).
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

/// One MASKED client text frame out of `raw`, unmasked into `out`. Returns
/// the payload and how many bytes of `raw` the frame consumed, or null while
/// it is not all there yet.
fn readWsText(raw: []const u8, out: []u8) ?struct { text: []const u8, used: usize } {
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
    return .{ .text = out[0..len], .used = at + 4 + len };
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

/// Keeps every broker log line, so the test can prove the plugin never
/// trapped and the error frame was logged.
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

        const ais = try alloc.create(aisstore.AisStore);
        ais.* = aisstore.AisStore.init(alloc);

        const log = try alloc.create(LogSink);
        log.* = .{ .alloc = alloc };

        const br = try alloc.create(broker.Broker);
        br.* = broker.Broker.init(alloc, vessels, ais, .{});
        br.setLog(log, LogSink.write);
        // Plugin storage stays in the test's own directory: without this the
        // minted identity lands in the MACHINE'S real plugin storage, poisons
        // later runs into skipping the mint, and hands the real app a
        // loopback token.
        br.setStorageDir(dir_path);

        const h = try alloc.create(host.Host);
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

/// A plugin directory holding the aiscast pair — its manifest granted `local`
/// instead of the production host so it may dial the loopback relay — and,
/// for the sharing test, the nmea0183 pair beside it.
fn plugDir(alloc: std.mem.Allocator, tmp: *std.testing.TmpDir, comptime which: enum { ac, both }) ![]u8 {
    const local_manifest = try std.mem.replaceOwned(u8, alloc, ac_manifest, "\"ais.openwaters.io\"", "\"local\"");
    defer alloc.free(local_manifest);
    try tmp.dir.writeFile(io, .{ .sub_path = ac_id ++ ".wasm", .data = ac_wasm });
    try tmp.dir.writeFile(io, .{ .sub_path = ac_id ++ ".manifest.json", .data = local_manifest });
    if (which == .both) {
        try tmp.dir.writeFile(io, .{ .sub_path = nmea_id ++ ".wasm", .data = nmea_wasm });
        try tmp.dir.writeFile(io, .{ .sub_path = nmea_id ++ ".manifest.json", .data = nmea_manifest });
    }
    return std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{tmp.sub_path});
}

fn serverRow(alloc: std.mem.Allocator, out: *std.ArrayList(u8), port: u16) !void {
    return serverRowShare(alloc, out, port, false);
}

fn serverRowShare(alloc: std.mem.Allocator, out: *std.ArrayList(u8), port: u16, share: bool) !void {
    out.clearRetainingCapacity();
    try out.print(
        alloc,
        "{{\"servers\":[{{\"id\":\"r-main\",\"name\":\"Loopback relay\",\"host\":\"127.0.0.1\"," ++
            "\"port\":{d},\"share\":{s},\"enabled\":true}}]}}",
        .{ port, if (share) "true" else "false" },
    );
}

// ---------------------------------------------------------------------------
// the test
// ---------------------------------------------------------------------------

test "the relay feeds the chart for the view, and the receiver still outranks it" {
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const dir_path = try plugDir(alloc, &tmp, .ac);
    defer alloc.free(dir_path);

    var relay = Relay{};
    try relay.open();
    defer relay.close();

    var rig = try Rig.init(alloc, dir_path);
    defer rig.deinit();
    try std.testing.expectEqual(@as(usize, 1), rig.h.count());

    // The fresher target the relay's old-timed event must never overwrite.
    _ = try rig.ais.upsert(.{ .mmsi = 111000111, .lat = 38.98, .lon = -76.47, .ts_ms = broker.wallMs() }, 7);

    // The chart is looking at the Oslofjord before the plugin starts, so the
    // first VIEW_CHANGED carries a real box.
    rig.br.setView(.{ .min_lat = 59.0, .min_lon = 10.0, .max_lat = 60.0, .max_lon = 11.0 });

    try rig.h.start();
    var cfg: std.ArrayList(u8) = .empty;
    defer cfg.deinit(alloc);
    try serverRow(alloc, &cfg, relay.port);
    try rig.h.configSet(ac_id, cfg.items);

    // The relay sends nothing until it has read a subscribe frame, so a
    // target in the store proves the whole path: view fanout, subscribe,
    // upgrade, event, upsert.
    try waitFor("the vessel in the AIS store", rig.ais, struct {
        fn ready(a: *aisstore.AisStore) bool {
            const g = a.get(899000404) orelse return false;
            return g.name() != null;
        }
    }.ready);

    // The subscribe frame is the view padded by the margin.
    try must(std.mem.eql(u8, relay.request(), "{\"type\":\"subscribe\",\"snapshot\":true,\"bbox\":[[58.7000,9.7000,60.3000,11.3000]]}"), "the subscription is the padded view");

    // Knots became metres per second, the heading sentinel became absence,
    // the name lost its padding, and the batch carried `net`.
    const vessel = rig.ais.get(899000404).?;
    try must(vessel.net, "the vessel is marked internet");
    try std.testing.expectApproxEqAbs(@as(f64, 5.1 * 1852.0 / 3600.0), vessel.sog.?, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 210.5), vessel.cog.?, 1e-9);
    try must(vessel.heading == null, "TrueHeading 511 reads as unavailable");
    try std.testing.expectEqualStrings("TANGERINE OTTER", vessel.name().?);

    // The aid came through with its nature, and the '@' padding trimmed.
    try waitFor("the aid in the AIS store", rig.ais, struct {
        fn ready(a: *aisstore.AisStore) bool {
            return a.get(998990002) != null;
        }
    }.ready);
    const aid = rig.ais.get(998990002).?;
    try must(aid.aton, "the aid is an aid");
    try must(aid.virtual_aton, "the aid is virtual");
    try must(aid.off_position == false, "the aid is on station");
    try std.testing.expectEqualStrings("WRECK MARK", aid.name().?);

    // Freshest wins: the relay's 2020-timed event for 111000111 has been
    // arriving all along and the fresher receiver-held target never moved.
    const held = rig.ais.get(111000111).?;
    try must(!held.net, "the receiver's target is not marked internet");
    try std.testing.expectApproxEqAbs(@as(f64, 38.98), held.lat.?, 1e-9);

    // The error frame was words in the log, not a trap.
    try must(rig.log.has("loopback says hello"), "the error frame was logged");

    // A big move resubscribes on the same socket.
    const subs_before = relay.subscribed.load(.monotonic);
    rig.br.setView(.{ .min_lat = 20.0, .min_lon = -40.0, .max_lat = 21.0, .max_lon = -39.0 });
    try waitFor("the resubscription", &relay, struct {
        fn ready(r: *Relay) bool {
            return std.mem.indexOf(u8, r.request(), "19.7000") != null;
        }
    }.ready);
    try must(relay.subscribed.load(.monotonic) > subs_before, "the move produced a new subscribe frame");
    try must(relay.accepted.load(.monotonic) == 1, "the resubscribe reused the socket");

    // A nudge inside the subscribed box does not.
    const subs_after_move = relay.subscribed.load(.monotonic);
    rig.br.setView(.{ .min_lat = 20.05, .min_lon = -39.95, .max_lat = 21.05, .max_lon = -38.95 });
    broker.sleepMs(2_200); // past the resubscribe rate limit, so silence is a decision
    try must(relay.subscribed.load(.monotonic) == subs_after_move, "a nudge did not resubscribe");

    // Nothing trapped and nothing was refused a grant.
    try must(!rig.log.has("trap"), "no plugin trapped");
    try must(!rig.log.has("denied"), "nothing was denied");
}

test "the receiver's sentences ride the bus to the relay, minted and acked" {
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const dir_path = try plugDir(alloc, &tmp, .both);
    defer alloc.free(dir_path);

    var relay = Relay{};
    try relay.open();
    defer relay.close();

    // A VDM the plugin must share, and a VDO — this boat's own transmission —
    // it must not. Both carry valid checksums or the feeder drops them.
    var feed = NmeaFeed{ .lines = "!AIVDM,1,1,,A,13HOI:0P0000VOHLCnHQKwvL05Ip,0*23\r\n" ++
        "!AIVDO,1,1,,A,13HOI:0P0000VOHLCnHQKwvL05Ip,0*21\r\n" };
    try feed.open();
    defer feed.close();

    var rig = try Rig.init(alloc, dir_path);
    defer rig.deinit();
    try std.testing.expectEqual(@as(usize, 2), rig.h.count());

    rig.br.setView(.{ .min_lat = 59.0, .min_lon = 10.0, .max_lat = 60.0, .max_lon = 11.0 });
    try rig.h.start();

    var cfg: std.ArrayList(u8) = .empty;
    defer cfg.deinit(alloc);
    try serverRowShare(alloc, &cfg, relay.port, true);
    try rig.h.configSet(ac_id, cfg.items);
    cfg.clearRetainingCapacity();
    try cfg.print(
        alloc,
        "{{\"connections\":[{{\"id\":\"c-ais\",\"name\":\"Receiver\",\"host\":\"127.0.0.1\",\"port\":{d},\"enabled\":true}}]}}",
        .{feed.port},
    );
    try rig.h.configSet(nmea_id, cfg.items);

    // The whole path in one wait: gateway -> nmea0183 -> bus -> aiscast ->
    // register -> key -> welcome -> publish -> ack. Nothing publishes until
    // a welcome says the socket may, so a publish frame proves the register
    // round-trip too.
    try waitFor("a publish frame at the relay", &relay, struct {
        fn ready(r: *Relay) bool {
            return r.publishes.load(.monotonic) >= 1;
        }
    }.ready);

    // Exactly one identity was registered, however many frames flowed.
    if (relay.registers.load(.monotonic) != 1) {
        std.debug.print("\nregisters={d} accepted={d} subscribed={d}\n", .{
            relay.registers.load(.monotonic),
            relay.accepted.load(.monotonic),
            relay.subscribed.load(.monotonic),
        });
    }
    try must(relay.registers.load(.monotonic) == 1, "one register, no more");

    // The frame carries the VDM with its TAG block naming the source row —
    // JSON-escaped backslashes on the wire.
    const frame = relay.publishFrame();
    try must(std.mem.indexOf(u8, frame, "\\\\s:lk1*7F\\\\!AIVDM,1,1,,A,13HOI:0P0000VOHLCnHQKwvL05Ip,0*23") != null, "the tagged VDM is in the publish frame");

    // The receiver's target reached the store as receiver-heard, not net:
    // the bus carried the raw sentence while ais_upsert carried the decode.
    try waitFor("the receiver's target in the store", rig.ais, struct {
        fn ready(a: *aisstore.AisStore) bool {
            return a.get(227006760) != null;
        }
    }.ready);
    try must(!rig.ais.get(227006760).?.net, "the receiver's target is not marked internet");

    // The same consent covers the boat's own transponder report, which goes
    // upstream verbatim — MMSI and all.
    try waitFor("the boat's own report at the relay", &relay, struct {
        fn ready(r: *Relay) bool {
            return r.saw_vdo.load(.acquire);
        }
    }.ready);

    // The identity was KEPT, not just used. A token too big for the plugin's
    // buffer would still publish this session — the welcome is what opens the
    // gate — and then register again on every start, so only the stored file
    // proves the token survived.
    try waitFor("the identity in plugin storage", &tmp, struct {
        fn ready(d: *std.testing.TmpDir) bool {
            var buf: [4096]u8 = undefined;
            const text = d.dir.readFile(io, ac_id ++ ".json", &buf) catch return false;
            // The store keeps values base64-encoded, a value being bytes, so
            // the token is only findable once it is decoded back.
            const at = std.mem.indexOf(u8, text, "\"b64\":\"") orelse return false;
            const rest = text[at + 7 ..];
            const end = std.mem.indexOfScalar(u8, rest, '"') orelse return false;
            const dec = std.base64.standard.Decoder;
            var out: [2048]u8 = undefined;
            const n = dec.calcSizeForSlice(rest[0..end]) catch return false;
            if (n > out.len) return false;
            dec.decode(out[0..n], rest[0..end]) catch return false;
            return std.mem.indexOf(u8, out[0..n], loopback_token) != null;
        }
    }.ready);

    try must(!rig.log.has("trap"), "no plugin trapped");
    try must(!rig.log.has("denied"), "nothing was denied");
}
