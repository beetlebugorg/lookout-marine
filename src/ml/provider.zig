//! Serves `lookout://` resources to MapLibre out of tile57.
//!
//! WHY THIS EXISTS. MapLibre points a source at ONE url. Lookout does not have
//! one archive: it opens a folder of per-chart `.pmtiles` and composes them at
//! runtime through `tile57_compose`, resolving band handoff and ownership per
//! tile. There is no merged archive to point at.
//!
//! The evaluation that preceded this branch called that a blocker and proposed
//! contributing an `addProtocol` equivalent to MapLibre Native. That was wrong:
//! `mln_runtime_set_resource_provider` already exists and is exactly the hook.
//! This file is the provider. The compositor stays, the incremental per-chart
//! bake stays, and nothing has to be merged.
//!
//! THE SCHEME
//!
//!   lookout://tile/{z}/{x}/{y}          composed vector tile (MLT or MVT)
//!   lookout://sprite.json               MapLibre sprite index, current scheme
//!   lookout://sprite.png                 the sheet the index addresses
//!   lookout://sprite@2x.json|png        the same at a second density
//!   lookout://glyphs/{stack}/{a}-{b}.pbf  SDF glyph range for a fontstack
//!
//! THREADING. MapLibre calls `handle` on a worker or network thread and states
//! the callback must return promptly and must not re-enter the map or runtime.
//! A composed tile is far too slow to serve inline — it reads archives and
//! stitches faces — so the callback only takes the request handle and queues it.
//! One worker owns the tile57 handles and completes each request off-thread.
//! That also satisfies tile57, whose handles are not internally synchronized:
//! exactly one thread ever touches them.
//!
//! CANCELLATION. MapLibre cancels tiles constantly while a view moves. The
//! worker asks `handle.cancelled()` before doing the work, so a queue that has
//! fallen behind a pan discards instead of composing tiles nobody wants.

const std = @import("std");
const cc = @import("cabi").c;
const t57 = @import("tile57");
const maplibre = @import("maplibre_native_ffi");

const glyphpbf = t57.sprite.glyphpbf;

pub const scheme = "lookout://";

/// What a parsed `lookout://` url asks for.
const Ask = union(enum) {
    tile: struct { z: u8, x: u32, y: u32 },
    sprite_json: struct { pixel_ratio: u8 },
    sprite_png: struct { pixel_ratio: u8 },
    glyphs: struct { stack: []const u8, start: u21 },
};

/// A request the callback accepted and the worker still owes a response for.
const Job = struct {
    handle: maplibre.ResourceRequestHandle,
    ask: Ask,
    /// Owns `ask.glyphs.stack` when the ask carries one; freed with the job.
    stack_buf: ?[]u8 = null,
};

pub const Provider = struct {
    alloc: std.mem.Allocator,

    /// The compositor over the open library. Borrowed: root.zig owns it and
    /// must not close it while this provider runs. Null while a compose is
    /// being rebuilt, which serves tiles as 404 rather than blocking.
    compose: ?*cc.tile57_compose = null,
    /// Single chart shortcut: when the library holds exactly one chart there is
    /// no compositor and tiles come straight off the archive.
    chart: ?*cc.tile57_chart = null,
    /// Guards `compose`/`chart` against a swap while the worker reads them.
    src_lock: std.Thread.Mutex = .{},

    /// Baked once per (scheme, density) and handed out for the process life.
    sprite_cache: std.ArrayList(SpriteEntry) = .empty,
    sprite_lock: std.Thread.Mutex = .{},
    scheme_now: cc.tile57_scheme = cc.TILE57_SCHEME_DAY,
    catalog_dir: ?[:0]const u8 = null,

    /// Glyph ranges are small and re-requested constantly; cache them forever.
    glyph_cache: std.StringHashMapUnmanaged([]u8) = .empty,
    glyph_lock: std.Thread.Mutex = .{},

    queue: std.ArrayList(Job) = .empty,
    queue_lock: std.Thread.Mutex = .{},
    queue_wake: std.Thread.Condition = .{},
    worker: ?std.Thread = null,
    stopping: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    const SpriteEntry = struct {
        pixel_ratio: u8,
        scheme: cc.tile57_scheme,
        json: []u8,
        png: []u8,
    };

    pub fn init(alloc: std.mem.Allocator) Provider {
        return .{ .alloc = alloc };
    }

    pub fn start(self: *Provider) !void {
        if (self.worker != null) return;
        self.stopping.store(false, .release);
        self.worker = try std.Thread.spawn(.{}, run, .{self});
    }

    pub fn deinit(self: *Provider) void {
        self.stopping.store(true, .release);
        self.queue_lock.lock();
        self.queue_wake.broadcast();
        self.queue_lock.unlock();
        if (self.worker) |w| w.join();
        self.worker = null;

        // Anything still queued was never completed. Release each handle so
        // MapLibre stops waiting on it.
        for (self.queue.items) |*job| {
            job.handle.release();
            if (job.stack_buf) |b| self.alloc.free(b);
        }
        self.queue.deinit(self.alloc);

        for (self.sprite_cache.items) |e| {
            self.alloc.free(e.json);
            self.alloc.free(e.png);
        }
        self.sprite_cache.deinit(self.alloc);

        var it = self.glyph_cache.iterator();
        while (it.next()) |kv| {
            self.alloc.free(kv.key_ptr.*);
            self.alloc.free(kv.value_ptr.*);
        }
        self.glyph_cache.deinit(self.alloc);

        if (self.catalog_dir) |d| self.alloc.free(d);
    }

    /// Point the provider at the open library. Called from the api thread with
    /// the compositor root.zig just built; the worker picks it up on its next
    /// job. Passing null (mid-rebuild) makes tiles 404 until the next set.
    pub fn setSource(self: *Provider, compose: ?*cc.tile57_compose, chart: ?*cc.tile57_chart) void {
        self.src_lock.lock();
        defer self.src_lock.unlock();
        self.compose = compose;
        self.chart = chart;
    }

    pub fn setScheme(self: *Provider, s: cc.tile57_scheme) void {
        self.sprite_lock.lock();
        defer self.sprite_lock.unlock();
        self.scheme_now = s;
    }

    pub fn setCatalogDir(self: *Provider, dir: ?[]const u8) !void {
        self.sprite_lock.lock();
        defer self.sprite_lock.unlock();
        if (self.catalog_dir) |d| self.alloc.free(d);
        self.catalog_dir = if (dir) |d| try self.alloc.dupeZ(u8, d) else null;
    }

    // ---- the MapLibre-facing callback ------------------------------------

    /// `maplibre.ResourceProvider.handler`. Runs on a MapLibre thread: parse,
    /// queue, return. No tile57 call happens here.
    pub fn handler(
        ctx: ?*anyopaque,
        request: maplibre.ResourceRequest,
        handle: ?maplibre.ResourceRequestHandle,
    ) maplibre.ResourceProviderDecision {
        const self: *Provider = @ptrCast(@alignCast(ctx orelse return .pass_through));
        const h = handle orelse return .pass_through;

        // Everything that is not ours goes to MapLibre's own file source, so a
        // style that also names an http basemap still works.
        if (!std.mem.startsWith(u8, request.resolved_url, scheme)) return .pass_through;

        const ask = parse(request.resolved_url[scheme.len..]) orelse {
            complete404(h);
            return .handle;
        };

        var job = Job{ .handle = h, .ask = ask };
        if (ask == .glyphs) {
            // The url is borrowed for the callback only; the worker needs its
            // own copy of the fontstack name.
            const buf = self.alloc.dupe(u8, ask.glyphs.stack) catch {
                complete404(h);
                return .handle;
            };
            job.stack_buf = buf;
            job.ask = .{ .glyphs = .{ .stack = buf, .start = ask.glyphs.start } };
        }

        self.queue_lock.lock();
        defer self.queue_lock.unlock();
        self.queue.append(self.alloc, job) catch {
            if (job.stack_buf) |b| self.alloc.free(b);
            complete404(h);
            return .handle;
        };
        self.queue_wake.signal();
        return .handle;
    }

    fn complete404(h: maplibre.ResourceRequestHandle) void {
        h.complete(.{ .status = .not_found }) catch {};
        h.release();
    }

    // ---- the worker ------------------------------------------------------

    fn run(self: *Provider) void {
        while (true) {
            self.queue_lock.lock();
            while (self.queue.items.len == 0) {
                if (self.stopping.load(.acquire)) {
                    self.queue_lock.unlock();
                    return;
                }
                self.queue_wake.wait(&self.queue_lock);
            }
            const job = self.queue.orderedRemove(0);
            self.queue_lock.unlock();

            self.serve(job);
            if (job.stack_buf) |b| self.alloc.free(b);
        }
    }

    fn serve(self: *Provider, job: Job) void {
        defer job.handle.release();

        // A pan queues far more tiles than it keeps. Drop the ones MapLibre has
        // already given up on before paying to compose them.
        if (job.handle.cancelled() catch false) return;

        const bytes: ?[]const u8 = switch (job.ask) {
            .tile => |t| self.composeTile(t.z, t.x, t.y),
            .sprite_json => |s| self.sprite(s.pixel_ratio, .json),
            .sprite_png => |s| self.sprite(s.pixel_ratio, .png),
            .glyphs => |g| self.glyphRange(g.stack, g.start),
        };

        if (bytes) |b| {
            job.handle.complete(.{ .status = .ok, .bytes = b }) catch {};
        } else {
            // "Nothing here" is not an error for a chart library: most of the
            // world has no cell. A 404 tells MapLibre to stop asking rather
            // than to retry.
            job.handle.complete(.{ .status = .not_found }) catch {};
        }

        // A composed tile is freshly allocated per request; sprite and glyph
        // bytes are cached and outlive the job.
        if (job.ask == .tile) if (bytes) |b| cc.tile57_free(@constCast(b.ptr));
    }

    fn composeTile(self: *Provider, z: u8, x: u32, y: u32) ?[]const u8 {
        self.src_lock.lock();
        const compose = self.compose;
        const chart = self.chart;
        self.src_lock.unlock();

        var out: [*c]u8 = null;
        var out_len: usize = 0;
        var owned: bool = false;
        var err: cc.tile57_error = undefined;

        const st = if (compose) |c|
            cc.tile57_compose_tile(c, z, x, y, &out, &out_len, &owned, &err)
        else if (chart) |ch|
            cc.tile57_chart_tile(ch, z, x, y, &out, &out_len, &err)
        else
            return null;

        if (st != cc.TILE57_OK) return null;
        if (out == null or out_len == 0) return null; // no ground here
        return out[0..out_len];
    }

    const SpriteKind = enum { json, png };

    fn sprite(self: *Provider, pixel_ratio: u8, kind: SpriteKind) ?[]const u8 {
        self.sprite_lock.lock();
        defer self.sprite_lock.unlock();

        for (self.sprite_cache.items) |e| {
            if (e.pixel_ratio == pixel_ratio and e.scheme == self.scheme_now)
                return if (kind == .json) e.json else e.png;
        }

        var assets: cc.tile57_assets = std.mem.zeroes(cc.tile57_assets);
        var err: cc.tile57_error = undefined;
        const dir: [*c]const u8 = if (self.catalog_dir) |d| d.ptr else null;
        const st = cc.tile57_bake_sprite_mln(
            dir,
            @floatFromInt(pixel_ratio),
            self.scheme_now,
            &assets,
            &err,
        );
        if (st != cc.TILE57_OK) return null;
        defer cc.tile57_assets_free(&assets);

        const json = self.alloc.dupe(u8, assets.sprite_json[0..assets.sprite_json_len]) catch return null;
        const png = self.alloc.dupe(u8, assets.sprite_png[0..assets.sprite_png_len]) catch {
            self.alloc.free(json);
            return null;
        };
        self.sprite_cache.append(self.alloc, .{
            .pixel_ratio = pixel_ratio,
            .scheme = self.scheme_now,
            .json = json,
            .png = png,
        }) catch {
            self.alloc.free(json);
            self.alloc.free(png);
            return null;
        };
        return if (kind == .json) json else png;
    }

    /// tile57 can encode a MapLibre glyph range but does NOT expose it on the C
    /// ABI (only the GPU path's SDF atlas, which is a different format). We
    /// reach it as a Zig module instead. See specs/maplibre/concerns.md C2.
    fn glyphRange(self: *Provider, stack: []const u8, first_cp: u21) ?[]const u8 {
        var key_buf: [96]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "{s}/{d}", .{ stack, first_cp }) catch return null;

        self.glyph_lock.lock();
        defer self.glyph_lock.unlock();
        if (self.glyph_cache.get(key)) |v| return v;

        const face = faceFor(stack);
        const bytes = glyphpbf.encodeRange(self.alloc, face, stack, first_cp) catch return null;
        const owned_key = self.alloc.dupe(u8, key) catch {
            self.alloc.free(bytes);
            return null;
        };
        self.glyph_cache.put(self.alloc, owned_key, bytes) catch {
            self.alloc.free(owned_key);
            self.alloc.free(bytes);
            return null;
        };
        return bytes;
    }

    /// The style names three fontstacks for the label tiers (bold for populated
    /// places, italic for hydrography, regular otherwise). Return the embedded
    /// TrueType bytes for each — `encodeRange` shapes from the face itself, not
    /// from a face name.
    fn faceFor(stack: []const u8) []const u8 {
        const font = t57.render.font;
        if (std.mem.indexOf(u8, stack, "Bold") != null) return font.notosans_bold;
        if (std.mem.indexOf(u8, stack, "Italic") != null) return font.notosans_italic;
        return font.notosans;
    }
};

// ---- url parsing ---------------------------------------------------------

/// Parse the part after `lookout://`. Returns null for anything unrecognised,
/// which the caller answers 404 rather than passing through — a malformed
/// lookout url is our bug, not something MapLibre's http source should see.
fn parse(path: []const u8) ?Ask {
    if (std.mem.startsWith(u8, path, "tile/")) {
        var it = std.mem.splitScalar(u8, path["tile/".len..], '/');
        const z = std.fmt.parseInt(u8, it.next() orelse return null, 10) catch return null;
        const x = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
        const y_s = it.next() orelse return null;
        if (it.next() != null) return null;
        const y = std.fmt.parseInt(u32, y_s, 10) catch return null;
        return .{ .tile = .{ .z = z, .x = x, .y = y } };
    }

    if (std.mem.startsWith(u8, path, "sprite")) {
        const rest = path["sprite".len..];
        // MapLibre asks for `<base>.json`, `<base>.png`, and the @2x variants.
        var ratio: u8 = 1;
        var tail = rest;
        if (std.mem.startsWith(u8, tail, "@2x")) {
            ratio = 2;
            tail = tail["@2x".len..];
        } else if (std.mem.startsWith(u8, tail, "@3x")) {
            ratio = 3;
            tail = tail["@3x".len..];
        }
        if (std.mem.eql(u8, tail, ".json")) return .{ .sprite_json = .{ .pixel_ratio = ratio } };
        if (std.mem.eql(u8, tail, ".png")) return .{ .sprite_png = .{ .pixel_ratio = ratio } };
        return null;
    }

    if (std.mem.startsWith(u8, path, "glyphs/")) {
        const rest = path["glyphs/".len..];
        const slash = std.mem.lastIndexOfScalar(u8, rest, '/') orelse return null;
        const stack = rest[0..slash];
        const range = rest[slash + 1 ..];
        if (!std.mem.endsWith(u8, range, ".pbf")) return null;
        const nums = range[0 .. range.len - ".pbf".len];
        const dash = std.mem.indexOfScalar(u8, nums, '-') orelse return null;
        const start = std.fmt.parseInt(u21, nums[0..dash], 10) catch return null;
        if (stack.len == 0) return null;
        return .{ .glyphs = .{ .stack = stack, .start = start } };
    }

    return null;
}

// ---- tests ---------------------------------------------------------------

test "parse: a composed tile url" {
    const a = parse("tile/14/4711/6262").?;
    try std.testing.expectEqual(@as(u8, 14), a.tile.z);
    try std.testing.expectEqual(@as(u32, 4711), a.tile.x);
    try std.testing.expectEqual(@as(u32, 6262), a.tile.y);
}

test "parse: a tile url with a trailing segment is refused" {
    // Guards against a style template that appends an extension: serving the
    // wrong tile is worse than serving none.
    try std.testing.expect(parse("tile/14/4711/6262/extra") == null);
    try std.testing.expect(parse("tile/14/4711") == null);
    try std.testing.expect(parse("tile/x/4711/6262") == null);
}

test "parse: sprite at each density" {
    try std.testing.expectEqual(@as(u8, 1), parse("sprite.json").?.sprite_json.pixel_ratio);
    try std.testing.expectEqual(@as(u8, 1), parse("sprite.png").?.sprite_png.pixel_ratio);
    try std.testing.expectEqual(@as(u8, 2), parse("sprite@2x.json").?.sprite_json.pixel_ratio);
    try std.testing.expectEqual(@as(u8, 2), parse("sprite@2x.png").?.sprite_png.pixel_ratio);
    try std.testing.expect(parse("sprite.gif") == null);
}

test "parse: a glyph range keeps a fontstack containing spaces" {
    const a = parse("glyphs/Noto Sans Regular/0-255.pbf").?;
    try std.testing.expectEqualStrings("Noto Sans Regular", a.glyphs.stack);
    try std.testing.expectEqual(@as(u21, 0), a.glyphs.start);

    const b = parse("glyphs/Noto Sans Bold/256-511.pbf").?;
    try std.testing.expectEqualStrings("Noto Sans Bold", b.glyphs.stack);
    try std.testing.expectEqual(@as(u21, 256), b.glyphs.start);
}

test "parse: unknown paths are refused, not passed through" {
    try std.testing.expect(parse("") == null);
    try std.testing.expect(parse("style.json") == null);
    try std.testing.expect(parse("glyphs/NoRange") == null);
}

test "faceFor: the three label tiers select three distinct faces" {
    const font = t57.render.font;
    try std.testing.expectEqual(font.notosans.ptr, Provider.faceFor("Noto Sans Regular").ptr);
    try std.testing.expectEqual(font.notosans_bold.ptr, Provider.faceFor("Noto Sans Bold").ptr);
    try std.testing.expectEqual(font.notosans_italic.ptr, Provider.faceFor("Noto Sans Italic").ptr);
}
