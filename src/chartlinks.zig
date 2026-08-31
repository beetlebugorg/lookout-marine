//! Charts by link: a publisher's MapLibre style drawn AS the chart.
//!
//! WHY THIS IS IN THE CORE. None of the work is networking: probing a link,
//! inlining a TileJSON, generating a wrapper style, naming a sprite variant,
//! reducing an attribution to its text, filling a tile template. It is shared
//! logic, so it belongs where every shell reaches the same copy of it, and the
//! shell keeps one job: fetch the bytes at a url with the platform's own HTTP
//! stack.
//!
//! THE ONE PRIMITIVE THE SHELL KEEPS. The core opens no socket. It drives a
//! generic async fetcher the shell provides (`HttpGetFn`), and every url the
//! feature needs — the style, a TileJSON, a sibling style.json, a sprite index
//! and sheet, and every map tile — goes through it. The shell does not know
//! which is which; it fetches the url it is handed.
//!
//! THE MACHINE IS EVENT-DRIVEN. `add` / `select` / `refresh` start a resolve
//! that advances on each answer, issuing the next round of fetches, until the
//! style is assembled or an error is reached. No thread of its own: answers
//! enqueue from the shell's fetch threads without the api lock (`respond`),
//! and the frame loop adopts them under the lock (`adopt`). A queued answer
//! raises the needs-redraw flag, so a shell that draws on demand still ticks;
//! the cost is that a resolve advances only while frames run, and a
//! backgrounded shell finishes it on its first frame back.
//!
//! EPOCHS. Every resolve carries one. A mariner who picks a second chart
//! while the first is still fetching supersedes the old resolve: its
//! outstanding requests are cancelled and their budget slots released at
//! once, and any answer that still lands is dropped.
//!
//! file:// SECURITY. `allow_file` is 1 for the link the mariner typed, and
//! for a style/TileJSON/sprite url named by a document ITSELF read from disk
//! when it resolves inside the typed link's directory. Tiles are always 0,
//! and so is every url that arrived over the network — a hostile style cannot
//! make the shell read arbitrary local files as its "TileJSON".
//!
//! LOCKING. Everything here runs under the api lock except `respond`, which
//! takes only `inbox_mu` and must not take the api lock: the shell answers
//! from whatever thread its networking finished on, and that thread must not
//! queue behind a frame in flight. That also makes answering safe from inside
//! `http_get`, which a shell reading a file:// url will naturally do.

const std = @import("std");
const owned = @import("owned");
const Lock = @import("lock.zig").Lock;

/// Fetch the bytes at `url`. Called with the api lock held: the shell must not
/// block and must not call back into the core except `respond` — start the
/// fetch on its own thread and return.
pub const HttpGetFn = *const fn (
    user: ?*anyopaque,
    req_id: u64,
    url: [*:0]const u8,
    allow_file: c_int,
) callconv(.c) void;

/// The core no longer wants an answer. Advisory: the shell may abort the
/// transfer to save bandwidth, and answering anyway is harmless.
pub const HttpCancelFn = *const fn (user: ?*anyopaque, req_id: u64) callconv(.c) void;

/// What a tile answer says, in charttable's terms.
pub const TileStatus = enum(u8) { ok, empty, failed };

/// The renderer's half of the feature, behind a vtable so the machine can be
/// driven with no renderer, no GPU and no network at all.
pub const Sink = struct {
    ctx: *anyopaque,
    /// Draw `json` instead of the engine's portrayal, or null for lookout's
    /// own chart. False when the core refuses the style.
    setStyle: *const fn (ctx: *anyopaque, json: ?[]const u8) bool,
    /// Fold one sprite pack into the resident atlas. Answers cells added.
    spritePack: *const fn (ctx: *anyopaque, prefix: []const u8, index_json: []const u8, png: []const u8) usize,
    /// Answer one tile the renderer parked, by the id it asked under.
    tileRespond: *const fn (ctx: *anyopaque, provider_req: u64, bytes: []const u8, status: TileStatus) void,
};

/// How many resolve fetches (style, sibling, TileJSON, sprites) may be
/// outstanding at once, and how many tiles. TWO budgets, not one: resolve
/// fetches are always few, and a mariner's new `add` must go out at once
/// rather than wait behind a tile budget a fresh zoom level has filled.
pub const MAX_RESOLVE_INFLIGHT = 8;
pub const MAX_TILE_INFLIGHT = 24;
/// A ceiling on tiles waiting for a budget slot. Past it the oldest is failed
/// rather than dropped: a tile nobody answers is a hole in the chart that
/// never fills, and a failed tile is asked again after an eviction.
pub const MAX_TILE_QUEUE = 1024;

/// A cap on any document the machine will read, so a hostile or broken host
/// cannot grow the process without limit. Sprite sheets are the large ones.
pub const MAX_DOC_BYTES = 32 << 20;

/// A cap on how many links one mariner carries, and on the list file.
pub const MAX_LINKS = 256;
const MAX_LIST_BYTES = 1 << 20;

/// One chart the mariner added.
pub const Entry = struct {
    /// What the machine fetches: the typed link, or the sibling style.json
    /// when the link was a TileJSON that shipped one beside it.
    url: []u8,
    name: []u8,
    /// A LOCAL link's kept style text. The path may not read the same next
    /// launch — a removed stick, a sandbox that no longer reaches it — so the
    /// text that worked is carried. Null for a network link, which is fetched
    /// fresh every time. Read lazily off disk; see docPath.
    doc: ?[]u8 = null,
    /// Whether a kept doc exists on disk (so a lazy read knows to try).
    has_doc: bool = false,
};

/// Where a source's tiles come from, after the style is resolved.
const TileSource = struct {
    name: []u8,
    /// The style's url templates, `{z}/{x}/{y}` still in them.
    templates: std.ArrayList([]u8) = .empty,
    /// TMS counts y from the south; the style spec counts from the north.
    tms: bool = false,
};

const Op = enum { add, select, refresh };

const Phase = enum { style, sibling, tilejson, sprites };

/// One sprite pack being fetched. @2x first — the sheets draw at their
/// authored logical size whatever the ratio, and every display that matters is
/// dense — with the 1x pair as the fallback for a publisher who ships only
/// one. A pack that will not fetch is skipped, not fatal: the chart draws,
/// short its icons.
const Pack = struct {
    prefix: []u8,
    base: []u8,
    /// 0 while the @2x pair is in flight, 1 for the 1x retry.
    density: u8 = 0,
    json: ?[]u8 = null,
    png: ?[]u8 = null,
    /// Answers still outstanding for this pack (0, 1 or 2).
    waiting: u8 = 0,
    /// Either fetched or given up on: the phase ends when every pack is.
    settled: bool = false,
};

/// One resolve in flight.
const Resolve = struct {
    epoch: u64,
    op: Op,
    /// The link as typed (add) or the entry's url (select/refresh).
    link: []u8,
    /// What the entry's url will become — the link, or the sibling style.json.
    url: []u8,
    name: []u8,
    /// Whether the STYLE DOCUMENT was read from local disk. Sub-resources may
    /// reach the disk only when this is true (and only inside link's dir).
    local: bool,
    phase: Phase,
    /// The style being rewritten, and the arena that owns every byte of it.
    arena: *std.heap.ArenaAllocator,
    style: ?std.json.Value = null,
    /// The style text a LOCAL link keeps.
    text: ?[]u8 = null,
    /// Something to tell the mariner even though the chart drew: the kept
    /// text standing in for a path that would not read. Static or arena.
    note: []const u8 = "",
    /// Phase 2: source names by request index, so an answer finds its source.
    src_names: std.ArrayList([]u8) = .empty,
    waiting_tilejson: usize = 0,
    /// Phase 3.
    packs: std.ArrayList(Pack) = .empty,
};

/// What one outstanding request is for.
const Kind = union(enum) {
    style,
    sibling,
    /// Index into the resolve's src_names.
    tilejson: usize,
    /// Index into the resolve's packs.
    sprite_json: usize,
    sprite_png: usize,
    /// The renderer's own request id for this tile.
    tile: u64,
};

const Req = struct {
    id: u64,
    epoch: u64,
    kind: Kind,

    fn isTile(self: Req) bool {
        return self.kind == .tile;
    }
};

/// A tile ask waiting for a budget slot.
const TileAsk = struct {
    provider_req: u64,
    url: []u8,
};

/// One answer, as it lands from a fetch thread.
const Answer = struct {
    id: u64,
    bytes: []u8,
    status: c_int,
};

// ---- the read a shell draws ---------------------------------------------------

/// One chart the mariner added by link. Picking it renders that publisher's
/// style instead of the built-in chart.
pub const Link = extern struct {
    url: [*:0]const u8,
    name: [*:0]const u8,
};

/// Everything beside the list. `active` is the picked link's url, empty for
/// lookout's own chart.
pub const State = extern struct {
    active: [*:0]const u8,
    /// A condition of service on public tile hosts, not a courtesy: draw it
    /// while a link is active. Empty when there is none.
    attribution: [*:0]const u8,
    /// Empty when the last resolve succeeded.
    err: [*:0]const u8,
    /// 1 while a resolve is in flight.
    busy: c_int,
};

/// The link list, held until the shell frees it.
pub const Read = struct {
    arena: std.heap.ArenaAllocator,
    state: State = undefined,
    links: []const *const Link = &.{},

    pub fn free(self: *Read) void {
        const gpa = self.arena.child_allocator;
        self.arena.deinit();
        gpa.destroy(self);
    }
};

pub const Links = struct {
    alloc: std.mem.Allocator,
    sink: Sink,

    get: ?HttpGetFn = null,
    cancel: ?HttpCancelFn = null,
    user: ?*anyopaque = null,

    /// Where links.json and the kept style docs live. Null keeps the list in
    /// memory only, which is what a test and a platform with no per-user
    /// directory get.
    dir: ?[]u8 = null,

    entries: std.ArrayList(Entry) = .empty,
    /// The selected link's url, or null for lookout's own chart.
    active: ?[]u8 = null,
    /// The credit line the active style's sources ask for. Owned; "" for none.
    attribution: []u8 = &.{},
    /// What went wrong with the last operation. Owned; "" for none.
    err: []u8 = &.{},
    /// Raised whenever the snapshot the UI renders changes. ONE consumer: the
    /// shell's frame loop owns the poll.
    changed: bool = false,

    epoch: u64 = 0,
    rs: ?*Resolve = null,

    next_req: u64 = 1,
    reqs: std.ArrayList(Req) = .empty,
    resolve_inflight: usize = 0,
    tiles_inflight: usize = 0,

    sources: std.ArrayList(TileSource) = .empty,
    tile_queue: std.ArrayList(TileAsk) = .empty,

    /// Answers from the shell's fetch threads. Guarded by inbox_mu ALONE — the
    /// api lock is deliberately not taken here.
    inbox_mu: Lock = .{},
    inbox: std.ArrayList(Answer) = .empty,
    /// Read by needsRedraw without the api lock, so a shell that draws on
    /// demand wakes for an answer that landed.
    inbox_len: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    pub fn init(alloc: std.mem.Allocator, sink: Sink) Links {
        return .{ .alloc = alloc, .sink = sink };
    }

    pub fn deinit(self: *Links) void {
        self.dropResolve();
        for (self.entries.items) |*e| self.freeEntry(e);
        self.entries.deinit(self.alloc);
        if (self.active) |a| self.alloc.free(a);
        self.freeStr(&self.attribution);
        self.freeStr(&self.err);
        self.clearSources();
        self.sources.deinit(self.alloc);
        for (self.tile_queue.items) |q| self.alloc.free(q.url);
        self.tile_queue.deinit(self.alloc);
        self.reqs.deinit(self.alloc);
        for (self.inbox.items) |a| self.alloc.free(a.bytes);
        self.inbox.deinit(self.alloc);
        if (self.dir) |d| self.alloc.free(d);
        self.* = undefined;
    }

    fn freeEntry(self: *Links, e: *Entry) void {
        self.alloc.free(e.url);
        self.alloc.free(e.name);
        if (e.doc) |d| self.alloc.free(d);
    }

    fn freeStr(self: *Links, s: *[]u8) void {
        if (s.len != 0) self.alloc.free(s.*);
        s.* = &.{};
    }

    fn setStr(self: *Links, s: *[]u8, text: []const u8) void {
        const copy = if (text.len == 0) @as([]u8, &.{}) else self.alloc.dupe(u8, text) catch return;
        self.freeStr(s);
        s.* = copy;
    }

    // ---- the shell's fetcher -------------------------------------------------

    /// Adopt the shell's fetcher. Clearing it (get null) stands the feature
    /// down: every outstanding request is abandoned and its tiles failed,
    /// because a tile nobody will answer is a hole that never fills.
    pub fn setProvider(self: *Links, get: ?HttpGetFn, cancel: ?HttpCancelFn, user: ?*anyopaque) void {
        self.get = get;
        self.cancel = cancel;
        self.user = user;
        if (get == null) {
            self.dropResolve();
            self.cancelResolves();
            self.cancelTiles();
            return;
        }
        // A fetcher arriving is what the chart the mariner left selected has
        // been waiting for: resolving needs one, and the list is read before
        // the shell can have set it.
        self.reapply();
    }

    pub fn hasProvider(self: *const Links) bool {
        return self.get != null;
    }

    /// Hand one url to the shell and remember what its answer is for. Answers
    /// the request id, or 0 when there is nobody to ask.
    fn issue(self: *Links, url: []const u8, allow_file: bool, kind: Kind) u64 {
        const get = self.get orelse return 0;
        const z = self.alloc.dupeZ(u8, url) catch return 0;
        defer self.alloc.free(z);
        const id = self.next_req;
        self.next_req += 1;
        self.reqs.append(self.alloc, .{ .id = id, .epoch = self.epoch, .kind = kind }) catch return 0;
        if (kind == .tile) self.tiles_inflight += 1 else self.resolve_inflight += 1;
        // The api lock is already held, and the shell's rule is to start the
        // fetch and return. It may answer before this call ends — respond only
        // enqueues, so that is safe.
        get(self.user, id, z.ptr, if (allow_file) 1 else 0);
        return id;
    }

    /// Forget one request and release its budget slot. The shell is told when
    /// it may still be transferring.
    fn retire(self: *Links, id: u64, tell_shell: bool) ?Req {
        for (self.reqs.items, 0..) |r, i| {
            if (r.id != id) continue;
            const req = self.reqs.swapRemove(i);
            if (req.isTile()) {
                self.tiles_inflight -= 1;
            } else {
                self.resolve_inflight -= 1;
            }
            if (tell_shell) {
                if (self.cancel) |c| c(self.user, id);
            }
            return req;
        }
        return null;
    }

    /// Cancel every outstanding RESOLVE request, releasing its slot at once
    /// rather than when it answers. A superseded epoch must not hold budget.
    fn cancelResolves(self: *Links) void {
        var i: usize = 0;
        while (i < self.reqs.items.len) {
            if (self.reqs.items[i].isTile()) {
                i += 1;
                continue;
            }
            const r = self.reqs.swapRemove(i);
            self.resolve_inflight -= 1;
            if (self.cancel) |c| c(self.user, r.id);
        }
    }

    /// Cancel every outstanding tile. Called when the style they belong to
    /// goes away: a tile of a chart nobody is looking at any more is bandwidth
    /// spent for nothing, and at sea that matters. A cancelled tile is FAILED
    /// rather than left parked — the renderer would wait on it forever — and
    /// failed is cacheable only until an eviction, so it is asked again if the
    /// chart comes back.
    fn cancelTiles(self: *Links) void {
        var i: usize = 0;
        while (i < self.reqs.items.len) {
            if (!self.reqs.items[i].isTile()) {
                i += 1;
                continue;
            }
            const r = self.reqs.swapRemove(i);
            self.tiles_inflight -= 1;
            self.sink.tileRespond(self.sink.ctx, r.kind.tile, &.{}, .failed);
            if (self.cancel) |c| c(self.user, r.id);
        }
        for (self.tile_queue.items) |q| {
            self.alloc.free(q.url);
            self.sink.tileRespond(self.sink.ctx, q.provider_req, &.{}, .failed);
        }
        self.tile_queue.clearRetainingCapacity();
    }

    // ---- answers -------------------------------------------------------------

    /// One answer, from any thread. Enqueues and returns; the frame loop
    /// adopts it. `status` is the final HTTP status after redirects, or 0 for
    /// a transport failure. Bytes are copied.
    pub fn respond(self: *Links, req_id: u64, bytes: []const u8, status: c_int) void {
        const keep: []u8 = if (bytes.len == 0 or bytes.len > MAX_DOC_BYTES)
            &.{}
        else
            self.alloc.dupe(u8, bytes) catch &.{};
        self.inbox_mu.lock();
        defer self.inbox_mu.unlock();
        self.inbox.append(self.alloc, .{
            .id = req_id,
            .bytes = keep,
            .status = if (bytes.len > MAX_DOC_BYTES) 0 else status,
        }) catch {
            if (keep.len != 0) self.alloc.free(keep);
            return;
        };
        // Under the lock with the append, not after it: an adopt clearing the
        // count outside the lock could clobber a store from here and leave an
        // answer sitting in the queue with nothing to raise a frame for it.
        self.inbox_len.store(self.inbox.items.len, .release);
    }

    /// True while an answer is waiting to be adopted. Read without the api
    /// lock, so a shell that draws on demand keeps ticking until the machine
    /// has taken everything.
    pub fn pending(self: *const Links) bool {
        return self.inbox_len.load(.acquire) != 0;
    }

    /// Take every answer that landed and advance on it. Call once at the top of
    /// a frame, under the api lock.
    pub fn adopt(self: *Links) void {
        if (self.inbox_len.load(.acquire) == 0) return;
        var taken: std.ArrayList(Answer) = .empty;
        defer {
            for (taken.items) |a| if (a.bytes.len != 0) self.alloc.free(a.bytes);
            taken.deinit(self.alloc);
        }
        self.inbox_mu.lock();
        taken = self.inbox;
        self.inbox = .empty;
        self.inbox_len.store(0, .release);
        self.inbox_mu.unlock();

        for (taken.items) |a| self.dispatch(a);
        self.pumpTileQueue();
    }

    fn dispatch(self: *Links, a: Answer) void {
        const req = self.retire(a.id, false) orelse return;
        const ok = a.status >= 200 and a.status < 300;
        if (req.kind == .tile) {
            // 404 and 204 say the publisher genuinely has no tile there — a
            // hole in their coverage, not a fault, and worth remembering as
            // one so it is not re-asked every frame.
            const st: TileStatus = if (ok and a.bytes.len != 0)
                .ok
            else if (ok or a.status == 404 or a.status == 204)
                .empty
            else
                .failed;
            self.sink.tileRespond(self.sink.ctx, req.kind.tile, a.bytes, st);
            return;
        }
        const rs = self.rs orelse return;
        // A superseded epoch's answers are dropped: a newer add or select owns
        // the chart now.
        if (req.epoch != rs.epoch) return;
        switch (req.kind) {
            .style => self.onStyle(rs, a.bytes, ok),
            .sibling => self.onSibling(rs, a.bytes, ok),
            .tilejson => |i| self.onTileJson(rs, i, a.bytes, ok),
            .sprite_json => |i| self.onSprite(rs, i, a.bytes, ok, true),
            .sprite_png => |i| self.onSprite(rs, i, a.bytes, ok, false),
            .tile => unreachable,
        }
    }

    // ---- the management surface ---------------------------------------------

    /// Add a chart by link: resolve it and, on success, keep it and select it.
    pub fn add(self: *Links, link: []const u8) void {
        const trimmed = std.mem.trim(u8, link, " \t\r\n");
        if (trimmed.len == 0) return;
        // Already carried: pick it rather than adding a second row for it.
        if (self.find(trimmed) != null) {
            self.select(trimmed);
            return;
        }
        if (self.entries.items.len >= MAX_LINKS) {
            self.fail("That is as many charts as this carries.");
            return;
        }
        self.start(.add, trimmed, trimmed, true);
    }

    /// Draw one of the carried charts, or null for lookout's own.
    pub fn select(self: *Links, url: ?[]const u8) void {
        const want = url orelse {
            self.clearSelection();
            return;
        };
        const e = self.find(want) orelse return;
        // The pick is the mariner's and stands whatever the network does: an
        // offline resolve leaves it selected so the next open retries.
        self.setActive(want);
        self.save();
        self.changed = true;
        if (self.entryDoc(e)) |doc| {
            self.startFromText(.select, e.url, e.url, doc, true);
            return;
        }
        self.start(.select, e.url, e.url, isLocalPath(e.url));
    }

    /// Read the chart again. For a local link that means re-reading the typed
    /// path; when the read fails the kept text stands and the error is set.
    pub fn refresh(self: *Links, url: []const u8) void {
        const e = self.find(url) orelse return;
        self.setActive(url);
        self.changed = true;
        self.start(.refresh, e.url, e.url, isLocalPath(e.url));
    }

    /// Drop one chart. Its kept style text goes with it, and if it was the one
    /// being drawn, lookout's own chart comes back.
    pub fn remove(self: *Links, url: []const u8) void {
        for (self.entries.items, 0..) |*e, i| {
            if (!std.mem.eql(u8, e.url, url)) continue;
            self.deleteDoc(e.url);
            self.freeEntry(e);
            _ = self.entries.orderedRemove(i);
            if (self.active != null and std.mem.eql(u8, self.active.?, url)) {
                self.clearSelection();
            } else {
                self.save();
                self.changed = true;
            }
            return;
        }
    }

    fn find(self: *Links, url: []const u8) ?*Entry {
        for (self.entries.items) |*e| {
            if (std.mem.eql(u8, e.url, url)) return e;
        }
        return null;
    }

    fn setActive(self: *Links, url: ?[]const u8) void {
        const copy: ?[]u8 = if (url) |u| (self.alloc.dupe(u8, u) catch return) else null;
        if (self.active) |a| self.alloc.free(a);
        self.active = copy;
    }

    /// Back to lookout's own chart.
    fn clearSelection(self: *Links) void {
        self.dropResolve();
        self.cancelResolves();
        self.clearSources();
        self.setActive(null);
        self.freeStr(&self.attribution);
        self.freeStr(&self.err);
        _ = self.sink.setStyle(self.sink.ctx, null);
        self.save();
        self.changed = true;
    }

    /// Record a failure for the UI without touching the mariner's pick.
    fn fail(self: *Links, message: []const u8) void {
        self.setStr(&self.err, message);
        self.changed = true;
    }

    // ---- the resolve machine -------------------------------------------------

    fn start(self: *Links, op: Op, link: []const u8, url: []const u8, allow_file: bool) void {
        const rs = self.begin(op, link, url) orelse return;
        if (self.get == null) {
            self.abort("No way to fetch that link.");
            return;
        }
        rs.phase = .style;
        _ = self.issue(link, allow_file, .style);
    }

    /// A resolve that already has its style text: a local link's kept doc.
    fn startFromText(self: *Links, op: Op, link: []const u8, url: []const u8, text: []const u8, local: bool) void {
        const rs = self.begin(op, link, url) orelse return;
        rs.local = local;
        self.onStyleText(rs, text);
    }

    fn begin(self: *Links, op: Op, link: []const u8, url: []const u8) ?*Resolve {
        // A newer resolve supersedes an older one whose fetches are still
        // landing: the race a mariner causes by picking a second chart
        // mid-fetch.
        self.dropResolve();
        self.cancelResolves();
        self.epoch += 1;
        self.freeStr(&self.err);

        const arena = self.alloc.create(std.heap.ArenaAllocator) catch return null;
        arena.* = std.heap.ArenaAllocator.init(self.alloc);
        const a = arena.allocator();
        const rs = self.alloc.create(Resolve) catch {
            arena.deinit();
            self.alloc.destroy(arena);
            return null;
        };
        rs.* = .{
            .epoch = self.epoch,
            .op = op,
            .link = a.dupe(u8, link) catch "",
            .url = a.dupe(u8, url) catch "",
            .name = a.dupe(u8, defaultName(link)) catch "",
            .local = isLocalPath(link),
            .phase = .style,
            .arena = arena,
        };
        self.rs = rs;
        self.changed = true;
        return rs;
    }

    fn dropResolve(self: *Links) void {
        const rs = self.rs orelse return;
        self.rs = null;
        if (rs.text) |t| self.alloc.free(t);
        rs.arena.deinit();
        self.alloc.destroy(rs.arena);
        self.alloc.destroy(rs);
    }

    /// Give up on the resolve in flight, keeping the mariner's selection and
    /// standing lookout's own chart in behind it. The next open retries.
    fn abort(self: *Links, message: []const u8) void {
        self.dropResolve();
        self.cancelResolves();
        self.clearSources();
        self.freeStr(&self.attribution);
        _ = self.sink.setStyle(self.sink.ctx, null);
        self.fail(message);
    }

    /// Phase 1: the link itself came back.
    fn onStyle(self: *Links, rs: *Resolve, bytes: []const u8, ok: bool) void {
        if (!ok or bytes.len == 0) {
            // A local link that will not read keeps whatever text worked last
            // time: a stick pulled out must not lose the mariner the chart.
            if (rs.op == .refresh) {
                if (self.find(rs.url)) |e| {
                    if (self.entryDoc(e)) |doc| {
                        const keep = self.alloc.dupe(u8, doc) catch {
                            self.abort("Could not read that chart link.");
                            return;
                        };
                        defer self.alloc.free(keep);
                        rs.note = "Could not read that chart link; the kept chart stands.";
                        self.onStyleText(rs, keep);
                        return;
                    }
                }
            }
            self.abort("Could not read that chart link.");
            return;
        }
        self.onStyleText(rs, bytes);
    }

    fn onStyleText(self: *Links, rs: *Resolve, text: []const u8) void {
        const a = rs.arena.allocator();
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, a, text, .{}) catch {
            self.abort("No chart style or tile source at that link.");
            return;
        };
        if (parsed != .object) {
            self.abort("No chart style or tile source at that link.");
            return;
        }
        if (isStyle(parsed)) {
            rs.style = parsed;
            if (rs.local) rs.text = self.alloc.dupe(u8, text) catch null;
            if (memberString(parsed, "name")) |n| {
                if (n.len != 0) rs.name = a.dupe(u8, n) catch rs.name;
            }
            self.phaseTileJson(rs);
            return;
        }
        if (parsed.object.get("tiles") != null or parsed.object.get("tilejson") != null) {
            // A TileJSON names tiles, not a look. The publisher may have
            // shipped the look beside it — that is what the mariner pasted the
            // link expecting — so try style.json in the same directory first.
            rs.style = parsed;
            if (rs.local) rs.text = self.alloc.dupe(u8, text) catch null;
            if (siblingUrl(a, rs.link)) |cand| {
                rs.phase = .sibling;
                if (self.issue(cand, rs.local, .sibling) != 0) return;
            }
            self.wrapTileJson(rs);
            return;
        }
        self.abort("No chart style or tile source at that link.");
    }

    /// Phase 1b: the sibling style.json probe answered.
    fn onSibling(self: *Links, rs: *Resolve, bytes: []const u8, ok: bool) void {
        const a = rs.arena.allocator();
        if (ok and bytes.len != 0) {
            if (std.json.parseFromSliceLeaky(std.json.Value, a, bytes, .{})) |doc| {
                if (isStyle(doc)) {
                    // The entry becomes the sibling: that url is the chart.
                    rs.url = a.dupe(u8, siblingUrl(a, rs.link) orelse rs.link) catch rs.url;
                    rs.style = doc;
                    if (rs.local) {
                        if (rs.text) |t| self.alloc.free(t);
                        rs.text = self.alloc.dupe(u8, bytes) catch null;
                    }
                    const n = memberString(doc, "name") orelse "";
                    rs.name = a.dupe(u8, if (n.len != 0) n else defaultName(rs.url)) catch rs.name;
                    self.phaseTileJson(rs);
                    return;
                }
            } else |_| {}
        }
        self.wrapTileJson(rs);
    }

    /// No style beside the tiles: draw them in a legible generic scheme.
    fn wrapTileJson(self: *Links, rs: *Resolve) void {
        const doc = rs.style orelse {
            self.abort("No chart style or tile source at that link.");
            return;
        };
        const n = memberString(doc, "name") orelse "";
        if (n.len != 0) rs.name = rs.arena.allocator().dupe(u8, n) catch rs.name;
        const wrapper = wrapperStyle(rs.arena.allocator(), doc) catch {
            self.abort("No chart style or tile source at that link.");
            return;
        };
        rs.style = wrapper;
        if (rs.local) {
            // A local TileJSON keeps the WRAPPER, since that is the style the
            // chart is drawn from and the path may not read the same again.
            if (rs.text) |t| self.alloc.free(t);
            rs.text = std.json.Stringify.valueAlloc(self.alloc, wrapper, .{}) catch null;
        }
        self.phaseTileJson(rs);
    }

    /// Phase 2: every source that names a TileJSON instead of its tiles.
    ///
    /// Only an inlined source is something the renderer can act on: it reads
    /// each source's zoom band and tile size out of the style to know where to
    /// stop asking, and a source with no declared bounds asks for tiles at
    /// every zoom forever.
    fn phaseTileJson(self: *Links, rs: *Resolve) void {
        rs.phase = .tilejson;
        const style = rs.style orelse return;
        const sources = style.object.getPtr("sources") orelse {
            self.phaseSprites(rs);
            return;
        };
        if (sources.* != .object) {
            self.phaseSprites(rs);
            return;
        }
        const a = rs.arena.allocator();
        for (sources.object.keys()) |name| {
            const src = sources.object.getPtr(name) orelse continue;
            if (src.* != .object) continue;
            if (src.object.get("tiles") != null) continue;
            const link = memberString(src.*, "url") orelse continue;
            if (link.len == 0) continue;
            const idx = rs.src_names.items.len;
            rs.src_names.append(a, a.dupe(u8, name) catch continue) catch continue;
            // The security rule, applied: disk only when the document that
            // named the url was itself read from disk, and only inside the
            // typed link's directory.
            const allow = rs.local and insideLinkDir(rs.link, link);
            if (self.issue(link, allow, .{ .tilejson = idx }) == 0) {
                _ = rs.src_names.pop();
                continue;
            }
            rs.waiting_tilejson += 1;
        }
        if (rs.waiting_tilejson == 0) self.phaseSprites(rs);
    }

    fn onTileJson(self: *Links, rs: *Resolve, idx: usize, bytes: []const u8, ok: bool) void {
        rs.waiting_tilejson -= 1;
        defer if (rs.waiting_tilejson == 0) self.phaseSprites(rs);
        if (!ok or bytes.len == 0) return;
        if (idx >= rs.src_names.items.len) return;
        const style = rs.style orelse return;
        const sources = style.object.getPtr("sources") orelse return;
        const src = sources.object.getPtr(rs.src_names.items[idx]) orelse return;
        const a = rs.arena.allocator();
        const doc = std.json.parseFromSliceLeaky(std.json.Value, a, bytes, .{}) catch return;
        if (doc != .object) return;
        inlineTileJson(a, src, doc) catch {};
    }

    /// Phase 3: the sprite packs the style names.
    fn phaseSprites(self: *Links, rs: *Resolve) void {
        rs.phase = .sprites;
        const style = rs.style orelse return;
        const a = rs.arena.allocator();
        spriteRefs(a, style, &rs.packs) catch {};
        if (rs.packs.items.len == 0) {
            self.applyResolve(rs);
            return;
        }
        for (rs.packs.items, 0..) |*p, i| self.askPack(rs, p, i);
        if (self.packsSettled(rs)) self.applyResolve(rs);
    }

    fn askPack(self: *Links, rs: *Resolve, p: *Pack, i: usize) void {
        const a = rs.arena.allocator();
        const density: []const u8 = if (p.density == 0) "@2x" else "";
        const allow = rs.local and insideLinkDir(rs.link, p.base);
        const j = spriteVariant(a, p.base, density, ".json") catch {
            p.settled = true;
            return;
        };
        const b = spriteVariant(a, p.base, density, ".png") catch {
            p.settled = true;
            return;
        };
        p.waiting = 0;
        if (self.issue(j, allow, .{ .sprite_json = i }) != 0) p.waiting += 1;
        if (self.issue(b, allow, .{ .sprite_png = i }) != 0) p.waiting += 1;
        if (p.waiting == 0) p.settled = true;
    }

    fn onSprite(self: *Links, rs: *Resolve, idx: usize, bytes: []const u8, ok: bool, is_json: bool) void {
        if (idx >= rs.packs.items.len) return;
        const p = &rs.packs.items[idx];
        p.waiting -= 1;
        if (ok and bytes.len != 0) {
            const copy = rs.arena.allocator().dupe(u8, bytes) catch null;
            if (is_json) p.json = copy else p.png = copy;
        }
        if (p.waiting != 0) return;
        if (p.json != null and p.png != null) {
            p.settled = true;
        } else if (p.density == 0) {
            // No @2x pair: try the 1x one before giving the pack up.
            p.density = 1;
            p.json = null;
            p.png = null;
            self.askPack(rs, p, idx);
        } else {
            p.settled = true;
        }
        if (self.packsSettled(rs)) self.applyResolve(rs);
    }

    fn packsSettled(self: *Links, rs: *Resolve) bool {
        _ = self;
        for (rs.packs.items) |p| {
            if (!p.settled) return false;
        }
        return true;
    }

    /// Phase 4: hand the assembled style to the renderer and keep the link.
    fn applyResolve(self: *Links, rs: *Resolve) void {
        // Guarded on epoch and on the still-active url: an older resolve
        // finishing after the mariner moved on must not draw over them.
        if (rs.epoch != self.epoch) {
            self.dropResolve();
            return;
        }
        if (rs.op != .add) {
            const act = self.active orelse {
                self.dropResolve();
                return;
            };
            // Either name is the mariner's pick: a sibling style.json winning
            // mid-resolve rewrites the url the entry will carry.
            if (!std.mem.eql(u8, act, rs.url) and !std.mem.eql(u8, act, rs.link)) {
                self.dropResolve();
                return;
            }
        }
        const style = rs.style orelse {
            self.abort("No chart style or tile source at that link.");
            return;
        };
        const json = std.json.Stringify.valueAlloc(self.alloc, style, .{}) catch {
            self.abort("That chart style could not be drawn.");
            return;
        };
        defer self.alloc.free(json);

        if (!self.sink.setStyle(self.sink.ctx, json)) {
            // A style the CORE refuses is not a network problem and will not
            // fix itself: drop the pick so the credit does not claim the
            // publisher over lookout's own chart.
            _ = self.sink.setStyle(self.sink.ctx, null);
            self.dropResolve();
            self.cancelResolves();
            self.clearSources();
            self.setActive(null);
            self.freeStr(&self.attribution);
            self.fail("That chart style could not be drawn.");
            self.save();
            return;
        }

        self.installSources(style);
        // AFTER the style: setting one clears the previous style's packs.
        for (rs.packs.items) |p| {
            const j = p.json orelse continue;
            const b = p.png orelse continue;
            _ = self.sink.spritePack(self.sink.ctx, p.prefix, j, b);
        }
        self.setStr(&self.attribution, creditLine(rs.arena.allocator(), style) catch "");
        self.keepEntry(rs);
        self.setActive(rs.url);
        if (rs.note.len != 0) self.setStr(&self.err, rs.note) else self.freeStr(&self.err);
        self.save();
        self.changed = true;
        self.dropResolve();
    }

    /// Fold the resolve's result into the carried list.
    fn keepEntry(self: *Links, rs: *Resolve) void {
        if (self.find(rs.url) orelse self.find(rs.link)) |e| {
            if (!std.mem.eql(u8, e.url, rs.url)) {
                // A sibling style.json won: the entry follows it, and the kept
                // doc goes with the old key.
                const u = self.alloc.dupe(u8, rs.url) catch return;
                self.deleteDoc(e.url);
                self.alloc.free(e.url);
                e.url = u;
            }
            if (rs.name.len != 0 and !std.mem.eql(u8, e.name, rs.name)) {
                const n = self.alloc.dupe(u8, rs.name) catch return;
                self.alloc.free(e.name);
                e.name = n;
            }
            self.keepDoc(e, rs);
            return;
        }
        if (self.entries.items.len >= MAX_LINKS) return;
        const url = self.alloc.dupe(u8, rs.url) catch return;
        const name = self.alloc.dupe(u8, if (rs.name.len != 0) rs.name else rs.url) catch {
            self.alloc.free(url);
            return;
        };
        self.entries.append(self.alloc, .{ .url = url, .name = name }) catch {
            self.alloc.free(url);
            self.alloc.free(name);
            return;
        };
        self.keepDoc(&self.entries.items[self.entries.items.len - 1], rs);
    }

    fn keepDoc(self: *Links, e: *Entry, rs: *Resolve) void {
        const text = rs.text orelse return;
        const copy = self.alloc.dupe(u8, text) catch return;
        if (e.doc) |d| self.alloc.free(d);
        e.doc = copy;
        e.has_doc = true;
        self.writeDoc(e.url, copy);
    }

    // ---- tile serving --------------------------------------------------------

    /// What the renderer wants: source S at z/x/y. The template is filled here
    /// and the fetch goes out as any other url does.
    pub fn askTile(self: *Links, source: []const u8, provider_req: u64, z: i32, x: i32, y: i32) void {
        const url = self.tileUrl(source, z, x, y) orelse {
            // Answered, not dropped: a tile nobody answers is a hole in the
            // chart that never fills.
            self.sink.tileRespond(self.sink.ctx, provider_req, &.{}, .failed);
            return;
        };
        if (self.tiles_inflight < MAX_TILE_INFLIGHT) {
            defer self.alloc.free(url);
            if (self.issue(url, false, .{ .tile = provider_req }) == 0) {
                self.sink.tileRespond(self.sink.ctx, provider_req, &.{}, .failed);
            }
            return;
        }
        // Over budget: park it rather than dumping a whole zoom level on the
        // shell in one burst.
        if (self.tile_queue.items.len >= MAX_TILE_QUEUE) {
            const oldest = self.tile_queue.orderedRemove(0);
            self.alloc.free(oldest.url);
            self.sink.tileRespond(self.sink.ctx, oldest.provider_req, &.{}, .failed);
        }
        self.tile_queue.append(self.alloc, .{ .provider_req = provider_req, .url = url }) catch {
            self.alloc.free(url);
            self.sink.tileRespond(self.sink.ctx, provider_req, &.{}, .failed);
        };
    }

    fn pumpTileQueue(self: *Links) void {
        while (self.tile_queue.items.len != 0 and self.tiles_inflight < MAX_TILE_INFLIGHT) {
            const ask = self.tile_queue.orderedRemove(0);
            defer self.alloc.free(ask.url);
            if (self.issue(ask.url, false, .{ .tile = ask.provider_req }) == 0) {
                self.sink.tileRespond(self.sink.ctx, ask.provider_req, &.{}, .failed);
            }
        }
    }

    /// Fill a source's url template for one tile. The subdomain pick is
    /// deterministic, so the same tile keeps hitting the same host and stays
    /// cached there. TMS counts y from the south.
    pub fn tileUrl(self: *Links, source: []const u8, z: i32, x: i32, y: i32) ?[]u8 {
        if (z < 0 or z > 30 or x < 0 or y < 0) return null;
        for (self.sources.items) |s| {
            if (!std.mem.eql(u8, s.name, source)) continue;
            if (s.templates.items.len == 0) return null;
            const pick: usize = @intCast(@mod(@as(i64, x) + @as(i64, y), @as(i64, @intCast(s.templates.items.len))));
            const ty: i64 = if (s.tms) (@as(i64, 1) << @intCast(z)) - 1 - y else y;
            return fillTemplate(self.alloc, s.templates.items[pick], z, x, ty) catch null;
        }
        return null;
    }

    /// Forget where the current style's tiles came from. Its outstanding
    /// tiles go with it: they are asks about a chart nobody is looking at any
    /// more.
    fn clearSources(self: *Links) void {
        self.cancelTiles();
        for (self.sources.items) |*s| {
            for (s.templates.items) |t| self.alloc.free(t);
            s.templates.deinit(self.alloc);
            self.alloc.free(s.name);
        }
        self.sources.clearRetainingCapacity();
    }

    fn installSources(self: *Links, style: std.json.Value) void {
        self.clearSources();
        const sources = style.object.get("sources") orelse return;
        if (sources != .object) return;
        for (sources.object.keys()) |name| {
            const src = sources.object.get(name) orelse continue;
            if (src != .object) continue;
            const tiles = src.object.get("tiles") orelse continue;
            if (tiles != .array) continue;
            var s = TileSource{ .name = self.alloc.dupe(u8, name) catch continue };
            for (tiles.array.items) |t| {
                if (t != .string) continue;
                const copy = self.alloc.dupe(u8, t.string) catch continue;
                s.templates.append(self.alloc, copy) catch self.alloc.free(copy);
            }
            const scheme = memberString(src, "scheme") orelse "";
            s.tms = std.ascii.eqlIgnoreCase(scheme, "tms");
            if (s.templates.items.len == 0) {
                s.templates.deinit(self.alloc);
                self.alloc.free(s.name);
                continue;
            }
            self.sources.append(self.alloc, s) catch {
                for (s.templates.items) |t| self.alloc.free(t);
                s.templates.deinit(self.alloc);
                self.alloc.free(s.name);
            };
        }
    }

    // ---- what the UI renders -------------------------------------------------

    /// Everything the UI shows, as one transfer-full document. One document on
    /// purpose: borrowed per-field getters could be freed under the caller by
    /// a resolve finishing on a fetch thread.
    pub fn snapshotAlloc(self: *Links, alloc: std.mem.Allocator) ?[:0]u8 {
        var out: std.ArrayList(u8) = .empty;
        self.writeSnapshot(alloc, &out, true) catch {
            out.deinit(alloc);
            return null;
        };
        return out.toOwnedSliceSentinel(alloc, 0) catch {
            out.deinit(alloc);
            return null;
        };
    }

    /// The same snapshot, as structs. Both this and `snapshotAlloc` walk the
    /// same state under the same lock, so the two say the same thing.
    pub fn read(self: *Links, gpa: std.mem.Allocator) !*Read {
        const out = try gpa.create(Read);
        errdefer gpa.destroy(out);
        out.* = .{ .arena = std.heap.ArenaAllocator.init(gpa) };
        errdefer out.arena.deinit();
        const a = out.arena.allocator();

        const rows = try a.alloc(Link, self.entries.items.len);
        const by_ptr = try a.alloc(*const Link, rows.len);
        for (self.entries.items, rows, by_ptr) |e, *dst, *p| {
            dst.* = .{
                .url = try owned.str(a, e.url),
                .name = try owned.str(a, e.name),
            };
            p.* = dst;
        }
        out.links = by_ptr;
        out.state = .{
            // Empty is lookout's own chart, where the JSON writes null. A url
            // is never empty.
            .active = try owned.str(a, self.active orelse ""),
            .attribution = try owned.str(a, self.attribution),
            .err = try owned.str(a, self.err),
            .busy = @intFromBool(self.rs != null),
        };
        return out;
    }

    /// `full` writes what the UI renders; without it, only what the store
    /// keeps — which is exactly the shape `import` takes.
    fn writeSnapshot(self: *Links, alloc: std.mem.Allocator, out: *std.ArrayList(u8), full: bool) !void {
        try out.appendSlice(alloc, "{\"links\":[");
        for (self.entries.items, 0..) |e, i| {
            if (i > 0) try out.append(alloc, ',');
            try out.appendSlice(alloc, "{\"url\":");
            try jsonString(alloc, out, e.url);
            try out.appendSlice(alloc, ",\"name\":");
            try jsonString(alloc, out, e.name);
            try out.append(alloc, '}');
        }
        try out.appendSlice(alloc, "],\"active\":");
        if (self.active) |a| {
            try jsonString(alloc, out, a);
        } else {
            try out.appendSlice(alloc, "null");
        }
        if (full) {
            try out.appendSlice(alloc, ",\"attribution\":");
            try jsonString(alloc, out, self.attribution);
            try out.appendSlice(alloc, ",\"error\":");
            try jsonString(alloc, out, self.err);
            // What a shell shows as "working": one resolve is in flight.
            try out.appendSlice(alloc, if (self.rs != null) ",\"busy\":true" else ",\"busy\":false");
        }
        try out.appendSlice(alloc, "}");
    }

    /// 1 since the last poll, then clears.
    pub fn takeChanged(self: *Links) bool {
        const was = self.changed;
        self.changed = false;
        return was;
    }

    // ---- the store -----------------------------------------------------------

    /// Adopt a directory and read whatever list is in it. Called once, before
    /// the shell can have asked for anything.
    pub fn openStore(self: *Links, dir: []const u8) void {
        if (self.dir) |d| self.alloc.free(d);
        self.dir = self.alloc.dupe(u8, dir) catch null;
        self.load();
    }

    fn listPath(self: *Links, alloc: std.mem.Allocator) ?[]u8 {
        const d = self.dir orelse return null;
        return std.fmt.allocPrint(alloc, "{s}/chartlinks.json", .{d}) catch null;
    }

    /// A kept style's own file, keyed by a hash of the link: a style can run
    /// to megabytes and the list stays a list.
    fn docPath(self: *Links, alloc: std.mem.Allocator, url: []const u8) ?[]u8 {
        const d = self.dir orelse return null;
        const h = std.hash.Wyhash.hash(0, url);
        return std.fmt.allocPrint(alloc, "{s}/chartlink-{x:0>16}.json", .{ d, h }) catch null;
    }

    /// A local entry's kept style text, read off disk on first use.
    fn entryDoc(self: *Links, e: *Entry) ?[]const u8 {
        if (e.doc) |d| return d;
        if (!e.has_doc) return null;
        const path = self.docPath(self.alloc, e.url) orelse return null;
        defer self.alloc.free(path);
        const io = std.Io.Threaded.global_single_threaded.io();
        const text = std.Io.Dir.cwd().readFileAlloc(io, path, self.alloc, .limited(MAX_DOC_BYTES)) catch {
            e.has_doc = false;
            return null;
        };
        e.doc = text;
        return text;
    }

    fn writeDoc(self: *Links, url: []const u8, text: []const u8) void {
        const path = self.docPath(self.alloc, url) orelse return;
        defer self.alloc.free(path);
        const io = std.Io.Threaded.global_single_threaded.io();
        const d = self.dir orelse return;
        std.Io.Dir.cwd().createDirPath(io, d) catch {};
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = text }) catch {};
    }

    fn deleteDoc(self: *Links, url: []const u8) void {
        const path = self.docPath(self.alloc, url) orelse return;
        defer self.alloc.free(path);
        const io = std.Io.Threaded.global_single_threaded.io();
        std.Io.Dir.cwd().deleteFile(io, path) catch {};
    }

    fn load(self: *Links) void {
        const path = self.listPath(self.alloc) orelse return;
        defer self.alloc.free(path);
        const io = std.Io.Threaded.global_single_threaded.io();
        const text = std.Io.Dir.cwd().readFileAlloc(io, path, self.alloc, .limited(MAX_LIST_BYTES)) catch return;
        defer self.alloc.free(text);
        self.adoptList(text);
    }

    /// Read a list document — ours, or a shell's old store on migration.
    /// Anything that will not parse is ignored rather than fatal: a mariner
    /// losing their charts is bad, and refusing to open over it is worse.
    fn adoptList(self: *Links, text: []const u8) void {
        var parsed = std.json.parseFromSlice(std.json.Value, self.alloc, text, .{}) catch return;
        defer parsed.deinit();
        const arr: std.json.Value = switch (parsed.value) {
            .array => parsed.value,
            .object => parsed.value.object.get("links") orelse return,
            else => return,
        };
        if (arr != .array) return;

        for (self.entries.items) |*e| self.freeEntry(e);
        self.entries.clearRetainingCapacity();

        for (arr.array.items) |it| {
            if (self.entries.items.len >= MAX_LINKS) break;
            if (it != .object) continue;
            const url = memberString(it, "url") orelse continue;
            if (url.len == 0) continue;
            const name = memberString(it, "name") orelse "";
            const u = self.alloc.dupe(u8, url) catch continue;
            const n = self.alloc.dupe(u8, if (name.len != 0) name else defaultName(url)) catch {
                self.alloc.free(u);
                continue;
            };
            // has_doc is a maybe, not a claim: entryDoc clears it when the
            // file is not there, which spares a stat per row at load.
            self.entries.append(self.alloc, .{ .url = u, .name = n, .has_doc = true }) catch {
                self.alloc.free(u);
                self.alloc.free(n);
                continue;
            };
            // A shell's old store may carry the style TEXT it kept for a local
            // link. Take it: the path may no longer read (a sandbox grant ends
            // with the session that made it), and the text is then the only
            // copy of that chart. A network link's kept doc is NOT taken —
            // that one is a wrapper over a TileJSON, resolved from the url.
            const doc = memberString(it, "doc") orelse "";
            if (doc.len != 0 and isLocalPath(url)) {
                const e = &self.entries.items[self.entries.items.len - 1];
                e.doc = self.alloc.dupe(u8, doc) catch null;
                if (e.doc) |d| self.writeDoc(e.url, d);
            }
        }
        const act = if (parsed.value == .object) parsed.value.object.get("active") else null;
        if (act) |a| {
            if (a == .string and self.find(a.string) != null) self.setActive(a.string);
        }
        self.changed = true;
    }

    /// Write the list. Through a temporary and a rename, so a machine that
    /// loses power mid-write keeps the charts it had rather than a half file.
    fn save(self: *Links) void {
        const path = self.listPath(self.alloc) orelse return;
        defer self.alloc.free(path);
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.alloc);
        self.writeSnapshot(self.alloc, &out, false) catch return;
        const text = out.items;

        const io = std.Io.Threaded.global_single_threaded.io();
        const d = self.dir orelse return;
        const cwd = std.Io.Dir.cwd();
        cwd.createDirPath(io, d) catch {};
        const tmp = std.fmt.allocPrint(self.alloc, "{s}.tmp", .{path}) catch return;
        defer self.alloc.free(tmp);
        cwd.writeFile(io, .{ .sub_path = tmp, .data = text }) catch return;
        cwd.rename(tmp, cwd, path, io) catch {
            cwd.deleteFile(io, tmp) catch {};
        };
    }

    /// One-time migration from a shell's old store. Ignored once the core has
    /// a list of its own, so a crash between the import and the shell deleting
    /// its store replays harmlessly next launch.
    pub fn import(self: *Links, links_json: []const u8) void {
        if (self.entries.items.len != 0) return;
        self.adoptList(links_json);
        if (self.entries.items.len == 0) return;
        self.save();
        self.changed = true;
        // The list the shell just handed over may name a selected chart, and
        // the import lands AFTER the fetcher was set — so nothing else would
        // draw it until the mariner picked something.
        self.reapply();
    }

    /// Draw whatever was selected when the list was read. Called once the
    /// shell has a fetcher, since resolving needs one.
    pub fn reapply(self: *Links) void {
        const act = self.active orelse return;
        const url = self.alloc.dupe(u8, act) catch return;
        defer self.alloc.free(url);
        self.select(url);
    }
};

// ---- style shapes ------------------------------------------------------------

fn isStyle(v: std.json.Value) bool {
    if (v != .object) return false;
    return v.object.get("layers") != null and v.object.get("version") != null;
}

fn memberString(v: std.json.Value, name: []const u8) ?[]const u8 {
    if (v != .object) return null;
    const m = v.object.get(name) orelse return null;
    return if (m == .string) m.string else null;
}

/// Copy what a TileJSON says into the source that named it, and drop the url:
/// only an inlined source carries the zoom band and tile size the renderer
/// needs.
fn inlineTileJson(a: std.mem.Allocator, src: *std.json.Value, doc: std.json.Value) !void {
    const keys = [_][]const u8{ "tiles", "minzoom", "maxzoom", "bounds", "scheme", "attribution" };
    for (keys) |k| {
        const v = doc.object.get(k) orelse continue;
        try src.object.put(a, k, v);
    }
    // TileJSON says tileSize nowhere; raster tiles are 256 unless the style
    // already said otherwise, and getting this wrong draws the imagery one
    // zoom level off.
    if (src.object.get("tileSize") == null) {
        const kind = memberString(src.*, "type") orelse "";
        if (std.mem.eql(u8, kind, "raster")) try src.object.put(a, "tileSize", .{ .integer = 256 });
    }
    _ = src.object.orderedRemove("url");
}

/// The style.json beside a TileJSON, when the publisher shipped one.
fn siblingUrl(alloc: std.mem.Allocator, link: []const u8) ?[]const u8 {
    const cut = std.mem.lastIndexOfScalar(u8, link, '/') orelse return null;
    const cand = std.fmt.allocPrint(alloc, "{s}/style.json", .{link[0..cut]}) catch return null;
    if (std.mem.eql(u8, cand, link)) return null;
    return cand;
}

/// A style for a bare tile source. Raster tiles draw as imagery; vector tiles
/// draw each advertised layer in a legible generic scheme — honest geometry,
/// not the publisher's portrayal, which a tile source does not carry.
fn wrapperStyle(a: std.mem.Allocator, tilejson: std.json.Value) !std.json.Value {
    var layers = std.json.Array.init(a);

    var bg = std.json.ObjectMap.empty;
    var bg_paint = std.json.ObjectMap.empty;
    try bg_paint.put(a, "background-color", .{ .string = "#c9e2f0" });
    try bg.put(a, "id", .{ .string = "bg" });
    try bg.put(a, "type", .{ .string = "background" });
    try bg.put(a, "paint", .{ .object = bg_paint });
    try layers.append(.{ .object = bg });

    var source = std.json.ObjectMap.empty;

    const vlayers = tilejson.object.get("vector_layers");
    const vector = vlayers != null and vlayers.? == .array and vlayers.?.array.items.len > 0;

    if (!vector) {
        try source.put(a, "type", .{ .string = "raster" });
        var l = std.json.ObjectMap.empty;
        try l.put(a, "id", .{ .string = "tiles" });
        try l.put(a, "type", .{ .string = "raster" });
        try l.put(a, "source", .{ .string = "tiles" });
        try layers.append(.{ .object = l });
    } else {
        try source.put(a, "type", .{ .string = "vector" });
        const hues = [_]u32{ 210, 30, 120, 275, 0, 165, 55, 320 };
        for (vlayers.?.array.items, 0..) |el, i| {
            if (el != .object) continue;
            const lid = memberString(el, "id") orelse continue;
            if (lid.len == 0) continue;
            const low = try std.ascii.allocLowerString(a, lid);

            var radius: f64 = 2.5;
            var fill: []const u8 = undefined;
            var line: []const u8 = undefined;
            var point: []const u8 = undefined;
            if (has(low, "depare") or has(low, "depth") or has(low, "bathy")) {
                fill = "hsla(205,60%,70%,0.5)";
                line = "hsl(205,45%,55%)";
                point = "hsl(205,45%,45%)";
            } else if (has(low, "contour")) {
                fill = "hsla(205,30%,60%,0.15)";
                line = "hsl(205,35%,55%)";
                point = "hsl(205,35%,45%)";
            } else if (has(low, "sound")) {
                radius = 1.5;
                fill = "hsla(210,25%,55%,0.2)";
                line = "hsl(210,25%,55%)";
                point = "hsl(210,25%,35%)";
            } else if (has(low, "land") or has(low, "coast")) {
                fill = "hsla(45,45%,70%,0.9)";
                line = "hsl(45,30%,40%)";
                point = "hsl(45,30%,40%)";
            } else {
                const hue = hues[i % hues.len];
                fill = try std.fmt.allocPrint(a, "hsla({d},55%,62%,0.35)", .{hue});
                line = try std.fmt.allocPrint(a, "hsl({d},60%,38%)", .{hue});
                point = try std.fmt.allocPrint(a, "hsl({d},65%,40%)", .{hue});
            }

            var pf = std.json.ObjectMap.empty;
            try pf.put(a, "fill-color", .{ .string = fill });
            try layers.append(try wrapperLayer(a, lid, "-fill", "fill", "Polygon", pf));

            var pl = std.json.ObjectMap.empty;
            try pl.put(a, "line-color", .{ .string = line });
            try pl.put(a, "line-width", .{ .float = 1.0 });
            try layers.append(try wrapperLayer(a, lid, "-line", "line", "LineString", pl));

            var pp = std.json.ObjectMap.empty;
            try pp.put(a, "circle-radius", .{ .float = radius });
            try pp.put(a, "circle-color", .{ .string = point });
            try layers.append(try wrapperLayer(a, lid, "-pt", "circle", "Point", pp));
        }
    }

    // The document is already in hand, so the wrapper's one source is inlined
    // here rather than fetched again in phase 2.
    var src_value = std.json.Value{ .object = source };
    try inlineTileJson(a, &src_value, tilejson);

    var sources = std.json.ObjectMap.empty;
    try sources.put(a, "tiles", src_value);

    var style = std.json.ObjectMap.empty;
    try style.put(a, "version", .{ .integer = 8 });
    const name = memberString(tilejson, "name") orelse "Tiles";
    try style.put(a, "name", .{ .string = try a.dupe(u8, name) });
    try style.put(a, "sources", .{ .object = sources });
    try style.put(a, "layers", .{ .array = layers });
    return .{ .object = style };
}

fn wrapperLayer(
    a: std.mem.Allocator,
    lid: []const u8,
    suffix: []const u8,
    kind: []const u8,
    geometry: []const u8,
    paint: std.json.ObjectMap,
) !std.json.Value {
    var layer = std.json.ObjectMap.empty;
    try layer.put(a, "id", .{ .string = try std.fmt.allocPrint(a, "{s}{s}", .{ lid, suffix }) });
    try layer.put(a, "type", .{ .string = kind });
    try layer.put(a, "source", .{ .string = "tiles" });
    try layer.put(a, "source-layer", .{ .string = try a.dupe(u8, lid) });

    var getter = std.json.Array.init(a);
    try getter.append(.{ .string = "geometry-type" });
    var filter = std.json.Array.init(a);
    try filter.append(.{ .string = "==" });
    try filter.append(.{ .array = getter });
    try filter.append(.{ .string = geometry });
    try layer.put(a, "filter", .{ .array = filter });
    try layer.put(a, "paint", .{ .object = paint });
    return .{ .object = layer };
}

fn has(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

// ---- sprites -----------------------------------------------------------------

/// The style's `sprite` root: one base url, or the array form of {id, url}
/// packs whose icons resolve as "id:name" ("default" gives bare names).
fn spriteRefs(a: std.mem.Allocator, style: std.json.Value, out: *std.ArrayList(Pack)) !void {
    const node = style.object.get("sprite") orelse return;
    if (node == .string) {
        if (node.string.len == 0) return;
        try out.append(a, .{ .prefix = try a.dupe(u8, ""), .base = try a.dupe(u8, node.string) });
        return;
    }
    if (node != .array) return;
    for (node.array.items) |el| {
        if (el != .object) continue;
        const url = memberString(el, "url") orelse continue;
        if (url.len == 0) continue;
        const id = memberString(el, "id") orelse "";
        const prefix = if (std.mem.eql(u8, id, "default")) "" else id;
        try out.append(a, .{ .prefix = try a.dupe(u8, prefix), .base = try a.dupe(u8, url) });
    }
}

/// "…/sprite" + "@2x" + ".json", keeping a query string at the end: an
/// API-keyed host serves …/sprite@2x.json?key=K, never …?key=K@2x.json.
fn spriteVariant(a: std.mem.Allocator, base: []const u8, density: []const u8, ext: []const u8) ![]u8 {
    const q = std.mem.indexOfScalar(u8, base, '?') orelse
        return std.fmt.allocPrint(a, "{s}{s}{s}", .{ base, density, ext });
    return std.fmt.allocPrint(a, "{s}{s}{s}{s}", .{ base[0..q], density, ext, base[q..] });
}

// ---- attribution -------------------------------------------------------------

/// The credit line the sources ask for: distinct attributions, HTML markup
/// reduced to its text. Public tile hosts make the visible credit a condition
/// of service, openstreetmap.org's tile usage policy among them.
fn creditLine(a: std.mem.Allocator, style: std.json.Value) ![]const u8 {
    var credits: std.ArrayList([]const u8) = .empty;
    const sources = style.object.get("sources") orelse return "";
    if (sources != .object) return "";
    for (sources.object.keys()) |name| {
        const src = sources.object.get(name) orelse continue;
        const raw = memberString(src, "attribution") orelse continue;
        const text = try stripMarkup(a, raw);
        if (text.len == 0) continue;
        try credits.append(a, text);
    }

    var out: std.ArrayList(u8) = .empty;
    for (credits.items, 0..) |c, i| {
        // An attribution CONTAINED in another is dropped: sources repeat each
        // other's credits inside composite strings, and keeping both runs the
        // line longer than the scale bar it sits under.
        var drop = false;
        for (credits.items, 0..) |other, k| {
            if (k == i) continue;
            if (std.mem.eql(u8, other, c)) {
                if (k < i) drop = true; // an exact duplicate: the first speaks
            } else if (has(other, c)) {
                drop = true;
            }
            if (drop) break;
        }
        if (drop) continue;
        if (out.items.len != 0) try out.appendSlice(a, " \xC2\xB7 ");
        try out.appendSlice(a, c);
    }
    return out.items;
}

/// Tags removed and the entities a publisher actually writes decoded.
fn stripMarkup(a: std.mem.Allocator, raw: []const u8) ![]const u8 {
    const entities = [_]struct { name: []const u8, text: []const u8 }{
        .{ .name = "&copy;", .text = "\xC2\xA9" },
        .{ .name = "&lt;", .text = "<" },
        .{ .name = "&gt;", .text = ">" },
        .{ .name = "&quot;", .text = "\"" },
        .{ .name = "&#39;", .text = "'" },
        .{ .name = "&apos;", .text = "'" },
        .{ .name = "&nbsp;", .text = " " },
        // LAST: decoding it first would let "&amp;lt;" become "<".
        .{ .name = "&amp;", .text = "&" },
    };
    var out: std.ArrayList(u8) = .empty;
    var in_tag = false;
    var i: usize = 0;
    outer: while (i < raw.len) {
        const c = raw[i];
        if (c == '<') {
            in_tag = true;
            i += 1;
            continue;
        }
        if (c == '>') {
            in_tag = false;
            i += 1;
            continue;
        }
        if (in_tag) {
            i += 1;
            continue;
        }
        if (c == '&') {
            for (entities) |e| {
                if (std.mem.startsWith(u8, raw[i..], e.name)) {
                    try out.appendSlice(a, e.text);
                    i += e.name.len;
                    continue :outer;
                }
            }
        }
        try out.append(a, c);
        i += 1;
    }
    return std.mem.trim(u8, out.items, " \t\r\n");
}

// ---- urls --------------------------------------------------------------------

fn fillTemplate(alloc: std.mem.Allocator, template: []const u8, z: i32, x: i32, y: i64) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < template.len) {
        if (template[i] == '{' and i + 2 < template.len and template[i + 2] == '}') {
            switch (template[i + 1]) {
                'z' => {
                    try out.print(alloc, "{d}", .{z});
                    i += 3;
                    continue;
                },
                'x' => {
                    try out.print(alloc, "{d}", .{x});
                    i += 3;
                    continue;
                },
                'y' => {
                    try out.print(alloc, "{d}", .{y});
                    i += 3;
                    continue;
                },
                else => {},
            }
        }
        try out.append(alloc, template[i]);
        i += 1;
    }
    return out.toOwnedSlice(alloc);
}

/// Whether a link names a place on this machine rather than a host. Anything
/// carrying a scheme that is not file:// is remote.
pub fn isLocalPath(link: []const u8) bool {
    if (std.mem.startsWith(u8, link, "file://")) return true;
    if (std.mem.indexOf(u8, link, "://") != null) return false;
    if (link.len == 0) return false;
    if (link[0] == '/' or link[0] == '.' or link[0] == '~') return true;
    // A Windows drive letter: C:\charts\style.json.
    if (link.len > 2 and link[1] == ':' and (link[2] == '\\' or link[2] == '/')) return true;
    return false;
}

/// The path a local link names, with the file:// prefix and any percent
/// escapes taken off. Borrowed from `link` when nothing had to be decoded.
fn localPath(buf: []u8, link: []const u8) ?[]const u8 {
    var s = link;
    if (std.mem.startsWith(u8, s, "file://")) {
        s = s["file://".len..];
        // file://host/path is not this machine; file:///path is.
        if (s.len != 0 and s[0] != '/') {
            const slash = std.mem.indexOfScalar(u8, s, '/') orelse return null;
            if (slash != 0) return null;
        }
    }
    if (std.mem.indexOfScalar(u8, s, '%') == null) return s;
    if (s.len > buf.len) return null;
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (n += 1) {
        if (s[i] == '%' and i + 2 < s.len) {
            const hi = std.fmt.charToDigit(s[i + 1], 16) catch {
                buf[n] = s[i];
                i += 1;
                continue;
            };
            const lo = std.fmt.charToDigit(s[i + 2], 16) catch {
                buf[n] = s[i];
                i += 1;
                continue;
            };
            buf[n] = @intCast(hi * 16 + lo);
            i += 3;
            continue;
        }
        buf[n] = s[i];
        i += 1;
    }
    return buf[0..n];
}

/// May the shell read `url` off disk, given that the document naming it was
/// itself read from disk at `link`? Only when the url is local too, resolves
/// inside the typed link's directory, and climbs out of it nowhere.
///
/// This is the whole file:// boundary, in one place. A hostile style must not
/// be able to make the shell read arbitrary local files as its "TileJSON".
pub fn insideLinkDir(link: []const u8, url: []const u8) bool {
    if (!isLocalPath(url)) return false;
    var lbuf: [4096]u8 = undefined;
    var ubuf: [4096]u8 = undefined;
    const lpath = localPath(&lbuf, link) orelse return false;
    const upath = localPath(&ubuf, url) orelse return false;
    if (has(upath, "..")) return false;
    const cut = std.mem.lastIndexOfScalar(u8, lpath, '/') orelse return false;
    const dir = lpath[0 .. cut + 1];
    if (dir.len == 0) return false;
    return std.mem.startsWith(u8, upath, dir);
}

/// A name for a link with nothing better: the file's stem for a path, the link
/// itself for a url.
fn defaultName(link: []const u8) []const u8 {
    if (!isLocalPath(link)) return link;
    const cut = std.mem.lastIndexOfScalar(u8, link, '/');
    const base = if (cut) |c| link[c + 1 ..] else link;
    if (base.len == 0) return link;
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return base;
    if (dot == 0) return base;
    return base[0..dot];
}

/// One JSON string literal, escaped. Control bytes go out as \u00xx.
fn jsonString(alloc: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    const hex = "0123456789abcdef";
    try out.append(alloc, '"');
    for (s) |c| switch (c) {
        '"' => try out.appendSlice(alloc, "\\\""),
        '\\' => try out.appendSlice(alloc, "\\\\"),
        '\n' => try out.appendSlice(alloc, "\\n"),
        '\r' => try out.appendSlice(alloc, "\\r"),
        '\t' => try out.appendSlice(alloc, "\\t"),
        else => if (c < 0x20) {
            try out.appendSlice(alloc, "\\u00");
            try out.append(alloc, hex[(c >> 4) & 0xf]);
            try out.append(alloc, hex[c & 0xf]);
        } else try out.append(alloc, c),
    };
    try out.append(alloc, '"');
}

// ---- tests -------------------------------------------------------------------
//
// The machine is fed canned answers and its outputs asserted: no network, no
// device, no renderer.

const testing = std.testing;

/// The whole outside world: a shell that records every url it is handed and
/// answers on demand, and a renderer that records what it was asked to draw.
const Fake = struct {
    alloc: std.mem.Allocator,
    links: Links = undefined,

    sent: std.ArrayList(Sent) = .empty,
    cancelled: std.ArrayList(u64) = .empty,
    /// When set, the shell answers inside http_get itself — what a shell
    /// reading a file:// url or refusing a malformed one naturally does.
    inline_body: ?[]const u8 = null,

    style: ?[]u8 = null,
    style_calls: usize = 0,
    /// Stand in for a style the core will not draw.
    refuse: bool = false,
    packs: std.ArrayList(SeenPack) = .empty,
    tiles: std.ArrayList(SeenTile) = .empty,

    const Sent = struct { id: u64, url: []u8, allow_file: bool, answered: bool = false };
    const SeenPack = struct { prefix: []u8, json: []u8, png: []u8 };
    const SeenTile = struct { req: u64, len: usize, status: TileStatus };

    fn open(alloc: std.mem.Allocator) !*Fake {
        const f = try alloc.create(Fake);
        f.* = .{ .alloc = alloc };
        f.links = Links.init(alloc, .{
            .ctx = f,
            .setStyle = setStyle,
            .spritePack = spritePack,
            .tileRespond = tileRespond,
        });
        f.links.setProvider(get, cancel, f);
        return f;
    }

    fn close(f: *Fake) void {
        f.links.deinit();
        for (f.sent.items) |s| f.alloc.free(s.url);
        f.sent.deinit(f.alloc);
        f.cancelled.deinit(f.alloc);
        for (f.packs.items) |p| {
            f.alloc.free(p.prefix);
            f.alloc.free(p.json);
            f.alloc.free(p.png);
        }
        f.packs.deinit(f.alloc);
        f.tiles.deinit(f.alloc);
        if (f.style) |s| f.alloc.free(s);
        const alloc = f.alloc;
        alloc.destroy(f);
    }

    fn get(user: ?*anyopaque, id: u64, url: [*:0]const u8, allow_file: c_int) callconv(.c) void {
        const f: *Fake = @ptrCast(@alignCast(user.?));
        const copy = f.alloc.dupe(u8, std.mem.span(url)) catch return;
        f.sent.append(f.alloc, .{ .id = id, .url = copy, .allow_file = allow_file != 0 }) catch {
            f.alloc.free(copy);
            return;
        };
        if (f.inline_body) |body| {
            f.sent.items[f.sent.items.len - 1].answered = true;
            f.links.respond(id, body, 200);
        }
    }

    fn cancel(user: ?*anyopaque, id: u64) callconv(.c) void {
        const f: *Fake = @ptrCast(@alignCast(user.?));
        f.cancelled.append(f.alloc, id) catch {};
    }

    fn setStyle(ctx: *anyopaque, json: ?[]const u8) bool {
        const f: *Fake = @ptrCast(@alignCast(ctx));
        f.style_calls += 1;
        if (f.style) |s| f.alloc.free(s);
        f.style = null;
        const j = json orelse return true;
        if (f.refuse) return false;
        f.style = f.alloc.dupe(u8, j) catch return false;
        return true;
    }

    fn spritePack(ctx: *anyopaque, prefix: []const u8, index_json: []const u8, png: []const u8) usize {
        const f: *Fake = @ptrCast(@alignCast(ctx));
        f.packs.append(f.alloc, .{
            .prefix = f.alloc.dupe(u8, prefix) catch return 0,
            .json = f.alloc.dupe(u8, index_json) catch return 0,
            .png = f.alloc.dupe(u8, png) catch return 0,
        }) catch return 0;
        return 1;
    }

    fn tileRespond(ctx: *anyopaque, req: u64, bytes: []const u8, status: TileStatus) void {
        const f: *Fake = @ptrCast(@alignCast(ctx));
        f.tiles.append(f.alloc, .{ .req = req, .len = bytes.len, .status = status }) catch {};
    }

    /// The first request whose url carries `needle` and has not been answered.
    fn waiting(f: *Fake, needle: []const u8) ?*Sent {
        for (f.sent.items) |*s| {
            if (!s.answered and has(s.url, needle)) return s;
        }
        return null;
    }

    /// Answer one request and let the frame loop take it.
    fn answer(f: *Fake, needle: []const u8, body: []const u8, status: c_int) !void {
        const s = f.waiting(needle) orelse return error.NothingAskedThat;
        s.answered = true;
        const id = s.id;
        f.links.respond(id, body, status);
        f.links.adopt();
    }

    /// Answer everything outstanding, the way a shell with several fetches in
    /// flight does.
    fn drainAll(f: *Fake, status: c_int) void {
        for (f.sent.items) |*s| {
            if (s.answered) continue;
            s.answered = true;
            f.links.respond(s.id, "", status);
        }
        f.links.adopt();
    }

    /// What allow_file the machine passed with the (first) url carrying `needle`.
    fn allowOf(f: *Fake, needle: []const u8) !bool {
        for (f.sent.items) |s| {
            if (has(s.url, needle)) return s.allow_file;
        }
        return error.NothingAskedThat;
    }

    fn asked(f: *Fake, needle: []const u8) bool {
        for (f.sent.items) |s| {
            if (has(s.url, needle)) return true;
        }
        return false;
    }

    /// The style the renderer was last given, parsed.
    fn drawn(f: *Fake) !std.json.Parsed(std.json.Value) {
        const s = f.style orelse return error.NoStyleDrawn;
        return std.json.parseFromSlice(std.json.Value, f.alloc, s, .{});
    }
};

/// A style whose one source names a TileJSON rather than its tiles.
const style_with_tilejson =
    \\{"version":8,"name":"Harbour",
    \\ "sources":{"base":{"type":"raster","url":"https://tiles.example/base.json"}},
    \\ "layers":[{"id":"b","type":"raster","source":"base"}]}
;

const tilejson_doc =
    \\{"tilejson":"2.2.0","name":"Base","tiles":["https://a.example/{z}/{x}/{y}.png"],
    \\ "minzoom":2,"maxzoom":17,"bounds":[-180,-85,180,85],"scheme":"tms",
    \\ "attribution":"<a href=\"https://osm.org\">&copy; OpenStreetMap</a>"}
;

test "chartlinks: a TileJSON source is inlined and its url dropped" {
    const f = try Fake.open(testing.allocator);
    defer f.close();

    f.links.add("https://tiles.example/style.json");
    try f.answer("style.json", style_with_tilejson, 200);
    try f.answer("base.json", tilejson_doc, 200);

    var drawn = try f.drawn();
    defer drawn.deinit();
    const src = drawn.value.object.get("sources").?.object.get("base").?;
    try testing.expect(src.object.get("url") == null);
    try testing.expectEqualStrings(
        "https://a.example/{z}/{x}/{y}.png",
        src.object.get("tiles").?.array.items[0].string,
    );
    try testing.expectEqual(@as(i64, 2), src.object.get("minzoom").?.integer);
    try testing.expectEqual(@as(i64, 17), src.object.get("maxzoom").?.integer);
    try testing.expectEqual(@as(usize, 4), src.object.get("bounds").?.array.items.len);
    try testing.expectEqualStrings("tms", src.object.get("scheme").?.string);
    try testing.expect(src.object.get("attribution") != null);
    // TileJSON says tileSize nowhere and a raster source is 256, not the
    // vector default: getting this wrong draws the imagery a zoom level off.
    try testing.expectEqual(@as(i64, 256), src.object.get("tileSize").?.integer);
}

test "chartlinks: a raster TileJSON with no style beside it gets a wrapper" {
    const f = try Fake.open(testing.allocator);
    defer f.close();

    f.links.add("https://tiles.example/base.json");
    try f.answer("base.json", tilejson_doc, 200);
    // The sibling probe: the publisher shipped none.
    try f.answer("style.json", "", 404);

    var drawn = try f.drawn();
    defer drawn.deinit();
    const layers = drawn.value.object.get("layers").?.array;
    try testing.expectEqual(@as(usize, 2), layers.items.len);
    try testing.expectEqualStrings("bg", layers.items[0].object.get("id").?.string);
    try testing.expectEqualStrings("raster", layers.items[1].object.get("type").?.string);
    const src = drawn.value.object.get("sources").?.object.get("tiles").?;
    try testing.expectEqualStrings("raster", src.object.get("type").?.string);
    try testing.expectEqualStrings("Base", drawn.value.object.get("name").?.string);
}

test "chartlinks: a vector TileJSON gets a layer trio per advertised layer" {
    const f = try Fake.open(testing.allocator);
    defer f.close();

    f.links.add("https://tiles.example/v.json");
    try f.answer("v.json",
        \\{"tilejson":"2.2.0","tiles":["https://a.example/{z}/{x}/{y}.pbf"],
        \\ "vector_layers":[{"id":"depare"},{"id":"buildings"}]}
    , 200);
    try f.answer("style.json", "", 404);

    var drawn = try f.drawn();
    defer drawn.deinit();
    const layers = drawn.value.object.get("layers").?.array;
    // background + three layers each for two advertised layers.
    try testing.expectEqual(@as(usize, 7), layers.items.len);
    try testing.expectEqualStrings("depare-fill", layers.items[1].object.get("id").?.string);
    try testing.expectEqualStrings("depare-line", layers.items[2].object.get("id").?.string);
    try testing.expectEqualStrings("depare-pt", layers.items[3].object.get("id").?.string);
    // The depth case is a hue of its own, not the generic table.
    try testing.expectEqualStrings(
        "hsla(205,60%,70%,0.5)",
        layers.items[1].object.get("paint").?.object.get("fill-color").?.string,
    );
    try testing.expectEqualStrings("Polygon", layers.items[1].object.get("filter").?.array.items[2].string);
    try testing.expectEqualStrings(
        "vector",
        drawn.value.object.get("sources").?.object.get("tiles").?.object.get("type").?.string,
    );
}

test "chartlinks: a style.json beside the tiles beats a generated wrapper" {
    const f = try Fake.open(testing.allocator);
    defer f.close();

    f.links.add("https://tiles.example/base.json");
    try f.answer("base.json", tilejson_doc, 200);
    try f.answer("style.json",
        \\{"version":8,"name":"Seascape","sources":{},"layers":[]}
    , 200);

    var drawn = try f.drawn();
    defer drawn.deinit();
    try testing.expectEqualStrings("Seascape", drawn.value.object.get("name").?.string);
    // The entry follows the sibling: that url IS the chart from here on.
    try testing.expectEqual(@as(usize, 1), f.links.entries.items.len);
    try testing.expectEqualStrings("https://tiles.example/style.json", f.links.entries.items[0].url);
    try testing.expectEqualStrings("Seascape", f.links.entries.items[0].name);
    try testing.expectEqualStrings("https://tiles.example/style.json", f.links.active.?);
}

test "chartlinks: sprite refs, in both forms and with a query string" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var one: std.ArrayList(Pack) = .empty;
    const string_form = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"sprite":"https://h/sprite?key=K"}
    , .{});
    try spriteRefs(a, string_form, &one);
    try testing.expectEqual(@as(usize, 1), one.items.len);
    try testing.expectEqualStrings("", one.items[0].prefix);

    // "…/sprite@2x.json?key=K", never "…?key=K@2x.json": an API-keyed host
    // 401s on the second.
    try testing.expectEqualStrings(
        "https://h/sprite@2x.json?key=K",
        try spriteVariant(a, one.items[0].base, "@2x", ".json"),
    );
    try testing.expectEqualStrings(
        "https://h/sprite.png?key=K",
        try spriteVariant(a, one.items[0].base, "", ".png"),
    );
    try testing.expectEqualStrings(
        "https://h/sprite@2x.png",
        try spriteVariant(a, "https://h/sprite", "@2x", ".png"),
    );

    var many: std.ArrayList(Pack) = .empty;
    const array_form = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"sprite":[{"id":"default","url":"https://h/base"},
        \\           {"id":"seamarks","url":"https://h/marks"},
        \\           {"id":"nourl"}]}
    , .{});
    try spriteRefs(a, array_form, &many);
    try testing.expectEqual(@as(usize, 2), many.items.len);
    // "default" resolves icons by bare name, so it carries no prefix.
    try testing.expectEqualStrings("", many.items[0].prefix);
    try testing.expectEqualStrings("seamarks", many.items[1].prefix);
}

test "chartlinks: sprite packs fetch @2x, fall back to 1x, and a dead pack is skipped" {
    const f = try Fake.open(testing.allocator);
    defer f.close();

    f.links.add("https://h/style.json");
    try f.answer("style.json",
        \\{"version":8,"sources":{},"layers":[],
        \\ "sprite":[{"id":"default","url":"https://h/base"},
        \\           {"id":"marks","url":"https://h/marks"}]}
    , 200);

    // The default pack has no @2x pair; the 1x one answers.
    try f.answer("base@2x.json", "", 404);
    try f.answer("base@2x.png", "", 404);
    try f.answer("base.json", "{\"icons\":1}", 200);
    try f.answer("base.png", "PNG1", 200);
    // The marks pack answers at @2x.
    try f.answer("marks@2x.json", "{\"icons\":2}", 200);
    try f.answer("marks@2x.png", "PNG2", 200);

    try testing.expectEqual(@as(usize, 2), f.packs.items.len);
    try testing.expectEqualStrings("", f.packs.items[0].prefix);
    try testing.expectEqualStrings("PNG1", f.packs.items[0].png);
    try testing.expectEqualStrings("marks", f.packs.items[1].prefix);
    try testing.expectEqualStrings("PNG2", f.packs.items[1].png);
    // The packs go AFTER the style: setting one clears the previous style's.
    try testing.expect(f.style != null);
}

test "chartlinks: a pack that will not fetch is skipped, not fatal" {
    const f = try Fake.open(testing.allocator);
    defer f.close();

    f.links.add("https://h/style.json");
    try f.answer("style.json",
        \\{"version":8,"sources":{},"layers":[],"sprite":"https://h/gone"}
    , 200);
    try f.answer("gone@2x.json", "", 404);
    try f.answer("gone@2x.png", "", 404);
    try f.answer("gone.json", "", 500);
    try f.answer("gone.png", "", 500);

    try testing.expectEqual(@as(usize, 0), f.packs.items.len);
    try testing.expect(f.style != null); // the chart draws, short its icons
}

test "chartlinks: the credit line drops a credit contained in another" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const style = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"sources":{
        \\  "a":{"attribution":"<a href=\"x\">&copy; OpenStreetMap</a>"},
        \\  "b":{"attribution":"&copy; OpenStreetMap &amp; &copy; Open Waters"},
        \\  "c":{"attribution":"&copy; Open Waters"},
        \\  "d":{"attribution":"  "}}}
    , .{});
    // b contains both of the others, so only b survives; the markup is gone
    // and the entities are decoded.
    try testing.expectEqualStrings(
        "\u{00A9} OpenStreetMap & \u{00A9} Open Waters",
        try creditLine(a, style),
    );
}

test "chartlinks: exact duplicate credits are joined once" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const style = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"sources":{"a":{"attribution":"&copy; A"},
        \\            "b":{"attribution":"&copy; A"},
        \\            "c":{"attribution":"&copy; B"}}}
    , .{});
    try testing.expectEqualStrings("\u{00A9} A \u{00B7} \u{00A9} B", try creditLine(a, style));
}

test "chartlinks: a tile url is templated, y-flipped for TMS, and picked deterministically" {
    const f = try Fake.open(testing.allocator);
    defer f.close();

    f.links.add("https://h/style.json");
    try f.answer("style.json",
        \\{"version":8,"layers":[],"sources":{
        \\  "north":{"type":"raster","tiles":["https://a/{z}/{x}/{y}.png","https://b/{z}/{x}/{y}.png"]},
        \\  "south":{"type":"raster","scheme":"TMS","tiles":["https://c/{z}/{x}/{y}.png"]}}}
    , 200);

    const a = testing.allocator;
    const even = f.links.tileUrl("north", 4, 3, 5).?; // 3+5 == 8, even -> first
    defer a.free(even);
    try testing.expectEqualStrings("https://a/4/3/5.png", even);
    const odd = f.links.tileUrl("north", 4, 3, 6).?; // 9, odd -> second
    defer a.free(odd);
    try testing.expectEqualStrings("https://b/4/3/6.png", odd);
    // TMS counts y from the south: 2^4 - 1 - 5 == 10.
    const tms = f.links.tileUrl("south", 4, 3, 5).?;
    defer a.free(tms);
    try testing.expectEqualStrings("https://c/4/3/10.png", tms);
    // A source the style does not name has nowhere to come from.
    try testing.expect(f.links.tileUrl("nobody", 4, 3, 5) == null);
}

test "chartlinks: a tile is fetched through the same door and answered back" {
    const f = try Fake.open(testing.allocator);
    defer f.close();

    f.links.add("https://h/style.json");
    try f.answer("style.json",
        \\{"version":8,"layers":[],
        \\ "sources":{"base":{"type":"raster","tiles":["https://a/{z}/{x}/{y}.png"]}}}
    , 200);

    f.links.askTile("base", 77, 4, 3, 5);
    try testing.expect(f.asked("https://a/4/3/5.png"));
    // Tiles never reach the disk, whatever the style said.
    try testing.expectEqual(false, try f.allowOf("https://a/4/3/5.png"));

    try f.answer("4/3/5.png", "TILEBYTES", 200);
    try testing.expectEqual(@as(usize, 1), f.tiles.items.len);
    try testing.expectEqual(@as(u64, 77), f.tiles.items[0].req);
    try testing.expectEqual(TileStatus.ok, f.tiles.items[0].status);
    try testing.expectEqual(@as(usize, 9), f.tiles.items[0].len);

    // A 404 is "no tile there" and is remembered as one, so it is not re-asked
    // every frame; a 500 is a fault.
    f.links.askTile("base", 78, 4, 4, 5);
    try f.answer("4/4/5.png", "", 404);
    try testing.expectEqual(TileStatus.empty, f.tiles.items[1].status);
    f.links.askTile("base", 79, 4, 5, 5);
    try f.answer("4/5/5.png", "", 500);
    try testing.expectEqual(TileStatus.failed, f.tiles.items[2].status);

    // A tile for a source with no template is ANSWERED, not dropped: a tile
    // nobody answers is a hole in the chart that never fills.
    f.links.askTile("nobody", 80, 4, 3, 5);
    try testing.expectEqual(TileStatus.failed, f.tiles.items[3].status);
}

test "chartlinks: a second add mid-resolve wins, and the first is cancelled" {
    const f = try Fake.open(testing.allocator);
    defer f.close();

    f.links.add("https://one.example/style.json");
    const first = f.waiting("one.example").?.id;
    try testing.expectEqual(@as(usize, 1), f.links.resolve_inflight);

    // The mariner picks a second chart while the first is still fetching.
    f.links.add("https://two.example/style.json");
    try testing.expectEqual(@as(usize, 1), f.cancelled.items.len);
    try testing.expectEqual(first, f.cancelled.items[0]);
    // The superseded epoch's slot is released at once, not when it answers.
    try testing.expectEqual(@as(usize, 1), f.links.resolve_inflight);

    // The old answer still lands. It must not draw over the new pick.
    f.links.respond(first, "{\"version\":8,\"name\":\"One\",\"sources\":{},\"layers\":[]}", 200);
    f.links.adopt();
    try testing.expect(f.style == null);

    try f.answer("two.example", "{\"version\":8,\"name\":\"Two\",\"sources\":{},\"layers\":[]}", 200);
    var drawn = try f.drawn();
    defer drawn.deinit();
    try testing.expectEqualStrings("Two", drawn.value.object.get("name").?.string);
    try testing.expectEqual(@as(usize, 1), f.links.entries.items.len);
}

test "chartlinks: a cancelled request stops holding its budget slot" {
    const f = try Fake.open(testing.allocator);
    defer f.close();

    f.links.add("https://one.example/style.json");
    try testing.expectEqual(@as(usize, 1), f.links.resolve_inflight);
    // Nobody ever answers it; the mariner goes back to lookout's own chart.
    f.links.select(null);
    try testing.expectEqual(@as(usize, 0), f.links.resolve_inflight);
    try testing.expectEqual(@as(usize, 0), f.links.reqs.items.len);

    // The machine still works: the slot was freed, not leaked.
    f.links.add("https://two.example/style.json");
    try testing.expectEqual(@as(usize, 1), f.links.resolve_inflight);
}

test "chartlinks: a resolve fetch is never queued behind a full tile budget" {
    const f = try Fake.open(testing.allocator);
    defer f.close();

    f.links.add("https://h/style.json");
    try f.answer("style.json",
        \\{"version":8,"layers":[],
        \\ "sources":{"base":{"type":"raster","tiles":["https://a/{z}/{x}/{y}.png"]}}}
    , 200);

    // Fill the tile budget and overflow it.
    for (0..MAX_TILE_INFLIGHT + 5) |i| f.links.askTile("base", 1000 + i, 6, @intCast(i), 1);
    try testing.expectEqual(MAX_TILE_INFLIGHT, f.links.tiles_inflight);
    try testing.expectEqual(@as(usize, 5), f.links.tile_queue.items.len);

    // The mariner adds a chart. Its style must go out at once, not wait for a
    // tile budget a fresh zoom level has filled.
    f.links.add("https://other.example/style.json");
    try testing.expect(f.asked("other.example"));
    try testing.expectEqual(@as(usize, 1), f.links.resolve_inflight);

    // A queued tile takes the first slot that frees.
    try f.answer("https://a/6/0/1.png", "T", 200);
    try testing.expectEqual(@as(usize, 4), f.links.tile_queue.items.len);
    try testing.expectEqual(MAX_TILE_INFLIGHT, f.links.tiles_inflight);
}

test "chartlinks: allow_file is 1 for a local link and for what its own document names" {
    const f = try Fake.open(testing.allocator);
    defer f.close();

    f.links.add("/Users/mariner/charts/style.json");
    try testing.expectEqual(true, try f.allowOf("/Users/mariner/charts/style.json"));
    try f.answer("style.json",
        \\{"version":8,"sources":{
        \\  "near":{"type":"vector","url":"/Users/mariner/charts/tiles.json"},
        \\  "away":{"type":"vector","url":"/etc/passwd"},
        \\  "up":{"type":"vector","url":"/Users/mariner/charts/../../../etc/shadow"},
        \\  "web":{"type":"vector","url":"https://tiles.example/t.json"}},
        \\ "layers":[],"sprite":"/Users/mariner/charts/sprite"}
    , 200);

    // Inside the typed link's directory: the shell may read it.
    try testing.expectEqual(true, try f.allowOf("/Users/mariner/charts/tiles.json"));
    // Outside it, climbing out of it, or over the network: it may not.
    try testing.expectEqual(false, try f.allowOf("/etc/passwd"));
    try testing.expectEqual(false, try f.allowOf("/etc/shadow"));
    try testing.expectEqual(false, try f.allowOf("https://tiles.example/t.json"));

    f.drainAll(404);
    // A sprite named by a local document, inside its directory: readable.
    try testing.expectEqual(true, try f.allowOf("/Users/mariner/charts/sprite@2x.json"));
}

test "chartlinks: nothing a network style names may reach the disk" {
    const f = try Fake.open(testing.allocator);
    defer f.close();

    f.links.add("https://hostile.example/style.json");
    try f.answer("style.json",
        \\{"version":8,"sources":{"x":{"type":"vector","url":"/etc/passwd"}},
        \\ "layers":[],"sprite":"/etc/sprite"}
    , 200);
    try testing.expectEqual(false, try f.allowOf("/etc/passwd"));
    try f.answer("/etc/passwd", "", 404);
    try testing.expectEqual(false, try f.allowOf("/etc/sprite@2x.json"));
}

test "chartlinks: an offline resolve keeps the mariner's selection" {
    const f = try Fake.open(testing.allocator);
    defer f.close();

    f.links.add("https://h/style.json");
    try f.answer("style.json", "{\"version\":8,\"sources\":{},\"layers\":[]}", 200);
    try testing.expect(f.style != null);

    // Later, out at sea, the same chart will not load.
    f.links.refresh("https://h/style.json");
    try f.answer("style.json", "", 0);

    // The pick stands so the next open retries; lookout's own chart stands in
    // behind it and the credit does not claim the publisher.
    try testing.expectEqualStrings("https://h/style.json", f.links.active.?);
    try testing.expect(f.style == null);
    try testing.expectEqual(@as(usize, 0), f.links.attribution.len);
    try testing.expect(f.links.err.len != 0);
}

test "chartlinks: a style the core refuses drops the pick and the credit" {
    const f = try Fake.open(testing.allocator);
    defer f.close();

    f.refuse = true;
    f.links.add("https://h/style.json");
    try f.answer("style.json",
        \\{"version":8,"sources":{"a":{"type":"raster","tiles":["https://a/{z}/{x}/{y}.png"],
        \\ "attribution":"&copy; Somebody"}},"layers":[]}
    , 200);

    try testing.expect(f.links.active == null);
    try testing.expectEqual(@as(usize, 0), f.links.attribution.len);
    try testing.expect(f.links.err.len != 0);
    try testing.expect(f.style == null);
}

test "chartlinks: a link with nothing chart-like behind it is an error, not a chart" {
    const f = try Fake.open(testing.allocator);
    defer f.close();

    f.links.add("https://h/readme.txt");
    try f.answer("readme.txt", "{\"hello\":\"world\"}", 200);
    try testing.expectEqualStrings("No chart style or tile source at that link.", f.links.err);
    try testing.expectEqual(@as(usize, 0), f.links.entries.items.len);
    try testing.expect(f.links.active == null);
}

test "chartlinks: an answer given inside http_get is not lost and does not deadlock" {
    const f = try Fake.open(testing.allocator);
    defer f.close();

    // A shell reading a file:// url has the bytes already and will answer
    // before returning. respond only enqueues, so that is safe.
    f.inline_body = "{\"version\":8,\"name\":\"Local\",\"sources\":{},\"layers\":[]}";
    f.links.add("/Users/mariner/charts/style.json");
    // Nothing has been adopted yet, but the answer is waiting and the frame
    // loop has been told to run.
    try testing.expect(f.links.pending());
    try testing.expect(f.style == null);

    f.links.adopt();
    try testing.expect(!f.links.pending());
    var drawn = try f.drawn();
    defer drawn.deinit();
    try testing.expectEqualStrings("Local", drawn.value.object.get("name").?.string);
}

test "chartlinks: a local link keeps the text that worked" {
    const f = try Fake.open(testing.allocator);
    defer f.close();

    const doc = "{\"version\":8,\"name\":\"Bay\",\"sources\":{},\"layers\":[]}";
    f.links.add("/Users/mariner/charts/bay.json");
    try f.answer("bay.json", doc, 200);
    try testing.expectEqualStrings("Bay", f.links.entries.items[0].name);
    try testing.expectEqualStrings(doc, f.links.entries.items[0].doc.?);

    // Selecting it again draws the kept text without going back to the path.
    const before = f.sent.items.len;
    f.links.select(null);
    f.links.select("/Users/mariner/charts/bay.json");
    try testing.expectEqual(before, f.sent.items.len);
    try testing.expect(f.style != null);

    // A refresh DOES re-read the path, and when the read fails the kept text
    // stands: a stick pulled out must not lose the mariner the chart.
    f.links.refresh("/Users/mariner/charts/bay.json");
    try f.answer("bay.json", "", 0);
    try testing.expect(f.style != null);
    try testing.expect(f.links.err.len != 0);
    try testing.expectEqualStrings("/Users/mariner/charts/bay.json", f.links.active.?);
}

test "chartlinks: the snapshot is what the UI renders, and the changed flag has one consumer" {
    const f = try Fake.open(testing.allocator);
    defer f.close();

    f.links.add("https://h/style.json");
    try f.answer("style.json",
        \\{"version":8,"name":"Harbour","layers":[],
        \\ "sources":{"a":{"type":"raster","tiles":["https://a/{z}/{x}/{y}.png"],
        \\  "attribution":"&copy; Somebody"}}}
    , 200);

    const snap = f.links.snapshotAlloc(testing.allocator).?;
    defer testing.allocator.free(snap);
    try testing.expectEqualStrings(
        "{\"links\":[{\"url\":\"https://h/style.json\",\"name\":\"Harbour\"}]," ++
            "\"active\":\"https://h/style.json\"," ++
            "\"attribution\":\"\u{00A9} Somebody\",\"error\":\"\",\"busy\":false}",
        snap,
    );
    try testing.expect(f.links.takeChanged());
    try testing.expect(!f.links.takeChanged());

    f.links.remove("https://h/style.json");
    try testing.expect(f.links.takeChanged());
    try testing.expectEqual(@as(usize, 0), f.links.entries.items.len);
    try testing.expect(f.links.active == null);
    try testing.expect(f.style == null);
}

test "chartlinks: import adopts a shell's old store once and then stands aside" {
    const f = try Fake.open(testing.allocator);
    defer f.close();

    f.links.import(
        \\{"links":[{"url":"https://a/style.json","name":"A"},
        \\          {"url":"https://b/style.json","name":"B"}],
        \\ "active":"https://b/style.json"}
    );
    try testing.expectEqual(@as(usize, 2), f.links.entries.items.len);
    try testing.expectEqualStrings("https://b/style.json", f.links.active.?);
    // The chart the old store had selected is drawn at once: the import lands
    // after the fetcher was set, so nothing else would go and get it.
    try f.answer("https://b/style.json", "{\"version\":8,\"sources\":{},\"layers\":[]}", 200);
    try testing.expect(f.style != null);

    // Replayed after a crash between the import and the shell deleting its
    // store: a no-op, because the core has a list of its own now.
    f.links.import("{\"links\":[{\"url\":\"https://c/style.json\",\"name\":\"C\"}]}");
    try testing.expectEqual(@as(usize, 2), f.links.entries.items.len);

    // The bare-array form a shell may have stored instead, and the style TEXT
    // it kept for a local link — which the path may no longer answer with.
    const g = try Fake.open(testing.allocator);
    defer g.close();
    g.links.import(
        \\[{"url":"https://a/style.json"},
        \\ {"url":"/Users/mariner/bay.json","name":"Bay","doc":"{\"version\":8,\"sources\":{},\"layers\":[]}"},
        \\ {"url":"https://b/tiles.json","name":"B","doc":"{\"version\":8,\"sources\":{},\"layers\":[]}"}]
    );
    try testing.expectEqual(@as(usize, 3), g.links.entries.items.len);
    try testing.expectEqualStrings("https://a/style.json", g.links.entries.items[0].name);
    // The local link's text came across; the network link's generated wrapper
    // did not, because that one is re-resolved from its url.
    try testing.expect(g.links.entries.items[1].doc != null);
    try testing.expect(g.links.entries.items[2].doc == null);

    // The kept text draws with no fetch at all.
    g.links.select("/Users/mariner/bay.json");
    try testing.expectEqual(@as(usize, 0), g.sent.items.len);
    try testing.expect(g.style != null);
}

test "chartlinks: the list survives a restart" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer testing.allocator.free(dir);

    {
        const f = try Fake.open(testing.allocator);
        defer f.close();
        f.links.openStore(dir);
        f.links.add("/Users/mariner/charts/bay.json");
        try f.answer("bay.json", "{\"version\":8,\"name\":\"Bay\",\"sources\":{},\"layers\":[]}", 200);
    }
    {
        const f = try Fake.open(testing.allocator);
        defer f.close();
        // The store is read before the shell sets a fetcher, and the fetcher
        // arriving is what resolves the selection.
        f.links.openStore(dir);
        try testing.expectEqual(@as(usize, 1), f.links.entries.items.len);
        try testing.expectEqualStrings("Bay", f.links.entries.items[0].name);
        try testing.expectEqualStrings("/Users/mariner/charts/bay.json", f.links.active.?);
        // The kept style text came back with it, so the chart draws with no
        // fetch at all.
        f.links.setProvider(Fake.get, Fake.cancel, f);
        try testing.expectEqual(@as(usize, 0), f.sent.items.len);
        try testing.expect(f.style != null);
    }
}

test "chartlinks: with no fetcher a tile is failed rather than parked forever" {
    const f = try Fake.open(testing.allocator);
    defer f.close();

    f.links.add("https://h/style.json");
    try f.answer("style.json",
        \\{"version":8,"layers":[],
        \\ "sources":{"base":{"type":"raster","tiles":["https://a/{z}/{x}/{y}.png"]}}}
    , 200);
    f.links.setProvider(null, null, null);

    f.links.askTile("base", 5, 4, 3, 5);
    try testing.expectEqual(@as(usize, 1), f.tiles.items.len);
    try testing.expectEqual(TileStatus.failed, f.tiles.items[0].status);
}

test "chartlinks: a local path is told from a url" {
    try testing.expect(isLocalPath("/Users/mariner/charts/style.json"));
    try testing.expect(isLocalPath("file:///Users/mariner/style.json"));
    try testing.expect(isLocalPath("./style.json"));
    try testing.expect(isLocalPath("C:\\charts\\style.json"));
    try testing.expect(!isLocalPath("https://h/style.json"));
    try testing.expect(!isLocalPath("http://h/style.json"));
    try testing.expect(!isLocalPath("style.json"));

    const link = "/Users/mariner/charts/style.json";
    try testing.expect(insideLinkDir(link, "/Users/mariner/charts/tiles.json"));
    try testing.expect(insideLinkDir(link, "file:///Users/mariner/charts/deep/tiles.json"));
    // Percent escapes are decoded before the check, or "%2e%2e" walks out.
    try testing.expect(!insideLinkDir(link, "file:///Users/mariner/charts/%2e%2e/other/t.json"));
    try testing.expect(!insideLinkDir(link, "/Users/mariner/other/tiles.json"));
    try testing.expect(!insideLinkDir(link, "https://h/tiles.json"));
    try testing.expect(!insideLinkDir("https://h/style.json", "/etc/passwd"));
}

test "chartlinks: the typed read says what the snapshot says" {
    const f = try Fake.open(testing.allocator);
    defer f.close();

    f.links.add("https://h/style.json");
    try f.answer("style.json",
        \\{"version":8,"name":"Harbour","layers":[],
        \\ "sources":{"a":{"type":"raster","tiles":["https://a/{z}/{x}/{y}.png"],
        \\  "attribution":"&copy; Somebody"}}}
    , 200);
    f.links.add("https://b/style.json");
    try f.answer("style.json", "{\"version\":8,\"name\":\"Bay\",\"layers\":[]}", 200);

    const snap = f.links.snapshotAlloc(testing.allocator).?;
    defer testing.allocator.free(snap);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const doc = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), snap, .{});
    const o = doc.object;

    const r = try f.links.read(testing.allocator);
    defer r.free();

    const list = o.get("links").?.array;
    try testing.expectEqual(list.items.len, r.links.len);
    for (list.items, r.links) |item, got| {
        try testing.expectEqualStrings(item.object.get("url").?.string, std.mem.span(got.url));
        try testing.expectEqualStrings(item.object.get("name").?.string, std.mem.span(got.name));
    }
    // The JSON writes null for lookout's own chart; the read writes an empty
    // string, because a url is never empty.
    const active = o.get("active").?;
    try testing.expectEqualStrings(
        if (active == .string) active.string else "",
        std.mem.span(r.state.active),
    );
    try testing.expectEqualStrings(o.get("attribution").?.string, std.mem.span(r.state.attribution));
    try testing.expectEqualStrings(o.get("error").?.string, std.mem.span(r.state.err));
    try testing.expectEqual(o.get("busy").?.bool, r.state.busy != 0);
}

test "chartlinks: lookout's own chart reads as an empty active url" {
    const f = try Fake.open(testing.allocator);
    defer f.close();

    const r = try f.links.read(testing.allocator);
    defer r.free();
    try testing.expectEqual(@as(usize, 0), r.links.len);
    try testing.expectEqualStrings("", std.mem.span(r.state.active));
    try testing.expectEqualStrings("", std.mem.span(r.state.attribution));
    try testing.expectEqualStrings("", std.mem.span(r.state.err));
    try testing.expectEqual(@as(c_int, 0), r.state.busy);
}
