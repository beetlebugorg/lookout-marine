//! Serves the sources an ALT STYLE names, by asking the host for them.
//!
//! WHY THIS EXISTS. lookout's own chart comes off disk — a .pmtiles archive
//! charttable reads itself, or a set composed through ct/tiles.zig. A style
//! the HOST supplied is the publisher's instead, and it names
//! its sources by URL, over the network. charttable does not have an HTTP
//! client, and the proxy, cookie, certificate-pinning and API-key rules such a
//! fetch needs are already the shell's — it applied them to get the style in
//! the first place.
//!
//! So the ask goes OUT. The core reports the source name and z/x/y, the shell
//! resolves that against the style it holds, fetches with its own networking,
//! and hands the bytes back to `respond`. This file is only the switchboard.
//!
//! THREADING. `pump` runs on the thread that drives the map, and the host's
//! callback is invoked with no lock of ours held — so a host that already has
//! the tile (a cache, the app bundle) may answer inside the callback rather
//! than bouncing through a queue to avoid a deadlock. `respond` is called from
//! whatever thread the host's networking finished on and does not take the api
//! lock, so a tile landing never waits on a frame in flight. That is
//! ct/tiles.zig's rule as well, and for the same reason.
//!
//! LIFETIME. A Source is never freed while the map lives. charttable's cache
//! workers call `fetch` on a provider from their own threads, so dropping one
//! because a style stopped naming it would be a use-after-free — and the whole
//! saving is a few hundred bytes and a name. Re-binding a name reuses its box,
//! and everything goes at deinit, after the map has stopped its workers.

const std = @import("std");
const ct = @import("charttable");
const Lock = @import("../lock.zig").Lock;

const Request = ct.provider.Request;

/// One tile the chart wants and only the host can fetch. Answer with
/// `respond`, from any thread, whenever the bytes arrive — the tile is parked,
/// not spinning, and a slow answer is never mistaken for a missing tile.
pub const RequestFn = *const fn (
    user: ?*anyopaque,
    source: [*:0]const u8,
    req_id: u64,
    z: c_int,
    x: c_int,
    y: c_int,
) callconv(.c) void;

pub const Status = ct.provider.Status;

pub const Provided = struct {
    alloc: std.mem.Allocator,

    /// Guards `sources` and the callback pair. Held only to look things up:
    /// never across a call into the host, and never across `Provider.respond`
    /// on a foreign thread.
    mu: Lock = .{},
    sources: std.ArrayListUnmanaged(*Source) = .empty,
    cb: ?RequestFn = null,
    user: ?*anyopaque = null,

    /// Scratch for `pump`, reused so a frame allocates nothing new. Touched
    /// only on the thread that drives the map.
    drained: std.ArrayListUnmanaged(Request) = .empty,
    asks: std.ArrayListUnmanaged(Ask) = .empty,

    const Ask = struct {
        req: Request,
        /// Borrowed from the Source, which outlives every ask.
        source: [*:0]const u8,
    };

    /// A style source name and the provider standing behind it. Heap-boxed
    /// because the map holds `*Provider` and the list may grow.
    pub const Source = struct {
        name: [:0]u8,
        provider: ct.provider.Provider,
    };

    pub fn init(alloc: std.mem.Allocator) Provided {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Provided) void {
        for (self.sources.items) |s| {
            s.provider.deinit();
            self.alloc.free(s.name);
            self.alloc.destroy(s);
        }
        self.sources.deinit(self.alloc);
        self.drained.deinit(self.alloc);
        self.asks.deinit(self.alloc);
    }

    /// Where the asks go. Setting no callback is not an error — every ask is
    /// then answered `failed`, because a tile nobody will ever answer is a
    /// hole in the chart that never fills.
    pub fn setCallback(self: *Provided, cb: ?RequestFn, user: ?*anyopaque) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.cb = cb;
        self.user = user;
    }

    pub fn hasCallback(self: *Provided) bool {
        self.mu.lock();
        defer self.mu.unlock();
        return self.cb != null;
    }

    /// The provider for `name`, created on first use. Call under the api lock.
    pub fn source(self: *Provided, name: []const u8) !*Source {
        self.mu.lock();
        defer self.mu.unlock();
        for (self.sources.items) |s| {
            if (std.mem.eql(u8, s.name, name)) return s;
        }
        const s = try self.alloc.create(Source);
        errdefer self.alloc.destroy(s);
        s.name = try self.alloc.dupeZ(u8, name);
        errdefer self.alloc.free(s.name);
        s.provider = ct.provider.Provider.init(self.alloc);
        // Request ids must be unique across ALL of these: one callback and one
        // respond() serve every source, so two providers numbering from 1
        // would answer each other's tiles — a raster source's PNG handed to a
        // vector source to decode.
        s.provider.id_bias = @as(u64, self.sources.items.len + 1) << 48;
        try self.sources.append(self.alloc, s);
        return s;
    }

    /// Take every outstanding ask and report it to the host. Call once per
    /// frame, from whichever thread drives the map.
    pub fn pump(self: *Provided) void {
        self.asks.clearRetainingCapacity();
        self.mu.lock();
        const cb = self.cb;
        const user = self.user;
        for (self.sources.items) |s| {
            self.drained.clearRetainingCapacity();
            s.provider.drain(&self.drained, self.alloc);
            for (self.drained.items) |req| {
                self.asks.append(self.alloc, .{ .req = req, .source = s.name.ptr }) catch break;
            }
        }
        self.mu.unlock();

        // Outside the lock: a host with the tile already in hand is allowed to
        // answer before this returns.
        for (self.asks.items) |a| {
            if (cb) |f| {
                f(user, a.source, a.req.id, @intCast(a.req.z), @intCast(a.req.x), @intCast(a.req.y));
            } else {
                self.respond(a.req.id, "", .failed);
            }
        }
    }

    /// The host's answer, from any thread. `bytes` is copied. An id that is
    /// unknown or already answered is ignored rather than treated as an error:
    /// a host racing a style change, or answering twice, must not corrupt
    /// anything.
    pub fn respond(self: *Provided, req_id: u64, bytes: []const u8, status: Status) void {
        // The high bits say which source asked (see id_bias). Only that one is
        // offered the answer — broadcasting it is how a raster tile's PNG ends
        // up being decoded as someone else's vector tile.
        const which = req_id >> 48;
        self.mu.lock();
        const s: ?*Source = if (which >= 1 and which <= self.sources.items.len)
            self.sources.items[which - 1]
        else
            null;
        self.mu.unlock();
        // Outside our lock: the provider has its own, and a host answering
        // from a network thread must not queue behind a frame's pump.
        if (s) |src| src.provider.respond(req_id, bytes, status);
    }

    /// How many asks the host has been told about and not yet answered.
    /// Reported rather than folded into `idle`: the host may never answer, and
    /// a chart that says "still building" forever because one tile server is
    /// down would spin a progress indicator for the rest of the session.
    pub fn outstanding(self: *Provided) usize {
        self.mu.lock();
        defer self.mu.unlock();
        var n: usize = 0;
        for (self.sources.items) |s| n += s.provider.pendingCount();
        return n;
    }
};

// ---- tests -----------------------------------------------------------------

const testing = std.testing;

/// A host that records what it was asked. One per test, reached through the
/// `user` pointer — which is what that pointer is for, and a global here would
/// have to be reset between tests in one binary.
const FakeHost = struct {
    seen: std.ArrayListUnmanaged(Seen) = .empty,

    const Seen = struct { source: []const u8, id: u64, z: c_int, x: c_int, y: c_int };

    fn deinit(self: *FakeHost) void {
        self.seen.deinit(testing.allocator);
    }

    fn onTile(user: ?*anyopaque, src: [*:0]const u8, id: u64, z: c_int, x: c_int, y: c_int) callconv(.c) void {
        const self: *FakeHost = @ptrCast(@alignCast(user.?));
        self.seen.append(testing.allocator, .{
            .source = std.mem.span(src),
            .id = id,
            .z = z,
            .x = x,
            .y = y,
        }) catch {};
    }

    /// The id the host was given for `name`, or 0.
    fn idFor(self: *const FakeHost, name: []const u8) u64 {
        for (self.seen.items) |s| {
            if (std.mem.eql(u8, s.source, name)) return s.id;
        }
        return 0;
    }
};

test "provided: an ask reaches the host with its source name, and the bytes come back" {
    var p = Provided.init(testing.allocator);
    defer p.deinit();
    var host: FakeHost = .{};
    defer host.deinit();
    p.setCallback(FakeHost.onTile, &host);

    const s = try p.source("satellite");
    const src = s.provider.source();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const id = ct.coord.TileId{ .z = 7, .x = 33, .y = 48 };

    // The map asks, the tile parks, the host is told once.
    try testing.expect(src.fetch(src.ptr, arena.allocator(), id) == .not_ready);
    p.pump();
    try testing.expectEqual(@as(usize, 1), host.seen.items.len);
    try testing.expectEqualStrings("satellite", host.seen.items[0].source);
    try testing.expectEqual(@as(c_int, 7), host.seen.items[0].z);
    try testing.expectEqual(@as(c_int, 33), host.seen.items[0].x);
    try testing.expectEqual(@as(c_int, 48), host.seen.items[0].y);

    // Still parked until the host answers — never cached as missing.
    try testing.expect(src.fetch(src.ptr, arena.allocator(), id) == .not_ready);

    p.respond(host.seen.items[0].id, "tile bytes", .ok);
    const got = src.fetch(src.ptr, arena.allocator(), id);
    try testing.expect(got == .bytes);
    try testing.expectEqualStrings("tile bytes", got.bytes);
}

test "provided: two sources answer through one door without crossing" {
    // The bug this exists to prevent: source A's bytes delivered to source B's
    // parked tile, because both numbered their requests from 1.
    var p = Provided.init(testing.allocator);
    defer p.deinit();
    var host: FakeHost = .{};
    defer host.deinit();
    p.setCallback(FakeHost.onTile, &host);

    const a = try p.source("basemap");
    const b = try p.source("hillshade");
    const sa = a.provider.source();
    const sb = b.provider.source();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const id = ct.coord.TileId{ .z = 4, .x = 2, .y = 3 }; // the SAME tile of each

    try testing.expect(sa.fetch(sa.ptr, arena.allocator(), id) == .not_ready);
    try testing.expect(sb.fetch(sb.ptr, arena.allocator(), id) == .not_ready);
    p.pump();
    try testing.expectEqual(@as(usize, 2), host.seen.items.len);

    const id_a = host.idFor("basemap");
    const id_b = host.idFor("hillshade");
    try testing.expect(id_a != id_b);

    // Answer only the hillshade. The basemap must still be waiting.
    p.respond(id_b, "hillshade bytes", .ok);
    try testing.expect(sa.fetch(sa.ptr, arena.allocator(), id) == .not_ready);
    const got = sb.fetch(sb.ptr, arena.allocator(), id);
    try testing.expect(got == .bytes);
    try testing.expectEqualStrings("hillshade bytes", got.bytes);
}

test "provided: with no host to ask, a tile is failed rather than parked forever" {
    var p = Provided.init(testing.allocator);
    defer p.deinit();

    const s = try p.source("satellite");
    const src = s.provider.source();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const id = ct.coord.TileId{ .z = 3, .x = 1, .y = 1 };

    try testing.expect(src.fetch(src.ptr, arena.allocator(), id) == .not_ready);
    p.pump();
    try testing.expect(src.fetch(src.ptr, arena.allocator(), id) == .failed);
}

test "provided: a stray response is ignored, and a name is bound once" {
    var p = Provided.init(testing.allocator);
    defer p.deinit();

    p.respond(0, "nobody asked", .ok); // no source at all
    p.respond(99 << 48, "nor here", .ok); // a source index past the end

    const first = try p.source("satellite");
    const again = try p.source("satellite");
    try testing.expectEqual(first, again);
    try testing.expectEqual(@as(usize, 1), p.sources.items.len);
    try testing.expectEqual(@as(usize, 0), p.outstanding());
}
