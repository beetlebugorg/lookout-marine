//! HTTP/1.1 and RFC 6455 over one socket, with TLS from `std.crypto`.
//!
//! WHAT THIS FILE IS. `net.zig` moves bytes; this file gives them a protocol.
//! It knows nothing about plugins, capabilities or the broker's queues — it
//! takes a URL and a buffer and answers with a status, headers and a body, or
//! with a stream of WebSocket messages. broker.zig decides who is allowed to
//! ask.
//!
//! THREADS. Every call here BLOCKS. One `Stream` belongs to one thread for its
//! whole life, and the broker gives each fetch and each WebSocket a thread of
//! its own for exactly that reason. Nothing in this file may run on the I/O
//! thread.
//!
//! TLS. `std.crypto.tls.Client` over a plain `std.Io.Reader`/`Writer` pair on
//! the socket, so no `std.Io` implementation is needed for the network itself.
//! The root certificates come from the platform once per process, behind
//! `caBundle`. There is no new dependency: the whole TLS stack is in Zig's
//! standard library.
//!
//! WHAT IS NOT HERE. HTTP/2, cookies, authentication, connection reuse and
//! compressed transfer encodings. A plugin fetching a GRIB file or holding a
//! Signal K socket needs none of them.

const std = @import("std");
const builtin = @import("builtin");
const net = @import("net.zig");

const tls = std.crypto.tls;
const io = std.Io.Threaded.global_single_threaded.io();

/// Longest single header line accepted, and the reader buffer a plain socket
/// gets. TLS needs `tls.max_ciphertext_record_len` anyway, so this is the
/// floor rather than the common case.
const line_buffer = tls.max_ciphertext_record_len;

/// How long a fetch or a handshake waits on one read or one write.
pub const socket_timeout_ms: u32 = 20_000;

pub const Error = error{
    BadUrl,
    UnsupportedScheme,
    ConnectFailed,
    TlsFailed,
    WriteFailed,
    BadResponse,
    BodyTooLarge,
    TooManyRedirects,
    RedirectOffHost,
    HandshakeRefused,
    ProtocolError,
    MessageTooLarge,
    Closed,
    OutOfMemory,
};

// ---- URLs --------------------------------------------------------------------

/// `scheme://host[:port]/path`. Everything after the host is the target,
/// query and all: nothing here decodes it, and the server gets the bytes the
/// plugin wrote.
pub const Url = struct {
    scheme: []const u8,
    host: []const u8,
    port: u16,
    /// Always starts with '/'. Points into `buf` when the URL had no path.
    target: []const u8,
    tls: bool,

    var root_path = [_]u8{'/'};

    pub fn parse(text: []const u8) Error!Url {
        const sep = std.mem.indexOf(u8, text, "://") orelse return Error.BadUrl;
        const scheme = text[0..sep];
        var secure = false;
        var default_port: u16 = 0;
        if (std.mem.eql(u8, scheme, "https") or std.mem.eql(u8, scheme, "wss")) {
            secure = true;
            default_port = 443;
        } else if (std.mem.eql(u8, scheme, "http") or std.mem.eql(u8, scheme, "ws")) {
            default_port = 80;
        } else return Error.UnsupportedScheme;

        const rest = text[sep + 3 ..];
        const path_at = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
        var authority = rest[0..path_at];
        const target = if (path_at == rest.len) &root_path else rest[path_at..];
        // Credentials in a URL are refused rather than ignored: a plugin that
        // puts a password in one has made a mistake worth stopping.
        if (std.mem.indexOfScalar(u8, authority, '@') != null) return Error.BadUrl;

        var port = default_port;
        if (authority.len > 0 and authority[0] == '[') {
            // A literal IPv6 host keeps its brackets out of the name.
            const end = std.mem.indexOfScalar(u8, authority, ']') orelse return Error.BadUrl;
            const after = authority[end + 1 ..];
            if (after.len > 0) {
                if (after[0] != ':') return Error.BadUrl;
                port = std.fmt.parseInt(u16, after[1..], 10) catch return Error.BadUrl;
            }
            authority = authority[1..end];
        } else if (std.mem.lastIndexOfScalar(u8, authority, ':')) |at| {
            port = std.fmt.parseInt(u16, authority[at + 1 ..], 10) catch return Error.BadUrl;
            authority = authority[0..at];
        }
        if (authority.len == 0 or authority.len > 253) return Error.BadUrl;
        for (authority) |c| {
            if (c <= ' ' or c == 0x7f) return Error.BadUrl;
        }
        if (port == 0) return Error.BadUrl;
        return .{ .scheme = scheme, .host = authority, .port = port, .target = target, .tls = secure };
    }
};

/// Case-insensitive host comparison. Hostnames are ASCII here: an
/// internationalised name reaches this already punycoded or not at all.
pub fn sameHost(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

// ---- the root certificates ----------------------------------------------------

var bundle_mu: std.Io.RwLock = .init;
var bundle: std.crypto.Certificate.Bundle = .empty;
var bundle_ready = std.atomic.Value(u32).init(0);
var bundle_gate: std.Io.Mutex = .init;

/// The bundle is PROCESS-wide and outlives any one plugin layer, so it holds
/// the process allocator rather than the caller's. A test allocator would
/// otherwise report a live leak for something deliberately kept.
const bundle_gpa = std.heap.c_allocator;

/// The platform's root certificates, scanned once per process. Every HTTPS
/// connection shares them: the scan reads about 160 certificates on macOS and
/// doing it per fetch would cost more than the handshake.
fn caBundle() !*std.crypto.Certificate.Bundle {
    if (bundle_ready.load(.acquire) == 1) return &bundle;
    bundle_gate.lock(io) catch {};
    defer bundle_gate.unlock(io);
    if (bundle_ready.load(.acquire) == 1) return &bundle;
    try bundle.rescan(bundle_gpa, io, .{ .nanoseconds = @as(i96, wallSec()) * std.time.ns_per_s });
    bundle_ready.store(1, .release);
    return &bundle;
}

/// Release the process-wide certificate bundle. The host calls this when the
/// last plugin layer goes down; the next HTTPS fetch rescans.
pub fn deinitCaBundle() void {
    if (bundle_ready.swap(0, .acq_rel) == 0) return;
    bundle.deinit(bundle_gpa);
    bundle = .empty;
}

/// Seconds since the Unix epoch, for the certificate validity window. Read
/// from the platform's own clock: POSIX clock_gettime has no declaration
/// Windows can compile, and importing the broker's wallMs here would make the
/// two files import each other.
fn wallSec() i64 {
    if (comptime builtin.os.tag == .windows) {
        // FILETIME counts 100 ns ticks from 1601-01-01. 11644473600 seconds
        // separate that epoch from the Unix one.
        var ft: [2]u32 = .{ 0, 0 };
        GetSystemTimeAsFileTime(&ft);
        const ticks = (@as(u64, ft[1]) << 32) | ft[0];
        return @intCast(@divTrunc(ticks, 10_000_000) -% 11_644_473_600);
    } else {
        var ts: std.c.timespec = undefined;
        if (std.c.clock_gettime(.REALTIME, &ts) != 0) return 0;
        return @intCast(ts.sec);
    }
}

extern "kernel32" fn GetSystemTimeAsFileTime(lpSystemTimeAsFileTime: *[2]u32) callconv(.winapi) void;

// ---- the stream ---------------------------------------------------------------

/// One socket, plain or wrapped in TLS, presented as a `std.Io.Reader` and a
/// `std.Io.Writer` of PLAINTEXT.
///
/// SELF-REFERENTIAL. The reader and the writer are found from their addresses
/// with `@fieldParentPtr`, and the TLS client holds pointers to the two socket
/// halves. Nothing may copy or move a Stream after `open`, which is why `open`
/// returns a pointer and the caller destroys it.
pub const Stream = struct {
    fd: net.Socket,
    sock_reader: std.Io.Reader,
    sock_writer: std.Io.Writer,
    tls_client: ?tls.Client = null,
    gpa: std.mem.Allocator,

    sock_rbuf: [line_buffer]u8 = undefined,
    sock_wbuf: [line_buffer]u8 = undefined,
    tls_rbuf: [line_buffer]u8 = undefined,
    tls_wbuf: [line_buffer]u8 = undefined,

    pub fn open(gpa: std.mem.Allocator, url: Url) Error!*Stream {
        const self = gpa.create(Stream) catch return Error.OutOfMemory;
        errdefer gpa.destroy(self);
        const fd = net.dialBlocking(url.host, url.port, socket_timeout_ms) catch return Error.ConnectFailed;
        errdefer net.close(fd);

        self.* = .{
            .fd = fd,
            .gpa = gpa,
            .sock_reader = .{ .vtable = &.{ .stream = sockStream }, .buffer = &self.sock_rbuf, .seek = 0, .end = 0 },
            .sock_writer = .{ .vtable = &.{ .drain = sockDrain }, .buffer = &self.sock_wbuf, .end = 0 },
        };
        if (!url.tls) return self;

        const ca = caBundle() catch return Error.TlsFailed;
        var entropy: [tls.Client.Options.entropy_len]u8 = undefined;
        io.random(&entropy);
        self.tls_client = tls.Client.init(&self.sock_reader, &self.sock_writer, .{
            .host = .{ .explicit = url.host },
            .ca = .{ .bundle = .{ .gpa = bundle_gpa, .io = io, .lock = &bundle_mu, .bundle = ca } },
            .read_buffer = &self.tls_rbuf,
            .write_buffer = &self.tls_wbuf,
            .entropy = &entropy,
            .realtime_now = .{ .nanoseconds = @as(i96, wallSec()) * std.time.ns_per_s },
        }) catch return Error.TlsFailed;
        return self;
    }

    pub fn close(self: *Stream) void {
        if (self.tls_client) |*c| c.end() catch {};
        self.flush() catch {};
        net.close(self.fd);
        self.gpa.destroy(self);
    }

    pub fn reader(self: *Stream) *std.Io.Reader {
        if (self.tls_client) |*c| return &c.reader;
        return &self.sock_reader;
    }

    /// True when bytes are waiting inside the stream itself: decrypted in the
    /// TLS reader, or read off the socket and not yet decrypted. A poll on the
    /// descriptor cannot see either, so a reader loop asks this first.
    pub fn hasBuffered(self: *Stream) bool {
        if (self.sock_reader.bufferedLen() > 0) return true;
        if (self.tls_client) |*c| return c.reader.bufferedLen() > 0;
        return false;
    }

    pub fn writer(self: *Stream) *std.Io.Writer {
        if (self.tls_client) |*c| return &c.writer;
        return &self.sock_writer;
    }

    /// TLS's own flush only encrypts into the socket writer's buffer, so a
    /// flush is always two flushes.
    pub fn flush(self: *Stream) Error!void {
        if (self.tls_client) |*c| c.writer.flush() catch return Error.WriteFailed;
        self.sock_writer.flush() catch return Error.WriteFailed;
    }

    fn sockStream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *Stream = @alignCast(@fieldParentPtr("sock_reader", r));
        const dest = limit.slice(try w.writableSliceGreedy(1));
        const n = net.recv(self.fd, dest);
        if (n == 0) return error.EndOfStream;
        if (n < 0) return error.ReadFailed;
        w.advance(@intCast(n));
        return @intCast(n);
    }

    fn sockDrain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        _ = splat;
        const self: *Stream = @alignCast(@fieldParentPtr("sock_writer", w));
        const buffered = w.buffered();
        if (buffered.len > 0) {
            const n = net.send(self.fd, buffered);
            if (n <= 0) return error.WriteFailed;
            return w.consume(@intCast(n));
        }
        for (data) |chunk| {
            if (chunk.len == 0) continue;
            const n = net.send(self.fd, chunk);
            if (n <= 0) return error.WriteFailed;
            return @intCast(n);
        }
        return 0;
    }
};

// ---- HTTP ---------------------------------------------------------------------

pub const Header = struct {
    /// Lower-cased. HTTP header names are case-insensitive and a plugin should
    /// not have to know which case a server chose.
    name: []u8,
    value: []u8,
};

pub const Response = struct {
    gpa: std.mem.Allocator,
    status: u16,
    headers: []Header,
    body: []u8,
    /// The URL the body actually came from, after any redirects.
    url: []u8,

    pub fn deinit(self: *Response) void {
        for (self.headers) |h| {
            self.gpa.free(h.name);
            self.gpa.free(h.value);
        }
        if (self.headers.len > 0) self.gpa.free(self.headers);
        self.gpa.free(self.body);
        self.gpa.free(self.url);
        self.* = undefined;
    }

    pub fn header(self: *const Response, name: []const u8) ?[]const u8 {
        for (self.headers) |h| {
            if (std.mem.eql(u8, h.name, name)) return h.value;
        }
        return null;
    }
};

pub const Request = struct {
    method: []const u8 = "GET",
    url: []const u8,
    /// Extra request headers, name and value as written.
    headers: []const Header = &.{},
    /// `bytes=0-1048575`, or empty for none.
    range: []const u8 = "",
    /// Refused above this many body bytes. Range is the way past it.
    max_body: usize = 4 * 1024 * 1024,
    /// Redirects followed. Each must stay on the same host.
    max_redirects: u8 = 5,
    /// Told which socket the fetch is using, and told `net.invalid` again just
    /// before that socket is closed. The broker uses it to shut a fetch down
    /// from another thread without racing the close.
    socket_ctx: ?*anyopaque = null,
    onSocket: ?*const fn (ctx: ?*anyopaque, fd: net.Socket) void = null,
};

/// Longest response head accepted, and the most headers kept.
const max_headers = 64;

/// Perform one request, following same-host redirects. BLOCKING.
pub fn fetch(gpa: std.mem.Allocator, req: Request) Error!Response {
    var current = gpa.dupe(u8, req.url) catch return Error.OutOfMemory;
    errdefer gpa.free(current);

    var hops: u8 = 0;
    while (true) {
        const url = try Url.parse(current);
        var stream = try Stream.open(gpa, url);
        if (req.onSocket) |f| f(req.socket_ctx, stream.fd);
        defer {
            if (req.onSocket) |f| f(req.socket_ctx, net.invalid);
            stream.close();
        }

        try writeRequest(stream, url, req);
        var resp = try readResponse(gpa, stream, url, current, req);
        // No errdefer on `resp` or on `next` below: every path out of here
        // releases them by hand, and an errdefer beside that would free each
        // one twice.

        const redirect = switch (resp.status) {
            301, 302, 303, 307, 308 => resp.header("location"),
            else => null,
        };
        const location = redirect orelse {
            gpa.free(current);
            return resp;
        };

        hops += 1;
        if (hops > req.max_redirects) {
            resp.deinit();
            return Error.TooManyRedirects;
        }
        const next = resolveLocation(gpa, url, location) catch |e| {
            resp.deinit();
            return e;
        };
        const next_url = Url.parse(next) catch {
            gpa.free(next);
            resp.deinit();
            return Error.BadUrl;
        };
        // SAME HOST ONLY. A redirect that leaves the host would leave the
        // manifest's allowlist with it, and the allowlist is checked once.
        if (!sameHost(next_url.host, url.host)) {
            gpa.free(next);
            resp.deinit();
            return Error.RedirectOffHost;
        }
        resp.deinit();
        gpa.free(current);
        current = next;
    }
}

/// A `Location` that may be absolute, root-relative or path-relative.
fn resolveLocation(gpa: std.mem.Allocator, base: Url, location: []const u8) Error![]u8 {
    if (location.len == 0) return Error.BadResponse;
    if (std.mem.indexOf(u8, location, "://") != null)
        return gpa.dupe(u8, location) catch Error.OutOfMemory;
    if (location[0] == '/')
        return std.fmt.allocPrint(gpa, "{s}://{s}:{d}{s}", .{ base.scheme, base.host, base.port, location }) catch Error.OutOfMemory;
    const cut = std.mem.lastIndexOfScalar(u8, base.target, '/') orelse 0;
    return std.fmt.allocPrint(gpa, "{s}://{s}:{d}{s}/{s}", .{
        base.scheme, base.host, base.port, base.target[0..cut], location,
    }) catch Error.OutOfMemory;
}

fn writeRequest(stream: *Stream, url: Url, req: Request) Error!void {
    const w = stream.writer();
    w.print("{s} {s} HTTP/1.1\r\n", .{ req.method, url.target }) catch return Error.WriteFailed;
    if ((url.tls and url.port == 443) or (!url.tls and url.port == 80)) {
        w.print("host: {s}\r\n", .{url.host}) catch return Error.WriteFailed;
    } else {
        w.print("host: {s}:{d}\r\n", .{ url.host, url.port }) catch return Error.WriteFailed;
    }
    // No keep-alive: one fetch is one connection, so nothing has to reason
    // about a pool that a plugin's grant was checked against once.
    w.writeAll("connection: close\r\nuser-agent: lookout-marine\r\naccept-encoding: identity\r\n") catch
        return Error.WriteFailed;
    if (req.range.len > 0) w.print("range: {s}\r\n", .{req.range}) catch return Error.WriteFailed;
    for (req.headers) |h| w.print("{s}: {s}\r\n", .{ h.name, h.value }) catch return Error.WriteFailed;
    w.writeAll("\r\n") catch return Error.WriteFailed;
    try stream.flush();
}

fn readResponse(gpa: std.mem.Allocator, stream: *Stream, url: Url, url_text: []const u8, req: Request) Error!Response {
    const r = stream.reader();
    const status = try parseStatus(takeLine(r) catch return Error.BadResponse);

    var headers: std.ArrayList(Header) = .empty;
    errdefer {
        for (headers.items) |h| {
            gpa.free(h.name);
            gpa.free(h.value);
        }
        headers.deinit(gpa);
    }

    var content_length: ?u64 = null;
    var chunked = false;
    while (true) {
        const line = takeLine(r) catch return Error.BadResponse;
        if (line.len == 0) break;
        if (headers.items.len >= max_headers) continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (name.len == 0) continue;

        const name_owned = gpa.alloc(u8, name.len) catch return Error.OutOfMemory;
        errdefer gpa.free(name_owned);
        _ = std.ascii.lowerString(name_owned, name);
        const value_owned = gpa.dupe(u8, value) catch return Error.OutOfMemory;
        headers.append(gpa, .{ .name = name_owned, .value = value_owned }) catch return Error.OutOfMemory;

        if (std.mem.eql(u8, name_owned, "content-length")) {
            content_length = std.fmt.parseInt(u64, value, 10) catch null;
        } else if (std.mem.eql(u8, name_owned, "transfer-encoding")) {
            chunked = std.ascii.indexOfIgnoreCase(value, "chunked") != null;
        }
    }

    if (content_length) |n| {
        if (n > req.max_body) return Error.BodyTooLarge;
    }

    var body: std.ArrayList(u8) = .empty;
    errdefer body.deinit(gpa);
    // A 204, a 304 and a HEAD have no body whatever the headers say.
    const bodyless = status == 204 or status == 304 or std.mem.eql(u8, req.method, "HEAD");
    if (!bodyless) {
        if (chunked) {
            try readChunked(gpa, r, &body, req.max_body);
        } else if (content_length) |n| {
            try readExact(gpa, r, &body, @intCast(n));
        } else {
            try readToEnd(gpa, r, &body, req.max_body);
        }
    }

    _ = url;
    return .{
        .gpa = gpa,
        .status = status,
        .headers = headers.toOwnedSlice(gpa) catch return Error.OutOfMemory,
        .body = body.toOwnedSlice(gpa) catch return Error.OutOfMemory,
        .url = gpa.dupe(u8, url_text) catch return Error.OutOfMemory,
    };
}

/// One CRLF-terminated line, without its terminator. `takeDelimiterExclusive`
/// leaves the delimiter in the stream, which would make the blank line that
/// ends a header block read as an infinite run of blank lines.
fn takeLine(r: *std.Io.Reader) std.Io.Reader.DelimiterError![]u8 {
    const raw = try r.takeDelimiterInclusive('\n');
    var line = raw[0 .. raw.len - 1];
    if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
    return line;
}

fn parseStatus(line: []const u8) Error!u16 {
    if (!std.mem.startsWith(u8, line, "HTTP/")) return Error.BadResponse;
    const sp = std.mem.indexOfScalar(u8, line, ' ') orelse return Error.BadResponse;
    if (line.len < sp + 4) return Error.BadResponse;
    return std.fmt.parseInt(u16, line[sp + 1 .. sp + 4], 10) catch Error.BadResponse;
}

fn readExact(gpa: std.mem.Allocator, r: *std.Io.Reader, out: *std.ArrayList(u8), n: usize) Error!void {
    out.ensureTotalCapacity(gpa, n) catch return Error.OutOfMemory;
    var left = n;
    while (left > 0) {
        const chunk = r.peekGreedy(1) catch return Error.BadResponse;
        const take = @min(chunk.len, left);
        out.appendSlice(gpa, chunk[0..take]) catch return Error.OutOfMemory;
        r.toss(take);
        left -= take;
    }
}

fn readToEnd(gpa: std.mem.Allocator, r: *std.Io.Reader, out: *std.ArrayList(u8), cap: usize) Error!void {
    while (true) {
        const chunk = r.peekGreedy(1) catch |e| switch (e) {
            error.EndOfStream => return,
            else => return Error.BadResponse,
        };
        if (out.items.len + chunk.len > cap) return Error.BodyTooLarge;
        out.appendSlice(gpa, chunk) catch return Error.OutOfMemory;
        r.toss(chunk.len);
    }
}

fn readChunked(gpa: std.mem.Allocator, r: *std.Io.Reader, out: *std.ArrayList(u8), cap: usize) Error!void {
    while (true) {
        const line = takeLine(r) catch return Error.BadResponse;
        // A chunk size may carry extensions after a semicolon.
        const end = std.mem.indexOfScalar(u8, line, ';') orelse line.len;
        const size = std.fmt.parseInt(usize, std.mem.trim(u8, line[0..end], " \t"), 16) catch return Error.BadResponse;
        if (size == 0) {
            // Trailers, then the blank line that ends them.
            while (true) {
                const trailer = takeLine(r) catch return;
                if (trailer.len == 0) return;
            }
        }
        if (out.items.len + size > cap) return Error.BodyTooLarge;
        try readExact(gpa, r, out, size);
        const crlf = takeLine(r) catch return Error.BadResponse;
        if (crlf.len != 0) return Error.BadResponse;
    }
}

// ---- WebSocket ----------------------------------------------------------------

/// RFC 6455 section 1.3. The one constant the handshake is built on.
const ws_guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

pub const Opcode = enum(u4) {
    continuation = 0x0,
    text = 0x1,
    binary = 0x2,
    close = 0x8,
    ping = 0x9,
    pong = 0xa,
    _,
};

/// Longest message reassembled from its fragments. A Signal K delta is a few
/// hundred bytes; the room is for a full-tree snapshot.
pub const max_message = 1024 * 1024;

/// A control frame's payload is 125 bytes at most (RFC 6455 section 5.5).
const max_control = 125;

pub const Handshake = struct {
    /// The subprotocol the server chose, or empty.
    protocol: [64]u8 = @splat(0),
    protocol_len: usize = 0,

    pub fn chosen(self: *const Handshake) []const u8 {
        return self.protocol[0..self.protocol_len];
    }
};

/// Send the client handshake and check the server's answer. On return the
/// stream carries frames and nothing else.
pub fn wsHandshake(stream: *Stream, url: Url, protocols: []const u8, out: *Handshake) Error!void {
    var key_bytes: [16]u8 = undefined;
    io.random(&key_bytes);
    var key: [24]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&key, &key_bytes);

    const w = stream.writer();
    w.print("GET {s} HTTP/1.1\r\n", .{url.target}) catch return Error.WriteFailed;
    if ((url.tls and url.port == 443) or (!url.tls and url.port == 80)) {
        w.print("host: {s}\r\n", .{url.host}) catch return Error.WriteFailed;
    } else {
        w.print("host: {s}:{d}\r\n", .{ url.host, url.port }) catch return Error.WriteFailed;
    }
    w.writeAll("upgrade: websocket\r\nconnection: Upgrade\r\nsec-websocket-version: 13\r\n") catch
        return Error.WriteFailed;
    w.print("sec-websocket-key: {s}\r\n", .{key}) catch return Error.WriteFailed;
    if (protocols.len > 0) w.print("sec-websocket-protocol: {s}\r\n", .{protocols}) catch return Error.WriteFailed;
    w.writeAll("user-agent: lookout-marine\r\n\r\n") catch return Error.WriteFailed;
    try stream.flush();

    const r = stream.reader();
    const status = parseStatus(takeLine(r) catch return Error.HandshakeRefused) catch
        return Error.HandshakeRefused;
    if (status != 101) return Error.HandshakeRefused;

    var expect: [28]u8 = undefined;
    acceptFor(&key, &expect);
    var saw_accept = false;
    var saw_upgrade = false;
    while (true) {
        const line = takeLine(r) catch return Error.HandshakeRefused;
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, "sec-websocket-accept")) {
            saw_accept = std.mem.eql(u8, value, &expect);
        } else if (std.ascii.eqlIgnoreCase(name, "upgrade")) {
            saw_upgrade = std.ascii.eqlIgnoreCase(value, "websocket");
        } else if (std.ascii.eqlIgnoreCase(name, "sec-websocket-protocol")) {
            const n = @min(value.len, out.protocol.len);
            @memcpy(out.protocol[0..n], value[0..n]);
            out.protocol_len = n;
        }
    }
    // The accept hash is what proves the peer read the key rather than a cache
    // replaying a 101 at us.
    if (!saw_accept or !saw_upgrade) return Error.HandshakeRefused;
}

/// base64(sha1(key ++ GUID)), RFC 6455 section 4.1.
pub fn acceptFor(key: []const u8, out: *[28]u8) void {
    var sha: std.crypto.hash.Sha1 = .init(.{});
    sha.update(key);
    sha.update(ws_guid);
    var digest: [20]u8 = undefined;
    sha.final(&digest);
    _ = std.base64.standard.Encoder.encode(out, &digest);
}

/// One frame's header. The payload is left in the stream: a message may be a
/// megabyte and the reader's buffer is 16 KiB, so the caller streams it.
pub const FrameHead = struct {
    fin: bool,
    opcode: Opcode,
    len: u64,
};

/// Read one frame's header and leave its payload in the stream.
///
/// A frame from a server must NOT be masked (RFC 6455 section 5.1); one that is
/// is a protocol error rather than something to unmask politely.
pub fn readFrameHead(r: *std.Io.Reader) Error!FrameHead {
    const b0 = r.takeByte() catch return Error.Closed;
    const b1 = r.takeByte() catch return Error.Closed;
    // The three reserved bits mean an extension nobody negotiated.
    if ((b0 & 0x70) != 0) return Error.ProtocolError;
    const fin = (b0 & 0x80) != 0;
    const opcode: Opcode = @enumFromInt(@as(u4, @truncate(b0)));
    if ((b1 & 0x80) != 0) return Error.ProtocolError;

    var len: u64 = b1 & 0x7f;
    if (len == 126) {
        const b = r.takeArray(2) catch return Error.Closed;
        len = std.mem.readInt(u16, b, .big);
    } else if (len == 127) {
        const b = r.takeArray(8) catch return Error.Closed;
        len = std.mem.readInt(u64, b, .big);
    }
    const control = (@intFromEnum(opcode) & 0x8) != 0;
    if (control and (len > max_control or !fin)) return Error.ProtocolError;
    if (len > max_message) return Error.MessageTooLarge;
    return .{ .fin = fin, .opcode = opcode, .len = len };
}

/// Append one frame's payload to `out`. Streamed rather than peeked, so a
/// message larger than the reader's buffer still arrives whole.
pub fn readPayloadInto(gpa: std.mem.Allocator, r: *std.Io.Reader, out: *std.ArrayList(u8), len: usize) Error!void {
    if (out.items.len + len > max_message) return Error.MessageTooLarge;
    out.ensureUnusedCapacity(gpa, len) catch return Error.OutOfMemory;
    var left = len;
    while (left > 0) {
        const chunk = r.peekGreedy(1) catch return Error.Closed;
        const take = @min(chunk.len, left);
        out.appendSlice(gpa, chunk[0..take]) catch return Error.OutOfMemory;
        r.toss(take);
        left -= take;
    }
}

/// Write one masked frame. Every client frame is masked with four fresh random
/// bytes (RFC 6455 section 5.3); a server closes a connection that sends an
/// unmasked one.
pub fn writeFrame(stream: *Stream, opcode: Opcode, payload: []const u8) Error!void {
    var head: [14]u8 = undefined;
    var n: usize = 0;
    head[0] = 0x80 | @as(u8, @intFromEnum(opcode));
    if (payload.len < 126) {
        head[1] = 0x80 | @as(u8, @intCast(payload.len));
        n = 2;
    } else if (payload.len <= std.math.maxInt(u16)) {
        head[1] = 0x80 | 126;
        std.mem.writeInt(u16, head[2..4], @intCast(payload.len), .big);
        n = 4;
    } else {
        head[1] = 0x80 | 127;
        std.mem.writeInt(u64, head[2..10], payload.len, .big);
        n = 10;
    }
    var mask: [4]u8 = undefined;
    io.random(&mask);
    @memcpy(head[n .. n + 4], &mask);
    n += 4;

    const w = stream.writer();
    w.writeAll(head[0..n]) catch return Error.WriteFailed;
    var i: usize = 0;
    var scratch: [1024]u8 = undefined;
    while (i < payload.len) {
        const take = @min(scratch.len, payload.len - i);
        for (0..take) |k| scratch[k] = payload[i + k] ^ mask[(i + k) & 3];
        w.writeAll(scratch[0..take]) catch return Error.WriteFailed;
        i += take;
    }
    try stream.flush();
}

/// The close code and reason inside a close frame's payload.
pub fn closePayload(payload: []const u8) struct { code: u16, reason: []const u8 } {
    if (payload.len < 2) return .{ .code = 1005, .reason = "" };
    return .{ .code = std.mem.readInt(u16, payload[0..2], .big), .reason = payload[2..] };
}

// ---- tests ---------------------------------------------------------------------

const t = std.testing;

test "a URL splits into scheme, host, port and target" {
    const a = try Url.parse("https://nomads.ncep.noaa.gov/cgi-bin/filter.pl?file=gfs");
    try t.expectEqualStrings("https", a.scheme);
    try t.expectEqualStrings("nomads.ncep.noaa.gov", a.host);
    try t.expectEqual(@as(u16, 443), a.port);
    try t.expectEqualStrings("/cgi-bin/filter.pl?file=gfs", a.target);
    try t.expect(a.tls);

    const b = try Url.parse("http://192.168.1.9:3000");
    try t.expectEqualStrings("192.168.1.9", b.host);
    try t.expectEqual(@as(u16, 3000), b.port);
    try t.expectEqualStrings("/", b.target);
    try t.expect(!b.tls);

    const c = try Url.parse("ws://demo.signalk.org/signalk/v1/stream?subscribe=none");
    try t.expectEqual(@as(u16, 80), c.port);
    try t.expectEqualStrings("/signalk/v1/stream?subscribe=none", c.target);

    const d = try Url.parse("wss://[::1]:8080/x");
    try t.expectEqualStrings("::1", d.host);
    try t.expectEqual(@as(u16, 8080), d.port);
    try t.expect(d.tls);

    // A scheme nobody serves, a URL with no scheme, credentials, and a port
    // that is not a number.
    try t.expectError(Error.UnsupportedScheme, Url.parse("ftp://example.com/x"));
    try t.expectError(Error.BadUrl, Url.parse("example.com/x"));
    try t.expectError(Error.BadUrl, Url.parse("https://user:pass@example.com/x"));
    try t.expectError(Error.BadUrl, Url.parse("https://example.com:hello/x"));
}

test "a Location resolves against the URL it came from" {
    const a = t.allocator;
    const base = try Url.parse("https://example.com/a/b/c?q=1");

    const abs = try resolveLocation(a, base, "https://example.com/z");
    defer a.free(abs);
    try t.expectEqualStrings("https://example.com/z", abs);

    const root = try resolveLocation(a, base, "/z");
    defer a.free(root);
    try t.expectEqualStrings("https://example.com:443/z", root);

    const rel = try resolveLocation(a, base, "d");
    defer a.free(rel);
    try t.expectEqualStrings("https://example.com:443/a/b/d", rel);
}

test "the WebSocket accept hash is RFC 6455's own example" {
    // RFC 6455 section 1.3: key dGhlIHNhbXBsZSBub25jZQ== accepts as
    // s3pPLMBiTxaQ9kYGzzhZRbK+xOo=.
    var out: [28]u8 = undefined;
    acceptFor("dGhlIHNhbXBsZSBub25jZQ==", &out);
    try t.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", &out);
}

test "a frame header takes the three length forms and refuses a masked one" {
    const a = t.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);

    // RFC 6455 section 5.7's single-frame unmasked "Hello".
    var short = std.Io.Reader.fixed(&[_]u8{ 0x81, 0x05, 'H', 'e', 'l', 'l', 'o' });
    const f = try readFrameHead(&short);
    try t.expect(f.fin);
    try t.expectEqual(Opcode.text, f.opcode);
    try readPayloadInto(a, &short, &out, @intCast(f.len));
    try t.expectEqualStrings("Hello", out.items);

    // A 16-bit length, and a fragment that is not final.
    var body: [4 + 300]u8 = undefined;
    body[0] = 0x01;
    body[1] = 126;
    std.mem.writeInt(u16, body[2..4], 300, .big);
    @memset(body[4..], 'x');
    var medium = std.Io.Reader.fixed(&body);
    const g = try readFrameHead(&medium);
    try t.expect(!g.fin);
    try t.expectEqual(Opcode.text, g.opcode);
    try t.expectEqual(@as(u64, 300), g.len);

    // A server frame must not be masked, and a reserved bit means an
    // extension nobody negotiated.
    var masked = std.Io.Reader.fixed(&[_]u8{ 0x81, 0x85, 1, 2, 3, 4, 'H', 'e', 'l', 'l', 'o' });
    try t.expectError(Error.ProtocolError, readFrameHead(&masked));
    var reserved = std.Io.Reader.fixed(&[_]u8{ 0xc1, 0x00 });
    try t.expectError(Error.ProtocolError, readFrameHead(&reserved));

    // A control frame is never fragmented and never over 125 bytes.
    var long_ping = std.Io.Reader.fixed(&[_]u8{ 0x89, 126, 0x01, 0x00 });
    try t.expectError(Error.ProtocolError, readFrameHead(&long_ping));
    var split_close = std.Io.Reader.fixed(&[_]u8{ 0x08, 0x00 });
    try t.expectError(Error.ProtocolError, readFrameHead(&split_close));
}

test "a close frame carries its code and reason" {
    const empty = closePayload("");
    try t.expectEqual(@as(u16, 1005), empty.code);
    const going = closePayload(&[_]u8{ 0x03, 0xe9, 'b', 'y', 'e' });
    try t.expectEqual(@as(u16, 1001), going.code);
    try t.expectEqualStrings("bye", going.reason);
}

test "a status line parses and a body that is not HTTP is refused" {
    try t.expectEqual(@as(u16, 200), try parseStatus("HTTP/1.1 200 OK"));
    try t.expectEqual(@as(u16, 206), try parseStatus("HTTP/1.1 206 Partial Content"));
    try t.expectEqual(@as(u16, 101), try parseStatus("HTTP/1.1 101 Switching Protocols"));
    try t.expectError(Error.BadResponse, parseStatus("gibberish"));
    try t.expectError(Error.BadResponse, parseStatus("HTTP/1.1"));
}

test "a chunked body reassembles, and one over the cap is refused" {
    const a = t.allocator;
    var r = std.Io.Reader.fixed("4\r\nWiki\r\n7\r\npedia i\r\n0\r\n\r\n");
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try readChunked(a, &r, &out, 1024);
    try t.expectEqualStrings("Wikipedia i", out.items);

    out.clearRetainingCapacity();
    var big = std.Io.Reader.fixed("10\r\n0123456789abcdef\r\n0\r\n\r\n");
    try t.expectError(Error.BodyTooLarge, readChunked(a, &big, &out, 8));
}
