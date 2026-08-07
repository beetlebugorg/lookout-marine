//! How a Signal K stream is carried, and how its bytes become whole JSON
//! documents.
//!
//! Signal K defines two streaming transports. This file names both. Only the
//! TCP one is built.
//!
//!   * `tcp` — "Streaming over TCP", Signal K 1.8.2, Streaming API. The server
//!     writes one JSON message per line, terminated CR LF. A document is
//!     framed by the line, not by a length or a checksum.
//!   * `ws` — the websocket at `/signalk/v1/stream`. The host has no websocket
//!     import, so a row that asks for it is refused with a line of its own.
//!     When the import lands, a websocket frame is already one whole document,
//!     which is why `Framer` in `.ws` mode passes a chunk straight through.
//!
//! The only import is `std`, so `zig test transport.zig` runs natively while
//! the same file compiles into the wasm module.

const std = @import("std");

/// Which stream a row uses.
pub const Kind = enum {
    tcp,
    ws,

    /// True while the host can carry this transport.
    pub fn available(self: Kind) bool {
        return self == .tcp;
    }
};

/// The port a Signal K server SHOULD serve its TCP stream on. Signal K 1.8.2,
/// Urls and Ports. It is the ASCII codes of S and K.
///
/// Port 3000 is the reference server's web page and websocket. Port 10110 is
/// its NMEA 0183 bridge, which the nmea0183 plugin reads. Neither carries
/// deltas.
pub const default_tcp_port: u16 = 8375;

/// The longest document the plugin reassembles. A delta that carries one
/// vessel's paths is a few hundred bytes; a server that merges a whole vessel
/// into one message is the large one.
pub const max_doc = 8192;

/// What the plugin sends when a stream opens.
///
/// A TCP stream starts with NO subscription — Signal K 1.8.2 fixes the initial
/// policy at `none` — so a client that sends nothing receives nothing after
/// the hello. This asks for every path of every vessel, because the plugin
/// publishes own ship AND the AIS targets the server holds.
///
/// `instant` with a `minPeriod` sends each change as it happens and no faster
/// than 200 ms. The default policy is `ideal`, which repeats a value that did
/// not change; a repeat is a store write that elects the same number again,
/// and at one server per row it is what fills the host's event queue first.
pub const subscribe_all =
    "{\"context\":\"*\",\"subscribe\":[{\"path\":\"*\",\"policy\":\"instant\",\"minPeriod\":200}]}\r\n";

/// Reassembles whole JSON documents from arbitrary byte chunks.
///
/// The caller owns the buffer, which bounds the longest document the framer
/// emits. A longer one is dropped up to its terminator and counted: half a
/// document is not a smaller document, and JSON gives no way to resume inside
/// one.
///
/// A document begins at `{`. Bytes before the first `{` of a line are skipped,
/// so a connection opened in the middle of a document resynchronises on the
/// next one instead of handing the parser a fragment.
pub const Framer = struct {
    kind: Kind = .tcp,
    buf: []u8,
    len: usize = 0,
    /// Set while the current document is over-long. Bytes are dropped until
    /// the next terminator.
    dropping: bool = false,
    /// Set while `buf` holds a document already handed to the caller.
    ready: bool = false,
    stats: Stats = .{},

    pub const Stats = struct {
        /// Documents returned to the caller.
        docs: u64 = 0,
        /// Documents longer than the buffer.
        oversize: u64 = 0,
    };

    pub fn init(kind: Kind, buf: []u8) Framer {
        return .{ .kind = kind, .buf = buf };
    }

    /// Clear the partial document. Call on connect: bytes left from the last
    /// connection belong to no document on this one.
    pub fn reset(self: *Framer) void {
        self.len = 0;
        self.ready = false;
        self.dropping = false;
    }

    pub fn feed(self: *Framer, chunk: []const u8) DocIter {
        return .{ .f = self, .rest = chunk };
    }

    pub const DocIter = struct {
        f: *Framer,
        rest: []const u8,

        /// The returned slice points into the framer's buffer and stays valid
        /// until the next call.
        pub fn next(it: *DocIter) ?[]const u8 {
            const f = it.f;
            // A websocket frame arrives whole, so the chunk IS the document.
            if (f.kind == .ws) {
                if (it.rest.len == 0) return null;
                const doc = it.rest;
                it.rest = &.{};
                if (doc.len == 0 or doc[0] != '{') return null;
                f.stats.docs += 1;
                return doc;
            }
            if (f.ready) {
                f.ready = false;
                f.len = 0;
            }
            while (it.rest.len > 0) {
                const c = it.rest[0];
                it.rest = it.rest[1..];
                if (c == '\r' or c == '\n') {
                    const n = f.len;
                    const was_dropping = f.dropping;
                    f.dropping = false;
                    f.len = 0;
                    if (was_dropping or n == 0) continue;
                    f.stats.docs += 1;
                    f.ready = true;
                    f.len = n;
                    return f.buf[0..n];
                }
                if (f.dropping) continue;
                // Resync: a document begins at its brace, never mid-object.
                if (f.len == 0 and c != '{') continue;
                if (f.len == f.buf.len) {
                    f.dropping = true;
                    f.len = 0;
                    f.stats.oversize += 1;
                    continue;
                }
                f.buf[f.len] = c;
                f.len += 1;
            }
            return null;
        }
    };
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const t = std.testing;

fn collect(f: *Framer, chunk: []const u8, out: *std.ArrayList([]const u8), alloc: std.mem.Allocator) !void {
    var it = f.feed(chunk);
    while (it.next()) |doc| {
        const copy = try alloc.dupe(u8, doc);
        try out.append(alloc, copy);
    }
}

test "a document is one line, and a split arrives whole" {
    var buf: [256]u8 = undefined;
    var f = Framer.init(.tcp, &buf);
    var got: std.ArrayList([]const u8) = .empty;
    defer {
        for (got.items) |s| t.allocator.free(s);
        got.deinit(t.allocator);
    }

    try collect(&f, "{\"a\":1}\r\n{\"b\":", &got, t.allocator);
    try t.expectEqual(@as(usize, 1), got.items.len);
    try t.expectEqualStrings("{\"a\":1}", got.items[0]);

    try collect(&f, "2}\n", &got, t.allocator);
    try t.expectEqual(@as(usize, 2), got.items.len);
    try t.expectEqualStrings("{\"b\":2}", got.items[1]);
    try t.expectEqual(@as(u64, 2), f.stats.docs);
}

test "a connection opened mid-document resynchronises on the next one" {
    var buf: [256]u8 = undefined;
    var f = Framer.init(.tcp, &buf);
    var got: std.ArrayList([]const u8) = .empty;
    defer {
        for (got.items) |s| t.allocator.free(s);
        got.deinit(t.allocator);
    }

    try collect(&f, "alues\":[]}]}\n{\"context\":\"vessels.self\"}\n", &got, t.allocator);
    try t.expectEqual(@as(usize, 1), got.items.len);
    try t.expectEqualStrings("{\"context\":\"vessels.self\"}", got.items[0]);
}

test "a document longer than the buffer is dropped whole and counted" {
    var buf: [16]u8 = undefined;
    var f = Framer.init(.tcp, &buf);
    var got: std.ArrayList([]const u8) = .empty;
    defer {
        for (got.items) |s| t.allocator.free(s);
        got.deinit(t.allocator);
    }

    try collect(&f, "{\"long\":\"aaaaaaaaaaaaaaaaaaaa\"}\n{\"ok\":1}\n", &got, t.allocator);
    try t.expectEqual(@as(usize, 1), got.items.len);
    try t.expectEqualStrings("{\"ok\":1}", got.items[0]);
    try t.expectEqual(@as(u64, 1), f.stats.oversize);
    try t.expectEqual(@as(u64, 1), f.stats.docs);
}

test "reset drops the partial document a closed connection left" {
    var buf: [256]u8 = undefined;
    var f = Framer.init(.tcp, &buf);
    var got: std.ArrayList([]const u8) = .empty;
    defer {
        for (got.items) |s| t.allocator.free(s);
        got.deinit(t.allocator);
    }

    try collect(&f, "{\"half\":", &got, t.allocator);
    try t.expectEqual(@as(usize, 0), got.items.len);
    f.reset();
    try collect(&f, "1}\n{\"whole\":2}\n", &got, t.allocator);
    // The rest of the old document no longer starts with a brace, so it is
    // skipped and only the whole one is returned.
    try t.expectEqual(@as(usize, 1), got.items.len);
    try t.expectEqualStrings("{\"whole\":2}", got.items[0]);
}

test "a websocket frame is already one document" {
    var buf: [256]u8 = undefined;
    var f = Framer.init(.ws, &buf);
    var it = f.feed("{\"updates\":[]}");
    try t.expectEqualStrings("{\"updates\":[]}", it.next().?);
    try t.expect(it.next() == null);
    try t.expectEqual(@as(u64, 1), f.stats.docs);
}

test "only the tcp transport is available today" {
    try t.expect(Kind.tcp.available());
    try t.expect(!Kind.ws.available());
}

test "the subscription is one line of the shape the spec's schema requires" {
    try t.expect(std.mem.endsWith(u8, subscribe_all, "\r\n"));
    const body = subscribe_all[0 .. subscribe_all.len - 2];
    // No newline inside: a server splits the stream on lines.
    try t.expect(std.mem.indexOfAny(u8, body, "\r\n") == null);

    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const root = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), body, .{});
    // The schema requires both keys.
    try t.expectEqualStrings("*", root.object.get("context").?.string);
    const items = root.object.get("subscribe").?.array.items;
    try t.expectEqual(@as(usize, 1), items.len);
    try t.expectEqualStrings("*", items[0].object.get("path").?.string);
    try t.expectEqualStrings("instant", items[0].object.get("policy").?.string);
    try t.expectEqual(@as(i64, 200), items[0].object.get("minPeriod").?.integer);
}
