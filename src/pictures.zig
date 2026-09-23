//! Pictures of charts, for a shell's chart list.
//!
//! A shell requests one chart at one point and size, and gets back RGBA or
//! PENDING. There are three sources:
//!
//! - The chart being drawn is pictured as the handle draws it: a snapshot,
//!   taken once the handle has settled.
//! - Any other link, asked for as a TILE, is the one publisher tile at the
//!   point. A style that is not all raster has no such tile, and none is
//!   returned.
//! - Any link asked for as a RENDER is drawn on a second handle with no
//!   window. That handle has no fetcher of its own: its fetches go out through
//!   this handle's fetcher as relayed requests, and their responses return
//!   the same way.
//!
//! No thread of its own. The second handle ticks inside this handle's frame
//! step, under its api lock, at most once per `tick_ms`. While a picture is
//! pending the frame step waits at most `frame.picture_ms`. Once every
//! picture is ready or failed, pictures add no wake. Every pending picture
//! has a deadline, so none keeps the loop awake for good.

const std = @import("std");
const cc = @import("c.zig").c;
const root = @import("root.zig");
const png = @import("png.zig");
const cachedir = @import("cachedir.zig");
const clock = @import("clock.zig");
const frame = @import("shell/frame.zig");

const Lookout = root.Lookout;

/// What the shell requests. See lookout-library.h.
pub const Kind = enum(c_int) { tile = 0, render = 1 };
pub const Result = enum(c_int) { none = 0, ready = 1, pending = 2 };

/// The largest side a shell may ask for.
pub const MAX_SIDE = 4096;

/// A cap on the pixels kept in memory. Past it the least recently asked
/// picture is dropped.
const MAX_BYTES = 64 << 20;

/// How long each source may stay pending.
const snapshot_ms: i64 = 9_000;
const template_ms: i64 = 12_000;
const fetch_ms: i64 = 20_000;

/// The second handle's clock: one tick per `tick_ms`, settling counted only
/// after `warmup` ticks, done after `settle` quiet ticks in a row or after
/// `patience` ticks whatever the state.
const tick_ms: i64 = 100;
const warmup = 10;
const settle = 4;
const patience = 70;

/// Relay tokens with this bit set are a picture's tile. The rest are the
/// second handle's own request ids.
const TILE_TOKEN: u64 = 1 << 63;

const Source = enum { snapshot, tile, render };
/// A `dropped` picture leaves the list at the end of the step that set it.
const State = enum { waiting, ready, failed, dropped };

const Picture = struct {
    url: []u8,
    kind: Kind,
    /// The cache key's place: z, x, y. See `cellOf`.
    cell: [3]i32,
    w: u32,
    h: u32,
    lon: f64,
    lat: f64,
    zoom: f64,
    source: Source,
    state: State = .waiting,
    px: []u8 = &.{},
    serial: u64,
    deadline_ms: i64,
    used_ms: i64,
    /// A tile picture's style read went out.
    template_asked: bool = false,
    /// A tile picture's tile fetch is out.
    fetching: bool = false,
};

pub const Pictures = struct {
    alloc: std.mem.Allocator,
    list: std.ArrayList(*Picture) = .empty,
    bytes: usize = 0,
    next_serial: u64 = 1,

    /// The second handle, open while a render is queued.
    engine: ?*Lookout = null,
    /// Set when the second handle failed to open, so no render waits on it.
    engine_refused: bool = false,
    job: ?*Picture = null,
    ticks: u32 = 0,
    quiet: u32 = 0,
    last_tick_ms: i64 = 0,

    pub fn init(alloc: std.mem.Allocator) Pictures {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Pictures, main: *Lookout) void {
        self.closeEngine(main);
        for (self.list.items) |p| self.free(p);
        self.list.deinit(self.alloc);
        self.* = undefined;
    }

    fn free(self: *Pictures, p: *Picture) void {
        self.bytes -= p.px.len;
        if (p.px.len != 0) self.alloc.free(p.px);
        self.alloc.free(p.url);
        self.alloc.destroy(p);
    }

    // ---- the shell's ask ------------------------------------------------------

    /// One picture. `url` empty is lookout's own chart. READY copies it into
    /// `dst`, which holds w * h * 4 bytes.
    pub fn get(
        self: *Pictures,
        main: *Lookout,
        url: []const u8,
        kind: Kind,
        lon: f64,
        lat: f64,
        zoom: f64,
        w: u32,
        h: u32,
        dst: []u8,
    ) Result {
        if (w == 0 or h == 0 or w > MAX_SIDE or h > MAX_SIDE) return .none;
        if (dst.len < @as(usize, w) * h * 4) return .none;
        if (!std.math.isFinite(lon) or !std.math.isFinite(lat) or !std.math.isFinite(zoom)) return .none;
        const cell = cellOf(kind, lon, lat, zoom);
        const now = clock.ticksMs();
        if (self.find(url, kind, cell, w, h)) |p| {
            // A publisher tile stands in only until the chart is drawn. Once
            // it is, the snapshot replaces it.
            if (p.source != .tile or !isActive(main, url)) {
                p.used_ms = now;
                return self.copyOut(p, dst);
            }
            if (p.fetching) main.links.cancelRelay(TILE_TOKEN | p.serial);
            p.fetching = false;
            p.state = .dropped;
        }

        const source: Source = switch (kind) {
            .render => blk: {
                if (url.len == 0) return .none;
                break :blk .render;
            },
            .tile => blk: {
                if (isActive(main, url)) break :blk .snapshot;
                if (url.len == 0) return .none;
                switch (main.links.tileKnown(url)) {
                    .none, .not_a_link => return .none,
                    .tiles, .unknown => break :blk .tile,
                }
            },
        };
        const p = self.alloc.create(Picture) catch return .none;
        p.* = .{
            .url = self.alloc.dupe(u8, url) catch {
                self.alloc.destroy(p);
                return .none;
            },
            .kind = kind,
            .cell = cell,
            .w = w,
            .h = h,
            .lon = lon,
            .lat = lat,
            .zoom = zoom,
            .source = source,
            .serial = self.next_serial,
            // A render has no deadline: `patience` bounds it.
            .deadline_ms = now + switch (source) {
                .snapshot => snapshot_ms,
                .tile => template_ms,
                .render => 0,
            },
            .used_ms = now,
        };
        self.next_serial += 1;
        self.list.append(self.alloc, p) catch {
            self.free(p);
            return .none;
        };
        if (source == .render) self.readKept(p);
        return self.copyOut(p, dst);
    }

    fn copyOut(self: *Pictures, p: *Picture, dst: []u8) Result {
        _ = self;
        return switch (p.state) {
            .waiting => .pending,
            .failed, .dropped => .none,
            .ready => blk: {
                @memcpy(dst[0..p.px.len], p.px);
                break :blk .ready;
            },
        };
    }

    fn find(self: *Pictures, url: []const u8, kind: Kind, cell: [3]i32, w: u32, h: u32) ?*Picture {
        for (self.list.items) |p| {
            if (p.state == .dropped) continue;
            if (p.kind == kind and p.w == w and p.h == h and
                std.mem.eql(i32, &p.cell, &cell) and std.mem.eql(u8, p.url, url)) return p;
        }
        return null;
    }

    fn bySerial(self: *Pictures, serial: u64) ?*Picture {
        for (self.list.items) |p| {
            if (p.serial == serial) return p;
        }
        return null;
    }

    /// Drop every picture that is not ready, and close the second handle. A
    /// failed picture is dropped too, so the next request tries again.
    pub fn cancel(self: *Pictures, main: *Lookout) void {
        self.closeEngine(main);
        var i: usize = 0;
        while (i < self.list.items.len) {
            const p = self.list.items[i];
            if (p.state == .ready) {
                i += 1;
                continue;
            }
            if (p.fetching) main.links.cancelRelay(TILE_TOKEN | p.serial);
            _ = self.list.orderedRemove(i);
            self.free(p);
        }
        self.engine_refused = false;
    }

    // ---- the frame step -------------------------------------------------------

    /// Advance every pending picture. True while one is still pending.
    pub fn step(self: *Pictures, main: *Lookout) bool {
        if (self.list.items.len == 0) return false;
        const now = clock.ticksMs();
        var busy = false;
        var i: usize = 0;
        while (i < self.list.items.len) : (i += 1) {
            const p = self.list.items[i];
            if (p.state != .waiting) continue;
            switch (p.source) {
                .snapshot => self.stepSnapshot(main, p, now),
                .tile => self.stepTile(main, p, now),
                .render => {},
            }
            if (p.state == .waiting) busy = true;
        }
        if (self.stepRender(main, now)) busy = true;
        self.sweep();
        return busy;
    }

    /// Take dropped pictures off the list, then the least recently asked
    /// past the memory cap. A pending picture stays.
    fn sweep(self: *Pictures) void {
        var i: usize = 0;
        while (i < self.list.items.len) {
            const p = self.list.items[i];
            if (p.state != .dropped) {
                i += 1;
                continue;
            }
            _ = self.list.orderedRemove(i);
            self.free(p);
        }
        self.evict(null);
    }

    fn finish(self: *Pictures, main: *Lookout, p: *Picture, px: ?[]u8) void {
        if (px) |bytes| {
            p.px = bytes;
            p.state = .ready;
            self.bytes += bytes.len;
        } else {
            p.state = .failed;
        }
        p.fetching = false;
        main.links.changed = true;
    }

    /// Drop the least recently asked pictures past the memory cap. `spare`
    /// and anything pending stay.
    fn evict(self: *Pictures, spare: ?*Picture) void {
        while (self.bytes > MAX_BYTES) {
            var oldest: ?usize = null;
            for (self.list.items, 0..) |p, i| {
                if (p == spare or p.state == .waiting) continue;
                if (oldest == null or p.used_ms < self.list.items[oldest.?].used_ms) oldest = i;
            }
            const i = oldest orelse return;
            self.free(self.list.orderedRemove(i));
        }
    }

    fn stepSnapshot(self: *Pictures, main: *Lookout, p: *Picture, now: i64) void {
        // The pick moved on, or the style failed to draw: this chart is not
        // the one on screen. The next request fetches its tile.
        const failed = p.url.len != 0 and main.links.rs == null and main.links.err.len != 0;
        if (!isActive(main, p.url) or failed) {
            p.state = .dropped;
            main.links.changed = true;
            return;
        }
        const settled = main.links.rs == null and !main.needsRedraw() and !main.isBuilding();
        if (!settled and now < p.deadline_ms) return;
        // Still opening the charts at the deadline: the frame has no chart
        // in it yet.
        if (main.loading) return self.finish(main, p, null);
        self.finish(main, p, self.shoot(main, p.w, p.h));
    }

    /// The handle's frame, filled into w by h. Null when it cannot be read.
    fn shoot(self: *Pictures, l: *Lookout, w: u32, h: u32) ?[]u8 {
        const sw = l.ct.width();
        const sh = l.ct.height();
        if (sw == 0 or sh == 0) return null;
        const full = self.alloc.alloc(u8, @as(usize, sw) * sh * 4) catch return null;
        defer self.alloc.free(full);
        l.snapshotNow(full) catch return null;
        const out = self.alloc.alloc(u8, @as(usize, w) * h * 4) catch return null;
        fill(full, sw, sh, out, w, h);
        return out;
    }

    fn stepTile(self: *Pictures, main: *Lookout, p: *Picture, now: i64) void {
        if (now >= p.deadline_ms) {
            if (p.fetching) main.links.cancelRelay(TILE_TOKEN | p.serial);
            return self.finish(main, p, null);
        }
        if (p.fetching) return;
        switch (main.links.tileKnown(p.url)) {
            .none, .not_a_link => return self.finish(main, p, null),
            .unknown => {
                if (!p.template_asked) p.template_asked = main.links.previewOne(p.url);
            },
            .tiles => {
                var buf: [4096]u8 = undefined;
                const z: i32 = p.cell[0];
                const url = main.links.previewUrl(p.url, p.lon, p.lat, z, &buf) orelse
                    return self.finish(main, p, null);
                if (main.links.issueRelay(url, false, TILE_TOKEN | p.serial) == 0)
                    return self.finish(main, p, null);
                p.fetching = true;
                p.deadline_ms = now + fetch_ms;
            },
        }
    }

    /// A picture's tile came back.
    fn onTile(self: *Pictures, main: *Lookout, serial: u64, bytes: []const u8, status: c_int) void {
        const p = self.bySerial(serial) orelse return;
        if (p.state != .waiting or !p.fetching) return;
        p.fetching = false;
        const ok = status >= 200 and status < 300 and bytes.len != 0;
        self.finish(main, p, if (ok) self.decodeFilled(bytes, p.w, p.h) else null);
    }

    /// A PNG or JPEG, premultiplied and filled into w by h.
    fn decodeFilled(self: *Pictures, bytes: []const u8, w: u32, h: u32) ?[]u8 {
        if (bytes.len > std.math.maxInt(c_int)) return null;
        var sw: c_int = 0;
        var sh: c_int = 0;
        var comp: c_int = 0;
        const raw = cc.stbi_load_from_memory(bytes.ptr, @intCast(bytes.len), &sw, &sh, &comp, 4) orelse return null;
        defer cc.stbi_image_free(raw);
        if (sw <= 0 or sh <= 0) return null;
        const src = raw[0 .. @as(usize, @intCast(sw)) * @as(usize, @intCast(sh)) * 4];
        premultiply(src);
        const out = self.alloc.alloc(u8, @as(usize, w) * h * 4) catch return null;
        fill(src, @intCast(sw), @intCast(sh), out, w, h);
        return out;
    }

    // ---- the second handle ----------------------------------------------------

    /// Advance the render in progress, or start the next. True while one is
    /// running or waiting.
    fn stepRender(self: *Pictures, main: *Lookout, now: i64) bool {
        if (self.job == null) {
            const next = self.nextRender() orelse {
                self.closeEngine(main);
                return false;
            };
            if (!self.start(main, next)) {
                self.finish(main, next, null);
                // The next one starts on the next step.
                return self.afterRender(main);
            }
            return true;
        }
        const p = self.job.?;
        const e = self.engine.?;
        if (self.last_tick_ms != 0 and now - self.last_tick_ms < tick_ms) return true;
        self.last_tick_ms = now;
        _ = e.frameStep();
        e.buildStep();
        self.ticks += 1;
        // The style did not resolve. The handle is left drawing lookout's own
        // chart, and that is not a picture of this link.
        if (e.links.rs == null and e.links.err.len != 0) {
            self.job = null;
            self.finish(main, p, null);
            return self.afterRender(main);
        }
        if (self.ticks >= warmup) {
            const quiet = e.links.rs == null and e.ct.idle() and !e.isBuilding();
            self.quiet = if (quiet) self.quiet + 1 else 0;
        }
        if (self.quiet < settle and self.ticks < patience) return true;
        self.job = null;
        const px = self.shoot(e, p.w, p.h);
        if (px) |bytes| self.keep(p, bytes);
        self.finish(main, p, px);
        return self.afterRender(main);
    }

    /// A render finished. The second handle closes at once when none is
    /// queued, so it holds no device while the loop is stopped.
    fn afterRender(self: *Pictures, main: *Lookout) bool {
        if (self.nextRender() != null) return true;
        self.closeEngine(main);
        return false;
    }

    fn nextRender(self: *Pictures) ?*Picture {
        for (self.list.items) |p| {
            if (p.source == .render and p.state == .waiting) return p;
        }
        return null;
    }

    fn start(self: *Pictures, main: *Lookout, p: *Picture) bool {
        if (main.links.get == null) return false;
        const e = self.engine orelse blk: {
            if (self.engine_refused) return false;
            const e = Lookout.openCharts(std.heap.c_allocator, &.{}, .{
                .width = p.w,
                .height = p.h,
                .want_window = false,
                .want_msaa = false,
                .link_store = false,
            }) catch {
                self.engine_refused = true;
                return false;
            };
            e.setHttpProvider(forwardGet, forwardCancel, main);
            self.engine = e;
            break :blk e;
        };
        if (e.ct.width() != p.w or e.ct.height() != p.h) e.resize(p.w, p.h) catch return false;
        e.setView(.{ .lon = p.lon, .lat = p.lat, .zoom = p.zoom });
        e.links.drawOnly(p.url);
        self.job = p;
        self.ticks = 0;
        self.quiet = 0;
        self.last_tick_ms = 0;
        return true;
    }

    /// Close the second handle. Clearing its fetcher first cancels what it
    /// has out, through forwardCancel.
    fn closeEngine(self: *Pictures, main: *Lookout) void {
        _ = main;
        const e = self.engine orelse return;
        self.engine = null;
        self.job = null;
        e.setHttpProvider(null, null, null);
        e.close();
    }

    /// The second handle's fetcher: this handle's, as a relayed request under
    /// the second handle's own id.
    fn forwardGet(user: ?*anyopaque, req_id: u64, url: [*:0]const u8, allow_file: c_int) callconv(.c) void {
        const main: *Lookout = @ptrCast(@alignCast(user orelse return));
        if (main.links.issueRelay(std.mem.span(url), allow_file != 0, req_id) != 0) return;
        const e = main.pictures.engine orelse return;
        e.links.respond(req_id, &.{}, 0);
    }

    fn forwardCancel(user: ?*anyopaque, req_id: u64) callconv(.c) void {
        const main: *Lookout = @ptrCast(@alignCast(user orelse return));
        main.links.cancelRelay(req_id);
    }

    /// Delivery for every relayed fetch on this handle.
    pub fn onRelay(ctx: *anyopaque, token: u64, bytes: []const u8, status: c_int) void {
        const main: *Lookout = @ptrCast(@alignCast(ctx));
        const self = &main.pictures;
        if (token & TILE_TOKEN != 0) return self.onTile(main, token & ~TILE_TOKEN, bytes, status);
        const e = self.engine orelse return;
        e.links.respond(token, bytes, status);
    }

    // ---- the rendered pictures on disk ----------------------------------------

    fn keptPath(self: *Pictures, p: *const Picture) ?[]u8 {
        const r = cachedir.rootPath(self.alloc) orelse return null;
        defer self.alloc.free(r);
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(p.url);
        hasher.update(std.mem.asBytes(&p.cell));
        hasher.update(std.mem.asBytes(&p.w));
        hasher.update(std.mem.asBytes(&p.h));
        return std.fmt.allocPrint(self.alloc, "{s}/lookout/pictures/{x:0>16}.png", .{ r, hasher.final() }) catch null;
    }

    /// A render from an earlier run, if one is on disk.
    fn readKept(self: *Pictures, p: *Picture) void {
        const path = self.keptPath(p) orelse return;
        defer self.alloc.free(path);
        const io = std.Io.Threaded.global_single_threaded.io();
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, self.alloc, .limited(64 << 20)) catch return;
        defer self.alloc.free(bytes);
        if (bytes.len > std.math.maxInt(c_int)) return;
        var sw: c_int = 0;
        var sh: c_int = 0;
        var comp: c_int = 0;
        const raw = cc.stbi_load_from_memory(bytes.ptr, @intCast(bytes.len), &sw, &sh, &comp, 4) orelse return;
        defer cc.stbi_image_free(raw);
        if (sw != p.w or sh != p.h) return;
        const px = self.alloc.dupe(u8, raw[0 .. @as(usize, p.w) * p.h * 4]) catch return;
        p.px = px;
        p.state = .ready;
        self.bytes += px.len;
        self.evict(p);
    }

    fn keep(self: *Pictures, p: *const Picture, px: []const u8) void {
        const path = self.keptPath(p) orelse return;
        defer self.alloc.free(path);
        const bytes = png.encode(self.alloc, px, p.w, p.h) catch return;
        defer self.alloc.free(bytes);
        const io = std.Io.Threaded.global_single_threaded.io();
        const cwd = std.Io.Dir.cwd();
        if (std.fs.path.dirname(path)) |d| cwd.createDirPath(io, d) catch return;
        cwd.writeFile(io, .{ .sub_path = path, .data = bytes }) catch {};
    }
};

/// True when `url` is the chart this handle draws. Empty is lookout's own.
fn isActive(main: *Lookout, url: []const u8) bool {
    const act = main.links.active orelse return url.len == 0;
    return std.mem.eql(u8, act, url);
}

/// Where a picture is kept in the cache. A tile is keyed by the tile it
/// shows, at the zoom asked for. A render is keyed by a quarter degree cell,
/// so a mariner who moves a few miles keeps the pictures they have.
fn cellOf(kind: Kind, lon: f64, lat: f64, zoom: f64) [3]i32 {
    const z: i32 = @intFromFloat(std.math.clamp(@floor(zoom), 0, 22));
    return switch (kind) {
        .tile => blk: {
            const xy = tileXY(lon, lat, std.math.clamp(z, 0, 20));
            break :blk .{ std.math.clamp(z, 0, 20), xy[0], xy[1] };
        },
        .render => .{
            z,
            @intFromFloat(std.math.clamp(@trunc(lon * 4), -1000, 1000)),
            @intFromFloat(std.math.clamp(@trunc(lat * 4), -1000, 1000)),
        },
    };
}

/// The XYZ tile holding a point, north counting from zero.
fn tileXY(lon: f64, lat: f64, z: i32) [2]i32 {
    const n = @as(f64, @floatFromInt(@as(i64, 1) << @intCast(z)));
    const wrapped = lon - @floor((lon + 180.0) / 360.0) * 360.0;
    const x_f = (wrapped + 180.0) / 360.0 * n;
    const rad = std.math.clamp(lat, -85.05112878, 85.05112878) * std.math.pi / 180.0;
    const y_f = (1.0 - @log(@tan(rad) + 1.0 / @cos(rad)) / std.math.pi) / 2.0 * n;
    const last: i32 = @intFromFloat(n - 1);
    return .{
        std.math.clamp(@as(i32, @intFromFloat(@floor(x_f))), 0, last),
        std.math.clamp(@as(i32, @intFromFloat(@floor(y_f))), 0, last),
    };
}

fn premultiply(px: []u8) void {
    var i: usize = 0;
    while (i + 3 < px.len) : (i += 4) {
        const a: u32 = px[i + 3];
        if (a == 255) continue;
        inline for (0..3) |c| px[i + c] = @intCast((@as(u32, px[i + c]) * a + 127) / 255);
    }
}

/// Scale `src` to cover `dst` and crop the overflow evenly off both sides, as
/// a picture filling a card is drawn. A pixel shrinking is the average of the
/// source pixels under it. A pixel growing is sampled between its four
/// nearest.
fn fill(src: []const u8, sw: u32, sh: u32, dst: []u8, dw: u32, dh: u32) void {
    const fsw: f64 = @floatFromInt(sw);
    const fsh: f64 = @floatFromInt(sh);
    const fdw: f64 = @floatFromInt(dw);
    const fdh: f64 = @floatFromInt(dh);
    const scale = @max(fdw / fsw, fdh / fsh);
    const step = 1.0 / scale;
    const x0 = (fsw - fdw * step) / 2.0;
    const y0 = (fsh - fdh * step) / 2.0;
    var j: u32 = 0;
    while (j < dh) : (j += 1) {
        const fy0 = y0 + @as(f64, @floatFromInt(j)) * step;
        var i: u32 = 0;
        while (i < dw) : (i += 1) {
            const fx0 = x0 + @as(f64, @floatFromInt(i)) * step;
            const o = (@as(usize, j) * dw + i) * 4;
            if (step > 1.0) {
                box(src, sw, sh, fx0, fy0, step, dst[o .. o + 4]);
            } else {
                bilinear(src, sw, sh, fx0 + step / 2.0 - 0.5, fy0 + step / 2.0 - 0.5, dst[o .. o + 4]);
            }
        }
    }
}

fn box(src: []const u8, sw: u32, sh: u32, fx: f64, fy: f64, step: f64, out: []u8) void {
    const xa: u32 = @intFromFloat(std.math.clamp(@floor(fx), 0, @as(f64, @floatFromInt(sw - 1))));
    const ya: u32 = @intFromFloat(std.math.clamp(@floor(fy), 0, @as(f64, @floatFromInt(sh - 1))));
    const xb: u32 = @intFromFloat(std.math.clamp(@ceil(fx + step), @as(f64, @floatFromInt(xa + 1)), @as(f64, @floatFromInt(sw))));
    const yb: u32 = @intFromFloat(std.math.clamp(@ceil(fy + step), @as(f64, @floatFromInt(ya + 1)), @as(f64, @floatFromInt(sh))));
    var sum = [4]u32{ 0, 0, 0, 0 };
    var y = ya;
    while (y < yb) : (y += 1) {
        var x = xa;
        while (x < xb) : (x += 1) {
            const s = (@as(usize, y) * sw + x) * 4;
            inline for (0..4) |c| sum[c] += src[s + c];
        }
    }
    const n = (xb - xa) * (yb - ya);
    inline for (0..4) |c| out[c] = @intCast((sum[c] + n / 2) / n);
}

fn bilinear(src: []const u8, sw: u32, sh: u32, fx: f64, fy: f64, out: []u8) void {
    const mx: f64 = @floatFromInt(sw - 1);
    const my: f64 = @floatFromInt(sh - 1);
    const x = std.math.clamp(fx, 0, mx);
    const y = std.math.clamp(fy, 0, my);
    const xa: u32 = @intFromFloat(@floor(x));
    const ya: u32 = @intFromFloat(@floor(y));
    const xb = @min(xa + 1, sw - 1);
    const yb = @min(ya + 1, sh - 1);
    const tx = x - @as(f64, @floatFromInt(xa));
    const ty = y - @as(f64, @floatFromInt(ya));
    inline for (0..4) |c| {
        const p00: f64 = @floatFromInt(src[(@as(usize, ya) * sw + xa) * 4 + c]);
        const p10: f64 = @floatFromInt(src[(@as(usize, ya) * sw + xb) * 4 + c]);
        const p01: f64 = @floatFromInt(src[(@as(usize, yb) * sw + xa) * 4 + c]);
        const p11: f64 = @floatFromInt(src[(@as(usize, yb) * sw + xb) * 4 + c]);
        const top = p00 + (p10 - p00) * tx;
        const bot = p01 + (p11 - p01) * tx;
        out[c] = @intFromFloat(std.math.clamp(@round(top + (bot - top) * ty), 0, 255));
    }
}

// ---- tests ---------------------------------------------------------------------

const testing = std.testing;

test "a picture covers its card and is cropped evenly off the long side" {
    // Four columns: red, green, blue, white. Covering a 2x2 card keeps the
    // middle two.
    var src: [4 * 2 * 4]u8 = undefined;
    const cols = [4][4]u8{ .{ 255, 0, 0, 255 }, .{ 0, 255, 0, 255 }, .{ 0, 0, 255, 255 }, .{ 255, 255, 255, 255 } };
    for (0..2) |y| for (0..4) |x| @memcpy(src[(y * 4 + x) * 4 ..][0..4], &cols[x]);
    var dst: [2 * 2 * 4]u8 = undefined;
    fill(&src, 4, 2, &dst, 2, 2);
    try testing.expectEqualSlices(u8, &cols[1], dst[0..4]);
    try testing.expectEqualSlices(u8, &cols[2], dst[4..8]);
    try testing.expectEqualSlices(u8, &cols[1], dst[8..12]);

    // Shrinking averages: the whole 4x2 into 1x1 covers the middle two.
    var one: [4]u8 = undefined;
    fill(&src, 4, 2, &one, 1, 1);
    try testing.expectEqualSlices(u8, &.{ 0, 128, 128, 255 }, &one);

    // Growing keeps a flat colour flat.
    var flat = [_]u8{ 10, 20, 30, 255 } ** 4;
    var big: [8 * 4 * 4]u8 = undefined;
    fill(&flat, 2, 2, &big, 8, 4);
    for (0..32) |i| try testing.expectEqualSlices(u8, flat[0..4], big[i * 4 ..][0..4]);
}

test "a tile picture is keyed by its tile, and a render by a quarter degree" {
    // Annapolis at z9 is tile 147/195.
    try testing.expectEqual([3]i32{ 9, 147, 195 }, cellOf(.tile, -76.48, 38.97, 9.7));
    try testing.expectEqual([3]i32{ 12, -305, 155 }, cellOf(.render, -76.48, 38.97, 12));
    try testing.expectEqual(cellOf(.render, -76.40, 38.90, 12), cellOf(.render, -76.30, 38.80, 12));
}

test "a picture kept on disk reads back as it was written" {
    const px = [_]u8{ 1, 2, 3, 255, 4, 5, 6, 255, 7, 8, 9, 255, 10, 11, 12, 255, 13, 14, 15, 255, 16, 17, 18, 255 };
    const bytes = try png.encode(testing.allocator, &px, 3, 2);
    defer testing.allocator.free(bytes);
    var w: c_int = 0;
    var h: c_int = 0;
    var comp: c_int = 0;
    const raw = cc.stbi_load_from_memory(bytes.ptr, @intCast(bytes.len), &w, &h, &comp, 4) orelse return error.NotDecoded;
    defer cc.stbi_image_free(raw);
    try testing.expectEqual(@as(c_int, 3), w);
    try testing.expectEqual(@as(c_int, 2), h);
    try testing.expectEqualSlices(u8, &px, raw[0..px.len]);
}

/// A shell's fetcher that holds every request until the test responds.
const TestFetch = struct {
    reqs: std.ArrayList(struct { id: u64, url: []u8, done: bool = false }) = .empty,

    fn get(user: ?*anyopaque, id: u64, url: [*:0]const u8, allow_file: c_int) callconv(.c) void {
        _ = allow_file;
        const f: *TestFetch = @ptrCast(@alignCast(user orelse return));
        const copy = testing.allocator.dupe(u8, std.mem.span(url)) catch return;
        f.reqs.append(testing.allocator, .{ .id = id, .url = copy }) catch testing.allocator.free(copy);
    }

    fn cancel(user: ?*anyopaque, id: u64) callconv(.c) void {
        const f: *TestFetch = @ptrCast(@alignCast(user orelse return));
        for (f.reqs.items) |*r| {
            if (r.id == id) r.done = true;
        }
    }

    /// Answer everything out: a style for a style url, `tile` for the rest.
    fn respondAll(f: *TestFetch, main: *Lookout, style: []const u8, tile: []const u8) usize {
        var n: usize = 0;
        for (f.reqs.items) |*r| {
            if (r.done) continue;
            r.done = true;
            const body = if (std.mem.endsWith(u8, r.url, "style.json")) style else tile;
            main.links.respond(r.id, body, 200);
            n += 1;
        }
        return n;
    }

    fn deinit(f: *TestFetch) void {
        for (f.reqs.items) |r| testing.allocator.free(r.url);
        f.reqs.deinit(testing.allocator);
    }
};

const test_style =
    \\{"version":8,"sources":{"sea":{"type":"raster","tileSize":256,
    \\ "tiles":["https://t.example/{z}/{x}/{y}.png"]}},
    \\ "layers":[{"id":"sea","type":"raster","source":"sea"}]}
;

/// A handle with its store, cache and fetcher pointed at a scratch directory,
/// or null on a machine with no GPU device.
fn openForTest(tmp: *std.testing.TmpDir, f: *TestFetch) !?*Lookout {
    const marks = @import("markers.zig");
    const home = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer testing.allocator.free(home);
    marks.test_support_dir = try testing.allocator.dupe(u8, home);
    cachedir.setRoot(home);
    const main = Lookout.openCharts(std.heap.c_allocator, &.{}, .{ .width = 64, .height = 64 }) catch |e| switch (e) {
        error.SurfaceFailed => {
            testing.allocator.free(marks.test_support_dir.?);
            marks.test_support_dir = null;
            return null;
        },
        else => return e,
    };
    main.setHttpProvider(TestFetch.get, TestFetch.cancel, f);
    return main;
}

/// What a windowed shell's frame leaves behind. This handle has no window, so
/// its frames are never presented. A snapshot builds and posts the overlay as
/// a frame does.
fn presented(main: *Lookout) void {
    var px: [64 * 64 * 4]u8 = undefined;
    main.snapshotNow(&px) catch {};
    main.ct.m.markDrawn();
    main.view_dirty = false;
}

fn closeForTest(main: *Lookout) void {
    const marks = @import("markers.zig");
    main.close();
    if (marks.test_support_dir) |d| testing.allocator.free(d);
    marks.test_support_dir = null;
}

/// A solid 256 pixel tile.
fn solidTile(rgba: [4]u8) ![]u8 {
    const px = try testing.allocator.alloc(u8, 256 * 256 * 4);
    defer testing.allocator.free(px);
    for (0..256 * 256) |i| @memcpy(px[i * 4 ..][0..4], &rgba);
    return png.encode(testing.allocator, px, 256, 256);
}

test "a tile picture and a snapshot come back, and then the frame loop stops" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var f: TestFetch = .{};
    defer f.deinit();
    const main = (try openForTest(&tmp, &f)) orelse return error.SkipZigTest;
    defer closeForTest(main);
    main.links.import(
        \\{"links":[{"url":"https://t.example/style.json","name":"T"}]}
    );
    const tile = try solidTile(.{ 200, 40, 40, 255 });
    defer testing.allocator.free(tile);

    var dst: [32 * 16 * 4]u8 = undefined;
    const url = "https://t.example/style.json";
    // Not a link, and not asked as a render: no picture.
    try testing.expectEqual(Result.none, main.chartLinkPicture("https://u.example/style.json", .tile, -76.48, 38.97, 9, 32, 16, &dst));
    try testing.expectEqual(Result.pending, main.chartLinkPicture(url, .tile, -76.48, 38.97, 9, 32, 16, &dst));
    // Lookout's own chart is the one drawn, so its picture is a snapshot.
    try testing.expectEqual(Result.pending, main.chartLinkPicture("", .tile, -76.48, 38.97, 9, 32, 16, &dst));

    var tries: usize = 0;
    while (tries < 200) : (tries += 1) {
        presented(main);
        _ = main.frameStep();
        _ = f.respondAll(main, test_style, tile);
        if (main.chartLinkPicture(url, .tile, -76.48, 38.97, 9, 32, 16, &dst) != .pending and
            main.chartLinkPicture("", .tile, -76.48, 38.97, 9, 32, 16, &dst) != .pending) break;
        @import("lock.zig").sleepMs(5);
    }
    try testing.expect(main.links.takeChanged());
    try testing.expectEqual(Result.ready, main.chartLinkPicture(url, .tile, -76.48, 38.97, 9, 32, 16, &dst));
    try testing.expectEqualSlices(u8, &.{ 200, 40, 40, 255 }, dst[0..4]);
    try testing.expectEqual(Result.ready, main.chartLinkPicture("", .tile, -76.48, 38.97, 9, 32, 16, &dst));

    // Picked, the link is pictured as it is drawn.
    main.links.select(url);
    try testing.expectEqual(Result.pending, main.chartLinkPicture(url, .tile, -76.48, 38.97, 9, 32, 16, &dst));
    tries = 0;
    while (tries < 400) : (tries += 1) {
        presented(main);
        _ = main.frameStep();
        _ = f.respondAll(main, test_style, tile);
        if (main.chartLinkPicture(url, .tile, -76.48, 38.97, 9, 32, 16, &dst) != .pending) break;
        @import("lock.zig").sleepMs(5);
    }
    try testing.expectEqual(Result.ready, main.chartLinkPicture(url, .tile, -76.48, 38.97, 9, 32, 16, &dst));
    try testing.expectEqual(Source.snapshot, main.pictures.find(url, .tile, cellOf(.tile, -76.48, 38.97, 9), 32, 16).?.source);

    // Every picture is ready, so the loop stops.
    presented(main);
    var step = main.frameStep();
    for (0..4) |_| step = main.frameStep();
    try testing.expectEqual(frame.Verdict.idle, step.verdict);
    try testing.expectEqual(@as(c_int, 0), step.wait_ms);
    try testing.expect(!main.pictures.step(main));
}

test "a render fetches through the first handle's fetcher, and is kept on disk" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var f: TestFetch = .{};
    defer f.deinit();
    const main = (try openForTest(&tmp, &f)) orelse return error.SkipZigTest;
    defer closeForTest(main);
    const tile = try solidTile(.{ 30, 90, 200, 255 });
    defer testing.allocator.free(tile);

    const url = "https://t.example/style.json";
    const w = 48;
    const h = 32;
    var dst: [w * h * 4]u8 = undefined;
    try testing.expectEqual(Result.pending, main.chartLinkPicture(url, .render, -76.48, 38.97, 12, w, h, &dst));
    var responded: usize = 0;
    var tries: usize = 0;
    while (tries < 3000) : (tries += 1) {
        presented(main);
        const step = main.frameStep();
        if (main.pictures.job != null) {
            try testing.expect(step.verdict != .idle);
            try testing.expect(step.wait_ms <= frame.picture_ms);
        }
        responded += f.respondAll(main, test_style, tile);
        if (main.chartLinkPicture(url, .render, -76.48, 38.97, 12, w, h, &dst) != .pending) break;
        @import("lock.zig").sleepMs(5);
    }
    try testing.expectEqual(Result.ready, main.chartLinkPicture(url, .render, -76.48, 38.97, 12, w, h, &dst));
    // The style and at least one tile went out through the first handle.
    try testing.expect(responded >= 2);
    const mid = (@as(usize, h / 2) * w + w / 2) * 4;
    try testing.expectEqualSlices(u8, &.{ 30, 90, 200, 255 }, dst[mid .. mid + 4]);

    // The queue is empty, so the second handle closes and the loop stops.
    presented(main);
    var step = main.frameStep();
    for (0..4) |_| step = main.frameStep();
    try testing.expect(main.pictures.engine == null);
    try testing.expectEqual(frame.Verdict.idle, step.verdict);

    // A new run reads it off disk, with no fetch.
    main.pictures.deinit(main);
    main.pictures = Pictures.init(main.alloc);
    const before = f.reqs.items.len;
    @memset(&dst, 0);
    try testing.expectEqual(Result.ready, main.chartLinkPicture(url, .render, -76.48, 38.97, 12, w, h, &dst));
    try testing.expectEqualSlices(u8, &.{ 30, 90, 200, 255 }, dst[mid .. mid + 4]);
    try testing.expectEqual(before, f.reqs.items.len);
}

test "a render runs to the end in the frame step of a thread with a 256 KB stack" {
    // A shell's UI thread has 1 MB on Windows, and the frame step runs on it.
    // The settings store's atomic write, also under the frame step, needs
    // about 790 KB of that in std's Windows file calls. 256 KB is what is
    // left.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var f: TestFetch = .{};
    defer f.deinit();
    const main = (try openForTest(&tmp, &f)) orelse return error.SkipZigTest;
    defer closeForTest(main);
    const tile = try solidTile(.{ 30, 90, 200, 255 });
    defer testing.allocator.free(tile);

    const Run = struct {
        fn run(l: *Lookout, fetch: *TestFetch, body: []const u8, out: *Result) void {
            const url = "https://t.example/style.json";
            var dst: [48 * 32 * 4]u8 = undefined;
            out.* = l.chartLinkPicture(url, .render, -76.48, 38.97, 12, 48, 32, &dst);
            var tries: usize = 0;
            while (out.* == .pending and tries < 3000) : (tries += 1) {
                presented(l);
                _ = l.frameStep();
                _ = fetch.respondAll(l, test_style, body);
                out.* = l.chartLinkPicture(url, .render, -76.48, 38.97, 12, 48, 32, &dst);
                @import("lock.zig").sleepMs(5);
            }
        }
    };
    var got: Result = .pending;
    const th = try std.Thread.spawn(.{ .stack_size = 256 * 1024 }, Run.run, .{ main, &f, tile, &got });
    th.join();
    try testing.expectEqual(Result.ready, got);
}
