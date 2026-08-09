//! One HTTP fetch in flight: what the plugin asked for, the thread that runs
//! it, and the one HTTP_RESPONSE every request ends with.
//!
//! `webio.zig` speaks HTTP; this file is the part that belongs to a plugin.

const std = @import("std");

const broker = @import("../broker.zig");
const caps = @import("caps.zig");
const queue = @import("queue.zig");
const registry_json = @import("registry_json.zig");
const testing = @import("testing.zig");

const net = @import("../net.zig");
const webio = @import("../webio.zig");

const Broker = broker.Broker;
const Event = queue.Event;
const Kind = caps.Kind;
const level_warn = caps.level_warn;
const writeJsonString = registry_json.writeJsonString;
const writeJsonStringTo = registry_json.writeJsonStringTo;

/// Fetches allowed at once across every plugin. Each holds a thread and a TLS
/// session of about 70 KiB, and a chartplotter downloading four things at once
/// is already doing more than one mariner asked for.
pub const http_max_inflight: u32 = 4;

/// Largest response body a fetch will hold. Over this the fetch fails and says
/// so: a plugin that wants a 200 MB GRIB asks for it in ranges.
pub const http_max_body: usize = 4 * 1024 * 1024;

/// What `http_fetch` was asked for, copied out of the plugin's memory: the
/// worker thread outlives the call that started it.
pub const FetchRequest = struct {
    method: []u8,
    url: []u8,
    range: []u8,
    headers: []webio.Header,

    pub fn deinit(self: *FetchRequest, alloc: std.mem.Allocator) void {
        alloc.free(self.method);
        alloc.free(self.url);
        alloc.free(self.range);
        for (self.headers) |h| {
            alloc.free(h.name);
            alloc.free(h.value);
        }
        if (self.headers.len > 0) alloc.free(self.headers);
        self.* = undefined;
    }
};

/// One fetch, owned by its own thread and listed in the broker only so it can
/// be cancelled. `fd` and `cancelled` are guarded by the broker's `mu`.
pub const Fetch = struct {
    br: *Broker,
    id: i64,
    plugin: u32,
    req: FetchRequest,
    fd: net.Socket = net.invalid,
    cancelled: bool = false,

    /// Give up. Shutting the socket down — rather than closing it — makes the
    /// worker's blocking read return at once while the descriptor stays valid
    /// under the thread that owns it.
    pub fn cancelLocked(self: *Fetch) void {
        self.cancelled = true;
        if (net.valid(self.fd)) net.shutdownBoth(self.fd);
    }
};

/// Told by webio which socket the fetch is using, and told again with
/// `net.invalid` before that socket is closed. Both happen under `mu`, which is
/// what makes `cancelLocked` safe: it either sees a live descriptor and shuts
/// it down, or sees none and does nothing.
fn fetchSocket(ctx: ?*anyopaque, fd: net.Socket) void {
    const f: *Fetch = @ptrCast(@alignCast(ctx orelse return));
    f.br.mu.lock();
    defer f.br.mu.unlock();
    f.fd = fd;
}

pub fn fetchMain(f: *Fetch) void {
    const br = f.br;
    defer {
        br.retireFetch(f);
        _ = br.workers.fetchSub(1, .acq_rel);
    }
    var resp = webio.fetch(br.alloc, .{
        .method = f.req.method,
        .url = f.req.url,
        .headers = f.req.headers,
        .range = f.req.range,
        .max_body = http_max_body,
        .socket_ctx = f,
        .onSocket = fetchSocket,
    }) catch |e| {
        deliverFetchError(f, @errorName(e));
        return;
    };
    defer resp.deinit();
    deliverFetch(f, &resp);
}

/// True when the plugin that asked is gone, or the host is shutting down. A
/// cancelled fetch delivers nothing: the queue it would push into is being torn
/// down, and an event nobody will handle is worse than no event.
fn fetchCancelled(f: *Fetch) bool {
    f.br.mu.lock();
    defer f.br.mu.unlock();
    return f.cancelled;
}

/// `u32 json_len | status+headers JSON | raw body`. One buffer, because a
/// plugin needs both halves and the API carries one payload per event.
fn deliverFetch(f: *Fetch, resp: *webio.Response) void {
    if (fetchCancelled(f)) return;
    const alloc = f.br.alloc;
    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(alloc);
    json.print(alloc, "{{\"status\":{d},\"url\":", .{resp.status}) catch return;
    writeJsonString(&json, alloc, resp.url) catch return;
    json.appendSlice(alloc, ",\"headers\":{") catch return;
    for (resp.headers, 0..) |h, i| {
        if (i > 0) json.append(alloc, ',') catch return;
        writeJsonString(&json, alloc, h.name) catch return;
        json.append(alloc, ':') catch return;
        writeJsonString(&json, alloc, h.value) catch return;
    }
    json.appendSlice(alloc, "}}") catch return;

    var payload = alloc.alloc(u8, 4 + json.items.len + resp.body.len) catch return;
    defer alloc.free(payload);
    std.mem.writeInt(u32, payload[0..4], @intCast(json.items.len), .little);
    @memcpy(payload[4 .. 4 + json.items.len], json.items);
    @memcpy(payload[4 + json.items.len ..], resp.body);
    f.br.push(f.plugin, Kind.http_response, @bitCast(f.id), payload);
}

/// A fetch that never produced a response answers with status 0 and the reason.
/// The plugin still gets exactly one HTTP_RESPONSE per request id, so nothing
/// has to time a request out on its own.
fn deliverFetchError(f: *Fetch, reason: []const u8) void {
    f.br.say(level_warn, f.br.idOf(f.plugin), "http_fetch {s}: {s}", .{ f.req.url, reason });
    if (fetchCancelled(f)) return;
    var buf: [768]u8 = undefined;
    var w = std.Io.Writer.fixed(buf[4..]);
    w.writeAll("{\"status\":0,\"url\":") catch return;
    writeJsonStringTo(&w, f.req.url);
    w.writeAll(",\"headers\":{},\"error\":") catch return;
    writeJsonStringTo(&w, reason);
    w.writeAll("}") catch return;
    const json_len = w.buffered().len;
    std.mem.writeInt(u32, buf[0..4], @intCast(json_len), .little);
    f.br.push(f.plugin, Kind.http_response, @bitCast(f.id), buf[0 .. 4 + json_len]);
}

const t = std.testing;
const Fixture = testing.Fixture;
const nextEvent = testing.nextEvent;
const test_body = testing.test_body;

/// A loopback HTTP/1.1 server for the fetch tests. One thread, one connection
/// at a time, a canned reply per path, and Range honoured on /plain.
const TestHttp = struct {
    alloc: std.mem.Allocator,
    fd: net.Socket,
    port: u16,
    th: ?std.Thread = null,
    stopping: std.atomic.Value(bool) = .init(false),
    /// Requests answered, so a test can prove a redirect made two.
    served: std.atomic.Value(u32) = .init(0),

    fn open(alloc: std.mem.Allocator) !*TestHttp {
        const self = try alloc.create(TestHttp);
        var port: u16 = 0;
        const fd = try net.listen4(&port);
        net.setNonBlocking(fd);
        self.* = .{ .alloc = alloc, .fd = fd, .port = port };
        self.th = try std.Thread.spawn(.{ .stack_size = 512 * 1024 }, run, .{self});
        return self;
    }

    fn close(self: *TestHttp) void {
        self.stopping.store(true, .release);
        if (self.th) |th| th.join();
        net.close(self.fd);
        self.alloc.destroy(self);
    }

    fn run(self: *TestHttp) void {
        while (!self.stopping.load(.acquire)) {
            var fds = [_]net.pollfd{.{ .fd = self.fd, .events = net.POLL.IN, .revents = 0 }};
            if (net.poll(&fds, 20) == 0) continue;
            const peer = net.accept(self.fd) catch continue;
            defer net.close(peer);
            self.serve(peer);
        }
    }

    fn serve(self: *TestHttp, peer: net.Socket) void {
        // macOS hands an accepted socket the listener's O_NONBLOCK, so a read
        // here would fail with EAGAIN before the request had arrived and the
        // server would answer nothing at all. Blocking, with a deadline so a
        // broken test cannot hang the suite.
        net.setBlocking(peer);
        net.setTimeouts(peer, 3_000);
        var head: [4096]u8 = undefined;
        var used: usize = 0;
        while (std.mem.indexOf(u8, head[0..used], "\r\n\r\n") == null) {
            if (used == head.len) return;
            const n = net.recv(peer, head[used..]);
            if (n <= 0) return;
            used += @intCast(n);
        }
        _ = self.served.fetchAdd(1, .acq_rel);
        const text = head[0..used];
        const line_end = std.mem.indexOf(u8, text, "\r\n") orelse return;
        var it = std.mem.tokenizeScalar(u8, text[0..line_end], ' ');
        _ = it.next() orelse return; // method
        const target = it.next() orelse return;

        var out: [1024]u8 = undefined;
        if (std.mem.eql(u8, target, "/plain")) {
            if (rangeOf(text)) |r| {
                const from = @min(r[0], test_body.len);
                const to = @min(r[1] + 1, test_body.len);
                const slice = test_body[from..to];
                const msg = std.fmt.bufPrint(&out, "HTTP/1.1 206 Partial Content\r\ncontent-type: text/plain\r\n" ++
                    "content-range: bytes {d}-{d}/{d}\r\ncontent-length: {d}\r\nconnection: close\r\n\r\n{s}", .{
                    from, to - 1, test_body.len, slice.len, slice,
                }) catch return;
                _ = net.send(peer, msg);
                return;
            }
            const msg = std.fmt.bufPrint(&out, "HTTP/1.1 200 OK\r\ncontent-type: text/plain\r\n" ++
                "content-length: {d}\r\nconnection: close\r\n\r\n{s}", .{ test_body.len, test_body }) catch return;
            _ = net.send(peer, msg);
        } else if (std.mem.eql(u8, target, "/chunked")) {
            _ = net.send(peer, "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\nconnection: close\r\n\r\n" ++
                "a\r\n0123456789\r\n1a\r\nabcdefghijklmnopqrstuvwxyz\r\n0\r\n\r\n");
        } else if (std.mem.eql(u8, target, "/moved")) {
            _ = net.send(peer, "HTTP/1.1 302 Found\r\nlocation: /plain\r\ncontent-length: 0\r\nconnection: close\r\n\r\n");
        } else if (std.mem.eql(u8, target, "/away")) {
            _ = net.send(peer, "HTTP/1.1 302 Found\r\nlocation: http://elsewhere.invalid/x\r\n" ++
                "content-length: 0\r\nconnection: close\r\n\r\n");
        } else if (std.mem.eql(u8, target, "/huge")) {
            _ = net.send(peer, "HTTP/1.1 200 OK\r\ncontent-length: 99999999\r\nconnection: close\r\n\r\n");
        } else {
            _ = net.send(peer, "HTTP/1.1 404 Not Found\r\ncontent-length: 0\r\nconnection: close\r\n\r\n");
        }
    }

    /// `bytes=a-b` out of a request head, or null.
    fn rangeOf(text: []const u8) ?[2]usize {
        const at = std.ascii.indexOfIgnoreCase(text, "range: bytes=") orelse return null;
        const rest = text[at + "range: bytes=".len ..];
        const end = std.mem.indexOf(u8, rest, "\r\n") orelse return null;
        const dash = std.mem.indexOfScalar(u8, rest[0..end], '-') orelse return null;
        const from = std.fmt.parseInt(usize, rest[0..dash], 10) catch return null;
        const to = std.fmt.parseInt(usize, rest[dash + 1 .. end], 10) catch return null;
        return .{ from, to };
    }
};

/// Start a fetch and wait for its HTTP_RESPONSE, split back into the JSON head
/// and the raw body the envelope carries.
const FetchResult = struct {
    event: Event,
    json: []const u8,
    body: []const u8,
};

fn fetchOnce(b: *Broker, url: []const u8, range: []const u8) !FetchResult {
    const alloc = b.alloc;
    const req = FetchRequest{
        .method = try alloc.dupe(u8, "GET"),
        .url = try alloc.dupe(u8, url),
        .range = try alloc.dupe(u8, range),
        .headers = &.{},
    };
    const id = b.startFetch(0, req);
    if (id <= 0) return error.FetchRefused;
    const e = try nextEvent(b, 0, 10_000);
    if (e.kind != Kind.http_response) {
        b.freeEvent(e);
        return error.WrongEvent;
    }
    const json_len = std.mem.readInt(u32, e.payload[0..4], .little);
    return .{
        .event = e,
        .json = e.payload[4 .. 4 + json_len],
        .body = e.payload[4 + json_len ..],
    };
}

test "a fetch answers with one enveloped event carrying status, headers and body" {
    const a = t.allocator;
    const fx = try Fixture.init(a);
    defer fx.deinit(a);
    const b = &fx.br;
    try b.start();
    const srv = try TestHttp.open(a);
    defer srv.close();

    var url: [64]u8 = undefined;
    const plain = try std.fmt.bufPrint(&url, "http://127.0.0.1:{d}/plain", .{srv.port});

    const r = try fetchOnce(b, plain, "");
    defer b.freeEvent(r.event);
    try t.expect(std.mem.indexOf(u8, r.json, "\"status\":200") != null);
    try t.expect(std.mem.indexOf(u8, r.json, "\"content-type\":\"text/plain\"") != null);
    try t.expect(std.mem.indexOf(u8, r.json, plain) != null);
    try t.expectEqualStrings(test_body, r.body);
    // The envelope's length prefix is what splits the two halves, so the two
    // slices must account for the whole payload.
    try t.expectEqual(4 + r.json.len + r.body.len, r.event.payload.len);
}

test "a Range request comes back as 206 with only the bytes it asked for" {
    const a = t.allocator;
    const fx = try Fixture.init(a);
    defer fx.deinit(a);
    const b = &fx.br;
    try b.start();
    const srv = try TestHttp.open(a);
    defer srv.close();

    var url: [64]u8 = undefined;
    const plain = try std.fmt.bufPrint(&url, "http://127.0.0.1:{d}/plain", .{srv.port});

    const r = try fetchOnce(b, plain, "bytes=10-19");
    defer b.freeEvent(r.event);
    try t.expect(std.mem.indexOf(u8, r.json, "\"status\":206") != null);
    try t.expect(std.mem.indexOf(u8, r.json, "\"content-range\":\"bytes 10-19/36\"") != null);
    try t.expectEqualStrings("abcdefghij", r.body);
}

test "a chunked body reassembles and a same-host redirect is followed" {
    const a = t.allocator;
    const fx = try Fixture.init(a);
    defer fx.deinit(a);
    const b = &fx.br;
    try b.start();
    const srv = try TestHttp.open(a);
    defer srv.close();

    var url: [64]u8 = undefined;
    const r = try fetchOnce(b, try std.fmt.bufPrint(&url, "http://127.0.0.1:{d}/chunked", .{srv.port}), "");
    defer b.freeEvent(r.event);
    try t.expect(std.mem.indexOf(u8, r.json, "\"status\":200") != null);
    try t.expectEqualStrings(test_body, r.body);

    var url2: [64]u8 = undefined;
    const moved = try fetchOnce(b, try std.fmt.bufPrint(&url2, "http://127.0.0.1:{d}/moved", .{srv.port}), "");
    defer b.freeEvent(moved.event);
    try t.expect(std.mem.indexOf(u8, moved.json, "\"status\":200") != null);
    try t.expectEqualStrings(test_body, moved.body);
    // The redirect really was two requests, and the final URL is the one the
    // body came from rather than the one the plugin asked for.
    try t.expectEqual(@as(u32, 3), srv.served.load(.acquire));
    try t.expect(std.mem.indexOf(u8, moved.json, "/plain") != null);
}

test "a fetch that fails still answers exactly once, with status 0 and a reason" {
    const a = t.allocator;
    const fx = try Fixture.init(a);
    defer fx.deinit(a);
    const b = &fx.br;
    try b.start();
    const srv = try TestHttp.open(a);
    defer srv.close();

    var url: [64]u8 = undefined;
    // A redirect that leaves the host would leave the manifest's allowlist with
    // it, so the fetch stops instead of following.
    const away = try fetchOnce(b, try std.fmt.bufPrint(&url, "http://127.0.0.1:{d}/away", .{srv.port}), "");
    defer b.freeEvent(away.event);
    try t.expect(std.mem.indexOf(u8, away.json, "\"status\":0") != null);
    try t.expect(std.mem.indexOf(u8, away.json, "RedirectOffHost") != null);
    try t.expectEqual(@as(usize, 0), away.body.len);

    // A body over the cap is refused by its content-length, before a byte of it
    // is read. Range is the documented way past this.
    var url2: [64]u8 = undefined;
    const huge = try fetchOnce(b, try std.fmt.bufPrint(&url2, "http://127.0.0.1:{d}/huge", .{srv.port}), "");
    defer b.freeEvent(huge.event);
    try t.expect(std.mem.indexOf(u8, huge.json, "BodyTooLarge") != null);

    // Nothing listening at all is the same shape: one event, status 0.
    const dead = try fetchOnce(b, "http://127.0.0.1:9/nothing", "");
    defer b.freeEvent(dead.event);
    try t.expect(std.mem.indexOf(u8, dead.json, "\"status\":0") != null);
}

test "the fetch count is capped, and a refused fetch frees what it was given" {
    const a = t.allocator;
    const fx = try Fixture.init(a);
    defer fx.deinit(a);
    const b = &fx.br;

    // The count is set by hand rather than by racing four real fetches: a
    // connect to a closed port is refused in microseconds, so a timing version
    // of this test would sometimes find a slot free and prove nothing.
    b.mu.lock();
    b.fetching = http_max_inflight;
    b.mu.unlock();

    const req = FetchRequest{
        .method = try a.dupe(u8, "GET"),
        .url = try a.dupe(u8, "http://127.0.0.1:9/x"),
        .range = try a.dupe(u8, ""),
        .headers = &.{},
    };
    try t.expectEqual(@as(i64, -1), b.startFetch(0, req));
    // The refusal took the request with it: what the plugin handed over is
    // owned by the broker from the call on, and the testing allocator fails
    // this test if the refusal path forgot it.
    b.mu.lock();
    const listed = b.fetches.items.len;
    b.fetching = 0;
    b.mu.unlock();
    try t.expectEqual(@as(usize, 0), listed);
}
